local silly = require "silly"
local time = require "silly.time"
local testaux = require "test.testaux"
local c = require "test.aux.c"
local logger = require "silly.logger"

local captured = {}

local function clear_captured()
    c.debugctrl("log.flush")
    captured = {}
end

c.debugctrl("log.capture", function(fd, data, bytes)
    table.insert(captured, data)
    return bytes
end)

-- Test cases

testaux.case("Test 1: Basic log capture", function()
    clear_captured()
    logger.info("hello world")
    c.debugctrl("log.flush")
    testaux.asserteq(#captured, 1, "Test 1.1: One log entry")
    testaux.assertcontains(captured[1], "hello world", "Test 1.2: Content")
end)

testaux.case("Test 2: Log level filtering", function()
    clear_captured()
    logger.setlevel(logger.WARN)
    logger.debug("hidden")
    logger.info("hidden")
    logger.warn("visible")
    c.debugctrl("log.flush")
    testaux.asserteq(#captured, 1, "Test 2.1: Only WARN captured")
    testaux.assertcontains(captured[1], "visible", "Test 2.2: Content")
end)

testaux.case("Test 3: Direct write path (message >= buffer)", function()
    clear_captured()
    logger.setlevel(logger.INFO)  -- Reset level after Test 2
    local huge = string.rep("x", 100 * 1024)
    logger.info(huge)
    c.debugctrl("log.flush")
    testaux.asserteq(#captured, 1, "Test 3.1: Direct write triggered")
    testaux.assertgt(#captured[1], 100 * 1024, "Test 3.2: Full content")
end)

testaux.case("Test 4: Partial write retry", function()
    clear_captured()
    c.debugctrl("log.partial", 10)
    logger.info("this is a long message that exceeds 10 bytes")
    c.debugctrl("log.partial", 0)
    c.debugctrl("log.flush")
    testaux.assertgt(#captured[1], 20, "Test 4.1: Content complete")
end)

testaux.case("Test 5: Write error injection (block_write error path)", function()
    clear_captured()
    -- First write something so ring_flush will be triggered
    logger.info("before error")
    c.debugctrl("log.exception", 1, 5)
    c.debugctrl("log.flush")
    c.debugctrl("log.exception", 0)
    -- Data should be retained in buffer
    testaux.asserteq(#captured, 0, "Test 5.1: No data captured during error")
    -- Now flush without error to recover
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 5.2: Data flushed after error reset")
    testaux.assertcontains(captured[1], "before error", "Test 5.3: Content preserved")
end)

testaux.case("Test 6: EINTR retry in block_write", function()
    clear_captured()
    logger.info("retry test")
    c.debugctrl("log.exception", 1, 4)
    c.debugctrl("log.flush")
    c.debugctrl("log.exception", 0)
    testaux.assertgt(#captured, 0, "Test 6.1: Message delivered after EINTR retry")
    testaux.assertcontains(captured[1], "retry test", "Test 6.2: Content correct")
end)

testaux.case("Test 7: Explicit flush", function()
    clear_captured()
    logger.info("before flush")
    c.debugctrl("log.flush")
    logger.info("after flush")
    c.debugctrl("log.flush")
    testaux.asserteq(#captured, 2, "Test 7.1: Two entries")
end)

testaux.case("Test 8: Timestamp and trace ID", function()
    clear_captured()
    local trace = require "silly.trace"
    trace.setnode(0xABCD)
    logger.info("trace test")
    c.debugctrl("log.flush")
    local line = captured[1]
    local trace_id = line:match("(%x+) [DIEW]")
    testaux.assertneq(trace_id, nil, "Test 8.1: Trace ID present")
    testaux.asserteq(#trace_id, 16, "Test 8.2: Trace ID format correct")
    testaux.assertcontains(captured[1], "trace test", "Test 8.3: Content present")
end)

testaux.case("Test 9: Multiple log entries with flush", function()
    clear_captured()
    for i = 1, 10 do
        logger.info("entry " .. i)
        c.debugctrl("log.flush")
    end
    testaux.asserteq(#captured, 10, "Test 9.1: All logs captured separately")
    for i = 1, 10 do
        testaux.assertcontains(captured[i], "entry " .. i,
            "Test 9." .. (1 + i) .. ": Message " .. i .. " content")
    end
end)

testaux.case("Test 10: Multiple log levels", function()
    clear_captured()
    logger.setlevel(logger.DEBUG)
    logger.debug("D")
    logger.info("I")
    logger.warn("W")
    logger.error("E")
    c.debugctrl("log.flush")
    testaux.asserteq(#captured, 1, "Test 10.1: All levels merged")
    local merged = captured[1]
    testaux.assertcontains(merged, "D", "Test 10.2: DEBUG")
    testaux.assertcontains(merged, "I", "Test 10.3: INFO")
    testaux.assertcontains(merged, "W", "Test 10.4: WARN")
    testaux.assertcontains(merged, "E", "Test 10.5: ERROR")
end)

testaux.case("Test 11: State reset between tests", function()
    clear_captured()
    logger.info("before reset")
    c.debugctrl("log.flush")
    local before_count = #captured
    c.debugctrl("log.reset")
    logger.info("after reset")
    c.debugctrl("log.flush")
    testaux.asserteq(#captured - before_count, 1, "Test 11.1: Only after reset")
end)

testaux.case("Test 12: Large formatted message", function()
    clear_captured()
    logger.setlevel(logger.INFO)
    local long_str = string.rep("x", 1500)
    logger.infof("Large message: %s", long_str)
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 12.1: Large formatted message captured")
    testaux.assertgt(#captured[1], 1500, "Test 12.2: Content size")
end)

testaux.case("Test 13: BUILD_TRACE (trace ID change within same second)", function()
    clear_captured()
    local trace = require "silly.trace"
    trace.setnode(0xABCD)
    trace.spawn()
    logger.info("msg1")
    trace.setnode(0xEF01)
    trace.spawn()
    logger.info("msg2")
    c.debugctrl("log.flush")
    testaux.assertcontains(captured[1], "msg1", "Test 13.1: First message")
    testaux.assertcontains(captured[1], "msg2", "Test 13.2: Second message")
    -- Node ID is embedded in trace ID's high 16 bits → first 4 hex chars
    testaux.assertcontains(captured[1], "abcd", "Test 13.3: Trace contains node 0xABCD")
    testaux.assertcontains(captured[1], "ef01", "Test 13.4: Trace contains node 0xEF01")
end)

testaux.case("Test 14: Ring buffer many messages", function()
    clear_captured()
    logger.setlevel(logger.INFO)
    for i = 1, 20 do
        logger.info("message " .. i)
    end
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 14.1: Logs captured")
    testaux.assertcontains(captured[#captured], "message 20", "Test 14.2: Last message present")
end)

testaux.case("Test 15: Multiple consecutive errors", function()
    clear_captured()
    c.debugctrl("log.exception", 1, 5)
    logger.info("error test 1")
    c.debugctrl("log.exception", 2, 5)
    logger.info("error test 2")
    c.debugctrl("log.exception", 0)
    c.debugctrl("log.flush")
    -- Data should be retained in buffer even after errors
    testaux.assertgt(#captured, 0, "Test 15.1: Data retained after errors")
end)

testaux.case("Test 16: Log level API", function()
    local original = logger.getlevel()
    testaux.assertneq(original, nil, "Test 16.1: getlevel returns value")
    logger.setlevel(logger.ERROR)
    testaux.asserteq(logger.getlevel(), logger.ERROR, "Test 16.2: setlevel works")
    logger.setlevel(logger.INFO)  -- Reset to INFO for consistency
end)

testaux.case("Test 17: Very large formatted message", function()
    clear_captured()
    logger.setlevel(logger.INFO)
    local huge_arg = string.rep("ABCDEFGH", 200)  -- 1600 bytes
    logger.infof("Huge: %s end", huge_arg)
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 17.1: Message captured")
    testaux.assertgt(#captured[1], 1600, "Test 17.2: Content size correct")
end)

testaux.case("Test 18: Multiple large messages", function()
    clear_captured()
    logger.setlevel(logger.INFO)
    for i = 1, 5 do
        local large = string.rep("x", 2000)
        logger.info(large)
        c.debugctrl("log.flush")
    end
    testaux.asserteq(#captured, 5, "Test 18.1: All 5 messages captured")
end)

testaux.case("Test 19: Tiny messages", function()
    clear_captured()
    logger.setlevel(logger.INFO)
    for i = 1, 30 do
        logger.info("x")
    end
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 19.1: Tiny messages captured")
end)

testaux.case("Test 20: Ring buffer wrap-around", function()
    clear_captured()
    logger.setlevel(logger.INFO)
    -- Reset ring buffer to known empty state
    c.debugctrl("log.reset")
    for i = 1, 500 do
        logger.info("wrap test message " .. i)
    end
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 20.1: Wrap-around completed, data flushed")
    testaux.assertcontains(captured[#captured], "wrap test message 500", "Test 20.2: Last message present")
end)

testaux.case("Test 21: Direct write for huge message", function()
    clear_captured()
    logger.setlevel(logger.INFO)
    local huge = string.rep("y", 20 * 1024)  -- 20KB > 16KB buffer
    logger.info(huge)
    c.debugctrl("log.flush")
    testaux.asserteq(#captured, 1, "Test 21.1: Direct write triggered")
    testaux.assertgt(#captured[1], 20 * 1024, "Test 21.2: Full content")
end)

testaux.case("Test 22: Ring write failure fallback to stderr", function()
    clear_captured()
    logger.setlevel(logger.INFO)
    c.debugctrl("log.reset")
    for i = 1, 400 do
        logger.info("fill " .. i)
    end
    c.debugctrl("log.exception", 1, 5)
    logger.info("fallback test")
    c.debugctrl("log.exception", 0)
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 22.1: Buffer flushed after error cleared")
end)

testaux.case("Test 23: Multiple EINTR retries", function()
    clear_captured()
    logger.setlevel(logger.INFO)
    logger.info("interrupted")
    c.debugctrl("log.exception", 3, 4)
    c.debugctrl("log.flush")
    c.debugctrl("log.exception", 0)
    testaux.assertgt(#captured, 0, "Test 23.1: Message delivered after retries")
    testaux.assertcontains(captured[1], "interrupted", "Test 23.2: Content correct")
end)

testaux.case("Test 24: block_writev error paths", function()
    clear_captured()
    logger.setlevel(logger.INFO)
    c.debugctrl("log.reset")
    local big = string.rep("A", 15 * 1024)
    logger.info(big)
    for i = 1, 40 do
        logger.info("x")
    end
    -- Part A: EINTR retry in block_writev
    c.debugctrl("log.exception", 1, 4)
    c.debugctrl("log.flush")
    c.debugctrl("log.exception", 0)
    testaux.assertgt(#captured, 0, "Test 24.1: Data flushed after EINTR retry")
    -- Part B: real writev error (non-EINTR)
    clear_captured()
    c.debugctrl("log.reset")
    logger.info(big)
    for i = 1, 40 do
        logger.info("x")
    end
    c.debugctrl("log.exception", 1, 5)
    c.debugctrl("log.flush")
    c.debugctrl("log.exception", 0)
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 24.2: Data recovered after writev error")
    -- Part C: ring_write stderr fallback (ring_flush fails)
    clear_captured()
    c.debugctrl("log.reset")
    logger.info(big)
    c.debugctrl("log.exception", 1, 5)
    local huge = string.rep("Z", 2000)
    logger.info(huge)
    c.debugctrl("log.exception", 0)
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 24.3: Recovered after stderr fallback")
end)

testaux.case("Test 25: Invalid log level", function()
    clear_captured()
    logger.setlevel(logger.DEBUG)
    logger.debug("before")
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 25.1: DEBUG logs work")
    clear_captured()
    local clogger = require "silly.logger.c"
    clogger.setlevel(999)
    logger.setlevel(clogger.getlevel())
    logger.debug("after invalid")
    c.debugctrl("log.flush")
    testaux.assertgt(#captured, 0, "Test 25.2: Level unchanged after invalid setlevel")
end)

c.debugctrl("log.unhook")
silly.exit(0)
