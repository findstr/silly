local c = require "core.logger.c"
local logger = {
	--const from silly_log.h
	DEBUG = 0,
	INFO = 1,
	WARN = 2,
	ERROR = 3,
	--logger function export
	getlevel = c.getlevel,
	setlevel = nil,
	debug = nil,
	info = nil,
	warn = nil,
	error = nil,
}

local func_level = {
	debug = logger.DEBUG,
	info = logger.INFO,
	warn = logger.WARN,
	error = logger.ERROR,
}

local function nop()
end


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

return logger

