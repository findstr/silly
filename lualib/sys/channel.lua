local core = require "sys.core"
local assert = assert
local tremove = table.remove
local tpack = table.pack
local tunpack = table.unpack

local channel = {}

local mt = {__index = channel}

function channel.channel()
	local obj = {}
	obj.queue = {}
	obj.co = false
	obj.popi = 1
	obj.pushi = 1
	setmetatable(obj, mt)
	return obj
end

function channel.push(self, dat)
	local pushi = self.pushi
	self.queue[pushi] = dat
	pushi = pushi + 1
	self.pushi = pushi
	assert(pushi - self.popi < 0x7FFFFFFF, "channel size must less then 2G")
	local co = self.co
	if co then
		self.co = false
		core.wakeup(co)
	end
end

function channel.pop(self)
	if self.popi == self.pushi then
		self.popi = 1
		self.pushi = 1
		assert(not self.co)
		local co = core.running()
		self.co = co
		core.wait(co)
	end
	assert(self.popi - self.pushi < 0)
	local i = self.popi
	self.popi= i + 1
	local queue = self.queue
	local d = queue[i]
	queue[i] = nil
	return d
end

function channel.push2(self, ...)
	channel.push(self, tpack(...))
end

function channel.pop2(self)
	local dat = channel.pop(self)
	return tunpack(dat, 1, dat.n)
end

return channel

