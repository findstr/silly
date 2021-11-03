local core = require "sys.core"
local patch = require "sys.patch"
local socket = require "sys.socket"
local debugger = require "sys.debugger"
local type = type
local pairs = pairs
local pcall = pcall
local assert = assert
local select = select
local loadfile = loadfile
local tonumber = tonumber
local lower = string.lower
local format = string.format
local concat = table.concat
local insert = table.insert
local unpack = table.unpack

local NULL = ""
local prompt = "console> "
local desc = {
"HELP: List command description. [HELP]",
"PING: Test connection alive. [PING <text>]",
"GC: Performs a full garbage-collection cycle. [GC]",
"INFO: Show all information of server, include CPUINFO,MINFO,QINFO. [INFO]",
"MINFO: Show memory infomation. [MINFO <kb|mb>]",
"QINFO: Show framework message queue size. [QINFO]",
"NETINFO: Show network info. [NETINFO]",
"TIMERINFO: Show timer pending/process event count. [TIMERINFO]",
"CPUINFO: Show system time and user time statistics. [CPUINFO]",
"SOCKET: Show socket detail information. [SOCKET]",
"TASK: Show all task status and traceback. [TASK]",
"INJECT: INJECT code. [INJECT <path>]",
"DEBUG: Enter Debug mode. [DEBUG]",
"QUIT: Quit the console. [QUIT]",
}


local console = {}

local envmt = {__index = _ENV}

function console.help()
	return desc
end

function console.quit()
	return nil
end

function console.exit()
	return nil
end

function console.ping(_, txt)
	return txt or "PONG"
end

function console.gc()
	collectgarbage()
	return format("Lua Mem Used:%.2f KiB", collectgarbage("count"))
end

function console.timerinfo()
	return format("#Timer\r\n\z
		resolution:%s\r\n\z
		active:%s\r\n\z
		expired:%s\r\n",
		core.timerrs, core.timerinfo())
end

function console.cpuinfo()
	local sys, usr = core.cpuinfo()
	return format("#CPU\r\ncpu_sys:%.2fs\r\ncpu_user:%.2fs", sys, usr)
end

local function format_size(fmt, size)
	if fmt == "kb" then
		return format("%.2f KiB", size / 1024)
	elseif fmt == "mb" then
		return format("%.2f MB", size / (1024 * 1024))
	else
		return format("%d B", size)
	end
end

function console.minfo(_, fmt)
	if fmt then
		fmt = lower(fmt)
	else
		fmt = NULL
	end
	local sz = core.memused()
	local rss = core.memrss()
	local allocated, active, resident = core.allocatorinfo()
	local tbl = {
		"#Memory",
		"\r\nused_memory:",
		format_size(fmt, sz),
		"\r\nused_memory_rss:",
		format_size(fmt, rss),
		"\r\nallocator_allocated:",
		format_size(fmt, allocated),
		"\r\nallocator_active:",
		format_size(fmt, active),
		"\r\nallocator_resident:",
		format_size(fmt, resident),
		"\r\nmemory_fragmentation_ratio:",
		format("%.2f", rss / sz),
		"\r\nmemory_allocator:",
		core.allocator,
	}
	return concat(tbl)
end

function console.qinfo()
	local sz = core.msgsize();
	return format("#Message\r\nmessage pending:%d", sz)
end

function console.netinfo()
	local info = core.netinfo()
	local a = format("#NET\r\ntcp_listen:%s\r\ntcp_client:%s\r\n\z
		tcp_connecting:%s\r\ntcp_halfclose:%s\r\n", info.tcplisten,
		info.tcpclient, info.connecting, info.tcphalfclose)
	local b = format("udp_bind:%s\r\nudp_client:%s\r\n",
		info.udpbind, info.udpclient)
	local c = format("send_buffer_size:%s\r\n", info.sendsize)
	return a .. b .. c
end

