local labels = require "core.metrics.labels"
---@class core.metrics.gauge_mt : core.metrics.collector
local M = {}

---@class core.metrics.gaugesub : core.metrics.gauge_mt
---@field value number?

---@class core.metrics.gauge : core.metrics.gaugesub
---@field name string
---@field help string
---@field kind string
---@field value number?

---@class core.metrics.gaugevec : core.metrics.gauge_mt
---@field labelnames string[]
---@field labelcache table<string|number, table>
---@field metrics table<string, core.metrics.gaugesub>

local mt = {__index = M}

local setmetatable = setmetatable

---@param self core.metrics.gaugesub
---@param v number
function M:set(v)
	self.value = v
end

---@param self core.metrics.gauge
---@param v number
function M:add(v)
	self.value = self.value + 1
end
function M:inc()
	self.value = self.value + 1
end
---@param v number
function M:sub(v)
	self.value = self.value - v
end
function M:dec()
	self.value = self.value - 1
end

---@param self core.metrics.gauge
---@param buf core.metrics.metric[]
function M.collect(self, buf)
	buf[#buf+1] = self
end

---@param self core.metrics.gaugevec
---@param ... string|number
---@return core.metrics.gaugesub
function M.labels(self, ...)
	local metrics = self.metrics
	local k = labels.key(self.labelcache, self.labelnames, {...})
	local g = metrics[k]
	if not g then
		g = setmetatable({
			value = 0,
		}, mt)
		metrics[k] = g
	end
	return g
end

---@param name string
---@param help string
---@param labelnames string[]?
---@return core.metrics.gauge | core.metrics.gaugevec
local function new (name, help, labelnames)
	if not labelnames then
		return setmetatable({
			name = name,
			help = help,
			kind = "gauge",
			value = 0,	--the value
		}, mt)
	end
	return setmetatable({
		name = name,
		help = help,
		kind = "gauge",
		metrics = {},
		labelnames = labelnames,
		labelcache = {},
	}, mt)
end

return new
