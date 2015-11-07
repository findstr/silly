local socket = require "silly.socket"
local timer = require "silly.timer"
local test = require "test"

local function tm()
        test.echo();
        timer.add(10000, tm);
end

timer.add(1000, tm);


