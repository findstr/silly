---
title: silly.net.cluster
icon: network-wired
category:
  - API Reference
tag:
  - Network
  - Cluster
  - RPC
  - Distributed
---

# silly.net.cluster

The `silly.net.cluster` module provides TCP-based inter-node communication for clusters, implementing a complete RPC (Remote Procedure Call) framework. This module supports request-response patterns, timeout control, connection management, and distributed tracing across nodes.

## Core Concepts

### Cluster Communication Model

The cluster module adopts a client-server model where each node can act as both a server accepting connections and a client initiating connections:

- **Server Role**: Listen on a port via `listen()` to accept connections from other nodes
- **Client Role**: Connect to other nodes via `connect()`
- **Bidirectional Communication**: Once connected, both sides can initiate RPC calls

### RPC Protocol

Cluster internally uses the `silly.net.cluster.c` module to implement a binary protocol:

- **Request Packet**: `[2-byte length][business data][traceid(8 bytes)][cmd(4 bytes)][session(4 bytes)]`
- **Response Packet**: `[2-byte length][business data][session(4 bytes)]`
- **Session Mechanism**: Uses session to automatically match requests and responses
- **Timeout Control**: Supports setting timeout for each request
- **Memory Management**: Buffers are automatically managed, no manual freeing required

### Serialization Mechanism

The cluster module is not bound to a specific serialization format and supports any encoding/decoding method through callback functions:

- **marshal**: Encode Lua data into binary
- **unmarshal**: Decode binary into Lua data
- Common choices: zproto, protobuf, msgpack, json, etc.

## API Reference

### cluster.serve(conf)

Configure the global behavior of the cluster module, setting encoding/decoding, timeout, and callback functions.

**Parameters:**

- `conf` (table) - Configuration table containing the following fields:
  - `marshal` (function) - **Required**, encoding function: `function(type, cmd, body) -> cmd_number, data`
    - `type`: "request" or "response"
    - `cmd`: Command identifier (string or number)
    - `body`: Lua data to encode
    - Returns: command number, data string (returning nil means no data is sent, e.g., no response)
  - `unmarshal` (function) - **Required**, decoding function: `function(type, cmd, data) -> body, err?`
    - `type`: "request" or "response"
    - `cmd`: Command identifier
    - `data`: Data string
    - Returns: Decoded Lua data, optional error message
  - `call` (function) - **Required**, RPC request handler: `function(peer, cmd, body) -> response`
    - `peer`: Peer object of the connection
    - `cmd`: Command identifier
    - `body`: Decoded request data
    - Returns: Response data (nil means no response needed)
  - `close` (function) - Optional, connection close callback: `function(peer, errno)`
    - **Only triggered when the remote peer closes the connection**, actively calling `cluster.close()` does not trigger this callback
    - `peer`: Peer object of the connection
    - `errno`: Error code
  - `accept` (function) - Optional, new connection callback: `function(peer, addr)`
    - `peer`: Peer object of the new connection
    - `addr`: Client address
  - `timeout` (number) - Optional, RPC timeout in milliseconds, default 5000

**Returns:**

- No return value

**Notes:**

- `cluster.serve()` must be called before using other cluster functions
- Peer objects contain `fd` and `addr` fields (peers from accept have no addr)
- Peers with addr support automatic reconnection

**Example:**

```lua validate
local silly = require "silly"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

-- Define protocol
local proto = zproto:parse [[
ping 0x01 {
    .msg:string 1
}
pong 0x02 {
    .msg:string 1
}
]]

-- Encoding function
local function marshal(typ, cmd, body)
    if typ == "response" then
        -- If body is nil, it means no response needs to be sent
        if not body then
            return nil
        end
        -- Convert ping to pong for responses
        if cmd == "ping" or cmd == 0x01 then
            cmd = "pong"
        end
    end

    if type(cmd) == "string" then
        cmd = proto:tag(cmd)
    end

    local dat, sz = proto:encode(cmd, body, true)
    local buf = proto:pack(dat, sz, false)
    return cmd, buf
end

-- Decoding function
local function unmarshal(typ, cmd, buf)
    if typ == "response" then
        if cmd == "ping" or cmd == 0x01 then
            cmd = "pong"
        end
    end

    local dat, sz = proto:unpack(buf, #buf, true)
    local body = proto:decode(cmd, dat, sz)
    return body
end

-- Configure server
cluster.serve {
    timeout = 3000,
    marshal = marshal,
    unmarshal = unmarshal,
    accept = function(peer, addr)
        print("New connection from:", addr)
    end,
    call = function(peer, cmd, body)
        print("Received request:", body.msg)
        return {msg = "Hello from server"}
    end,
    close = function(peer, errno)
        print("Connection closed, errno:", errno)
    end,
}

-- Start listening
local listener = cluster.listen("127.0.0.1:8888")
print("Server listening: 127.0.0.1:8888")

local silly = require "silly"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"
local task = require "silly.task"

-- ... (omitted intermediate code)

-- Create client and test
task.fork(function()
    local peer = cluster.connect("127.0.0.1:8888")

    local resp = cluster.call(peer, "ping", {msg = "Hello"})
    print("Received response:", resp and resp.msg or "nil")

    cluster.close(peer)
end)
```

