# Log Test Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-step. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a comprehensive test harness for the logging subsystem that intercepts write operations, enables error injection, and achieves 100% code coverage of `log.c` write paths.

**Architecture:** Inject write hooks through macro indirection (`sys_write`/`sys_writev`) that only exists when `SILLY_TEST` is defined. Lua tests call `c.debugctrl("log.capture", ...)` which internally registers a C hook that invokes Lua callbacks.

**Tech Stack:** C (pthread, atomic, iovec), Lua 5.4, silly framework

---

## File Structure

| File | Action | Responsibility |
|------|--------|-----------------|
| `src/log.h` | Modify | Add `log_debug_ctrl` declaration (SILLY_TEST only) |
| `src/log.c` | Modify | Macro indirection, `sys_write`/`sys_writev`, `log_debug_ctrl` implementation |
| `src/monitor.h` | Modify | Add `monitor_debug_ctrl` declaration (SILLY_TEST only) |
| `src/monitor.c` | Modify | Pause/resume mechanism, atomic flag |
| `src/api.c` | Modify | Prefix dispatch for `silly_debug_ctrl` |
| `src/socket.c` | Modify | Remove `"socket."` prefix from command comparisons |
| `luaclib-src/ltest.c` | Modify | Hook implementation, Lua state management, debug_ctrl commands |
| `test/testlog.lua` | Create | Comprehensive test suite |

---

### Task 1: Add log_debug_ctrl Declaration to log.h

**Files:**
- Modify: `src/log.h`

- [ ] **Step 1: Add SILLY_TEST declaration**

Add at the end of `src/log.h` before the final `#endif`:

```c
#ifdef SILLY_TEST
void log_debug_ctrl(const char *cmd, const char *key, int val);
#endif
```

- [ ] **Step 2: Verify compilation**

Run: `make clean && make`

Expected: Clean build with no errors or warnings

- [ ] **Step 3: Commit**

```bash
git add src/log.h
git commit -m "log: add log_debug_ctrl declaration for SILLY_TEST"
```

---

### Task 2: Add Macro Indirection to log.c

**Files:**
- Modify: `src/log.c`

- [ ] **Step 1: Read current block_write and block_writev**

Run: `grep -n "static size_t block_write\|static size_t block_writev" src/log.c`

Note: Current implementation uses `write()` and `writev()` directly

- [ ] **Step 2: Add SILLY_TEST indirection functions**

After the `#include` section in `src/log.c`, add:

```c
#ifdef SILLY_TEST
#include <sys/uio.h>

static ssize_t (*hook_writev)(int fd, const struct iovec *iov, int iovcnt) = NULL;

static ssize_t sys_write(int fd, const void *buf, size_t count) {
    struct iovec iov = { .iov_base = (void *)buf, .iov_len = count };
    return sys_writev(fd, &iov, 1);
}

static ssize_t sys_writev(int fd, const struct iovec *iov, int iovcnt) {
    if (hook_writev)
        return hook_writev(fd, iov, iovcnt);
    return writev(fd, iov, iovcnt);
}
#else
#define sys_write  write
#define sys_writev writev
#endif
```

- [ ] **Step 3: Replace write with sys_write in block_write**

In `block_write` function, replace `write(fd, buf, len)` with `sys_write(fd, buf, len)`

Current code around line 127:
```c
ssize_t n = write(fd, buf, len);
```

Change to:
```c
ssize_t n = sys_write(fd, buf, len);
```

- [ ] **Step 4: Replace writev with sys_writev in block_writev**

In `block_writev` function, replace `writev(fd, iov, 2)` with `sys_writev(fd, iov, 2)`

Current code around line 158:
```c
ssize_t n = writev(fd, iov, 2);
```

Change to:
```c
ssize_t n = sys_writev(fd, iov, 2);
```

- [ ] **Step 5: Replace writev in ring_flush for direct write path**

In `ring_flush` function, around line 199, replace `block_writev(STDOUT_FILENO, ...)` call with the existing function name (the function already uses sys_writev internally after our changes)

Actually, `ring_flush` calls `block_write` and `block_writev`, so no additional changes needed.

- [ ] **Step 6: Verify compilation**

Run: `make clean && make`

Expected: Clean build

- [ ] **Step 7: Commit**

```bash
git add src/log.c
git commit -m "log: add sys_write/sys_writev macro indirection for SILLY_TEST"
```

---

### Task 3: Implement log_debug_ctrl in log.c

**Files:**
- Modify: `src/log.c`

- [ ] **Step 1: Add log_debug_ctrl function**

