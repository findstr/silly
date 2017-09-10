local core = require "silly.core"
local patch = require "silly.patch"
local socket = require "socket"

local desc = {

"HELP: List command description [HELP]",
"PING: Test connection alive [PING <text>]",
"MINFO: Show memory infomation [MINFO <kb|mb>]",
"QINFO: Show framework message queue size[QINFO]",
"PATCH: Hot patch the code [PATCH <fixfile> <modulename> <funcname> ...]"

}


local console = {}

local envmt = {__index = _ENV}

local function _patch(fixfile, module, ...)
	local ENV = {}
	local funcs = {}
	local funcname = {...}
	assert(#funcname > 0, "function list is empty")
	setmetatable(ENV, envmt)
	local runm = require(module)
	local fixm = assert(loadfile(fixfile, "bt", ENV))()
	assert(runm and type(runm) == "table")
	assert(fixm and type(fixm) == "table")
	for k, v in pairs(funcname) do
		local funcid = tonumber(v)
		if funcid then
			funcname[k] = funcid
			v = funcid
		end
		local runf = assert(runm[v], "run code has no function")
		local fixf = assert(fixm[v], "fix code has no function")
		funcs[#funcs + 1] = fixf
		funcs[#funcs + 1] = runf
	end
	patch(ENV, table.unpack(funcs))
	for k, v in pairs(funcname) do
		runm[v] = assert(fixm[v])
	end
	return
end


function console.help()
	return desc
end

function console.quit()
	return nil
end

function console.exit()
	return nil
end

function console.ping(txt)
	return txt or "PONG"
end

function console.minfo(fmt)
	local sz = core.memstatus()
	fmt = fmt or ""
	fmt = string.lower(fmt)
	if fmt == "kb" then
		return string.format("Memory Used:%d KByte", sz // 1024)
	elseif fmt == "mb" then
		return string.format("Memory Used:%d MByte", sz // (1024 * 1024))
	else
		return string.format("Memory Used:%d Byte", sz)
	end
end

function console.qinfo()
	local sz = core.msgstatus();
	return string.format("Message Queue Count:%d", sz)
end

function console.patch(fix, module, ...)
	if not fix then
		return "ERR lost the fix file name"
	elseif not module then
		return "ERR lost the module file name"
	elseif select("#", ...) == 0 then
		return "ERR lost the function name"
	end
	local ok, err = pcall(_patch, fix, module, ...)
	local fmt = "Patch module:%s function:%s by:%s %s"
	if ok then
		return string.format(fmt, module, funcname, fix, "Success")
	else
		return string.format(fmt, module, funcname, fix, err)
	end
end

local function process(config, param, l)
	if l == "\n" or l == "\r\n" then
		return ""
	end
	if #param == 0 then
		return string.format("ERR unknown '%s'\n", l)
	end
	local cmd = string.lower(param[1])
	local func = console[cmd]
	if not func then
		if config.cmd then
			func = config.cmd[cmd]
		end
	end
	if func then
		return func(table.unpack(param, 2))
	end
	return string.format("ERR unknown command '%s'\n", param[1])
end


return function (config)
	socket.listen(config.addr, function(fd, addr)
		core.log("console come in:", addr)
		local param = {}
		while true do
			local l = socket.readline(fd)
			if not l then
				break
			end
			for w in string.gmatch(l, "%g+") do
				param[#param + 1] = w
			end
			local res = process(config, param, l)
			if not res then
				socket.close(fd)
				break
			end

			local echo = "\n"
			if type(res) == "table" then
				echo = table.concat(res, "\n")
			else
				echo = res
			end
			echo = echo .. "\n\n"
			socket.write(fd, echo)
			for i = 1, #param do
				param[i] = nil
			end
		end
		core.log(addr, "leave")
end)

end

