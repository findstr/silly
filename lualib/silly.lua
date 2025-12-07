--[[
Note:
Functions prefixed with "_" are considered internal implementation details.
They are not part of the public API and MUST NOT be used in business code.
]]

local c = require "silly.c"
local task = require "silly.task"
local logger = require "silly.logger.c"

local silly = {}

local assert = assert

local traceback = debug.traceback
local log_error = assert(logger.error)

local function errmsg(msg)
	return traceback("error: " .. tostring(msg), 2)
end

local function silly_pcall(f, ...)
	return xpcall(f, errmsg, ...)
end

function silly.error(errmsg)
	log_error(errmsg)
	log_error(traceback())
end

silly.pid = c.pid
silly.gitsha1 = c.gitsha1
silly.version = c.version
silly.allocator = c.allocator
silly.multiplexer = c.multiplexer
silly.timerresolution = c.timerresolution

silly.genid = c.genid
silly.tostring = c.tostring
silly.register = c.register
silly.pcall = silly_pcall
silly.exit = task._exit
silly._start = task._start
silly._dispatch_wakeup = task._dispatch_wakeup

return silly
