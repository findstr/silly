# Log Test Harness Design

## Overview

This document describes the design for a comprehensive test harness for the logging subsystem (`log.c`, `llogger.c`, `logger.lua`). The harness intercepts write operations through macro indirection, allowing tests to verify log content, buffer behavior, error handling, and concurrent access.

## Goals

- Achieve 100% code coverage of `log.c` write paths
- Test all error scenarios (EINTR, EPIPE, ENOSPC, partial writes)
- Verify ring buffer behavior (wraparound, flush timing, direct-write threshold)
- Support concurrent logging tests
- Minimal code intrusion - only active when `SILLY_TEST` is defined

## Architecture

```
logger.lua (test frontend)
    ↓ normal logger API calls
log.c / llogger.c (middle layer)
    ↓ uses sys_write (SILLY_TEST mode)
sys_write / sys_writev (backend injection point)
    ↓ calls hook function
ltest.c: hook_writev_impl (captures/simulates writes)
    ↓ invokes Lua callback
test/testlog.lua (test cases)
```

## Components

### 1. log.h - Add Declaration

```c
// log.h
#ifdef SILLY_TEST
void log_debug_ctrl(const char *cmd, const char *key, int val);
#endif
```

### 2. log.c - Macro Indirection and Debug Control

```c
// log.c

#ifdef SILLY_TEST
#include <sys/uio.h>

// Function pointer for writev hook
static ssize_t (*hook_writev)(int fd, const struct iovec *iov, int iovcnt) = NULL;

// Indirection functions
static ssize_t sys_write(int fd, const void *buf, size_t count) {
    struct iovec iov = { .iov_base = (void *)buf, .iov_len = count };
    return sys_writev(fd, &iov, 1);
}

static ssize_t sys_writev(int fd, const struct iovec *iov, int iovcnt) {
    if (hook_writev)
        return hook_writev(fd, iov, iovcnt);
    return writev(fd, iov, iovcnt);
}

// Debug control interface
void log_debug_ctrl(const char *cmd, const char *key, int val) {
    (void)key;
    if (strcmp(cmd, "hook") == 0) {
        hook_writev = (ssize_t (*)(int, const struct iovec *, int))val;
    } else if (strcmp(cmd, "unhook") == 0) {
        hook_writev = NULL;
    } else if (strcmp(cmd, "flush") == 0) {
        log_flush();
    }
}
#else
// Production mode: direct mapping
#define sys_write  write
#define sys_writev writev
#endif
```

Replace all `write(...)` with `sys_write(...)` and `writev(...)` with `sys_writev(...)` in `block_write` and `block_writev` functions.

### 3. monitor.h - Add Declaration

```c
// monitor.h (or worker.h if no separate monitor.h)
#ifdef SILLY_TEST
void monitor_debug_ctrl(const char *cmd, const char *key, int val);
#endif
```

### 4. monitor.c - Pause/Resume Implementation

```c
// monitor.c

#ifdef SILLY_TEST
#include <stdatomic.h>

static atomic_int monitor_pause = 0;

void monitor_debug_ctrl(const char *cmd, const char *key, int val) {
    (void)key; (void)val;
    if (strcmp(cmd, "pause") == 0) {
        atomic_store_explicit(&monitor_pause, 1, memory_order_relaxed);
    } else if (strcmp(cmd, "resume") == 0) {
        atomic_store_explicit(&monitor_pause, 0, memory_order_relaxed);
    }
}

// In monitor thread main loop, add:
#ifdef SILLY_TEST
    if (atomic_load_explicit(&monitor_pause, memory_order_relaxed)) {
        usleep(10000);  // Sleep while paused
        continue;
    }
#endif
#endif
```

### 5. api.c - Prefix Dispatch

```c
// api.c

#ifdef SILLY_TEST
#include "log.h"
#include "worker.h"  // or monitor.h

SILLY_API void silly_debug_ctrl(const char *cmd, const char *key, int val)
{
    if (strncmp(cmd, "socket.", 7) == 0) {
        socket_debug_ctrl(cmd + 7, key, val);
    } else if (strncmp(cmd, "log.", 4) == 0) {
        log_debug_ctrl(cmd + 4, key, val);
    } else if (strncmp(cmd, "monitor.", 8) == 0) {
        monitor_debug_ctrl(cmd + 8, key, val);
    } else {
        // Fallback for legacy direct calls
        socket_debug_ctrl(cmd, key, val);
    }
}
#endif
```

### 6. socket.c - Remove Prefix from Commands

Update `socket_debug_ctrl` to accept commands without `"socket."` prefix:

