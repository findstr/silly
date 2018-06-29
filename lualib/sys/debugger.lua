local core = require "sys.core"
local socket = require "sys.socket"
local helper = require "sys.debugger.helper"
local sethook = helper.hook
local getinfo = debug.getinfo
local getlocal = debug.getlocal
local getupvalue = debug.getupvalue
local format = string.format
local coresume = coroutine.resume
local coyield = coroutine.yield

local prompt
local writedat
local debuglock
local cwrite, cread

local breakidx = 0
local breakcount = 0
local breaksource = nil
local breakline = nil

local lastfile = nil
local lastline = nil
local calllevel = nil
local nextlevel = nil
local stepmode = false
local calltrigger = nil

local hookmask = nil
local hookfunc = nil

local lockthread = nil

local livethread = nil


local function cleardat(tbl)
	if type(tbl) ~= "table" then
		return
	end
	tbl[1] = nil
	tbl[2] = nil
end

local function sethookall(hook, mask)
	hookmask = mask
	hookfunc = hook
	for co, _ in pairs(livethread) do
		sethook(co, hook, mask)
	end
end

local function hookresume(co, typ, ...)
	if typ == "STARTUP" then
		livethread[co] = true
		sethook(co, hookfunc, hookmask)
	end
	return coresume(co, typ, ...)
end

local function hookyield(typ, ...)
	if typ == "EXIT" then
		local co = core.running()
		livethread[co] = nil
		sethook(co);
	end
	return coyield(typ, ...)
end

local function breakpoint(file, line)
	breakidx = breakidx + 1
	breaksource[breakidx] = file
	breakline[breakidx] = line
	breakcount = breakcount + 1
	return breakidx
end

local function clearpoint(bid)
	if not breaksource[bid] then
		return
	end
	breaksource[bid] = nil
	breakline[bid] = nil
	breakcount = breakcount - 1
	if breakcount == 0 then
		sethookall()
	end
end

local function clearallpoint()
	for i = 1, breakidx do
		clearpoint(i)
	end
end

--------state machine

local checkcall, checkline, checklinethread, checkbreak

