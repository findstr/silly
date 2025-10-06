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

- **请求包**：`[2字节长度][业务数据][traceid(8字节)][cmd(4字节)][session(4字节)]`
- **响应包**：`[2字节长度][业务数据][session(4字节)]`
- **会话机制**：使用 session 自动匹配请求和响应
- **超时控制**：支持为每个请求设置超时时间
- **内存管理**：buffer 自动管理，无需手动释放

### 序列化机制

cluster 模块不绑定特定的序列化格式，通过配置回调函数支持任意编解码方式：

- **marshal**：将 Lua 数据编码为二进制
- **unmarshal**：将二进制解码为 Lua 数据
- 常见选择：zproto、protobuf、msgpack、json 等

## API 参考

### cluster.serve(conf)

配置 cluster 模块的全局行为，设置编解码、超时和回调函数。

**参数：**

- `conf` (table) - 配置表，包含以下字段：
  - `marshal` (function) - **必需**，编码函数：`function(type, cmd, body) -> cmd_number, data`
    - `type`："request" 或 "response"
    - `cmd`：命令标识（字符串或数字）
    - `body`：要编码的 Lua 数据
    - 返回：命令数字、数据字符串
  - `unmarshal` (function) - **必需**，解码函数：`function(type, cmd, data) -> body, err?`
    - `type`："request" 或 "response"
    - `cmd`：命令标识
    - `data`：数据字符串
    - 返回：解码后的 Lua 数据，可选错误信息
  - `call` (function) - **必需**，RPC 请求处理函数：`function(peer, cmd, body) -> response`
    - `peer`：连接的 peer 对象
    - `cmd`：命令标识
    - `body`：解码后的请求数据
    - 返回：响应数据（nil 表示不需要响应）
  - `close` (function) - 可选，连接关闭回调：`function(peer, errno)`
    - `peer`：连接的 peer 对象
    - `errno`：错误码
  - `accept` (function) - 可选，新连接回调：`function(peer, addr)`
    - `peer`：新连接的 peer 对象
    - `addr`：客户端地址
  - `timeout` (number) - 可选，RPC 超时时间（毫秒），默认 5000

**返回值：**

- 无返回值

**注意：**

- `cluster.serve()` 必须在使用其他 cluster 函数之前调用
- peer 对象包含 `fd` 和 `addr` 字段（accept 的 peer 无 addr）
- 有 addr 的 peer 支持自动重连

**示例：**

```lua validate
local silly = require "silly"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

-- 定义协议
local proto = zproto:parse [[
ping 0x01 {
    .msg:string 1
}
pong 0x02 {
    .msg:string 1
}
]]

-- 编码函数
local function marshal(typ, cmd, body)
    if typ == "response" then
        -- 响应时将 ping 转换为 pong
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

-- 解码函数
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

-- 配置服务器
cluster.serve {
    timeout = 3000,
    marshal = marshal,
    unmarshal = unmarshal,
    accept = function(peer, addr)
        print("新连接:", peer.fd, addr)
    end,
    call = function(peer, cmd, body)
        print("收到请求:", body.msg)
        return {msg = "Hello from server"}
    end,
    close = function(peer, errno)
        print("连接关闭:", peer.fd, errno)
    end,
}

-- 启动监听
local listen_handle = cluster.listen("127.0.0.1:8888")
print("服务器监听:", listen_handle.fd)

-- 创建客户端并测试
silly.fork(function()
    local peer, err = cluster.connect("127.0.0.1:8888")
    if not peer then
        print("连接失败:", err)
        return
    end

    local resp = cluster.call(peer, "ping", {msg = "Hello"})
    print("收到响应:", resp and resp.msg or "nil")

    cluster.close(peer)
end)
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

**示例：**

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
        print(string.format("接受连接 fd=%d 来自 %s", peer.fd, addr))
    end,
    call = function(peer, cmd, body)
        return body
    end,
    close = function(peer, errno)
        print(string.format("连接 %d 关闭，错误码: %d", peer.fd, errno))
    end,
}

-- 监听多个端口
local listener1 = cluster.listen("0.0.0.0:8888")
local listener2 = cluster.listen("0.0.0.0:8889", 256)

print("监听端口:", listener1.fd, listener2.fd)
```

---

### cluster.connect(addr)

连接到指定地址的服务器。这是一个**异步操作**，必须在协程中调用。

**参数：**

- `addr` (string) - 服务器地址，格式为 "ip:port" 或 "domain:port"

**返回值：**

- `peer` (table|nil) - 成功返回 peer 对象，包含 `fd` 和 `addr` 字段
- `err` (string) - 失败返回错误信息

**注意：**

