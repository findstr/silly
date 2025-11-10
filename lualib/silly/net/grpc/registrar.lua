local silly = require "silly"
local code = require "silly.net.grpc.code"
local helper = require "silly.net.grpc.helper"
local logger = require "silly.logger"

local assert = assert
local format = string.format
local setmetatable = setmetatable
local readbody = helper.readbody
local writebody = helper.writebody
local pcall = silly.pcall

---@class silly.net.grpc.error
---@field code integer
---@field message string

---@param ok boolean
---@param err string|silly.net.grpc.error|nil
---@return boolean, table?
local function make_trailer(ok, err)
	local success, trailer
	if not ok then
		trailer = {
			['grpc-status'] = code.Internal,
			['grpc-message'] = err,
		}
		success = false
	elseif err then
		trailer = {
			['grpc-status'] = err.code or code.Unknown,
			['grpc-message'] = err.message,
		}
		success = false
	else
		trailer = {
			['grpc-status'] = code.OK,
		}
		success = true
	end
	return success, trailer
end

---@param s silly.net.grpc.server.cstream | silly.net.grpc.server.bstream
---@return table?
local function stream_read(s)
	local h2stream = s.h2stream
	local req, err = readbody(h2stream, true, s.input_type)
	if req then
		return req
	end
	if h2stream:eof() then
		s.status = code.OK
	else
		s.status = code.Internal
	end
	s.message = err
end

---@param s silly.net.grpc.server.sstream | silly.net.grpc.server.bstream
---@param req table
---@return boolean, string? error
local function stream_write(s, req)
	return writebody(s.h2stream, s.output_type, req, false)
end

---@class silly.net.grpc.server.cstream
---@field h2stream silly.net.http.h2.stream
---@field input_type string
---@field status integer?
---@field message string?
local cs = {
	read = stream_read,
}
local cs_mt= { __index = cs }

---@class silly.net.grpc.server.sstream
---@field h2stream silly.net.http.h2.stream
---@field output_type string
---@field status integer?
---@field message string?
local ss = {
	write = stream_write,
}
local ss_mt= { __index = ss }

---@class silly.net.grpc.server.bstream
---@field h2stream silly.net.http.h2.stream
---@field input_type string
---@field output_type string
---@field status integer?
---@field message string?
local bs = {
	read = stream_read,
	write = stream_write,
}
local bs_mt= { __index = bs }

---@param fullname string
---@param method pb.method
---@param fn fun(input: table): table?, silly.net.grpc.error
local function unary(fullname, method, fn)
	local input_type = method.input_type
	local output_type = method.output_type
	---@param h2stream silly.net.http.h2.stream
	return function(h2stream)
		local req, err = readbody(h2stream, true, input_type)
		if not req then
			logger.warnf("[silly.net.grpc] %s read body failed: %s", fullname, err)
			return
		end
		local ok, output, err = pcall(fn, req)
		local success, trailer = make_trailer(ok, err)
		if success and output then
			writebody(h2stream, output_type, output, false)
		end
		h2stream:closewrite(nil, trailer)
	end
end

local function sstreaming(fullname, method, fn)
	local input_type = method.input_type
	local output_type = method.output_type
	---@param h2stream silly.net.http.h2.stream
	return function(h2stream)
		local req, err = readbody(h2stream, true, input_type)
		if not req then
			logger.warnf("[silly.net.grpc] %s read body failed: %s", fullname, err)
			return
		end
		---@type silly.net.grpc.server.sstream
		local s = {
			h2stream = h2stream,
			output_type = output_type,
		}
		setmetatable(s, ss_mt)
		local ok, output, err = pcall(fn, req, s)
		local success, trailer = make_trailer(ok, err)
		if success and output then
			writebody(h2stream, output_type, output, false)
		end
		h2stream:closewrite(nil, trailer)
	end
end

local function cstreaming(fullname, method, fn)
	local input_type = method.input_type
	local output_type = method.output_type
	---@param h2stream silly.net.http.h2.stream
	return function(h2stream)
		---@type silly.net.grpc.server.bstream
		local s = {
			h2stream = h2stream,
			input_type = input_type,
			output_type = output_type,
		}
		setmetatable(s, bs_mt)
		local ok, resp, err = pcall(fn, s)
		local success, trailer = make_trailer(ok, err)
		if success and resp then
			writebody(h2stream, output_type, resp, false)
		end
		h2stream:closewrite(nil, trailer)
	end
end

local function bstreaming(fullname, method, fn)
	local input_type = method.input_type
	local output_type = method.output_type
	---@param h2stream silly.net.http.h2.stream
	return function(h2stream)
		---@type silly.net.grpc.server.bstream
		local s = {
			h2stream = h2stream,
			input_type = input_type,
			output_type = output_type,
		}
		setmetatable(s, bs_mt)
		local ok, err = pcall(fn, s)
		local _, trailer = make_trailer(ok, err)
		h2stream:closewrite(nil, trailer)
	end
end


---@param fullname string
---@param method pb.method
---@param fn function
local function wrap(fullname, method, fn)
	local ss = method.server_streaming
	local cs = method.client_streaming
	if ss and cs then
		return bstreaming(fullname, method, fn)
	elseif ss then
		return sstreaming(fullname, method, fn)
	elseif cs then
		return cstreaming(fullname, method, fn)
	else
		return unary(fullname, method, fn)
	end
end

---@class silly.net.grpc.registrar
---@field handlers table<string, function>
local M = {}


M.__index = M

---@return silly.net.grpc.registrar
function M.new()
	---@type silly.net.grpc.registrar
	local r = {
		handlers = {},
	}
	return setmetatable(r, M)
end

---@param self silly.net.grpc.registrar
---@param proto pb.proto
---@param service_name string
---@param service_handlers table<string, function>
function M:register(proto, service_name, service_handlers)
	local service
	for _, v in pairs(proto.service) do
		if v.name == service_name then
			service = v
			break
		end
	end
	if not service then
		error("service not found: " .. service_name)
	end

	local package = proto.package
	local handlers = self.handlers
	for _, m in pairs(service.method) do
		local name = m.name
		local fullname = format("/%s.%s/%s", package, service_name, name)
		local fn = assert(service_handlers[name], name)
		handlers[fullname] = wrap(fullname, m, fn)
	end
end

return M