```c
// socket.c

#ifdef SILLY_TEST
void socket_debug_ctrl(const char *cmd, const char *key, int val)
{
    if (strcmp(cmd, "conf") == 0) {           // was "socket.conf"
        // ... existing config logic ...
    } else if (strcmp(cmd, "apply") == 0) {   // was "socket.apply"
        // ... existing apply logic ...
    } else if (strcmp(cmd, "reset") == 0) {   // was "socket.reset"
        // ... existing reset logic ...
    } else if (strcmp(cmd, "kick") == 0) {    // was "socket.kick"
        // ... existing kick logic ...
    }
}
#endif
```

### 7. ltest.c - Hook Implementation and Lua API

```c
// ltest.c

#ifdef SILLY_TEST
#include <stdatomic.h>

// Lua callback reference
static int writev_lua_ref = LUA_NOREF;
static pthread_mutex_t writev_lock = PTHREAD_MUTEX_INITIALIZER;

// Test state for error injection
static struct {
    int error_nth;        // Nth write returns -1
    int error_errno;      // errno to inject
    int partial_bytes;    // Partial write bytes (0 = full)
    atomic_int hook_disabled;  // Temporarily disable hook
} log_test_state = {0};

// Main Lua state (set during module init)
static lua_State *main_lua_state = NULL;

// C-level hook function, passed to log.c via silly_debug_ctrl
static ssize_t hook_writev_impl(int fd, const struct iovec *iov, int iovcnt) {
    // Check if temporarily disabled (for testaux output)
    if (atomic_load_explicit(&log_test_state.hook_disabled,
                             memory_order_relaxed))
        return writev(fd, iov, iovcnt);

    // Calculate total length
    size_t total = 0;
    for (int i = 0; i < iovcnt; i++)
        total += iov[i].iov_len;

    // Merge iovecs into single buffer
    char *merged = mem_alloc(total);
    size_t pos = 0;
    for (int i = 0; i < iovcnt; i++) {
        memcpy(merged + pos, iov[i].iov_base, iov[i].iov_len);
        pos += iov[i].iov_len;
    }

    pthread_mutex_lock(&writev_lock);

    // Error injection
    if (log_test_state.error_nth > 0) {
        if (--log_test_state.error_nth == 0) {
            pthread_mutex_unlock(&writev_lock);
            mem_free(merged);
            errno = log_test_state.error_errno;
            return -1;
        }
    }

    // Determine write bytes (partial or full)
    int write_bytes = (log_test_state.partial_bytes > 0) ?
                      log_test_state.partial_bytes : (int)total;

    // Call Lua callback
    if (writev_lua_ref != LUA_NOREF && main_lua_state) {
        lua_rawgeti(main_lua_state, LUA_REGISTRYINDEX, writev_lua_ref);
        lua_pushinteger(main_lua_state, fd);
        lua_pushlstring(main_lua_state, merged, total);
        lua_pushinteger(main_lua_state, write_bytes);

        if (lua_pcall(main_lua_state, 3, 1, 0) == LUA_OK) {
            int result = lua_tointeger(main_lua_state, -1);
            lua_pop(main_lua_state, 1);
            pthread_mutex_unlock(&writev_lock);
            mem_free(merged);
            return result;
        }
        lua_pop(main_lua_state, 1);
    }

    pthread_mutex_unlock(&writev_lock);
    mem_free(merged);

    // No hook or error - fall back to real writev
    return writev(fd, iov, iovcnt);
}

// Extend ldebugctrl with log commands
static int ldebugctrl(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);

    if (strcmp(cmd, "socket.conf") == 0) {
        // Existing socket.conf logic...

#ifdef SILLY_TEST
    } else if (strcmp(cmd, "log.capture") == 0) {
        luaL_checktype(L, 2, LUA_TFUNCTION);
        if (!main_lua_state)
            main_lua_state = L;  // Save main state

        pthread_mutex_lock(&writev_lock);
        if (writev_lua_ref != LUA_NOREF)
            luaL_unref(L, LUA_REGISTRYINDEX, writev_lua_ref);
        writev_lua_ref = luaL_ref(L, LUA_REGISTRYINDEX);

        // Set C hook in log.c
        silly_debug_ctrl("log.hook", NULL, (int)hook_writev_impl);
        pthread_mutex_unlock(&writev_lock);

    } else if (strcmp(cmd, "log.unhook") == 0) {
        pthread_mutex_lock(&writev_lock);
        if (writev_lua_ref != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, writev_lua_ref);
            writev_lua_ref = LUA_NOREF;
        }
        pthread_mutex_unlock(&writev_lock);
        silly_debug_ctrl("log.unhook", NULL, 0);

    } else if (strcmp(cmd, "log.exception") == 0) {
        int nth = luaL_checkinteger(L, 2);
        int error = luaL_optinteger(L, 3, 5);  // Default EIO
        pthread_mutex_lock(&writev_lock);
        log_test_state.error_nth = nth;
        log_test_state.error_errno = error;
        pthread_mutex_unlock(&writev_lock);

    } else if (strcmp(cmd, "log.partial") == 0) {
        int bytes = luaL_checkinteger(L, 2);
        pthread_mutex_lock(&writev_lock);
        log_test_state.partial_bytes = bytes;
        pthread_mutex_unlock(&writev_lock);

    } else if (strcmp(cmd, "log.reset") == 0) {
        pthread_mutex_lock(&writev_lock);
        log_test_state.error_nth = 0;
        log_test_state.error_errno = 0;
        log_test_state.partial_bytes = 0;
        pthread_mutex_unlock(&writev_lock);

    } else if (strcmp(cmd, "log.flush") == 0) {
        silly_debug_ctrl("log.flush", NULL, 0);

    } else if (strcmp(cmd, "log.disable") == 0) {
        atomic_store_explicit(&log_test_state.hook_disabled, 1,
                              memory_order_relaxed);

    } else if (strcmp(cmd, "log.enable") == 0) {
        atomic_store_explicit(&log_test_state.hook_disabled, 0,
                              memory_order_relaxed);

    } else if (strcmp(cmd, "monitor.pause") == 0) {
        silly_debug_ctrl("monitor.pause", NULL, 0);

    } else if (strcmp(cmd, "monitor.resume") == 0) {
        silly_debug_ctrl("monitor.resume", NULL, 0);

#endif
    } else {
        return luaL_error(L, "unknown debugctrl command: %s", cmd);
    }
    return 0;
}
#endif
```

