local core = require "core"
local time = require "core.time"
local patch = require "core.patch"
local testaux = require "test.testaux"
local function fix(P, ENV, M1, M2, skip)
	local up1 = P:collectupval(M1)
	local up2 = P:collectupval(M2)
	local absent = P:join(up2, up1)
	testaux.asserteq(absent[1], skip, "test absent upvalue")
	for name, fn1 in pairs(M2) do
		M1[name] = fn1
	end
	for k, v in pairs(ENV) do
		if not _ENV[k] or type(v) == "function" then
			_ENV[k] = v
		end
	end
	return up1, up2
end

local function case1(P)
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
	fix(P, ENV, M1, M2, "$.testfn2.testfn2.testfn2._ENV")
	testaux.asserteq(M1.testfn2(), 19, "new module")
	testaux.asserteq(M1.testfn2(), 27, "new module")
end

local function case2(P)
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
	local step = 3
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
	fix(P, ENV, M1, M2, "$.testfn2.testfn2.testfn2.step")
	testaux.asserteq(M1.testfn2(), 19, "new module")
	testaux.asserteq(M1.testfn2(), 27, "new module")
end


local function case3(P)
	local M1 = load([[
	local core = require "core"
	local time = require "core.time"
	local M = {}
	local foo
	local timer_foo
	function timer_foo()
		foo = "hello"
		print("timer old")
		time.after(100, timer_foo)
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
	local core = require "core"
	local time = require "core.time"
	local M = {}
	local foo
	local timer_foo
	function timer_foo()
		if not timer_foo then
			return
		end
		foo = "world"
		print("timer new")
		time.after(500, timer_foo)
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
	time.sleep(1000)
	testaux.asserteq(M1.get_foo(), "hello", "old timer")
	local up1, up2 = fix(P, ENV, M1, M2, nil)
	local uv1 = up1.timer_foo.upvals.timer_foo
	local uv2 = up2.timer_foo.upvals.timer_foo
	testaux.asserteq(up1.timer_foo.upvals.timer_foo.upid,
		uv1.upvals.timer_foo.upid, "test upvalueid")
	debug.setupvalue(uv1.val, uv1.upvals.timer_foo.idx, uv2.upvals.timer_foo.val)
	time.sleep(1000)
	testaux.asserteq(M1.get_foo(), "world", "new timer")
	M1.stop()
end

local function case4(P)
	local M1 = load([[
	local M = {}
	local a,b = 3,4

	function M.foo()
		a = a + 1
		return a
	end

	function M.foo2()
		b = b + 2
		return b
	end
	function M.bar()
		return a, b
	end
	return M
	]], nil, "t", _ENV)()

	local ENV = setmetatable({}, {__index = _ENV})
	local M2 = load([[
	local M = {}
	local a,b = 0,0

	function M.foo()
		a = a + 1
		b = b + 1
		return a,b
	end

	function M.foo2()
		 b = b + 3
		 return b
	end
	function M.bar()
		return a, b
	end
	return M
	]], nil, "t", ENV)()
	testaux.asserteq(M1.foo(), 4, "old foo")
	testaux.asserteq(M1.foo2(), 6, "old foo2")
	local a, b = M1.bar()
	testaux.asserteq(a, 4, "old bar")
	testaux.asserteq(b, 6, "old bar")
	local up1, up2 = fix(P, ENV, M1, M2, "$.foo.b")
	debug.upvaluejoin(up2.foo.val, up2.foo.upvals.b.idx, up2.bar.val, up2.bar.upvals.b.idx)
	local a, b = M1.foo()
	testaux.asserteq(a, 5, "new foo")
	testaux.asserteq(b, 7, "new foo")
	testaux.asserteq(M1.foo2(), 10, "new foo")
	local a, b = M1.bar()
	testaux.asserteq(a, 5, "new foo")
	testaux.asserteq(b, 10, "new foo")
end

local function case5(P)
	local M1 = load([[
	local M = {}
	function M.foo()
	end
	return M
	]], nil, "t", _ENV)()

	local ENV = setmetatable({}, {__index = _ENV})
	local M2 = load([[
	local M = {}
	bar = 3
	function M.foo()
		bar = bar + 1
	end
	return M
	]], nil, "t", ENV)()

	fix(P, ENV, M1, M2, "$.foo._ENV")
	testaux.asserteq(_ENV.bar, 3, "global variable")
	M1.foo()
	testaux.asserteq(_ENV.bar, 4, "global variable")
end

local P = patch:create()
case1(P)
case2(P)
case3(P)
case4(P)
case5(P)