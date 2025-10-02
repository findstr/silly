local silly = require "silly"
local c = require "silly.time.c"

local assert = assert
local type = type
local task_running = silly.running
local task_create = silly._task_create
local task_resume = silly._task_resume
local task_yield = silly._task_yield
local timeout = c.timeout
local timercancel = c.timercancel

local sleep_session_task = {}
local timer_user_data = {}

local M = {}

M.now = c.now
M.monotonic = c.monotonic

local function nop(_) end

---@param ms integer
function M.sleep(ms)
	local t = task_running()
	local session = timeout(ms)
	sleep_session_task[session] = t
	task_yield("SLEEP")
end

---@param ms integer
---@param func function
---@param ud any
function M.after(ms, func, ud)
	local userid
	if ud then
		userid = #timer_user_data + 1
		timer_user_data[userid] = ud
	end
	local session = timeout(ms, userid)
	sleep_session_task[session] = func
	return session
end

---@param session integer
function M.cancel(session)
	local f = sleep_session_task[session]
	if f then
		assert(type(f) == "function")
		local ud = timercancel(session)
		if ud then
			if ud ~= 0 then
				timer_user_data[ud] = nil
			end
			sleep_session_task[session] = nil
		else -- The expire event has already been triggered and is on its way.
			sleep_session_task[session] = nop
		end
	end
end


silly.register(c.EXPIRE, function(session, userid)
	local t = sleep_session_task[session]
	if t then
		sleep_session_task[session] = nil
		if type(t) == "function" then
			t = task_create(t)
		end
		local ud
		if userid == 0 then --has no user data
			ud = session
		else
			ud = timer_user_data[userid]
			timer_user_data[userid] = nil
		end
		task_resume(t, ud)
	end
end)

return M
