---
title: silly.net.websocket
icon: plug
category:
  - API Reference
tag:
  - Network
  - WebSocket
  - Real-time Communication
---

# silly.net.websocket

The `silly.net.websocket` module provides a complete WebSocket protocol implementation (RFC 6455), supporting both server-side and client-side. Built on coroutines, it offers a clean asynchronous API that automatically handles handshake, frame encoding/decoding, fragmentation, masking, and other protocol details.

## Module Import

```lua validate
local websocket = require "silly.net.websocket"
```

## Core Concepts

### WebSocket Protocol

WebSocket is a protocol that enables full-duplex communication over a single TCP connection, with the following key features:

- **Bidirectional Communication**: Both server and client can actively send messages at any time
- **Low Latency**: Compared to HTTP polling, WebSocket avoids frequent handshake overhead
- **Frame Types**: Supports text frames, binary frames, and control frames (ping/pong/close)
- **Automatic Fragmentation**: Large messages are automatically fragmented for transmission, handled transparently

### Upgrade Mechanism

WebSocket connections are typically upgraded from HTTP connections. In `silly`, the server-side must first use `silly.net.http` to accept the connection, then call `websocket.upgrade` to upgrade it to a WebSocket connection.

### Socket Object

WebSocket connections are represented by socket objects:

- **Server-side**: The `upgrade` function returns a socket object
- **Client-side**: The `connect` function returns a socket object

---

## Server-side API

### websocket.upgrade(stream)

Upgrades an HTTP stream to a WebSocket connection.

- **Parameters**:
  - `stream`: `table` - HTTP stream object (provided by the handler of `http.listen`)
- **Returns**:
  - Success: `socket` - WebSocket socket object
  - Failure: `nil, string` - nil and error message
- **Notes**:
  - Before calling this function, the stream must be in an open state
  - After successful upgrade, do not operate on the original stream object
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"

task.fork(function()
    local server = http.listen {
        addr = ":8080",
        handler = function(stream)
            -- Check if this is a WebSocket upgrade request
            if stream.header["upgrade"] == "websocket" then
                local sock, err = websocket.upgrade(stream)
                if not sock then
                    print("Upgrade failed:", err)
                    return
                end

                -- WebSocket communication loop
                while true do
                    local data, typ = sock:read()
                    if not data then
                        break
                    end

                    if typ == "text" then
                        sock:write("Echo: " .. data, "text")
                    elseif typ == "close" then
                        break
                    end
                end

                sock:close()
            else
                -- Handle regular HTTP requests
                stream:respond(200, {["content-type"] = "text/plain"})
                stream:close("Not a WebSocket request")
            end
        end
    }

    print("WebSocket server listening on :8080")
end)
```

---

## Client-side API

### websocket.connect(url [, header])

Connects to a WebSocket server (asynchronous).

- **Parameters**:
  - `url`: `string` - WebSocket URL (starting with `ws://` or `wss://`)
  - `header`: `table|nil` (optional) - Custom HTTP request headers
- **Returns**:
  - Success: `socket` - WebSocket socket object
  - Failure: `nil, string` - nil and error message
- **Async**: Suspends the coroutine until the connection is established or fails
- **Notes**:
  - Use `ws://` for plain connections, `wss://` for TLS-encrypted connections
  - Automatically sends WebSocket handshake request
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local websocket = require "silly.net.websocket"

task.fork(function()
    local sock, err = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        print("Connect failed:", err)
        return
    end

    print("Connected to WebSocket server")

    -- Send message
    sock:write("Hello, Server!", "text")

    -- Read response
    local data, typ = sock:read()
    if data then
        print("Received:", data)
    end

    sock:close()
end)
```

---

## Socket API

After the connection is established, the socket object provides the following methods for communication.

### sock:read()

Reads a WebSocket message (asynchronous).

- **Parameters**: None
- **Returns**:
  - Success: `string, string` - Message data and frame type
  - Failure: `nil, string, string` - nil, error message, and partial data
- **Frame Types**: `"text"`, `"binary"`, `"ping"`, `"pong"`, `"close"`, `"continuation"`
- **Async**: Suspends the coroutine until a complete message is received
- **Notes**:
  - Automatically handles fragmented messages, returning complete content
  - When the `close` type is returned, the connection is about to close
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local websocket = require "silly.net.websocket"

task.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then return end

    while true do
        local data, typ = sock:read()
        if not data then break end

        if typ == "text" then
            print("Text:", data)
        elseif typ == "ping" then
            sock:write(data, "pong")
        elseif typ == "close" then
            break
        end
    end
    sock:close()
end)
```

### sock:write(data [, type])

Sends a WebSocket message (asynchronous).

- **Parameters**:
  - `data`: `string|nil` - Data to send (can be empty string or nil)
  - `type`: `string|nil` (optional) - Frame type, default is `"binary"`
    - Valid values: `"text"`, `"binary"`, `"ping"`, `"pong"`, `"close"`
- **Returns**:
  - Success: `true`
  - Failure: `false, string` - false and error message
- **Notes**:
  - Control frames (ping/pong/close) data length cannot exceed 125 bytes
  - Large messages (>= 64KB) are automatically fragmented for transmission
  - Text messages should be valid UTF-8 encoded

### sock:close()

Closes the WebSocket connection.

- **Parameters**: None
- **Returns**: None
- **Notes**:
  - Automatically sends a close frame
  - The socket cannot be used after calling this method

### sock Properties

The socket object contains the following read-only properties:

- `sock.conn`: `table` - Underlying connection object (tcp or tls)
- `sock.stream`: `table` - Associated HTTP stream object

---

## Usage Examples

### Example 1: Broadcast Server

Broadcasting messages to all connected clients:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"
local channel = require "silly.sync.channel"

task.fork(function()
    local clients = {}
    local broadcast_chan = channel.new()

    -- Broadcast coroutine
    task.fork(function()
        while true do
            local message = broadcast_chan:recv()
            for i, sock in ipairs(clients) do
                sock:write(message, "text")
            end
        end
    end)

    http.listen {
        addr = ":8080",
        handler = function(stream)
            if stream.header["upgrade"] == "websocket" then
                local sock = websocket.upgrade(stream)
                if sock then
                    table.insert(clients, sock)

                    while true do
                        local data, typ = sock:read()
                        if not data or typ == "close" then break end
                        if typ == "text" then
                            broadcast_chan:send(data)
                        end
                    end

                    -- Remove client (simplified handling, should be more robust in practice)
                    for i, v in ipairs(clients) do
                        if v == sock then
                            table.remove(clients, i)
                            break
                        end
                    end
                    sock:close()
                end
            else
                stream:respond(404, {})
                stream:close()
            end
        end
    }
end)
```

### Example 2: Secure WebSocket (WSS)

Using HTTPS server to upgrade to WSS:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"

task.fork(function()
    -- Certificate configuration (details omitted)
    local certs = {{
        cert = "-----BEGIN CERTIFICATE-----\n...",
        key = "-----BEGIN PRIVATE KEY-----\n..."
    }}

    http.listen {
        addr = ":8443",
        certs = certs,
        handler = function(stream)
            if stream.header["upgrade"] == "websocket" then
                local sock = websocket.upgrade(stream)
                if sock then
                    sock:write("Secure connection established", "text")
                    -- ... communication loop
                    sock:close()
                end
            end
        end
    }
end)
```
