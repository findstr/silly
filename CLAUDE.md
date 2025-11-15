# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Silly is a lightweight, high-performance Lua server framework with coroutine-based async/await. It handles 200,000+ requests/second with single-threaded business logic and supports TCP, UDP, HTTP, WebSocket, gRPC, TLS, MySQL, Redis, and more.

## Build Commands

```bash
# Standard build (Linux/macOS/Windows)
make

# Build with OpenSSL support for TLS
make OPENSSL=ON

# Build with address sanitizer for debugging (Linux/macOS)
make test

# Clean build artifacts
make clean

# Clean everything including dependencies
make cleanall

# Format C code with clang-format
make fmt
```

## Testing

```bash
# Run all tests (builds with address sanitizer first)
make testall

# Run tests in parallel (Linux only)
sh test/test.sh -j

# Run a specific test suite
./silly test/test.lua --set=testtcp2

# Run a specific test case within a suite
./silly test/test.lua --set=testtcp2 --case="Test 11"
```

### Test File Organization

- Test files are in `test/` directory, named `test*.lua`
- **ALL tests MUST be wrapped with `testaux.case("Test X: Description", function() ... end)`**
- **ALL assertions MUST use `"Test X.Y:"` prefix format** (e.g., `"Test 11.3: Second read should get complete data"`)
- When adding new tests, follow the pattern in `test/testredis.lua` or `test/testtcp2.lua` for reference
- Each test case should have a clear description and sequential sub-assertions (Test 1.1, 1.2, etc.)

### Running Individual Tests

The test runner (`test/test.lua`) loads test files via `--set` parameter:
- `--set=testtcp2` loads `test/testtcp2.lua`
- `--set=adt/testqueue` loads `test/adt/testqueue.lua`

## Architecture

### Threading Model

Silly uses a hybrid 4-thread architecture:

1. **Worker Thread (Lua VM)**: Single-threaded business logic, runs Lua code and coroutines
2. **Socket Thread**: Event-driven I/O (epoll/kqueue/iocp), handles up to 65K connections
3. **Timer Thread**: 10ms resolution timing, manages timeouts and scheduled tasks
4. **Monitor Thread**: Health checks, detects slow message processing

Key principle: Single-threaded business logic eliminates locks and race conditions.

### Coroutine Flow Control

Network modules (`tcp.lua`, `tls.lua`, `udp.lua`) implement flow control via coroutines:

- **State Management**: Each socket has `s.co` (waiting coroutine), `s.delim` (read delimiter), `s.err` (error state)
- **Critical Pattern**: When waking a coroutine, ALWAYS clear state first, then call `wakeup`:
  ```lua
  local co = s.co
  s.co = nil
  s.delim = nil
  wakeup(co, data)
  ```
  This prevents re-entry bugs if the woken coroutine immediately calls read again.

- **Timeout Implementation**: Uses timer + sentinel value pattern:
  ```lua
  local TIMEOUT = {}  -- Unique sentinel value

  local timer = time.after(timeout_ms, function(s)
      local co = s.co
      if co then
          s.co = nil
          s.delim = nil
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

## Code Patterns

### Adding Timeout to Network Operations

When adding timeout support to network read operations (as done in tcp/tls/udp):

1. Add `TIMEOUT` constant: `local TIMEOUT<const> = {}`
2. Add timeout parameter to read functions: `function read(s, n, timeout)`
3. Create timer callback that clears state before wakeup:
   ```lua
   local function read_timer(s)
       local co = s.co
       if co then
           s.co = nil
           s.delim = nil  -- or any other state
           twakeup(co, TIMEOUT)
       end
   end
   ```
4. In read function, handle timeout:
   ```lua
   if not timeout then
       dat = wait()
   else
       local timer = time.after(timeout, read_timer, s)
       dat = wait()
       if dat == TIMEOUT then
           return nil, "read timeout"
       end
       time.cancel(timer)
   end
   ```
5. Ensure ALL wakeup paths (data arrival, close, error) follow state-cleanup-first pattern

### Test Assertion Patterns

Use descriptive assertion messages with test numbers:
```lua
testaux.asserteq(value, expected, "Test 5.3: Second read should get complete data")
testaux.assertneq(fd, nil, "Test 1.1: Connect to server")
testaux.assertgt(count, 0, "Test 7.2: Should have buffered data")
```

## Running Examples

```bash
# Basic TCP echo server
./silly examples/tcp_echo.lua

# HTTP server on port 8080
./silly examples/http_server.lua --port=8080

# Access custom arguments in Lua
local env = require "silly.env"
local port = env.get("port")  -- "8080"
```

## Command Line Options

```bash
./silly main.lua [options]

# Core
-h, --help              Display help
-v, --version           Show version
-d, --daemon            Run as daemon

# Logging
-p, --logpath PATH      Log file path
-l, --loglevel LEVEL    Log level (debug/info/warn/error)
-f, --pidfile FILE      PID file path

# Custom key-value pairs
--key=value             Accessible via env.get("key")
```

## Documentation

- Official docs: https://findstr.github.io/silly/
- API Reference: https://findstr.github.io/silly/reference/
- Tutorials: https://findstr.github.io/silly/tutorials/
