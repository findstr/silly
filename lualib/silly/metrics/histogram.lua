local labels = require "silly.metrics.labels"
---@class silly.metrics.histogram_mt : silly.metrics.collector
local M = {}

---@class silly.metrics.histogramsub : silly.metrics.histogram_mt
---@field buckets number[]
---@field bucketcounts number[]
---@field sum number
---@field count number

---@class silly.metrics.histogram : silly.metrics.histogramsub
---@field name string
---@field help string
---@field kind string

---@class silly.metrics.histogramvec : silly.metrics.histogram_mt
---@field labelnames string[]
---@field labelcache table<string|number, table>
---@field metrics table<string, silly.metrics.histogramsub>
---@field buckets number[]

local mt = {__index = M}
local type = type
local assert = assert
local pairs = pairs
local sort = table.sort
local setmetatable = setmetatable

-- default bucket boundaries (same as Prometheus default)
local defaultbuckets = {0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0}

---@param self silly.metrics.histogramsub
---@param value number
function M:observe(value)
	-- update sum and count
	self.sum = self.sum + value
	self.count = self.count + 1
	local buckets = self.buckets
	local bucketcounts = self.bucketcounts
	if value <= buckets[#buckets] then
		for i = 1, #buckets do
			if value <= buckets[i] then
				bucketcounts[i] = bucketcounts[i] + 1
				break
			end
		end
	end
end

---@param self silly.metrics.histogram
---@param buf silly.metrics.metric[]
function M.collect(self, buf)
	buf[#buf+1] = self
end

---@param self silly.metrics.histogramvec
---@param ... string|number
---@return silly.metrics.histogramsub
function M.labels(self, ...)
	local metrics = self.metrics
	local lvalues = {...}
	local k = labels.key(self.labelcache, self.labelnames, lvalues)
	local h = metrics[k]
	if not h then
		local bucketcounts = {}
		for i = 1, #self.buckets do
			bucketcounts[i] = 0
		end
		h = setmetatable({
			buckets = self.buckets,
			bucketcounts = bucketcounts,
			sum = 0,
			count = 0,
		}, mt)
		metrics[k] = h
	end
	return h
end

---@param name string
---@param help string
---@param labelnames string[]?
---@param buckets number[]?
---@return silly.metrics.histogram | silly.metrics.histogramvec
local function new(name, help, labelnames, buckets)
	buckets = buckets or defaultbuckets
	-- ensure buckets are sorted
	local sortedbuckets = {}
	for i, v in pairs(buckets) do
		sortedbuckets[i] = v
	end
	sort(sortedbuckets)

	if not labelnames then
		-- initialize bucket counts array
		local bucketcounts = {}
		for i = 1, #sortedbuckets do
			bucketcounts[i] = 0
		end
		---@type silly.metrics.histogram
		return setmetatable({
			name = name,
			help = help,
			kind = "histogram",
			buckets = sortedbuckets,
			bucketcounts = bucketcounts,
			sum = 0,
			count = 0,
		}, mt)
	end

	return setmetatable({
		name = name,
		help = help,
		kind = "histogram",
		buckets = sortedbuckets,
		metrics = {},
		labelnames = labelnames,
		labelcache = {},
	}, mt)
end

return new