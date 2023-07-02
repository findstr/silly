local c = require "sys.metrics.c"
local time = require "sys.time"
local gauge = require "sys.metrics.gauge"
local setmetatable = setmetatable

local M = {}
M.__index = M

function M:new()
	local cpu_seconds_usr = gauge(
		"process_cpu_seconds_user",
		"Total user CPU time spent in seconds."
	)
	local cpu_seconds_sys = gauge(
		"process_cpu_seconds_system",
		"Total system CPU time spent in seconds."
	)
	local resident_memory_bytes = gauge(
		"process_resident_memory_bytes",
		"Resident memory size in bytes."
	)
	local heap_bytes = gauge(
		"process_heap_bytes",
		"Process heap size in bytes allocated by application."
	)
	local collect = function(_, buf, len)
		local sys, usr = c.cpustat()
		local vmrss, heap = c.memstat()

		cpu_seconds_usr:set(usr)
		cpu_seconds_sys:set(sys)
		resident_memory_bytes:set(vmrss)
		heap_bytes:set(heap)

		buf[len + 1] = cpu_seconds_usr
		buf[len + 2] = cpu_seconds_sys
		buf[len + 3] = resident_memory_bytes
		buf[len + 4] = heap_bytes
		return len + 4
	end
	local c = {
		name = "Process",
		new = M.new,
		collect = collect,
	}
	return c
end

return M

