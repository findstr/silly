---
title: silly.net
icon: network-wired
category:
  - API Reference
tag:
  - Network
  - Socket
  - Low-level API
---

# silly.net

`silly.net` is the low-level network module of the Silly framework, providing basic TCP/UDP socket operations. It is the foundation for higher-level modules like `silly.net.tcp` and `silly.net.udp`.

::: warning Usage Recommendation
For most application scenarios, it's recommended to use higher-level modules like [silly.net.tcp](./net/tcp.md) or [silly.net.udp](./net/udp.md). The `silly.net` module provides low-level APIs that require manual management of callbacks and events.
:::

## Module Import

```lua validate
local net = require "silly.net"
```

## Address Format

All network addresses use a unified format: `"[IP]:Port"`

**IPv4 Examples**:
- `"127.0.0.1:8080"` - Local loopback address
- `"0.0.0.0:9000"` - Listen on all interfaces
- `":8080"` - Shorthand form, equivalent to `"0.0.0.0:8080"`

**IPv6 Examples**:
- `"[::1]:8080"` - IPv6 local loopback
- `"[2001:db8::1]:9000"` - IPv6 address
- `"[::]:8080"` - Listen on all IPv6 interfaces

## TCP Functions

### net.tcplisten(addr, event, backlog)

Create TCP listener at specified address.

**Parameters**:
- `addr` (string): Listen address, format `"[IP]:Port"`
- `event` (table): Event handler table, contains following fields:
  - `accept` (function, optional): `function(fd, listenid, addr)` - New connection callback
  - `data` (function): `function(fd, ptr, size)` - Data receive callback
  - `close` (function): `function(fd, errno)` - Connection close callback
- `backlog` (integer, optional): Listen queue size, default 256

**Returns**:
- `fd` (integer): Listen socket file descriptor
- `err` (string): Error message (on failure)

**Example**:
```lua validate
local silly = require "silly"
local task = require "silly.task"
local net = require "silly.net"

local listenfd = net.tcplisten("[::]:8080", {
    accept = function(fd, listenid, addr)
        print("New connection from:", addr)
    end,
    data = function(fd, ptr, size)
        local data = silly.tostring(ptr, size)
        print("Received:", data)
    end,
    close = function(fd, errno)
        print("Connection closed:", fd, errno)
    end,
})

if listenfd then
    print("Listening on port 8080")
end
```

### net.tcpconnect(addr, event, bind)

Connect to TCP server.

**Parameters**:
- `addr` (string): Server address
- `event` (table): Event handler table (same as `tcplisten`, but no `accept` needed)
- `bind` (string, optional): Local bind address
- `timeout` (integer, optional): Connection timeout (milliseconds)

**Returns**:
- `fd` (integer): Connected file descriptor
- `err` (string): Error message (on failure)

**Example**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

local fd = net.tcpconnect("127.0.0.1:8080", {
    data = function(fd, ptr, size)
        local data = silly.tostring(ptr, size)
        print("Received:", data)
    end,
    close = function(fd, errno)
        print("Disconnected:", errno)
    end,
})

if fd then
    net.tcpsend(fd, "Hello, Server!\n")
end
```

### net.tcpsend(fd, data, size)

Send data to TCP socket.

**Parameters**:
- `fd` (integer): Socket file descriptor
- `data` (string|lightuserdata|table): Data to send
  - `string`: Send string directly
  - `lightuserdata`: Send raw memory pointer (need to specify `size`)
  - `table`: Send string table (batch send)
- `size` (integer, optional): Data size (required for `lightuserdata`)

**Returns**:
- `ok` (boolean): Whether successful
- `err` (string): Error message (on failure)

**Example**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

-- Assume fd is a connected socket
local fd = 1

-- Send string
net.tcpsend(fd, "Hello\n")

-- Send multiple strings
net.tcpsend(fd, {"Line 1\n", "Line 2\n", "Line 3\n"})
```

### net.tcpmulticast(fd, data, size, addr)

Broadcast data to multiple TCP connections.

