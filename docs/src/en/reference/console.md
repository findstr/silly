---
title: silly.console
icon: terminal
category:
  - API Reference
tag:
  - Tools
  - Console
  - Operations
---

# silly.console

Interactive console module providing TCP remote management interface, supporting runtime information viewing, code injection, debugging, and other operational tasks.

## Module Import

```lua validate
local console = require "silly.console"
```

::: tip Module Feature
The `silly.console` module exports a function. Calling this function starts a TCP listener server that accepts console connections.
:::

## API

### console(config)
Start console server.

- **Parameters**:
  - `config`: `table` - Configuration table
    - `addr`: `string` - Listen address, format `"host:port"` (e.g., `"127.0.0.1:8888"`)
    - `cmd`: `table` (optional) - Custom command table, keys are command names, values are handler functions
- **Description**:
  - Starts TCP listener at specified address after startup
  - Each connection handled independently, supports multiple concurrent console sessions
  - Recommended to listen only on internal network address to avoid security risks

## Built-in Commands

Console provides the following built-in commands (case-insensitive):

### HELP
Display help information for all commands.

- **Syntax**: `HELP`
- **Returns**: List of all command descriptions

### PING
Test if connection is alive.

- **Syntax**: `PING [text]`
- **Returns**: Returns `text` or `"PONG"`

### GC
Perform a full garbage collection.

- **Syntax**: `GC`
- **Returns**: Lua memory usage (KiB)

### INFO
Display all server information.

- **Syntax**: `INFO`
- **Returns**: Information including:
  - Build info: version, Git SHA1, multiplexing API, memory allocator, timer resolution
  - Process info: process ID
  - Metrics info: all Prometheus collector metrics

### SOCKET
Display detailed information about specified socket.

- **Syntax**: `SOCKET <fd>`
- **Parameters**:
  - `fd`: `integer` - Socket file descriptor
- **Returns**: Socket information:
  - fd: File descriptor
  - os_fd: OS file descriptor
  - type: Socket type
  - protocol: Protocol type
  - sendsize: Send buffer size
  - localaddr/remoteaddr: Local and remote addresses (if connected)

### TASK
Display status and stack traces of all coroutine tasks.

- **Syntax**: `TASK`
- **Returns**: List of all active coroutines, including:
  - Coroutine ID
  - Status (running/suspended/...)
  - Complete stack trace

### INJECT
Inject and execute a Lua file.

- **Syntax**: `INJECT <filepath>`
- **Parameters**:
  - `filepath`: `string` - Path to Lua file
- **Returns**: Message indicating injection success or failure
- **Description**:
  - File executes in independent environment, inheriting global environment
  - Can be used for runtime bug fixes or feature additions
  - Use carefully, incorrect code may crash server

### DEBUG
Enter debug mode.

- **Syntax**: `DEBUG`
- **Description**:
  - Starts interactive debugger
  - See [silly.debugger](./debugger.md) for details

### QUIT / EXIT
Exit console connection.

- **Syntax**: `QUIT` or `EXIT`

## Usage Examples

### Example 1: Start Basic Console

```lua validate
local console = require "silly.console"

console({
    addr = "127.0.0.1:8888"
})

print("Console started on 127.0.0.1:8888")
```

### Example 2: Connect Using telnet

```bash
$ telnet 127.0.0.1 8888
```

```
Welcome to console.

Type 'help' for help.

console> help
HELP: List command description. [HELP]
PING: Test connection alive. [PING <text>]
GC: Performs a full garbage-collection cycle. [GC]
INFO: Show all information of server. [INFO]
SOCKET: Show socket detail information. [SOCKET]
TASK: Show all task status and traceback. [TASK]
INJECT: INJECT code. [INJECT <path>]
DEBUG: Enter Debug mode. [DEBUG]
QUIT: Quit the console. [QUIT]

console> ping hello world
hello world

console> gc
Lua Mem Used:1234.56 KiB

console> quit
Bye, Bye
```

### Example 3: View Server Information

Connect to console and execute:

