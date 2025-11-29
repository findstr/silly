local silly = require "silly"
local task = require "silly.task"
local c = require "silly.signal.c"
local logger = require "silly.logger.c"

local assert = assert
local task_create = task._create
local task_resume = task._resume

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
		logger.error("[signal] sig:", sig, "not support")
		return nil
	end
	local s = assert(signal_map[sig], sig)
	local err = c_signal(s)
	assert(not err, err)
	local old = signal_dispatch[s]
	signal_dispatch[s] = f
	return old
end


silly.register(c.FIRE, function(signum)
	local fn = signal_dispatch[signum]
	if fn then
		local t = task_create(fn)
		task_resume(t, signal_map[signum])
		return
	end
	logger.info("[signal] signum:", signal_map[signum], "received")
	silly.exit(0)
end)

signal("SIGINT", function(_)
	silly.exit(0)
end)

return signal
