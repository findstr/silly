local c = require "silly.metrics.c"
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"
local gauge = require "silly.metrics.gauge"
local histogram = require "silly.metrics.histogram"

local tostring = tostring
local concat = table.concat

local M ={}

local R = registry.new()

function M.counter(name, help, labels)
	local ct = counter(name, help, labels)
	R:register(ct)
	return ct
end

function M.gauge(name, help, labels)
	local g = gauge(name, help, labels)
	R:register(g)
	return g
end

function M.histogram(name, help, labels, buckets)
	local h = histogram(name, help, labels, buckets)
	R:register(h)
	return h
end

function M.registry()
	return R
end

local strcache = setmetatable({}, {__index = function(t, v)
	local s = tostring(v)
	t[v] = s
	return s
end})

local function format_count(buf, name, label, v)
	local n = #buf
	buf[n + 1] = name
	n = n + 1
	if label then
		buf[n + 1] = "{"
		buf[n + 2] = label
		buf[n + 3] = "}"
		n = n + 3
	end
	buf[n + 1] = "\t"
	buf[n + 2] = v.value
	buf[n + 3] = "\n"
end

local function format_histogram(buf, name, label, v)
	local buckets = v.buckets
	local bucketcounts = v.bucketcounts
	local count = 0
	local n = #buf

	-- Bucket entries
	for i = 1, #bucketcounts do
		buf[n + 1] = name
		buf[n + 2] = '_bucket'
		buf[n + 3] = '{'
		n = n + 3
		if label then
			buf[n + 1] = label
			buf[n + 2] = ','
			n = n + 2
		end
		local bc = bucketcounts[i]
		count = count + bc
		buf[n + 1] = 'le="'
		buf[n + 2] = strcache[buckets[i]]
		buf[n + 3] = '"}\t'
		buf[n + 4] = tostring(bc)
		buf[n + 5] = "\n"
		n = n + 5
	end

	-- +Inf bucket
	buf[n + 1] = name
	buf[n + 2] = '_bucket'
	buf[n + 3] = '{'
	n = n + 3
	if label then
		buf[n + 1] = label
		buf[n + 2] = ','
		n = n + 2
	end
	buf[n + 1] = 'le="+Inf"}\t'
	buf[n + 2] = tostring(v.count - count)
	buf[n + 3] = "\n"
	n = n + 3

	-- _count
	buf[n + 1] = name
	buf[n + 2] = '_count'
	n = n + 2
	if label then
		buf[n + 1] = '{'
		buf[n + 2] = label
		buf[n + 3] = '}'
		n = n + 3
	end
	buf[n + 1] = "\t"
	buf[n + 2] = tostring(v.count)
	buf[n + 3] = "\n"
	n = n + 3

	-- _sum
	buf[n + 1] = name
	buf[n + 2] = '_sum'
	n = n + 2
	if label then
		buf[n + 1] = '{'
		buf[n + 2] = label
		buf[n + 3] = '}'
		n = n + 3
	end
	buf[n + 1] = "\t"
	buf[n + 2] = tostring(v.sum)
	buf[n + 3] = "\n"
end

local buf = {}
--- @param r silly.metrics.registry
function M.gather(r)
	r = r or R
	local collectors = r:collect()
	for i = 1, #collectors do
		local m = collectors[i]
		local kind = m.kind
		local name = m.name

		-- Write HELP line
		local n = #buf
		buf[n + 1] = "# HELP "
		buf[n + 2] = name
		buf[n + 3] = " "
		buf[n + 4] = m.help
		buf[n + 5] = "\n"

		-- Write TYPE line
		buf[n + 6] = "# TYPE "
		buf[n + 7] = name
		buf[n + 8] = " "
		buf[n + 9] = kind
		buf[n + 10] = "\n"

		local fmt = kind == "histogram" and format_histogram or format_count
		local metrics = m.metrics
		if metrics then
			local count = 0
			for k, v in pairs(metrics) do
				count = count + 1
				fmt(buf, name, k, v)
			end
		else
			fmt(buf, name, nil, m)
		end
	end
	local str = concat(buf, "")
	for i = 1, #buf do
		buf[i] = nil
	end
	return str
end

--register default collector
local silly_collector = require "silly.metrics.collector.silly"
R:register(silly_collector.new())

local process_collector = require "silly.metrics.collector.process"
R:register(process_collector.new())
if c.jestat then
	local je_collector = require "silly.metrics.collector.jemalloc"
	R:register(je_collector.new())
end

return M

