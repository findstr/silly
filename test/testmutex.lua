local core = require "core"
local time = require "core.time"
local testaux = require "test.testaux"
local waitgroup = require "core.sync.waitgroup"
local mutex = require "core.sync.mutex"

local mutex = mutex:new()

local function testcase1()
	print("===:case1")
	local wg = waitgroup.new()
	local key = {}
	local x = 0
	for i = 1, 5 do
		wg:fork(function()
			local lock<close> = mutex:lock(key)
			local n = x
			time.sleep(100)
			testaux.asserteq(n, x, "test mutex lock")
			x = n + 1
		end)
	end
	wg:fork(function()
		local lock<close> = mutex:lock(key)
		local n = x
		time.sleep(100)
			testaux.asserteq(n, x, "test mutex lock")
			x = n + 1
		end)
	wg:wait()
	testaux.asserteq(x, 6, "all mutex can be released")
end

local function testcase2()
	print("===:case2")
	local wg = waitgroup.new()
	local key = {}
	local x = 0
	for i = 1, 5 do
		wg:fork(function()
			local lock<close> = mutex:lock(key)
			local n = x
			time.sleep(100)
			testaux.asserteq(n, x, "test mutex lock")
			x = n + 1
			lock:unlock()
		end)
	end
	wg:fork(function()
		local lock<close> = mutex:lock(key)
		local n = x
		time.sleep(100)
			testaux.asserteq(n, x, "test mutex lock")
			x = n + 1
		end)
	wg:wait()
	testaux.asserteq(x, 6, "all mutex can be released")
end

local function testcase3()
	print("===:case3")
	local wg = waitgroup.new()
	local key = {}
	local x = 0
	for i = 1, 5 do
		wg:fork(function()
			local lock<close> = mutex:lock(key)
			local n = x
			time.sleep(100)
			testaux.asserteq(n, x, "test mutex lock")
			x = n + 1
			error("exception")
			lock:unlock()
		end)
	end
	wg:fork(function()
		local lock<close> = mutex:lock(key)
		local n = x
		time.sleep(100)
			testaux.asserteq(n, x, "test mutex lock")
			x = n + 1
		end)
	wg:wait()
	testaux.asserteq(x, 6, "all mutex can be released")
end

local function testcase4()
	print("===:case4")
	local wg = waitgroup.new()
	local key = {}
	local x = 0
	wg:fork(function()
		local lock<close> = mutex:lock(key)
		local n = x
		time.sleep(100)
		testaux.asserteq(n, x, "test mutex lock")
		x = n + 1
		lock:unlock()
	end)
	wg:wait()
	wg:fork(function()
		local lock<close> = mutex:lock(key)
		local n = x
		time.sleep(100)
		testaux.asserteq(n, x, "test mutex lock")
		x = n + 1
		lock:unlock()
	end)
	wg:wait()
	testaux.asserteq(x, 2, "all mutex can be released")
end

local function testcase5()
	print("===:case5")
	local wg = waitgroup.new()
	local key = {}
	wg:fork(function()
		local lock1 = mutex:lock(key)
		local lock = mutex:lock(key)
		local flag = false
		lock:unlock()
		local parent = core.running()
		core.fork(function()
			core.wakeup(parent)
			local x = mutex:lock(key)
			flag = true
		end)
		core.wait()
		testaux.asserteq(flag, false, "test lock reentrant")
	end)
	wg:wait()
	testaux.success("reentrant mutex is ok")
end

local function testcase6()
	print("===:case6")
	local wg = waitgroup.new()
	local key = {}
	wg:fork(function()
		local lock1 = mutex:lock(key)
		local lock = mutex:lock(key)
		local flag = false
		lock:unlock()
		lock1:unlock()
		local parent = core.running()
		core.fork(function()
			core.wakeup(parent)
			local k = mutex:lock(key)
			flag = true
		end)
		core.wait()
		testaux.asserteq(flag, true, "test lock reentrant")
	end)
	wg:wait()
	testaux.success("reentrant mutex is ok")
end



testcase1()
testcase2()
testcase3()
testcase4()
testcase5()
testcase6()