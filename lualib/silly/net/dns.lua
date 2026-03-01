local c = require "silly.net.dns.c"
local task = require "silly.task"
local time = require "silly.time"
local logger = require "silly.logger"
local udp = require "silly.net.udp"
local addr = require "silly.net.addr"
local tcp = require "silly.net.tcp"

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

global _

---@class silly.net.dns.server
---@field addr string
---@field udp_conn silly.net.udp.conn?
---@field tcp_conn silly.net.tcp.conn?
---@field tcp_time integer? last TCP activity timestamp (monotonic ms)

local servers = {}     ---@type silly.net.dns.server[]
local search_list = {} ---@type string[]

---@class silly.net.dns.conf
---@field nameservers string[]?
---@field search string[]?
---@field timeout integer?    per-attempt timeout in seconds (default 5, max 30)
---@field attempts integer?   retry rounds (default 2, max 5)
---@field ndots integer?      search list threshold (default 1, max 15)

---@class silly.net.dns.ctx
---@field request silly.net.dns.req
---@field co thread

---@class silly.net.dns.req
---@field rr table          interned rr object (inflight key)
---@field pkt string        wire-format query packet
---@field attempt integer   current attempt number
---@field timer integer?    retry timer handle
---@field version integer    query ID (matches rr.version)
---@field waiting table<thread, silly.net.dns.ctx>  set of waiting coroutines
---@field error string?       error message if request failed

local conf_timeout = 5000   ---@type integer per-attempt timeout (ms)
local conf_attempts = 2     ---@type integer retry rounds
local conf_ndots = 1        ---@type integer search list dot threshold

local name_cache = {}

local inflight = {}       ---@type table<table, silly.net.dns.req>

local RR_A<const> = 1
local RR_CNAME<const> = 5
local RR_AAAA<const> = 28
local RR_SRV<const> = 33

local TCP_SCAN<const> = 10000     -- 10s TCP cleanup scan interval
local TCP_IDLE<const> = 30000     -- 30s idle timeout for TCP connections
local DEFAULT_TTL<const> = 5000   -- 5s default cache TTL (ms)
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
---@param name string
---@param qtype integer
---@return table
local function try_create_rr(name, qtype)
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


local tcp_timer_started = false

--- Periodically scan servers and release idle TCP connections.
local function start_tcp_timer()
	local exist_tcp = false
	local now = timenow()
	for _, srv in ipairs(servers) do
		local conn = srv.tcp_conn
		if conn then
			if now - srv.tcp_time >= TCP_IDLE then
				conn:close()
				srv.tcp_conn = nil
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
	local waiting = req.waiting
	for co, v in pairs(waiting) do
		v.co = nil
		waiting[co] = nil
		wakeup(co, ok)
	end
end

local tcp_fallback

