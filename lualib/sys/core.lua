local silly = require "sys.silly"

local core = {}
local type = type
local error = error
local assert = assert
local xpcall = xpcall
local tostring = tostring
local tonumber = tonumber
local smatch = string.match
local sformat = string.format
local tremove = table.remove
local tpack = table.pack
local tunpack = table.unpack
local traceback = debug.traceback
local weakmt = {__mode="kv"}

--misc
local core_log = silly.log
core.log = core_log
core.tostring = silly.tostring
core.genid = silly.genid

--coroutine
--state migrate(RUN (WAIT->READY)/SLEEP RUN)
local task_status = setmetatable({}, weakmt)
local task_running = nil
local cocreate = coroutine.create
local corunning = coroutine.running
local coyield = coroutine.yield
local coresume = coroutine.resume
local coclose = coroutine.close
local task_yield = coyield
local function task_resume(t, ...)
	local save = task_running
	task_status[t] = "RUN"
	task_running = t
	local ok, err = coresume(t, ...)
	task_running = save
	if not ok then
		task_status[t] = nil
		local ret = traceback(t, tostring(err), 1)
		core_log("[sys.core] task resume", ret)
		local ok, err = coclose(t)
		if not ok then
			core_log("[sys.core] task close", err)
		end
	else
		task_status[t] = err
	end
end
--env
core.envget = silly.getenv
core.envset = silly.setenv
--socket
local socket_listen = silly.listen
local socket_bind = silly.bind
local socket_connect = silly.connect
local socket_udp = silly.udp
local socket_close = silly.close
local socket_readctrl = silly.readctrl
core.multipack = silly.multipack
core.multifree = silly.multifree
core.multicast = silly.multicast
core.write = silly.send
core.udpwrite = silly.udpsend
core.ntop = silly.ntop
core.sendsize = silly.sendsize
core.readctrl = function (sid, ctrl)
	return socket_readctrl(sid, ctrl == "enable")
end
--timer
local silly_timeout = silly.timeout
core.now = silly.timenow
core.nowsec = silly.timenowsec
core.monotonic = silly.timemonotonic
core.monotonicsec = silly.timemonotonicsec
--debug interface
core.memused = silly.memused
core.memrss = silly.memrss
core.msgsize = silly.msgsize
core.cpuinfo = silly.cpuinfo
core.getpid = silly.getpid
core.netinfo = silly.netinfo
core.socketinfo = silly.socketinfo
core.timerinfo = silly.timerinfo
core.allocatorinfo = silly.memallocatorinfo
--const
core.allocator = silly.memallocator()
core.version = silly.version()
core.pollapi = silly.pollapi()
core.timerrs = silly.timerresolution()

local function errmsg(msg)
	return traceback("error: " .. tostring(msg), 2)
end

local function core_pcall(f, ...)
	return xpcall(f, errmsg, ...)
end

function core.error(errmsg)
	core_log(errmsg)
	core_log(traceback())
end

core.pcall = core_pcall
function core.running()
	return task_running
end

--coroutine pool will be dynamic size
--so use the weaktable
local copool = {}
setmetatable(copool, weakmt)

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
			f = nil
			copool[#copool + 1] = corunning()
			ret, f = coyield("EXIT")
			if ret ~= "STARTUP" then
				core_log("[sys.core] task create", ret)
				core_log(traceback())
				return
			end
			f(coyield())
		end
	end)
	return co
end

local task_create_origin = task_create
local task_resume_origin = task_resume

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

local dispatch_wakeup

core.exit = function(status)
	silly.dispatch(function() end)
	wakeup_task_queue = {}
	wakeup_task_param = {}
	silly.exit(status)
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