function console.task(fd)
	local buf = {}
	local tasks = core.tasks()
	local i, j = 0, 1
	for co, info in pairs(tasks) do
		i = i + 1
		j = j + 1
		buf[j] = format("Task %s - %s :", co, info.status)
		j = j + 1
		buf[j] = info.traceback .. "\r\n\r\n"
	end
	buf[1] = format("#Task (%s)\r\n", i)
	return concat(buf)
end

function console.socket(_, fd)
	if not fd then
		return "lost fd argument"
	end
	local info = core.socketinfo(fd)
	local a, b = format("#Socket\r\nfd:%s\r\nos_fd:%s\r\ntype:%s\r\n\z
		protocol:%s\r\nsendsize:%s\r\n", info.fd, info.os_fd,
		info.type, info.protocol, info.sendsize), ""
	if info.localaddr ~= "" then
		b = info.localaddr .. "<->" .. info.remoteaddr
	end
	return a .. b .. "\r\n"
end

function console.info()
	local tbl = {}
	local uptime = core.monotonicsec()
	insert(tbl, "#Server")
	insert(tbl, format("version:%s", core.version))
	insert(tbl, format("process_id:%s", core.getpid()))
	insert(tbl, format("multiplexing_api:%s", core.pollapi))
	insert(tbl, format("uptime_in_seconds:%s", uptime))
	insert(tbl, format("uptime_in_days:%.2f\r\n", uptime / (24 * 3600)))
	insert(tbl, console.cpuinfo())
	insert(tbl, NULL)
	insert(tbl, console.qinfo())
	insert(tbl, NULL)
	insert(tbl, console.minfo(nil, "MB"))
	insert(tbl, NULL)
	insert(tbl, console.timerinfo())
	return concat(tbl, "\r\n")
end

function console.inject(_, filepath)
	if not filepath then
		return "ERR lost the filepath"
	end
	local ENV = setmetatable({}, envmt)
	local ok, err = pcall(loadfile, filepath, "bt", ENV)
	if ok then
		ok, err = pcall(err)
	end
	local fmt = "Inject file:%s %s"
	if ok then
		return format(fmt, filepath, "Success")
	else
		return format(fmt, filepath, err)
	end
end

function console.debug(fd)
	local read = function ()
		return socket.readline(fd)
	end
	local write = function(dat)
		return socket.write(fd, dat)
	end
	return debugger.start(read, write)
end

local function process(fd, config, param, l)
	if l == "\n" or l == "\r\n" then
		return ""
	end
	if #param == 0 then
		return format("ERR unknown '%s'\n", l)
	end
	local cmd = lower(param[1])
	local func = console[cmd]
	if not func then
		if config.cmd then
			func = config.cmd[cmd]
		end
	end
	if func then
		return func(fd, unpack(param, 2))
	end
	return format("ERR unknown command '%s'", param[1])
end

local function clear(tbl)
	for i = 1, #tbl do
		tbl[i] = nil
	end
end

return function (config)
	socket.listen(config.addr, function(fd, addr)
		core.log("console come in:", addr)
		local param = {}
		local dat = {}
		socket.write(fd, "\nWelcome to console.\n\n")
		socket.write(fd, "Type 'help' for help.\n\n")
		socket.write(fd, prompt)
		while true do
			local l = socket.readline(fd)
			if not l then
				break
			end
			for w in string.gmatch(l, "%g+") do
				param[#param + 1] = w
			end
			local res = process(fd, config, param, l)
			if not res then
				dat[1] = "Bye, Bye\n"
				socket.write(fd, dat)
				clear(dat)
				socket.close(fd)
				break
			end
			if type(res) == "table" then
				dat[1] = concat(res, "\n")
			else
				dat[1] = res
			end
			dat[2] = "\n"
			dat[3] = prompt
			socket.write(fd, dat)
			clear(dat)
			for i = 1, #param do
				param[i] = nil
			end
		end
		core.log(addr, "leave")
end)

end

