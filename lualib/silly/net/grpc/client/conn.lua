local mutex = require "silly.sync.mutex"
local tcp = require "silly.net.tcp"
local tls = require "silly.net.tls"
local dns = require "silly.net.dns"
local h2 = require "silly.net.http.h2"


local setmetatable = setmetatable
local format = string.format

local ALPN_PROTOS<const> = {"h2"}

local function parse_target(target)
	local scheme, rest = target:match("^([%w]+):///?(.*)")
	if not scheme then
		scheme = "passthrough"
		rest = target
	end
	if scheme == "dns" or scheme == "passthrough" then
		local host, port = rest:match("([^:]+):(%d+)")
		if not host or not port then
			return nil, "invalid target: " .. target
		end
		return host, port
	end
	return nil, "unsupported scheme: " .. scheme
end

---@class silly.net.grpc.client.conn
---@field scheme string
---@field addr string
---@field host string
---@field channel silly.net.http.h2.channel.client?
local conn = {}
local client_mt = {__index = conn}

local connlock = mutex.new()

---@param client silly.net.grpc.client.conn
---@return silly.net.http.h2.channel.client?, string?
local function newchannel(client)
	local lock<close> = connlock:lock(client)
	local ch = client.channel
	if ch and ch:isalive() then
		return ch, nil
	end
	local conn, err
	local scheme = client.scheme
	local addr = client.addr
	local host = client.host
	if scheme == "https" then
		conn, err = tls.connect(addr, {
			hostname = host,
			alpnprotos = ALPN_PROTOS
		})
	else
		conn, err = tcp.connect(addr)
	end
	if not conn then
		return nil, err
	end
	local ch, err = h2.newchannel(scheme, conn, addr)
	if not ch then
		conn:close()
		return nil, err
	end
	client.channel = ch
	return ch, nil
end

---@param self silly.net.grpc.client.conn
---@return silly.net.http.h2.stream?, string?
function conn.openstream(self)
	local ch = self.channel
	if not ch or not ch:isalive() then
		local err
		ch, err = newchannel(self)
		if not ch then
			return nil, err
		end
	end
	return ch:openstream()
end

---@class silly.net.grpc.client.conn.opts
---@field target string
---@field tls boolean?

---@param opts silly.net.grpc.client.conn.opts
---@return silly.net.grpc.client.conn?, string?
function conn.new(opts)
	local host, port = parse_target(opts.target)
	if not host then
		return nil, port
	end
	local ip = dns.lookup(host, dns.A)
	if not ip then
		return nil, "dns lookup failed"
	end
	host = ip
	local addr = format("%s:%s", host, port)
	---@type silly.net.grpc.client.conn
	local c = {
		scheme = opts.tls and "https" or "http",
		addr = addr,
		host = host,
	}
	setmetatable(c, client_mt)
	return c, nil
end

return conn

