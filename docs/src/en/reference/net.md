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

Addresses use the `host:port` form. Splitting is done by `silly.net.addr.parse`:

- **No `[...]` brackets** — the parser uses the **first** `:` as the host/port separator. So `"127.0.0.1:8080"` works, but `"::1:8080"` is **not** an IPv6 loopback — it parses as `host=""`, `port=":1:8080"` and fails further validation.
- **`[...]` brackets** — required to disambiguate any IPv6 literal that contains `:`. The closing `]` must be followed by `:port`.

**IPv4 Examples**:
- `"127.0.0.1:8080"` — Local loopback address
- `"0.0.0.0:9000"` — Listen on all IPv4 interfaces
- `":8080"` — Shorthand: empty host, port `8080` (the listen wrappers normalize empty host to `0::0`, i.e. all interfaces)

**IPv6 Examples**:
- `"[::1]:8080"` — IPv6 loopback (brackets required)
- `"[::]:8080"` — Listen on all IPv6 interfaces
- `"[2001:db8::1]:443"` — Any IPv6 literal containing `:` must use brackets

**Domain Example**:
- `"example.com:80"`

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
- `err` (`silly.errno?`): Error code on failure

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

### net.tcpconnect(addr, event, bind, timeout)

Connect to TCP server.

**Parameters**:
- `addr` (string): Server address
- `event` (table): Event handler table (same as `tcplisten`, but no `accept` needed)
- `bind` (string, optional): Local bind address (`"ip:port"`)
- `timeout` (integer, optional): Connection timeout in milliseconds; on expiry the in-flight socket is closed and `errno.TIMEDOUT` is returned

**Returns**:
- `fd` (integer): Connected file descriptor
- `err` (`silly.errno?`): Error code on failure

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

### net.tcpsend(fd, data[, size])

Send data to TCP socket.

**Parameters**:
- `fd` (integer): Socket file descriptor
- `data` (string|lightuserdata|table): Data to send
  - `string` — sent as-is; size is `#data`
  - `lightuserdata` — raw memory pointer; **must** pass `size` as the next argument
  - `table` — array of strings; sent as one combined buffer
- `size` (integer, optional): Required only when `data` is `lightuserdata`

**Returns**:
- `ok` (boolean): Whether successful
- `err` (`silly.errno?`): Error code on failure

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

### net.tcpmulticast(fd, ptr, size)

Send a single buffer (a multipack handle from `net.multipack`) to one TCP socket without copying. The buffer's reference count is decremented after the send completes; freeing happens automatically when the count reaches zero.

**Parameters**:
- `fd` (integer): Target file descriptor
- `ptr` (lightuserdata): Buffer returned by `net.multipack`
- `size` (integer): Buffer size in bytes

**Returns**:
- `ok` (boolean): Whether the send was queued successfully
- `err` (`silly.errno?`): Error code on failure

::: tip Multicast Pattern
Allocate one buffer with `net.multipack(data, fanout)` (where `fanout` is the number of intended receivers, used as the initial refcount), then call `net.tcpmulticast(fd, ptr, size)` once per receiver. The shared buffer is freed automatically once every receiver's send completes.
:::

## UDP Functions

### net.udpbind(addr, event)

Bind UDP socket to specified address.

**Parameters**:
- `addr` (string): Bind address
- `event` (table): Event handler table:
  - `data` (function): `function(fd, ptr, size, addr)` - Data receive callback (note has `addr` parameter)
  - `close` (function): `function(fd, errno)` - Close callback

(The wrapper accepts a third `backlog` argument for symmetry with `tcplisten`, but UDP has no listen queue and the value is ignored.)

**Returns**:
- `fd` (integer): UDP socket file descriptor
- `err` (`silly.errno?`): Error code on failure

**Example**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

local udpfd = net.udpbind("[::]:9000", {
    data = function(fd, ptr, size, addr)
        local data = silly.tostring(ptr, size)
        print("UDP from", addr, ":", data)
        -- Reply to client
        net.udpsend(fd, data, addr)
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
- `err` (`silly.errno?`): Error code on failure

### net.udpsend(fd, data, [size,] [addr])

Send UDP datagram. The argument layout depends on the `data` type:

| `data` type | Call form | Notes |
|---|---|---|
| `string` | `net.udpsend(fd, str)` or `net.udpsend(fd, str, addr)` | Size is `#str`; `addr` only needed for an unconnected socket |
| `table` (array of strings) | `net.udpsend(fd, tbl)` or `net.udpsend(fd, tbl, addr)` | Strings are concatenated in order |
| `lightuserdata` | `net.udpsend(fd, ptr, size)` or `net.udpsend(fd, ptr, size, addr)` | `size` is **required** when sending a raw pointer |

**Returns**:
- `ok` (boolean): Whether successful
- `err` (`silly.errno?`): Error code on failure

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
- `err` (`silly.errno?`): Error code on failure

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
- `errno` (`silly.errno`): Close reason. A normal peer close is typically reported as `errno.EOF`; other cases use the corresponding low-level error

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

Address format strictly follows `[IP]:Port` for any IPv6 literal that contains `:`. The parser uses the **first** `:` outside brackets as the host/port separator, so `"::1:8080"` and `"::1"` are not valid IPv6 addresses to it:

- IPv4: `"192.168.1.1:8080"`
- IPv6: `"[2001:db8::1]:8080"` (brackets required)
- Shorthand: `":8080"` — empty host plus port; the listen wrapper turns the empty host into `0::0` (all interfaces, both families)

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
