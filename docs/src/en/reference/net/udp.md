---
title: silly.net.udp
icon: network-wired
category:
  - API Reference
tag:
  - Network
  - UDP
  - Protocol
---

# udp (`silly.net.udp`)

The `silly.net.udp` module provides a high-level asynchronous API for UDP (User Datagram Protocol) networking. UDP is a connectionless, message-oriented protocol, meaning you send and receive discrete packets (datagrams).

## Module Import

```lua validate
local udp = require "silly.net.udp"
```

---

## Core Concepts

Unlike TCP, UDP does not establish persistent connections. Each datagram is sent independently. `conn:recvfrom` is asynchronous: it suspends the current coroutine until a datagram is received and returns the data along with the sender's address.

There are two ways to create UDP sockets:

1. **`udp.bind(address)`**: creates a "server" socket that listens on a specific address and can receive packets from any peer. When sending, the destination address must be passed to `conn:sendto`.
2. **`udp.connect(address)`**: creates a "client" socket with a default destination address. Packets can be sent via `conn:sendto` without specifying an address each time.

Both return a `silly.net.udp.conn` object; all send/receive/close operations are methods on that object.

---

## UDP vs TCP

**UDP Features:**
- **Connectionless**: no handshake, packets sent directly
- **Unreliable**: packets may be lost, duplicated, or arrive out of order
- **Lightweight**: low protocol overhead, low latency
- **Message-oriented**: preserves message boundaries

**Use Cases:**
- Real-time games (position sync, state updates)
- DNS queries
- Audio/video streaming (tolerates packet loss)
- LAN service discovery
- Log collection (tolerates loss)

**Not Suitable For:**
- File transfers (requires reliability)
- HTTP/HTTPS (requires ordering guarantees)
- Database connections (requires transactions)

---

## Complete Example: Echo Server

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- Create a server socket bound to an address.
local server, err = udp.bind("127.0.0.1:9989")
assert(server, err)

-- Handle incoming packets.
wg:fork(function()
    local data, addr = server:recvfrom()
    if not data then
        print("Server recv error:", addr)  -- on error, second return is silly.errno
        return
    end
    print("Server received '"..data.."' from", addr)

    -- Echo back to the original sender.
    server:sendto(data, addr)
end)

-- Fork a client coroutine
wg:fork(function()
    time.sleep(100)

    -- Create a client socket with a default destination.
    local client, cerr = udp.connect("127.0.0.1:9989")
    assert(client, cerr)

    -- No explicit addr needed for a connected socket.
    local msg = "Hello, UDP!"
    client:sendto(msg)

    local data, addr = client:recvfrom()
    if data then
        print("Client received '"..data.."' from", addr)
        assert(data == msg)
    end

    client:close()
end)

wg:wait()
server:close()
```

---

## API Reference

### Socket creation

#### `udp.bind(address)`

Creates a UDP socket bound to a local address. Typically used for servers.

- **Parameters**:
  - `address` (`string`): address to bind, format `"IP:PORT"`
    - IPv4: `"127.0.0.1:8080"` or `":8080"` (all interfaces)
    - IPv6: `"[::1]:8080"` or `"[::]:8080"` (all interfaces)
- **Returns**:
  - Success: `silly.net.udp.conn`
  - Failure: `nil, silly.errno` - see [silly.errno](../errno.md)

```lua validate
local udp = require "silly.net.udp"

local sock, err = udp.bind("127.0.0.1:8989")
if not sock then
    print("Bind failed:", err)
else
    print("Bound to port 8989")
end
```

#### `udp.connect(address [, opts])`

Creates a UDP socket and sets a default destination address for outbound packets. Typically used for clients.

- **Parameters**:
  - `address` (`string`): default destination, e.g. `"127.0.0.1:8080"`
  - `opts` (`table|nil`, optional):
    - `bindaddr` (`string|nil`): local address to bind the client socket to
- **Returns**:
  - Success: `silly.net.udp.conn`
  - Failure: `nil, silly.errno`
- **Note**: a "connected" UDP socket is still connectionless — `connect` simply records a default destination.

```lua validate
local udp = require "silly.net.udp"

local sock, err = udp.connect("127.0.0.1:8989")
if not sock then
    print("Connect failed:", err)
else
    print("Connected to server")
end
```

### Sending and receiving

#### `conn:sendto(data [, address])`

Sends a datagram.

- **Parameters**:
  - `data` (`string | string[]`): payload to send; an array of strings is concatenated (zero-copy)
  - `address` (`string|nil`): destination
    - For sockets created with `udp.bind`: **required**
    - For sockets created with `udp.connect`: optional (default address is used if omitted)
- **Returns**:
  - Success: `true`
  - Failure: `false, silly.errno`
- **Does NOT yield.**

```lua validate
local udp = require "silly.net.udp"

-- bound socket: address is required
local server = udp.bind(":9001")
server:sendto("Hello", "127.0.0.1:8080")

-- connected socket: address is optional
local client = udp.connect("127.0.0.1:9001")
client:sendto("Hi there")