- 必须在 `silly.fork()` 创建的协程中调用
- 支持域名解析（自动调用 DNS 查询）
- peer 对象保存了地址信息，连接断开后可自动重连
- 连接成功后即可使用 `cluster.call()` 或 `cluster.send()` 发送请求

**示例：**

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

silly.fork(function()
    -- 连接 IP 地址
    local peer1, err1 = cluster.connect("127.0.0.1:8888")
    print("连接1:", peer1 and peer1.fd or nil, err1)

    -- 连接域名（会自动 DNS 解析）
    local peer2, err2 = cluster.connect("example.com:80")
    print("连接2:", peer2 and peer2.fd or nil, err2)

    -- 连接失败处理
    if not peer1 then
        print("连接失败:", err1)
        return
    end

    -- 使用连接...
    cluster.close(peer1)
end)
```

---

### cluster.call(peer, cmd, obj)

发送 RPC 请求并等待响应。这是一个**异步操作**，必须在协程中调用。

**参数：**

- `peer` (table) - peer 对象（由 `cluster.connect()` 或 accept 回调获得）
- `cmd` (string|number) - 命令标识
- `obj` (any) - 请求数据（会通过 marshal 编码）

**返回值：**

- `response` (any|nil) - 成功返回响应数据（通过 unmarshal 解码）
- `err` (string|nil) - 失败返回错误信息（"closed"、"timeout" 等）

**注意：**

- 必须在 `silly.fork()` 创建的协程中调用
- 如果超时，返回 `nil, "timeout"`
- 如果连接已关闭但 peer 有 addr，会自动重连
- 如果 peer 无 addr（accept 产生的），连接断开后返回 `nil, "peer closed"`
- 自动处理 session 匹配和超时控制

**示例：**

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

-- 服务器端
cluster.serve {
    timeout = 2000,
    marshal = function(typ, cmd, body)
        if typ == "response" and cmd == "add" then
            cmd = "sum"
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
        -- 计算加法
        return {result = body.a + body.b}
    end,
    close = function() end,
}

cluster.listen("127.0.0.1:9999")

-- 客户端测试
silly.fork(function()
    time.sleep(100)
    local peer = cluster.connect("127.0.0.1:9999")

    -- 发送请求并等待响应
    local resp, err = cluster.call(peer, "add", {a = 10, b = 20})
    if resp then
        print("计算结果:", resp.result)  -- 输出: 30
    else
        print("调用失败:", err)
    end

    cluster.close(peer)
end)
```

---

### cluster.send(peer, cmd, obj)

发送单向消息，不等待响应。这是一个**异步操作**，必须在协程中调用。

**参数：**

- `peer` (table) - peer 对象
- `cmd` (string|number) - 命令标识
- `obj` (any) - 消息数据

**返回值：**

- `ok` (boolean|nil) - 成功返回 true
- `err` (string|nil) - 失败返回错误信息

**注意：**

- 必须在 `silly.fork()` 创建的协程中调用
- 与 `call` 不同，send 不等待响应
- 适用于通知、日志推送等无需响应的场景
- 如果连接断开但 peer 有 addr，会自动重连

**示例：**

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

-- 服务器接收通知
cluster.serve {
    marshal = function(typ, cmd, body)
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
        print("收到通知:", body.message)
        -- 单向消息不返回响应
        return nil
    end,
    close = function() end,
}

cluster.listen("127.0.0.1:7777")

-- 客户端发送通知
silly.fork(function()
    time.sleep(100)
    local peer = cluster.connect("127.0.0.1:7777")

    -- 发送多条通知
    for i = 1, 5 do
        local ok, err = cluster.send(peer, "notify", {
            message = "通知 #" .. i
        })
        if not ok then
            print("发送失败:", err)
            break
        end
        time.sleep(100)
    end

    cluster.close(peer)
end)
```

---

### cluster.close(peer)

关闭连接或监听器。

**参数：**

- `peer` (table) - peer 对象或 listener 对象

**返回值：**

- 无返回值

**注意：**

- 可以关闭客户端连接、accept 的连接或监听器
- 关闭后会触发 `close` 回调（listener 除外）
- 关闭后 peer.fd 会被设为 nil

**示例：**

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
        print("连接已关闭:", peer.fd, errno)
    end,
}

local listener = cluster.listen("127.0.0.1:6666")

silly.fork(function()
    local peer = cluster.connect("127.0.0.1:6666")

    -- 主动关闭连接
    cluster.close(peer)
    print("peer 已关闭, fd:", peer.fd)  -- nil

    -- 关闭监听器
    cluster.close(listener)
end)
```

---

## 完整示例

### 简单的 RPC 服务

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
    if typ == "response" and (cmd == "ping" or cmd == 0x01) then
        cmd = "pong"
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
        print("新连接:", peer.fd, addr)
    end,
    call = function(peer, cmd, body)
        print("收到:", body.msg)
        return {msg = "pong from server"}
    end,
    close = function(peer, errno)
        print("连接关闭:", peer.fd)
    end,
}

