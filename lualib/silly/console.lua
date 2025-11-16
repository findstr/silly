local silly = require "silly"
local metrics = require "silly.metrics.c"
local prometheus = require "silly.metrics.prometheus"
local logger = require "silly.logger"
local tcp = require "silly.net.tcp"
local debugger = require "silly.debugger"
local type = type
local pairs = pairs
local pcall = pcall
local loadfile = loadfile
local lower = string.lower
local format = string.format
local concat = table.concat
local unpack = table.unpack

local prompt = "console> "
local desc = {
"HELP: List command description. [HELP]",
"PING: Test connection alive. [PING <text>]",
"GC: Performs a full garbage-collection cycle. [GC]",
"INFO: Show all information of server. [INFO]",
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

function console.task(fd)
	local buf = {}
	local tasks = silly.tasks()
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
	local info = metrics.socketinfo(fd)
	local a, b = format("#Socket\r\nfd: %s\r\nos_fd: %s\r\ntype: %s\r\n\z
		protocol: %s\r\nsendsize: %s\r\n", info.fd, info.os_fd,
		info.type, info.protocol, info.sendsize), ""
	if info.localaddr ~= "" then
		b = info.localaddr .. "<->" .. info.remoteaddr
	end
	return a .. b .. "\r\n"
end

function console.info()
	local buf = {}
	buf[#buf + 1] = ""
	buf[#buf + 1] = "#Build"
	buf[#buf + 1] = format("version:%s", silly.version)
	buf[#buf + 1] = format("git_sha1:%s", silly.gitsha1)
	buf[#buf + 1] = format("multiplexing_api:%s", metrics.pollapi())
	buf[#buf + 1] = format("memory_allocator:%s", metrics.memallocator())
	buf[#buf + 1] = format("timer_resolution:%s ms", metrics.timerresolution())
	buf[#buf + 1] = ""
	local list = {}
	local collectors = prometheus.registry()
	for i = 1, #collectors do
		local collector = collectors[i]
		local n = collector:collect(list)
		local name = collector.name
		buf[#buf + 1] = "#" .. name
		if name == "Process" then
			buf[#buf + 1] = format("process_id:%s", silly.pid)
		end
		for j = 1, n do
			local m = list[j]
			local name = m.name
			if m.labelnames then
				for j = 1, #m do
					local v = m[j]
					buf[#buf + 1] = format('%s%s:%s',
						name, v[2], v[1])
				end
			else
				buf[#buf + 1] = format('%s:%s', name, m[1])
			end
		end
		buf[#buf + 1] = ""
	end
	return concat(buf, "\r\n")
end

function console.inject(_, filepath)
	if not filepath then
		return "ERR lost the filepath"
	end
	local ok
	local ENV = setmetatable({}, envmt)
	local chunk, err = loadfile(filepath, "bt", ENV)
	if chunk then
		ok, err = pcall(chunk)
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
		return tcp.read(fd, "\n")
	end
	local write = function(dat)
		return tcp.write(fd, dat)
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
tcp.listen {
	addr = config.addr,
	accept = function(fd)
		local addr = fd:remoteaddr()
		logger.info("console come in:", addr)
		local param = {}
		local dat = {}
		tcp.write(fd, "\nWelcome to console.\n\n")
		tcp.write(fd, "Type 'help' for help.\n\n")
		tcp.write(fd, prompt)
		while true do
			local l, err = tcp.read(fd, "\n")
			if err then
				break
			end
			for w in string.gmatch(l, "%g+") do
				param[#param + 1] = w
			end
			local res = process(fd, config, param, l)
			if not res then
				dat[1] = "Bye, Bye\n"
				tcp.write(fd, dat)
				clear(dat)
				tcp.close(fd)
				break
			end
			if type(res) == "table" then
				dat[1] = concat(res, "\n")
			else
				dat[1] = res
			end
			dat[2] = "\n"
			dat[3] = prompt
			tcp.write(fd, dat)
			clear(dat)
			for i = 1, #param do
				param[i] = nil
			end
		end
		logger.info(addr, "leave")
	end
}

end

