local core = require "silly.core"

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
        self.queue[self.pushi] = dat
        self.pushi = self.pushi + 1
        assert(self.pushi - self.popi < 0x7FFFFFFF, "channel size must less then 2G")
        if self.co then
                local co = self.co
                self.co = false
                core.wakeup(co)
        end
end

function channel.pop(self)
        if self.popi == self.pushi then
                self.popi = 1
                self.pushi = 1
                assert(not self.co)
                self.co = core.running()
                core.wait()
        end
        assert(self.popi - self.pushi < 0)
        local i = self.popi
        self.popi= i + 1
        local d = self.queue[i]
        self.queue[i] = nil
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

