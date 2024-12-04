local core = require "core"
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
	isalive = wrap_one(tls.isalive),
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
	isalive = wrap_one(tls.isalive),
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


local socket_mutex = mutex:new()
local socket_pool = setmetatable({}, {__gc = function(t)
	for k, s in pairs(t) do
		t[k] = nil
		s:close()
	end
end})

local function check_alive_timer(_)
	for k, s in pairs(socket_pool) do
		if not s:isalive() then
			socket_pool[k] = nil
		end
	end
	core.timeout(1000, check_alive_timer)
end

core.timeout(1000, check_alive_timer)

local function connect(scheme, host, port, alpnprotos, reuse)
	local tag, lock
	if scheme == "https" or reuse then
		--https try reuse connects
		tag = format("%s:%s", host, port)
		local socket = socket_pool[tag]
		if socket and socket:isalive() then
			return socket
		end
		lock = socket_mutex:lock(tag)
	end
	local ip = dns.lookup(host, dns.A)
	if not ip then
		if lock then
			lock:unlock()
		end
		return nil, "dns lookup failed"
	end
	assert(ip, host)
	local addr = format("%s:%s", ip, port)
	local connect_fn = scheme_connect[scheme]
	local fd, err = connect_fn(addr, nil, host, alpnprotos)
	if not fd then
		if lock then
			lock:unlock()
		end
		return nil, err
	end
	local socket = setmetatable({fd}, scheme_io[scheme])
	if lock then
		socket_pool[tag] = socket
		lock:unlock()
	end
	return socket, "ok"
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
	scheme_io = scheme_io,
	connect = connect,
	httpd = httpd,
}

return M
