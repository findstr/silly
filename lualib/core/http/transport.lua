local core = require "core"
local tcp = require "core.net.tcp"
local tls = require "core.net.tls"
local dns = require "core.dns"
local mutex = require "core.sync.mutex"
local h1 = require "core.http.h1stream"
local h2 = require "core.http.h2stream"
local assert = assert
local pairs = pairs
local format = string.format
local setmetatable = setmetatable
local socket_mutex = mutex:new()

local M = {}

local transport_layers = {
	["http"] = tcp,
	["https"] = tls,
}

---@type table<string, core.http.h2stream.channel>
local h2_pool = setmetatable({}, {__gc = function(t)
	for k, s in pairs(t) do
		t[k] = nil
		s:close()
	end
end})

local function check_alive_timer(_)
	for k, s in pairs(h2_pool) do
		if not s.transport.isalive(s.fd) then
			h2_pool[k] = nil
		end
	end
	core.timeout(1000, check_alive_timer)
end

core.timeout(1000, check_alive_timer)

---@param scheme string
---@param host string
---@param port string
---@param alpnprotos core.net.tls.alpn_proto[]
---@return integer?, core.net.tcp|core.net.tls|string|nil
local function connect_exec(scheme, host, port, alpnprotos)
	local ip = dns.lookup(host, dns.A)
	if not ip then
		return nil, "dns lookup failed"
	end
	assert(ip, host)
	local transport = transport_layers[scheme]
	local addr = format("%s:%s", ip, port)
	local fd, err = transport.connect(addr, nil, host, alpnprotos)
	if not fd then
		return nil, err
	end
	return fd, transport
end

---@param scheme string
---@param host string
---@param port string
---@param alpnprotos core.net.tls.alpn_proto[]
---@return core.http.h1stream|core.http.h2stream|nil, string? error
function M.connect(scheme, host, port, alpnprotos)
	local aln_count = alpnprotos and #alpnprotos or 0
	if aln_count == 1 and alpnprotos[1] == "http/1.1" then -- force http1.x protocol, don't reuse connection
		local fd, transport = connect_exec(scheme, host, port, alpnprotos)
		if not fd then
			return nil, transport
		end
		return h1.new(scheme, fd, transport), nil
	end
	-- try use h2 connection
	local tag = format("%s:%s:%s", scheme, host, port)
	local channel = h2_pool[tag]
	if channel and channel.transport.isalive(channel.fd) then
		return channel:open_stream(), nil
	end
	local lock<close> = socket_mutex:lock(tag)
	-- double check
	local channel = h2_pool[tag]
	if channel and channel.transport.isalive(channel.fd) then
		return channel:open_stream(), nil
	end
	local fd, transport = connect_exec(scheme, host, port, alpnprotos)
	if not fd then
		return nil, transport
	end
	local is_h2 = aln_count == 1 and alpnprotos[1] == "h2"
	if not is_h2 then
		---@cast transport core.net.tls|core.net.tcp
		local alpnproto = transport.alpnproto
		is_h2 = alpnproto and alpnproto(fd) == "h2"
	end
	if is_h2 then
		local channel, err = h2.newchannel(scheme, fd, transport)
		if not channel then
			return nil, err
		end
		h2_pool[tag] = channel
		return channel:open_stream(), nil
	end
	return h1.new(scheme, fd, transport), nil
end

---@class core.http.transport.listen.conf
---@field handler fun(sock: any, stream: any)
---@field addr string
---@field tls boolean?
---@field certs table<number, {
---		cert:string,
---		cert_key:string,
---	}>?,
---@field alpnprotos string[]?
---@field forceh2 boolean?
---}

---@param conf core.http.transport.listen.conf
---@return integer?, core.net.tcp|core.net.tls|string
function M.listen(conf)
	local handler = function(fd, addr)
		local transport
		local is_h2 = conf.forceh2
		if conf.tls then
			transport = transport_layers["https"]
		else
			transport = transport_layers["http"]
		end
		if not is_h2 then
			local alpnproto = transport.alpnproto
			is_h2 = alpnproto and alpnproto(fd) == "h2"
		end
		local httpd = is_h2 and h2.httpd or h1.httpd
		httpd(conf.handler, fd, transport, addr)
	end

	local fd, transport, err
	local addr = conf.addr
	if not conf.tls then
		transport = tcp
		fd, err = tcp.listen(addr, handler)
	else
		transport = tls
		fd, err = tls.listen {
			addr = addr,
			certs = conf.certs,
			alpnprotos = conf.alpnprotos,
			disp = handler,
		}
	end
	if not fd then
		return nil, err
	end
	return fd, transport
end

function M.channels()
	return h2_pool
end

return M
