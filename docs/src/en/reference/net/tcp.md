---
title: silly.net.tcp
icon: network-wired
category:
  - API Reference
tag:
  - Network
  - TCP
  - Protocol
---

# silly.net.tcp

The `silly.net.tcp` module provides a high-level asynchronous API for handling TCP network connections. Built on coroutines, it enables writing clear, sequential-style code without callbacks for read operations. TCP is a connection-oriented, reliable, stream-based transport layer protocol.

## Module Import

```lua validate
local tcp = require "silly.net.tcp"
```

## Core Concepts

### Asynchronous Operations

Functions that read data from sockets, such as `conn:read`, are **asynchronous**. This means if data is not immediately available, they will suspend the current coroutine and resume execution when data arrives. This allows a single-threaded Silly service to efficiently handle many concurrent connections.

### Connection-Oriented

TCP is a connection-oriented protocol, meaning a connection must be established before data transmission. Once established, data is transmitted reliably and in order, guaranteeing arrival in the same sequence as sent.

## API Documentation

### tcp.listen(conf)

Starts a TCP server listening on the given address.

- **Parameters**:
  - `conf`: `table` - Configuration table with the following fields:
    - `addr`: `string` - Listening address, e.g., `"127.0.0.1:8080"` or `":8080"`
    - `accept`: `async fun(conn)` - Connection callback function executed for each new client connection
      - `conn`: Connection object (`silly.net.tcp.conn`)
    - `backlog`: `integer|nil` (optional) - Maximum length of pending connection queue
- **Returns**:
  - Success: `silly.net.tcp.listener` - Listener object
  - Failure: `nil, string` - nil and error message
- **Example**:

```lua validate
local tcp = require "silly.net.tcp"

local listener, err = tcp.listen {
    addr = "127.0.0.1:8080",
    accept = function(conn)
        print("New connection from:", conn.remoteaddr)
        -- Handle connection...
        conn:close()
    end
}

if not listener then
    print("Listen failed:", err)
end
```

### tcp.connect(addr [, opts])

Establishes a connection to a TCP server (asynchronous).

- **Parameters**:
  - `addr`: `string` - Server address to connect to, e.g., `"127.0.0.1:8080"`
  - `opts`: `table|nil` (optional) - Configuration options
    - `bind`: `string|nil` - Local address to bind client socket to
    - `timeout`: `integer|nil` - Connection timeout in milliseconds, no timeout if not set
- **Returns**:
  - Success: `silly.net.tcp.conn` - Connection object
  - Failure: `nil, string` - nil and error message ("connect timeout" if timed out)
- **Async**: This function is asynchronous and waits for connection or timeout
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn, err = tcp.connect("127.0.0.1:8080")
    if not conn then
        print("Connect failed:", err)
        return
    end
    print("Connected! Remote addr:", conn.remoteaddr)
    conn:close()
end)
```

### conn:close()

Closes a TCP connection.

- **Returns**:
  - Success: `true`
  - Failure: `false, string` - false and error message (if socket is already closed or invalid)
- **Example**:

```lua validate
local tcp = require "silly.net.tcp"

local conn, err = tcp.connect("127.0.0.1:8080")
if not conn then return end

local ok, err = conn:close()
if not ok then
    print("Close failed:", err)
end
```

### conn:write(data)

Writes data to the socket. From the user's perspective, this operation is non-blocking; data is buffered and sent by the framework.

- **Parameters**:
  - `data`: `string|table` - Data to send, can be a string or table of strings
- **Returns**:
  - Success: `true`
  - Failure: `false, string` - false and error message
- **Example**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

-- Send string
conn:write("Hello, World!\n")

-- Send multiple strings (zero-copy)
conn:write({"HTTP/1.1 200 OK\r\n", "Content-Length: 5\r\n\r\n", "Hello"})
```

### conn:read(n [, timeout])

Reads exactly `n` bytes or reads data from the socket until a delimiter is found (asynchronous).

- **Parameters**:
  - `n`: `integer|string` - Number of bytes to read or delimiter
    - If integer: read specified number of bytes
    - If string: read until delimiter is encountered (including delimiter)
- **Returns**:
  - Success: `string` - Data read
  - Failure: `nil, string` - nil and error message
  - **EOF**: `"", "end of file"` - Empty string and "end of file" error message
- **Async**: Suspends coroutine if data is not ready until data arrives
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn, err = tcp.connect("127.0.0.1:8080")
    if not conn then
        return
    end

    -- Read a line (ending with \n)
    local line, err = conn:read("\n")
    if err then  -- Use err to check connection status (including EOF)
        print("Read failed:", err)
        conn:close()
        return
    end

    print("Received:", line)

    -- Read fixed number of bytes
    local header, err = conn:read(4)
    if err then
        print("Read failed:", err)
        conn:close()
        return
    end

    print("Header:", header)
    conn:close()
