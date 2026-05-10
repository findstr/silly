local addr = require "silly.net.addr"

local pairs = pairs
local type = type
local tonumber = tonumber
local format = string.format
local gsub = string.gsub
local sub = string.sub
local match = string.match
local gmatch = string.gmatch
local byte = string.byte
local concat = table.concat
local strchar = string.char
local lower = string.lower
local parse_addr = addr.parse
local join_addr = addr.join

global _

local M = {}

--- @class silly.net.http.url.parts
--- @field scheme string
--- @field host string       hostname only (no port)
--- @field port string       port as string
--- @field authority string  "host" or "host:port" — for Host/:authority header
--- @field path string       request target (path + query + fragment)

local default_port = {
	["https"] = "443",
	["wss"] = "443",
	["http"] = "80",
	["ws"] = "80",
}

local function makeurl(scheme, host, port, path)
	scheme = lower(scheme)
	host = lower(host)
	if not port then
		port = default_port[scheme]
		if not port then
			return nil, "Unsupported scheme"
		end
	end
	local authority
	if default_port[scheme] ~= port then
		authority = join_addr(host, port)
	else
		authority = join_addr(host)
	end
	return {
		scheme = scheme,
		host = host,
		port = port,
		authority = authority,
		path = path,
	}
end

local function parsehostport(scheme, hostport, path)
	if path == "" or byte(path, 1) == 63 then -- '?'
		path = "/" .. path
	end
	local host, port = parse_addr(hostport)
	if not host then
		return nil, "Invalid url"
	end
	return makeurl(scheme, host, port, path)
end

---Parse a URL into a structured object.
---@param url string
---@return silly.net.http.url.parts? result, string? error
function M.parse(url)
	local scheme, hostport, path = match(url, "^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?]*)(.*)")
	if not scheme then
		return nil, "Invalid url"
	end
	return parsehostport(scheme, hostport, path)
end

---Resolve a reference against a base URL (RFC 3986 Section 5).
---@param base_url string
---@param ref string
---@return silly.net.http.url.parts? result, string? error
function M.resolve(base_url, ref)
	-- absolute URL
	local scheme, hostport, path = match(ref, "^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?]*)(.*)")
	if scheme then
		return parsehostport(scheme, hostport, path)
	end
	-- parse base for non-absolute refs
	local bscheme, bhostport, bpath = match(base_url, "^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?]*)(.*)")
	if not bscheme then
		return nil, "Invalid base url"
	end
	if bpath == "" or byte(bpath, 1) == 63 then -- '?'
		bpath = "/" .. bpath
	end
	local ref_first, ref_second = byte(ref, 1), byte(ref, 2)
	-- protocol-relative
	if ref_first == 47 and ref_second == 47 then -- '//'
		local hostport, path = match(ref, "^//([^/?]*)(.*)")
		return parsehostport(bscheme, hostport, path)
	end
	-- same origin, resolve path
	local bhost, bport = parse_addr(bhostport)
	if not bhost then
		return nil, "Invalid url"
	end
	-- query-only
	if ref_first == 63 then -- '?'
		return makeurl(bscheme, bhost, bport, match(bpath, "^([^?#]*)") .. ref)
	end
	-- fragment-only
	if ref_first == 35 then -- '#'
		return makeurl(bscheme, bhost, bport, match(bpath, "^([^#]*)") .. ref)
	end
	-- root-relative
	if ref_first == 47 then -- '/'
		return makeurl(bscheme, bhost, bport, ref)
	end
	-- path-relative
	-- dot segments (../  ./) are not normalized; extremely rare in HTTP redirects.
	-- servers/routers that care should normalize the request target themselves (RFC 9112 §3.6).
	local dir = match(bpath, "^(.*/)")
	return makeurl(bscheme, bhost, bport, (dir or "/") .. ref)
end

---Reconstruct the full URL string from a parsed url object.
---@param u silly.net.http.url.parts
---@return string
function M.build(u)
	return format("%s://%s%s", u.scheme, u.authority, u.path)
end

-- RFC 3986 path: unreserved / pct-encoded / sub-delims / ":" / "@" / "/"
local function pathescapechar(val)
	return gsub(val, "([^0-9a-zA-Z$_%.!*(),;:@&=+~/%-])", function(n)
		return format("%%%02X", byte(n, 1))
	end)
end

-- application/x-www-form-urlencoded: unreserved + "*", "-", ".", "_"
-- "*" is a sub-delimiter (RFC 3986 Section 2.2) left unencoded in query strings
-- spaces become "+"
local function queryescapechar(val)
	return gsub(val, "([^0-9a-zA-Z%*%-%._])", function(n)
		if n == " " then
			return "+"
		end
		return format("%%%02X", byte(n, 1))
	end)
end

---Percent-encode a string for use in URL path segments (RFC 3986).
---@param val string
---@return string
function M.pathescape(val)
	return pathescapechar(val)
end

---Encode a string or table for use in URL query strings (application/x-www-form-urlencoded).
---@param val string|table<string, string>
---@return string
function M.queryescape(val)
	if type(val) == "table" then
		local buf = {}
		for k, v in pairs(val) do
			buf[#buf + 1] = format("%s=%s", queryescapechar(k), queryescapechar(v))
		end
		return concat(buf, "&")
	end
	return queryescapechar(val)
end

---Percent-decode a string (RFC 3986). Only handles %XX sequences.
---@param s string
---@return string
local function pathunescape(s)
	return gsub(s, "%%([0-9a-fA-F][0-9a-fA-F])", function(h)
		return strchar(tonumber(h, 16))
	end)
end

---Percent-decode a string for query context. Handles %XX and converts '+' to space.
---@param s string
---@return string
local function queryunescape(s)
	return pathunescape(gsub(s, "%+", " "))
end

---Parse a query string into a key-value table (like Go's url.ParseQuery).
---@param query string
---@return table<string, string> result
function M.parsequery(query)
	local result = {}
	if query and query ~= "" then
		for k, v in gmatch(query, "([^=&]+)=?([^&]*)") do
			result[queryunescape(k)] = queryunescape(v)
		end
	end
	return result
end


M.pathunescape = pathunescape
M.queryunescape = queryunescape

return M
