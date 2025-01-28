local format = string.format
local gsub = string.gsub
local find = string.find
local sub = string.sub
local match = string.match
local gmatch = string.gmatch
local insert = table.insert
local concat = table.concat
local char = utf8.char
local pairs = pairs
local tonumber = tonumber
local type = type

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
		return char(tonumber(s, 10))
	end)
	html = gsub(html, "&(%a+);", html_unescape)
	return html
end

local function encode(val)
	return gsub(val, "([^0-9a-zA-Z$_%.!*(),-])", function(n)
		return format("%%%02X", n:byte(1))
	end)
end

function helper.urlencode(val)
	if type(val) == "table" then
		local buf = {}
		for k, v in pairs(val) do
			v = encode(v)
			buf[#buf+1] = format("%s=%s", k, v)
		end
		return concat(buf, "&")
	else
		return encode(val)
	end
end

function helper.urldecode(url)
	url = gsub(url, "%%([0-9A-Fa-F][0-9A-Fa-F])", function (s)
		return char(tonumber(s, 16))
	end)
	return url
end

function helper.setcookie(header, cookie)
	local c = header['Set-Cookie']
	if c then
		insert(cookie, c)
	end
end

function helper.getcookie(cookie)
	return "Cookie:" .. concat(cookie, ";")
end

local default_port = {
	["https"] = "443",
	["wss"] = "443",
	["http"] = "80",
	["ws"] = "80",
}


function helper.parseurl(url)
	local default = false
	local scheme, host, port, path= match(url, "^([^:]+)://([^:/]+):?(%d*)(.*)")
	if path == "" then
		path = "/"
	end
	if port == "" then
		port = default_port[scheme]
		if not port then
			assert(false, "unsupport parse url scheme:" .. scheme)
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
	assert(start > 1)
	local path = sub(target, 1, start - 1)
	local f = sub(target, start + 1)
	for k, v in gmatch(f, "([^=&]+)=([^&]+)") do
		query[k] = v
	end
	return path, query
end

return helper

