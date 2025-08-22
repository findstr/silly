local core = require "core"
local time = require "core.time"
local testaux = require "test.testaux"
local waitgroup = require "core.sync.waitgroup"

local wg = waitgroup.new()
local count = 0
for i = 1, 5 do
	wg:fork(function()
		time.sleep(500)
		count = count + 1
		assert(count ~= 5, "crash the last coroutine")
	end)
end
wg:wait()
testaux.asserteq(count, 5, "wait")