**Parameters**:
- `fd` (integer): Starting file descriptor (actually a placeholder)
- `data` (lightuserdata): Data pointer
- `size` (integer): Data size
- `addr` (string, optional): Target address filter

**Returns**:
- `ok` (boolean): Whether successful
- `err` (string): Error message

::: tip Advanced Feature
This function efficiently sends same data to multiple connections, using zero-copy technique internally.
:::

## UDP Functions

### net.udpbind(addr, event, backlog)

Bind UDP socket to specified address.

**Parameters**:
- `addr` (string): Bind address
- `event` (table): Event handler table:
  - `data` (function): `function(fd, ptr, size, addr)` - Data receive callback (note has `addr` parameter)
  - `close` (function): `function(fd, errno)` - Close callback
- `backlog` (integer, optional): Unused (UDP has no listen queue)

**Returns**:
- `fd` (integer): UDP socket file descriptor
- `err` (string): Error message

**Example**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

local udpfd = net.udpbind("[::]:9000", {
    data = function(fd, ptr, size, addr)
        local data = silly.tostring(ptr, size)
        print("UDP from", addr, ":", data)
        -- Reply to client
        net.udpsend(fd, data, size, addr)
    end,
    close = function(fd, errno)
        print("UDP closed:", errno)
    end,
})
```

### net.udpconnect(addr, event, bind)

Connect to UDP server (pseudo-connection, only sets default target address).

**Parameters**:
- `addr` (string): Server address
- `event` (table): Event handler table
- `bind` (string, optional): Local bind address

**Returns**:
- `fd` (integer): UDP socket file descriptor
- `err` (string): Error message

### net.udpsend(fd, data, size_or_addr, addr)

Send UDP datagram.

**Parameters**:
- `fd` (integer): UDP socket file descriptor
- `data` (string|lightuserdata|table): Data to send
- `size_or_addr` (integer|string, optional):
  - If `data` is `lightuserdata`, this is data size
  - If `data` is string and socket not connected, this is target address
- `addr` (string, optional): Target address (used when third arg is size)

**Returns**:
- `ok` (boolean): Whether successful
- `err` (string): Error message

**Example**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

-- Assume fd is a connected or bound UDP socket
local fd = 1

-- Connected UDP socket
net.udpsend(fd, "Hello UDP\n")

-- Unconnected UDP socket, specify target address
net.udpsend(fd, "Hello\n", "127.0.0.1:9000")
```

## Common Functions

### net.close(fd)

Close network socket.

**Parameters**:
- `fd` (integer): Socket file descriptor

**Returns**:
- `ok` (boolean): Whether successful
- `err` (string): Error message

**Example**:
```lua validate
local net = require "silly.net"

-- Assume fd is an open socket
local fd = 1

local ok, err = net.close(fd)
if not ok then
    print("Close error:", err)
end
```

### net.sendsize(fd)

Get send buffer size.

**Parameters**:
- `fd` (integer): Socket file descriptor

**Returns**:
- `size` (integer): Number of bytes in send buffer

**Example**:
```lua validate
local net = require "silly.net"

-- Assume fd is a connected socket
local fd = 1

local pending = net.sendsize(fd)
if pending > 1024 * 1024 then
    print("Warning: send buffer is large")
end
```

## Event Handling

### accept Callback

Called when new TCP connection established.

**Parameters**:
- `fd` (integer): New connection's file descriptor
- `listenid` (integer): Listen socket's file descriptor
- `addr` (string): Client address

::: warning Callback Limitations
Event callback functions execute in coroutines, but `ptr` pointer is only valid during synchronous callback execution. Once callback yields or returns, memory pointed to by `ptr` may be freed. Therefore, **must copy data to string before yielding**.
:::

### data Callback

Called when data received.

**TCP Parameters**:
- `fd` (integer): Connection's file descriptor
- `ptr` (lightuserdata): Data pointer
- `size` (integer): Data size

**UDP Parameters**:
- `fd` (integer): UDP socket file descriptor
- `ptr` (lightuserdata): Data pointer
- `size` (integer): Data size
- `addr` (string): Sender address