function core.fork(func)
	local t = task_create(func)
	task_status[t] = "READY"
	wakeup_task_queue[#wakeup_task_queue + 1] = t
	return t
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

function core.wakeup(t, res)
	local status = task_status[t]
	assert(status == "WAIT", status)
	task_status[t] = "READY"
	wakeup_task_param[t] = res
	wakeup_task_queue[#wakeup_task_queue + 1] = t
end

function core.wakeup2(t, ...)
	core.wakeup(t, tpack(...))
end

function core.sleep(ms)
	local t = task_running
	local status = task_status[t]
	assert(status == "RUN", status)
	local session = silly_timeout(ms)
	sleep_session_task[session] = t
	task_yield("SLEEP")
end

function core.timeout(ms, func)
	local session = silly_timeout(ms)
	sleep_session_task[session] = func
	return session
end

function core.timercancel(session)
	f = sleep_session_task[session]
	if f then
		assert(type(f) == "function")
		sleep_session_task[session] = nil
	end
end

function core.start(func)
	local t = task_create(func)
	task_resume(t)
	dispatch_wakeup()
end

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

--socket
local socket_dispatch = {}
local socket_connecting = {}

local ip_pattern = "%[-([0-9A-Fa-f:%.]*)%]-:([0-9a-zA-Z]+)$"

function core.listen(addr, dispatch, backlog)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	if ip == "" then
		ip = "0::0"
	end
	if not backlog then
		backlog = 256 --this constant come from linux kernel comment
	end
	local id = socket_listen(ip, port, backlog);
	if id < 0 then
		local errno = -id
		core_log("[sys.core] listen", port, "error", errno)
		return nil, errno
	end
	socket_dispatch[id] = dispatch
	return id
end

function core.bind(addr, dispatch)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	if ip == "" then
		ip = "0::0"
	end
	local id = socket_bind(ip, port);
	if id < 0 then
		core_log("[sys.core] udpbind", port, "error",  id)
		return nil
	end
	socket_dispatch[id] = dispatch
	return id

end

function core.connect(addr, dispatch, bind)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	assert(ip and port, addr)
	bind = bind or ":0"
	local bip, bport = smatch(bind, ip_pattern)
	assert(bip and bport)
	local fd = socket_connect(ip, port, bip, bport)
	if fd < 0 then
		return nil
	end
	assert(socket_connecting[fd] == nil)
	socket_connecting[fd] = task_running
	local ok = core.wait()
	socket_connecting[fd] = nil
	if ok ~= true then
		return nil
	end
	socket_dispatch[fd] = assert(dispatch)
	return fd
end

function core.udp(addr, dispatch, bind)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	assert(ip and port, addr)
	bind = bind or ":0"
	local bip, bport = smatch(bind, ip_pattern)
	assert(bip and bport)
	local fd = socket_udp(ip, port, bip, bport)
	if fd >= 0 then
		socket_dispatch[fd] = dispatch
		return fd
	else
		return nil
	end
end

function core.close(fd)
	local sc = socket_dispatch[fd]
	if sc == nil then
		return false
	end
	socket_dispatch[fd] = nil
	assert(socket_connecting[fd] == nil)
	socket_close(fd)
end

--the message handler can't be yield
local MSG = {
[1] = function(session)					--SILLY_TEXPIRE = 1
	local t = sleep_session_task[session]
	if t then
		sleep_session_task[session] = nil
		if type(t) == "function" then
			t = task_create(t)
		end
		task_resume(t, session)
	end
end,
[2] = function(fd, _, portid, addr)			--SILLY_SACCEPT = 2
	assert(socket_dispatch[fd] == nil)
	assert(socket_connecting[fd] == nil)
	local cb = socket_dispatch[portid]
	assert(cb, portid)
	socket_dispatch[fd] = cb
	local t = task_create(cb)
	task_resume(t, "accept", fd, _, portid,addr)
end,
[3] = function(fd, _, errno)				--SILLY_SCLOSE = 3
	local t = socket_connecting[fd]
	if t then	--connect fail
		core.wakeup(t, false)
		return
	end
	local f = socket_dispatch[fd]
	if f then	--is connected
		socket_dispatch[fd] = nil
		local t = task_create(f)
		task_resume(t, "close", fd, _, errno)
	end
end,
[4] = function(fd)					--SILLY_SCONNECTED = 4
	local t = socket_connecting[fd]
	if t == nil then	--have already closed
		assert(socket_dispatch[fd] == nil)
		return
	end
	task_resume(t, true)
end,
[5] = function(fd, msg)					--SILLY_SDATA = 5
	local f = socket_dispatch[fd]
	if f then
		local t = task_create(f)
		task_resume(t, "data", fd, msg)
	else
		core_log("[sys.core] SILLY_SDATA fd:", fd, "closed")
	end
end,
[6] = function(fd, msg, addr)				--SILLY_UDP = 6
	local f = socket_dispatch[fd]
	if f then
		local t = task_create(f)
		task_resume(t, "udp", fd, msg, addr)
	else
		core_log("[sys.core] SILLY_UDP fd:", fd, "closed")
	end
end
}

--fd, message, portid/errno, addr
local function dispatch(typ, fd, message, ...)
	--may run other coroutine here(like connected)
	MSG[typ](fd, message, ...)
	dispatch_wakeup()
end

silly.dispatch(dispatch)

return core