cluster.listen("127.0.0.1:8888")

silly.fork(function()
    local peer = cluster.connect("127.0.0.1:8888")
    local resp = cluster.call(peer, "ping", {msg = "ping"})
    print("响应:", resp.msg)
    cluster.close(peer)
end)
```

---

### 多节点集群通信

```lua validate
local silly = require "silly"
local time = require "silly.time"
local cluster = require "silly.net.cluster"
local zproto = require "zproto"

-- 定义集群协议
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

-- 节点信息
local nodes = {}

-- 创建节点服务器
local function create_node(node_id, port)
    cluster.serve {
        timeout = 5000,
        marshal = marshal,
        unmarshal = unmarshal,
        accept = function(peer, addr)
            print(string.format("[%s] 接受连接: %s", node_id, addr))
            nodes[addr] = peer
        end,
        call = function(peer, cmd, body)
            if cmd == 0x01 then  -- register
                print(string.format("[%s] 节点注册: %s @ %s",
                    node_id, body.node_id, body.addr))
                return {status = "ok"}
            elseif cmd == 0x02 then  -- heartbeat
                return {timestamp = os.time()}
            elseif cmd == 0x03 then  -- forward
                print(string.format("[%s] 转发消息到 %s: %s",
                    node_id, body.target, body.data))
                return {result = "forwarded"}
            end
        end,
        close = function(peer, errno)
            print(string.format("[%s] 节点断开", node_id))
        end,
    }

    local listener = cluster.listen("127.0.0.1:" .. port)
    print(string.format("[%s] 监听端口: %d", node_id, port))
    return listener
end

-- 创建三个节点
local node1 = create_node("node1", 10001)
local node2 = create_node("node2", 10002)
local node3 = create_node("node3", 10003)

-- 节点互联
silly.fork(function()
    time.sleep(100)

    -- node2 连接到 node1
    local peer2 = cluster.connect("127.0.0.1:10001")
    if peer2 then
        local resp = cluster.call(peer2, "register", {
            node_id = "node2",
            addr = "127.0.0.1:10002"
        })
        print("注册响应:", resp and resp.status or "nil")

        -- 发送心跳
        time.sleep(500)
        local hb = cluster.call(peer2, "heartbeat", {
            timestamp = os.time()
        })
        print("心跳响应:", hb and hb.timestamp or "nil")
    end

    -- node3 连接到 node1
    local peer3 = cluster.connect("127.0.0.1:10001")
    if peer3 then
        cluster.call(peer3, "register", {
            node_id = "node3",
            addr = "127.0.0.1:10003"
        })

        -- 通过 node1 转发消息
        local fwd = cluster.call(peer3, "forward", {
            target = "node2",
            data = "Hello from node3"
        })
        print("转发结果:", fwd and fwd.result or "nil")
    end
end)
```

---

### 广播消息到所有节点

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

-- 配置广播服务器
cluster.serve {
    timeout = 1000,
    marshal = function(typ, cmd, body)
        if typ == "response" and cmd == "broadcast" then
            cmd = "ack"
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
        print("接收广播:", body.message)
        return {node_id = "node_" .. peer.fd}
    end,
    close = function() end,
}

-- 启动 3 个接收节点
local listeners = {}
local ports = {8001, 8002, 8003}
for _, port in ipairs(ports) do
    local listener = cluster.listen("127.0.0.1:" .. port)
    table.insert(listeners, listener)
end

-- 广播客户端
silly.fork(function()
    time.sleep(200)

    -- 连接所有节点
    local peers = {}
    for _, port in ipairs(ports) do
        local peer = cluster.connect("127.0.0.1:" .. port)
        if peer then
            table.insert(peers, peer)
        end
    end

    -- 并发广播到所有节点
    local message = "重要通知：系统将于 10 分钟后维护"
    local acks = {}

    for _, peer in ipairs(peers) do
        silly.fork(function()
            local resp = cluster.call(peer, "broadcast", {
                message = message
            })
            if resp then
                table.insert(acks, resp.node_id)
                print("收到确认:", resp.node_id)
            end
        end)
    end

    -- 等待所有响应
    time.sleep(500)
    print("广播完成，确认数:", #acks)

    -- 清理连接
    for _, peer in ipairs(peers) do
        cluster.close(peer)
    end
end)
```

---

### 负载均衡调用

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