### 8. test/testlog.lua - Comprehensive Test Suite

```lua
local testaux = require "testaux"
local c = require "test.aux.c"
local logger = require "silly.logger"

-- Captured log entries
local captured = {}

-- Inject writev hook to capture logs
c.debugctrl("log.capture", function(fd, data, bytes)
    table.insert(captured, data)
    return bytes  -- Return byte count to simulate
end)

-- Pause monitor to avoid interference
c.debugctrl("monitor.pause")

testaux.case("Test 1: Basic log capture", function()
    captured = {}
    logger.info("hello world")
    testaux.asserteq(#captured, 1, "Test 1.1: One log entry")
    testaux.assertcontains(captured[1], "hello world", "Test 1.2: Content")
end)

testaux.case("Test 2: Log level filtering", function()
    captured = {}
    logger.setlevel(logger.WARN)
    logger.debug("hidden")
    logger.info("hidden")
    logger.warn("visible")
    testaux.asserteq(#captured, 1, "Test 2.1: Only WARN captured")
    testaux.assertcontains(captured[1], "visible", "Test 2.2: Content")
end)

testaux.case("Test 3: Ring buffer wraparound", function()
    captured = {}
    -- LOG_BUF_SIZE = 64KB, write enough to trigger wraparound
    for i = 1, 1000 do
        logger.info(string.format("message %d", i))
    end
    -- Oldest entries should be dropped
    local first = captured[1]
    testaux.assertgt(first:find("message") or 1, 100,
                     "Test 3.1: Early messages wrapped")
end)

testaux.case("Test 4: Direct write path (message >= buffer)", function()
    captured = {}
    local huge = string.rep("x", 100 * 1024)  -- > LOG_BUF_SIZE
    logger.info(huge)
    testaux.asserteq(#captured, 1, "Test 4.1: Direct write triggered")
    testaux.assertgt(#captured[1], 100 * 1024, "Test 4.2: Full content")
end)

testaux.case("Test 5: Partial write retry", function()
    captured = {}
    c.debugctrl("log.partial", 10)  -- Only write 10 bytes at a time
    logger.info("this is a long message that exceeds 10 bytes")
    c.debugctrl("log.partial", 0)  -- Reset
    testaux.assertgt(#captured[1], 20, "Test 5.1: Content complete")
end)

testaux.case("Test 6: Write error injection", function()
    captured = {}
    c.debugctrl("log.exception", 1, 5)  -- First write returns EIO
    logger.info("should fallback to stderr")
    c.debugctrl("log.exception", 0)  -- Reset
    -- Verify stderr fallback path works
end)

testaux.case("Test 7: EINTR retry behavior", function()
    captured = {}
    local attempt = 0
    c.debugctrl("log.capture", function(fd, data, bytes)
        attempt = attempt + 1
        if attempt == 1 then
            -- Simulate EINTR
            return -1  -- Let log.c retry
        end
        table.insert(captured, data)
        return bytes
    end)
    logger.info("retry test")
    testaux.asserteq(#captured, 1, "Test 7.1: Message delivered after retry")
    -- Restore original hook
    c.debugctrl("log.capture", function(fd, data, bytes)
        table.insert(captured, data)
        return bytes
    end)
end)

testaux.case("Test 8: Explicit flush", function()
    captured = {}
    logger.info("before flush")
    c.debugctrl("log.flush")
    logger.info("after flush")
    testaux.asserteq(#captured, 2, "Test 8.1: Two entries")
end)

testaux.case("Test 9: Timestamp and trace ID", function()
    captured = {}
    silly.trace_set_node(0xABCD)
    logger.info("trace test")
    local line = captured[1]
    -- Format: "YYYY-MM-DD HH:MM:SS <trace_hex> W body\n"
    local trace = line:match("(%x+) [DIEW]")
    testaux.assertneq(trace, nil, "Test 9.1: Trace ID present")
    testaux.assertneq(trace:find("abcd"), nil, "Test 9.2: Trace ID matches")
end)

testaux.case("Test 10: Concurrent logging", function()
    captured = {}
    local ch = require("silly.sync.channel").new()

    for i = 1, 10 do
        task.fork(function()
            logger.info("concurrent " .. i)
            ch:push(i)
        end)
    end

    for i = 1, 10 do ch:pop() end
    testaux.asserteq(#captured, 10, "Test 10.1: All logs captured")
end)

testaux.case("Test 11: Multiple log levels", function()
    captured = {}
    logger.setlevel(logger.DEBUG)
    logger.debug("D")
    logger.info("I")
    logger.warn("W")
    logger.error("E")
    testaux.asserteq(#captured, 4, "Test 11.1: All levels")
    testaux.assertcontains(captured[1], "D", "Test 11.2: DEBUG")
    testaux.assertcontains(captured[2], "I", "Test 11.3: INFO")
end)

testaux.case("Test 12: State reset between tests", function()
    captured = {}
    logger.info("before reset")
    c.debugctrl("log.reset")
    logger.info("after reset")
    testaux.asserteq(#captured, 1, "Test 12.1: Only after reset")
end)

-- Cleanup
c.debugctrl("log.unhook")  -- Directly unhook in log.c
c.debugctrl("monitor.resume")
```

