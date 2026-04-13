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
  local errno = require "silly.errno"
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
      return nil, errno.TIMEDOUT
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
- `lsilly.c`: Core runtime (fork, wait, wakeup)
- `ltime.c`: Timer operations
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

### Error Reporting in Low-Level Code

In low-level modules (C engine, transport layer), pick **one** of: log the error, or return the error code to the caller. Do not do both. If the returned errno already tells the caller what went wrong, an additional `log_error` is redundant noise — the caller decides whether the failure is worth logging and in what context. Only log at the lowest layer when the error cannot be propagated (e.g., inside an event handler with no caller) or when local context (ip/port, sid) adds diagnostic value the caller does not have.

## Module Reference Index

For API details (function signatures, options, semantics), read the authoritative doc for the module rather than relying on memory. Paths are relative to the repo root.

Always prefer these over web search or training-data recall — they match the current code. Type stubs in `lualib/types/silly/` complement these with machine-readable signatures.

### Core runtime
| Module | Doc |
|---|---|
| `silly` | `docs/src/en/reference/silly.md` |
| `silly.task` | `docs/src/en/reference/task.md` |
| `silly.time` | `docs/src/en/reference/time.md` |
| `silly.logger` | `docs/src/en/reference/logger.md` |
| `silly.env` | `docs/src/en/reference/env.md` |
| `silly.signal` | `docs/src/en/reference/signal.md` |
| `silly.trace` | `docs/src/en/reference/trace.md` |
| `silly.errno` | `lualib/types/silly/errno.lua` (type stub is authoritative) |

### Network
| Module | Doc |
|---|---|
| `silly.net` | `docs/src/en/reference/net.md` |
| `silly.net.tcp` | `docs/src/en/reference/net/tcp.md` |
| `silly.net.tls` | `docs/src/en/reference/net/tls.md` |
| `silly.net.udp` | `docs/src/en/reference/net/udp.md` |
| `silly.net.http` | `docs/src/en/reference/net/http.md` |
| `silly.net.websocket` | `docs/src/en/reference/net/websocket.md` |
| `silly.net.grpc` | `docs/src/en/reference/net/grpc.md` |
| `silly.net.cluster` | `docs/src/en/reference/net/cluster.md` |
| `silly.net.dns` | `docs/src/en/reference/net/dns.md` |
| `silly.net.addr` | `docs/src/en/reference/net/addr.md` |

### Sync / ADT / Storage
| Module | Doc |
|---|---|
| `silly.sync.channel` / `mutex` / `waitgroup` | `docs/src/en/reference/sync/` |
| `silly.adt.buffer` / `queue` | `docs/src/en/reference/adt/` |
| `silly.store.mysql` / `redis` / `etcd` | `docs/src/en/reference/store/` |

### Crypto / Encoding / Security / Metrics / Misc
| Module | Doc |
|---|---|
| `silly.crypto.*` | `docs/src/en/reference/crypto/` |
| `silly.encoding.base64` / `json` | `docs/src/en/reference/encoding/` |
| `silly.security.jwt` | `docs/src/en/reference/security/jwt.md` |
| `silly.metrics.*` | `docs/src/en/reference/metrics/` |
| `silly.console` / `debugger` / `hive` / `patch` / `perf` | `docs/src/en/reference/<name>.md` |

Tutorials (end-to-end examples) live under `docs/src/en/tutorials/`. Runnable scripts live under `examples/`; CLI flags are documented via `./silly --help`.

### errno Boundary (rule, not reference)

`silly.errno` exists to give network errors a **uniform, human-readable string format with a numeric suffix** (e.g. `"End of file (10004)"`) so logs across modules read the same. It is *not* a typed enum for control flow.

The rule users of the library see is simple: **look at the function's `---@return` annotation**. If the error is declared as `silly.errno?`, callers may compare it against `silly.errno` constants. If it is declared as `string?`, callers must treat it as an opaque string for logging only. Everything below is the policy we enforce when writing modules so that this user-facing rule holds.

**Who may annotate errors as `silly.errno?`** (and therefore allow callers to branch on them):
- `silly.net`
- `silly.net.tcp`
- `silly.net.tls`
- `silly.net.udp`

Nothing else. Every other module — `silly.net.http` (including `http.h1`, `http.h2`, `http.client`), `silly.net.websocket`, `silly.net.grpc.*`, `silly.net.cluster`, `silly.net.dns`, `silly.store.*`, `silly.sync.*`, application APIs — must annotate error returns as `string?`, even when the value at runtime happens to be a `silly.errno` constant. Their callers are forbidden from comparing the error against `silly.errno`.

**Producing / propagating vs. typed contract**:
- Any module may *construct or pass through* a `silly.errno` value internally. Doing so just means "the string surfaced in logs will be uniformly formatted". It does **not** widen the module's typed contract.
- The contract is whatever the `---@return` annotation says. A module annotated `string?` remains free to rewrap, translate, or replace its error strings in the future without breaking the contract.

**Why this matters**: the moment downstream code branches on `errno.XXX` from a non-transport module, that module loses the freedom to change its error wording — and the wide `silly.errno` table (which surfaces every libc errno on the platform) becomes load-bearing in places it was never meant to be.

**Peer close**: a normal peer close reported through transport `close` callbacks is `errno.EOF`, not `nil`.

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
   local errno = require "silly.errno"
   local timer = time.after(timeout, read_timer, s)
   local dat = wait()
   if dat == TIMEOUT then
       return nil, errno.TIMEDOUT
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

## Documentation

- Official docs: https://findstr.github.io/silly/
- API Reference: https://findstr.github.io/silly/reference/
- Tutorials: https://findstr.github.io/silly/tutorials/
