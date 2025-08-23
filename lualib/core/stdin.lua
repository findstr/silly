local hive = require "core.hive"
local logger = require "core.logger"
local unpack = table.unpack

local bee = hive.spawn([[
	local stdin = io.stdin
	return function(fn, ...)
		return stdin[fn](stdin, ...)
	end
]])

local M = {}
function M:__close()
	-- do nothing
end

function M:close()
	-- do nothing
end

function M:flush()
	logger.error("can't flush stdin")
end

function M:seek(whence, offset)
	logger.error("can't seek stdin")
end

function M:setvbuf(mode, size)
	logger.error("can't setvbuf stdin")
end

function M:write(...)
	logger.error("can't write stdin")
end

function M:read(...)
	return hive.invoke(bee, "read", ...)
end

local function lines_iter(args)
	return M:read(unpack(args))
end

function M:lines(...)
	local args = {...}
	if #args == 0 then
		args = {"l"}
	end
	return lines_iter, args, nil
end

io.stdin = M


return M
