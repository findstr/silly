# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Silly is a lightweight, high-performance Lua server framework with coroutine-based async/await. It handles 200,000+ requests/second with single-threaded business logic and supports TCP, UDP, HTTP, WebSocket, gRPC, TLS, MySQL, Redis, and more.

## Lua Interpreter

The standalone Lua interpreter is at `deps/lua/lua`. Use it for running pure Lua scripts (benchmarks, utilities) that don't need the silly runtime:

```bash
deps/lua/lua script.lua
```

For scripts that use silly modules (network, coroutines, etc.), use the silly runtime instead:

```bash
./silly script.lua
```

## Build Commands

```bash
make                # Standard build (Linux/macOS/Windows)
make OPENSSL=ON     # Build with OpenSSL/TLS support
make test           # Build with address sanitizer (Linux/macOS)
make clean          # Clean build artifacts
make cleanall       # Clean everything including dependencies
make fmt            # Format C code with clang-format
```

## Testing

```bash
make testall                                      # Run all tests
sh test/test.sh -j                                # Run tests in parallel (Linux only)
./silly test/test.lua --set=testtcp2              # Run specific test suite
./silly test/test.lua --set=testtcp2 --case="Test 11"  # Run specific test case
```

### Test File Organization

- Test files are in `test/` directory, named `test*.lua`
- **ALL tests MUST be wrapped with `testaux.case("Test X: Description", function() ... end)`**
- **ALL assertions MUST use `"Test X.Y:"` prefix format** (e.g., `"Test 11.3: description"`)
- Follow the pattern in `test/testredis.lua` or `test/testtcp2.lua` for reference

## Architecture

### Threading Model

Silly uses a hybrid 4-thread architecture:

1. **Worker Thread (Lua VM)**: Single-threaded business logic, runs Lua code and coroutines
2. **Socket Thread**: Event-driven I/O (epoll/kqueue/iocp), handles up to 65K connections
3. **Timer Thread**: 10ms resolution timing, manages timeouts and scheduled tasks
4. **Monitor Thread**: Health checks, detects slow message processing

Key principle: Single-threaded business logic eliminates locks and race conditions.

### Event Loop Ordering

The worker thread calls `task._dispatch_wakeup()` **after every single message** (timer, socket I/O, signal). This is a critical architectural guarantee:

- Any coroutine woken during message processing runs **before** the next message is dispatched
- Timers cancelled by a woken coroutine are guaranteed cancelled before their EXPIRE event fires

```
message N processed → _dispatch_wakeup() → [ready coroutines run] → message N+1 processed
```

This makes patterns like "wake coroutine, coroutine cancels timer" race-free.

### Yield Semantics

Only these operations yield the current coroutine:

| Yields | Does NOT yield |
|--------|---------------|
| `conn:read()`, `conn:recvfrom()`, `conn:readall()` | `conn:write()`, `conn:sendto()`, `conn:closewrite()` |
| `tcp.connect()`, `tls.connect()` | `udp.connect()` (no handshake) |
| `time.sleep()`, `task.wait()` | `time.after()`, `task.fork()` |
| `channel:pop()` (when empty) | `tcp.listen()`, `udp.bind()` |

**Between a send and the next yield point, no other coroutine can run.** This is critical for reasoning about code correctness without locks.

### Timer Internals

`time.after(ms, func, ud)` runs `func` in a **new coroutine** when the timer fires.

`time.cancel(session)` clears the callback from the dispatch table. The EXPIRE handler checks `sleep_session_task[session]` before running, so cancel works even if the EXPIRE event is already queued — because `_dispatch_wakeup` guarantees the cancelling coroutine runs first.

### Coroutine Flow Control

Network modules implement flow control via coroutines:

- **Critical Pattern**: Clear state first, then call `wakeup` to prevent re-entry bugs:
  ```lua
  local co = s.co
  s.co = nil
  s.delim = nil
  wakeup(co, data)
  ```

- **Timeout Pattern**: Use timer + sentinel value:
  ```lua
  local TIMEOUT = {}

  local timer = time.after(timeout_ms, function(s)
      local co = s.co
      if co then           -- guard: check nil since finish_req may have cleared it
          s.co = nil
          wakeup(co, TIMEOUT)
      end
  end, socket)

  local data = wait()
  if data == TIMEOUT then
      return nil, "read timeout"
  end
  time.cancel(timer)
  ```

### Module Structure

- `lualib/silly/`: Pure Lua modules
- `lualib/silly/net/`: Network protocols (tcp, udp, tls, http, websocket, grpc)
- `lualib/silly/store/`: Database clients (mysql, redis, etcd)
- `lualib/silly/sync/`: Concurrency primitives (channel, mutex, waitgroup)
- `lualib/silly/crypto/`: Cryptography utilities
- `lualib/silly/metrics/`: Prometheus metrics
- `luaclib-src/`: C extensions that compile to `.so` files in `luaclib/`
- `src/`: Core C engine (socket, timer, worker, message queue)

### C-Lua Boundary

C modules in `luaclib-src/` expose APIs to Lua:
- `lnet.c`: Socket operations (connect, listen, send, recv)
- `lhttp.c`: HTTP parsing
- `lualib-silly.c`: Core runtime (fork, wait, wakeup)
- `lualib-time.c`: Timer operations
- `crypto/*.c`: Cryptographic functions (AES, RSA, HMAC, etc.)

### Lua Stack Safety in Recursive C Code