---

### cluster.listen(addr, backlog)

Listen for TCP connections on the specified address.

**Parameters:**

- `addr` (string) - Listen address in format "ip:port"
- `backlog` (number) - Optional, listen queue length, default 128

**Returns:**

- `listener` (table|nil) - On success, returns listener object containing `fd` field
- `err` (string|nil) - On failure, returns error message

**Notes:**

- Listen is a synchronous operation, does not need to be called in a coroutine
- After successful listen, new connections will trigger the `accept` callback
- The listener object can be used with `cluster.close()` to close the listener

**Example:**

```lua validate
local silly = require "silly"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

local proto = zproto:parse [[
echo 0x01 {
    .text:string 1
}
]]

cluster.serve {
    marshal = function(typ, cmd, body)
        if typ == "response" and not body then
            return nil
        end
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf = proto:pack(dat, sz, false)
        return cmd, buf
    end,
    unmarshal = function(typ, cmd, buf)
        local dat, sz = proto:unpack(buf, #buf, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function(peer, addr)
        print(string.format("Accept connection from %s", addr))
    end,
    call = function(peer, cmd, body)
        return body
    end,
    close = function(peer, errno)
        print(string.format("Connection closed, errno: %d", errno))
    end,
}

-- Listen on multiple ports
local listener1 = cluster.listen("0.0.0.0:8888")
local listener2 = cluster.listen("0.0.0.0:8889", 256)

print("Listening on ports: 8888, 8889")
```

---

### cluster.connect(addr)

Generate a peer handle for the specified address, attempting to connect once on first call. This is an **asynchronous operation** and must be called in a coroutine.

**Parameters:**

- `addr` (string) - Server address in format "ip:port" or "domain:port"

**Returns:**

- `peer` (handle) - Peer handle (opaque structure)

**Notes:**

- Must be called in a coroutine created by `task.fork()`
- Supports domain name resolution (automatic DNS queries)
- Always returns a peer handle, even if the first connection fails
- The peer handle saves address information, `cluster.call()` will automatically reconnect when needed
- No need to check connection status, directly use `cluster.call()` or `cluster.send()`

**Example:**

```lua validate
local silly = require "silly"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

local proto = zproto:parse [[
request 0x01 {
    .data:string 1
}
]]

cluster.serve {
    marshal = function(typ, cmd, body)
        if typ == "response" and not body then
            return nil
        end
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf = proto:pack(dat, sz, false)
        return cmd, buf
    end,
    unmarshal = function(typ, cmd, buf)
        local dat, sz = proto:unpack(buf, #buf, true)
        return proto:decode(cmd, dat, sz)
    end,
    call = function() end,
    close = function() end,
}

local silly = require "silly"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"
local task = require "silly.task"

-- ... (omitted intermediate code)

task.fork(function()
    -- Generate peer handles
    local peer1 = cluster.connect("127.0.0.1:8888")
    local peer2 = cluster.connect("example.com:80")

    -- Use peer handle directly without checking connection status
    -- cluster.call() automatically handles reconnection
    local resp, err = cluster.call(peer1, "request", {data = "test"})
    if not resp then
        print("Call failed:", err)
    end

    cluster.close(peer1)
end)
```

---

### cluster.call(peer, cmd, obj)

Send an RPC request and wait for a response. This is an **asynchronous operation** and must be called in a coroutine.

**Parameters:**

- `peer` (table) - Peer object (obtained from `cluster.connect()` or accept callback)
- `cmd` (string|number) - Command identifier
- `obj` (any) - Request data (will be encoded via marshal)

