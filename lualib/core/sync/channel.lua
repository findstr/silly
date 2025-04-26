local core = require "core"
local assert = assert

---@class core.sync.channel
---@field queue table
---@field closed boolean
---@field co thread|nil
---@field popi integer
---@field pushi integer
local channel = {}

local mt = {__index = channel}

---@return core.sync.channel
function channel.new()
	local obj = {
		queue = {},
		co = nil,
		popi = 1,
		pushi = 1,
		closed = false,
	}
	setmetatable(obj, mt)
	return obj
end

---@param self core.sync.channel
---@param dat any
---@return boolean, string? error
function channel.push(self, dat)
	if self.closed then
		return false, "channel closed"
	end
	local pushi = self.pushi
	self.queue[pushi] = dat
	pushi = pushi + 1
	assert(pushi - self.popi < 0x7FFFFFFF, "channel size must less then 2G")
	self.pushi = pushi
	local co = self.co
	if co then
		self.co = nil
		core.wakeup(co)
	end
	return true, nil
end

function channel.pop(self)
	if self.popi == self.pushi then
		if self.closed then
			return nil, "channel closed"
		end
		assert(not self.co)
		self.co = core.running()
		core.wait()
		if self.popi == self.pushi then
			return nil, "channel closed"
		end
	end
	assert(self.popi - self.pushi < 0)
	local i = self.popi
	local popi = i + 1
	if popi == self.pushi then
		self.popi = 1
		self.pushi = 1
	else
		self.popi= popi
	end
	local queue = self.queue
	local d = queue[i]
	queue[i] = nil
	return d, nil
end

function channel.clear(self)
	for i = self.popi, self.pushi do
		self.queue[i] = nil
	end
	self.popi = 1
	self.pushi = 1
end

function channel.close(self)
	self.closed = true
	local co = self.co
	if co then
		self.co = nil
		core.wakeup(co)
	end
end

return channel

