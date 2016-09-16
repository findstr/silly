local core = require "silly.core"

local tremove = table.remove
local tinsert = table.insert
local tpack = table.pack
local tunpack = table.unpack


local channel = {}

local mt = {__index = channel}

local function start(self, func)
        core.fork(function()
                while true do
                        if #self.queue == 0 then
                                self.co = core.running()
                                local ok, err = core.pcall(func, core.wait())
                                assert(not self.co)
                                if not ok then
                                        print("channel", err)
                                end
                        end
                        while #self.queue > 0 do
                                local t = tremove(self.queue, 1)
                                local ok, err = core.pcall(func, tunpack(t, 1, t.n))
                                if not ok then
                                        print("channel", err)
                                end
                        end
                end

        end)
end


function channel.run(func)
        local self = {}
        self.queue = {}
        self.co = false
        setmetatable(self, mt)
        start(self, func)
        return self
end

function channel.push(self, ...)
        if self.co then
                local co = self.co
                self.co = false
                core.wakeup(co, ...)
        else
                tinsert(self.queue, tpack(...))
        end
end


return channel

