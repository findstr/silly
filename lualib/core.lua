--[[
Note:
Functions prefixed with "_" are considered internal implementation details.
They are not part of the public API and MUST NOT be used in business code.
]]

local c = require "core.c"
local logger = require "core.logger.c"

local core = {}
local type = type
local pairs = pairs
local assert = assert
local xpcall = xpcall
local tostring = tostring
local smatch = string.match
local tremove = table.remove
local tpack = table.pack
local tunpack = table.unpack
local traceback = debug.traceback
local weakmt = {__mode="kv"}

local function nop(_) end
--misc
local log_info = assert(logger.info)
local log_error = assert(logger.error)
local trace_new = assert(c.trace_new)
local trace_set = assert(c.trace_set)
local trace_span = assert(c.trace_span)

core.pid = c.getpid()
core.genid = c.genid
core.gitsha1 = c.gitsha1()
core.version = c.version()
core.tostring = c.tostring
core.register = c.register
--coroutine
--state migrate(RUN (WAIT->READY)/SLEEP RUN)
local task_status = setmetatable({}, weakmt)
local task_traceid = setmetatable({}, weakmt)
local task_running = coroutine.running()
local cocreate = coroutine.create
local corunning = coroutine.running
local coyield = coroutine.yield
local coresume = coroutine.resume
local coclose = coroutine.close
local task_yield = coyield

---@param t thread
local function task_resume(t, ...)
	local save = task_running
	task_status[t] = "RUN"
	task_running = t
	local traceid = trace_set(t, task_traceid[t])
	local ok, err = coresume(t, ...)
	trace_set(traceid)
	task_running = save
	if not ok then
		task_status[t] = nil
		local ret = traceback(t, tostring(err), 1)
		log_error("[core] task resume", ret)
		local ok, err = coclose(t)
		if not ok then
			log_error("[core] task close", err)
		end
	else
		task_status[t] = err
	end
end

local function errmsg(msg)
	return traceback("error: " .. tostring(msg), 2)
end

local function core_pcall(f, ...)
	return xpcall(f, errmsg, ...)
end

core.tracespan = trace_span
core.tracepropagate = trace_new

---@return integer
function core.tracenew()
	local traceid = task_traceid[task_running]
	if traceid then
		return traceid
	end
	return trace_new()
end

---@return integer
function core.trace(id)
	task_traceid[task_running] = id
	return (trace_set(task_running, id))
end

function core.error(errmsg)
	log_error(errmsg)
	log_error(traceback())
end

core.pcall = core_pcall

---@return thread
function core.running()
	return task_running
end

--coroutine pool will be dynamic size
--so use the weaktable
local copool = {}
setmetatable(copool, weakmt)
local NIL = function() end
---@param f async fun(...)
---@return thread
local function task_create(f)
	local co = tremove(copool)
	if co then
		coresume(co, "STARTUP", f)
		return co
	end
	co = cocreate(function(...)
		f(...)
		while true do
			local ret
			f = NIL
			local running = corunning()
			task_traceid[running] = nil
			copool[#copool + 1] = running
			ret, f = coyield("EXIT")
			if ret ~= "STARTUP" then
				log_error("[core] task create", ret)
				log_error(traceback())
				return
			end
			f(coyield())
		end
	end)
	return co
end

local task_create_origin = task_create
local task_resume_origin = task_resume

---@param create function|nil
---@param term function|nil
function core.task_hook(create, term)
	if create then
		task_create = function(f)
			local t = task_create_origin(f)
			create(t)
			return t
		end
	else
		task_create = task_create_origin
	end
	if term then
		task_resume = function(t, ...)
			local ok, err = task_resume_origin(t, ...)
			if err == "EXIT" then
				term(t)
			end
		end
	else
		task_resume = task_resume_origin
	end
	return task_resume, task_yield
end


local wakeup_task_queue = {}
local wakeup_task_param = {}

core._task_create = task_create
core._task_resume = task_resume
core._task_yield = task_yield

function core._dispatch_wakeup()
	while true do
		local co = tremove(wakeup_task_queue, 1)
		if not co then
			return
		end
		local param = wakeup_task_param[co]
		wakeup_task_param[co] = nil
		task_resume(co, param)
	end
end

---@type fun(status:integer)
core.exit = function(status)
	wakeup_task_queue = {}
	wakeup_task_param = {}
	c.exit(status)
	coyield()
end

---@param func async fun()
function core.fork(func)
	local t = task_create(func)
	task_status[t] = "READY"
	wakeup_task_queue[#wakeup_task_queue + 1] = t
	return t
end

function core.status(t)
	return task_status[t]
end

function core.wait()
	local t = task_running
	local status = task_status[t]
	assert(status == "RUN", status)
	return task_yield("WAIT")
end

---@param t thread
---@param res any
function core.wakeup(t, res)
	local status = task_status[t]
	assert(status == "WAIT", status)
	task_status[t] = "READY"
	wakeup_task_param[t] = res
	wakeup_task_queue[#wakeup_task_queue + 1] = t
end

---@param func async fun()
function core.start(func)
	local t = task_create(func)
	task_resume(t)
end

---@return integer, integer
function core.taskstat()
	return #copool, #wakeup_task_queue
end

---@return { [thread]: { traceback: string, status: string } }
function core.tasks()
	local tasks = {}
	for t, status in pairs(task_status) do
		tasks[t] = {
			traceback = traceback(t),
			status = status
		}
	end
	return tasks
end

return core
