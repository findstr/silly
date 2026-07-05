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

- **Request Packet**: `[4-byte length][session(8 bytes)][traceid(8 bytes)][business data]`
- **Response Packet**: `[4-byte length][session(8 bytes)][business data]`
- **Session Mechanism**: Uses session to automatically match requests and responses
- **Timeout Control**: Supports setting timeout for each request
- **Memory Management**: Buffers are automatically managed, no manual freeing required

### Raw String Transport

The cluster module is a raw string transport — it does not perform any serialization or deserialization. The `call` callback receives raw string data and returns raw string responses. Users are responsible for encoding/decoding using any format they prefer (zproto, protobuf, msgpack, json, etc.) inside their callbacks.

## API Reference

### cluster.serve(conf)

Configure the global behavior of the cluster module, setting timeout and callback functions.

**Parameters:**

- `conf` (table) - Configuration table containing the following fields:
  - `call` (function) - **Required**, RPC request handler: `function(peer, data) -> response`
    - `peer`: Peer object of the connection
    - `data`: Raw string request data; dispatch (which procedure to run) is encoded by the caller inside this string — cluster is transport-only
    - Returns: Raw string response data (nil means no response needed)
  - `close` (function) - Optional, connection close callback: `function(peer, errno)`
    - **Only triggered when the remote peer closes the connection**, actively calling `cluster.close()` does not trigger this callback
    - `peer`: Peer object of the connection
    - `errno`: Error code
  - `accept` (function) - Optional, new connection callback: `function(peer)`
    - `peer`: Peer object of the new connection (contains `remoteaddr` field for client address)
  - `timeout` (number) - Optional, RPC timeout in milliseconds, default 5000
  - `hardlimit` (number) - Optional, max body size before error (default 128MB)
  - `softlimit` (number) - Optional, max body size before warning (default 65535)

**Returns:**

- No return value

**Notes:**

- `cluster.serve()` must be called before using other cluster functions
- Peer objects contain `fd` and `remoteaddr` fields

**Example:**

```lua validate
local silly = require "silly"
local cluster = require "silly.net.cluster"

cluster.serve {
    timeout = 3000,
    accept = function(peer)
        print("New connection from:", peer.remoteaddr)
    end,
    call = function(peer, data)
        return "pong:" .. data
    end,
    close = function(peer, errno)
        print("Connection closed, errno:", errno)
    end,
}

local listener = cluster.listen("127.0.0.1:8888")
print("Server listening: 127.0.0.1:8888")
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

---

### cluster.connect(addr)

Connect to a remote cluster node. Performs DNS lookup and TCP connect immediately (eager connect). This is an **asynchronous operation** and must be called in a coroutine.

**Parameters:**

- `addr` (string) - Server address in format `"ip:port"` or `"domain:port"`

**Returns:**

- `peer` (table|nil) - On success, returns peer handle with `fd` and `remoteaddr` fields
- `err` (string|nil) - On failure, returns error message

**Notes:**

- **Must be called from a coroutine** (e.g., inside `task.fork()`)
- Returns immediately with a connected peer, or `nil, err` on failure
- If the connection drops later, `call`/`send` returns `"Peer closed"` — there is no automatic reconnection
- To reconnect after a drop, call `cluster.connect()` again to get a new peer

**Example:**

```lua validate
local silly = require "silly"
local task = require "silly.task"
local cluster = require "silly.net.cluster"

task.fork(function()
    local peer, err = cluster.connect("127.0.0.1:8888")
    if not peer then
        print("Connect failed:", err)
        return
    end
    -- peer is ready to use immediately
    local resp, err = cluster.call(peer, "hello")
    if resp then
        print("Response:", resp)
    end
    cluster.close(peer)
end)
```

---

### cluster.call(peer, data)

Send an RPC request and wait for a response. This is an **asynchronous operation** and must be called in a coroutine.

**Parameters:**

- `peer` (table) - Peer object (obtained from `cluster.connect()` or accept callback)
- `data` (string) - Raw string request data; encode any dispatch key your server needs inside this string

**Returns:**

- `response` (string|nil) - On success, returns raw string response data
- `err` (string|nil) - On failure: error string (e.g. timeout, connection error)

**Notes:**

- Must be called in a coroutine created by `task.fork()`
- On timeout, returns `nil, errno.TIMEDOUT`
- If the peer's connection has dropped, returns `nil, "Peer closed"`
- Automatically handles session matching and timeout control

---

### cluster.send(peer, data)

Send a one-way message without waiting for a response. This is an **asynchronous operation** and must be called in a coroutine.

**Parameters:**

- `peer` (table) - Peer object
- `data` (string) - Raw string message data

**Returns:**

- `ok` (boolean|nil) - On success, returns true
- `err` (string|nil) - On failure, returns error message

**Notes:**

- Must be called in a coroutine created by `task.fork()`
- Unlike `call`, send does not wait for a response
- Suitable for notifications, log pushing, and other scenarios that don't require responses

---

### cluster.close(peer)

Close a connection or listener.

**Parameters:**

- `peer` (table) - Peer object or listener object

**Returns:**

- No return value

**Notes:**

- Can close client connections, accepted connections, or listeners
- Actively closed connections **do not** trigger the `close` callback
- Peer handles should not be used after closing

---

## Complete Example

### Simple RPC Service

```lua validate
local silly = require "silly"
local task = require "silly.task"
local cluster = require "silly.net.cluster"

