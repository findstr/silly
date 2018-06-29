local format = string.format
local gsub = string.gsub
local char = string.char
local insert = table.insert
local concat = table.concat
local tonumber = tonumber

local helper = {}

local html_unescape = {
	['quot'] = '"',
	['amp'] = '&',
	['lt'] = '<',
	['gt'] = '>',
}

function helper.htmlunescape(html)
	html = gsub(html, "&#(%d+);", function(s)
		return char(tonumber(s))
	end)
	html = gsub(html, "&(%a+);", html_unescape)
	return html
end

function helper.urlencode(url)
	url = gsub(url, "([^0-9a-zA-Z$-_%.+!*(),])", function(n)
		local s = format("%%%02X", n:byte(1))
		return s
	end)
	return url
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

return helper

