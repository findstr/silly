local time = require "silly.time"
local tcp = require "silly.net.tcp"
local tls = require "silly.net.tls"
local dns = require "silly.net.dns"
local h1 = require "silly.net.http.h1"
local h2 = require "silly.net.http.h2"
local helper = require "silly.net.http.helper"
local gzip = require "silly.compress.gzip"
local parseurl = helper.parseurl

local assert = assert
local pairs = pairs
local setmetatable = setmetatable
local format = string.format
local tremove = table.remove
local lower = string.lower

---@class silly.net.http.client.pool.h1
---@field key string
---@field conn silly.net.tcp.conn|silly.net.tls.conn
---@field lastfree integer  -- timestamp
---@field client silly.net.http.client

---@class silly.net.http.client.pool.h2
---@field key string
---@field channel silly.net.http.h2.channel.client
---@field lastfree integer   -- timestamp
---@field client silly.net.http.client

---@class silly.net.http.client
---@field max_idle_per_host integer
---@field idle_timeout integer
---@field alpnprotos silly.net.tls.alpn_proto[]
---@field h1pool table<string, silly.net.http.client.pool.h1[]>
---@field h2pool table<string, silly.net.http.client.pool.h2[]>
local M = {}
local mt = {__index = M}

 ---@type table<silly.net.tcp.conn|silly.net.tls.conn, silly.net.http.client.pool.h1>
local h1using = {}

local default_opts = {
	max_idle_per_host = 10,
	idle_timeout = 30000,
	read_timeout = 5000,
	alpnprotos = {"http/1.1", "h2"}
}

local pool_mt = {__index = function(t, k)
	local entries = {}
	t[k] = entries
	return entries
end}

