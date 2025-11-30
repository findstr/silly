---
title: silly.debugger
icon: bug
category:
  - API Reference
tag:
  - Tools
  - Debugging
  - Development
---

# silly.debugger

Interactive Lua debugger supporting breakpoints, single-stepping, variable inspection, stack backtraces, and other features for runtime debugging of Lua code.

## Module Import

```lua validate
local debugger = require "silly.debugger"
```

## API

### debugger.start(read, write)
Start debugger session.

- **Parameters**:
  - `read`: `function() -> string|nil` - Read function, returns a line of input, or nil indicating disconnection
  - `write`: `function(data: string|table)` - Write function, sends data to client
- **Returns**: `string|nil` - Debugger session end message, or nil on error
- **Description**:
  - Debugger is exclusive, only one debug session at a time
  - Debugger hooks all active coroutines
  - After exiting debugger, all hooks are cleared

## Debug Commands

After entering debugger, the following commands are available:

### h (help)
Display command help.

- **Syntax**: `h`

### b (breakpoint)
Set breakpoint.

- **Syntax**: `b [filename] [line]`
- **Parameters**:
  - `filename`: `string` (optional) - Filename, defaults to current file
  - `line`: `integer` - Line number
- **Returns**: Breakpoint ID (e.g., `$1`, `$2`)
- **Example**:
```
debugger> b main.lua 42
Breakpoint $1 at file:main.lua, line:42

debugger> b 50
Breakpoint $2 at file:main.lua, line:50
```

### d (delete)
Delete breakpoint.

- **Syntax**: `d [breakpoint_id]`
- **Parameters**:
  - `breakpoint_id`: `integer` (optional) - Breakpoint ID, omit to delete all breakpoints
- **Example**:
```
debugger> d 1
Delete breakpoint $1

debugger> d
Delete breakpoint $ALL
```

### n (next)
Single step (step over function calls).

- **Syntax**: `n`
- **Description**:
  - Execute current line, if there's a function call, won't enter function
  - Only available when paused at breakpoint

### s (step)
Single step (step into function calls).

- **Syntax**: `s`
- **Description**:
  - Execute current line, if there's a function call, will enter function
  - Only available when paused at breakpoint

### c (continue)
Continue program execution.

- **Syntax**: `c`
- **Description**:
  - Continue executing until next breakpoint
  - Only available when paused at breakpoint

### p (print)
Print variable value.

- **Syntax**: `p <variable_name>`
- **Parameters**:
  - `variable_name`: `string` - Variable name
- **Description**:
  - Searches in order: local variables → upvalue → global variables
  - Supports printing tables, strings, numbers, and all other types
  - Only available when paused at breakpoint
- **Example**:
```
debugger> p user_id
Param $1 user_id = 12345

debugger> p config
Upvalue $1 config = {['host'] = 'localhost',['port'] = 8080,}

debugger> p print
Global $_ENV print = function: 0x12345678
```

### bt (backtrace)
Print current coroutine's stack backtrace.

- **Syntax**: `bt`
- **Description**:
  - Displays complete call stack
  - Only available when paused at breakpoint

### q (quit)
Exit debugger.

- **Syntax**: `q`
- **Description**:
  - Clear all breakpoints
  - Resume normal execution of all coroutines
  - Close debug session

## Usage Examples

### Example 1: Start Debugger via console

The `silly.console` module has built-in DEBUG command to start debugger:

```lua validate
local console = require "silly.console"

console({
    addr = "127.0.0.1:8888"
})

print("Console started, use 'telnet 127.0.0.1 8888' and type 'DEBUG' to start debugger")
```

Connect via telnet and start debugger:

```
$ telnet 127.0.0.1 8888
console> debug

debugger> h
List of commands:
b: Insert a break point [b 'filename linenumber']
d: Delete a break point [d 'breakpoint id']
n: Step next line, it will over the call [n]
s: Step next line, it will into the call [s]
c: Continue program being debugged [c]
p: Print variable include local/up/global values [p name]
bt: Print backtrace of all stack frames [bt]
q: Quit debug mode [q]
```

### Example 2: Set Breakpoint and Debug

```
debugger> b main.lua 100
Breakpoint $1 at file:main.lua, line:100

debugger> c
(Program continues until breakpoint...)

debugger main.lua main.lua:100> p request
Param $1 request = {['method'] = 'GET',['path'] = '/api/users',}

debugger main.lua main.lua:100> bt
stack traceback:
        [C]: in function 'breakin'
        main.lua:100: in function 'handle_request'
        main.lua:50: in function <main.lua:45>
        ...

debugger main.lua main.lua:100> n
(Execute next line)

debugger main.lua main.lua:101> s
(Step into function)

debugger utils.lua utils.lua:25> p data
Param $1 data = 'hello world'

debugger utils.lua utils.lua:25> c
(Continue execution)
```

### Example 3: Custom Debug Interface

Can implement debug interface for custom protocol:

