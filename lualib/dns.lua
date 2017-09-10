local socket = require "socket"
local core = require "silly.core"

local dns = {}
local dns_server = "192.168.1.1@53"
local domain_cache = {}
local wait_coroutine = {}
local weakmt = {__mode = "kv"}
local connectfd = -1
local session = 0

setmetatable(domain_cache, weakmt)

local function timenow()
	return math.floor(core.monotonic() / 1000)
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

local buildformat = ">I2I2I2I2I2I2zI2I2"

local function formatdomain(domain)
	local n = ""
	for k in string.gmatch(domain, "([^%.]+)") do
		n = n .. string.pack("<I1", #k) .. k
	end
	return n
end

local function build_request(domain)
	session = session + 1
	local req = {
		ID = session,

		--[[
		QR = 0,
		OPCODE = 0, (4bit)
		AA = 0,
		TC = 0,
		RD = 1,
		RA = 0,
		--3 bit zero
		RCCODE = 0,
		]]--
		FLAG = 0x0100,

		QDCOUNT = 1,
		ANCOUNT = 0,
		NSCOUNT = 0,
		ARCOUNT = 0,

		QNAME = formatdomain(domain),
		QTYPE = 1,
		QCLASS = 1,
	}

	return req.ID, string.pack(buildformat,
			req.ID, req.FLAG,
			req.QDCOUNT, req.ANCOUNT,
			req.NSCOUNT, req.ARCOUNT,
			req.QNAME,
			req.QTYPE, req.QCLASS
			)
end

local function parsename(init, dat, pos, ptr)
	if ptr and ptr > 0xc000 then --ptr
		pos = ptr & 0x3fff
		return parsename(init, dat, pos + 1, nil)
	else	--normal
		local i = pos
		while i < #dat do
			local n = string.unpack(">I1", dat, i)
			if n >= 0xc0 then
				n = string.unpack(">I2", dat, i)
				i = i + 2
				return parsename(init, dat, i, n)
			elseif n == 0x00 then
				break
			else
				i = i + 1
				init = init .. string.sub(dat, i, i + n - 1) .. "."
				i = i + n;
			end
		end
		init = string.sub(init, 1, -2)
		return init
	end
end

local function desc(dat, pos, n)
	for i = 1, n do
		local ptr, qtype, qclass, ttl, rdlen, offset= string.unpack(">I2I2I2I4I2", dat, pos)
		if qtype == 5 then --cname
			local src = parsename("", dat, pos)
			local cname = parsename("", dat, offset)
			pos = offset + rdlen
			domain_cache[src] = {
				ttl = timenow() + ttl,
				type = "cname",
				addr = cname,
			}
		elseif qtype == 1 then --ip
			local src = parsename("", dat, pos)
			pos = offset + rdlen
			local seg1, seg2, seg3, seg4 = string.unpack("<I1I1I1I1", dat, offset)
			domain_cache[src] = {
				ttl = timenow() + ttl,
				type = "ip",
				addr = string.format("%d.%d.%d.%d", seg1, seg2, seg3, seg4),
			}
		end
	end
end

local function callback(msg, addr)
	local res = {}
	local pos
	if not msg then --udp closed
		connectfd = -1
		return
	end
	res.ID, res.FLAG,
	res.QDCOUNT, res.ANCOUNT,
	res.NSCOUNT, res.ARCOUNT,
	res.QNAME,
	res.QTYPE, res.QCLASS, pos = string.unpack(buildformat, msg)
	desc(msg, pos, res.ANCOUNT)
	local co = wait_coroutine[res.ID]
	if not co then --already timeout
		return
	end
	wait_coroutine[res.ID] = nil
	core.wakeup(co, true)
end

local query_request

function query(domain, timeout)
	local d = domain_cache[domain]
	if not d then
		return nil
	end
	if d.ttl < timenow() then
		domain_cache[domain] = nil
		return nil
	end
	if d.type == "cname" then
		return query_request(d.addr, timeout)
	else
		return d.addr
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

local function checkconnect()
	if connectfd >= 0 then
		return connectfd
	end
	return socket.udp(dns_server, callback)
end

function query_request(domain, timeout)
	local res = query(domain)
	if res then
		return res
	end
	timeout = timeout or 1000
	local s, r = build_request(domain)
	local fd = checkconnect()
	local i = 1
	assert(fd > 0)
	while true do
		local ok = socket.udpwrite(fd, r)
		if not ok then
			return nil
		end
		local ok = suspend(s, timeout)
		if ok then
			return query(domain, timeout)
		end
		i = i + 1
		if i > 3 then
			return nil
		end
		core.sleep(timeout * i)
	end
end

--all query use one udp connecction, so need no close
dns.query = query_request

function dns.isdomain(addr)
	local s1, s2, s3, s4 = string.match(addr, "(%d+).(%d+).(%d+).(%d+)")
	if s1 and s2 and s3 and s4 then
		return false
	end
	return true
end

function dns.server(ip)
	dns_server = ip
end

return dns

