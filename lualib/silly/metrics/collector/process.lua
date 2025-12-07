local c = require "silly.metrics.c"
local counter = require "silly.metrics.counter"
local gauge = require "silly.metrics.gauge"

local M = {}
M.__index = M

---@return silly.metrics.collector
function M.new()
	local cpu_seconds_usr = counter(
		"process_cpu_seconds_user",
		"Total user CPU time spent in seconds."
	)
	local cpu_seconds_sys = counter(
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
	local last_cpu_usr = 0
	local last_cpu_sys = 0
	local collect = function(_, buf)
		local sys, usr = c.cpustat()
		if usr > last_cpu_usr then
			cpu_seconds_usr:add(usr - last_cpu_usr)
		end
		if sys > last_cpu_sys then
			cpu_seconds_sys:add(sys - last_cpu_sys)
		end
		last_cpu_usr = usr
		last_cpu_sys = sys

		local vmrss, heap = c.memstat()

		resident_memory_bytes:set(vmrss)
		heap_bytes:set(heap)

		local len = #buf
		buf[len + 1] = cpu_seconds_usr
		buf[len + 2] = cpu_seconds_sys
		buf[len + 3] = resident_memory_bytes
		buf[len + 4] = heap_bytes
	end
	local c = {
		name = "Process",
		new = M.new,
		collect = collect,
	}
	return c
end

return M