cluster.serve {
    timeout = 3000,
    accept = function(peer)
        print("New connection from:", peer.remoteaddr)
    end,
    call = function(peer, data)
        return "pong:" .. data
    end,
    close = function(peer, errno)
        print("Connection closed, errno:", errno)
    end,
}

cluster.listen("127.0.0.1:8888")

task.fork(function()
    local peer, err = cluster.connect("127.0.0.1:8888")
    if not peer then
        print("Connect failed:", err)
        return
    end
    local resp = cluster.call(peer, "ping")
    print("Response:", resp)
    cluster.close(peer)
end)
```

### With Custom Serialization

Users can use any serialization library inside their `call` callback:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local cluster = require "silly.net.cluster"
local json = require "silly.encoding.json"

cluster.serve {
    timeout = 5000,
    call = function(peer, data)
        local req = json.decode(data)
        if req.action == "get_user" then
            local user = {id = req.id, name = "Alice"}
            return json.encode(user)
        elseif req.action == "set_user" then
            -- process the request
            return json.encode({ok = true})
        end
    end,
    accept = function() end,
    close = function() end,
}

cluster.listen("127.0.0.1:9000")

task.fork(function()
    local peer, err = cluster.connect("127.0.0.1:9000")
    if not peer then
        print("Connect failed:", err)
        return
    end
    local resp = cluster.call(peer, json.encode({action = "get_user", id = 42}))
    if resp then
        local user = json.decode(resp)
        print("User:", user.name)
    end
    cluster.close(peer)
end)
```

---

## Notes

### Coroutine Requirements

`cluster.connect`, `cluster.call`, and `cluster.send` must be called in coroutines created by `task.fork()`:

```lua
-- ❌ Wrong: Direct call will error (cluster.connect yields)
local peer, err = cluster.connect("127.0.0.1:8888")

-- ✅ Correct: Call in coroutine
task.fork(function()
    local peer, err = cluster.connect("127.0.0.1:8888")
    if not peer then
        print("Connect failed:", err)
        return
    end
    -- use peer...
end)
```

### Peer Handles

- **Peer handles from connect**: Have `fd` and `remoteaddr` fields
  - Connection is established immediately by `cluster.connect()`
  - When the connection drops, `call`/`send` returns `"Peer closed"`
  - **No automatic reconnection** — call `cluster.connect()` again to get a new peer

- **Peer handles from accept callback**: Have `fd` and `remoteaddr` fields
  - Behave identically to connect-created peers once connected

- **Listener handles**: Used for listening on ports
  - Can be closed via `cluster.close()`

### Timeout Control

- Default timeout 5000 milliseconds (5 seconds)
- On timeout, returns `nil, errno.TIMEDOUT`
- Timed-out requests are cleaned up, delayed responses are ignored

### Error Handling

`cluster.call` / `cluster.send` errors are **opaque strings** from the caller's perspective — do not `err == errno.X` against them. Log or propagate the value; put retry / fallback decisions elsewhere.

```lua
local logger = require "silly.logger"

task.fork(function()
    local peer, err = cluster.connect(addr)
    if not peer then
        logger.error("cluster connect failed:", err)
        return
    end

    local resp, err = cluster.call(peer, data)
    if not resp then
        logger.error("cluster call failed:", err)
        return
    end

    -- Process response...
end)
```

### Distributed Tracing

Cluster automatically propagates trace IDs:

```lua
-- Client initiates request, automatically carries current trace ID using trace.propagate()
local resp = cluster.call(peer, data)

-- Server processes, trace ID is automatically set by cluster
call = function(peer, data)
    -- logger automatically uses current trace ID for logging
    -- Enables distributed tracing across services
    logger.info("Processing request")
end
```

### Performance Recommendations

1. **Connection Reuse**: Establish long connections, avoid frequent connection/disconnection
2. **Batch Operations**: Use `task.fork()` to send multiple concurrent requests
3. **Reasonable Timeouts**: Set appropriate timeout based on business needs
4. **Serialization Choice**: Prioritize binary protocols (zproto, protobuf)
5. **Connection Pool**: For high-concurrency scenarios, maintain a connection pool

---

## Related Modules

- [silly.net.tcp](./tcp.md) - TCP low-level interface
- [silly.net.dns](./dns.md) - DNS resolution
- [silly.logger](../logger.md) - Logging
- [silly.time](../time.md) - Timers and delays
- [silly.sync.waitgroup](../sync/waitgroup.md) - Coroutine synchronization