```lua validate
local silly = require "silly"
local debugger = require "silly.debugger"
local tcp = require "silly.net.tcp"

-- Start debug server
tcp.listen("127.0.0.1:9999", function(fd, addr)
    print("Debugger connected:", addr)

    -- Define read/write functions
    local read = function()
        return tcp.readline(fd)
    end

    local write = function(data)
        tcp.write(fd, data)
    end

    -- Start debug session
    local result = debugger.start(read, write)

    if result then
        print("Debug session ended:", result)
    else
        print("Debug session error")
    end

    tcp.close(fd)
end)

print("Debugger listening on 127.0.0.1:9999")
```

### Example 4: Debug Scheduled Tasks

Suppose there's scheduled task code:

```lua
local time = require "silly.time"
local task = require "silly.task"

local function timer_task()
    local count = 0
    for i = 1, 3 do  -- Run 3 times for demo
        count = count + 1
        print("Timer tick:", count)
        if i < 3 then
            time.sleep(1000)
        end
        -- Want to set breakpoint here
    end
end

task.fork(timer_task)
```

Debug steps:

```
debugger> b timer.lua 7
Breakpoint $1 at file:timer.lua, line:7

debugger> c
(Wait for timer to trigger...)

debugger timer.lua timer.lua:7> p count
Param $1 count = 5

debugger timer.lua timer.lua:7> n
(Execute next line)

debugger timer.lua timer.lua:8> c
(Continue execution)
```

### Example 5: View Table Structure

```
debugger> p config
Upvalue $1 config = {
  ['server'] = {
    ['host'] = 'localhost',
    ['port'] = 8080,
  },
  ['database'] = {
    ['host'] = 'db.example.com',
    ['name'] = 'mydb',
  },
}
```

### Example 6: Debug Network Request Handling

```lua
local tcp = require "silly.net.tcp"

tcp.listen("0.0.0.0:8080", function(fd, addr)
    local data = tcp.read(fd, 1024)
    -- Set breakpoint here to check received data
    local response = process_request(data)
    tcp.write(fd, response)
    tcp.close(fd)
end)
```

Debug:

```
debugger> b handler.lua 5
Breakpoint $1 at file:handler.lua, line:5

debugger> c
(Wait for client connection...)

debugger handler.lua handler.lua:5> p data
Param $1 data = 'GET /api/users HTTP/1.1\r\n...'

debugger handler.lua handler.lua:5> p addr
Param $2 addr = '192.168.1.100:54321'

debugger handler.lua handler.lua:5> s
(Step into process_request function)
```

## Implementation Details

### Hook Mechanism

Debugger uses Lua's debug hook mechanism:

- **call hook**: Detects function calls, determines whether to enable line hook
- **line hook**: Checks each line of code, determines whether breakpoint is hit
- **return hook**: Tracks call stack depth

### Breakpoint Detection

Breakpoints detected through:

1. Check if source filename matches (supports suffix matching)
2. Check if line number is within function definition range
3. Check if current execution line equals breakpoint line

### Coroutine Management

- Debugger hooks all active coroutines
- When new coroutine created, automatically adds hook
- When coroutine ends, automatically removes hook
- Uses `task.hook()` to listen to coroutine lifecycle

### Thread Locking

When breakpoint triggers:

- Current coroutine is "locked" (paused)
- Other coroutines continue running normally
- Only locked coroutine can use `n`/`s`/`c`/`p`/`bt` commands
- Command prompt shows current file and line number

## Notes

::: warning Performance Impact
Debugger significantly reduces program performance because it needs to hook every function call and line execution. Do not enable debugger in production environment.
:::

::: warning Concurrency Limitation
Only one debug session at a time. If debugger is already running, new debug requests will be rejected.
:::

::: tip Breakpoint Activation
After setting breakpoint, need to execute `c` command to take effect. Breakpoint only checked on next function call.
:::

::: tip Filename Matching
Breakpoint filename supports suffix matching, so `b main.lua 10` can match `/path/to/main.lua`.
:::

## Limitations

1. **C Functions**: Cannot debug inside C functions, can only see C function calls
2. **Tail Calls**: Tail call optimization may cause incomplete stack information
3. **String Escaping**: Special characters in variable values displayed escaped (e.g., `\n`, `\x00`)
4. **Circular References**: Circular references in tables only displayed once to avoid infinite recursion
5. **Large Tables**: Very large tables may produce excessive output, recommend viewing specific fields only

## Integration with console

`silly.console` module has built-in `DEBUG` command:

```lua
function console.debug(fd)
    local read = function()
        return tcp.readline(fd)
    end
    local write = function(dat)
        return tcp.write(fd, dat)
    end
    return debugger.start(read, write)
end
```

This makes entering debugger through console very convenient.

## See Also

- [silly.console](./console.md) - Console command line
- [silly.logger](./logger.md) - Logging system
- [Lua Debug Library](https://www.lua.org/manual/5.4/manual.html#6.10) - Lua debug library documentation
