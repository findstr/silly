local labels = require "core.metrics.labels"
---@class core.metrics.counter_mt : core.metrics.collector
local M = {}

---@class core.metrics.countersub : core.metrics.counter_mt
---@field value number?

---@class core.metrics.counter : core.metrics.countersub
---@field name string
---@field help string
---@field kind string

---@class core.metrics.countervec : core.metrics.counter_mt
---@field labelnames string[]
---@field labelcache table<string|number, table>
---@field metrics table<string, core.metrics.countersub>

local mt = {__index = M}

local setmetatable = setmetatable

---@param self core.metrics.countersub
---@param v number
function M:add(v)
	assert(v >= 0, "Counter can only increase")
	self.value = self.value + v
end

---@param self core.metrics.countersub
function M:inc()
	self.value = self.value + 1
end

---@param self core.metrics.counter
---@param buf core.metrics.metric[]
function M.collect(self, buf)
	buf[#buf+1] = self
end

---@param self core.metrics.countervec
---@param ... string|number
---@return core.metrics.countersub
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
---@return core.metrics.counter | core.metrics.countervec
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
