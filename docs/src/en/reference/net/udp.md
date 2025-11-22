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

Unlike TCP, UDP does not establish persistent connections. Each packet is sent independently. The main read function `udp.recvfrom` is asynchronous—it suspends the current coroutine until a datagram is received and returns both the data and the sender's address.

There are two main ways to create UDP sockets:
1.  **`udp.bind(address)`**: Creates a "server" socket that listens on a specific address and can receive packets from any source. When sending responses, you must specify the destination address in `udp.sendto`.
2.  **`udp.connect(address)`**: Creates a "client" socket that has a default destination address. You can send packets using `udp.sendto` without specifying the address each time.

---

## UDP vs TCP

**UDP Features:**
- **Connectionless**: No handshake, packets sent directly
- **Unreliable**: Packets may be lost, duplicated, or arrive out of order
- **Lightweight**: Low protocol overhead, low latency
- **Message-oriented**: Preserves message boundaries

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

This example demonstrates a simple UDP echo server and a client that sends messages and receives echoes. It showcases both socket types.

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- 1. Create a server socket bound to an address.
local server_fd, err = udp.bind("127.0.0.1:9989")
assert(server_fd, err)

-- 2. Fork a coroutine to handle incoming packets.
wg:fork(function()
    -- 5. Wait for a packet from any source.
    local data, addr = udp.recvfrom(server_fd)
    if not data then
        print("Server recv error:", addr)
        return
    end
    print("Server received '"..data.."' from", addr)

    -- 6. Echo the data back to the original sender.
    udp.sendto(server_fd, data, addr)
end)

-- Fork client coroutine
wg:fork(function()
    -- Give the server a moment to start up.
    time.sleep(100)

    -- 3. Create a client socket connected to the server.
    local client_fd, cerr = udp.connect("127.0.0.1:9989")
    assert(client_fd, cerr)

    -- 4. Send a message. Because the socket is "connected", sendto doesn't need an address.
    local msg = "Hello, UDP!"
    print("Client sending '"..msg.."'")
    udp.sendto(client_fd, msg)

    -- 7. Wait for the echo.
    local data, addr = udp.recvfrom(client_fd)
    if data then
        print("Client received '"..data.."' from", addr)
        assert(data == msg)
    end

    -- 8. Clean up client.
    udp.close(client_fd)
end)

wg:wait() -- Wait for both server and client coroutines to complete
udp.close(server_fd) -- Clean up server
```

---

## API Reference

### Socket Creation

#### `udp.bind(address)`
Creates a UDP socket and binds it to a local address. Typically used for servers.

- **Parameters**:
  - `address` (`string`): Address to bind to, format: `"IP:PORT"`
    - IPv4: `"127.0.0.1:8080"` or `":8080"` (listen on all interfaces)
    - IPv6: `"[::1]:8080"` or `"[::]:8080"` (listen on all interfaces)
- **Returns**: File descriptor (`fd`) on success, `nil, error` on failure
- **Example**:
```lua validate
local udp = require "silly.net.udp"

local fd, err = udp.bind("127.0.0.1:8989")
if not fd then
    print("Bind failed:", err)
else
    print("Bound to port 8989, fd:", fd)
end
```

#### `udp.connect(address, [bind_address])`
Creates a UDP socket and sets a default destination address for outbound packets. Typically used for clients.

- **Parameters**:
  - `address` (`string`): Default destination address, e.g. `"127.0.0.1:8080"`
  - `bind_address` (`string`, optional): Local address to bind the client socket to
- **Returns**: File descriptor (`fd`) on success, `nil, error` on failure
- **Note**: A "connected" UDP socket is still connectionless, it just sets a default destination address
- **Example**:
```lua validate
local udp = require "silly.net.udp"

local fd, err = udp.connect("127.0.0.1:8989")
if not fd then
    print("Connect failed:", err)
else
    print("Connected to server, fd:", fd)
end
```

### Sending and Receiving

#### `udp.sendto(fd, data, [address])`
Sends a datagram.

- **Parameters**:
  - `fd` (`integer`): File descriptor of the UDP socket
  - `data` (`string | table`): Packet content to send
    - `string`: Send string directly
    - `table`: Array of string fragments, automatically concatenated
  - `address` (`string`, optional): Destination address
    - For sockets created with `bind`: **Required**
    - For sockets created with `connect`: Optional (uses default address if omitted)
- **Returns**: `true` on success, `false, error` on failure
- **Example**:
```lua validate
local udp = require "silly.net.udp"

-- bind socket needs to specify address
local server_fd = udp.bind(":9001")
udp.sendto(server_fd, "Hello", "127.0.0.1:8080")

-- connect socket can omit address
local client_fd = udp.connect("127.0.0.1:9001")
udp.sendto(client_fd, "Hi there")

