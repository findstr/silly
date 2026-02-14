local find = string.find
local byte = string.byte
local match = string.match

local M = {}
local PORT_PATTERN <const> = "[_%w]+"
local ADDR_PATTERN <const> = "^(.*):(" .. PORT_PATTERN .. ")$"
local BRACKET_ADDR_PATTERN <const> = "^%[([^%]]*)%]:(" .. PORT_PATTERN .. ")$"
local BRACKET_HOST_PATTERN <const> = "^%[([^%]]*)%]$"

---@param addr string
---@return string? host, string? port
function M.parse(addr)
	local host, port
	if byte(addr, 1) == 91 then -- '['
		host, port = match(addr, BRACKET_ADDR_PATTERN)
		if not host then
			host = match(addr, BRACKET_HOST_PATTERN)
		end
	else
		host, port = match(addr, ADDR_PATTERN)
		if not host then
			host = addr
		end
	end
	if host == "" then
		host = nil
	end
	return host, port
end

---@param host string?
---@param port string
---@return string
function M.join(host, port)
	if host == nil or host == "" then
		return ":" .. port
	end
	if byte(host, 1) ~= 91 and find(host, ":", 1, true) then
		return "[" .. host .. "]:" .. port
	end
	return host .. ":" .. port
end

local IPV4_PATTERN <const> = "^%d+%.%d+%.%d+%.%d+$"
---@param host string
---@return boolean
function M.isv4(host)
	return match(host, IPV4_PATTERN) ~= nil
end

---@param host string
---@return boolean
function M.isv6(host)
	return find(host, ":", 1, true) ~= nil
end

---@param host string
---@return boolean
function M.ishost(host)
	if host == "" then
		return false
	end
	if find(host, ":", 1, true) then -- IPv6
		return false
	end
	return match(host, IPV4_PATTERN) == nil
end

return M
