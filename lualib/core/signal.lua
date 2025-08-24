local core = require "core"
local c = require "core.signal.c"
local logger = require "core.logger.c"

local assert = assert
local task_create = core._task_create
local task_resume = core._task_resume

--signal
local c_signal = c.signal
local signal_map = c.signalmap()
local signal_dispatch = {}


---@param sig string
---@param f async fun(sig:string)
---@return function?
local function signal(sig, f)
	local s = signal_map[sig]
	if not s then
		logger.error("[core] signal", sig, "not support")
		return nil
	end
	local s = assert(signal_map[sig], sig)
	local err = c_signal(s)
	assert(not err, err)
	local old = signal_dispatch[s]
	signal_dispatch[s] = f
	return old
end


core.register(c.FIRE, function(signum)
	local fn = signal_dispatch[signum]
	if fn then
		local t = task_create(fn)
		task_resume(t, signal_map[signum])
		return
	end
	logger.info("[core] signal", signum, "received")
	core.exit(0)
end)

signal("SIGINT", function(_)
	core.exit(0)
end)

return signal