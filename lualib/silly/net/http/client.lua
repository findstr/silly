local time = require "silly.time"
local tcp = require "silly.net.tcp"
local tls = require "silly.net.tls"
local dns = require "silly.net.dns"
local h1 = require "silly.net.http.h1"
local h2 = require "silly.net.http.h2"
local url = require "silly.net.http.url"
local gzip = require "silly.compress.gzip"
local addr = require "silly.net.addr"
local urlparse = url.parse
local urlresolve = url.resolve
local urlbuild = url.build
local join_addr = addr.join
local pairs = pairs
local setmetatable = setmetatable
local format = string.format
local tremove = table.remove
local lower = string.lower

global _

local redirect_status = {
	[301] = true,
	[302] = true,
	[303] = true,
	[307] = true,
	[308] = true,
}

local method_change_redirect = {
	[301] = true,
	[302] = true,
	[303] = true,
}

-- Headers stripped on cross-origin redirects (matching Go's net/http behavior)
local sensitive_headers = {
	["authorization"] = true,
	["www-authenticate"] = true,
	["cookie"] = true,
	["cookie2"] = true,
	["proxy-authorization"] = true,
	["proxy-authenticate"] = true,
	["referer"] = true,
}

local MAX_FOLLOW_REDIRECTS = 10

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
---@field package closed boolean
---@field package timer integer?
---@field package max_idle_per_host integer
---@field package idle_timeout integer
---@field package alpnprotos silly.net.tls.alpn_proto[]
---@field package h1pool table<string, silly.net.http.client.pool.h1[]>
---@field package h2pool table<string, silly.net.http.client.pool.h2[]>
local M = {}
local mt = {__index = M}

 ---@type table<silly.net.tcp.conn|silly.net.tls.conn, silly.net.http.client.pool.h1>
local h1using = {}

local default_opts = {
	max_idle_per_host = 10,
	idle_timeout = 30000,
	alpnprotos = {"http/1.1", "h2"}
}

local pool_mt = {__index = function(t, k)
	local entries = {}
	t[k] = entries
	return entries
end}

---@param c silly.net.http.client
local function check_alive_timer(c)
	if c.closed then
		c.timer = nil
		return
	end
	local now = time.now()
	local idle_timeout = c.idle_timeout
	local max_idle_per_host = c.max_idle_per_host
	local alive = false

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
		else
			alive = true
		end
	end

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
		else
			alive = true
		end
	end

	if alive then
		c.timer = time.after(c.idle_timeout / 2, check_alive_timer, c)
	else
		c.timer = nil
	end
end

local function ensure_timer(c)
	if not c.timer and not c.closed then
		c.timer = time.after(c.idle_timeout / 2, check_alive_timer, c)
	end
end

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
		ensure_timer(client)
	else
		conn:close()
	end
end

local function find_conn(client, key, scheme, authority)
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
			return h1.newstream(scheme, entry.conn, authority, releaseh1)
		end
	end
	return nil
end

---@class silly.net.http.client.opts
---@field max_idle_per_host integer?  -- Maximum idle connections per host (default: 10)
---@field idle_timeout integer?       -- Idle connection timeout in ms (default: 30000)
---@field alpnprotos silly.net.tls.alpn_proto[]? -- ALPN protocols (default: {"http/1.1", "h2"})

---@param opts silly.net.http.client.opts?
---@return silly.net.http.client
function M.new(opts)
	---@type silly.net.http.client
	local c = {
		closed = false,
		timer = nil,
		max_idle_per_host = opts and opts.max_idle_per_host or default_opts.max_idle_per_host,
		idle_timeout = opts and opts.idle_timeout or default_opts.idle_timeout,
		alpnprotos = opts and opts.alpnprotos or default_opts.alpnprotos,
		h1pool = setmetatable({}, pool_mt),
		h2pool = setmetatable({}, pool_mt),
	}
	setmetatable(c, mt)
	return c
end

---@param client silly.net.http.client
---@param u silly.net.http.url.parts
---@return silly.net.http.h1.stream.client|silly.net.http.h2.stream|nil, string? error
local function connect(client, u)
	local key = format("%s:%s:%s", u.scheme, u.host, u.port)
	local stream = find_conn(client, key, u.scheme, u.authority)
	if stream then
		return stream, nil
	end

	local ip, err = dns.lookup(u.host, dns.A)
	if not ip then
		return nil, format("dns lookup %s failed: %s", u.host, err)
	end
	local a = join_addr(ip, u.port)
	local conn
	if u.scheme == "https" then
		conn, err = tls.connect(a, {
			hostname = u.host,
			alpnprotos = client.alpnprotos
		})
	else
		conn, err = tcp.connect(a)
	end
	if not conn then
		return nil, err
	end
	local alpnproto = conn.alpnproto
	if alpnproto and alpnproto(conn) == "h2" then
		local channel, err = h2.newchannel(u.scheme, conn, u.authority)
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
		ensure_timer(client)
		return channel:openstream(), nil
	end
	h1using[conn] = {
		key = key,
		conn = conn,
		lastfree = 0,
		client = client,
	}
	return h1.newstream(u.scheme, conn, u.authority, releaseh1), nil
end

---@param client silly.net.http.client
---@param method string
---@param u silly.net.http.url.parts
---@param header table<string, string|number>?
---@return silly.net.http.h2.stream|silly.net.http.h1.stream.client|nil, string?
local function request_url(client, method, u, header)
	if client.closed then
		return nil, "client is closed"
	end
	local stream, err = connect(client, u)
	if not stream then
		return nil, err
	end
	header = header or {}
	local ok, err = stream:request(method, u.path, header)
	if not ok then
		stream:close()
		return nil, err
	end
	return stream, nil
end

---@param client silly.net.http.client
---@param method string
---@param url string
---@param header table<string, string|number>?
---@return silly.net.http.h2.stream|silly.net.http.h1.stream.client|nil, string?
function M.request(client, method, url, header)
	if client.closed then
		return nil, "client is closed"
	end
	local u, err = urlparse(url)
	if not u then
		return nil, err
	end
	return request_url(client, method, u, header)
end

---@param client silly.net.http.client
---@param method string
---@param url string
---@param header table<string, string|number>
---@param body string?
---@return table? response, string? error
local function do_with_redirects(client, method, url, header, body)
	local seen = {}
	local redirect_count = 0
	local cur_method = method
	local send_body = body
	local u, err = urlparse(url)
	if not u then
		return nil, err
	end
	local h = {}
	for k, v in pairs(header) do
		h[lower(k)] = v
	end
	local initial_scheme = u.scheme
	local initial_authority = u.authority
	local strip_sensitive = false
	while redirect_count <= MAX_FOLLOW_REDIRECTS do
		local url_key = urlbuild(u)
		if seen[url_key] then
			return nil, "redirect loop detected: " .. url_key
		end
		seen[url_key] = true
		if not h["accept-encoding"] then
			h["accept-encoding"] = "gzip"
		end
		if send_body then
			h["content-length"] = #send_body
		end
		local stream<close>, err = request_url(client, cur_method, u, h)
		if not stream then
			return nil, err
		end
		stream:closewrite(send_body)
		local resp_body, req_err = stream:readall()
		if not resp_body then
			return nil, req_err
		end

		local status = stream.status
		if redirect_status[status] and stream.header["location"] then
			local location = stream.header["location"]
			u, err = urlresolve(url_key, location)
			if not u then
				return nil, err
			end
			if not strip_sensitive and (u.scheme ~= initial_scheme or u.authority ~= initial_authority) then
				strip_sensitive = true
			end
			if strip_sensitive then
				for k in pairs(h) do
					if sensitive_headers[lower(k)] then
						h[k] = nil
					end
				end
			end
			if method_change_redirect[status] then
				cur_method = "GET"
				send_body = nil
				h["content-length"] = nil
				h["content-type"] = nil
			end
			redirect_count = redirect_count + 1
		else
			local encoding = stream.header["content-encoding"]
			if encoding and lower(encoding) == "gzip" then
				resp_body, req_err = gzip.decompress(resp_body)
				if not resp_body then
					return nil, req_err
				end
			end
			return {
				status = stream.status,
				header = stream.header,
				body = resp_body,
			}, nil
		end
	end
	return nil, "too many redirects"
end

---@param client silly.net.http.client
function M.get(client, url, header)
	return do_with_redirects(client, "GET", url, header or {}, nil)
end

---@param client silly.net.http.client
function M.post(client, url, header, body)
	return do_with_redirects(client, "POST", url, header or {}, body)
end

---@param client silly.net.http.client
function M.close(client)
	if client.closed then
		return
	end
	client.closed = true
	if client.timer then
		time.cancel(client.timer)
		client.timer = nil
	end
	for k, entries in pairs(client.h1pool) do
		for i = 1, #entries do
			entries[i].conn:close()
		end
		client.h1pool[k] = nil
	end
	for k, entries in pairs(client.h2pool) do
		for i = 1, #entries do
			entries[i].channel:close()
		end
		client.h2pool[k] = nil
	end
	for conn, entry in pairs(h1using) do
		if entry.client == client then
			conn:close()
			h1using[conn] = nil
		end
	end
end
return M
