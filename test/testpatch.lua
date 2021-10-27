local core = require "sys.core"
local patch = require "sys.patch"
local testaux = require "testaux"

return function()
	local M1 = load([[
	local testup1 = 3
	local M = {}
	local function testfn2()
		testup1 = testup1 + 2
	end
	local function testfn3()
		return function()
			testfn2()
			testfn2()
		end
	end

	local testfn2 = testfn3()

	function M.testfn2()
		testfn2()
		return testup1
	end
	return M
	]])()

	local ENV = {}
	local M2 = load([[
	step = 3
	local testup1 = 3
	local M = {}
	local function testfn2()
		testup1 = testup1 + step
	end
	local function testfn3()
		step = step + 1
		return function()
			testfn2()
			testfn2()
		end
	end

	local testfn2 = testfn3()

	function M.testfn2()
		testfn2()
		return testup1
	end
	return M
	]], nil, "t", ENV)()

	print("test patch closure")
	testaux.asserteq(M1.testfn2(), 7, "old module")
	testaux.asserteq(M1.testfn2(), 11, "old module")
	patch(ENV, M1, M2)
	testaux.asserteq(M1.testfn2(), 19, "new module")
	testaux.asserteq(M1.testfn2(), 27, "new module")

	local M1 = load([[
	local core = require "sys.core"
	local M = {}
	local foo
	local timer_foo
	function timer_foo()
		foo = "hello"
		print("timer old")
		core.timeout(100, timer_foo)
	end
	function M.timer_foo()
		timer_foo()
		foo = "bar"
	end
	function M.get_foo()
		return foo
	end
	return M
	]], nil, "t", _ENV)()

	local ENV = setmetatable({}, {__index = _ENV})
	local M2 = load([[
	local core = require "sys.core"
	local M = {}
	local foo
	local timer_foo
	function timer_foo()
		foo = "world"
		print("timer new")
		if timer_foo then
			core.timeout(500, timer_foo)
		end
	end
	function M.timer_foo()
		timer_foo()
		foo = "bar"
	end
	function M.get_foo()
		return foo
	end
	function M.stop()
		timer_foo = nil
	end
	return M
	]], nil, "t", ENV)()

	print("test patch timer")
	M1.timer_foo()
	core.sleep(1000)
	testaux.asserteq(M1.get_foo(), "hello", "old timer")
	patch(ENV, M1, M2)
	core.sleep(1000)
	testaux.asserteq(M1.get_foo(), "world", "new timer")
	M1.stop()
	print("test patch success")
end
