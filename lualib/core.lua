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
local readctrl = assert(c.readctrl)
local trace_new = assert(c.trace_new)
local trace_set = assert(c.trace_set)
local trace_span = assert(c.trace_span)

core.pid = c.getpid()
core.genid = c.genid
core.gitsha1 = c.gitsha1()
core.version = c.version()
core.tostring = c.tostring
core.multipack = assert(c.multipack)
---@type fun(fd:integer):integer
core.sendsize = assert(c.sendsize)
core.socket_read_ctrl = function (sid, ctrl)
	return readctrl(sid, ctrl == "enable")
end

--signal
local signal = c.signal
local signal_map = c.signalmap()
local signal_dispatch = {}

--stdin
local stdin_dispatch = nop

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
local sleep_session_task = {}
local timer_user_data = {}

local dispatch_wakeup

---@type fun(status:integer)
core.exit = function(status)
	c.dispatch(function() end)
	wakeup_task_queue = {}
	wakeup_task_param = {}
	c.exit(status)
	coyield()
end

function dispatch_wakeup()
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

function core.wait2()
	local res = core.wait()
	if not res then
		return
	end
	return tunpack(res, 1, res.n)
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

---@param t thread
function core.wakeup2(t, ...)
	core.wakeup(t, tpack(...))
end

local timeout = c.timeout
local timercancel = c.timercancel

---@param ms integer
function core.sleep(ms)
	local t = task_running
	local status = task_status[t]
	assert(status == "RUN", status)
	local session = timeout(ms)
	sleep_session_task[session] = t
	task_yield("SLEEP")
end

---@param ms integer
---@param func function
---@param ud any
function core.timeout(ms, func, ud)
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
function core.timercancel(session)
	local f = sleep_session_task[session]
	if f then
		assert(type(f) == "function")
		local ud = timercancel(session)
		if ud then
			if ud ~= 0 then
				timer_user_data[ud] = nil
			end
			sleep_session_task[session] = nil
		else
			sleep_session_task[session] = nop
		end
	end
end

---@param sig string
---@param f async fun(sig:string)
---@return function?
function core.signal(sig, f)
	local s = signal_map[sig]
	if not s then
		log_error("[core] signal", sig, "not support")
		return nil
	end
	local s = assert(signal_map[sig], sig)
	local err = signal(s)
	assert(not err, err)
	local old = signal_dispatch[s]
	signal_dispatch[s] = f
	return old
end

---@param func async fun()
function core.start(func)
	local t = task_create(func)
	task_resume(t)
	dispatch_wakeup()
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

---@param dispatch async fun(data:string)
function core.stdin(dispatch)
	stdin_dispatch = dispatch
end

--socket
local socket_pending = {}
local socket_callback = {}

local ip_pattern = "%[-([0-9A-Fa-f:%.]*)%]-:([0-9a-zA-Z]+)$"

---@type fun(ip:string, port:string, backlog:integer):integer?, string? error
local tcp_listen = assert(c.tcp_listen)
---@type fun(ip:string, port:string, bind_ip:string, bind_port:string):integer?, string? error
local tcp_connect = assert(c.tcp_connect)
---@type fun(ip:string, port:string):integer?, string? error
local udp_bind = assert(c.udp_bind)
---@type fun(ip:string, port:string, bind_ip:string, bind_port:string):integer?, string? error
local udp_connect = assert(c.udp_connect)
---@type fun(fd:integer):boolean, string? error
local socket_close = assert(c.close)
---@type fun(fd:integer, data:string|lightuserdata|table, size:integer|nil):boolean, string? error
core.tcp_send = assert(c.tcp_send)
---@type fun(fd:integer, data:string|lightuserdata|table, size:integer|nil, addr:string|nil):boolean, string? error
core.udp_send = assert(c.udp_send)
---@type fun(fd:integer, data:lightuserdata, size:integer?, addr:string?): boolean, string? error
core.tcp_multicast = assert(c.tcp_multicast)

local function listen_wrap(listen)
	---@param addr string
	---@param callback async fun(typ:string, fd:integer,
	---	message:lightuserdata, addr:string)
	---@param backlog integer|nil
	---@return integer|nil, string|nil
	return function(addr, callback, backlog)
		assert(callback)
		local ip, port = smatch(addr, ip_pattern)
		if ip == "" then
			ip = "0::0"
		end
		if not backlog then
			backlog = 256 --this constant come from linux kernel comment
		end
		local fd, err = listen(ip, port, backlog);
		if fd  then
			assert(socket_pending[fd] == nil)
			socket_pending[fd] = task_running
			err = core.wait()
			socket_pending[fd] = nil
			if err then
				return nil, err
			end
			socket_callback[fd] = callback
			return fd, nil
		end
		log_error("[core] listen", port, "error", err)
		return nil, err
	end