**Returns:**

- `response` (any|nil) - On success, returns response data (decoded via unmarshal)
- `err` (string|nil) - On failure, returns error message ("closed", "timeout", etc.)

**Notes:**

- Must be called in a coroutine created by `task.fork()`
- On timeout, returns `nil, "timeout"`
- If connection is closed but peer has addr, will automatically reconnect
- If peer has no addr (from accept), returns `nil, "peer closed"` after disconnection
- Automatically handles session matching and timeout control

**Example:**

```lua validate
local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

local proto = zproto:parse [[
add 0x01 {
    .a:integer 1
    .b:integer 2
}
sum 0x02 {
    .result:integer 1
}
]]

-- Server side
cluster.serve {
    timeout = 2000,
    marshal = function(typ, cmd, body)
        if typ == "response" then
            if not body then
                return nil
            end
            if cmd == "add" then
                cmd = "sum"
            end
        end
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf = proto:pack(dat, sz, false)
        return cmd, buf
    end,
    unmarshal = function(typ, cmd, buf)
        if typ == "response" and cmd == "add" then
            cmd = "sum"
        end
        local dat, sz = proto:unpack(buf, #buf, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function() end,
    call = function(peer, cmd, body)
        -- Calculate addition
        return {result = body.a + body.b}
    end,
    close = function() end,
}

cluster.listen("127.0.0.1:9999")

local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"
local task = require "silly.task"

-- ... (omitted intermediate code)

-- Client test
task.fork(function()
    time.sleep(100)
    local peer = cluster.connect("127.0.0.1:9999")

    -- Send request and wait for response
    local resp, err = cluster.call(peer, "add", {a = 10, b = 20})
    if resp then
        print("Calculation result:", resp.result)  -- Output: 30
    else
        print("Call failed:", err)
    end

    cluster.close(peer)
end)
```

---

### cluster.send(peer, cmd, obj)

Send a one-way message without waiting for a response. This is an **asynchronous operation** and must be called in a coroutine.

**Parameters:**

- `peer` (table) - Peer object
- `cmd` (string|number) - Command identifier
- `obj` (any) - Message data

**Returns:**

- `ok` (boolean|nil) - On success, returns true
- `err` (string|nil) - On failure, returns error message

**Notes:**

- Must be called in a coroutine created by `task.fork()`
- Unlike `call`, send does not wait for a response
- Suitable for notifications, log pushing, and other scenarios that don't require responses
- If connection is disconnected but peer has addr, will automatically reconnect

**Example:**

```lua validate
local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

local proto = zproto:parse [[
notify 0x10 {
    .message:string 1
}
]]

-- Server receives notifications
cluster.serve {
    marshal = function(typ, cmd, body)
        if typ == "response" and not body then
            return nil
        end
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf = proto:pack(dat, sz, false)
        return cmd, buf
    end,
    unmarshal = function(typ, cmd, buf)
        local dat, sz = proto:unpack(buf, #buf, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function() end,
    call = function(peer, cmd, body)
        print("Received notification:", body.message)
        -- One-way message does not return response
        return nil
    end,
    close = function() end,
}

cluster.listen("127.0.0.1:7777")

local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"
local task = require "silly.task"

-- ... (omitted intermediate code)

-- Client sends notifications
task.fork(function()
    time.sleep(100)
    local peer = cluster.connect("127.0.0.1:7777")

    -- Send multiple notifications
    for i = 1, 5 do
        local ok, err = cluster.send(peer, "notify", {
            message = "Notification #" .. i
        })
        if not ok then
            print("Send failed:", err)
            break
        end
        time.sleep(100)
    end

    cluster.close(peer)
end)
```

---

### cluster.close(peer)

Close a connection or listener.

**Parameters:**

- `peer` (table) - Peer object or listener object

**Returns:**

- No return value

**Notes:**

- Can close client connections, accepted connections, or listeners
- Actively closed connections **do not** trigger the `close` callback and **do not** automatically reconnect
- Peer handles should not be used after closing

**Example:**

