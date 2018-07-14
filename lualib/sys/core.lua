local silly = require "sys.silly"

local core = {}
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

local core_log = silly.log
local cocreate_ = coroutine.create
local corunning = coroutine.running
local coyield = coroutine.yield
local coresume = coroutine.resume
function core.running()
	local co = corunning()
	return co
end

function core.coroutine(resume, yield)
	coyield = yield
	coresume = resume
end

--coroutine pool will be dynamic size
--so use the weaktable
local copool = {}
local weakmt = {__mode="kv"}
setmetatable(copool, weakmt)

local function cocall()
	while true do
		local ret, func = coyield("EXIT")
		if ret ~= "STARTUP" then
			core_log("[sys.core] create coroutine fail", ret)
			core_log(traceback())
			return
		end
		local ok, err = core.pcall(func, coyield())
		if ok == false then
			core_log("[sys.core] call", err)
		end
	end
end

local function cocreate(f)
	local co = tremove(copool)
	if co then
		coresume(co, "STARTUP", f)
		return co
	end
	co = cocreate_(cocall)
	coresume(co)	--wakeup the new coroutine
	coresume(co, "STARTUP", f)	 --pass the function handler
	return co
end
--env
core.envget = silly.getenv
core.envset = silly.setenv
--socket
core.packmulti = silly.packmulti
core.freemulti = silly.freemulti
core.multicast = silly.multicast
core.write = silly.send
core.udpwrite = silly.udpsend
core.log = core_log
core.exit = silly.exit
core.tostring = silly.tostring
core.genid = silly.genid
core.now = silly.timenow
core.monotonic = silly.timemonotonic
core.monotonicsec = silly.timemonotonicsec
--debug interface
core.memused = silly.memused
core.memrss = silly.memrss
core.msgsize = silly.msgsize
core.cpuinfo = silly.cpuinfo
core.getpid = silly.getpid
--const
core.allocator = silly.memallocator()
core.version = silly.version()
core.pollapi = silly.pollapi()
core.timerrs = silly.timerresolution()

local function errmsg(msg)
	return traceback("error: " .. tostring(msg), 2)
end

core.pcall = function(f, ...)
	return xpcall(f, errmsg, ...)
end

function core.error(errmsg)
	core_log(errmsg)
	core_log(traceback())
end

local wakeup_co_queue = {}
local wakeup_co_param = {}
local wait_co_status = {}
local sleep_co_session = {}
local sleep_session_co = {}

--the wait_co_status won't hold the coroutine
--this table just to be check some incorrect call of core.wakeup
--the coroutine in wait_co_status should be hold by the wakeuper
setmetatable(wait_co_status, weakmt)

local dispatch_wakeup

local function waitresume(co, typ, ...)
	assert(typ == "WAKEUP", typ)
	assert(wait_co_status[co]== nil)
	assert(sleep_co_session[co] == nil)
	return ...
end


