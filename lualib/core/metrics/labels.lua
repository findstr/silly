local assert = assert
local tostring = tostring
local concat = table.concat
global none

local M = {}

local buf = {}
local function compose(lnames, values)
	assert(#lnames == #values)
	local n = #lnames
	local j = 1
	for i = 1, n do
		buf[j] = lnames[i]
		buf[j + 1] = '="'
		buf[j + 2] = tostring(values[i])
		buf[j + 3] = '",'
		j = j + 4
	end
	buf[j-1] = '"'
	local str = concat(buf)
	for i = 1, #buf do
		buf[i] = nil
	end
	return str
end

function M.key(lcache, lnames, values)
	local n = #values
	for i = 1, n - 1 do
		local t = lcache[i]
		if not t then
			t = {}
			lcache[i] = t
		end
		lcache[i] = t
	end
	local value = values[n]
	local t = lcache[value]
	if not t then
		t = compose(lnames, values)
		lcache[value] = t
	end
	return t
end

return M

