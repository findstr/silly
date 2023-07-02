local M = {}

local assert = assert
local setmetatable = setmetatable

function M:set(v)
	self[1] = v
end

function M:add(v)
	assert(v >= 0)
	self[1] = self[1] + v
end

function M:inc()
	self[1] = self[1] + 1
end

function M:sub(v)
	self[1] = self[1] - v
end

function M:dec()
	self[1] = self[1] - 1
end

function M.new(kind, mt, label_mt)
	assert(kind, "kind")
	assert(mt, "mt")
	assert(label_mt, "label_mt")
	return function(name, help, labels)
		local obj
		if labels then
			obj = setmetatable({
				name = name,
				help = help,
				kind = kind,
				labelnames = labels,
			}, label_mt)
		else
			obj = setmetatable({
				name = name,
				help = help,
				kind = kind,
				[1] = 0,	--the count value
			}, mt)
		end
		return obj
	end
end

function M.collect(self, buf, len)
	len = len + 1
	buf[len] = self
	return len
end

return M
