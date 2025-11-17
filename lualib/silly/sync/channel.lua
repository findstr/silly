local task = require "silly.task"
local queue = require "silly.adt.queue"
local assert = assert
local setmetatable = setmetatable
local wakeup = task.wakeup
local qnew = queue.new
local qpop = queue.pop
local qpush = queue.push
local qclear = queue.clear

---@class silly.sync.channel
---@field queue userdata
---@field closed boolean
---@field co thread|nil
local channel = {}

local mt = {__index = channel}

---@return silly.sync.channel
function channel.new()
	local obj = {
		queue = qnew(),
		co = nil,
		closed = false,
	}
	setmetatable(obj, mt)
	return obj
end

---@param self silly.sync.channel
---@param dat any
---@return boolean, string? error
function channel.push(self, dat)
	if not dat then
		return false, "nil data"
	end
	if self.closed then
		return false, "channel closed"
	end
	local co = self.co
	if co then
		self.co = nil
		wakeup(co, dat)
	else
		qpush(self.queue, dat)
	end
	return true, nil
end

function channel.pop(self)
	local dat = qpop(self.queue)
	if not dat then
		if self.closed then
			return nil, "channel closed"
		end
		assert(not self.co)
		self.co = task.running()
		local dat = task.wait()
		if not dat then
			return nil, "channel closed"
		end
		return dat, nil
	end
	return dat, nil
end

function channel.clear(self)
	qclear(self.queue)
end

function channel.close(self)
	self.closed = true
	local co = self.co
	if co then
		self.co = nil
		task.wakeup(co)
	end
end

return channel