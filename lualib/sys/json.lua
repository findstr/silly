local tconcat = table.concat
local format = string.format
local find = string.find
local json = {}

---------encode
local encode_func

local function encodebool(b)
	return b and "true" or "false"
end
local function encodenumber(n)
	return tostring(n)
end
local function encodestring(s)
	return format('"%s"', s) --TODO: escape
end
local function encodeobj(obj)
	if obj[1] ~= nil or next(obj) == nil then --array
		local str = {}
		for _, v in ipairs(obj) do
			v = encode_func[type(v)](v)
			str[#str + 1] = v
		end
		return format("[%s]", tconcat(str, ","))
	else --object
		local str = {}
		for k, v in pairs(obj) do
			v = encode_func[type(v)](v)
			str[#str + 1] = format("%s:%s", encodestring(k), v)
		end
		return format("{%s}", tconcat(str, ","))
	end
end

encode_func = {
	['table'] = encodeobj,
	['boolean'] = encodebool,
	['number'] = encodenumber,
	['string'] = encodestring,
}
----------decode

-- { -> 0x7b , } -> 0x7D, [ -> 0x5B, ] -> 0x5D, : -> 0x3A, " -> 0x22

local decode_func
local function skipspace(str, i)
	return find(str, "[^%s]", i)
end
local function decodestr(str, i)
	local s = find(str, '"', i + 1, true)
	return str:sub(i + 1, s - 1), s + 1
end
local function decodebool(str, i)
	local n = find(str, "[%s,}]", i)
	local k = str:sub(i, n - 1)
	if k == "true" then
		return true, n
	elseif k == "false" then
		return false, n
	else
		assert(false, k)
	end
end
local function decodenumber(str, i)
	local n = find(str, "[%s,}]", i)
	local k = str:sub(i, n - 1)
	return tonumber(k), n
end
local function decodeobj(str, i)
	local s
	local len = #str
	local obj = {}
	i = skipspace(str, i)
	if str:byte(i) ~= 0x7b then -- '{'
		assert(false, [[need '{']])
	end
	i = i + 1
	while true do
		local v
		i = skipspace(str, i)
		local ch = str:byte(i)
		if ch == 0x7D then -- '}'
			break
		end
		if ch ~= 0x22 then -- '"'
			assert(false, [[need '"']])
		end
		s = i + 1
		i = find(str, '"', s, true)
		local k = str:sub(s, i - 1)
		i = skipspace(str, i + 1)
		if str:byte(i) ~= 0x3A then
			assert(false, [[need ':']])
		end
		i = skipspace(str, i + 1)
		local n = str:byte(i)
		v, i = assert(decode_func[n], n)(str, i)
		obj[k] = v
		i = skipspace(str, i)
		if str:byte(i) == 0x2C then -- ','
			i = i + 1
		end
	end
	return obj, i + 1
end

local function decodearr(str, i)
	local ai = 0
	local arr = {}
	i = i + 1
	while true do
		i = skipspace(str, i)
		local ch = str:byte(i)
		if ch == 0x5D then -- ']'
			break
		end
		ai = ai + 1
		arr[ai], i = assert(decode_func[ch], ch)(str, i)
		i = skipspace(str, i)
		if str:byte(i) == 0x2C then -- ','
			i = i + 1
		end
	end
	return arr, i + 1
end

decode_func = {
	[0x7b] = decodeobj,
	[0x5b] = decodearr,
	[0x22] = decodestr,
	[0x66] = decodebool,
	[0x74] = decodebool,
}
for i = 0x30, 0x39 do
	decode_func[i] = decodenumber
end

---------interface
function json.encode(obj)
	return encodeobj(obj)
end
function json.decode(str)
	local ok, obj, i = pcall(decodeobj, str, 1)
	if not ok then
		return nil, obj
	end
	return obj, i
end

return json


