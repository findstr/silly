---
title: silly.net.cluster
icon: network-wired
category:
  - API参考
tag:
  - 网络
  - 集群
  - RPC
  - 分布式
---

# silly.net.cluster

`silly.net.cluster` 模块提供了基于 TCP 的集群节点间通信功能，实现了一个完整的 RPC（远程过程调用）框架。该模块支持请求-响应模式、超时控制、连接管理和跨节点的分布式追踪。

## 核心概念

### 集群通信模型

cluster 模块采用客户端-服务器模型，每个节点既可以作为服务器接受连接，也可以作为客户端发起连接：

- **服务器角色**：通过 `listen()` 监听端口，接受其他节点的连接
- **客户端角色**：通过 `connect()` 连接到其他节点
- **双向通信**：连接建立后，双方都可以发起 RPC 调用

### RPC 协议

cluster 内部使用 `silly.net.cluster.c` 模块实现二进制协议：

- **请求包**：`[4字节长度][session(8字节)][traceid(8字节)][业务数据]`
- **响应包**：`[4字节长度][session(8字节)][业务数据]`
- **会话机制**：使用 session 自动匹配请求和响应
- **超时控制**：支持为每个请求设置超时时间
- **内存管理**：buffer 自动管理，无需手动释放

### 裸字符串传输

cluster 模块是裸字符串传输层——不做任何序列化或反序列化。`call` 回调接收原始字符串数据并返回原始字符串响应。用户在自己的回调中使用任意格式（zproto、protobuf、msgpack、json 等）进行编解码。

## API 参考

### cluster.serve(conf)

配置 cluster 模块的全局行为，设置超时和回调函数。

**参数：**

- `conf` (table) - 配置表，包含以下字段：
  - `call` (function) - **必需**，RPC 请求处理函数：`function(peer, data) -> response`
    - `peer`：连接的 peer 对象
    - `data`：原始字符串请求数据；分派（执行哪个过程）由调用方在该字符串内自行编码——cluster 只是传输层
    - 返回：原始字符串响应数据（nil 表示不需要响应）
  - `close` (function) - 可选，连接关闭回调：`function(peer, errno)`
    - **仅在对端关闭连接时触发**，主动调用 `cluster.close()` 不会触发此回调
    - `peer`：连接的 peer 对象
    - `errno`：错误码
  - `accept` (function) - 可选，新连接回调：`function(peer)`
    - `peer`：新连接的 peer 对象（含 `remoteaddr` 字段表示客户端地址）
  - `timeout` (number) - 可选，RPC 超时时间（毫秒），默认 5000
  - `hardlimit` (number) - 可选，最大 body 大小限制，超过则报错（默认 128MB）
  - `softlimit` (number) - 可选，最大 body 大小警告阈值（默认 65535）

**返回值：**

- 无返回值

**注意：**

- `cluster.serve()` 必须在使用其他 cluster 函数之前调用
- peer 对象包含 `fd` 和 `remoteaddr` 字段

**示例：**

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

在指定地址上监听 TCP 连接。

**参数：**

- `addr` (string) - 监听地址，格式为 "ip:port"
- `backlog` (number) - 可选，listen 队列长度，默认 128

**返回值：**

- `listener` (table|nil) - 成功返回 listener 对象，包含 `fd` 字段
- `err` (string|nil) - 失败返回错误信息

**注意：**

- listen 是同步操作，不需要在协程中调用
- 监听成功后，新连接会触发 `accept` 回调
- listener 对象可用于 `cluster.close()` 关闭监听

---

### cluster.connect(addr)

连接到远程集群节点。立即执行 DNS 解析和 TCP 连接（eager connect）。这是一个**异步操作**，必须在协程中调用。

**参数：**

- `addr` (string) - 服务器地址，格式为 `"ip:port"` 或 `"domain:port"`

**返回值：**

- `peer` (table|nil) - 成功返回 peer 对象，包含 `fd` 和 `remoteaddr` 字段
- `err` (string|nil) - 失败返回错误信息

