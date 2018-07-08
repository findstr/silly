local core = require "sys.core"
local socket = require "sys.socket"
local assert = assert
local sub = string.sub
local concat = table.concat
local pack = string.pack
local unpack = string.unpack
local format = string.format
local match = string.match
local gmatch = string.gmatch

local dns = {}
local A = 1
local CNAME = 5
local AAAA = 28
local name_cache = {}
local wait_coroutine = {}
local weakmt = {__mode = "kv"}
local session = 0
local dns_server
local connectfd

setmetatable(name_cache, weakmt)

local timenow = core.monotonicsec

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

local buildformat = ">I2I2I2I2I2I2zI2I2"

local function formatname(name)
	local i = 0
	local n = {}
	for k in gmatch(name, "([^%.]+)") do
		i = i + 1
		n[i] = pack(">I1", #k) .. k
	end
	return concat(n)
end

local function question(name, typ)
	session = session + 1
	if typ == "AAAA" then
		typ = AAAA
	else
		typ = A
	end
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
	local QNAME = formatname(name)
	local QTYPE = typ
	local QCLASS = 1
	return ID, pack(buildformat,
			ID, FLAG,
			QDCOUNT, ANCOUNT,
			NSCOUNT, ARCOUNT,
			QNAME,
			QTYPE, QCLASS)
end

local function parsename(init, dat, pos, ptr)
	if ptr and ptr > 0xc000 then --ptr
		pos = ptr & 0x3fff
		return parsename(init, dat, pos + 1, nil)
	else	--normal
		local i = pos
		while i < #dat do
			local n = unpack(">I1", dat, i)
			if n >= 0xc0 then
				n = unpack(">I2", dat, i)
				i = i + 2
				return parsename(init, dat, i, n)
			elseif n == 0x00 then
				break
			else
				i = i + 1
				init = init .. sub(dat, i, i + n - 1) .. "."
				i = i + n;
			end
		end
		init = sub(init, 1, -2)
		return init
	end
end

local function answer(dat, pos, n)
	for i = 1, n do
		local ptr, qtype, qclass, ttl, rdlen, offset
			= unpack(">I2I2I2I4I2", dat, pos)
		if qtype == A then
			local src = parsename("", dat, pos)
			pos = offset + rdlen
			local d1, d2, d3, d4 =
				unpack(">I1I1I1I1", dat, offset)
			name_cache[src] = {
				TTL = timenow() + ttl,
				TYPE = "A",
				A = format("%d.%d.%d.%d", d1, d2, d3, d4),
			}
		elseif qtype == CNAME then
			local src = parsename("", dat, pos)
			local cname = parsename("", dat, offset)
			pos = offset + rdlen
			name_cache[src] = {
				TTL = timenow() + ttl,
				TYPE = "CNAME",
				CNAME = cname,
			}
		elseif qtype == AAAA then
			local src = parsename("", dat, pos)
			pos = offset + rdlen
			local x1, x2, x3, x4, x5, x6, x7, x8 =
				unpack(">I2I2I2I2I2I2I2I2", dat, offset)
			name_cache[src] = {
				TTL = timenow() + ttl,
				TYPE = "AAAA",
				AAAA = format("%x:%x:%x:%x:%x%x:%x:%x",
					x1, x2, x3, x4, x5, x6, x7, x8),
			}
		end
	end
end

local function callback(msg, _)
	local pos
	if msg then
		local ID, FLAG,
		QDCOUNT, ANCOUNT,
		NSCOUNT, ARCOUNT,
		QNAME,
		QTYPE, QCLASS, pos = unpack(buildformat, msg)
		answer(msg, pos, ANCOUNT)
		local co = wait_coroutine[ID]
		if not co then --already timeout
			return
		end
		wait_coroutine[ID] = nil
		core.wakeup(co, ANCOUNT > 0)
	else --udp closed
		for k, co in pairs(wait_coroutine) do
			core.wakeup(co, false)
			wait_coroutine[k] = nil
		end
		connectfd = nil
	end
end

local function suspend(session, timeout)
	local co = core.running()
	wait_coroutine[session] = co
	core.fork(function()
		core.sleep(timeout)
		local co = wait_coroutine[session]
		if not co then
			return
		end
		wait_coroutine[session] = nil
		core.wakeup(co, false)
	end)
	return core.wait()
end

local function connectserver()
	if not dns_server then
		local f = io.open("/etc/resolv.conf", "r")
		for l in f:lines() do
			dns_server = l:match("^%s*nameserver%s+([^%s]+)")
			if dns_server then
				dns_server = format("%s:53", dns_server)
				break
			end
		end
	end
	assert(dns_server)
	return socket.udp(dns_server, callback)
end

local function query(name, typ, timeout)
	if not connectfd then
		connectfd = connectserver()
	end
	assert(connectfd > 0)
	local retry = 1
	local s, r = question(name, typ)
	--RFC 1123 #page-76, the default timeout
	--should be less than 5 seconds
	timeout = timeout or 5000
	while true do
		local ok = socket.udpwrite(connectfd, r)
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
		core.sleep(timeout * retry)
	end
end

local function lookup(name)
	local d
	local now = timenow()
	for i = 1, 100 do
		d = name_cache[name]
		if not d then
			return nil, name
		end
		if d.TTL < now then
			name_cache[name] = nil
			return nil, name
		end
		if d.TYPE == "CNAME" then
			name = d.CNAME
		else
			return d
		end
	end
	return nil, name
end

local function isname(name)
	local right = name:match("([%x])", #name)
	if right then
		return false
	end
	return true
end

function dns.resolve(name, typ, timeout)
	if not isname(name) then
		return name
	end
	local d , cname = lookup(name)
	if not d then
		for i = 1, 100 do
			local res = query(cname, typ, timeout)
			if not res then
				return
			end
			d, cname = lookup(cname)
			if not cname then
				goto FIND
			end
		end
		return
	end
	::FIND::
	if typ then
		return d[typ], typ
	else
		return d.A or d.AAAA, d.TYPE
	end
end

function dns.server(ip)
	dns_server = ip
end

dns.isname = isname

return dns

