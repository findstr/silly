local time = require "silly.time"
local silly = require "silly"

local function timer(session)
	print("timer even expired", session)
	local s = time.after(1000, timer)
	print("next timer session", s)
end

silly.start(function()
	timer(0)
end)

