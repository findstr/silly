local time = require "silly.time"
local code = require "silly.net.grpc.code"
local helper = require "silly.net.grpc.helper"
local codename = require "silly.net.grpc.codename"

local tonumber = tonumber
local setmetatable = setmetatable

local format = string.format
local writebody = helper.writebody
local readbody = helper.readbody

---@type table<integer, silly.net.http.h2.stream>
local waiting_stream = {}

---@param session integer
local function timer_stream(session)
	local s = waiting_stream[session]
	if not s then
		return
	end
	waiting_stream[session] = nil
	s:close()
end

---@class silly.net.grpc.client.service.meta
---@field package _package string
---@field package _name string
---@field package _methods table<string, pb.method>
---@field [string] fun(self:silly.net.grpc.client.service, req:table, timeout:integer?):table?, string? error
---@field [string] fun(self:silly.net.grpc.client.service, req:table, timeout:integer?):silly.net.grpc.client.sstream?, string? error
---@field [string] fun(self:silly.net.grpc.client.service):silly.net.grpc.client.cstream?, string? error
---@field [string] fun(self:silly.net.grpc.client.service):silly.net.grpc.client.bstream?, string? error

---@class silly.net.grpc.client.service : silly.net.grpc.client.service.meta
---@field _conn silly.net.grpc.client.conn


---@param h2stream silly.net.http.h2.stream
---@param err string?
---@return integer, string?
local function check_trailer(h2stream, err)
	local status, message
	local trailer = h2stream.trailer
	local grpc_status = trailer['grpc-status']
	if grpc_status then
		status = tonumber(grpc_status)
		message = trailer['grpc-message'] or codename[status] or "Unknown"
	else
		status = code.Unknown
		message = err or "no status in trailer"
	end
	return status, message
end


---@param s silly.net.grpc.client.cstream
local function stream_readfinal(s)
	local h2stream = s.h2stream
	local obj, err = readbody(h2stream, false, s.output_type)
	h2stream:readall() -- drain all data
	s.status, s.message = check_trailer(h2stream, err)
	return obj
end

---@param s silly.net.grpc.client.sstream | silly.net.grpc.client.bstream
---@param data string?
local function stream_closewrite(s, data)
	local h2stream = s.h2stream
	return h2stream:closewrite(data)
end

---@param s silly.net.grpc.client.sstream | silly.net.grpc.client.bstream
---@return table?
local function stream_read(s)
	local h2stream = s.h2stream
	local obj, err = readbody(h2stream, false, s.output_type)
	if obj then
		return obj
	end
	s.status, s.message = check_trailer(h2stream, err)
	return nil
end

---@param s silly.net.grpc.client.cstream | silly.net.grpc.client.bstream
---@param req table
local function stream_write(s, req)
	return writebody(s.h2stream, s.input_type, req, false)
end

---@param s silly.net.grpc.client.cstream | silly.net.grpc.client.bstream | silly.net.grpc.client.sstream
local function stream_close(s)
	s.h2stream:close()
end

---@class silly.net.grpc.client.cstream
---@field package h2stream silly.net.http.h2.stream
---@field package input_type string
---@field package output_type string
---@field status integer?
---@field message string?
local cs = {
	write = stream_write,
	closewrite = stream_closewrite,
	read = stream_readfinal,
	close = stream_close,
}
local cs_mt= { __index = cs, __close = stream_close }

---@class silly.net.grpc.client.sstream
---@field package h2stream silly.net.http.h2.stream
---@field package output_type string
---@field status integer?
---@field message string?
local ss = {
	read = stream_read,
	close = stream_close,
}
local ss_mt= { __index = ss, __close = stream_close }

---@class silly.net.grpc.client.bstream
---@field package h2stream silly.net.http.h2.stream
---@field package input_type string
---@field package output_type string
---@field status integer?
---@field message string?
local bs = {
	read = stream_read,
	write = stream_write,
	closewrite = stream_closewrite,
	close = stream_close,
}
local bs_mt= { __index = bs, __close = stream_close }