local function istriggered(info)
	local source = info.source
	local len = #source
	for i = 1, breakidx do
		local src = breaksource[i]
		if src and source:find(src, len - #src, true) then
			local line = breakline[i]
			local linestart = info.linedefined
			local linestop = info.lastlinedefined
			if line >= linestart and line <= linestop then
				return true
			end
		end
	end
	return false
end

local function checkhit(info, runline)
	local source = info.source
	local len = #source
	for i = 1, breakidx do
		local src = breaksource[i]
		local line = breakline[i]
		if src and source:find(src, len - #src + 1, true) then
			local line = breakline[i]
			if line ~= lastline and line == runline then
				return true
			end
		end
	end
	return false
end

local function breakin(info, runline)
	local source = info.source
	lastfile = source
	lastline = runline
	lockthread = core.running()
	prompt = format("\ndebugger %s %s:%s> ", lockthread, source, runline)
	cwrite(prompt)
	return "PAUSE"
end

local function hook_checkcall(event, line)
	local info = getinfo(2, "S")
	if info.what == "C" then
		return
	end
	assert(event == "call" or event == "tail call")
	if istriggered(info) then
		checkline()
	end
end

local function hook_checkline(event, runline)
	local info = getinfo(2, "S")
	if info.what == "C" then
		return
	end
	if event == "line" then
		if not checkhit(info, runline) then
			return
		end
		checkbreak()
		return breakin(info, runline)
	elseif event == "call" then
		calllevel = calllevel + 1
		local istrigger = istriggered(info)
		calltrigger[calllevel] = istrigger
		if istrigger then
			sethook(hook_checkline, "crl")
		else
			sethook(hook_checkline, "cr")
		end
	elseif event == "tail call" then
		if istriggered(info) then
			sethook(hook_checkline, "crl")
		else
			sethook(hook_checkline, "cr")
		end
	elseif event == "return" then
		calltrigger[calllevel] = nil
		calllevel = calllevel - 1
		if calllevel == -1 then --has no breakpoint, enter 'checkcall'
			checkcall()
		elseif calltrigger[calllevel] then
			sethook(hook_checkline, "crl")
		end
	end
end

local function hook_checkbreak(event, runline)
	local info = getinfo(2, "S")
	if info.what == "C" then
		return
	end
	if event == "line" then
		if stepmode then
			stepmode = false
			return breakin(info, runline)
		elseif checkhit(info, runline) then
			return breakin(info, runline)
		end
	elseif event == "call" then
		if stepmode == "next" and calllevel == nextlevel then
			sethook(hook_checkbreak, "cr")
		end
		calllevel = calllevel + 1
		calltrigger[calllevel] = istriggered(info)
	elseif event == "return" then
		calltrigger[calllevel] = nil
		calllevel = calllevel - 1
		if calllevel == nextlevel and stepmode == "next" then
			nextlevel = nil
			sethook(hook_checkbreak, "crl")
		end
	end
end


function checkcall()
	prompt = "debugger> "
	lastline = nil
	sethookall(hook_checkcall, "c")
end

function checkline()
	sethookall()	--only only one thread
	calllevel = 0
	calltrigger[calllevel] = true
	sethook(hook_checkline, "crl")
end

function checklinethread(co)
	calltrigger[calllevel] = true
	sethook(co, hook_checkline, "crl")
end

function checkbreak()
	sethook(hook_checkbreak, "clr")
end

-------------cmd

local CMD = {}

local function dumpstr(val)
	val = string.gsub(val, ".", function(s)
		local n = s:byte(1)
		if n >= 32 and n <= 126 then
			return s
		elseif n == 10 then
			return "\\n"
		elseif n == 13 then
			return "\\r"
		else
			return format("\\x%02x", n)
		end
	end)
	return val
end

local function dumptbl(tbl, out, breakloop)
	breakloop = breakloop or {}
	breakloop[tbl] = true
	out[#out + 1] = "{"
	for k, v in pairs(tbl) do
		local key
		if type(k) == "string" then
			key = format("'%s'", k)
		else
			key = k
		end
		local typ = type(v)
		if typ == "table" then
			if not breakloop[v] then
				out[#out + 1] = format("[%s] = ", key)
				dumptbl(v, out, breakloop)
				out[#out + 1] = ","
			end
		elseif typ == "string" then
			out[#out + 1] = format("[%s] = '%s',", key, dumpstr(v))
		else
			out[#out + 1] = format("[%s] = %s,", key, v)
		end
	end
	out[#out + 1] = "}"
end

local function dumpval(title, i, name, val)
	if type(val) == "table" then
		local out = {}
		dumptbl(val, out)
		val = table.concat(out, "")
		return format("%s $%s %s = %s\n", title, i, name, val)
	elseif type(val) == "string" then
		val = dumpstr(val)
		return format("%s $%s %s = '%s'\n", title, i, name, val)
	else
		return format("%s $%s %s = %s\n", title, i, name, val)
	end
end


local ERR = "Pragram is runing, need trigger a breakpoint first\n"

function CMD.h()
	writedat[1] = [[
List of commands:
b: Insert a break point [b 'filename linenumber']
d: Delete a break point [d 'breakpoint id']
n: Step next line, it will over the call [n]
s: Step next line, it will into the call [s]
c: Continue program being debugged [c]
p: Print variable include local/up/global values [p name]
bt: Print backtrace of all stack frames [bt]
q: Quit debug mode [q]
]]
	writedat[2] = prompt
	return writedat
end

function CMD.b(file, line)--break
	if not file then
		file = lastfile
	end
	writedat[2] = prompt
	if not file then
		writedat[1] = "Invalid file name\n"
		return writedat
	end
	line = tonumber(line)
	if not line then
		writedat[1] = "Invalid line number\n"
		return writedat
	end
	local bid = breakpoint(file, line)
	checkcall()
	writedat[1] = format("Breakpoint $%s at file:%s, line:%s\n",
		bid, file, line)
	return writedat
end

function CMD.d(id)
	if not id then
		clearallpoint()
	else
		id = tonumber(id)
		clearpoint(id)
	end
	writedat[1] = format("Delete breakpoint $%s\n", id or "ALL")
	writedat[2] = prompt
	return writedat
end

function CMD.n() --next
	if not lockthread then
		writedat[1] = ERR
		writedat[2] = prompt
		return writedat
	end
	nextlevel = calllevel
	stepmode = "next"
	core.wakeup(lockthread)
	lockthread = nil
	return "\n"
end

function CMD.s()	--step
	if not lockthread then
		writedat[1] = ERR
		writedat[2] = prompt
		return writedat
	end
	stepmode = "step"
	core.wakeup(lockthread)
	lockthread = nil
	return
end

function CMD.c()	--continue
	if not lockthread then
		writedat[1] = ERR
		writedat[2] = prompt
		return writedat
	end
	core.wakeup(lockthread)
	checklinethread(lockthread)
	lockthread = nil
	prompt = "debugger> "
	writedat[1] = prompt
	return writedat
end

function CMD.p(pname)
	writedat[2] = prompt
	if not lockthread then
		writedat[1] = ERR
		return writedat
	end
	if not pname then
		writedat[1] = "Please input a variable name\n"
		return writedat
	end
	local info = getinfo(lockthread, 0, "uf")
	local i = 1
	while true do
		local name, val = getlocal(lockthread, 0, i)
		if not name then
			break
		end
		if name == pname then
			writedat[1] = dumpval("Param", i, name, val)
			return writedat
		end
		i = i + 1
	end
	local func = info.func
	for i = 1, info.nups do
		local name, val = getupvalue(func, i)
		if name == pname then
			writedat[1] = dumpval("Upvalue", i, name, val)
			return writedat
		end
	end
	local val = _ENV[pname]
	if val then
		writedat[1] = dumpval("Global", "_ENV", pname, val)
		return writedat
	end
	writedat[1] = format("Variable %s nonexist\n", pname)
	return writedat
end

function CMD.bt()
	writedat[2] = prompt
	if not lockthread then
		writedat[1] = ERR
		return writedat
	end
	writedat[1] = debug.traceback(lockthread, nil, 0) .. "\n"
	return writedat
end

local function enter()
	writedat = {}
	debuglock = true
	breakidx = 0
	breakcount = 0
	breaksource = {}
	breakline = {}

	lastfile = nil
	lastline = nil
	calllevel = nil
	nextlevel = nil
	stepmode = false
	calltrigger = {}

	hookmask = nil
	hookfunc = nil

	lockthread = nil

	livethread = {}
	setmetatable(livethread, {__mode="k"})
end

local function leave()
	writedat = nil
	debuglock = nil
	cwrite = nil
	cread = nil
	prompt = nil

	clearallpoint()
	breakidx = nil
	breakcount = nil
	breaksource = nil
	breakline = nil

	lastfile = nil
	lastline = nil
	calllevel = nil
	nextlevel = nil
	stepmode = nil
	calltrigger = nil

	hookmask = nil
	hookfunc = nil

	lockthread = nil
	livethread = nil
end

function CMD.q()
	if lockthread then
		core.wakeup(lockthread)
	end
	leave()
end

local function cmdline(fd)
	prompt = "debugger> "
	cwrite(prompt)
	local param = {}
	while true do
		local default
		local l = cread()
		if not l then
			return
		end
		default = l == "\n" or l == "\r\n"
		if not default then
			for k, _ in ipairs(param) do
				param[k] = nil
			end
			for w in string.gmatch(l, "%g+") do
				param[#param + 1] = w
			end
			param[1] = string.lower(param[1])
		end
		if param[1] == "q" then
			cwrite("Bye, Bye!\n")
			return ""
		end
		local func = CMD[param[1]]
		if func then
			local ret = func(table.unpack(param, 2))
			if ret then
				cwrite(ret)
				cleardat(ret)
			end
		else
			cwrite(format("Undefined command: %s\n%s",
				param[1], prompt))
		end
	end
end


local M = {
start = function(read, write)
	if debuglock then
		return 'debugger is already opened by other user'
	end
	enter()
	cread = read
	cwrite = write
	core.coroutine(hookresume, hookyield)
	local ok, err = core.pcall(cmdline)
	core.coroutine(coresume, coyield)
	CMD.q()
	if not ok then
		core.log(err)
		return
	end
	return err
end,
}

return M

