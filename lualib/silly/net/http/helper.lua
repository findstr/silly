local addr = require "silly.net.addr"

local pairs = pairs
local tonumber = tonumber
local type = type
local format = string.format
local gsub = string.gsub
local find = string.find
local sub = string.sub
local match = string.match
local gmatch = string.gmatch
local byte = string.byte
local concat = table.concat
local utf8char = utf8.char
local strchar = string.char
local parse_addr = addr.parse

local helper = {}

local html_unescape = {
	['quot'] = '"',
	['amp'] = '&',
	['lt'] = '<',
	['gt'] = '>',
	['nbsp'] = ' ',
}

function helper.htmlunescape(html)
	html = gsub(html, "&#(%d+);", function(s)
		return utf8char(tonumber(s, 10))
	end)
	html = gsub(html, "&(%a+);", html_unescape)
	return html
end

local function encode(val)
	return gsub(val, "([^0-9a-zA-Z$_%.!*(),-])", function(n)
		return format("%%%02X", byte(n, 1))
	end)
end

function helper.urlencode(val)
	if type(val) == "table" then
		local buf = {}
		for k, v in pairs(val) do
			buf[#buf+1] = format("%s=%s", encode(k), encode(v))
		end
		return concat(buf, "&")
	else
		return encode(val)
	end
end

local function urldecode(s)
	return gsub(s, "%%([0-9a-fA-F][0-9a-fA-F])", function (h)
		return strchar(tonumber(h, 16))
	end)
end

helper.urldecode = urldecode

local default_port = {
	["https"] = "443",
	["wss"] = "443",
	["http"] = "80",
	["ws"] = "80",
}


function helper.parseurl(url)
	local default = false
	local scheme, hostport, path = match(url, "^([^:]+)://([^/?]*)(.*)")
	if not scheme then
		return nil, "Invalid url"
	end
	if path == "" or byte(path, 1) == 63 then -- '?'
		path = "/" .. path
	end
	local host, port = parse_addr(hostport)
	if not host then
		return nil, "Invalid url"
	end
	if not port then
		port = default_port[scheme]
		if not port then
			return nil, "Unsupported scheme"
		end
		default = true
	end
	return scheme, host, port, path, default
end

function helper.parsetarget(target)
	local query = {}
	local start = find(target, "?", 1, true)
	if not start then
		return target, query
	end
	local path = sub(target, 1, start - 1)
	path = path == "" and "/" or path
	local querystring = sub(target, start + 1)
	if querystring ~= "" then
		for k, v in gmatch(querystring, "([^=&]+)=([^&]+)") do
			query[urldecode(k)] = urldecode(v)
		end
	end
	return path, query
end

return helper
