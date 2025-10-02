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
	buf[#buf + 1] = name
	if label then
		buf[#buf + 1] = "{"
		buf[#buf + 1] = label
		buf[#buf + 1] = ','
		buf[#buf + 1] = "}"
	end
	buf[#buf + 1] = "\t"
	buf[#buf + 1] = v.value
	buf[#buf + 1] = "\n"
end

local function format_histogram(buf, name, label, v)
	local buckets = v.buckets
	local bucketcounts = v.bucketcounts
	local n = #bucketcounts
	local count = 0
	for i = 1, n do
		buf[#buf + 1] = name
		buf[#buf + 1] = '_bucket'
		buf[#buf + 1] = '{'
		if label then
			buf[#buf + 1] = label
			buf[#buf + 1] = ','
		end
		local bc = bucketcounts[i]
		count = count + bc
		buf[#buf + 1] = 'le="'
		buf[#buf + 1] = strcache[buckets[i]]
		buf[#buf + 1] = '"}\t'
		buf[#buf + 1] = tostring(bc)
		buf[#buf + 1] = "\n"
	end
	buf[#buf + 1] = name
	buf[#buf + 1] = '_bucket'
	buf[#buf + 1] = '{'
	if label then
		buf[#buf + 1] = label
		buf[#buf + 1] = ','
	end
	buf[#buf + 1] = 'le="+Inf"}\t'
	buf[#buf + 1] = tostring(v.count - count)
	buf[#buf + 1] = "\n"

	buf[#buf + 1] = name
	buf[#buf + 1] = '_count'
	if label then
		buf[#buf + 1] = '{'
		buf[#buf + 1] = label
		buf[#buf + 1] = '}'
	end
	buf[#buf + 1] = "\t"
	buf[#buf + 1] = tostring(v.count)
	buf[#buf + 1] = "\n"

	buf[#buf + 1] = name
	buf[#buf + 1] = '_sum'
	if label then
		buf[#buf + 1] = '{'
		buf[#buf + 1] = label
		buf[#buf + 1] = '}'
	end
	buf[#buf + 1] = "\t"
	buf[#buf + 1] = tostring(v.sum)
	buf[#buf + 1] = "\n"
end

local buf = {}
function M.gather()
	local collectors = R:collect()
	for i = 1, #collectors do
		local m = collectors[i]
		local kind = m.kind
		local name = m.name
		buf[#buf + 1] = "# HELP "
		buf[#buf + 1] = name
		buf[#buf + 1] = " "
		buf[#buf + 1] = m.help
		buf[#buf + 1] = "\n"

		buf[#buf + 1] = "# TYPE "
		buf[#buf + 1] = name
		buf[#buf + 1] = " "
		buf[#buf + 1] = kind
		buf[#buf + 1] = "\n"

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

