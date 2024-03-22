local core = require "core"
local logger = require "core.logger"
local M = {}
local mt = {__index = M}

function M:create()
	return setmetatable({count = 0}, mt)
end

function M:fork(func)
	self.count = self.count +1
	core.fork(function()
		local ok, err = core.pcall(func)
		if not ok then
			logger.error("[waitgroup] fork err:", err)
		end
		local n = self.count - 1
		self.count = n
		if n <= 0 then
			local co = self.waitco
			if co then
				self.waitco = nil
				core.wakeup(co)
			end
		end
	end)
end

function M:wait()
	local n = self.count
	if n <= 0 then
		return
	end
	local co = core.running()
	self.waitco = co
	core.wait()
end

return M

