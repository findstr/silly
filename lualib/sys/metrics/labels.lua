local assert = assert
local sort = table.sort
local concat = table.concat
local format = string.format
local setmetatable = setmetatable

local cmp = function(a, b)
	return a[2] < b[2]
end
local function labels(mt)
	return function(self, ...)
		local labels = self.labelnames
		local buf = {}
		local values = {...}
		for i = 1, #labels do
			local val = assert(values[i])
			buf[i] = format('%s="%s"', labels[i], val)
		end
		local key = '{' .. concat(buf, ',') .. '}'
		for i = 1, #self do
			local value = self[i]
			if value[2] == key then
				return value
			end
		end
		local value = setmetatable({
			name = self.name,
			help = self.help,
			[1] = 0,
			[2] = key
		}, mt)
		self[#self + 1] = value
		sort(self, cmp)
		return value
	end
end

return labels

