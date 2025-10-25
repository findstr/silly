local silly = require "silly"
local time = require "silly.time"
local testaux = require "test.testaux"
local waitgroup = require "silly.sync.waitgroup"
local mutex = require "silly.sync.mutex"

local mutex = mutex.new()

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
		local parent = silly.running()
		silly.fork(function()
			silly.wakeup(parent)
			local x = mutex:lock(key)
			flag = true
		end)
		silly.wait()
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
		local parent = silly.running()
		silly.fork(function()
			silly.wakeup(parent)
			local k = mutex:lock(key)
			flag = true
		end)
		silly.wait()
		testaux.asserteq(flag, true, "test lock reentrant")
	end)
	wg:wait()
	testaux.success("reentrant mutex is ok")
end

local function testcase7()
	local obj = {
		step = 1,
	}
	local l1 = mutex:lock(obj)
	testaux.asserteq(obj.step, 1, "test lock race 1")
	obj.step = 2
	silly.fork(function()
		print("2")
		testaux.asserteq(obj.step, 2, "test lock race 2.1")
		local l2<close> = mutex:lock(obj)
		testaux.asserteq(obj.step, 2, "test lock race 2.2")
		obj.step = 3
	end)
	time.sleep(0) -- yield for lock2
	testaux.asserteq(obj.step, 2, "test lock race 2.3")
	l1:unlock() -- unlock, the lock is wakeup
	local l3<close> = mutex:lock(obj)
	testaux.asserteq(obj.step, 3, "test lock race 3")
end

testcase1()
testcase2()
testcase3()
testcase4()
testcase5()
testcase6()
testcase7()
