local tcp = require "core.net.tcp"
local tls = require "core.net.tls"
local h2 = require "core.http.h2stream"
local code = require "core.grpc.code"
local codename = require "core.grpc.codename"
local transport = require "core.http.transport"
local pb = require "pb"
local pack = string.pack
local format = string.format
local tonumber = tonumber
local setmetatable = setmetatable
local M = {}

local HDR_SIZE<const> = 5
local MAX_LEN<const> = 4*1024*1024

local function dispatch(registrar)
	local input_name = registrar.input_name
	local output_name = registrar.output_name
	local handlers = registrar.handlers
	--use closure for less hash
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
		local data = ""
		--read header
		for i = 1, 4 do
			local d, _ = stream:read()
			if not d or d == "" then
				stream:close()
				return
			end
			data = data .. d
			if #data >= HDR_SIZE then
				break
			end
		end
		local _, len = string.unpack(">I1I4", data)
		if len > MAX_LEN then
			stream:respond(200, {
				['content-type'] = 'application/grpc',
				['grpc-status'] = code.ResourceExhausted,
				['grpc-message'] = format("grpc: received message larger than max (%s vs. %s)", len, MAX_LEN),
			}, true)
			return
		end
		if #data < (len + HDR_SIZE) then
			local d, reason = stream:readall()
			if not d then
				stream:respond(200, {
					['content-type'] = 'application/grpc',
					['grpc-status'] = code.Unknown,
					['grpc-message'] = reason,
				}, true)
				return
			end
			data = data .. d
		end
		local input = pb.decode(itype, data:sub(HDR_SIZE+1))
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

---@param conf {
---	tls:boolean?,
---	addr:string,
---	ciphers:string?,
---	registrar:core.grpc.registrar,
---	certs:{cert:string, cert_key:string}[],
---	alpnprotos:string[]|nil, backlog:integer|nil,
---}
function M.listen(conf)
	local scheme_mt, fd
	local http2d = h2.httpd(dispatch(conf.registrar))
	local scheme_io = transport.scheme_io
	if conf.tls then
		scheme_mt = scheme_io["https"]
		fd = tls.listen {
			addr = conf.addr,
			certs = conf.certs,
			alpnprotos = conf.alpnprotos,
			ciphers = conf.ciphers,
			disp = function(fd, addr)
				local socket = setmetatable({fd}, scheme_mt)
				http2d(socket, addr)
			end,
		}
	else
		scheme_mt = scheme_io["http"]
		fd = tcp.listen(conf.addr, function(fd, addr)
			local socket = setmetatable({fd}, scheme_mt)
			http2d(socket, addr)
		end)
	end
	return setmetatable({fd}, scheme_mt)
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
		--TODO: support multi frame
		local body, reason = read(stream)
		if not body then
			return nil, reason
		end
		if #body < HDR_SIZE then
			return nil, "grpc: invalid body"
		end
		local resp = pb.decode(otype, body:sub(HDR_SIZE+1))
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
			body, reason = stream:readall(timeout)
			if not body then
				return nil, reason
			end
			if #body < HDR_SIZE then
				return nil, "grpc: invalid body"
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
		local resp = pb.decode(otype, body:sub(HDR_SIZE+1))
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
		local socket, err = transport.connect(scheme, host, port, alpn_protos, true)
		if not socket then
			return nil, err
		end
		local stream, err = h2.new(scheme, socket)
		if not stream then
			return nil, err
		end
		local ok, err = stream:request("POST", fullname, {
			[":authority"] = host,
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

