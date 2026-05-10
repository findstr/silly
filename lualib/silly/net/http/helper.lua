local gsub = string.gsub
local find = string.find
local sub = string.sub
local format = string.format
local byte = string.byte
local utf8char = utf8.char
local tonumber = tonumber
local parsequery = require "silly.net.http.url".parsequery

global _

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

---Parse an HTTP request target into path and query components.
---@param target string
---@return string path, table<string, string> query
function helper.parsetarget(target)
	local start = find(target, "?", 1, true)
	if not start then
		return target, {}
	end
	local path = sub(target, 1, start - 1)
	path = path == "" and "/" or path
	local querystring = sub(target, start + 1)
	return path, parsequery(querystring)
end

return helper