local function waityield(co, ret, typ)
	if ret == false then
		return
	end
	if typ == "WAIT" then
		assert(wait_co_status[co] and sleep_co_session[co] == nil)
	elseif typ == "SLEEP" then
		assert(wait_co_status[co] == nil and sleep_co_session[co])
	elseif typ == "EXIT" then
		copool[#copool + 1] = co
	elseif typ == nil then --pause by other logic
		assert(sleep_co_session[co] == nil)
		assert(wait_co_status[co] == nil)
		wait_co_status[co] = "PAUSE"
	else
		core_log("[sys.core] waityield unkonw return type", typ)
		core_log(traceback())
	end
	return dispatch_wakeup()
end

function dispatch_wakeup()
	local co = tremove(wakeup_co_queue, 1)
	if not co then
		return
	end
	local param = wakeup_co_param[co]
	wakeup_co_param[co] = nil
	return waityield(co, coresume(co, "WAKEUP", param))
end

function core.fork(func)
	local co = cocreate(func)
	wakeup_co_queue[#wakeup_co_queue + 1] = co
	return co
end

function core.wait()
	local co = corunning()
	assert(sleep_co_session[co] == nil)
	assert(wait_co_status[co] == nil)
	wait_co_status[co] = "WAIT"
	return waitresume(co, coyield("WAIT"))
end

function core.wait2()
	local res = core.wait()
	if not res then
		return
	end
	return tunpack(res, 1, res.n)
end

function core.wakeup(co, res)
	assert(wait_co_status[co])
	wakeup_co_param[co] = res
	wait_co_status[co] = nil
	wakeup_co_queue[#wakeup_co_queue + 1] = co
end

function core.wakeup2(co, ...)
	core.wakeup(co, tpack(...))
end

function core.sleep(ms)
	local co = corunning()
	local session = silly.timeout(ms)
	sleep_session_co[session] = co
	sleep_co_session[co] = session
	waitresume(co, coyield("SLEEP"))
end

function core.timeout(ms, func)
	local co = cocreate(func)
	local session = silly.timeout(ms)
	sleep_session_co[session] = co
	sleep_co_session[co] = session
	return session
end

function core.start(func)
	local co = cocreate(func)
	waityield(co, coresume(co))
end


--socket
local socket_dispatch = {}
local socket_tag = {}
local socket_connect = {}

local ip_pattern = "%[-([0-9A-Fa-f:%.]*)%]-:([0-9a-zA-Z]+)"

core.ntop = silly.ntop

function core.tag(fd)
	return socket_tag[fd] or "[no value]"
end

function core.listen(addr, dispatch, backlog, tag)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	if ip == "" then
		ip = "0::0"
	end
	if not backlog then
		backlog = 256 --this constant come from linux kernel comment
	end
	local id = silly.listen(ip, port, backlog);
	if id < 0 then
		core_log("[sys.core] listen", port, "error", id)
		return nil
	end
	socket_dispatch[id] = dispatch
	socket_tag[id] = tag
	return id
end

function core.bind(addr, dispatch, tag)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	if ip == "" then
		ip = "0::0"
	end
	local id = silly.bind(ip, port);
	if id < 0 then
		core_log("[sys.core] udpbind", port, "error",  id)
		return nil
	end
	socket_dispatch[id] = dispatch
	socket_tag[id] = tag
	return id

end

function core.connect(addr, dispatch, bind, tag)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	assert(ip and port, addr)
	bind = bind or ":0"
	local bip, bport = smatch(bind, ip_pattern)
	assert(bip and bport)
	local fd = silly.connect(ip, port, bip, bport)
	if fd < 0 then
		return nil
	end
	assert(socket_connect[fd] == nil)
	socket_connect[fd] = corunning()
	local ok = core.wait()
	socket_connect[fd] = nil
	if ok ~= true then
		return nil
	end
	socket_dispatch[fd] = assert(dispatch)
	socket_tag[fd]= tag
	return fd
end

function core.udp(addr, dispatch, bind, tag)
	assert(addr)
	assert(dispatch)
	local ip, port = smatch(addr, ip_pattern)
	assert(ip and port, addr)
	bind = bind or ":0"
	local bip, bport = smatch(bind, ip_pattern)
	assert(bip and bport)
	local fd = silly.udp(ip, port, bip, bport)
	if fd >= 0 then
		socket_dispatch[fd] = dispatch
		socket_tag[fd]= tag
	end
	return fd
end

function core.close(fd, tag)
	local sc = socket_dispatch[fd]
	if sc == nil then
		return false
	end
	local t = socket_tag[fd]
	if t and t ~= tag then
		error(sformat([[incorrect tag, "%s" exptected, got "%s"]],
			t, tag or "nil"))
	end
	socket_dispatch[fd] = nil
	socket_tag[fd] = nil
	assert(socket_connect[fd] == nil)
	silly.close(fd)
end

--the message handler can't be yield
local messagetype = {
	[1] = "expire",		--SILLY_TEXPIRE		= 1
	[2] = "accept",		--SILLY_SACCEPT		= 2
	[3] = "close",		--SILLY_SCLOSE		= 3
	[4] = "connected",	--SILLY_SCONNECTED	= 4
	[5] = "data",		--SILLY_SDATA		= 5
	[6] = "udp",		--SILLY_UDP		= 6
}

local MSG = {}
function MSG.expire(session, _, _)
	local co = sleep_session_co[session]
	assert(sleep_co_session[co] == session)
	sleep_session_co[session] = nil
	sleep_co_session[co] = nil
	wakeup_co_queue[#wakeup_co_queue + 1] = co
end

function MSG.accept(fd, _, portid, addr)
	assert(socket_dispatch[fd] == nil)
	assert(socket_connect[fd] == nil)
	assert(socket_dispatch[portid], portid)
	socket_dispatch[fd] = assert(socket_dispatch[portid])
	socket_tag[fd] = socket_tag[portid]
	return socket_dispatch[fd]
end

function MSG.close(fd)
	local co = socket_connect[fd]
	if co then	--connect fail
		core.wakeup(co, false)
		return nil;
	end
	local sd = socket_dispatch[fd]
	if sd == nil then	--have already closed
		return nil;
	end
	local d = socket_dispatch[fd];
	socket_dispatch[fd] = nil
	socket_tag[fd] = nil
	return d
end

function MSG.connected(fd)
	local co = socket_connect[fd]
	if co == nil then	--have already closed
		assert(socket_dispatch[fd] == nil)
		return
	end
	core.wakeup(co, true)
	return nil
end

function MSG.data(fd)
	--do nothing
	return socket_dispatch[fd]
end

function MSG.udp(fd)
	--do nothing
	return socket_dispatch[fd]
end

--fd, message, portid/errno, addr
local function dispatch(type, fd, message, ...)
	local type = messagetype[type]
	--may run other coroutine here(like connected)
	local dispatch = assert(MSG[type], type)(fd, message, ...)
	--check if the socket has closed
	if dispatch then     --have ready close
		local co = cocreate(dispatch)
		waityield(co, coresume(co, type, fd, message, ...))
	end
	dispatch_wakeup()
end

silly.dispatch(dispatch)

return core

