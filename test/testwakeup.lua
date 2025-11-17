local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local testaux = require "test.testaux"
local fork_queue = {}
local nxt = 1

local function wrap(str, i)
	return function(x)
		assert(x == nil)
		local x = task.wait()
		assert(x == i)
		testaux.asserteq(nxt, i, "wakeup validate sequence")
		nxt = i + 1
	end
end

for i = 1, 50 do
	fork_queue[i] = task.fork(wrap("test" .. i, i))
end
time.sleep(0)
local wakeup = task.wakeup
for i = 1, 50 do
	wakeup(fork_queue[i], i)
	local ok, err = pcall(wakeup, fork_queue[i], i)
	assert(not ok)
end
time.sleep(100)
for i = 51, 100 do
	fork_queue[i] = task.fork(wrap("test" .. i, i))
end
time.sleep(0)
local wakeup = task.wakeup
for i = 51, 100 do
	wakeup(fork_queue[i], i)
end
time.sleep(0)
testaux.asserteq(nxt, 101, "wakeup validate sequence")