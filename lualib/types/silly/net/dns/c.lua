---@meta silly.net.dns.c

---@class silly.net.dns.c
local M = {}

---Read the system resolv.conf and return its raw content.
---On Unix reads /etc/resolv.conf; on Windows synthesizes equivalent content
---from GetNetworkParams().
---@return string?
function M.resolvconf() end

---Read the system hosts file and return its raw content.
---On Unix reads /etc/hosts; on Windows reads %SystemRoot%\System32\drivers\etc\hosts.
---@return string?
function M.hosts() end

---Count the number of dots in `name`.
---@param name string
---@return integer
function M.dotcount(name) end

---Build a DNS query packet (header + QNAME + QTYPE/QCLASS + EDNS0 OPT).
---@param name string  domain name (dotted notation)
---@param qtype integer  query type (1=A, 28=AAAA, 33=SRV)
---@param id integer  query ID (0-65535)
---@return string  wire-format query packet
function M.question(name, qtype, id) end

---Validate a domain name (RFC 1035 §2.3.4).
---@param name string
---@return boolean
function M.validname(name) end

---Parse a complete DNS response: header, question section, and resource records.
---Returns nil (single value) on any parse failure (too short, QR=0, qdcount≠1,
---malformed question name, or RR count overflow).
---@param msg string  full DNS response packet
---@return integer id, string name, integer qtype, boolean tc, {[1]:string, [2]:integer, [3]:integer, [4]:(string|table)?}[]? records
function M.answer(msg) end

return M
