---@class silly.metrics.registry
---@field [integer] silly.metrics.collector
local M = {}
local mt = {__index = M}

local remove = table.remove
local setmetatable = setmetatable

---@return silly.metrics.registry
function M.new()
	return setmetatable({}, mt)
end

---@param obj silly.metrics.collector
function M:register(obj)
	for i = 1, #self do
		if self[i] == obj then
			return
		end
	end
	self[#self + 1] = obj
end

---@param obj silly.metrics.collector
function M:unregister(obj)
	for i = 1, #self do
		if self[i] == obj then
			remove(self, i)
			return
		end
	end
end

---@return silly.metrics.metric[]
function M:collect()
	local metrics = {}
	for i = 1, #self do
		self[i]:collect(metrics)
	end
	return metrics
end

return M