```lua validate
local silly = require "silly"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

local proto = zproto:parse [[
test 0x01 {
    .x:integer 1
}
]]

cluster.serve {
    marshal = function(typ, cmd, body)
        if typ == "response" and not body then
            return nil
        end
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf = proto:pack(dat, sz, false)
        return cmd, buf
    end,
    unmarshal = function(typ, cmd, buf)
        local dat, sz = proto:unpack(buf, #buf, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function() end,
    call = function() end,
    close = function(peer, errno)
        print("Connection closed, errno:", errno)
    end,
}

local silly = require "silly"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"
local task = require "silly.task"

-- ... (omitted intermediate code)

local listener = cluster.listen("127.0.0.1:6666")

task.fork(function()
    local peer = cluster.connect("127.0.0.1:6666")

    -- Actively close connection
    cluster.close(peer)
    print("Peer closed")

    -- Close listener
    cluster.close(listener)
end)
```

---

## Complete Examples

### Simple RPC Service

```lua validate
local silly = require "silly"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

local proto = zproto:parse [[
ping 0x01 {
    .msg:string 1
}
pong 0x02 {
    .msg:string 1
}
]]

local function marshal(typ, cmd, body)
    if typ == "response" then
        if not body then
            return nil
        end
        if cmd == "ping" or cmd == 0x01 then
            cmd = "pong"
        end
    end
    if type(cmd) == "string" then
        cmd = proto:tag(cmd)
    end
    local dat, sz = proto:encode(cmd, body, true)
    return cmd, proto:pack(dat, sz, false)
end

local function unmarshal(typ, cmd, buf)
    if typ == "response" and (cmd == "ping" or cmd == 0x01) then
        cmd = "pong"
    end
    local dat, sz = proto:unpack(buf, #buf, true)
    return proto:decode(cmd, dat, sz)
end

cluster.serve {
    marshal = marshal,
    unmarshal = unmarshal,
    accept = function(peer, addr)
        print("New connection from:", addr)
    end,
    call = function(peer, cmd, body)
        print("Received:", body.msg)
        return {msg = "pong from server"}
    end,
    close = function(peer, errno)
        print("Connection closed, errno:", errno)
    end,
}

local silly = require "silly"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"
local task = require "silly.task"

-- ... (omitted intermediate code)

cluster.listen("127.0.0.1:8888")

task.fork(function()
    local peer = cluster.connect("127.0.0.1:8888")
    local resp = cluster.call(peer, "ping", {msg = "ping"})
    print("Response:", resp.msg)
    cluster.close(peer)
end)
```

---

### Multi-Node Cluster Communication

```lua validate
local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

-- Define cluster protocol
local proto = zproto:parse [[
register 0x01 {
    .node_id:string 1
    .addr:string 2
}
heartbeat 0x02 {
    .timestamp:integer 1
}
forward 0x03 {
    .target:string 1
    .data:string 2
}
]]

local function marshal(typ, cmd, body)
    if typ == "response" and not body then
        return nil
    end
    if type(cmd) == "string" then
        cmd = proto:tag(cmd)
    end
    local dat, sz = proto:encode(cmd, body, true)
    return cmd, proto:pack(dat, sz, false)
end

local function unmarshal(typ, cmd, buf)
    local dat, sz = proto:unpack(buf, #buf, true)
    return proto:decode(cmd, dat, sz)
end

-- Node information
local nodes = {}

-- Create node server
local function create_node(node_id, port)
    cluster.serve {
        timeout = 5000,
        marshal = marshal,
        unmarshal = unmarshal,
        accept = function(peer, addr)
            print(string.format("[%s] Accept connection: %s", node_id, addr))
            nodes[addr] = peer
        end,
        call = function(peer, cmd, body)
            if cmd == 0x01 then  -- register
                print(string.format("[%s] Node registered: %s @ %s",
                    node_id, body.node_id, body.addr))
                return {status = "ok"}
            elseif cmd == 0x02 then  -- heartbeat
                return {timestamp = os.time()}
            elseif cmd == 0x03 then  -- forward
                print(string.format("[%s] Forward message to %s: %s",
                    node_id, body.target, body.data))
                return {result = "forwarded"}
            end
        end,
        close = function(peer, errno)
            print(string.format("[%s] Node disconnected", node_id))
        end,
    }

    local listener = cluster.listen("127.0.0.1:" .. port)
    print(string.format("[%s] Listening on port: %d", node_id, port))
    return listener
end

-- Create three nodes
local node1 = create_node("node1", 10001)
local node2 = create_node("node2", 10002)
local node3 = create_node("node3", 10003)

local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"
local task = require "silly.task"

-- ... (omitted intermediate code)

-- Node interconnection
task.fork(function()
    time.sleep(100)

    -- node2 connects to node1
    local peer2 = cluster.connect("127.0.0.1:10001")
    local resp = cluster.call(peer2, "register", {
        node_id = "node2",
        addr = "127.0.0.1:10002"
    })
    print("Registration response:", resp and resp.status or "nil")

    -- Send heartbeat
    time.sleep(500)
    local hb = cluster.call(peer2, "heartbeat", {
        timestamp = os.time()
    })
    print("Heartbeat response:", hb and hb.timestamp or "nil")

    -- node3 connects to node1
    local peer3 = cluster.connect("127.0.0.1:10001")
    cluster.call(peer3, "register", {
        node_id = "node3",
        addr = "127.0.0.1:10003"
    })

    -- Forward message via node1
    local fwd = cluster.call(peer3, "forward", {
        target = "node2",
        data = "Hello from node3"
    })
    print("Forward result:", fwd and fwd.result or "nil")
end)
```

