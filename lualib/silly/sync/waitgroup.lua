local silly = require "silly"
local task = require "silly.task"
local logger = require "silly.logger"
---@class silly.sync.waitgroup
---@field count integer
local M = {}
local mt = {__index = M}

---@return silly.sync.waitgroup
function M.new()
	return setmetatable({count = 0}, mt)
end

function M:fork(func)
	self.count = self.count +1
	local co = task.fork(function()
		local ok, err = silly.pcall(func)
		if not ok then
			logger.error("[waitgroup] fork err:", err)
		end
		local n = self.count - 1
		self.count = n
		if n <= 0 then
			local co = self.waitco
			if co then
				self.waitco = nil
				task.wakeup(co)
			end
		end
	end)
	return co
end

function M:wait()
	local n = self.count
	if n <= 0 then
		return
	end
	local co = task.running()
	self.waitco = co
	task.wait()
end

return M