local core = require "sys.core"
local testaux = require "testaux"
local fork_queue = {}
local nxt = 1
local last = nil

local function wrap(str, i)
	return function()
		local co = core.running()
		core.wait(co)
		testaux.asserteq(nxt, i, "wakeup validate sequence")
		nxt = i + 1
	end
end

return function()
	for i = 1, 100 do
		fork_queue[i] = core.fork(wrap("test" .. i, i))
	end
	core.sleep(0)
	local wakeup = core.wakeup
	for i = 1, 100 do
		wakeup(fork_queue[i])
	end
	core.sleep(0)
	testaux.asserteq(nxt, 101, "wakeup validate sequence")
end

