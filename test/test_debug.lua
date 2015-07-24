local socket = require("socket")
local timer = require("timer")
local test = require("test")

local function tm()
        test.echo();
        timer.add(10000, tm);
end

timer.add(1000, tm);


