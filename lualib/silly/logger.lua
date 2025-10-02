local silly = require "silly"
local signal = require "silly.signal"
local env = require "silly.env"
local c = require "silly.logger.c"

local function nop(...)end

local logger = {
	--const from silly_log.h
	DEBUG = 0,
	INFO = 1,
	WARN = 2,
	ERROR = 3,
	--logger function export
	getlevel = c.getlevel,
	setlevel = nil,
	debug = nop,
	info = nop,
	warn = nop,
	error = nop,
	debugf = nop,
	infof = nop,
	warnf = nop,
	errorf = nop,
}

local func_level = {
	debug = logger.DEBUG,
	debugf = logger.DEBUG,
	info = logger.INFO,
	infof = logger.INFO,
	warn = logger.WARN,
	warnf = logger.WARN,
	error = logger.ERROR,
	errorf = logger.ERROR,
}

local function refresh(visiable_level)
	for name, level in pairs(func_level) do
		if level >= visiable_level then
			logger[name] = c[name]
		else
			logger[name] = nop
		end
	end
end

refresh(logger.getlevel())


function logger.setlevel(level)
	refresh(level)
	c.setlevel(level)
end

signal("SIGUSR1", function(_)
	local path = env.get("logpath")
	if not path then
		return
	end
	c.openfile(path)
end)

return logger