Lua guarantees `LUA_MINSTACK` (20) free stack slots when entering a C function — sufficient for normal, non-recursive operations. However, when C code **recurses to process nested structures** (e.g., encoding nested tables in JSON), the entire recursion shares the same initial stack allocation. Each level consumes a few slots (`lua_pushnil`, `lua_next`, `lua_rawgeti`, etc.), and after ~5 levels the stack silently overflows, causing undefined behavior — `lua_next` returns wrong results, data is corrupted, but the program doesn't crash.

**Fix**: Call `lua_checkstack()` or `luaL_checkstack()` before stack operations in recursive functions. Use `lua_checkstack` (returns 0) when there are C-allocated resources to clean up; use `luaL_checkstack` (raises error) when all resources are GC-managed.

### Platform Headers

`src/platform.h` is for engine internals (`src/`) only. It pulls in event loop types, errno overrides, and other engine-specific details that `.so` modules should not depend on.

For cross-platform functions that exist on all platforms but live in different headers (e.g., `inet_pton` in `<arpa/inet.h>` vs `<ws2tcpip.h>`), use `#ifdef` directly in the `.c` file:

```c
#ifdef __WIN32
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#endif
```

Header includes are not logic — they just tell the compiler where to find declarations. `#ifdef` for header selection is acceptable and does not violate the goal of eliminating platform-specific code branches.

## API Usage Patterns

### TCP

```lua
local tcp = require "silly.net.tcp"

-- Server
local server = tcp.listen {
    addr = "127.0.0.1:8080",
    accept = function(conn)
        local data = conn:read(100)
        conn:write("response")
        conn:close()
    end
}

-- Client
local conn = tcp.connect("127.0.0.1:8080")
conn:write("request")
local response = conn:read(100)
conn:close()
```

### HTTP

```lua
local http = require "silly.net.http"

-- Server
local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        local body = stream:readall()
        stream:respond(200, {["content-type"] = "application/json"})
        stream:closewrite(response_data)  -- preferred: write + close in one call
    end
}

-- Client
local httpc = http.newclient({max_idle_per_host = 10, idle_timeout = 30000})
local response = httpc:get("http://example.com/api")
local response = httpc:post("http://example.com/api", headers, body)

-- Streaming
local stream = httpc:request("POST", "http://example.com/api", headers)
stream:closewrite(request_data)
local response_body = stream:readall()
```

### TLS

```lua
local tls = require "silly.net.tls"

-- Server
local server = tls.listen {
    addr = "0.0.0.0:443",
    certs = {{cert = cert_pem_string, key = key_pem_string}},
    accept = function(conn) end
}

-- Client
local conn = tls.connect("example.com:443", true)  -- true = verify certificate
```

### Important Notes

- **No `silly.start()` required**: The framework starts the event loop automatically
- **listen() returns immediately**: Accept connections in background
- **All I/O is coroutine-based**: Operations yield and resume via the scheduler
- **Connection objects are tables**: Use method syntax `conn:read()`, `stream:respond()`

## Code Patterns

### Table Iteration Safety

During `pairs` traversal:
- **Deleting keys** (setting to nil) is safe — `next` handles dead slots correctly
- **Inserting new keys** is undefined behavior and must be avoided

```lua
-- OK: delete during iteration
for k, v in pairs(t) do
    t[k] = nil  -- safe
end

-- NOT OK: insert during iteration
for k, v in pairs(t) do
    t[new_key] = value  -- undefined behavior
end
```

### Adding Timeout to Network Operations

1. Add sentinel: `local TIMEOUT<const> = {}`
2. In timer callback, guard with nil check before wakeup (the data path may have already resolved):
   ```lua
   local function read_timer(s)
       local co = s.co
       if co then
           s.co = nil
           wakeup(co, TIMEOUT)
       end
   end
   ```
3. In read function:
   ```lua
   local timer = time.after(timeout, read_timer, s)
   local dat = wait()
   if dat == TIMEOUT then
       return nil, "read timeout"
   end
   time.cancel(timer)
   ```

### Test Assertion Patterns

```lua
testaux.asserteq(value, expected, "Test 5.3: description")
testaux.assertneq(fd, nil, "Test 1.1: Connect to server")
testaux.assertgt(count, 0, "Test 7.2: Should have buffered data")
```

### Test Synchronization Patterns

**NEVER use `time.sleep()` for synchronization** — use `silly.sync.channel`:

```lua
local channel = require "silly.sync.channel"
local sync_ch = channel.new()

-- Signal from async handler
server_handler = function(stream)
    sync_ch:push("done")
end

-- Wait in test
client:send(data)
local result = sync_ch:pop()  -- blocks until handler runs
testaux.asserteq(result, "done", "Test 1.1: Handler completed")
```

## Running Examples

```bash
./silly examples/tcp_echo.lua
./silly examples/http_server.lua --port=8080
```

## Command Line Options

```bash
./silly main.lua [options]

-h, --help              Display help
-v, --version           Show version
-d, --daemon            Run as daemon
-p, --logpath PATH      Log file path
-l, --loglevel LEVEL    Log level (debug/info/warn/error)
-f, --pidfile FILE      PID file path
--key=value             Custom args, accessible via env.get("key")
```

## Documentation

- Official docs: https://findstr.github.io/silly/
- API Reference: https://findstr.github.io/silly/reference/
- Tutorials: https://findstr.github.io/silly/tutorials/
