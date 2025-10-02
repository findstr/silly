local logger = require "silly.logger"
local code = require "silly.grpc.code"
local codename = require "silly.grpc.codename"
local transport = require "silly.http.transport"
local pb = require "pb"

local assert = assert
local pack = string.pack
local unpack = string.unpack
local format = string.format
local sub = string.sub
local concat = table.concat
local tonumber = tonumber
local setmetatable = setmetatable

local M = {}

local HDR_SIZE<const> = 5
local BODY_START<const> = HDR_SIZE+1
local MAX_LEN<const> = 4*1024*1024

---@param h2stream silly.http.h2stream
---@param is_server boolean
---@param timeout number?
---@return string?, string? error
local function read_body(h2stream, is_server, timeout)
	local data = ""
	--read header
	local read = h2stream.read
	for i = 1, HDR_SIZE do
		local d, err = read(h2stream, timeout)
		if not d or d == "" then
			return nil, err
		end
		data = data .. d
		if #data >= HDR_SIZE then
			break
		end
	end
	local compress, frame_size = unpack(">I1I4", data)
	assert(compress == 0, "grpc: compression not supported")
	if is_server and frame_size > MAX_LEN then
		h2stream:respond(200, {
			['content-type'] = 'application/grpc',
			['grpc-status'] = code.ResourceExhausted,
		}, true)
		return nil, "grpc: received message larger than max"
	end
	data = sub(data, BODY_START)
	if frame_size > #data then
		local buf = {data}
		frame_size = frame_size - #data
		while frame_size > 0 do
			local d, err = read(h2stream, timeout)
			if not d or d == "" then
				return nil, err
			end
			buf[#buf + 1] = d
			frame_size = frame_size - #d
		end
		data = concat(buf)
	end
	return data, nil
end

local function dispatch(registrar)
	local input_name = registrar.input_name
	local output_name = registrar.output_name
	local handlers = registrar.handlers
	--use closure for less hash
	---@param h2stream silly.http.h2stream
	return function(h2stream)
		local status, header = h2stream:readheader()
		if status ~= 200 then
			h2stream:respond(200, {
				['content-type'] = 'application/grpc',
				['grpc-status'] = code.Unknown,
				['grpc-message'] = "grpc: invalid header"
			}, true)
			return
		end
		local method = header[':path']
		local itype = input_name[method]
		local otype = output_name[method]
		local data, err = read_body(h2stream, true, nil)
		if not data then
			h2stream:close()
			logger.warn("[silly.grpc] read body failed", err)
			return
		end
		local input = pb.decode(itype, data)
		local output = assert(handlers[method], method)(input)
		local outdata = pb.encode(otype, output)
		--payloadFormat, length, data
		outdata = pack(">I1I4", 0, #outdata) .. outdata
		h2stream:respond(200, {
			['content-type'] = 'application/grpc',
		})
		h2stream:close(outdata, {
			['grpc-status'] = code.OK,
		})
	end
end

---@class silly.grpc.server
---@field fd integer
---@field transport silly.net.tcp|silly.net.tls
local server = {
	close = function(self)
		local fd = self.fd
		if fd then
			self.fd = nil
			return self.transport.close(fd)
		end
		return false, "closed"
	end
}
local server_mt = {
	__index = server,
}

---@param conf {
---	tls:boolean?,
---	addr:string,
---	ciphers:string?,
---	registrar:silly.grpc.registrar,
---	certs:{cert:string, cert_key:string}[],
---	alpnprotos:string[]|nil, backlog:integer|nil,
---}
---@return silly.grpc.server?, string? error
function M.listen(conf)
	local handler = dispatch(conf.registrar)
	local fd, transport = transport.listen {
		addr = conf.addr,
		tls = conf.tls,
		certs = conf.certs,
		alpnprotos = conf.alpnprotos,
		ciphers = conf.ciphers,
		handler = handler,
		forceh2 = true,
	}
	if not fd then
		return nil, transport
	end
	return setmetatable({
		fd = fd,
		transport = transport,
	}, server_mt), nil
end

local function find_service(proto, name)
	for _, v in pairs(proto['service']) do
		if v.name == name then
			return v
		end
	end
	return nil
end

local alpn_protos = {"h2"}

---@class silly.grpc.streaming
---@field h2stream silly.http.h2stream
---@field need_header boolean
---@field input_type string
---@field output_type string
local grpc_streaming = {}
local grpc_streaming_mt = { __index = grpc_streaming }

---@param self silly.grpc.streaming
function grpc_streaming:write(req)
	local h2stream = self.h2stream
	local reqdat = pb.encode(self.input_type, req)
	reqdat = pack(">I1I4", 0, #reqdat) .. reqdat
	return h2stream:write(reqdat)
end

---@param self silly.grpc.streaming
---@param timeout number?
function grpc_streaming:read(timeout)
	local h2stream = self.h2stream
	if self.need_header then
		local status, header = h2stream:readheader(timeout)
		if not status then
			return nil, header
		end
		self.need_header = false
	end
	local data, err = read_body(h2stream, false, timeout)
	if not data then
		return nil, err
	end
	local resp = pb.decode(self.output_type, data)
	if not resp then
		return nil, "decode error"
	end
	return resp, nil
end

function grpc_streaming:close()
	self.h2stream:close()
end

---@return silly.grpc.stream|nil, string|nil
local function stream_call(timeout, connect, method, fullname)
	return function()
		---@class silly.grpc.stream:silly.http.h2stream
		local h2stream, err = connect(fullname)
		if not h2stream then
			return nil, err
		end
		local streaming = setmetatable({
			h2stream = h2stream,
			input_type = method.input_type,
			output_type = method.output_type,
			need_header = true,
		}, grpc_streaming_mt)
		return streaming, nil
	end
end

---@return any|nil, string|nil
local function general_call(timeout, connect, method, fullname)
	local itype = method.input_type
	local otype = method.output_type
	return function(req)
		local h2stream<close>, err = connect(fullname)
		if not h2stream then
			return nil, err
		end
		local reqdat = pb.encode(itype, req)
		reqdat = pack(">I1I4", 0, #reqdat) .. reqdat
		local ok, err = h2stream:write(reqdat)
		if not ok then
			return nil, err
		end
		local status, header = h2stream:readheader(timeout)
		if not status then
			return nil, header
		end
		local body
		local grpc_message
		local grpc_status = header['grpc-status']
		if not grpc_status then	--normal header
			local reason
			body, reason = read_body(h2stream, false, timeout)
			if not body then
				return nil, reason
			end
			local trailer, reason = h2stream:readtrailer(timeout)
			if not trailer then
				return nil, reason
			end
			grpc_status = trailer['grpc-status']
			grpc_message = trailer['grpc-message']
		else
			grpc_message = header['grpc-message']
		end
		grpc_status = tonumber(grpc_status)
		if grpc_status ~= code.OK then
			return nil, format("code = %s desc = %s",
				codename[grpc_status], grpc_message)
		end
		local resp = pb.decode(otype, body)
		if not resp then
			return nil, "decode error"
		end
		return resp, nil
	end
end
---@param conf {
---	service:string,		--service name
---	endpoints:string[],	--grpc server address
---	proto:table,		--protobuf loaded
---	tls:boolean,		--use tls
---	timeout:number,		--timeout
---}
---@return silly.grpc.client|nil, string|nil
function M.newclient(conf)
	local service_name = conf.service
	local endpoints = {}
	for i, addr in pairs(conf.endpoints) do
		local host, port = addr:match("([^:]+):(%d+)")
		if not host or not port then
			return nil, "invalid addr"
		end
		endpoints[i] = {host, port}
	end
	local proto = conf.proto
	local scheme = conf.tls and "https" or "http"
	local package = proto.package
	local methods = {}
	local service = find_service(proto, service_name)
	if not service then
		return nil, "grpc: service not found"
	end
	for _, method in pairs(service['method']) do
		methods[method.name] = method
	end
	local timeout = conf.timeout
	local round_robin = 1
	local endpoint_count = #endpoints
	local connect = function(fullname)
		local endpoint = endpoints[round_robin]
		round_robin = (round_robin % endpoint_count) + 1
		local host, port = endpoint[1], endpoint[2]
		local stream, err = transport.connect(scheme, host, port, alpn_protos)
		if not stream then
			return nil, err
		end
		local ok, err = stream:request("POST", fullname, {
			["host"] = host,
			["te"] = "trailers",
			["content-type"] = "application/grpc",
		}, false)
		if not ok then
			return nil, err
		end
		return stream, nil
	end
	---@class silly.grpc.client
	---@field Watch? fun():silly.grpc.stream|nil, string|nil
	---@field [string] async fun(...):any|nil, string|nil
	local mt = {
		__index = function(t, k)
			local method = methods[k]
			local full_name = format("/%s.%s/%s", package, service_name, k)
			local cs, ss = method.client_streaming, method.server_streaming
			local callx
			if cs or ss then
				callx = stream_call
			else
				callx = general_call
			end
			local fn = callx(timeout, connect, method, full_name)
			t[k] = fn
			return fn
		end,
	}
	return setmetatable({}, mt), nil
end

return M

