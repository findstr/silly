local M = {}
local remove = table.remove
local setmetatable = setmetatable

local mt = {__index = M}


function M:new()
	return setmetatable({metrics = {}}, mt)
end

function M:register(obj)
	for i = 1, #self do
		if self[i] == obj then
			return
		end
	end
	self[#self + 1] = obj
end

function M:unregister(obj)
	for i = 1, #self do
		if self[i] == obj then
			remove(self, i)
			return
		end
	end
end

function M:collect()
	local len = 0
	local metrics = self.metrics
	for i = 1, #self do
		len = self[i]:collect(metrics, len)
	end
	for i = len+1, #metrics do
		metrics[i] = nil
	end
	return metrics
end

return M

