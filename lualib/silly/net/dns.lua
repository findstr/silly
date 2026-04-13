local c = require "silly.net.dns.c"
local task = require "silly.task"
local time = require "silly.time"
local logger = require "silly.logger"
local udp = require "silly.net.udp"
local addr = require "silly.net.addr"
local tcp = require "silly.net.tcp"
local mutex = require "silly.sync.mutex"

local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local pack = string.pack
local unpack = string.unpack
local lower = string.lower
local timenow = time.monotonic
local maxinteger = math.maxinteger
local iptype = addr.iptype
local join_addr = addr.join
local parse_addr = addr.parse
local question = c.question
local answer = c.answer
local validname = c.validname
local running = task.running
local wakeup = task.wakeup
local wait = task.wait
local errno = require "silly.errno"
local ETIMEDOUT<const> = errno.TIMEDOUT

global _

---@alias silly.net.dns.type `dns.A` | `dns.AAAA` | `dns.SRV`
---@alias silly.net.dns.namecache table<string, table<silly.net.dns.type, silly.net.dns.rr>>
---@alias silly.net.dns.inflight table<table, silly.net.dns.req>

---@class silly.net.dns.rr
---@field package name string
---@field package qtype silly.net.dns.type
---@field package ttl integer
---@field package version integer

---@class silly.net.dns.server
---@field package addr string
---@field package failcount integer used only to pick the starting server for each resolve()
---@field package name_cache silly.net.dns.namecache
---@field package udp_conn silly.net.udp.conn?
---@field package tcp_conn silly.net.tcp.conn?
---@field package tcp_time integer? last TCP activity timestamp (monotonic ms)

---@class silly.net.dns.conf
---@field package nameservers string[]?
---@field package search string[]?
---@field package timeout integer?    per-attempt timeout in seconds (default 5, max 30)
---@field package attempts integer?   retry rounds (default 2, max 5)
---@field package ndots integer?      search list threshold (default 1, max 15)

---@class silly.net.dns.req
---@field package server silly.net.dns.server
---@field package rr silly.net.dns.rr interned rr object (inflight key)
---@field package pkt string          wire-format query packet
---@field package attempt integer     current attempt number
---@field package timer integer?      retry timer handle
---@field package version integer     query ID (matches rr.version)
---@field package waiting table<thread, silly.net.dns.trans>  set of waiting coroutines
---@field package error string?       error message if request failed
---@field package records table?

---@class silly.net.dns.trans
---@field package co thread?
---@field package req silly.net.dns.req?
---@field package name_cache silly.net.dns.namecache

local hosts = {}        ---@type silly.net.dns.namecache
local servers = {}      ---@type silly.net.dns.server[]
local search_list = {}  ---@type string[]
local inflight = {}     ---@type silly.net.dns.inflight

local conf_timeout = 5000   ---@type integer per-attempt timeout (ms)
local conf_attempts = 2     ---@type integer retry rounds
local conf_ndots = 1        ---@type integer search list dot threshold

local RR_A<const> = 1
local RR_CNAME<const> = 5
local RR_AAAA<const> = 28
local RR_SRV<const> = 33

local TCP_SCAN<const> = 10000     -- 10s TCP cleanup scan interval
local TCP_IDLE<const> = 30000     -- 30s idle timeout for TCP connections
local TIMEOUT<const> = {}

--- Normalize a nameserver address: add port 53 if not specified.
---@param s string
---@return string
local function ns_addr(s)
	local host, port = parse_addr(s)
	return join_addr(host, port or "53")
end

--- Get or create an interned rr object for name+qtype.
--- The rr serves as both cache entry and inflight dedup key.
---@param name_cache silly.net.dns.namecache
---@param name string
---@param qtype integer
---@return silly.net.dns.rr
local function try_create_rr(name_cache, name, qtype)
	local by_name = name_cache[name]
	if not by_name then
		by_name = {}
		name_cache[name] = by_name
	end
	local rr = by_name[qtype]
	if not rr then
		rr = {name = name, qtype = qtype, ttl = -1, version = 0}
		by_name[qtype] = rr
	end
	return rr
end

---@param rr silly.net.dns.rr
---@param ttl integer
local function clear_rr(rr, ttl)
	for i = 1, #rr do
		rr[i] = nil
	end
	rr.ttl = ttl
end