end)
```

::: tip Error Handling Best Practice
You should use `if err then` to check for connection closure, not `if not data then`. This is because on EOF, `conn:read()` returns `"", "end of file"`, where `data` is an empty string (truthy), but `err` is not nil.
:::

### conn:readline(delim)

::: warning Deprecated
This method is deprecated. Please use `conn:read(delim)` instead.
:::

Reads from socket until a specific delimiter is found (asynchronous). This is an alias for `conn:read(delim)`.

- **Parameters**:
  - `delim`: `string` - Delimiter (e.g., `"\n"`)
- **Returns**:
  - Success: `string` - Line of text (including delimiter)
  - Failure: `nil, string` - nil and error message
- **Async**: Suspends coroutine if delimiter is not found until complete line is received
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn, err = tcp.connect("127.0.0.1:8080")
    if not conn then
        return
    end

    -- Recommended: use conn:read("\n") instead
    -- Read a line (ending with \n)
    local line, err = conn:read("\n")
    if not line then
        print("Readline failed:", err)
        conn:close()
        return
    end

    print("Received line:", line)
    conn:close()
end)
```

### conn:unreadbytes()

::: warning Name Change
This method replaces the old `tcp.recvsize(fd)`. Gets the amount of data currently in the receive buffer that has not been read.
:::

Gets the amount of data currently available but not yet read in the receive buffer.

- **Returns**: `integer` - Number of bytes in receive buffer
- **Example**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

local size = conn:unreadbytes()
print("Buffered data:", size, "bytes")
```

### conn:limit(limit)

Sets the size limit for the socket receive buffer. This is a key flow control mechanism to prevent fast senders from overwhelming slow consumers.

- **Parameters**:
  - `limit`: `integer|nil` - Maximum bytes to buffer, or `nil` to disable limit
- **Description**: When receive buffer reaches the limit, TCP flow control pauses receiving more data
- **Example**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

-- Limit receive buffer to 8MB
conn:limit(8 * 1024 * 1024)

-- Disable limit
conn:limit(nil)
```

### conn:unsentbytes()

::: warning Name Change
This method replaces the old `tcp.sendsize(fd)`. Gets the amount of data waiting to be sent in the send buffer.
:::

Gets the amount of data currently held in the send buffer (queued but not yet transmitted).

- **Returns**: `integer` - Number of bytes in send buffer
- **Example**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

conn:write("Large data...")
local size = conn:unsentbytes()
print("Pending send:", size, "bytes")
```

### conn:isalive()

Checks if the connection is still valid.

- **Returns**: `boolean` - Returns `true` if connection is valid and has no errors
- **Example**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

if conn:isalive() then
    print("Connection is still alive")
end
```

### conn.remoteaddr

Gets the remote address of the connection (read-only property).

> **Note**: `remoteaddr` is a property of the connection object. Access it directly without parentheses.

- **Type**: `string` - Remote address string (format: `IP:Port`)
- **Example**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

print("Remote address:", conn.remoteaddr)
```

## Usage Examples

### Example 1: Echo Server

A simple echo server that returns received data back to the client:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

task.fork(function()
    local wg = waitgroup.new()

    -- Start server
    local listenfd = tcp.listen {
        addr = "127.0.0.1:9988",
        accept = function(conn)
            wg:fork(function()
                print("Client connected:", conn.remoteaddr)

                -- Echo data continuously until connection closes
                while true do
                    local line, err = conn:read("\n")
                    if err then
                        print("Client disconnected:", err or "closed")
                        break
                    end

                    print("Echo:", line)
                    conn:write(line)
                end

                conn:close()
            end)
        end
    }

    print("Echo server listening on 127.0.0.1:9988")

    -- Test client
    wg:fork(function()
        time.sleep(100)  -- Wait for server to start

        local conn, err = tcp.connect("127.0.0.1:9988")
        if not conn then
            print("Connect failed:", err)
            return
        end

        -- Send test message
        conn:write("Hello, Echo!\n")
        local response = conn:read("\n")
        print("Received:", response)

        conn:close()
    end)

    wg:wait()
    listenfd:close()
end)
```

### Example 2: HTTP Client

