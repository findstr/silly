local silly = require "silly"
local task = require "silly.task"
local c = require "silly.time.c"

local type = type
local task_running = task.running
local task_create = task._create
local task_resume = task._resume
local task_yield = task._yield
local timeafter = c.after
local timercancel = c.cancel

local sleep_session_task = {}
local timer_user_data = {}

local M = {}

M.now = c.now
M.monotonic = c.monotonic

---@param ms integer
function M.sleep(ms)
	local t = task_running()
	local session = timeafter(ms)
	sleep_session_task[session] = t
	task_yield("SLEEP")
end

---@param ms integer
---@param func async fun(any)
---@param ud any
function M.after(ms, func, ud)
	local session = timeafter(ms)
	if ud then
		timer_user_data[session] = ud
	end
	sleep_session_task[session] = func
	return session
end

---@param session integer
function M.cancel(session)
	local f = sleep_session_task[session]
	if f then
		sleep_session_task[session] = nil
		timer_user_data[session] = nil
		timercancel(session)
	end
end

silly.register(c.EXPIRE, function(session)
	local t = sleep_session_task[session]
	if t then
		sleep_session_task[session] = nil
		local ud = timer_user_data[session]
		if ud then
			timer_user_data[session] = nil
		else
			ud = session
		end
		if type(t) == "function" then
			t = task_create(t)
		end
		task_resume(t, ud)
	end
end)

function M._dump()
	return {
		sleep_session_task = sleep_session_task,
		timer_user_data = timer_user_data,
	}
end

return M