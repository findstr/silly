--[[
Note:
Functions prefixed with "_" are considered internal implementation details.
They are not part of the public API and MUST NOT be used in business code.
]]

local c = require "silly.c"
local queue = require "silly.adt.queue"
local logger = require "silly.logger.c"

local task = {}
local error = error
local pairs = pairs
local assert = assert
local tostring = tostring
local setmetatable = setmetatable
local tremove = table.remove
local traceback = debug.traceback
local qpop = queue.pop
local qpush = queue.push
local qsize = queue.size

local weakv = {__mode="v"}

--misc
local log_error = assert(logger.error)
local tracespawn = assert(c.tracespawn)
local traceset = assert(c.traceset)
local tracenode = assert(c.tracenode)

task.pid = c.getpid()
task.genid = c.genid
task.gitsha1 = c.gitsha1()
task.version = c.version()
task.tostring = c.tostring
task.register = c.register
--coroutine
--state migrate(RUN (WAIT->READY)/SLEEP RUN)
local task_status = {}
local task_traceid = {}
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
	task_running = t
	task_status[t] = "RUN"
	local traceid = traceset(task_traceid[t], t)
	local ok, err = coresume(t, ...)
	traceset(traceid)
	task_running = save
	task_status[save] = "RUN"
	if not ok then
		task_traceid[t] = nil
		task_status[t] = nil
		local ret = traceback(t, tostring(err), 1)
		log_error("[silly] task resume", ret)
		local ok, err = coclose(t)
		if not ok then
			log_error("[silly] task close", err)
		end
	end
end

local trace_node_id = 0

---@param nodeid integer
function task.tracenode(nodeid)
	trace_node_id = nodeid
	tracenode(nodeid)
end

---@return integer
function task.tracespawn()
	local nid, oid = tracespawn()
	task_traceid[task_running] = nid
	return oid
end

---@return integer
function task.traceset(id)
	task_traceid[task_running] = id
	return (traceset(id, task_running))
end

local traceid_node_mask = ~0xffff -- grep silly_tracenode_t

---@return integer
function task.tracepropagate()
	local traceid = task_traceid[task_running] or 0
	return traceid & traceid_node_mask | trace_node_id
end

function task.error(errmsg)
	log_error(errmsg)
	log_error(traceback())
end

---@return thread
function task.running()
	return task_running
end

--coroutine pool will be dynamic size
--so use the weaktable
local copool = {}
setmetatable(copool, weakv)
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
		local running = corunning()
		while true do
			local ret
			f = NIL
			task_traceid[running] = nil
			task_status[running] = nil
			copool[#copool + 1] = running
			ret, f = coyield("EXIT")
			if ret ~= "STARTUP" then
				log_error("[silly] task create", ret)
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
function task.task_hook(create, term)
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


local wakeup_task_queue = queue.new()
local wakeup_task_param = {}

task._task_create = task_create
task._task_resume = task_resume
task._task_yield = task_yield

function task._dispatch_wakeup()
	while true do
		local co = qpop(wakeup_task_queue)
		if not co then
			return
		end
		local param = wakeup_task_param[co]
		wakeup_task_param[co] = nil
		task_resume(co, param)
	end
end

---@type fun(status:integer)
function task._exit(status)
	wakeup_task_queue = queue.new()
	wakeup_task_param = {}
	task_status = {}
	task_traceid = {}
	task.wakeup = function()end
	task.fork = function()end
	c.exit(status)
	coyield()
end

---@param func async fun()
---@param ud any
function task.fork(func, ud)
	local t = task_create(func)
	task_status[t] = "READY"
	if ud then
		wakeup_task_param[t] = ud
	end
	qpush(wakeup_task_queue, t)
	return t
end

function task.status(t)
	return task_status[t]
end

function task.wait()
	local t = task_running
	local status = task_status[t]
	if status ~= "RUN" then
		error("BUG: wait on task stat:" .. status)
	end
	task_status[t] = "WAIT"
	return task_yield("WAIT")
end

---@param t thread
---@param res any
function task.wakeup(t, res)
	local status = task_status[t]
	if status ~= "WAIT" then
		error("BUG: wakeup on task stat:" .. tostring(status))
	end
	task_status[t] = "READY"
	if res then
		wakeup_task_param[t] = res
	end
	qpush(wakeup_task_queue, t)
end

---@param func async fun()
function task._start(func)
	local t = task_create(func)
	task_resume(t)
end

---@return integer
function task.taskstat()
	return qsize(wakeup_task_queue)
end

---@return { [thread]: { traceback: string, status: string } }
function task.tasks()
	local tasks = {}
	for t, status in pairs(task_status) do
		tasks[t] = {
			traceback = traceback(t),
			status = status
		}
	end
	return tasks
end

function task._dump()
	return {
		copool = copool,
		task_status = task_status,
		task_traceid = task_traceid,
	}
end

return task