---

### Broadcast Message to All Nodes

```lua validate
local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

local proto = zproto:parse [[
broadcast 0x20 {
    .message:string 1
}
ack 0x21 {
    .node_id:string 1
}
]]

-- Configure broadcast server
cluster.serve {
    timeout = 1000,
    marshal = function(typ, cmd, body)
        if typ == "response" then
            if not body then
                return nil
            end
            if cmd == "broadcast" then
                cmd = "ack"
            end
        end
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf = proto:pack(dat, sz, false)
        return cmd, buf
    end,
    unmarshal = function(typ, cmd, buf)
        if typ == "response" and cmd == "broadcast" then
            cmd = "ack"
        end
        local dat, sz = proto:unpack(buf, #buf, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function() end,
    call = function(peer, cmd, body)
        print("Received broadcast:", body.message)
        return {node_id = "node_" .. os.time()}  -- Use other identifier
    end,
    close = function() end,
}

-- Start 3 receiver nodes
local listeners = {}
local ports = {8001, 8002, 8003}
for _, port in ipairs(ports) do
    local listener = cluster.listen("127.0.0.1:" .. port)
    table.insert(listeners, listener)
end

-- Broadcast client
local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"
local task = require "silly.task"

-- ... (omitted intermediate code)

-- Broadcast client
task.fork(function()
    time.sleep(200)

    -- Connect to all nodes
    local peers = {}
    for _, port in ipairs(ports) do
        local peer = cluster.connect("127.0.0.1:" .. port)
        table.insert(peers, peer)
    end

    -- Concurrent broadcast to all nodes
    local message = "Important notice: System will be under maintenance in 10 minutes"
    local acks = {}

    for _, peer in ipairs(peers) do
        task.fork(function()
            local resp = cluster.call(peer, "broadcast", {
                message = message
            })
            if resp then
                table.insert(acks, resp.node_id)
                print("Received ack:", resp.node_id)
            end
        end)
    end

    -- Wait for all responses
    time.sleep(500)
    print("Broadcast complete, ack count:", #acks)

    -- Clean up connections
    for _, peer in ipairs(peers) do
        cluster.close(peer)
    end
end)
```

---

### Load Balanced Calls

```lua validate
local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

local proto = zproto:parse [[
work 0x30 {
    .task_id:integer 1
    .data:string 2
}
result 0x31 {
    .task_id:integer 1
    .output:string 2
}
]]

-- Configure cluster service
cluster.serve {
    timeout = 3000,
    marshal = function(typ, cmd, body)
        if typ == "response" then
            if not body then
                return nil
            end
            if cmd == "work" then
                cmd = "result"
            end
        end
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf = proto:pack(dat, sz, false)
        return cmd, buf
    end,
    unmarshal = function(typ, cmd, buf)
        if typ == "response" and cmd == "work" then
            cmd = "result"
        end
        local dat, sz = proto:unpack(buf, #buf, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function() end,
    call = function(peer, cmd, body)
        -- Simulate work processing (use task_id to distinguish tasks)
        local worker_id = (body.task_id % 3) + 1
        print(string.format("[Worker %d] Processing task #%d: %s",
            worker_id, body.task_id, body.data))
        time.sleep(100 + math.random(200))
        return {
            task_id = body.task_id,
            output = string.format("Worker %d completed", worker_id)
        }
    end,
    close = function() end,
}

-- Start 3 worker nodes
local listeners = {}
local ports = {9001, 9002, 9003}
for _, port in ipairs(ports) do
    local listener = cluster.listen("127.0.0.1:" .. port)
    table.insert(listeners, listener)
end

-- Load balancer client
local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"
local task = require "silly.task"

-- ... (omitted intermediate code)

-- Load balancer client
task.fork(function()
    time.sleep(200)

    -- Connect to all worker nodes
    local worker_peers = {}
    for _, port in ipairs(ports) do
        local peer = cluster.connect("127.0.0.1:" .. port)
        table.insert(worker_peers, peer)
    end

    -- Round-robin task distribution
    local current = 1
    for task_id = 1, 10 do
        local peer = worker_peers[current]

        task.fork(function()
            local resp = cluster.call(peer, "work", {
                task_id = task_id,
                data = "Task data " .. task_id
            })
            if resp then
                print(string.format("Task #%d result: %s",
                    resp.task_id, resp.output))
            end
        end)

        -- Round-robin to next worker node
        current = (current % #worker_peers) + 1
        time.sleep(50)
    end
end)
```

