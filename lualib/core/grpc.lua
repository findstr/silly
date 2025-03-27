local logger = require "core.logger"
local code = require "core.grpc.code"
local codename = require "core.grpc.codename"
local transport = require "core.http.transport"
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

---@param stream core.http.h2stream
---@param read fun(stream:core.http.h2stream, timeout:number):string?, string?
---@param is_server boolean
---@param timeout number
---@return string?, string? error
local function read_body(stream, read, is_server, timeout)
	local data = ""
	--read header
	for i = 1, HDR_SIZE do
		local d, err = read(stream, timeout)
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
		stream:respond(200, {
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
			local d, err = read(stream, timeout)
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
	---@param stream core.http.h2stream
	return function(stream)
		local status, header = stream:readheader()
		if status ~= 200 then
			stream:respond(200, {
				['content-type'] = 'application/grpc',
				['grpc-status'] = code.Unknown,
				['grpc-message'] = "grpc: invalid header"
			}, true)
			return
		end
		local method = header[':path']
		local itype = input_name[method]
		local otype = output_name[method]
		local data, err = read_body(stream, stream.read, true, nil)
		if not data then
			stream:close()
			logger.warn("[core.grpc] read body failed", err)
			return
		end
		local input = pb.decode(itype, data)
		local output = assert(handlers[method], method)(input)
		local outdata = pb.encode(otype, output)
		--payloadFormat, length, data
		outdata = pack(">I1I4", 0, #outdata) .. outdata
		stream:respond(200, {
			['content-type'] = 'application/grpc',
		})
		stream:close(outdata, {
			['grpc-status'] = code.OK,
		})
	end
end

---@class core.grpc.server
---@field fd integer
---@field transport core.net.tcp|core.net.tls
local server = {
	close = function(self)
		local fd = self.fd
		if fd then
			self.transport.close(fd)
			self.fd = nil
		end
	end
}
local server_mt = {
	__index = server,
}

---@param conf {
---	tls:boolean?,
---	addr:string,
---	ciphers:string?,
---	registrar:core.grpc.registrar,
---	certs:{cert:string, cert_key:string}[],
---	alpnprotos:string[]|nil, backlog:integer|nil,
---}
---@return core.grpc.server?, string? error
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

---@param stream core.http.h2stream
local function streaming_write_wrapper(stream, method, timeout)
	local itype = method.input_type
	local write = stream.write
	---@param stream core.http.h2stream
	---@param req table
	return function(stream, req)
		local reqdat = pb.encode(itype, req)
		reqdat = pack(">I1I4", 0, #reqdat) .. reqdat
		return write(stream, reqdat)
	end
end

---@param stream core.http.h2stream
local function streaming_read_wrapper(stream, method, timeout)
	local need_header = true
	local read = stream.read
	local otype = method.output_type
	return function(steam)
		if need_header then
			local status, header = stream:readheader(timeout)
			if not status then
				return nil, header
			end
			need_header = false
		end
		local data, err = read_body(stream, read, false, timeout)
		if not data then
			return nil, err
		end
		local resp = pb.decode(otype, data)
		if not resp then
			return nil, "decode error"
		end
		return resp, nil
	end
end

---@return core.grpc.stream|nil, string|nil
local function stream_call(timeout, connect, method, fullname)
	return function()
		---@class core.grpc.stream:core.http.h2stream
		local stream, err = connect(fullname)
		if not stream then
			return nil, err
		end
		stream.write = streaming_write_wrapper(stream, method, timeout)
		stream.read = streaming_read_wrapper(stream, method, timeout)
		return stream, nil
	end
end

---@return any|nil, string|nil
local function general_call(timeout, connect, method, fullname)
	local itype = method.input_type
	local otype = method.output_type
	return function(req)
		local stream<close>, err = connect(fullname)
		if not stream then
			return nil, err
		end
		local reqdat = pb.encode(itype, req)
		reqdat = pack(">I1I4", 0, #reqdat) .. reqdat
		local ok, err = stream:write(reqdat)
		if not ok then
			return nil, err
		end
		local status, header = stream:readheader(timeout)
		if not status then
			return nil, header
		end
		local body
		local grpc_message
		local grpc_status = header['grpc-status']
		if not grpc_status then	--normal header
			local reason
			body, reason = read_body(stream, stream.read, false, timeout)
			if not body then
				return nil, reason
			end
			local trailer, reason = stream:readtrailer(timeout)
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
---@return core.grpc.client|nil, string|nil
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
	---@class core.grpc.client
	---@field Watch? fun():core.grpc.stream|nil, string|nil
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