---@param conn silly.net.tcp.conn|silly.net.tls.conn
---@param broken boolean
local function releaseh1(conn, broken)
	local entry = h1using[conn]
	if not entry then
		return
	end
	h1using[conn] = nil
	if broken or not conn:isalive() then
		conn:close()
		return
	end
	local client = entry.client
	local entries = client.h1pool[entry.key]
	if #entries < client.max_idle_per_host then
		entry.lastfree = time.now()
		entries[#entries + 1] = entry
	else
		conn:close()
	end
end

---@param c silly.net.http.client
local function check_alive_timer(c)
	time.after(c.idle_timeout / 2, check_alive_timer, c)
	local now = time.now()
	local idle_timeout = c.idle_timeout
	local max_idle_per_host = c.max_idle_per_host

	-- Check h1 pool
	for k, entries in pairs(c.h1pool) do
		local wi = 0
		for i = 1, #entries do
			local entry = entries[i]
			if entry.lastfree + idle_timeout >= now and entry.conn:isalive() then
				wi = wi + 1
				entries[wi] = entry
			else
				entry.conn:close()
			end
		end
		for i = wi + 1, #entries do
			entries[i] = nil
		end
		if wi == 0 then
			c.h1pool[k] = nil
		end
	end

	-- Check h2 pool
	for k, entries in pairs(c.h2pool) do
		local wi = 0
		local idle_count = 0
		for i = 1, #entries do
			local entry = entries[i]
			local channel = entry.channel
			if not channel:isidle() then
				wi = wi + 1
				entry.lastfree = now
				entries[wi] = entry
			elseif entry.lastfree + idle_timeout >= now and idle_count < max_idle_per_host then
				wi = wi + 1
				idle_count = idle_count + 1
				entries[wi] = entry
			else
				channel:close()
			end
		end
		for i = wi + 1, #entries do
			entries[i] = nil
		end
		if wi == 0 then
			c.h2pool[k] = nil
		end
	end
end

local function find_conn(client, key, scheme)
	-- find h2 stream first
	local h2entries = client.h2pool[key]
	for i = #h2entries, 1, -1 do
		local entry = h2entries[i]
		local channel = entry.channel
		if channel:isalive() and not channel:isfull() then
			entry.lastfree = time.now()
			return channel:openstream()
		end
	end
	local h1entries = client.h1pool[key]
	for i = #h1entries, 1, -1 do
		local entry = h1entries[i]
		if entry.conn:isalive() then
			h1using[entry.conn] = entry
			tremove(h1entries, i)
			return h1.newstream(scheme, entry.conn, releaseh1)
		end
	end
	return nil
end

---@class silly.net.http.client.opts
---@field max_idle_per_host integer?  -- Maximum idle connections per host (default: 10)
---@field idle_timeout integer?       -- Idle connection timeout in ms (default: 30000)
---@field read_timeout integer?      -- Read timeout in ms (default: 5000)
---@field alpnprotos silly.net.tls.alpn_proto[]? -- ALPN protocols (default: {"http/1.1", "h2"})

---@param opts silly.net.http.client.opts?
---@return silly.net.http.client
function M.new(opts)
	---@type silly.net.http.client
	local c = {
		max_idle_per_host = opts and opts.max_idle_per_host or default_opts.max_idle_per_host,
		idle_timeout = opts and opts.idle_timeout or default_opts.idle_timeout,
		readtimeout = opts and opts.read_timeout or default_opts.read_timeout,
		alpnprotos = opts and opts.alpnprotos or default_opts.alpnprotos,
		h1pool = setmetatable({}, pool_mt),
		h2pool = setmetatable({}, pool_mt),
	}
	setmetatable(c, mt)
	time.after(c.idle_timeout / 2, check_alive_timer, c)
	return c
end

---@param client silly.net.http.client
---@param scheme string
---@param host string
---@param port string
---@return silly.net.http.h1.stream.client|silly.net.http.h2.stream|nil, string? error
local function connect(client, scheme, host, port)
	local key = format("%s:%s:%s", scheme, host, port)
	local stream = find_conn(client, key, scheme)
	if stream then
		return stream, nil
	end

	local ip = dns.lookup(host, dns.A)
	if not ip then
		return nil, "dns lookup failed"
	end
	assert(ip, host)
	local addr = format("%s:%s", ip, port)
	local conn, err
	if scheme == "https" then
		conn, err = tls.connect(addr, {
			hostname = host,
			alpnprotos = client.alpnprotos
		})
	else
		conn, err = tcp.connect(addr)
	end
	if not conn then
		return nil, err
	end
	local alpnproto = conn.alpnproto
	if alpnproto and alpnproto(conn) == "h2" then
		local channel, err = h2.newchannel(scheme, conn)
		if not channel then
			conn:close()
			return nil, err
		end
		local entry = {
			key = key,
			channel = channel,
			lastfree = 0,
			client = client,
		}
		local entries = client.h2pool[key]
		entries[#entries + 1] = entry
		return channel:openstream(), nil
	end
	h1using[conn] = {
		key = key,
		conn = conn,
		lastfree = 0,
		client = client,
	}
	return h1.newstream(scheme, conn, releaseh1), nil
end

---@param client silly.net.http.client
---@param method string
---@param url string
---@param header table<string, string|number>?
---@return silly.net.http.h2.stream|silly.net.http.h1.stream.client|nil, string?
function M.request(client, method, url, header)
	local scheme, host, port, path = parseurl(url)
	local stream, err = connect(client, scheme, host, port)
	if not stream then
		return nil, err
	end
	header = header or {}
	header["host"] = host
	local ok, err = stream:request(method, path, header)
	if not ok then
		stream:close()
		return nil, err
	end
	return stream, nil
end

---@param client silly.net.http.client
function M.get(client, url, header)
	header = header or {}
	-- RFC 7231: Automatically add Accept-Encoding if not set
	if not header["accept-encoding"] then
		header["accept-encoding"] = "gzip"
	end
	local stream<close>, err = client:request("GET", url, header)
	if not stream then
		return nil, err
	end
	stream:closewrite()
	local body, err = stream:readall()
	if not body then
		return nil, err
	end
	-- RFC 7231: Automatically decompress if Content-Encoding is gzip
	local encoding = stream.header["content-encoding"]
	if encoding and lower(encoding) == "gzip" then
		body, err = gzip.decompress(body)
		if not body then
			return nil, err
		end
	end
	return {
		status = stream.status,
		header = stream.header,
		body = body,
	}, nil
end

---@param client silly.net.http.client
function M.post(client, url, header, body)
	header = header or {}
	if body then
		header["content-length"] = #body
	end
	-- RFC 7231: Automatically add Accept-Encoding if not set
	if not header["accept-encoding"] then
		header["accept-encoding"] = "gzip"
	end
	local stream<close>, err = client:request("POST", url, header)
	if not stream then
		return nil, err
	end
	stream:closewrite(body)
	local body, err = stream:readall()
	if not body then
		return nil, err
	end
	-- RFC 7231: Automatically decompress if Content-Encoding is gzip
	local encoding = stream.header["content-encoding"]
	if encoding and lower(encoding) == "gzip" then
		body, err = gzip.decompress(body)
		if not body then
			return nil, err
		end
	end
	return {
		status = stream.status,
		header = stream.header,
		body = body,
	}, nil
end
return M