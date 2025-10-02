local silly = require "silly"
local env = require "silly.env"
local metrics = require "silly.metrics.c"
local time = require "silly.time"
local testaux = require "test.testaux"

local context = {}
local total = 30
local WAIT
local CHECK_DELTA = env.get("test.timer.checkdelta")
CHECK_DELTA = CHECK_DELTA and tonumber(CHECK_DELTA) or 100

local function gen_closure(n)
	local now = time.now()
	return function (s)
		assert(context[s] == n)
		local delta = time.now() - now
		delta = math.abs(delta - 100 - n)
		--precise is 50ms
		testaux.assertle(delta, CHECK_DELTA, "timer check delta")
		total = total - 1
		if total == 0 then
			silly.wakeup(WAIT)
		end
	end
end

local function test_timer()
	for i = 1, total do
		local n = i * 50
		local f = gen_closure(n)
		local s = time.after(100 + n, f)
		context[s] = n
	end
	WAIT = silly.running()
	silly.wait()
end

local function test_userdata()
	time.after(1, function(ud)
		testaux.asserteq(ud, 3, "timer userdata")
	end, 3)
	time.after(1, function(ud)
		testaux.asserteq(ud, "hello", "timer userdata")
	end, "hello")
	time.sleep(1000)
end

local function test_cancel()
	local key = "foo"
	local session = time.after(1, function(ud)
		testaux.asserteq(ud, 3, "timer userdata")
		key = "bar"
	end, 3)
	time.cancel(session)
	time.sleep(1000)
	testaux.assertneq(key, "bar", "test timer cancel")
end

test_timer()
test_userdata()
test_cancel()