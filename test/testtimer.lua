local core = require "sys.core"
local time = require "sys.time"
local testaux = require "testaux"

local context = {}
local total = 30
local WAIT

local function gen_closure(n)
	local now = time.now()
	return function (s)
		assert(context[s] == n)
		local delta = time.now() - now
		delta = math.abs(delta - 100 - n)
		--precise is 50ms
		testaux.assertle(delta, 100, "timer check delta")
		total = total - 1
		if total == 0 then
			core.wakeup(WAIT)
		end
	end
end

local function test_timer()
	for i = 1, total do
		local n = i * 50
		local f = gen_closure(n)
		local s = core.timeout(100 + n, f)
		context[s] = n
	end
	WAIT = core.running()
	core.wait(WAIT)
end

local function test_cancel()
	local key = "foo"
	local session = core.timeout(1, function()
		key = "bar"
	end)
	core.timercancel(session)
	core.sleep(1000)
	testaux.assertneq(key, "bar", "test timer cancel")
end

return function()
	test_timer()
	test_cancel()
end

