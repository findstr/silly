local core = require "sys.core"
local fork_queue = {}
local nxt = 1
local last = nil

local function wrap(str, i)
	return function()
		core.wait()
		assert(nxt == i)
		nxt = i + 1
		print("wakeup", i)
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
	assert(nxt == 101)
	print("testwakeup ok")
end

