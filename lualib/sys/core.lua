local silly = require "sys.silly"

local core = {}
local next = next
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

--coroutine
local cocreate_ = coroutine.create
local corunning = coroutine.running
local coyield = coroutine.yield
local coresume = coroutine.resume
--misc
local core_log = silly.log
core.log = core_log
core.tostring = silly.tostring
core.genid = silly.genid
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

local function cocreate(f)
	local k, co = next(copool)
	if co then
		copool[k] = nil
		coresume(co, "STARTUP", f)
		return co
	end
	co = cocreate_(function(...)
		local ok, err = core_pcall(f, ...)
		if not ok then
			core_log("[sys.core] call", err)
		end
		while true do
			local ret
			copool[#copool + 1] = corunning()
			ret, f = coyield("EXIT")
			if ret ~= "STARTUP" then
				core_log("[sys.core] coroutine create", ret)
				core_log(traceback())
				return
			end
			local ok, err = core_pcall(f, coyield("ARGS"))
			if ok == false then
				core_log("[sys.core] call", err)
			end
		end
	end)
	return co
end

local wakeup_co_queue = {}
local wakeup_co_param = {}
local sleep_co_session = {}
local sleep_session_co = {}

local dispatch_wakeup

core.exit = function(status)
	silly.dispatch(function() end)
	wakeup_co_queue = {}
	wakeup_co_param = {}
	silly.exit(status)
	coyield()
end

function dispatch_wakeup()
	while true do
		local co = tremove(wakeup_co_queue, 1)
		if not co then
			return
		end
		local param = wakeup_co_param[co]
		wakeup_co_param[co] = nil
		local ok, err = coresume(co, param)
		if not ok then
			local ret = traceback(co, "error: " .. tostring(err), 1)
			core_log("[sys.core] wakeup", ret)
		end
	end
end

function core.fork(func)
	local co = cocreate(func)
	wakeup_co_queue[#wakeup_co_queue + 1] = co
	return co
end

function core.wait(co)
	co = co or corunning()
	assert(sleep_co_session[co] == nil)
	return coyield("WAIT")
end

function core.wait2(co)
	local res = core.wait(co)
	if not res then
		return
	end
	return tunpack(res, 1, res.n)
end

function core.wakeup(co, res)
	wakeup_co_param[co] = res
	wakeup_co_queue[#wakeup_co_queue + 1] = co
end

function core.wakeup2(co, ...)
	core.wakeup(co, tpack(...))
end

function core.sleep(ms)
	local co = corunning()
	local session = silly_timeout(ms)
	sleep_session_co[session] = co
	sleep_co_session[co] = session
	coyield("SLEEP")
end

function core.timeout(ms, func)
	local co = cocreate(func)
	local session = silly_timeout(ms)
	sleep_session_co[session] = co
	sleep_co_session[co] = session
	return session
end

function core.start(func)
	local co = cocreate(func)
	coresume(co)
	dispatch_wakeup()
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
	local co = corunning()
	socket_connecting[fd] = co
	local ok = core.wait(co)
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
local messagetype = {
	[1] = "expire",		--SILLY_TEXPIRE		= 1
	[2] = "accept",		--SILLY_SACCEPT		= 2
	[3] = "close",		--SILLY_SCLOSE		= 3
	[4] = "connected",	--SILLY_SCONNECTED	= 4
	[5] = "data",		--SILLY_SDATA		= 5
	[6] = "udp",		--SILLY_UDP		= 6
}

local MSG = {
[1] = function(session)					--SILLY_TEXPIRE = 1
	local co = sleep_session_co[session]
	assert(sleep_co_session[co] == session)
	sleep_session_co[session] = nil
	sleep_co_session[co] = nil
	wakeup_co_queue[#wakeup_co_queue + 1] = co
end,
[2] = function(fd, _, portid, addr)			--SILLY_SACCEPT = 2
	assert(socket_dispatch[fd] == nil)
	assert(socket_connecting[fd] == nil)
	local cb = socket_dispatch[portid]
	assert(cb, portid)
	socket_dispatch[fd] = cb
	local co = cocreate(cb)
	coresume(co, "accept", fd, _, portid,addr)
end,
[3] = function(fd, _, errno)				--SILLY_SCLOSE = 3
	local co = socket_connecting[fd]
	if co then	--connect fail
		core.wakeup(co, false)
		return
	end
	local f = socket_dispatch[fd]
	if f then	--is connected
		socket_dispatch[fd] = nil
		local co = cocreate(f)
		coresume(co, "close", fd, _, errno)
	end
end,
[4] = function(fd)					--SILLY_SCONNECTED = 4
	local co = socket_connecting[fd]
	if co == nil then	--have already closed
		assert(socket_dispatch[fd] == nil)
		return
	end
	coresume(co, true)
end,
[5] = function(fd, msg)					--SILLY_SDATA = 5
	local f = socket_dispatch[fd]
	if f then
		local co = cocreate(f)
		coresume(co, "data", fd, msg)
	else
		core_log("[sys.core] SILLY_SDATA fd:", fd, "closed")
	end
end,
[6] = function(fd, msg, addr)				--SILLY_UDP = 6
	local f = socket_dispatch[fd]
	if f then
		local co = cocreate(f)
		coresume(co, "udp", fd, msg, addr)
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

