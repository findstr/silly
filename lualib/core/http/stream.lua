local tcp = require "core.net.tcp"
local tls = require "core.net.tls"
local dns = require "core.dns"
local mutex = require "core.sync.mutex"
local h1 = require "core.http.h1stream"
local h2 = require "core.http.h2stream"
local format = string.format

local function wrap_one(func)
	return function(self, x)
		local fd = self[1]
		if fd then
			return func(fd, x)
		else
			return false
		end
	end
end

local function wrap_close(func)
	return function(self)
		local ok = false
		local fd = self[1]
		if fd then
			ok = func(fd)
			self[1] = nil
		end
		return ok
	end
end

local function gc(self)
	self:close()
end
local tls_mt = {
	close = wrap_close(tls.close),
	read = wrap_one(tls.read),
	write = wrap_one(tls.write),
	readline = wrap_one(tls.readline),
	alpnproto = wrap_one(tls.alpnproto),
	__gc = gc,
	__index = nil,
}

local tcp_mt = {
	alpn = function() return nil end,
	close = wrap_close(tcp.close),
	read = wrap_one(tcp.read),
	write = wrap_one(tcp.write),
	readline = wrap_one(tcp.readline),
	alpnproto = function() return nil end,
	__gc = gc,
	__index = nil,
}

tls_mt.__index = tls_mt
tcp_mt.__index = tcp_mt

local tcp_connect = tcp.connect
local tls_connect = tls.connect

local scheme_io = {
	["https"] = tls_mt,
	["wss"] = tls_mt,
	["http"] = tcp_mt,
	["ws"] = tcp_mt,
}

local scheme_connect = {
	["http"] = tcp_connect,
	["ws"] = tcp_connect,
	["https"] = tls_connect,
	["wss"] = tls_connect,
}

local setmetatable = setmetatable

local connect_mutex = mutex.new()
local function connect(scheme, host, port, alpnprotos)
	local tag = format("%s:%s", host, port)
	local stream, _ = h2.new(tag, nil)
	if stream then
		return stream
	end
	local lock<close> = connect_mutex:lock(tag)
	--double check
	local stream, _ = h2.new(tag, nil)
	if stream then
		return stream
	end
	local ip = dns.lookup(host, dns.A)
	assert(ip, host)
	local addr = format("%s:%s", ip, port)
	local connect_fn = scheme_connect[scheme]
	local fd, err = connect_fn(addr, nil, host, alpnprotos)
	if not fd then
		return nil, err
	end
	local sock = setmetatable({fd}, scheme_io[scheme])
	if sock:alpnproto() == "h2" then --http2
		stream, err = h2.new(tag, sock)
	else
		stream, err = h1.new(sock)
	end
	return stream, err
end

local function httpd(scheme, handler)
	local http2d
	local http1d = h1.httpd(handler)
	if scheme == "https" then
		http2d = h2.httpd(handler)
	end
	local scheme_mt = scheme_io[scheme]
	return function(fd, addr)
		local socket = setmetatable({fd}, scheme_mt)
		if socket:alpnproto() == "h2" then
			http2d(socket, addr)
		else
			http1d(socket, addr)
		end
	end
end

local M = {
	connect = connect,
	httpd = httpd,
}

return M