-- Send multiple fragments
udp.sendto(client_fd, {"Header: ", "Value\n", "Body"})
```

#### `udp.recvfrom(fd)`
Asynchronously waits for and receives a single datagram.

- **Parameters**:
  - `fd` (`integer`): File descriptor
- **Returns**:
  - Success: `data, address`
    - `data` (`string`): Packet content
    - `address` (`string`): Sender's address (format: `"IP:PORT"`)
  - Failure: `nil, error`
- **Note**: This is an asynchronous function, suspends the current coroutine until data arrives
- **Example**:
```lua validate
local silly = require "silly"
local task = require "silly.task"
local udp = require "silly.net.udp"

local fd = udp.bind(":9002")

task.fork(function()
    while true do
        local data, addr = udp.recvfrom(fd)
        if not data then
            print("Recv error:", addr)
            break
        end
        print("Received", #data, "bytes from", addr)
        -- Echo the data
        udp.sendto(fd, data, addr)
    end
end)
```

### Management

#### `udp.close(fd)`
Closes a UDP socket.

- **Parameters**:
  - `fd` (`integer`): File descriptor of the socket to close
- **Returns**: `true` on success, `false, error` if socket already closed
- **Note**: Closing a socket wakes all coroutines waiting on `recvfrom` with an error
- **Example**:
```lua validate
local udp = require "silly.net.udp"

local fd = udp.bind(":9003")
local ok, err = udp.close(fd)
if not ok then
    print("Close failed:", err)
end
```

#### `udp.sendsize(fd)`
Gets the amount of data currently held in the send buffer.

- **Parameters**:
  - `fd` (`integer`): File descriptor
- **Returns**: `integer` - Number of bytes in send buffer
- **Usage**: Monitor network congestion, implement flow control
- **Example**:
```lua validate
local udp = require "silly.net.udp"

local fd = udp.connect("127.0.0.1:9004")
udp.sendto(fd, "data")
local pending = udp.sendsize(fd)
print("Pending bytes:", pending)
```

#### `udp.isalive(fd)`
Checks if a socket is still considered alive.

- **Parameters**:
  - `fd` (`integer`): File descriptor
- **Returns**: `boolean` - `true` if socket is open and hasn't encountered errors, `false` otherwise
- **Example**:
```lua validate
local udp = require "silly.net.udp"

local fd = udp.bind(":9005")
print("Socket alive:", udp.isalive(fd))
udp.close(fd)
print("Socket alive:", udp.isalive(fd))
```

---

## Usage Examples

### Example 1: Simple UDP Server

```lua validate
local silly = require "silly"
local task = require "silly.task"
local udp = require "silly.net.udp"

local fd = udp.bind(":8989")
print("UDP server listening on port 8989")

task.fork(function()
    while true do
        local data, addr = udp.recvfrom(fd)
        if not data then
            print("Server error:", addr)
            break
        end
        print("From", addr, ":", data)
        udp.sendto(fd, "ACK: " .. data, addr)
    end
    udp.close(fd)
end)
```

### Example 2: UDP Client

```lua validate
local silly = require "silly"
local task = require "silly.task"
local udp = require "silly.net.udp"
local time = require "silly.time"

local fd, err = udp.connect("127.0.0.1:8989")
if not fd then
    print("Connect error:", err)
    return
end

task.fork(function()
    -- Send multiple messages
    for i = 1, 5 do
        local msg = "Message " .. i
        udp.sendto(fd, msg)
        print("Sent:", msg)
        local data, addr = udp.recvfrom(fd)
        if not data then
            print("No response for message", i)
        end
        time.sleep(500) -- Message interval
    end
    udp.close(fd)
end)
```

### Example 3: Broadcast Messages

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- Receiver 1
wg:fork(function()
    local fd = udp.bind("127.0.0.1:9001")
    local data, addr = udp.recvfrom(fd)
    print("Receiver 1 got:", data, "from", addr)
    udp.close(fd)
end)

-- Receiver 2
wg:fork(function()
    local fd = udp.bind("127.0.0.1:9002")
    local data, addr = udp.recvfrom(fd)
    print("Receiver 2 got:", data, "from", addr)
    udp.close(fd)
end)

-- Sender (broadcast to multiple receivers)
wg:fork(function()
    local fd = udp.bind(":0") -- Bind to any port
    local msg = "Broadcast message"

    udp.sendto(fd, msg, "127.0.0.1:9001")
    udp.sendto(fd, msg, "127.0.0.1:9002")

    print("Broadcast sent to 2 receivers")
    udp.close(fd)
end)

wg:wait()
```

### Example 4: Heartbeat Detection

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- Heartbeat server
wg:fork(function()
    local fd = udp.bind(":9010")
    for i = 1, 3 do
        local data, addr = udp.recvfrom(fd)
        if data then
            print("Heartbeat received from", addr)
            udp.sendto(fd, "PONG", addr)
        end
    end
    udp.close(fd)
end)

-- Heartbeat client
wg:fork(function()
    time.sleep(50) -- Wait for server to start

    local fd = udp.connect("127.0.0.1:9010")
    for i = 1, 3 do
        udp.sendto(fd, "PING")
        print("Sent PING", i)

        local data, addr = udp.recvfrom(fd)
        if data then
            print("Got", data, "from", addr)
        end

        time.sleep(200)
    end
    udp.close(fd)
end)

wg:wait()
```

---

## Considerations

### 1. Packet Size Limits

UDP packets are subject to MTU (Maximum Transmission Unit) limits:
- **Ethernet MTU**: Typically 1500 bytes
- **Safe size**: Recommended not to exceed 1472 bytes (1500 - 20 IP header - 8 UDP header)
- **Exceeding MTU**: Causes IP fragmentation, increases packet loss risk

```lua validate
local udp = require "silly.net.udp"

local fd = udp.bind(":9020")

-- Good practice: small packets
udp.sendto(fd, string.rep("x", 1000), "127.0.0.1:9020")

-- Not recommended: large packets (may fragment)
udp.sendto(fd, string.rep("x", 10000), "127.0.0.1:9020")
```

### 2. Out-of-Order and Packet Loss

UDP does not guarantee packet ordering or arrival, application layer must handle:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local udp = require "silly.net.udp"

local fd = udp.bind(":9021")

task.fork(function()
    local sequence = {}
    for i = 1, 10 do
        local data, addr = udp.recvfrom(fd)
        if data then
            local seq = tonumber(data:match("SEQ:(%d+)"))
            sequence[#sequence + 1] = seq
        end
    end
    -- Check if arrived in order
    print("Received sequence:", table.concat(sequence, ","))
end)
```

### 3. Buffer Overflow

Rapid sending can lead to buffer full:

```lua validate
local udp = require "silly.net.udp"

local fd = udp.connect("127.0.0.1:9022")

for i = 1, 1000 do
    local ok, err = udp.sendto(fd, "data " .. i)
    if not ok then
        print("Send failed at", i, ":", err)
        print("Buffer size:", udp.sendsize(fd))
        break
    end
end
```

### 4. Address Format

Ensure correct address format:

```lua validate
local udp = require "silly.net.udp"

-- Correct formats
local fd1 = udp.bind("127.0.0.1:8080")  -- IPv4
local fd2 = udp.bind("[::1]:8081")      -- IPv6
local fd3 = udp.bind(":8082")           -- All interfaces (IPv4)

-- Wrong formats (will fail)
-- local fd4 = udp.bind("localhost:8080")  -- Needs IP address
-- local fd5 = udp.bind("8080")            -- Missing colon
```

### 5. Resource Cleanup

Always remember to close sockets:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local udp = require "silly.net.udp"

task.fork(function()
    local fd = udp.bind(":9030")
    -- ... use socket ...
    udp.close(fd)  -- Ensure cleanup
end)
```

---

## Performance Suggestions

### 1. Batch Sending

Reduce number of system calls:

```lua validate
local udp = require "silly.net.udp"

local fd = udp.connect("127.0.0.1:9040")

-- Send in batches using a table
udp.sendto(fd, {
    "header1\n",
    "header2\n",
    "body content"
})
```

### 2. Monitor Buffer

Avoid send buffer overflow:

```lua validate
local udp = require "silly.net.udp"

local fd = udp.connect("127.0.0.1:9041")

local function safe_send(data)
    local buffer_size = udp.sendsize(fd)
    if buffer_size > 1024 * 1024 then  -- 1MB threshold
        print("Warning: send buffer is", buffer_size, "bytes")
        return false
    end
    return udp.sendto(fd, data)
end
```

### 3. Reasonable Timeouts

Implement application-layer timeout mechanisms:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local udp = require "silly.net.udp"
local time = require "silly.time"

local function recv_with_timeout(fd, timeout_ms)
    local result = nil
    local task = task.fork(function()
        result = {udp.recvfrom(fd)}
    end)

    time.sleep(timeout_ms)

    if result then
        return table.unpack(result)
    else
        return nil, "timeout"
    end
end
```

---

## See Also

- [silly.net.tcp](./tcp.md) - TCP network protocol
- [silly.net.websocket](./websocket.md) - WebSocket protocol
- [silly.net.dns](./dns.md) - DNS resolution
- [silly.sync.waitgroup](../sync/waitgroup.md) - Coroutine wait group