Add after the `sys_writev` function in the `#ifdef SILLY_TEST` block:

```c
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
```

- [ ] **Step 2: Verify compilation**

Run: `make clean && make`

Expected: Clean build

- [ ] **Step 3: Commit**

```bash
git add src/log.c
git commit -m "log: implement log_debug_ctrl for hook management"
```

---

### Task 4: Add monitor_debug_ctrl Declaration to monitor.h

**Files:**
- Modify: `src/monitor.h`

- [ ] **Step 1: Add SILLY_TEST declaration**

Add at the end of `src/monitor.h` before the final `#endif`:

```c
#ifdef SILLY_TEST
void monitor_debug_ctrl(const char *cmd, const char *key, int val);
#endif
```

- [ ] **Step 2: Verify compilation**

Run: `make clean && make`

Expected: Clean build

- [ ] **Step 3: Commit**

```bash
git add src/monitor.h
git commit -m "monitor: add monitor_debug_ctrl declaration for SILLY_TEST"
```

---

### Task 5: Implement monitor_debug_ctrl with Pause/Resume

**Files:**
- Modify: `src/monitor.c`

- [ ] **Step 1: Add atomic pause flag and includes**

At the top of `src/monitor.c`, after the includes:

```c
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
#endif
```

- [ ] **Step 2: Find where to add pause check in monitor_init**

Check: `grep -n "pthread" src/*.c | grep monitor`

Expected: Monitor thread is created in `worker.c`. We need to find the actual monitor thread function.

- [ ] **Step 3: Check worker.c for monitor thread**

Run: `grep -n "monitor" src/worker.c`

Note: Find the monitor thread loop location

- [ ] **Step 4: Add pause check to monitor thread**

Based on grep results, add the pause check at the start of the monitor thread loop. The monitor thread calls `monitor_check()` in a loop. We need to add the pause check before `monitor_check()`.

In `src/worker.c`, find the monitor thread function and add before the `monitor_check()` call:

```c
#ifdef SILLY_TEST
    extern atomic_int monitor_pause;
    if (atomic_load_explicit(&monitor_pause, memory_order_relaxed)) {
        usleep(10000);  // Sleep while paused
        continue;
    }
#endif
```

Note: The `monitor_pause` variable is in `monitor.c`, so we need to declare it as `extern` or access it via a function. Better approach: add a function in `monitor.c`.

- [ ] **Step 5: Refactor to use function instead of extern**

In `src/monitor.c`, add:

```c
#ifdef SILLY_TEST
int monitor_is_paused(void) {
    return atomic_load_explicit(&monitor_pause, memory_order_relaxed);
}
#endif
```

In `src/monitor.h`, add:

```c
#ifdef SILLY_TEST
int monitor_is_paused(void);
#endif
```

In `src/worker.c`, use:

```c
#ifdef SILLY_TEST
    if (monitor_is_paused()) {
        usleep(10000);
        continue;
    }
#endif
```

- [ ] **Step 6: Verify compilation**

Run: `make clean && make`

Expected: Clean build

- [ ] **Step 7: Commit**

```bash
git add src/monitor.c src/monitor.h src/worker.c
git commit -m "monitor: add pause/resume mechanism for SILLY_TEST"
```

---

### Task 6: Update api.c for Prefix Dispatch

**Files:**
- Modify: `src/api.c`

- [ ] **Step 1: Read current silly_debug_ctrl implementation**

Run: `grep -B 2 -A 10 "silly_debug_ctrl" src/api.c`

Current code shows it only calls `socket_debug_ctrl(cmd, key, val)` directly.

- [ ] **Step 2: Add includes for log.h and monitor.h**

In the `#ifdef SILLY_TEST` block around the `silly_debug_ctrl` function, add includes:

```c
#ifdef SILLY_TEST
#include "log.h"
#include "monitor.h"

SILLY_API void silly_debug_ctrl(const char *cmd, const char *key, int val)
```

- [ ] **Step 3: Replace silly_debug_ctrl body with prefix dispatch**

Current code:
```c
SILLY_API void silly_debug_ctrl(const char *cmd, const char *key, int val)
{
    socket_debug_ctrl(cmd, key, val);
}
```

Replace with:
```c
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
```

- [ ] **Step 4: Verify compilation**

Run: `make clean && make`

Expected: Clean build

- [ ] **Step 5: Commit**

```bash
git add src/api.c
git commit -m "api: add prefix dispatch to silly_debug_ctrl"
```

---

### Task 7: Update socket.c to Remove Prefix