--- Dispatch a DNS response message.
--- Returns the matched req if TC bit is set (for UDP to trigger TCP fallback).
---@param msg string
---@return silly.net.dns.req?
local function dispatch_resp(msg)
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
	local now = timenow()
	rr.ttl = now + DEFAULT_TTL
	for i = 1, #rr do
		rr[i] = nil
	end
	if #records > 0 then
		local seen = {}
		for _, rec in ipairs(records) do
			local rname, rqtype, ttl, rdata = rec[1], rec[2], rec[3], rec[4]
			local cache_rr = try_create_rr(rname, rqtype)
			if not seen[cache_rr] then
				seen[cache_rr] = true
				for i = 1, #cache_rr do
					cache_rr[i] = nil
				end
				cache_rr.ttl = now + ttl
			end
			if rdata then
				cache_rr[#cache_rr + 1] = rdata
			end
		end
		-- Invalidate rr not updated by this response (e.g. CNAME-only reply)
		-- so findcache won't serve a stale positive entry
		if not seen[rr] then
			rr.ttl = -1
		end
	end
	local first = rr[1]
	local errmsg = not first and "nxdomain" or nil
	finish_req(req, errmsg)
	return nil
end

---@param srv silly.net.dns.server
local function udp_recv_loop(srv)
	local conn = srv.udp_conn
	if not conn then
		return
	end
	while true do
		local msg, err = conn:recvfrom()
		if not msg then
			logger.info("[dns] udp error:", err)
			break
		end
		local tc_req = dispatch_resp(msg)
		if tc_req then
			task.fork(tcp_fallback, {srv = srv, req = tc_req})
		end
	end
	conn:close()
	srv.udp_conn = nil
end

---@param srv silly.net.dns.server
local function tcp_recv_loop(srv)
	local conn = srv.tcp_conn
	if not conn then
		return
	end
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
		srv.tcp_time = timenow()
		dispatch_resp(msg)
	end
	conn:close()
	srv.tcp_conn = nil
end

--- TCP fallback: re-send a query over TCP when UDP response had TC=1.
---@param args {srv:silly.net.dns.server, req:silly.net.dns.req}
tcp_fallback = function(args)
	local srv = args.srv
	local req = args.req
	local rr = req.rr
	if not rr or inflight[rr] ~= req then
		return false
	end
	local now = timenow()
	local conn = srv.tcp_conn
	if not conn then
		local err
		conn, err = tcp.connect(srv.addr)
		if not conn then
			logger.error("[dns] tcp connect", srv.addr, "failed:", err)
			return false
		end
		srv.tcp_conn = conn
		srv.tcp_time = now
		task.fork(tcp_recv_loop, srv)
		if not tcp_timer_started then
			tcp_timer_started = true
			time.after(TCP_SCAN, start_tcp_timer)
		end
		-- Re-check: request might have been resolved while connecting
		if inflight[rr] ~= req then
			return false
		end
	end
	srv.tcp_time = now
	local pkt = req.pkt
	local ok, err = conn:write(pack(">I2", #pkt) .. pkt)
	if not ok then
		logger.error("[dns] tcp write to", srv.addr, "failed:", err)
		conn:close()
		--let recv loop clear srv.tcp_conn
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
	finish_req(req, "timeout")
end

---@param req silly.net.dns.req
---@return boolean
send_udp_req = function(req)
	local sent = false
	local pkt = req.pkt
	for i, srv in ipairs(servers) do
		local err
		local conn = srv.udp_conn
		if not conn then
			conn, err = udp.connect(srv.addr)
			if not conn then
				logger.error("[dns] connect", srv.addr, "failed:", err)
			else
				task.fork(udp_recv_loop, srv)
				srv.udp_conn = conn
			end
		end
		if conn then
			local ok = conn:sendto(pkt)
			if ok then
				sent = true
			end
		end
	end
	if sent then
		req.timer = time.after(conf_timeout, retry_cb, req)
	end
	return sent
end

local function close_servers()
	for _, req in pairs(inflight) do
		finish_req(req, "dns reconfigured")
	end
	for i, srv in ipairs(servers) do
		servers[i] = nil -- clear server list to prevent new queries and reconnect
		local udp_conn = srv.udp_conn
		if udp_conn then
			udp_conn:close()
			srv.udp_conn = nil
		end
		local tcp_conn = srv.tcp_conn
		if tcp_conn then
			tcp_conn:close()
			srv.tcp_conn = nil
		end
	end
end

local function query_timer(ctx)
	local co = ctx.co
	ctx.co = nil
	ctx.request.waiting[co] = nil
	wakeup(co, TIMEOUT)
end

--- Send a DNS query with inflight deduplication and timer-driven retry.
--- If timeout is provided, the caller gives up after that many ms
--- (the inflight query continues for the benefit of other/future callers).
---@async
---@param name string
---@param qtype silly.net.dns.type
---@param timeout integer   per-call user timeout (ms)
---@return boolean, string? error
local function query(name, qtype, timeout)
	local ctx
	local rr = try_create_rr(name, qtype)
	local co = running()
	local request = inflight[rr]
	if not request then
		local version = (rr.version + 1) & 0xFFFF
		rr.version = version
		local pkt = question(name, qtype, version)
		local waiting = {}
		request = {
			rr = rr,
			pkt = pkt,
			attempt = 1,
			waiting = waiting,
			version = version,
		}
		-- Set inflight BEFORE send_udp_req: udp.connect yields, so
		-- concurrent callers must see the inflight entry to join rather
		-- than issuing duplicate queries.
		ctx = {request = request, co = co}
		waiting[co] = ctx
		inflight[rr] = request
		local ok = send_udp_req(request)
		if not ok then
			-- Remove self from waiting, wake any joiners with failure.
			ctx.co = nil
			waiting[co] = nil
			finish_req(request, "send failed")
			return false
		end
	else
		ctx = {request = request, co = co}
		request.waiting[co] = ctx
	end
	-- Optional per-call user timeout
	local timer = time.after(timeout, query_timer, ctx)
	local ok = wait()
	if ok == TIMEOUT then
		return false
	end
	time.cancel(timer)
	return ok
end

---@param name string
---@param qtype silly.net.dns.type
---@return table|nil, string|nil
local function findcache(name, qtype)
	local now = timenow()
	local original = name
	for i = 1, 100 do
		local rrs = name_cache[name]
		if not rrs then
			if name ~= original then
				return nil, name
			end
			return nil, nil
		end
		local rr = rrs[qtype]
		if rr and rr.ttl >= now then
			return rr, nil
		end
		local cname = rrs[RR_CNAME]
		if cname and cname.ttl >= now and cname[1] then
			name = cname[1]
		else
			if name ~= original then
				return nil, name
			end
			return nil, nil
		end
	end
	return nil, nil
end

---@async
---@param name string
---@param qtype silly.net.dns.type
---@param timeout integer
---@param deep integer
---@return table|nil
local function resolve_r(name, qtype, timeout, deep)
	if deep > 100 then
		return nil
	end
	local rr, cname = findcache(name, qtype)
	if not rr and not cname then
		query(name, qtype, timeout)
		rr, cname = findcache(name, qtype)
	end
	if cname then
		return resolve_r(cname, qtype, timeout, deep + 1)
	end
	return rr
end

---@alias silly.net.dns.type `dns.A` | `dns.AAAA` | `dns.SRV`
---@class silly.net.dns
local dns = {
	---@type silly.net.dns.type
	A = RR_A,
	---@type silly.net.dns.type
	AAAA = RR_AAAA,
	---@type silly.net.dns.type
	SRV = RR_SRV,
}


---@async
---@param name string
---@param qtype silly.net.dns.type
---@param timeout integer?   per-call user timeout (ms)
---@return table|nil
local function resolve(name, qtype, timeout)
	if iptype(name) ~= 0 then
		return {name}
	end
	name = lower(name)
	if not validname(name) then
		return nil
	end
	timeout = timeout or conf_timeout
	local rr = resolve_r(name, qtype, timeout, 1)
	if rr then
		return rr
	end
	if conf_ndots > 0 and conf_ndots > c.dotcount(name) then
		for _, suffix in ipairs(search_list) do
			rr = resolve_r(name .. "." .. suffix, qtype, timeout, 1)
			if rr then
				return rr
			end
		end
	end
	return nil
end


---@async
---@param name string
---@param qtype silly.net.dns.type
---@param timeout integer?   per-call user timeout (ms)
---@return string|nil
function dns.lookup(name, qtype, timeout)
	if iptype(name) ~= 0 then
		return name
	end
	local rr = resolve(name, qtype, timeout)
	return rr and rr[1]
end

dns.resolve = resolve

dns.isname = function(name) return iptype(name) == 0 end

---------------------------------
--dns configuration and resolvconf parsing

local function parse_resolvconf(content)
	for line in content:gmatch("[^\n]+") do
		local ns = line:match("^%s*nameserver%s+([^%s]+)")
		if ns then
			servers[#servers + 1] = { addr = ns_addr(ns) }
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
			local rr = try_create_rr(lname, typename)
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
	if opts.nameservers then
		for i, a in ipairs(opts.nameservers) do
			servers[i] = { addr = ns_addr(a) }
		end
	end
	if opts.search then
		for _, s in ipairs(opts.search) do
			search_list[#search_list + 1] = lower(s)
		end
	end
	if opts.timeout then
		local t = opts.timeout
		if t > 30 then t = 30 end
		conf_timeout = t * 1000
	end
	if opts.attempts then
		local a = opts.attempts
		if a > 5 then a = 5 end
		conf_attempts = a
	end
	if opts.ndots then
		local n = opts.ndots
		if n > 15 then n = 15 end
		conf_ndots = n
	end
end

return dns
