local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local c = require "silly.hive.c"
local mutex = require "silly.sync.mutex"

local error = error
local pack = table.pack
local unpack = table.unpack

local task_running = task.running
local task_wait = task.wait
local task_resume = task._resume

local M = {}
local working = {}
local lock = mutex.new()

local prune_timer
prune_timer = function()
	c.prune()
	time.after(1000, prune_timer)
end
prune_timer()

M.limit = c.limit
M.threads = c.threads
M.spawn = c.spawn
M.prune = c.prune

---@param worker silly.hive.worker
---@param ... any
function M.invoke(worker, ...)
	local l<close> = lock:lock(worker)
	local t = task_running()
	local id = c.push(worker, ...)
	working[id] = t
	local ok, dat = task_wait()
	if not ok then
		error(dat[1])
	end
	working[id] = nil
	return unpack(dat)
end

silly.register(c.DONE, function(id, ok, ...)
	local t = working[id]
	task_resume(t, ok, pack(...))
end)

return M