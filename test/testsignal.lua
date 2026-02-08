local signal = require "silly.signal"
local signalc = require "silly.signal.c"
local testaux = require "test.testaux"
local silly = require "silly"
local channel = require "silly.sync.channel"
local signal_map = signalc.signalmap()

testaux.case("Test 1: signal handler override", function()
	local old = signal("SIGINT", function(_)
	end)
	testaux.asserteq(type(old), "function", "Test 1.1: should return old handler")
	testaux.success("Test 1 passed")
end)

-- This test is intended to be run under UBSan to catch shift UB
-- in sigbits handling for large signal numbers.
testaux.case("Test 2: signal large signum (C API)", function()
	local err = signalc.signal(1024)
	testaux.assertneq(err, nil, "Test 2.1: large signum should return error")
	testaux.success("Test 2 passed")
end)

-- Test SIGHUP signal delivery via kill command
-- Note: os.execute may trigger "endless loop" warning since it blocks - this is expected
testaux.case("Test 3: SIGHUP signal delivery", function()
	if silly.multiplexer == "iocp" or not signal_map.SIGHUP then
		testaux.success("Test 3 skipped (SIGHUP not supported on this platform)")
		return
	end
	local ch = channel.new()
	local received = false
	signal("SIGHUP", function(sig)
		received = true
		ch:push(sig)
	end)
	-- Send SIGHUP to ourselves
	local pid = silly.pid
	os.execute("kill -HUP " .. pid)
	-- Wait for signal (with timeout via select-like pattern)
	local sig = ch:pop()
	testaux.asserteq(received, true, "Test 3.1: SIGHUP handler should be called")
	testaux.asserteq(sig, "SIGHUP", "Test 3.2: Signal name should be SIGHUP")
	testaux.success("Test 3 passed")
end)

-- Test SIGUSR2 signal delivery in normal operation (not endless loop)
testaux.case("Test 4: SIGUSR2 signal delivery", function()
	if silly.multiplexer == "iocp" or not signal_map.SIGUSR2 then
		testaux.success("Test 4 skipped (SIGUSR2 not supported on this platform)")
		return
	end
	local ch = channel.new()
	local received = false
	signal("SIGUSR2", function(sig)
		received = true
		ch:push(sig)
	end)
	-- Send SIGUSR2 to ourselves
	local pid = silly.pid
	os.execute("kill -USR2 " .. pid)
	-- Wait for signal
	local sig = ch:pop()
	testaux.asserteq(received, true, "Test 4.1: SIGUSR2 handler should be called")
	testaux.asserteq(sig, "SIGUSR2", "Test 4.2: Signal name should be SIGUSR2")
	testaux.success("Test 4 passed")
end)
