local c = require "silly.metrics.c"
local gauge = require "silly.metrics.gauge"

local M = {}

---@return silly.metrics.collector
function M.new()
	local je_resident = gauge(
		"jemalloc_resident",
		"Maximum number of bytes in physically resident data pages mapped by the allocator."
	)
	local je_active = gauge(
		"jemalloc_active",
		"Total number of bytes in active pages allocated by the application."
	)
	local je_allocated = gauge(
		"jemalloc_allocated",
		"Total number of bytes allocated by the application."
	)
	local je_retained = gauge(
		"jemalloc_retained",
		"Total number of bytes in virtual memory mappings that were retained."
	)
	local collect = function(_, buf)
		local resident, active, allocated, retained = c.jestat()
		je_resident:set(resident)
		je_active:set(active)
		je_allocated:set(allocated)
		je_retained:set(retained)
		local len = #buf
		buf[len + 1] = je_resident
		buf[len + 2] = je_active
		buf[len + 3] = je_allocated
		buf[len + 4] = je_retained
	end
	local c = {
		name = "Jemalloc",
		new = M.new,
		collect = collect,
	}
	return c
end

return M