::: tip Data Lifetime
The `ptr` pointer is only valid during callback function execution. If need to save data, must use `silly.tostring()` to copy it.
:::

### close Callback

Called when connection closes.

**Parameters**:
- `fd` (integer): Socket file descriptor
- `errno` (integer): Error code (0 means normal close)

## Notes

### 1. Event-Driven Model

`silly.net` uses event-driven model, all I/O operations handled through callbacks:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local net = require "silly.net"

-- Wrong: cannot yield in callback
local fd = net.tcplisten("[::]:8080", {
    data = function(fd, ptr, size)
        -- silly.wait() -- ❌ This will cause error
        local data = silly.tostring(ptr, size)
        net.tcpsend(fd, data) -- ✓ Synchronous operation ok
    end,
    close = function(fd, errno) end,
})

-- Correct: copy data first, then process in fork
local fd2 = net.tcplisten("[::]:8081", {
    data = function(fd, ptr, size)
        local data = silly.tostring(ptr, size) -- Immediately copy data
        task.fork(function()
            -- Now can use async functions to process data (string)
            -- process_async(data)
            net.tcpsend(fd, "OK\n")
        end)
    end,
    close = function(fd, errno) end,
})
```

### 2. Memory Management

Received data pointer (`lightuserdata`) must be converted to string promptly:

```lua
data = function(fd, ptr, size)
    -- ✓ Correct: copy immediately
    local str = silly.tostring(ptr, size)

    -- ❌ Wrong: ptr invalid after leaving callback
    task.fork(function()
        local str = silly.tostring(ptr, size) -- ptr already invalid!
    end)
end
```

### 3. File Descriptor Reuse

File descriptors may be reused by OS, don't save `fd` outside callbacks for long-term use:

```lua
local saved_fd

-- ❌ Dangerous: fd may already be closed and reused
data = function(fd, ptr, size)
    saved_fd = fd
end

-- Later...
net.tcpsend(saved_fd, "data") -- saved_fd may point to other connection
```

### 4. IPv6 Support

Address format strictly follows `[IP]:Port` format:
- IPv4: `"192.168.1.1:8080"`
- IPv6: `"[2001:db8::1]:8080"` (brackets required)
- Shorthand: `":8080"` automatically selects IPv4 or IPv6

## Advanced Usage

### Custom Protocol Parsing

Since `net` module's `data` callback receives raw data pointer, need to use `silly.adt.buffer` to manage receive buffer:

```lua validate
local silly = require "silly"
local net = require "silly.net"
local buffer = require "silly.adt.buffer"

local buffers = {}

local listenfd = net.tcplisten("[::]:8080", {
    accept = function(fd, listenid, addr)
        buffers[fd] = buffer.new()
    end,
    data = function(fd, ptr, size)
        local buf = buffers[fd]
        if not buf then return end

        buffer.append(buf, ptr, size)

        -- Parse line protocol
        while true do
            local line = buffer.read(buf, "\n")
            if not line then break end

            -- Process one line of data
            print("Line:", line)
        end
    end,
    close = function(fd, errno)
        if buffers[fd] then
            buffer.clear(buffers[fd])
            buffers[fd] = nil
        end
    end,
})
```

::: tip
If need more convenient high-level APIs (like `read(n)` or `read("\n")`), recommend using [silly.net.tcp](./net/tcp.md) or [silly.net.tls](./net/tls.md) modules, which have built-in buffer management.
:::

## Performance Considerations

### Batch Send

Using table for batch send reduces system calls:

```lua
-- Send multiple messages at once
net.tcpsend(fd, {
    "Message 1\n",
    "Message 2\n",
    "Message 3\n",
})
```

### Avoid Frequent Close

Frequently creating/destroying connections affects performance, consider using connection pool.

## See Also

- [silly.net.tcp](./net/tcp.md) - High-level TCP API (recommended)
- [silly.net.udp](./net/udp.md) - High-level UDP API (recommended)
- [silly](./silly.md) - Core module