end

local function connect_wrap(connect)
	---@param addr string
	---@param callback async fun(typ:string, fd:integer,
	---	message:lightuserdata, addr:string)
	---@param bind string|nil
	---@return integer|nil, string|nil
	return function(addr, callback, bind)
		assert(callback)
		local ip, port = smatch(addr, ip_pattern)
		if not ip or not port then
			return nil, "invalid address:" .. addr
		end
		local bindip, bindport
		if bind then
			bindip, bindport = smatch(bind, ip_pattern)
			if not bindip or not bindport then
				return nil, "invalid bind address:" .. bind
			end
		else
			bindip, bindport = "", "0"
		end
		local fd, err = connect(ip, port, bindip, bindport)
		if fd then
			assert(socket_pending[fd] == nil)
			socket_pending[fd] = task_running
			err = core.wait()
			socket_pending[fd] = nil
			if err then
				return nil, err
			end
			socket_callback[fd] = callback
			return fd, nil
		end
		return nil, err
	end
end

core.tcp_listen = listen_wrap(tcp_listen)
core.udp_bind = listen_wrap(udp_bind)

core.tcp_connect = connect_wrap(tcp_connect)
core.udp_connect = connect_wrap(udp_connect)

---@param fd integer
---@return boolean, string? error
function core.socket_close(fd)
	local sc = socket_callback[fd]
	if sc == nil then
		return false, "socket closed"
	end
	socket_callback[fd] = nil
	assert(socket_pending[fd] == nil)
	local ok, err = socket_close(fd)
	if not ok then
		return false, err
	end
	return true, nil
end

local SIGNAL<const> = 1
local STDIN<const> = 2
local TIMER_EXPIRE<const> = 3
local SOCKET_LISTEN<const> = 4
local SOCKET_CONNECT<const> = 5
local SOCKET_ACCEPT<const> = 6
local SOCKET_DATA<const> = 7
local SOCKET_UDP<const> = 8
local SOCKET_CLOSE<const> = 9


--the message handler can't be yield
local MSG = {
[TIMER_EXPIRE] = function(session, userid)
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
end,
[SOCKET_ACCEPT] = function(fd, _, portid, addr)
	assert(socket_callback[fd] == nil)
	assert(socket_pending[fd] == nil)
	local cb = socket_callback[portid]
	assert(cb, portid)
	socket_callback[fd] = cb
	local t = task_create(cb)
	task_resume(t, "accept", fd, _, portid,addr)
end,

---@param fd integer
---@param errno integer
[SOCKET_CLOSE] = function(fd, _, errno)
	local f = socket_callback[fd]
	if f then
		local t = task_create(f)
		task_resume(t, "close", fd, _, errno)
	end
end,
[SOCKET_LISTEN] = function(fd, _, errno)
	local t = socket_pending[fd]
	if t == nil then --have already closed
		assert(socket_callback[fd] == nil)
		return
	end
	task_resume(t, errno)
end,
[SOCKET_CONNECT] = function(fd, _, errno)
	local t = socket_pending[fd]
	if t == nil then	--have already closed
		assert(socket_callback[fd] == nil)
		return
	end
	task_resume(t, errno)
end,
[SOCKET_DATA] = function(fd, msg)
	local f = socket_callback[fd]
	if f then
		local t = task_create(f)
		task_resume(t, "data", fd, msg)
	else
		log_info("[core] SILLY_SDATA fd:", fd, "closed")
	end
end,
[SOCKET_UDP] = function(fd, msg, addr)
	local f = socket_callback[fd]
	if f then
		local t = task_create(f)
		task_resume(t, "udp", fd, msg, addr)
	else
		log_info("[core] SILLY_UDP fd:", fd, "closed")
	end
end,
[SIGNAL] = function(signum)
	local fn = signal_dispatch[signum]
	if fn then
		local t = task_create(fn)
		task_resume(t, signal_map[signum])
		return
	end
	log_info("[core] signal", signum, "received")
	core.exit(0)
end,
[STDIN] = function(data)
	stdin_dispatch(data)
end,
}

--fd, message, portid/errno, addr
local function dispatch(typ, fd, message, ...)
	--may run other coroutine here(like connected)
	MSG[typ](fd, message, ...)
	dispatch_wakeup()
end

c.dispatch(dispatch)

core.signal("SIGINT", function(_)
	core.exit(0)
end)

return core

