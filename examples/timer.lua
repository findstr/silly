local core = require "core"

local function timer(session)
	print("timer even expired", session)
	local s = core.timeout(1000, timer)
	print("next timer session", s)
end

core.start(function()
	timer(0)
end)