---@param trans silly.net.dns.trans
---@param records table?
local function merge_records(trans, records)
	if not records then
		return
	end
	local name_cache = trans.name_cache
	local seen = {}
	for i = 1, #records do
		local rec = records[i]
		local rr = try_create_rr(name_cache, rec[1], rec[2])
		if not seen[rr] then
			seen[rr] = true
			clear_rr(rr, maxinteger)
		end
		local rdata = rec[4]
		if rdata then
			rr[#rr + 1] = rdata
		end
	end
end


local tcp_timer_started = false

--- Periodically scan servers and release idle TCP connections.
local function start_tcp_timer()
	local exist_tcp = false
	local now = timenow()
	for _, server in ipairs(servers) do
		local conn = server.tcp_conn
		if conn then
			if now - server.tcp_time >= TCP_IDLE then
				conn:close()
				server.tcp_conn = nil
			else
				exist_tcp = true
			end
		end
	end
	if not exist_tcp then
		tcp_timer_started = false
		return
	end
	time.after(TCP_SCAN, start_tcp_timer)
end

--- Finish an inflight request: cancel timer, clean tables, wake all waiters.
---@param req silly.net.dns.req
---@param errmsg string? nil = success, string = failure reason
local function finish_req(req, errmsg)
	local timer = req.timer
	if timer then
		time.cancel(timer)
		req.timer = nil
	end
	inflight[req.rr] = nil
	req.rr = nil
	req.error = errmsg
	local ok = not errmsg
	local server = req.server
	if not ok then
		server.failcount = server.failcount + 1
	else
		server.failcount = 0
	end
	local waiting = req.waiting
	for co, trans in pairs(waiting) do
		trans.co = nil
		waiting[co] = nil
		wakeup(co, ok)
	end
end

local tcp_fallback

--- Dispatch a DNS response message.
--- Returns the matched req if TC bit is set (for UDP to trigger TCP fallback).
---@param name_cache silly.net.dns.namecache
---@param msg string
---@return silly.net.dns.req?
local function dispatch_resp(name_cache, msg)
	local id, name, qtype, tc, records = answer(msg)
	if not id then
		return nil
	end
	local by_name = name_cache[name]
	local rr = by_name and by_name[qtype]
	local req = rr and inflight[rr]
	if not req or rr.version ~= id then
		return nil
	end
	if tc then -- TC (truncated)
		return req
	end
	if not records then
		-- Server failure is not a negative answer,
		-- so do not clear or overwrite cache.
		finish_req(req, "Server failure")
		return nil
	end
	local now = timenow()
	local seen = {}
	req.records = records
	for i = 1, #records do
		local rec = records[i]
		local ttl = rec[3]
		if ttl > 0 then
			local rname, rqtype, rdata = rec[1], rec[2], rec[4]
			local cache_rr = try_create_rr(name_cache, rname, rqtype)
			if not seen[cache_rr] then
				seen[cache_rr] = true
				clear_rr(cache_rr, now + ttl)
			end
			if rdata then
				cache_rr[#cache_rr + 1] = rdata
			end
		end
	end
	if not seen[rr] then
		-- A successful response may update only CNAME/related records;
		-- clear stale qtype data.
		clear_rr(rr, -1)
	end
	finish_req(req, nil)
	return nil
end

---@param server silly.net.dns.server
local function udp_recv_loop(server)
	local conn = server.udp_conn
	if not conn then
		return
	end
	local name_cache = server.name_cache
	while true do
		local msg, err = conn:recvfrom()
		if not msg then
			logger.info("[dns] udp error:", err)
			break
		end
		local tc_req = dispatch_resp(name_cache, msg)
		if tc_req then
			task.fork(tcp_fallback, {server = server, req = tc_req})
		end
	end
	conn:close()
	server.udp_conn = nil
end

---@param server silly.net.dns.server
local function tcp_recv_loop(server)
	local conn = server.tcp_conn
	if not conn then
		return
	end
	local name_cache = server.name_cache
	while true do
		local len_data, err = conn:read(2)
		if err then
			break
		end
		local len = unpack(">I2", len_data)
		if len == 0 then
			break
		end
		local msg, err = conn:read(len)
		if err then
			break
		end
		server.tcp_time = timenow()
		dispatch_resp(name_cache, msg)
	end
	conn:close()
	server.tcp_conn = nil
end

local connect_lock = mutex.new()
--- TCP fallback: re-send a query over TCP when UDP response had TC=1.
---@param args {server:silly.net.dns.server, req:silly.net.dns.req}
tcp_fallback = function(args)
	local server = args.server
	local req = args.req
	local rr = req.rr
	if not rr or inflight[rr] ~= req then
		return false
	end
	local now = timenow()
	local lock<close> = connect_lock:lock(server)
	local conn = server.tcp_conn
	if not conn then
		local err
		conn, err = tcp.connect(server.addr)
		if not conn then
			logger.error("[dns] tcp connect", server.addr, "failed:", err)
			return false
		end
		server.tcp_conn = conn
		server.tcp_time = now
		task.fork(tcp_recv_loop, server)
		if not tcp_timer_started then
			tcp_timer_started = true
			time.after(TCP_SCAN, start_tcp_timer)
		end
		-- Re-check: request might have been resolved while connecting
		if inflight[rr] ~= req then
			return false
		end
	end
	server.tcp_time = now
	local pkt = req.pkt
	local ok, err = conn:write(pack(">I2", #pkt) .. pkt)
	if not ok then
		logger.error("[dns] tcp write to", server.addr, "failed:", err)
		conn:close()
		--let recv loop clear server.tcp_conn
	end
	return ok
end

local send_udp_req

--- Timer-driven retry callback.
---@param req silly.net.dns.req
local function retry_cb(req)
	local rr = req.rr
	if not rr or rr.version ~= req.version then
		return  -- this request is too late, already superseded by a newer one
	end
	req.timer = nil  -- this timer just fired
	if req.attempt < conf_attempts then
		req.attempt = req.attempt + 1
		if send_udp_req(req) then
			return
		end
	end
	finish_req(req, ETIMEDOUT)
end

---@param req silly.net.dns.req
---@return boolean
send_udp_req = function(req)
	local err
	local server = req.server
	local pkt = req.pkt
	local conn = server.udp_conn
	if not conn then
		conn, err = udp.connect(server.addr)
		if not conn then
			logger.error("[dns] connect", server.addr, "failed:", err)
		else
			task.fork(udp_recv_loop, server)
			server.udp_conn = conn
		end
	end
	if not conn then
		return false
	end
	local ok = conn:sendto(pkt)
	if not ok then
		return false
	end
	req.timer = time.after(conf_timeout, retry_cb, req)
	return true
end

local function close_servers()
	for _, req in pairs(inflight) do
		finish_req(req, "Dns reconfigured")
	end
	for i, server in ipairs(servers) do
		servers[i] = nil -- clear server list to prevent new queries and reconnect
		local udp_conn = server.udp_conn
		if udp_conn then
			udp_conn:close()
			server.udp_conn = nil
		end
		local tcp_conn = server.tcp_conn
		if tcp_conn then
			tcp_conn:close()
			server.tcp_conn = nil
		end
	end
end

---@param trans silly.net.dns.trans
local function query_timer(trans)
	local co = trans.co
	if not co then
		return
	end
	trans.co = nil
	trans.req.waiting[co] = nil
	wakeup(co, TIMEOUT)
end

--- Send a DNS query with inflight deduplication and timer-driven retry.
--- If timeout is provided, the caller gives up after that many ms
--- (the inflight query continues for the benefit of other/future callers).
---@param server silly.net.dns.server
---@param trans silly.net.dns.trans
---@param name string
---@param qtype silly.net.dns.type
---@param timeout integer   per-call user timeout (ms)
---@return boolean, string? error
local function query(server, trans, name, qtype, timeout)
	local name_cache = server.name_cache
	local rr = try_create_rr(name_cache, name, qtype)
	local co = running()
	local request = inflight[rr]
	if not request then
		local version = (rr.version + 1) & 0xFFFF
		rr.version = version
		local pkt = question(name, qtype, version)
		request = {
			server = server,
			rr = rr,
			pkt = pkt,
			attempt = 1,
			waiting = {},
			version = version,
			records = nil,
		}
		-- Set inflight BEFORE send_udp_req: udp.connect yields, so
		-- concurrent callers must see the inflight entry to join rather
		-- than issuing duplicate queries.
		inflight[rr] = request
		local ok = send_udp_req(request)
		if not ok then
			finish_req(request, "Send failed")
			return false, "Send failed"
		end
	end
	-- Optional per-call user timeout
	trans.co = co
	trans.req = request
	request.waiting[co] = trans
	local timer = time.after(timeout, query_timer, trans)
	local ok = wait()
	if ok == TIMEOUT then
		return false, ETIMEDOUT
	end
	time.cancel(timer)
	if ok then
		merge_records(trans, request.records)
		return true
	end
	return false, request.error
end

---@param cache silly.net.dns.namecache
---@param name string
---@param qtype silly.net.dns.type
---@return silly.net.dns.rr?, string? next_name
local function lookup_trans(cache, name, qtype)
	local rrs = cache[name]
	if not rrs then
		return nil, nil
	end
	local rr = rrs[qtype]
	if rr and rr[1] then
		return rr, nil
	end
	local cname = rrs[RR_CNAME]
	return nil, cname and cname[1]
end

---@param cache silly.net.dns.namecache
---@param name string
---@param qtype silly.net.dns.type
---@param now integer
---@return silly.net.dns.rr?, string? next_name
local function lookup_server(cache, name, qtype, now)
	local rrs = cache[name]
	if not rrs then
		return nil, nil
	end
	local rr = rrs[qtype]
	if rr and rr.ttl >= now then
		return rr, nil
	end
	local cname = rrs[RR_CNAME]
	if cname and cname.ttl >= now then
		return nil, cname[1]
	end
	return nil, nil
end

---@param trans_cache silly.net.dns.namecache?
---@param name_cache silly.net.dns.namecache
---@param name string
---@param qtype silly.net.dns.type
---@return silly.net.dns.rr?, string? error_or_next_name
local function findcache(trans_cache, name_cache, name, qtype)
	local now = timenow()
	local original = name
	for i = 1, 100 do
		local rr, next_name
		if trans_cache then
			rr, next_name = lookup_trans(trans_cache, name, qtype)
			if rr then
				return rr, nil
			end
		end
		if not next_name then
			rr, next_name = lookup_server(name_cache, name, qtype, now)
			if rr then
				return rr, nil
			end
		end
		if not next_name then
			-- the CNAME chain advanced, but the final qtype is not cached yet
			return nil, name ~= original and name
		end
		name = next_name
	end
	return nil, nil
end

---@param server silly.net.dns.server
---@param trans silly.net.dns.trans
---@param name string
---@param qtype silly.net.dns.type
---@param timeout integer
---@param deep integer
---@return table? res, string? error
local function resolve_r(server, trans, name, qtype, timeout, deep)
	if deep > 100 then
		return nil, "Too deep"
	end
	local name_cache = server.name_cache
	local trans_cache = trans.name_cache
	local rr, cname = findcache(trans_cache, name_cache, name, qtype)
	if not rr and not cname then
		local ok, err = query(server, trans, name, qtype, timeout)
		if not ok then
			return nil, err
		end
		rr, cname = findcache(trans_cache, name_cache, name, qtype)
	end
	if cname then
		return resolve_r(server, trans, cname, qtype, timeout, deep + 1)
	end
	return rr
end

---@class silly.net.dns
local dns = {
	---@type silly.net.dns.type
	A = RR_A,
	---@type silly.net.dns.type
	AAAA = RR_AAAA,
	---@type silly.net.dns.type
	SRV = RR_SRV,
}


---@param name string
---@param qtype silly.net.dns.type
---@param timeout integer?   per-call user timeout (ms)
---@return table|nil, string? error
local function resolve(name, qtype, timeout)
	if iptype(name) ~= 0 then
		return {name}
	end
	name = lower(name)
	if not validname(name) then
		return nil, "Invalid name"
	end
	if qtype == RR_A or qtype == RR_AAAA then -- try hosts first
		local rrs = hosts[name]
		if rrs then
			local rr = rrs[qtype]
			if rr then
				return rr
			end
		end
	end
	timeout = timeout or conf_timeout
	local server
	local failcount = maxinteger
	-- select server
	for i = 1, #servers do
		local s = servers[i]
		local n = s.failcount
		if n == 0 then
			server = s
			break
		end
		if n < failcount then
			failcount = n
			server = s
		end
	end
	if not server then
		return nil, "No nameserver"
	end
	---@type silly.net.dns.trans
	local trans = {req = nil, co = nil, name_cache = {}}
	local rr, err = resolve_r(server, trans, name, qtype, timeout, 1)
	if rr then
		return rr
	end
	if conf_ndots > 0 and conf_ndots > c.dotcount(name) then
		for _, suffix in ipairs(search_list) do
			trans = {req = nil, co = nil, name_cache = {}}
			rr, err = resolve_r(server, trans, name .. "." .. suffix, qtype, timeout, 1)
			if rr then
				return rr
			end
		end
	end
	return nil, err or "Not found"
end


---@param name string
---@param qtype silly.net.dns.type
---@param timeout integer?   per-call user timeout (ms)
---@return string|nil, string? error
function dns.lookup(name, qtype, timeout)
	if iptype(name) ~= 0 then
		return name
	end
	local rr, err = resolve(name, qtype, timeout)
	return rr and rr[1], err
end

dns.resolve = resolve

dns.isname = function(name) return iptype(name) == 0 end

---------------------------------
--dns configuration and resolvconf parsing

local function parse_resolvconf(content)
	for line in content:gmatch("[^\n]+") do
		local ns = line:match("^%s*nameserver%s+([^%s]+)")
		if ns then
			servers[#servers + 1] = {
				addr = ns_addr(ns),
				failcount = 0,
				name_cache = {},
			}
		end
		local search = line:match("^%s*search%s+(.+)")
		if search then
			search_list = {}
			for domain in search:gmatch("%S+") do
				search_list[#search_list + 1] = lower(domain)
			end
		end
		local domain = line:match("^%s*domain%s+(%S+)")
		if domain then
			search_list = {lower(domain)}
		end
		local opts = line:match("^%s*options%s+(.+)")
		if opts then
			local t = opts:match("timeout:(%d+)")
			if t then
				t = tonumber(t)
				if t > 30 then t = 30 end
				conf_timeout = t * 1000
			end
			local a = opts:match("attempts:(%d+)")
			if a then
				a = tonumber(a)
				if a > 5 then a = 5 end
				conf_attempts = a
			end
			local n = opts:match("ndots:(%d+)")
			if n then
				n = tonumber(n)
				if n > 15 then n = 15 end
				conf_ndots = n
			end
		end
	end
end

local function parse_hosts(content)
	local seen = {}
	for line in content:gmatch("[^\n]+") do
		local ip, names = line:match("^%s*([%[%]%x%.%:]+)%s+([^#;]+)")
		if not ip or not names then
			goto continue
		end

		local typename
		local t = iptype(ip)
		if t == 4 then
			typename = RR_A
		elseif t == 6 then
			typename = RR_AAAA
		else
			goto continue
		end

		for name in names:gmatch("%S+") do
			local lname = name:lower()
			local rr = try_create_rr(hosts, lname, typename)
			if not seen[rr] then
				seen[rr] = true
				for i = 1, #rr do
					rr[i] = nil
				end
			end
			rr[#rr + 1] = ip
			rr.ttl = maxinteger
		end
		::continue::
	end
end

do
	local content = c.resolvconf()
	if not content then
		logger.warn("[dns] no resolvconf content, use 8.8.8.8")
		content = "nameserver 8.8.8.8"
	end
	parse_resolvconf(content)
	local content = c.hosts()
	if content then
		parse_hosts(content)
	end
end

dns.sethosts = parse_hosts

--- Configure the DNS resolver.
--- Replaces all existing servers and options.
---@param opts silly.net.dns.conf
function dns.conf(opts)
	close_servers()
	servers = {}
	search_list = {}
	conf_timeout = 5000
	conf_attempts = 2
	conf_ndots = 1
	local nameservers = opts.nameservers
	if not nameservers then
		nameservers = {}
	end
	if #nameservers == 0 then
		nameservers[1] = "8.8.8.8"
	end
	for i, a in ipairs(nameservers) do
		servers[i] = {
			addr = ns_addr(a),
			name_cache = {},
			failcount = 0,
		 }
	end
	if opts.search then
		search_list = {}
		for _, s in ipairs(opts.search) do
			search_list[#search_list + 1] = lower(s)
		end
	end
	if opts.timeout then
		local t = opts.timeout
		if t > 30 then
			t = 30
		end
		conf_timeout = t * 1000
	end
	if opts.attempts then
		local a = opts.attempts
		if a > 5 then
			a = 5
		end
		conf_attempts = a
	end
	if opts.ndots then
		local n = opts.ndots
		if n > 15 then
			n = 15
		end
		conf_ndots = n
	end
end

return dns