```
console> info

#Build
version:1.0.0
git_sha1:abc1234
multiplexing_api:epoll
memory_allocator:jemalloc
timer_resolution:10 ms

#Process
process_id:12345

#Memory
lua_memory_used:1234.56 KiB
...
```

### Example 4: View All Coroutine Tasks

```
console> task
#Task (3)
Task thread: 0x12345678 - suspended :
  [C]: in function 'tcp.read'
  /app/handler.lua:45: in function 'handle_request'
  ...

Task thread: 0x23456789 - suspended :
  [C]: in function 'time.sleep'
  /app/timer.lua:10: in function 'timer_task'
  ...
```

### Example 5: Inject Fix Code

Suppose there's a bug needing runtime fix, create file `/tmp/fix.lua`:

```lua
-- /tmp/fix.lua
local mymodule = require "mymodule"
mymodule.buggy_function = function()
    print("Fixed version")
end
```

In console:

```
console> inject /tmp/fix.lua
Inject file:/tmp/fix.lua Success
```

### Example 6: Add Custom Commands

```lua validate
local console = require "silly.console"

console({
    addr = "127.0.0.1:8888",
    cmd = {
        -- Custom STATUS command
        status = function(fd)
            return "Server is running normally"
        end,

        -- Custom USERS command, display online user count
        users = function(fd)
            -- local count = get_online_users_count()
            local count = 100  -- Mock
            return string.format("Online users: %d", count)
        end,
    }
})

print("Console with custom commands started")
```

After connecting, can use custom commands:

```
console> status
Server is running normally

console> users
Online users: 100
```

## Security Notes

::: danger Security Risks
Console provides complete access to the server, including code injection and debugging capabilities. Must pay attention to the following security measures:
:::

1. **Listen on Internal Network Only**: Use `127.0.0.1` or internal network address, never expose to public network
2. **Use Firewall**: Even on internal network, should restrict accessible IPs
3. **Consider Authentication**: In production, can implement authentication mechanism in custom commands
4. **Use INJECT Carefully**: Code injection is powerful but dangerous, only use in emergencies
5. **Log Everything**: All console operations are logged, facilitating auditing

## Command Handler Interface

Custom command handler function signature:

```lua
function(fd, ...) -> string | table | nil
```

- **Parameters**:
  - `fd`: `integer` - Client socket file descriptor
  - `...`: Command line arguments (space-separated)
- **Returns**:
  - `string`: Returned directly to client
  - `table`: Joined with newlines then returned
  - `nil`: Closes connection

Example:

```lua validate
local tcp = require "silly.net.tcp"
local console = require "silly.console"

console({
    addr = "127.0.0.1:8888",
    cmd = {
        -- Return string
        echo = function(fd, ...)
            local args = {...}
            return table.concat(args, " ")
        end,

        -- Return table (multiple lines)
        list = function(fd)
            return {
                "Item 1",
                "Item 2",
                "Item 3",
            }
        end,

        -- Close connection
        kick = function(fd)
            return nil  -- Returning nil closes connection
        end,
    }
})
```

## Integration with Other Modules

### Integration with metrics

Console's `INFO` command automatically displays all registered Prometheus metrics:

```lua
local console = require "silly.console"
local prometheus = require "silly.metrics.prometheus"

-- Register custom metric
local counter = prometheus.counter("my_requests", "Total requests")

console({
    addr = "127.0.0.1:8888"
})
```

### Integration with logger

Console automatically logs all connection and disconnection events:

```lua validate
local console = require "silly.console"
local logger = require "silly.logger"

logger.setlevel(logger.INFO)

console({
    addr = "127.0.0.1:8888"
})
```

Log output example:
```
[INFO] console come in: 127.0.0.1:54321
[INFO] 127.0.0.1:54321 leave
```

## See Also

- [silly.debugger](./debugger.md) - Interactive debugger
- [silly.metrics](./metrics/) - Metrics collection
- [silly.logger](./logger.md) - Logging system
- [silly.net.tcp](./net/tcp.md) - TCP networking