A simple HTTP GET request client:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn, err = tcp.connect("example.com:80")
    if not conn then
        print("Connect failed:", err)
        return
    end

    -- Send HTTP GET request
    local request = "GET / HTTP/1.1\r\n"
                 .. "Host: example.com\r\n"
                 .. "Connection: close\r\n"
                 .. "\r\n"

    conn:write(request)
    print("Request sent")

    -- Read HTTP response
    -- Read status line
    local status = conn:read("\r\n")
    print("Status:", status)

    -- Read headers
    while true do
        local header = conn:read("\r\n")
        if header == "\r\n" then
            break  -- Empty line indicates end of headers
        end
        print("Header:", header)
    end

    -- Read response body (simplified version, only reads available data)
    local body = conn:read(conn:unreadbytes())
    print("Body length:", #body)

    conn:close()
end)
```

### Example 3: Binary Protocol

Handling binary protocol (length + data format):

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

-- Helper functions: integer to bytes conversion
local function pack_uint32(n)
    return string.char(
        n >> 24 & 0xFF,
        n >> 16 & 0xFF,
        n >> 8 & 0xFF,
        n & 0xFF
    )
end

local function unpack_uint32(s)
    local b1, b2, b3, b4 = string.byte(s, 1, 4)
    return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
end

task.fork(function()
    local wg = waitgroup.new()

    -- Server: receive binary messages
    local listenfd = tcp.listen {
        addr = "127.0.0.1:9989",
        accept = function(conn)
            wg:fork(function()
                while true do
                    -- Read 4-byte length header
                    local header, err = conn:read(4)
                    if not header then
                        break
                    end

                    local length = unpack_uint32(header)
                    print("Receiving message of length:", length)

                    -- Read data body
                    local data = conn:read(length)
                    if not data then
                        break
                    end

                    print("Received data:", data)

                    -- Echo
                    conn:write(header)
                    conn:write(data)
                end

                conn:close()
            end)
        end
    }

    -- Client: send binary messages
    wg:fork(function()
        time.sleep(100)

        local conn = tcp.connect("127.0.0.1:9989")
        if not conn then
            return
        end

        -- Send message
        local message = "Binary Protocol Test"
        local header = pack_uint32(#message)

        conn:write(header)
        conn:write(message)
        print("Sent:", message)

        -- Receive echo
        local recv_header = conn:read(4)
        local recv_length = unpack_uint32(recv_header)
        local recv_data = conn:read(recv_length)
        print("Echoed:", recv_data)

        conn:close()
    end)

    wg:wait()
    listenfd:close()
end)
```

## Notes

### 1. Must Call Async Functions in Coroutines

Async functions like `tcp.connect`, `conn:read` must be called in coroutines:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

-- Correct: call in coroutine
task.fork(function()
    local conn = tcp.connect("127.0.0.1:8080")
    -- ...
end)

-- Wrong: cannot call directly in main thread
-- local conn = tcp.connect("127.0.0.1:8080")  -- This will fail!
```

### 2. Close Connections Promptly

Always remember to close connections that are no longer in use to avoid resource leaks:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn = tcp.connect("127.0.0.1:8080")
    if not conn then
        return
    end

    -- Use pcall to ensure connection is closed even on errors
    local ok, err = pcall(function()
        -- ... use connection ...
    end)

    conn:close()  -- Always close

    if not ok then
        print("Error:", err)
    end
end)
```

### 3. Check Return Values

Always check return values and handle error cases:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn, err = tcp.connect("127.0.0.1:8080")
    if not conn then
        print("Connect failed:", err)
        return
    end

    local data, err = conn:read(100)
    if err then
        print("Read failed:", err)
        conn:close()
        return
    end

    conn:close()
end)
```

### 4. Flow Control

For large data transfers, use `conn:limit()` to limit receive buffer and prevent memory exhaustion:

```lua validate
local tcp = require "silly.net.tcp"

-- Limit receive buffer to 8MB
conn:limit(8 * 1024 * 1024)
```

### 5. Send Buffer Management

When writing large amounts of data, check send buffer size to avoid memory accumulation:

```lua validate
local tcp = require "silly.net.tcp"
local time = require "silly.time"

-- If send buffer is too large, wait for a while
if conn:unsentbytes() > 10 * 1024 * 1024 then
    time.sleep(100)
end
```

## Performance Suggestions

### 1. Batch Writes

Use string tables for batch writes to reduce system calls:

```lua validate
local tcp = require "silly.net.tcp"

-- Recommended: batch write (zero-copy)
conn:write({"header", "body1", "body2"})

-- Avoid: multiple calls
conn:write("header")
conn:write("body1")
conn:write("body2")
```

### 2. Set Receive Buffer Limits Reasonably

Set reasonable buffer sizes based on application characteristics:

```lua validate
local tcp = require "silly.net.tcp"

-- Small message scenario: smaller buffer
conn:limit(64 * 1024)  -- 64KB

-- Large file transfer: larger buffer
conn:limit(8 * 1024 * 1024)  -- 8MB
```

### 3. Avoid Frequent Small Reads

Try to use `conn:read(delim)` or read more data at once:

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"

local task = require "silly.task"

task.fork(function()
    local conn = tcp.connect("127.0.0.1:8080")
    if not conn then return end

    -- Recommended: read by line
    local line = conn:read("\n")

    -- Recommended: read fixed size
    local data = conn:read(1024)

    -- Avoid: frequent small reads
    -- for i = 1, 1024 do
    --     conn:read(1)  -- Poor performance
    -- end

    conn:close()
end)
```

## See Also

- [silly](../silly.md) - Core module
- [silly.time](../time.md) - Timer module
- [silly.net.udp](./udp.md) - UDP protocol support
- [silly.net.tls](./tls.md) - TLS/SSL support
- [silly.sync.waitgroup](../sync/waitgroup.md) - Coroutine wait group
