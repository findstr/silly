local core = require "sys.core"
local testaux = require "testaux"
local waitgroup = require "sys.sync.waitgroup"
local mutex = require "sys.sync.mutex"

local function testcase1()
	local wg = waitgroup:create()
	local count = 0
	local key = {}
	local x = 0
	for i = 1, 5 do
		wg:fork(function()
			local lock<close> = mutex.lock(key)
			local n = x
			core.sleep(100)
			testaux.asserteq(n, x, "test mutex lock")
			x = n + 1
		end)
	end
	wg:fork(function()
		local lock<close> = mutex.lock(key)
		local n = x
		core.sleep(100)
		testaux.asserteq(n, x, "test mutex lock")
		x = n + 1
	end)
	wg:wait()
	testaux.asserteq(x, 6, "all mutex can be released")
end

local function testcase2()
	local wg = waitgroup:create()
	local count = 0
	local key = {}
	local x = 0
	for i = 1, 5 do
		wg:fork(function()
			local lock<close> = mutex.lock(key)
			local n = x
			core.sleep(100)
			testaux.asserteq(n, x, "test mutex lock")
			x = n + 1
			lock:unlock()
		end)
	end
	wg:fork(function()
		local lock<close> = mutex.lock(key)
		local n = x
		core.sleep(100)
		testaux.asserteq(n, x, "test mutex lock")
		x = n + 1
	end)
	wg:wait()
	testaux.asserteq(x, 6, "all mutex can be released")
end

local function testcase3()
	local wg = waitgroup:create()
	local count = 0
	local key = {}
	local x = 0
	for i = 1, 5 do
		wg:fork(function()
			local lock<close> = mutex.lock(key)
			local n = x
			core.sleep(100)
			testaux.asserteq(n, x, "test mutex lock")
			x = n + 1
			error("exception")
			lock:unlock()
		end)
	end
	wg:fork(function()
		local lock<close> = mutex.lock(key)
		local n = x
		core.sleep(100)
		testaux.asserteq(n, x, "test mutex lock")
		x = n + 1
	end)
	wg:wait()
	testaux.asserteq(x, 6, "all mutex can be released")
end

local function testcase4()
	local wg = waitgroup:create()
	local count = 0
	local key = {}
	local x = 0
	wg:fork(function()
		local lock<close> = mutex.lock(key)
		local n = x
		core.sleep(100)
		testaux.asserteq(n, x, "test mutex lock")
		x = n + 1
		lock:unlock()
	end)
	wg:wait()
	wg:fork(function()
		local lock<close> = mutex.lock(key)
		local n = x
		core.sleep(100)
		testaux.asserteq(n, x, "test mutex lock")
		x = n + 1
		lock:unlock()
	end)
	wg:wait()
	testaux.asserteq(x, 2, "all mutex can be released")
end


return function()
	testcase1()
	testcase2()
	testcase3()
	testcase4()
end

