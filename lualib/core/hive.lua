local c = require "core.c"
local core = require "core"
local time = require "core.time"
local hc = require "core.hive.c"
local mutex = require "core.sync.mutex"
local message = require "core.message"

local error = error
local pack = table.pack
local unpack = table.unpack

local task_running = core.running
local task_yield = core._task_yield
local task_resume = core._task_resume

local M = {}
local working = {}
local lock = mutex.new()

local prune_timer
prune_timer = function()
	hc.prune()
	time.after(1000, prune_timer)
end
prune_timer()

---@class core.hive.worker

---@type fun(min:integer, max:integer)
M.limit = hc.limit
---@type fun():integer
M.threads = hc.threads
---@type fun(code:string, ...):core.hive.worker
M.spawn = hc.spawn
---@type fun()
M.prune = hc.prune

---@param worker core.hive.worker
---@param ... any
function M.invoke(worker, ...)
	local l<close> = lock:lock(worker)
	local t = task_running()
	local id = hc.push(worker, ...)
	working[id] = t
	local ok, dat = task_yield("HIVE")
	if not ok then
		error(dat[1])
	end
	working[id] = nil
	return unpack(dat)
end

c.register(message.HIVE_DONE, function(id, ok, ...)
	local t = working[id]
	task_resume(t, ok, pack(...))
end)

return M