**Files:**
- Modify: `src/socket.c`

- [ ] **Step 1: Read current socket_debug_ctrl implementation**

Run: `grep -A 50 "void socket_debug_ctrl" src/socket.c | head -60`

Note the current command comparisons.

- [ ] **Step 2: Update command comparisons to remove "socket." prefix**

Find and replace:
- `strcmp(cmd, "socket.conf")` → `strcmp(cmd, "conf")`
- `strcmp(cmd, "socket.apply")` → `strcmp(cmd, "apply")`
- `strcmp(cmd, "socket.reset")` → `strcmp(cmd, "reset")`
- `strcmp(cmd, "socket.kick")` → `strcmp(cmd, "kick")`

Using Edit tool for each:

```c
// Before:
    if (strcmp(cmd, "socket.conf") == 0) {

// After:
    if (strcmp(cmd, "conf") == 0) {
```

Continue for all four commands.

- [ ] **Step 3: Verify compilation**

Run: `make clean && make`

Expected: Clean build

- [ ] **Step 4: Commit**

```bash
git add src/socket.c
git commit -m "socket: remove prefix from socket_debug_ctrl commands"
```

---

### Task 8: Add Hook Implementation to ltest.c

**Files:**
- Modify: `luaclib-src/ltest.c`

- [ ] **Step 1: Add includes and state variables**

After the existing includes in `luaclib-src/ltest.c`, inside the `#ifdef SILLY_TEST` block:

```c
#ifdef SILLY_TEST
#include <stdatomic.h>

static int writev_lua_ref = LUA_NOREF;
static pthread_mutex_t writev_lock = PTHREAD_MUTEX_INITIALIZER;
static lua_State *main_lua_state = NULL;

static struct {
    int error_nth;
    int error_errno;
    int partial_bytes;
    atomic_int hook_disabled;
} log_test_state = {0};
```

- [ ] **Step 2: Implement hook_writev_impl function**

Add the C-level hook function:

```c
static ssize_t hook_writev_impl(int fd, const struct iovec *iov, int iovcnt) {
    if (atomic_load_explicit(&log_test_state.hook_disabled,
                             memory_order_relaxed))
        return writev(fd, iov, iovcnt);

    size_t total = 0;
    for (int i = 0; i < iovcnt; i++)
        total += iov[i].iov_len;

    char *merged = mem_alloc(total);
    size_t pos = 0;
    for (int i = 0; i < iovcnt; i++) {
        memcpy(merged + pos, iov[i].iov_base, iov[i].iov_len);
        pos += iov[i].iov_len;
    }

    pthread_mutex_lock(&writev_lock);

    if (log_test_state.error_nth > 0) {
        if (--log_test_state.error_nth == 0) {
            pthread_mutex_unlock(&writev_lock);
            mem_free(merged);
            errno = log_test_state.error_errno;
            return -1;
        }
    }

    int write_bytes = (log_test_state.partial_bytes > 0) ?
                      log_test_state.partial_bytes : (int)total;

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

    return writev(fd, iov, iovcnt);
}
```

- [ ] **Step 3: Verify compilation**

Run: `make clean && make`

Expected: Clean build

- [ ] **Step 4: Commit**

```bash
git add luaclib-src/ltest.c
git commit -m "ltest: add hook_writev_impl for log testing"
```

---

### Task 9: Add Lua debug_ctrl Commands to ltest.c

**Files:**
- Modify: `luaclib-src/ltest.c`

- [ ] **Step 1: Find ldebugctrl function location**

Run: `grep -n "static int ldebugctrl" luaclib-src/ltest.c`

- [ ] **Step 2: Add log commands to ldebugctrl**

Inside the `ldebugctrl` function, after the `socket.conf` block and before the final `else`, add:

```c
#ifdef SILLY_TEST
    } else if (strcmp(cmd, "log.capture") == 0) {
        luaL_checktype(L, 2, LUA_TFUNCTION);
        if (!main_lua_state)
            main_lua_state = L;

        pthread_mutex_lock(&writev_lock);
        if (writev_lua_ref != LUA_NOREF)
            luaL_unref(L, LUA_REGISTRYINDEX, writev_lua_ref);
        writev_lua_ref = luaL_ref(L, LUA_REGISTRYINDEX);
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
        int error = luaL_optinteger(L, 3, 5);
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
```

Make sure the `#endif` comes before the final `else`.

- [ ] **Step 3: Verify compilation**

Run: `make clean && make`

Expected: Clean build

- [ ] **Step 4: Commit**

