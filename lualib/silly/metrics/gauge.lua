local labels = require "silly.metrics.labels"
---@class silly.metrics.gauge_mt : silly.metrics.collector
local M = {}

---@class silly.metrics.gaugesub : silly.metrics.gauge_mt
---@field value number?

---@class silly.metrics.gauge : silly.metrics.gaugesub
---@field name string
---@field help string
---@field kind string
---@field value number?

---@class silly.metrics.gaugevec : silly.metrics.gauge_mt
---@field labelnames string[]
---@field labelcache table<string|number, table>
---@field metrics table<string, silly.metrics.gaugesub>

local mt = {__index = M}

local setmetatable = setmetatable

---@param self silly.metrics.gaugesub
---@param v number
function M:set(v)
	self.value = v
end

---@param self silly.metrics.gaugesub
---@param v number
function M:add(v)
	self.value = self.value + 1
end

---@param self silly.metrics.gaugesub
function M:inc()
	self.value = self.value + 1
end

---@param self silly.metrics.gaugesub
---@param v number
function M:sub(v)
	self.value = self.value - v
end

---@param self silly.metrics.gaugesub
function M:dec()
	self.value = self.value - 1
end

---@param self silly.metrics.gauge
---@param buf silly.metrics.metric[]
function M.collect(self, buf)
	buf[#buf+1] = self
end

---@param self silly.metrics.gaugevec
---@param ... string|number
---@return silly.metrics.gaugesub
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
---@return silly.metrics.gauge | silly.metrics.gaugevec
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
