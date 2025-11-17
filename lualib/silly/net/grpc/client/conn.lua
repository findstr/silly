local mutex = require "silly.sync.mutex"
local tcp = require "silly.net.tcp"
local tls = require "silly.net.tls"
local dns = require "silly.net.dns"
local h2 = require "silly.net.http.h2"

local ipairs = ipairs
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

---@class silly.net.grpc.client.endpoint
---@field addr string
---@field hostname string
---@field channel silly.net.http.h2.channel.client?

---@class silly.net.grpc.client.conn
---@field scheme string
---@field robin integer
---@field closed boolean
---@field [integer]silly.net.grpc.client.endpoint
local conn = {}

local connlock = mutex.new()

---@param self silly.net.grpc.client.conn
---@param endpoint silly.net.grpc.client.endpoint
---@return silly.net.http.h2.channel.client?, string?
local function newchannel(self, endpoint)
	local lock<close> = connlock:lock(endpoint)
	local ch = endpoint.channel
	if ch then
		if ch:isalive() then
			return ch, nil
		end
		ch:close()
	end
	local conn, err
	local scheme = self.scheme
	local addr = endpoint.addr
	local hostname = endpoint.hostname
	if scheme == "https" then
		conn, err = tls.connect(addr, {
			hostname = hostname,
			alpnprotos = ALPN_PROTOS
		})
	else
		conn, err = tcp.connect(addr)
	end
	if not conn then
		return nil, err
	end
	local ch, err = h2.newchannel(scheme, conn)
	if not ch then
		conn:close()
		return nil, err
	end
	endpoint.channel = ch
	return ch, nil
end

---@param self silly.net.grpc.client.conn
---@return silly.net.http.h2.stream?, string?
function conn.openstream(self)
	if self.closed then
		return nil, "closed"
	end
	local robin = self.robin
	self.robin = robin % #self + 1
	local e = self[robin]
	local ch = e.channel
	if not ch or not ch:isalive() then
		local err
		ch, err = newchannel(self, e)
		if not ch then
			return nil, err
		end
	end
	return ch:openstream()
end

---@param self silly.net.grpc.client.conn
---@return silly.net.http.h2.stream?, string?
function conn.close(self)
	if self.closed then
		return
	end
	self.closed = true
	for k, e in ipairs(self) do
		self[k] = nil
		local ch = e.channel
		if ch then
			ch:close()
			e.channel = nil
		end
	end
end

local client_mt = {__index = conn, __close = conn.close}

---@class silly.net.grpc.client.conn.opts
---@field targets string[]
---@field tls boolean?

---@param opts silly.net.grpc.client.conn.opts
---@return silly.net.grpc.client.conn?, string?
function conn.new(opts)
	local targets = opts.targets
	if #targets == 0 then
		return nil, "empty targets"
	end
	---@type silly.net.grpc.client.conn
	local c = {
		scheme = opts.tls and "https" or "http",
		robin = 1,
		closed = false,
	}
	for i = 1, #targets do
		local target = targets[i]
		local host, port = parse_target(target)
		if not host then
			return nil, port
		end
		local ip = dns.lookup(host, dns.A)
		if not ip then
			return nil, "dns lookup failed"
		end
		c[i] = {
			addr = format("%s:%s", ip, port),
			hostname = host,
			channel = nil,
		}
	end
	setmetatable(c, client_mt)
	return c, nil
end

return conn

