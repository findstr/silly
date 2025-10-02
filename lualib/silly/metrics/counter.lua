local labels = require "silly.metrics.labels"
---@class silly.metrics.counter_mt : silly.metrics.collector
local M = {}

---@class silly.metrics.countersub : silly.metrics.counter_mt
---@field value number?

---@class silly.metrics.counter : silly.metrics.countersub
---@field name string
---@field help string
---@field kind string

---@class silly.metrics.countervec : silly.metrics.counter_mt
---@field labelnames string[]
---@field labelcache table<string|number, table>
---@field metrics table<string, silly.metrics.countersub>

local mt = {__index = M}

local setmetatable = setmetatable

---@param self silly.metrics.countersub
---@param v number
function M:add(v)
	assert(v >= 0, "Counter can only increase")
	self.value = self.value + v
end

---@param self silly.metrics.countersub
function M:inc()
	self.value = self.value + 1
end

---@param self silly.metrics.counter
---@param buf silly.metrics.metric[]
function M.collect(self, buf)
	buf[#buf+1] = self
end

---@param self silly.metrics.countervec
---@param ... string|number
---@return silly.metrics.countersub
function M.labels(self, ...)
	local metrics = self.metrics
	local k = labels.key(self.labelcache, self.labelnames, {...})
	local c = metrics[k]
	if not c then
		c = setmetatable({
			value = 0,
		}, mt)
		metrics[k] = c
	end
	return c
end

---@param name string
---@param help string
---@param labelnames string[]?
---@return silly.metrics.counter | silly.metrics.countervec
local function new (name, help, labelnames)
	if not labelnames then
		return setmetatable({
			name = name,
			help = help,
			kind = "counter",
			value = 0,	--the value
		}, mt)
	end
	return setmetatable({
		name = name,
		help = help,
		kind = "counter",
		metrics = {},
		labelnames = labelnames,
		labelcache = {},
	}, mt)
end

return new
