local core = require "core"
local time = require "core.time"
local env = require "core.env"
local logger = require "core.logger"
local udp = require "core.net.udp"
local assert = assert
local pairs = pairs
local sub = string.sub
local concat = table.concat
local pack = string.pack
local unpack = string.unpack
local format = string.format
local gmatch = string.gmatch
local setmetatable = setmetatable
local timenow = time.monotonic
local maxinteger = math.maxinteger

local session = 0
local dns_server
local connectfd

local resolv_conf = env.get("sys.dns.resolv_conf") or "/etc/resolv.conf"
local hosts = env.get("sys.dns.hosts") or "/etc/hosts"

local name_cache = {}
local wait_coroutine = {}

local RR_A<const> = 1
local RR_CNAME<const> = 5
local RR_AAAA<const> = 28
local RR_SRV<const> = 33

local function guesstype(str)
	if str:match("^[%d%.]+$") then
		return RR_A
	end
	if str:find(":") then
		return RR_AAAA
	end
	return RR_CNAME
end

--[[
	ID:16

	QR:1		0 -> request 1-> acknowledge
	OPCODE:4	0 -> QUERY 1 -> IQUERY 2 -> STATUS
	AA:1		authoriative Answer
	TC:1		trun cation
	RD:1		recursion desiered
	RA:1		rescursion availavle
	Z:3		0
	RCODE:4		0 -> ok 1 -> FormatError 2 -> Server Failure 3 -> NameError
				4 -> NotEmplemented 5 -> Refresued
	QDCOUNT:16	quest descriptor count
	ANCOUNT:16	anser RRs
	NSCOUNT:16	authority RRs
	ARCOUNT:16	Additional RRs

	QNAME:z		question name
	QTYPE:16	0x01 -> IP... 0x05 -> CNAME
	QCLASS:16	0x01 -> IN
]]--

local parseformat  = ">I2I2I2I2I2I2zI2I2"
local headerformat = ">I2I2I2I2I2I2"