**注意：**

- **必须在协程中调用**（例如在 `task.fork()` 内）
- 成功时立即返回已连接的 peer，失败时返回 `nil, err`
- 连接断开后，`call`/`send` 返回 `"Peer closed"`——**不会自动重连**
- 要在断开后重新连接，再次调用 `cluster.connect()` 获取新的 peer

**示例：**

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

发送 RPC 请求并等待响应。这是一个**异步操作**，必须在协程中调用。

**参数：**

- `peer` (table) - peer 对象（由 `cluster.connect()` 或 accept 回调获得）
- `data` (string) - 原始字符串请求数据；服务端所需的任何分派 key 都由你自行编码在该字符串内

**返回值：**

- `response` (string|nil) - 成功返回原始字符串响应数据
- `err` (string|nil) - 失败时返回错误字符串（例如超时、连接错误）

**注意：**

- 必须在 `task.fork()` 创建的协程中调用
- 超时后返回 `nil, errno.TIMEDOUT`
- 如果 peer 的连接已断开，返回 `nil, "Peer closed"`
- 自动处理 session 匹配和超时控制

---

### cluster.send(peer, data)

发送单向消息，不等待响应。这是一个**异步操作**，必须在协程中调用。

**参数：**

- `peer` (table) - peer 对象
- `data` (string) - 原始字符串消息数据

**返回值：**

- `ok` (boolean|nil) - 成功返回 true
- `err` (string|nil) - 失败返回错误信息

**注意：**

- 必须在 `task.fork()` 创建的协程中调用
- 与 `call` 不同，send 不等待响应
- 适用于通知、日志推送等无需响应的场景

---

### cluster.close(peer)

关闭连接或监听器。

**参数：**

- `peer` (table) - peer 对象或 listener 对象

**返回值：**

- 无返回值

**注意：**

- 可以关闭客户端连接、accept 的连接或监听器
- 主动关闭的连接**不会**触发 `close` 回调
- peer 关闭后不应再使用

---

## 完整示例

### 简单的 RPC 服务

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

### 自定义序列化

用户可以在 `call` 回调中使用任意序列化库：

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

## 注意事项

### 协程要求

`cluster.connect`、`cluster.call` 和 `cluster.send` 必须在 `task.fork()` 创建的协程中调用：

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

### Peer 对象

- **connect 返回的 peer**：包含 `fd` 和 `remoteaddr` 字段
  - 连接由 `cluster.connect()` 立即建立
  - 连接断开后，`call`/`send` 返回 `"Peer closed"`
  - **不会自动重连**——再次调用 `cluster.connect()` 获取新的 peer

- **accept 回调的 peer**：包含 `fd` 和 `remoteaddr` 字段
  - 行为与 connect 创建的 peer 一致

- **listener 对象**：用于监听端口
  - 通过 `cluster.close()` 关闭监听器

### 超时控制

- 默认超时 5000 毫秒（5 秒）
- 超时后返回 `nil, errno.TIMEDOUT`
- 超时的请求会被清理，延迟到达的响应会被忽略

### 错误处理

从调用方看，`cluster.call` / `cluster.send` 的错误是**不透明字符串**——不要 `err == errno.X` 做分支判断。把值记日志、原样透传；重试/降级决策放在别处。

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

### 分布式追踪

cluster 自动传播 trace ID：

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

### 性能建议

1. **复用连接**：建立长连接，避免频繁连接断开
2. **批量操作**：使用 `task.fork()` 并发发送多个请求
3. **合理超时**：根据业务设置合适的超时时间
4. **序列化选择**：优先使用二进制协议（zproto、protobuf）
5. **连接池**：对于高并发场景，可以维护连接池

---

## 相关模块

- [silly.net.tcp](./tcp.md) - TCP 底层接口
- [silly.net.dns](./dns.md) - DNS 解析
- [silly.logger](../logger.md) - 日志记录
- [silly.time](../time.md) - 定时器和延迟
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程同步