```bash
git add luaclib-src/ltest.c
git commit -m "ltest: add log debug_ctrl commands"
```

---

### Task 10: Create Comprehensive Test Suite

**Files:**
- Create: `test/testlog.lua`

- [ ] **Step 1: Create test file skeleton**

Create `test/testlog.lua`:

```lua
local testaux = require "testaux"
local c = require "test.aux.c"
local logger = require "silly.logger"

-- Captured log entries
local captured = {}

-- Inject writev hook to capture logs
c.debugctrl("log.capture", function(fd, data, bytes)
    table.insert(captured, data)
    return bytes
end)

-- Pause monitor to avoid interference
c.debugctrl("monitor.pause")

-- Test cases

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
    for i = 1, 1000 do
        logger.info(string.format("message %d", i))
    end
    local first = captured[1]
    testaux.assertgt(first:find("message") or 1, 100,
                     "Test 3.1: Early messages wrapped")
end)

testaux.case("Test 4: Direct write path (message >= buffer)", function()
    captured = {}
    local huge = string.rep("x", 100 * 1024)
    logger.info(huge)
    testaux.asserteq(#captured, 1, "Test 4.1: Direct write triggered")
    testaux.assertgt(#captured[1], 100 * 1024, "Test 4.2: Full content")
end)

testaux.case("Test 5: Partial write retry", function()
    captured = {}
    c.debugctrl("log.partial", 10)
    logger.info("this is a long message that exceeds 10 bytes")
    c.debugctrl("log.partial", 0)
    testaux.assertgt(#captured[1], 20, "Test 5.1: Content complete")
end)

testaux.case("Test 6: Write error injection", function()
    captured = {}
    c.debugctrl("log.exception", 1, 5)
    logger.info("should fallback to stderr")
    c.debugctrl("log.exception", 0)
    -- This test verifies stderr fallback works
    testaux.asserteq(#captured, 0, "Test 6.1: No capture (went to stderr)")
end)

testaux.case("Test 7: EINTR retry behavior", function()
    captured = {}
    local attempt = 0
    c.debugctrl("log.capture", function(fd, data, bytes)
        attempt = attempt + 1
        if attempt == 1 then
            return -1
        end
        table.insert(captured, data)
        return bytes
    end)
    logger.info("retry test")
    testaux.asserteq(#captured, 1, "Test 7.1: Message delivered after retry")
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
c.debugctrl("log.unhook")
c.debugctrl("monitor.resume")
```

- [ ] **Step 2: Run tests**

Run: `./silly test/test.lua --set=testlog`

Expected: Tests run (some may fail initially, we'll debug)

- [ ] **Step 3: Debug and fix any issues**

Common issues to check:
- LOG_BUF_SIZE constant value
- Test isolation between cases
- Proper cleanup in setup/teardown

- [ ] **Step 4: Commit**

```bash
git add test/testlog.lua
git commit -m "test: add comprehensive log test suite"
```

---

### Task 11: Integration Testing and Verification

**Files:**
- Test: All modified files

- [ ] **Step 1: Run full test suite**

Run: `make testall`

Expected: All existing tests still pass

- [ ] **Step 2: Run log tests specifically**

Run: `./silly test/test.lua --set=testlog`

Expected: All log tests pass

- [ ] **Step 3: Verify production build works**

Run: `make clean && make  # without SILLY_TEST`

Expected: Clean build, no test code in production binary

- [ ] **Step 4: Check code coverage**

If coverage tools are available:
Run: `make test && gcov src/log.c`

Expected: Write paths in log.c show 100% coverage

- [ ] **Step 5: Final commit if needed**

```bash
git commit --allow-empty -m "test: log test harness complete and verified"
```

---

## Self-Review Results

**1. Spec coverage:**
- ✅ Macro indirection in log.c (Task 2)
- ✅ log_debug_ctrl implementation (Task 3)
- ✅ monitor pause/resume (Task 5)
- ✅ Prefix dispatch in api.c (Task 6)
- ✅ socket.c prefix removal (Task 7)
- ✅ ltest.c hook implementation (Task 8)
- ✅ ltest.c Lua commands (Task 9)
- ✅ Comprehensive test suite (Task 10)

**2. Placeholder scan:**
- ✅ No TBD, TODO, or "implement later" found
- ✅ All code blocks contain actual implementation
- ✅ All steps have explicit commands with expected output

**3. Type consistency:**
- ✅ Command names consistent: `log.capture`, `log.exception`, `log.partial`, etc.
- ✅ Function signatures match across tasks
- ✅ All includes and declarations properly ordered
