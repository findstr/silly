local core = require "silly.core"

local tremove = table.remove
local tinsert = table.insert
local tpack = table.pack
local tunpack = table.unpack

local channel = {}

local mt = {__index = channel}

function channel.channel()
        local obj = {}
        obj.queue = {}
        obj.co = false
        setmetatable(obj, mt)
        return obj
end

function channel.push(self, dat)
        tinsert(self.queue, dat)
        if self.co then
                local co = self.co
                self.co = false
                core.wakeup(co)
        end
end

function channel.pop(self)
        if #self.queue == 0 then
                assert(not self.co)
                self.co = core.running()
                core.wait()
        end
        return tremove(self.queue, 1)
end

function channel.push2(self, ...)
        channel.push(self, tpack(...))
end

function channel.pop2(self)
        local dat = channel.pop(self)
        return tunpack(dat, 1, dat.n)
end

return channel