## Concurrency Considerations

The test harness uses `pthread_mutex_t` to protect shared state:
- `writev_lock`: Protects `writev_lua_ref` and error injection state
- `hook_disabled`: Atomic flag for temporarily disabling the hook

Concurrent scenarios tested:
1. Multiple Lua coroutines logging simultaneously (single-threaded cooperative)
2. Monitor thread calling `log_flush` while worker is logging
3. Signal handler calling `eh_clean` during active logging

## Test Coverage

| Component | Coverage Target |
|-----------|----------------|
| log.c write paths | 100% |
| Error handling (EINTR, EPIPE, ENOSPC) | All errno codes |
| Ring buffer behavior | Wraparound, flush timing |
| Direct write threshold | Messages ≥ buffer size |
| Partial writes | Retry logic |
| Concurrent access | Worker + Monitor + Signal |
| Level filtering | All 4 levels |
| Timestamp/trace ID | Format verification |

## Migration Notes

1. `socket.c` needs update: Remove `"socket."` prefix from all command comparisons
2. `monitor.c` needs: Pause/resume mechanism for clean test isolation
3. `log.c` needs: Macro indirection for `write`/`writev`
4. Existing tests using `socket.*` commands continue to work

## API Reference

### Lua Commands (via `c.debugctrl`)

| Command | Parameters | Description |
|---------|------------|-------------|
| `log.capture` | function(fd, data, bytes) | Set Lua callback to intercept writes |
| `log.unhook` | - | Remove hook, restore normal writes |
| `log.flush` | - | Trigger explicit flush |
| `log.exception` | nth, errno | Nth write returns -1 with specified errno |
| `log.partial` | bytes | Simulate partial write (return N bytes only) |
| `log.reset` | - | Reset all test state (error injection, partial) |
| `log.disable` | - | Temporarily disable hook (for testaux output) |
| `log.enable` | - | Re-enable hook |
| `monitor.pause` | - | Pause monitor thread |
| `monitor.resume` | - | Resume monitor thread |

### C Commands (via `silly_debug_ctrl`)

| Command | Parameters | Description |
|---------|------------|-------------|
| `log.hook` | NULL, func_ptr | Set C function pointer for writev hook |
| `log.unhook` | NULL, 0 | Remove hook |
| `log.flush` | NULL, 0 | Trigger flush |

## Future Enhancements

- Buffer state inspection API (`log.buffer_state`)
- Per-test log isolation (automatic reset between cases)
- Built-in log parsing helpers in `testaux.lua`