-- 配置 cluster 服务
cluster.serve {
    timeout = 3000,
    marshal = function(typ, cmd, body)
        if typ == "response" and cmd == "work" then
            cmd = "result"
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
        -- 模拟工作处理（根据端口区分工作节点）
        local worker_id = peer.fd % 3 + 1
        print(string.format("[Worker %d] 处理任务 #%d: %s",
            worker_id, body.task_id, body.data))
        time.sleep(100 + math.random(200))
        return {
            task_id = body.task_id,
            output = string.format("Worker %d 完成", worker_id)
        }
    end,
    close = function() end,
}

-- 启动 3 个工作节点
local listeners = {}
local ports = {9001, 9002, 9003}
for _, port in ipairs(ports) do
    local listener = cluster.listen("127.0.0.1:" .. port)
    table.insert(listeners, listener)
end

-- 负载均衡器客户端
silly.fork(function()
    time.sleep(200)

    -- 连接所有工作节点
    local worker_peers = {}
    for _, port in ipairs(ports) do
        local peer = cluster.connect("127.0.0.1:" .. port)
        if peer then
            table.insert(worker_peers, peer)
        end
    end

    -- 轮询分发任务
    local current = 1
    for task_id = 1, 10 do
        local peer = worker_peers[current]

        silly.fork(function()
            local resp = cluster.call(peer, "work", {
                task_id = task_id,
                data = "任务数据 " .. task_id
            })
            if resp then
                print(string.format("任务 #%d 结果: %s",
                    resp.task_id, resp.output))
            end
        end)

        -- 轮询到下一个工作节点
        current = (current % #worker_peers) + 1
        time.sleep(50)
    end
end)
```

---

## 注意事项

### 协程要求

所有异步操作（`connect`、`call`、`send`）必须在 `silly.fork()` 创建的协程中调用：

```lua
-- ❌ 错误：直接调用会报错
local peer = cluster.connect("127.0.0.1:8888")

-- ✅ 正确：在协程中调用
silly.fork(function()
    local peer = cluster.connect("127.0.0.1:8888")
end)
```

### Peer 对象和自动重连

- **connect 返回的 peer**：包含 `fd` 和 `addr` 字段，支持自动重连
  - 当连接断开时，`peer.fd` 会被设为 `nil`
  - 下次 `call()` 或 `send()` 时会自动重连
  - 通过 `addr_to_peer` 缓存，防止重复连接同一地址

- **accept 回调的 peer**：只包含 `fd` 字段，不支持自动重连
  - 没有 `addr` 信息，无法自动重连
  - 连接断开后返回 `nil, "peer closed"`

- **listener 对象**：只包含 `fd` 字段，用于监听端口
  - 通过 `cluster.close()` 可以关闭监听器

### 超时控制

- 默认超时 5000 毫秒（5 秒）
- 超时后返回 `nil, "timeout"`
- 超时的请求会被清理，延迟到达的响应会被忽略

### 序列化注意事项

- `marshal` 返回 `(cmd_number, data)`：
  - 第一个返回值必须是数字类型的命令 ID
  - 第二个返回值是编码后的字符串数据
  - 无需返回 size，自动从字符串获取长度

- `unmarshal` 接收字符串参数：
  - 参数 `buf` 是 Lua 字符串，可直接使用 `#buf` 获取长度
  - 无需手动管理内存，buffer 已自动转换为字符串
  - 返回解码后的 Lua 表和可选的错误信息

### 分布式追踪

cluster 自动传播 trace ID：

```lua
-- 客户端发起请求时，自动携带当前 trace ID
local resp = cluster.call(peer, "ping", data)

-- 服务器端处理时，自动切换到请求的 trace ID
call = function(peer, cmd, body)
    -- 这里的 silly.trace() 返回的是客户端的 trace ID
    -- 可以用于分布式追踪
end
```

### 性能建议

1. **复用连接**：建立长连接，避免频繁连接断开
2. **批量操作**：使用 `silly.fork()` 并发发送多个请求
3. **合理超时**：根据业务设置合适的超时时间
4. **序列化选择**：优先使用二进制协议（zproto、protobuf）
5. **连接池**：对于高并发场景，可以维护连接池

### 错误处理

```lua
silly.fork(function()
    local peer, err = cluster.connect(addr)
    if not peer then
        -- 连接失败
        print("连接错误:", err)
        return
    end

    local resp, err = cluster.call(peer, cmd, data)
    if not resp then
        -- 调用失败
        if err == "timeout" then
            -- 超时处理
        elseif err == "peer closed" then
            -- 连接已关闭（无 addr 的 peer）
        elseif err then
            -- 其他错误
        end
        return
    end

    -- 处理响应...
end)
```

---

## 相关模块

- [silly.net.tcp](./tcp.md) - TCP 底层接口
- [silly.net.dns](./dns.md) - DNS 解析
- [silly.logger](../logger.md) - 日志记录
- [silly.time](../time.md) - 定时器和延迟
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程同步
