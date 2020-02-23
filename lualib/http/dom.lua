local M = {}
local tconcat = table.concat
local tremove = table.remove
local nexttoken
local tag = [["'</>=]]
local T = {
[tag:byte(1)] = function(str, start) -- "
	local e = str:find('[^\\]"', start)
	return str:sub(start+1, e), e + 2
end,
[tag:byte(2)] = function(str, start) -- '
	local e = str:find("[^\\]'", start)
	return str:sub(start+1, e), e + 2
end,
[tag:byte(3)] = function(str, start) -- <
	local n = str:byte(start + 1)
	local s = "!/-"
	if n == s:byte(1) then
		if str:byte(start + 2) == s:byte(3) then -- comment
			local _, e = str:find("-->", start + 4, true)
			return nexttoken(str, e + 1)
		else
			local e = str:find(">", start + 1)
			return nexttoken(str, e + 1)
		end
	elseif n == s:byte(2) then
		return "</", start + 2
	end
	return "<", start + 1
end,
[tag:byte(4)] = function(str, start) -- /
	if str:byte(start + 1) == tag:byte(5) then --/>
		return "/>", start + 2
	end
	return "/", start + 1
end,
[tag:byte(5)] = function(str, start) -- >
	return ">", start + 1
end,
[tag:byte(6)] = function(str, start) -- =
	return "=", start + 1
end,
}

local function plain(str, start)
	local e = str:find("[%s><=/]", start)
	assert(e > start)
	return str:sub(start, e - 1), e
end

local function nexttext(str, start)
	local start = str:find('[^%s]', start)
	if not start then
		return nil
	end
	local e = str:find("<", start)
	assert(e > start)
	return str:sub(start, e - 1), e
end


function nexttoken(str, start)
	local start = str:find('[^%s]', start)
	if not start then
		return nil
	end
	local n = str:byte(start)
	local func = T[n]
	if not func then --plain
		func = plain
	end
	return func(str, start)
end

local node = {
	value = function(self, buffer)
		for _, v in pairs(self.child) do
			if type(v) == "string" then
				buffer[#buffer + 1] = v
			else
				v:value(buffer)
			end
		end
	end,
	text = function(self)
		local tbl = {}
		self:value(tbl)
		return tconcat(tbl)
	end,
	match = function(self, cond)
		local match = true
		local class = cond.class
		if class then
			match = false
			for _, v in pairs(self.class) do
				if v == class then
					match = true
					break
				end
			end
		end
		local id = cond.id
		if match and id and self.attr["id"] ~= id then
			match = false
		end
		local name = cond.name
		if match and name and self.name ~= name then
			match = false
		end
		return match
	end,
	select = function(self, method)
		local out = {}
		local childs = {}
		local cond = {
			name = nil,
			id = nil,
			class = nil,
		}
		local pattern = ".#"
		for k in method:gmatch("([.#]-[^.#%s]+)") do
			local n = k:byte(1)
			if n == pattern:byte(1) then --.
				cond.class = k:sub(2)
			elseif n == pattern:byte(2) then --#
				cond.id = k:sub(2)
			else
				cond.name = k
			end
		end
		local type, pairs = type, pairs
		local nodes = {self}
		while true do
			local n = tremove(nodes, 1)
			if not n then
				break
			end
			for _, v in pairs(n.child) do
				if type(v) == "table" then
					nodes[#nodes + 1] = v
				end
			end
			if n:match(cond) then
				out[#out + 1] = n
			end
		end
		return out
	end,
	selectn = function(self, method, level)
		local item = self
		for i = 1, level - 1 do
			item = item:select(method)[1]
		end
		return item:select(method)
	end
}

local nodemt = {__index = node}
local selfclose = {
	["META"] = true,
	["LINK"] = true,
	["INPUT"] = true,
	["IMG"] = true,
	["BR"] = true,
	["HR"] = true,
}

local html_unescape = {
	['quot'] = '"',
	['amp'] = '&',
	['lt'] = '<',
	['gt'] = '>',
	['nbsp'] = ' ',
}

function htmlunescape(html)
	html = string.gsub(html, "&#(%d+);", function(s)
		return utf8.char(tonumber(s))
	end)
	html = string.gsub(html, "&(%a+);", html_unescape)
	return html
end

local function parsenode(str, start)
	--open tag
	local tk, name, back
	tk, start = nexttoken(str, start)
	if not tk then
		return
	end
	assert(tk == "<")
	name, start = nexttoken(str, start)
	local attr = {}
	local class = {}
	local child = {}
	local obj = setmetatable({
		name = name,
		attr = attr,
		class = class,
		child = child,
	}, nodemt)
	--attribute
	while true do
		local x, val
		tk, start = nexttoken(str, start)
		if tk == ">" or tk == "/>" then
			break
		end
		back = start
		x, start = nexttoken(str, start)
		if x == "=" then
			local v
			v, start = nexttoken(str, start)
			if tk == "class" then
				for c in v:gmatch("[^%s]+") do
					class[#class + 1] = c
				end
				local a = attr[tk]
				if a then
					v = a .. " " .. v
				end
				attr[tk] = v

			else
				attr[tk] = v
			end
		else
			attr[tk] = true
			start = back
		end
	end
	if tk == "/>" or selfclose[name:upper()] then
		return obj, start
	end
	assert(tk == ">")
	if name == "script" then
		local s, e = str:find("</script>", start)
		child[#child + 1] = str:sub(start, s-1);
		return obj, e + 1
	elseif name == "style" then
		local s, e = str:find("</style>", start)
		child[#child + 1] = str:sub(start, s-1);
		return obj, e + 1
	end
	--child
	while true do
		local tk
		back = start
		tk, start = nexttoken(str, start)
		if not tk then
			break
		elseif tk == "<" then --open
			child[#child + 1], start = parsenode(str, back)
		elseif tk == "</" then --close
			name, start = nexttoken(str, start)
			tk, start = nexttoken(str, start)
			assert(tk, ">")
			if name ~= obj.name then
				start = back
			end
			break
		else
			tk, start = nexttext(str, back)
			local raw = htmlunescape(tk)
			child[#child + 1] = raw
		end
	end
	return obj, start
end

M.parse = function(str)
	local ok, node = pcall(parsenode, str, 1)
	if ok then
		return node
	else
		return nil, node
	end
end

return M