---

## Notes

### Coroutine Requirements

All asynchronous operations (`connect`, `call`, `send`) must be called in coroutines created by `task.fork()`:

```lua
-- ❌ Wrong: Direct call will error
local peer = cluster.connect("127.0.0.1:8888")

-- ✅ Correct: Call in coroutine
task.fork(function()
    local peer = cluster.connect("127.0.0.1:8888")
end)
```

### Peer Handles and Auto-Reconnection

- **Peer handles from connect**: Support auto-reconnection
  - Peer handles save address information
  - When **remote peer closes connection**, next `call()` or `send()` will automatically reconnect
  - **Connections closed by actively calling `cluster.close()` do not auto-reconnect**
  - Address caching mechanism prevents duplicate connections to the same address

- **Peer handles from accept callback**: Do not support auto-reconnection
  - Inbound connection peer handles do not save address information
  - After disconnection, cannot auto-reconnect, will return `nil, "peer closed"`

- **Listener handles**: Used for listening on ports
  - Can be closed via `cluster.close()`

### Timeout Control

- Default timeout 5000 milliseconds (5 seconds)
- On timeout, returns `nil, "timeout"`
- Timed-out requests are cleaned up, delayed responses are ignored

### Serialization Notes

- `marshal` returns `(cmd_number, data)`:
  - First return value must be numeric command ID
  - Second return value is encoded string data
  - No need to return size, length is automatically obtained from string

- `unmarshal` receives string parameter:
  - Parameter `buf` is a Lua string, can directly use `#buf` to get length
  - No manual memory management needed, buffer is automatically converted to string
  - Returns decoded Lua table and optional error message

### Distributed Tracing

Cluster automatically propagates trace IDs:

```lua
-- Client initiates request, automatically carries current trace ID using trace.propagate()
local resp = cluster.call(peer, "ping", data)

-- Server processes, trace ID is automatically set by cluster
call = function(peer, cmd, body)
    -- logger automatically uses current trace ID for logging
    -- Enables distributed tracing across services
    logger.info("Processing request:", cmd)
end
```

### Performance Recommendations

1. **Connection Reuse**: Establish long connections, avoid frequent connection/disconnection
2. **Batch Operations**: Use `task.fork()` to send multiple concurrent requests
3. **Reasonable Timeouts**: Set appropriate timeout based on business needs
4. **Serialization Choice**: Prioritize binary protocols (zproto, protobuf)
5. **Connection Pool**: For high-concurrency scenarios, maintain a connection pool

### Error Handling

```lua
task.fork(function()
    -- cluster.connect always returns peer handle
    local peer = cluster.connect(addr)

    -- Error handling is done in call/send
    local resp, err = cluster.call(peer, cmd, data)
    if not resp then
        -- Call failed
        if err == "timeout" then
            -- Timeout handling
        elseif err == "peer closed" then
            -- Connection closed (inbound connections cannot reconnect)
        else
            -- Other errors (such as connection failure, DNS resolution failure, etc.)
            print("Call error:", err)
        end
        return
    end

    -- Process response...
end)
```

---

## Related Modules

- [silly.net.tcp](./tcp.md) - TCP low-level interface
- [silly.net.dns](./dns.md) - DNS resolution
- [silly.logger](../logger.md) - Logging
- [silly.time](../time.md) - Timers and delays
- [silly.sync.waitgroup](../sync/waitgroup.md) - Coroutine synchronization
