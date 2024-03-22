local c = require "core.metrics.c"
local registry = require "core.metrics.registry"
local counter = require "core.metrics.counter"
local gauge = require "core.metrics.gauge"
local format = string.format
local concat = table.concat

local M ={}

local R = registry:new()

function M.counter(name, help, labels)
	local c = counter(name, help, labels)
	R:register(c)
	return c
end

function M.gauge(name, help, labels)
	local c = gauge(name, help, labels)
	R:register(c)
	return c
end

function M.sample(fn)
	R:sample(fn)
end

function M.unsample(fn)
	R:unsample(fn)
end

function M.registry()
	return R
end

function M.gather()
	local buf = {}
	local metrics = R:collect()
	for i = 1, #metrics do
		local m = metrics[i]
		local name = m.name
		buf[#buf + 1] = format("# HELP %s %s", name, m.help)
		buf[#buf + 1] = format("# TYPE %s %s", name, m.kind)
		local n = #buf
		if m.labelnames then
			for j = 1, #m do
				local v = m[j]
				buf[n + 1] = format('%s%s %s', name, v[2], v[1])
			end
		else
			buf[n + 1] = format('%s %s', name, m[1])
		end
	end
	buf[#buf + 1] = ""
	return concat(buf, "\n")
end

--register default collector

local core_collector = require "core.metrics.core_collector"
R:register(core_collector:new())

local process_collector = require "core.metrics.process_collector"
R:register(process_collector:new())
if c.jestat then
	local je_collector = require "core.metrics.jemalloc_collector"
	R:register(je_collector:new())
end

return M