local function QNAME(name, n)
	local i = #n
	for k in gmatch(name, "([^%.]+)") do
		i = i + 1
		n[i] = pack(">I1", #k)
		i = i + 1
		n[i] = k
	end
	i = i + 1
	n[i] = '\0'
end

---@param typ core.dns.type
local function question(name, typ)
	session = session % 65535 + 1
	local ID = session
	--[[ FLAG
		QR = 0,
		OPCODE = 0, (4bit)
		AA = 0,
		TC = 0,
		RD = 1,
		RA = 0,
		--3 bit zero
		RCCODE = 0,
	]]--
	local FLAG = 0x0100
	local QDCOUNT = 1
	local ANCOUNT = 0
	local NSCOUNT = 0
	local ARCOUNT = 0
	local QTYPE = typ
	local QCLASS = 1
	local dat = {
		pack(headerformat,
			ID, FLAG,
			QDCOUNT, ANCOUNT,
			NSCOUNT, ARCOUNT)
	}
	QNAME(name, dat)
	dat[#dat + 1] = pack(">I2I2", QTYPE, QCLASS)
	return ID, concat(dat)
end

local function readptr(init, dat, pos)
	local n, pos = unpack(">I1", dat, pos)
	if n >= 0xc0 then
		n = n & 0x3f
		local l, pos = unpack(">I1", dat, pos)
		n = n  << 8 | l
		return readptr(init, dat, n + 1)
	elseif n > 0 then
		local nxt = pos + n
		init[#init + 1] = sub(dat, pos, nxt - 1)
		init[#init + 1] = "."
		return readptr(init, dat, nxt)
	else
		return
	end
end

local function readname(dat, i)
	local tbl = {}
	while true do	--first
		local n, j = unpack(">I1", dat, i)
		if n >= 0xc0 then
			readptr(tbl, dat, i)
			i = i + 2
			break
		elseif n == 0 then
			i = j
			break
		end
		tbl[#tbl + 1] = sub(dat, j, i + n)
		tbl[#tbl + 1] = "."
		i = j + n
	end
	tbl[#tbl] = nil
	return concat(tbl), i
end

local parser = {
	[RR_A] = function(dat, pos)
		local d1, d2, d3, d4 = unpack(">I1I1I1I1", dat, pos)
		return format("%d.%d.%d.%d", d1, d2, d3, d4)
	end,
	[RR_AAAA] = function(dat, pos)
		local x1, x2, x3, x4, x5, x6, x7, x8 =
			unpack(">I2I2I2I2I2I2I2I2", dat, pos)
		return format(
			"%02x:%02x:%02x:%02x:%02x:%02x:%02x:%02x",
			x1, x2, x3, x4, x5, x6, x7, x8
		)
	end,
	[RR_CNAME] = function(dat, pos)
		return readname(dat, pos)
	end,
	[RR_SRV] = function(dat, pos)
		local priority, weight, port = unpack(">I2I2I2", dat, pos)
		local target = readname(dat, pos + 6)
		return {
			priority = priority,
			weight = weight,
			port = port,
			target = target,
		}
	end
}

local newrrmt = {__index = function(t, k)
	local v = {
		TTL = maxinteger
	}
	t[k] = v
	return v
end}

local answers = setmetatable({}, {__index = function(t, k)
	local v = setmetatable({}, newrrmt)
	t[k] = v
	return v
end})

local function merge_answers()
	for name, rrs in pairs(answers) do
		answers[name] = nil
		local dst = name_cache[name]
		if not dst then
			setmetatable(rrs, nil)
			name_cache[name] = rrs
		else
			for k, v in pairs(rrs) do
				dst[k] = v
			end
		end
	end
end

local function answer(dat, start, n)
	local now = timenow() // 1000
	for i = 1, n do
		local name, pos = readname(dat, start)
		local qtype, qclass, ttl, rdlen, pos = unpack(">I2I2I4I2", dat, pos)
		local parse = parser[qtype]
		if parse then
			local rr = answers[name][qtype]
			rr[#rr + 1] = parse(dat, pos)
			ttl = now + ttl
			if rr.TTL > ttl then
				rr.TTL = ttl
			end
		end
		start = pos + rdlen
	end
	merge_answers()
end


do --parse hosts
	local f<close> = io.open(hosts)
	if f then
		for line in f:lines() do
			local ip, names = line:match("^%s*([%[%]%x%.%:]+)%s+([^#;]+)")
			if not ip or not names then
				goto continue
			end

			local typename = guesstype(ip)
			if typename == "NAME" then
				goto continue
			end

			for name in names:gmatch("%S+") do
				name = name:lower()
				local rr = answers[name][typename]
				rr[#rr + 1] = ip
			end
			::continue::
		end
		merge_answers()
	end
end

local function suspend(session, timeout)
	local co = core.running()
	wait_coroutine[session] = co
	core.fork(function()
		time.sleep(timeout)
		local co = wait_coroutine[session]
		if not co then
			return
		end
		wait_coroutine[session] = nil
		core.wakeup(co, false)
	end)
	return core.wait()
end

local function find_dns_server()
	local f<close> = io.open(resolv_conf, "r")
	if not f then
		return
	end
	for l in f:lines() do
		dns_server = l:match("^%s*nameserver%s+([^%s]+)")
		if dns_server then
			if dns_server:find(':') then
				dns_server = '[' .. dns_server .. ']'
			end
			dns_server = format("%s:53", dns_server)
			break
		end
	end
end

local function connectserver()
	if connectfd then
		return
	end
	if not dns_server then
		find_dns_server()
	end
	assert(dns_server)
	logger.info("[dns] server ip:", dns_server)
	local fd = udp.connect(dns_server)
	connectfd = fd
	core.fork(function()
		while true do
			local msg, err = udp.recvfrom(fd)
			if not msg then
				logger.info("[dns] udp error:", err)
				break
			end
			local ID, FLAG,
			QDCOUNT, ANCOUNT,
			NSCOUNT, ARCOUNT,
			QNAME,
			QTYPE, QCLASS, pos = unpack(parseformat, msg)
			answer(msg, pos, ANCOUNT)
			local co = wait_coroutine[ID]
			if not co then --already timeout
				return
			end
			wait_coroutine[ID] = nil
			core.wakeup(co, ANCOUNT > 0)
		end
		-- udp error, wakeup all
		for k, co in pairs(wait_coroutine) do
			core.wakeup(co, false)
			wait_coroutine[k] = nil
		end
		udp.close(connectfd)
		connectfd = nil
	end)
	return fd
end

local function query(name, typ, timeout)
	connectserver()
	if not connectfd then
		return false
	end
	local retry = 1
	local s, r = question(name, typ)
	--RFC 1123 #page-76, the default timeout
	--should be less than 5 seconds
	timeout = timeout or 5000
	while true do
		local ok = udp.sendto(connectfd, r)
		if not ok then
			return false
		end
		local ok = suspend(s, timeout)
		if ok then
			return ok
		end
		retry = retry + 1
		if retry > 3 then
			return false
		end
		time.sleep(timeout * retry)
	end
end

---@param name string
---@param qtype core.dns.type
---@return table|nil, string|nil
local function findcache(name, qtype)
	local now = timenow() // 1000
	for i = 1, 100 do
		local rrs = name_cache[name]
		if not rrs then
			return nil, nil
		end
		local rr = rrs[qtype]
		if rr and rr.TTL >= now then
			return rr, nil
		end
		local cname = rrs[RR_CNAME]
		if cname and cname.TTL >= now then
			name = cname[1]
		else
			return nil, nil
		end
	end
	return nil, nil
end

---@async
---@param name string
---@param qtype core.dns.type
---@param timeout integer|nil
---@param deep integer
---@return table|nil
local function resolve(name, qtype, timeout, deep)
	if deep > 100 then
		return nil
	end
	local rr, cname = findcache(name, qtype)
	if not rr and not cname then
		local res = query(name, qtype, timeout)
		if not res then
			return nil
		end
		rr, cname = findcache(name, qtype)
	end
	if cname then
		return resolve(cname, qtype, timeout, deep + 1)
	end
	return rr
end

---@alias core.dns.type `dns.A` | `dns.AAAA` | `dns.SRV`
---@class core.dns
local dns = {
	---@type core.dns.type
	A = RR_A,
	---@type core.dns.type
	AAAA = RR_AAAA,
	---@type core.dns.type
	SRV = RR_SRV,
}


---@async
---@param name string
---@param qtype core.dns.type
---@param timeout integer|nil
---@return string|nil
function dns.lookup(name, qtype, timeout)
	if guesstype(name) ~= RR_CNAME then
		return name
	end
	local rr = resolve(name, qtype, timeout, 1)
	if not rr then
		return nil
	end
	return rr[1]
end

---@async
---@param name string
---@param qtype core.dns.type
---@param timeout integer|nil
---@return table
function dns.resolve(name, qtype, timeout)
	if guesstype(name) ~= RR_CNAME then
		return {name}
	end
	return resolve(name, qtype, timeout, 1)
end

---@param ip string
function dns.server(ip)
	dns_server = ip
end

---@param name string
---@return boolean
function dns.isname(name)
	return guesstype(name) == RR_CNAME
end

return dns

