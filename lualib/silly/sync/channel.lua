local task = require "silly.task"
local queue = require "silly.adt.queue"
local assert = assert
local setmetatable = setmetatable
local wakeup = task.wakeup
local qnew = queue.new
local qpop = queue.pop
local qpush = queue.push
local qclear = queue.clear

---@class silly.sync.channel<T>
---@field queue silly.adt.queue
---@field reason string?
---@field co thread|nil
local channel = {}

local mt = {__index = channel}

---@return silly.sync.channel
function channel.new()
	local obj = {
		queue = qnew(),
		co = nil,
		reason = nil,
	}
	setmetatable(obj, mt)
	return obj
end

---@generic T
---@param self silly.sync.channel<T>
---@param dat T
---@return boolean, string? error
function channel.push(self, dat)
	if not dat then
		return false, "nil data"
	end
	local reason = self.reason
	if reason then
		return false, reason
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

---@generic T
---@param self silly.sync.channel<T>
---@return T?, string? error
function channel.pop(self)
	local dat = qpop(self.queue)
	if not dat then
		local reason = self.reason
		if reason then
			return nil, reason
		end
		local co = self.co
		if co then
			return nil, "channel is mpsc"
		end
		self.co = task.running()
		local dat = task.wait()
		if not dat then
			return nil, self.reason
		end
		return dat, nil
	end
	return dat, nil
end

---@generic T
---@param self silly.sync.channel<T>
function channel.clear(self)
	qclear(self.queue)
end

---@generic T
---@param self silly.sync.channel<T>
---@param reason string?
function channel.close(self, reason)
	self.reason = reason or "channel closed"
	local co = self.co
	if co then
		self.co = nil
		task.wakeup(co)
	end
end

return channel