local function unary(method, fullname)
	local itype = method.input_type
	local otype = method.output_type
	---@param self silly.net.grpc.client.service
	---@param req table
	---@param timeout integer?
	---@return table?, string? error
	return function(self, req, timeout)
		local h2stream<close>, err = self._conn:openstream()
		if not h2stream then
			return nil, err
		end
		local timer
		if timeout then
			timer = time.after(timeout, timer_stream)
			waiting_stream[timer] = h2stream
		end
		h2stream:request("POST", fullname, {
			["content-type"] = "application/grpc",
		})
		writebody(h2stream, itype, req, true)
		local resp, err = readbody(h2stream, false, otype)
		h2stream:readall() -- drain all data
		if timer then
			if not waiting_stream[timer] then
				return nil, "grpc: deadline exceeded"
			end
			waiting_stream[timer] = nil
			time.cancel(timer)
		end
		local trailer = h2stream.trailer
		local grpc_status = trailer['grpc-status'] or h2stream.header['grpc-status']
		if not grpc_status then
			return nil, err or "grpc: no status in trailer"
		end
		local n = tonumber(grpc_status)
		if n ~= code.OK then
			return nil, format("code = %s desc = %s",
				codename[n], trailer['grpc-message'])
		end
		return resp, err
	end
end

local function sstreaming(method, fullname)
	local itype = method.input_type
	---@param self silly.net.grpc.client.service
	---@param req table
	---@param timeout integer?
	---@return silly.net.grpc.client.sstream?, string? error
	return function(self, req, timeout)
		local h2stream, err = self._conn:openstream()
		if not h2stream then
			return nil, err
		end
		local timer
		if timeout then
			timer = time.after(timeout, timer_stream)
			waiting_stream[timer] = h2stream
		end
		h2stream:request("POST", fullname, {
			["content-type"] = "application/grpc",
		})
		writebody(h2stream, itype, req, true)
		if timer then
			if not waiting_stream[timer] then
				return nil, "grpc: deadline exceeded"
			end
			waiting_stream[timer] = nil
			time.cancel(timer)
		end
		---@type silly.net.grpc.client.sstream
		local s = {
			h2stream = h2stream,
			output_type = method.output_type,
		}
		setmetatable(s, ss_mt)
		return s, nil
	end
end

local function cstreaming(method, fullname)
	---@param self silly.net.grpc.client.service
	---@return silly.net.grpc.client.cstream?, string? error
	return function(self)
		local h2stream, err = self._conn:openstream()
		if not h2stream then
			return nil, err
		end
		h2stream:request("POST", fullname, {
			["content-type"] = "application/grpc",
		})
		---@type silly.net.grpc.client.cstream
		local s = {
			h2stream = h2stream,
			input_type = method.input_type,
			output_type = method.output_type,
		}
		setmetatable(s, cs_mt)
		return s, nil
	end
end

local function bstreaming(method, fullname)
	---@param self silly.net.grpc.client.service
	---@return silly.net.grpc.client.bstream?, string? error
	return function(self)
		local h2stream, err = self._conn:openstream()
		if not h2stream then
			return nil, err
		end
		h2stream:request("POST", fullname, {
			["content-type"] = "application/grpc",
		})
		---@type silly.net.grpc.client.bstream
		local s = {
			h2stream = h2stream,
			input_type = method.input_type,
			output_type = method.output_type,
		}
		setmetatable(s, bs_mt)
		return s, nil
	end
end

local meta_mt = { __index = function(self, k)
	local package = self._package
	local method = self._methods[k]
	if not method then
		return nil
	end
	local ss = method.server_streaming
	local cs = method.client_streaming
	local full_name = format("/%s.%s/%s", package, self._name, k)
	local fn
	if cs and ss then
		fn = bstreaming(method, full_name)
	elseif ss then
		fn = sstreaming(method, full_name)
	elseif cs then
		fn = cstreaming(method, full_name)
	else
		fn = unary(method, full_name)
	end
	self[k] = fn
	return fn
end}

local mt_cache = {}
local function newmt(proto, service_name)
	local service
	for _, s in pairs(proto.service) do
		if s.name == service_name then
			service = s
		end
	end
	if not service then
		return nil, "service not found"
	end
	local mt = mt_cache[service]
	if mt then
		return mt
	end
	local methods = {}
	for _, method in pairs(service.method) do
		methods[method.name] = method
	end
	---@type silly.net.grpc.client.service.meta
	local srv = setmetatable({
		_package = proto.package,
		_name = service.name,
		_methods = methods
	}, meta_mt)
	mt = { __index = srv }
	mt_cache[service] = mt
	return mt
end

---@param conn silly.net.grpc.client.conn
---@param proto pb.proto
---@param service_name string
---@return silly.net.grpc.client.service?, string? error
local function new(conn, proto, service_name)
	local mt, err = newmt(proto, service_name)
	if not mt then
		return nil, err
	end
	---@type silly.net.grpc.client.service
	local s = setmetatable({
		_conn = conn,
	}, mt)
	return s, nil
end

return new