-- batched send
client:sendto({"Header: ", "Value\n", "Body"})
```

#### `conn:recvfrom([timeout])`

Asynchronously waits for and receives a single datagram.

- **Parameters**:
  - `timeout` (`integer|nil`): per-call timeout in milliseconds
- **Returns**:
  - Success: `data, address`
    - `data` (`string`): payload
    - `address` (`string`): sender's address, format `"IP:PORT"`
  - Failure: `nil, silly.errno` - e.g. `errno.TIMEDOUT` when `timeout` fires, `errno.CLOSED` on a closed socket
- **Async**: suspends the coroutine until a datagram arrives, the timeout fires, or the socket closes.

```lua validate
local silly = require "silly"
local task = require "silly.task"
local udp = require "silly.net.udp"

local sock = udp.bind(":9002")

task.fork(function()
    while true do
        local data, addr = sock:recvfrom()
        if not data then
            print("Recv error:", addr)  -- the second return holds the errno on error
            break
        end
        print("Received", #data, "bytes from", addr)
        sock:sendto(data, addr)
    end
end)
```

### Management

#### `conn:close()`

Closes a UDP socket.

- **Returns**: `true` on success, `false, silly.errno` if already closed.
- **Note**: closing wakes all coroutines currently blocked in `recvfrom` with an error.

#### `conn:isalive()`

Returns `true` while the socket is open and has not recorded an error.

#### `conn:unsentbytes()`

Returns the number of bytes held in the kernel send buffer that have not yet been transmitted. Useful for monitoring backpressure.

#### `conn:unreadbytes()`

Returns the total bytes of datagrams queued locally that have not yet been consumed via `recvfrom`.

#### `conn.fd`

Read-only integer file descriptor. Set to `nil` after `close`.

---

## Usage Examples

### Example 1: Simple UDP server

```lua validate
local silly = require "silly"
local task = require "silly.task"
local udp = require "silly.net.udp"

local sock = udp.bind(":8989")
print("UDP server listening on port 8989")

task.fork(function()
    while true do
        local data, addr = sock:recvfrom()
        if not data then
            print("Server error:", addr)
            break
        end
        print("From", addr, ":", data)
        sock:sendto("ACK: " .. data, addr)
    end
    sock:close()
end)
```

### Example 2: UDP client with timeout

```lua validate
local silly = require "silly"
local task = require "silly.task"
local udp = require "silly.net.udp"
local errno = require "silly.errno"

local sock, err = udp.connect("127.0.0.1:8989")
if not sock then
    print("Connect error:", err)
    return
end

task.fork(function()
    for i = 1, 5 do
        local msg = "Message " .. i
        sock:sendto(msg)

        local data, e = sock:recvfrom(500)  -- 500 ms timeout
        if not data then
            if e == errno.TIMEDOUT then
                print("No response for message", i, "(timeout)")
            else
                print("Recv error:", e)
                break
            end
        else
            print("Received:", data)
        end
    end
    sock:close()
end)
```

### Example 3: Broadcast

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- Receiver 1
wg:fork(function()
    local sock = udp.bind("127.0.0.1:9001")
    local data, addr = sock:recvfrom()
    print("Receiver 1 got:", data, "from", addr)
    sock:close()
end)

-- Receiver 2
wg:fork(function()
    local sock = udp.bind("127.0.0.1:9002")
    local data, addr = sock:recvfrom()
    print("Receiver 2 got:", data, "from", addr)
    sock:close()
end)

-- Sender (broadcast to multiple receivers)
wg:fork(function()
    local sock = udp.bind(":0")  -- bind to an ephemeral port
    local msg = "Broadcast message"

    sock:sendto(msg, "127.0.0.1:9001")
    sock:sendto(msg, "127.0.0.1:9002")

    print("Broadcast sent to 2 receivers")
    sock:close()
end)

wg:wait()
```

---

## Considerations

### 1. Packet size limits

UDP payloads are subject to the network path's MTU (typically 1500 bytes over Ethernet). A safe upper bound is 1472 bytes (1500 − 20 IP − 8 UDP). Larger datagrams trigger IP fragmentation and increase loss probability.

### 2. Loss and reordering

UDP does not guarantee ordering or arrival. If your protocol cares, add sequence numbers, retransmit, and apply the reliability logic in user space.

### 3. Address format

Always use `"IP:PORT"` with an explicit IP:

```lua validate
local udp = require "silly.net.udp"

local ok1 = udp.bind("127.0.0.1:8080")  -- IPv4
local ok2 = udp.bind("[::1]:8081")      -- IPv6
local ok3 = udp.bind(":8082")           -- all interfaces (IPv4)

-- These will fail:
-- udp.bind("localhost:8080")  -- needs IP literal
-- udp.bind("8080")            -- missing colon
```

### 4. Resource cleanup

Always close sockets when done. The conn object also has a GC finalizer as a safety net, but relying on it delays release.

---

## See Also

- [silly.net.tcp](./tcp.md) - TCP protocol
- [silly.net.websocket](./websocket.md) - WebSocket protocol
- [silly.net.dns](./dns.md) - DNS resolution
- [silly.errno](../errno.md) - Transport-layer error codes
- [silly.sync.waitgroup](../sync/waitgroup.md) - Coroutine wait group
