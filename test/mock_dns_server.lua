-- Mock UDP/TCP DNS server for testing

local task = require "silly.task"
local udp = require "silly.net.udp"
local tcp = require "silly.net.tcp"
local channel = require "silly.sync.channel"

local pack = string.pack
local unpack = string.unpack
local concat = table.concat
local sub = string.sub
local byte = string.byte
local ipairs = ipairs
local tonumber = tonumber
local setmetatable = setmetatable

local M = {}

-- DNS record type constants
M.A = 1
M.CNAME = 5
M.SOA = 6
M.AAAA = 28
M.SRV = 33

--- Encode a domain name to DNS wire format (length-prefixed labels)
---@param name string
---@return string
function M.encode_name(name)
	local parts = {}
	for label in name:gmatch("([^%.]+)") do
		parts[#parts + 1] = pack(">I1", #label)
		parts[#parts + 1] = label
	end
	parts[#parts + 1] = "\0"
	return concat(parts)
end

--- Decode a DNS query from raw UDP bytes
---@param data string
---@return table?, string? error
function M.decode_query(data)
	if #data < 12 then
		return nil, "packet too short"
	end
	-- Parse header (12 bytes)
	local id, flags, qdcount, ancount, nscount, arcount =
		unpack(">I2I2I2I2I2I2", data)
	-- Parse QNAME starting at byte 13
	local pos = 13
	local labels = {}
	while pos <= #data do
		local len = byte(data, pos)
		if len == 0 then
			pos = pos + 1
			break
		end
		if len >= 0xC0 then
			break -- compression pointer, unusual in queries
		end
		labels[#labels + 1] = sub(data, pos + 1, pos + len)
		pos = pos + 1 + len
	end
	local name = concat(labels, ".")
	-- Parse QTYPE and QCLASS
	if pos + 3 > #data then
		return nil, "truncated question"
	end
	local qtype, qclass = unpack(">I2I2", data, pos)
	return {
		id = id,
		flags = flags,
		name = name,
		qtype = qtype,
		qclass = qclass,
		arcount = arcount,
		raw = data,
		-- Offsets for echoing question section in response
		question_start = 13,
		question_end = pos + 3, -- end of QTYPE+QCLASS (inclusive)
	}
end

--- Encode an array of resource records into wire format parts.
---@param parts string[]  output accumulator
---@param rrs table[]     array of {type, name?, rdata, ttl?}
---@param default_name string  fallback name if rr has no explicit name
local function encode_rrs(parts, rrs, default_name)
	for _, ans in ipairs(rrs) do
		-- NAME
		parts[#parts + 1] = M.encode_name(ans.name or default_name)
		-- TYPE, CLASS, TTL
		parts[#parts + 1] = pack(">I2I2I4", ans.type, 1, ans.ttl or 300)
		-- RDATA
		local rdata
		if ans.type == M.A then
			local a, b, c, d = ans.rdata:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
			rdata = pack(">I1I1I1I1",
				tonumber(a), tonumber(b), tonumber(c), tonumber(d))
		elseif ans.type == M.AAAA then
			local groups = {}
			for g in ans.rdata:gmatch("([%x]+)") do
				groups[#groups + 1] = tonumber(g, 16)
			end
			rdata = pack(">I2I2I2I2I2I2I2I2",
				groups[1], groups[2], groups[3], groups[4],
				groups[5], groups[6], groups[7], groups[8])
		elseif ans.type == M.CNAME then
			rdata = M.encode_name(ans.rdata)
		elseif ans.type == M.SRV then
			local srv = ans.rdata
			rdata = pack(">I2I2I2", srv.priority, srv.weight, srv.port)
				.. M.encode_name(srv.target)
		elseif ans.type == M.SOA then
			local soa = ans.rdata
			rdata = M.encode_name(soa.mname or "ns1.mock.test")
				.. M.encode_name(soa.rname or "admin.mock.test")
				.. pack(">I4I4I4I4I4",
					soa.serial or 1,
					soa.refresh or 3600,
					soa.retry or 900,
					soa.expire or 604800,
					soa.minimum or 86400)
		else
			rdata = ans.rdata_raw or ""
		end
		-- RDLENGTH + RDATA
		parts[#parts + 1] = pack(">I2", #rdata)
		parts[#parts + 1] = rdata
	end
end

--- Build a DNS response packet
--- opts.answers: array of {type, name?, rdata, ttl?}
---   A rdata: "1.2.3.4"
---   AAAA rdata: "2001:0db8:..." (full 8-group hex)
---   CNAME rdata: "target.example.com"
---   SRV rdata: {priority, weight, port, target}
--- opts.additional: array of {type, name, rdata, ttl?} -- additional section RRs
--- opts.rcode: response code (default 0)
--- opts.tc: truncation flag (default false)
--- opts.qr: query/response flag (default 1 = response)
--- opts.aa: authoritative answer (default false)
---@param query table
---@param opts table?
---@return string
function M.build_response(query, opts)
	opts = opts or {}
	local answers = opts.answers or {}
	local authority = opts.authority or {}
	local additional = opts.additional or {}
	local rcode = opts.rcode or 0
	local tc = opts.tc and 1 or 0
	local qr = (opts.qr == nil) and 1 or opts.qr
	local aa = opts.aa and 1 or 0
	-- FLAGS: QR(1) OPCODE(4) AA(1) TC(1) RD(1) RA(1) Z(3) RCODE(4)
	local flags = (qr << 15) | (aa << 10) | (tc << 9)
		| (1 << 8) | (1 << 7) | rcode
	local parts = {}
	-- Header
	parts[#parts + 1] = pack(">I2I2I2I2I2I2",
		query.id, flags,
		1,              -- QDCOUNT
		#answers,       -- ANCOUNT
		#authority,     -- NSCOUNT
		#additional)    -- ARCOUNT
	-- Question section (echo from raw query)
	parts[#parts + 1] = sub(query.raw, query.question_start, query.question_end)
	-- Answer RRs
	encode_rrs(parts, answers, query.name)
	-- Authority RRs
	encode_rrs(parts, authority, query.name)
	-- Additional RRs
	encode_rrs(parts, additional, query.name)
	return concat(parts)
end

---@class MockDnsServer
---@field port integer
---@field conn silly.net.udp.conn?
---@field tcp_listener silly.net.tcp.listener?
---@field handler function?
---@field running boolean
---@field queries table[]
---@field query_ch silly.sync.channel
local Server = {}
local Server_mt = {__index = Server}

---@param port integer?
---@return MockDnsServer
function M.new(port)
	local server = {
		port = port or 15353,
		conn = nil,
		tcp_listener = nil,
		handler = nil,
		running = false,
		queries = {},
		query_ch = channel.new(),
	}
	return setmetatable(server, Server_mt)
end

---@param fn function
function Server:set_handler(fn)
	self.handler = fn
end

function Server:start()
	local addr = "127.0.0.1:" .. self.port
	local conn, err = udp.bind(addr)
	if not conn then
		error("mock_dns_server: bind " .. addr .. " failed: " .. tostring(err))
	end
	self.conn = conn
	self.running = true
	-- UDP receive loop
	task.fork(function()
		while self.running do
			local data, client_addr = self.conn:recvfrom(5000)
			if not data then
				goto continue
			end
			local query = M.decode_query(data)
			if not query then
				goto continue
			end
			-- Record query
			query.transport = "udp"
			query.client_addr = client_addr
			self.queries[#self.queries + 1] = query
			-- Notify waiters
			self.query_ch:push(#self.queries)
			-- Call handler
			if self.handler then
				local responded = false
				local function respond(opts)
					if responded then return end
					responded = true
					local response = M.build_response(query, opts)
					self.conn:sendto(response, client_addr)
				end
				local function respond_raw(raw_data)
					if responded then return end
					responded = true
					self.conn:sendto(raw_data, client_addr)
				end
				self.handler(query, respond, respond_raw)
			end
			::continue::
		end
	end)
	-- TCP listener for DNS-over-TCP (TC fallback)
	self.tcp_listener = tcp.listen {
		addr = addr,
		accept = function(conn)
			while true do
				local len_data = conn:read(2)
				if not len_data or len_data == "" then
					break
				end
				local len = unpack(">I2", len_data)
				if len == 0 then break end
				local data = conn:read(len)
				if not data or data == "" then
					break
				end
				local query = M.decode_query(data)
				if not query then
					goto continue
				end
				query.transport = "tcp"
				self.queries[#self.queries + 1] = query
				self.query_ch:push(#self.queries)
				if self.handler then
					local responded = false
					local function respond(opts)
						if responded then return end
						responded = true
						local response = M.build_response(query, opts)
						conn:write(pack(">I2", #response) .. response)
					end
					local function respond_raw(raw_data)
						if responded then return end
						responded = true
						conn:write(pack(">I2", #raw_data) .. raw_data)
					end
					self.handler(query, respond, respond_raw)
				end
				::continue::
			end
			conn:close()
		end
	}
end

function Server:stop()
	self.running = false
	if self.conn then
		self.conn:close()
		self.conn = nil
	end
	if self.tcp_listener then
		self.tcp_listener:close()
		self.tcp_listener = nil
	end
end

function Server:reset()
	self.queries = {}
	self.handler = nil
	self.query_ch = channel.new()
end

function Server:get_queries()
	return self.queries
end

--- Block until at least n queries have been received
---@param n integer
function Server:wait_query(n)
	while #self.queries < n do
		self.query_ch:pop()
	end
end

return M
