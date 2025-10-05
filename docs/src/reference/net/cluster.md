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

cluster 内部使用 `silly.netpacket` 模块实现二进制协议：

- **请求包**：`[2字节长度][业务数据][traceid(8字节)][cmd(4字节)][session(4字节)]`
- **响应包**：`[2字节长度][业务数据][session(4字节)]`
- **会话机制**：使用 session 自动匹配请求和响应
- **超时控制**：支持为每个请求设置超时时间

### 序列化机制

cluster 模块不绑定特定的序列化格式，通过配置回调函数支持任意编解码方式：

- **marshal**：将 Lua 数据编码为二进制
- **unmarshal**：将二进制解码为 Lua 数据
- 常见选择：zproto、protobuf、msgpack、json 等

## API 参考

### cluster.new(conf)

创建一个 cluster 实例，用于节点间通信。

**参数：**

- `conf` (table) - 配置表，包含以下字段：
  - `marshal` (function) - **必需**，编码函数：`function(type, cmd, body) -> cmd_number, data, size`
    - `type`："request" 或 "response"
    - `cmd`：命令标识（字符串或数字）
    - `body`：要编码的 Lua 数据
    - 返回：命令数字、数据指针、数据大小
  - `unmarshal` (function) - **必需**，解码函数：`function(type, cmd, buffer, size) -> body`
    - `type`："request" 或 "response"
    - `cmd`：命令标识
    - `buffer`：数据指针（lightuserdata）
    - `size`：数据大小
    - 返回：解码后的 Lua 数据
  - `call` (function) - **必需**，RPC 请求处理函数：`function(body, cmd, fd) -> response`
    - `body`：解码后的请求数据
    - `cmd`：命令标识
    - `fd`：连接的文件描述符
    - 返回：响应数据（nil 表示不需要响应）
  - `close` (function) - **必需**，连接关闭回调：`function(fd, errno)`
    - `fd`：连接的文件描述符
    - `errno`：错误码
  - `accept` (function) - 可选，新连接回调：`function(fd, addr)`
    - `fd`：新连接的文件描述符
    - `addr`：客户端地址
  - `timeout` (number) - 可选，RPC 超时时间（毫秒），默认 5000

**返回值：**

- `cluster` (table) - cluster 实例对象

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
    local buf, size = proto:pack(dat, sz, true)
    return cmd, buf, size
end

-- 解码函数
local function unmarshal(typ, cmd, buf, size)
    if typ == "response" then
        if cmd == "ping" or cmd == 0x01 then
            cmd = "pong"
        end
    end

    local dat, sz = proto:unpack(buf, size, true)
    local body = proto:decode(cmd, dat, sz)
    return body
end

-- 创建服务器
local server = cluster.new {
    timeout = 3000,
    marshal = marshal,
    unmarshal = unmarshal,
    accept = function(fd, addr)
        print("新连接:", fd, addr)
    end,
    call = function(body, cmd, fd)
        print("收到请求:", body.msg)
        return {msg = "Hello from server"}
    end,
    close = function(fd, errno)
        print("连接关闭:", fd, errno)
    end,
}

-- 启动监听
local listen_fd = server.listen("127.0.0.1:8888")
print("服务器监听:", listen_fd)

-- 创建客户端并测试
silly.fork(function()
    local client = cluster.new {
        marshal = marshal,
        unmarshal = unmarshal,
        call = function() end,
        close = function() end,
    }

    local fd, err = client.connect("127.0.0.1:8888")
    if not fd then
        print("连接失败:", err)
        return
    end

    local resp = client.call(fd, "ping", {msg = "Hello"})
    print("收到响应:", resp and resp.msg or "nil")

    client.close(fd)
end)
```

---

### instance.listen(addr, backlog)

在指定地址上监听 TCP 连接。

**参数：**

- `addr` (string) - 监听地址，格式为 "ip:port"
- `backlog` (number) - 可选，listen 队列长度，默认 128

**返回值：**

- `fd` (number|nil) - 成功返回监听文件描述符
- `err` (string|nil) - 失败返回错误信息

**注意：**

- listen 是同步操作，不需要在协程中调用
- 监听成功后，新连接会触发 `accept` 回调

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

local server = cluster.new {
    marshal = function(typ, cmd, body)
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf, size = proto:pack(dat, sz, true)
        return cmd, buf, size
    end,
    unmarshal = function(typ, cmd, buf, size)
        local dat, sz = proto:unpack(buf, size, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function(fd, addr)
        print(string.format("接受连接 fd=%d 来自 %s", fd, addr))
    end,
    call = function(body, cmd, fd)
        return body
    end,
    close = function(fd, errno)
        print(string.format("连接 %d 关闭，错误码: %d", fd, errno))
    end,
}

-- 监听多个端口
local fd1 = server.listen("0.0.0.0:8888")
local fd2 = server.listen("0.0.0.0:8889", 256)

print("监听端口:", fd1, fd2)
```

---

### instance.connect(addr)

连接到指定地址的服务器。这是一个**异步操作**，必须在协程中调用。

**参数：**

- `addr` (string) - 服务器地址，格式为 "ip:port" 或 "domain:port"

**返回值：**

- `fd` (number|nil) - 成功返回连接文件描述符
- `err` (string) - 失败返回错误信息

**注意：**

- 必须在 `silly.fork()` 创建的协程中调用
- 支持域名解析（自动调用 DNS 查询）
- 连接成功后即可使用 `call` 或 `send` 发送请求

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

local client = cluster.new {
    marshal = function(typ, cmd, body)
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf, size = proto:pack(dat, sz, true)
        return cmd, buf, size
    end,
    unmarshal = function(typ, cmd, buf, size)
        local dat, sz = proto:unpack(buf, size, true)
        return proto:decode(cmd, dat, sz)
    end,
    call = function() end,
    close = function() end,
}

silly.fork(function()
    -- 连接 IP 地址
    local fd1, err1 = client.connect("127.0.0.1:8888")
    print("连接1:", fd1, err1)

    -- 连接域名（会自动 DNS 解析）
    local fd2, err2 = client.connect("example.com:80")
    print("连接2:", fd2, err2)

    -- 连接失败处理
    if not fd1 then
        print("连接失败:", err1)
        return
    end

    -- 使用连接...
    client.close(fd1)
end)
```

---

### instance.call(fd, cmd, obj)

发送 RPC 请求并等待响应。这是一个**异步操作**，必须在协程中调用。

**参数：**

- `fd` (number) - 连接的文件描述符
- `cmd` (string|number) - 命令标识
- `obj` (any) - 请求数据（会通过 marshal 编码）

**返回值：**

- `response` (any|nil) - 成功返回响应数据（通过 unmarshal 解码）
- `err` (string|nil) - 失败返回错误信息（"closed"、"timeout" 等）

**注意：**

- 必须在 `silly.fork()` 创建的协程中调用
- 如果超时，返回 `nil, "timeout"`
- 如果连接已关闭，返回 `nil, "closed"`
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
local server = cluster.new {
    timeout = 2000,
    marshal = function(typ, cmd, body)
        if typ == "response" and cmd == "add" then
            cmd = "sum"
        end
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf, size = proto:pack(dat, sz, true)
        return cmd, buf, size
    end,
    unmarshal = function(typ, cmd, buf, size)
        if typ == "response" and cmd == "add" then
            cmd = "sum"
        end
        local dat, sz = proto:unpack(buf, size, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function() end,
    call = function(body, cmd, fd)
        -- 计算加法
        return {result = body.a + body.b}
    end,
    close = function() end,
}

server.listen("127.0.0.1:9999")

-- 客户端测试
silly.fork(function()
    local client = cluster.new {
        timeout = 2000,
        marshal = server.__event.marshal or function(typ, cmd, body)
            if typ == "response" and cmd == "add" then
                cmd = "sum"
            end
            if type(cmd) == "string" then
                cmd = proto:tag(cmd)
            end
            local dat, sz = proto:encode(cmd, body, true)
            local buf, size = proto:pack(dat, sz, true)
            return cmd, buf, size
        end,
        unmarshal = server.__event.unmarshal or function(typ, cmd, buf, size)
            if typ == "response" and cmd == "add" then
                cmd = "sum"
            end
            local dat, sz = proto:unpack(buf, size, true)
            return proto:decode(cmd, dat, sz)
        end,
        call = function() end,
        close = function() end,
    }

    time.sleep(100)
    local fd = client.connect("127.0.0.1:9999")

    -- 发送请求并等待响应
    local resp, err = client.call(fd, "add", {a = 10, b = 20})
    if resp then
        print("计算结果:", resp.result)  -- 输出: 30
    else
        print("调用失败:", err)
    end

    client.close(fd)
end)
```

---

### instance.send(fd, cmd, obj)

发送单向消息，不等待响应。这是一个**异步操作**，必须在协程中调用。

**参数：**

- `fd` (number) - 连接的文件描述符
- `cmd` (string|number) - 命令标识
- `obj` (any) - 消息数据

**返回值：**

- `ok` (boolean|nil) - 成功返回 true
- `err` (string|nil) - 失败返回错误信息

**注意：**

- 必须在 `silly.fork()` 创建的协程中调用
- 与 `call` 不同，send 不等待响应
- 适用于通知、日志推送等无需响应的场景

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
local server = cluster.new {
    marshal = function(typ, cmd, body)
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf, size = proto:pack(dat, sz, true)
        return cmd, buf, size
    end,
    unmarshal = function(typ, cmd, buf, size)
        local dat, sz = proto:unpack(buf, size, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function() end,
    call = function(body, cmd, fd)
        print("收到通知:", body.message)
        -- 单向消息不返回响应
        return nil
    end,
    close = function() end,
}

server.listen("127.0.0.1:7777")

-- 客户端发送通知
silly.fork(function()
    local client = cluster.new {
        marshal = function(typ, cmd, body)
            if type(cmd) == "string" then
                cmd = proto:tag(cmd)
            end
            local dat, sz = proto:encode(cmd, body, true)
            local buf, size = proto:pack(dat, sz, true)
            return cmd, buf, size
        end,
        unmarshal = function(typ, cmd, buf, size)
            local dat, sz = proto:unpack(buf, size, true)
            return proto:decode(cmd, dat, sz)
        end,
        call = function() end,
        close = function() end,
    }

    time.sleep(100)
    local fd = client.connect("127.0.0.1:7777")

    -- 发送多条通知
    for i = 1, 5 do
        local ok, err = client.send(fd, "notify", {
            message = "通知 #" .. i
        })
        if not ok then
            print("发送失败:", err)
            break
        end
        time.sleep(100)
    end

    client.close(fd)
end)
```

---

### instance.close(fd)

关闭连接。

**参数：**

- `fd` (number|string) - 文件描述符或监听地址

**返回值：**

- `ok` (boolean) - true 表示连接存在并已关闭
- `status` (string) - "connected" 或 "closed"

**注意：**

- 可以关闭客户端连接、accept 的连接或监听 fd
- 关闭后会触发 `close` 回调

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

local server = cluster.new {
    marshal = function(typ, cmd, body)
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf, size = proto:pack(dat, sz, true)
        return cmd, buf, size
    end,
    unmarshal = function(typ, cmd, buf, size)
        local dat, sz = proto:unpack(buf, size, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function() end,
    call = function() end,
    close = function(fd, errno)
        print("连接已关闭:", fd, errno)
    end,
}

local listen_fd = server.listen("127.0.0.1:6666")

silly.fork(function()
    local client = cluster.new {
        marshal = function(typ, cmd, body)
            if type(cmd) == "string" then
                cmd = proto:tag(cmd)
            end
            local dat, sz = proto:encode(cmd, body, true)
            local buf, size = proto:pack(dat, sz, true)
            return cmd, buf, size
        end,
        unmarshal = function(typ, cmd, buf, size)
            local dat, sz = proto:unpack(buf, size, true)
            return proto:decode(cmd, dat, sz)
        end,
        call = function() end,
        close = function(fd, errno)
            print("客户端连接关闭:", fd, errno)
        end,
    }

    local fd = client.connect("127.0.0.1:6666")

    -- 主动关闭连接
    local ok, status = client.close(fd)
    print("关闭连接:", ok, status)

    -- 重复关闭会返回 false
    ok, status = client.close(fd)
    print("重复关闭:", ok, status)  -- false, "closed"
end)
```

---

## 完整示例

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
    local buf, size = proto:pack(dat, sz, true)
    return cmd, buf, size
end

local function unmarshal(typ, cmd, buf, size)
    local dat, sz = proto:unpack(buf, size, true)
    return proto:decode(cmd, dat, sz)
end

-- 节点信息
local nodes = {}

-- 创建节点服务器
local function create_node(node_id, port)
    local server = cluster.new {
        timeout = 5000,
        marshal = marshal,
        unmarshal = unmarshal,
        accept = function(fd, addr)
            print(string.format("[%s] 接受连接: %s", node_id, addr))
        end,
        call = function(body, cmd, fd)
            if cmd == 0x01 then  -- register
                nodes[body.node_id] = {fd = fd, addr = body.addr}
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
        close = function(fd, errno)
            -- 清理断开的节点
            for k, v in pairs(nodes) do
                if v.fd == fd then
                    print(string.format("[%s] 节点断开: %s", node_id, k))
                    nodes[k] = nil
                    break
                end
            end
        end,
    }

    local listen_fd = server.listen("127.0.0.1:" .. port)
    print(string.format("[%s] 监听端口: %d", node_id, port))

    return server
end

-- 创建三个节点
local node1 = create_node("node1", 10001)
local node2 = create_node("node2", 10002)
local node3 = create_node("node3", 10003)

-- 节点互联
silly.fork(function()
    time.sleep(100)

    -- node2 连接到 node1
    local client2 = cluster.new {
        marshal = marshal,
        unmarshal = unmarshal,
        call = function() end,
        close = function() end,
    }

    local fd2 = client2.connect("127.0.0.1:10001")
    if fd2 then
        local resp = client2.call(fd2, "register", {
            node_id = "node2",
            addr = "127.0.0.1:10002"
        })
        print("注册响应:", resp and resp.status or "nil")

        -- 发送心跳
        time.sleep(500)
        local hb = client2.call(fd2, "heartbeat", {
            timestamp = os.time()
        })
        print("心跳响应:", hb and hb.timestamp or "nil")
    end

    -- node3 连接到 node1
    local client3 = cluster.new {
        marshal = marshal,
        unmarshal = unmarshal,
        call = function() end,
        close = function() end,
    }

    local fd3 = client3.connect("127.0.0.1:10001")
    if fd3 then
        client3.call(fd3, "register", {
            node_id = "node3",
            addr = "127.0.0.1:10003"
        })

        -- 通过 node1 转发消息
        local fwd = client3.call(fd3, "forward", {
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

-- 广播服务器
local broadcast_server = cluster.new {
    marshal = function(typ, cmd, body)
        if typ == "response" and cmd == "broadcast" then
            cmd = "ack"
        end
        if type(cmd) == "string" then
            cmd = proto:tag(cmd)
        end
        local dat, sz = proto:encode(cmd, body, true)
        local buf, size = proto:pack(dat, sz, true)
        return cmd, buf, size
    end,
    unmarshal = function(typ, cmd, buf, size)
        if typ == "response" and cmd == "broadcast" then
            cmd = "ack"
        end
        local dat, sz = proto:unpack(buf, size, true)
        return proto:decode(cmd, dat, sz)
    end,
    accept = function() end,
    call = function(body, cmd, fd)
        print("接收广播:", body.message)
        return {node_id = "node_" .. fd}
    end,
    close = function() end,
}

-- 启动 3 个接收节点
local ports = {8001, 8002, 8003}
for _, port in ipairs(ports) do
    broadcast_server.listen("127.0.0.1:" .. port)
end

-- 广播客户端
silly.fork(function()
    time.sleep(200)

    local broadcaster = cluster.new {
        timeout = 1000,
        marshal = function(typ, cmd, body)
            if typ == "response" and cmd == "broadcast" then
                cmd = "ack"
            end
            if type(cmd) == "string" then
                cmd = proto:tag(cmd)
            end
            local dat, sz = proto:encode(cmd, body, true)
            local buf, size = proto:pack(dat, sz, true)
            return cmd, buf, size
        end,
        unmarshal = function(typ, cmd, buf, size)
            if typ == "response" and cmd == "broadcast" then
                cmd = "ack"
            end
            local dat, sz = proto:unpack(buf, size, true)
            return proto:decode(cmd, dat, sz)
        end,
        call = function() end,
        close = function() end,
    }

    -- 连接所有节点
    local connections = {}
    for _, port in ipairs(ports) do
        local fd = broadcaster.connect("127.0.0.1:" .. port)
        if fd then
            table.insert(connections, fd)
        end
    end

    -- 并发广播到所有节点
    local message = "重要通知：系统将于 10 分钟后维护"
    local acks = {}

    for _, fd in ipairs(connections) do
        silly.fork(function()
            local resp = broadcaster.call(fd, "broadcast", {
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
    for _, fd in ipairs(connections) do
        broadcaster.close(fd)
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

-- 工作节点
local function create_worker(worker_id, port)
    local worker = cluster.new {
        timeout = 3000,
        marshal = function(typ, cmd, body)
            if typ == "response" and cmd == "work" then
                cmd = "result"
            end
            if type(cmd) == "string" then
                cmd = proto:tag(cmd)
            end
            local dat, sz = proto:encode(cmd, body, true)
            local buf, size = proto:pack(dat, sz, true)
            return cmd, buf, size
        end,
        unmarshal = function(typ, cmd, buf, size)
            if typ == "response" and cmd == "work" then
                cmd = "result"
            end
            local dat, sz = proto:unpack(buf, size, true)
            return proto:decode(cmd, dat, sz)
        end,
        accept = function() end,
        call = function(body, cmd, fd)
            -- 模拟工作处理
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

    worker.listen("127.0.0.1:" .. port)
    return worker
end

-- 启动 3 个工作节点
local workers = {
    create_worker(1, 9001),
    create_worker(2, 9002),
    create_worker(3, 9003),
}

-- 负载均衡器
silly.fork(function()
    time.sleep(200)

    local balancer = cluster.new {
        timeout = 5000,
        marshal = function(typ, cmd, body)
            if typ == "response" and cmd == "work" then
                cmd = "result"
            end
            if type(cmd) == "string" then
                cmd = proto:tag(cmd)
            end
            local dat, sz = proto:encode(cmd, body, true)
            local buf, size = proto:pack(dat, sz, true)
            return cmd, buf, size
        end,
        unmarshal = function(typ, cmd, buf, size)
            if typ == "response" and cmd == "work" then
                cmd = "result"
            end
            local dat, sz = proto:unpack(buf, size, true)
            return proto:decode(cmd, dat, sz)
        end,
        call = function() end,
        close = function() end,
    }

    -- 连接所有工作节点
    local worker_fds = {}
    local ports = {9001, 9002, 9003}
    for _, port in ipairs(ports) do
        local fd = balancer.connect("127.0.0.1:" .. port)
        if fd then
            table.insert(worker_fds, fd)
        end
    end

    -- 轮询分发任务
    local current = 1
    for task_id = 1, 10 do
        local fd = worker_fds[current]

        silly.fork(function()
            local resp = balancer.call(fd, "work", {
                task_id = task_id,
                data = "任务数据 " .. task_id
            })
            if resp then
                print(string.format("任务 #%d 结果: %s",
                    resp.task_id, resp.output))
            end
        end)

        -- 轮询到下一个工作节点
        current = (current % #worker_fds) + 1
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
local fd = client.connect("127.0.0.1:8888")

-- ✅ 正确：在协程中调用
silly.fork(function()
    local fd = client.connect("127.0.0.1:8888")
end)
```

### 连接生命周期

- 使用 `__fdaddr` 表跟踪所有活动连接
- 实例被 GC 时自动关闭所有连接（`__gc` 元方法）
- 手动关闭连接后，该 fd 从 `__fdaddr` 中移除

### 超时控制

- 默认超时 5000 毫秒（5 秒）
- 超时后返回 `nil, "timeout"`
- 超时的请求会被清理，延迟到达的响应会被忽略

### 序列化注意事项

- `marshal` 必须返回命令数字（不能是字符串）
- `unmarshal` 接收的 buffer 是 lightuserdata，需要通过 `np.tostring()` 或协议库处理
- 处理完 buffer 后必须调用 `np.drop()` 释放（cluster 内部已自动处理）

### 分布式追踪

cluster 自动传播 trace ID：

```lua
-- 客户端发起请求时，自动携带当前 trace ID
local resp = client.call(fd, "ping", data)

-- 服务器端处理时，自动切换到请求的 trace ID
call = function(body, cmd, fd)
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
    local fd, err = client.connect(addr)
    if not fd then
        -- 连接失败
        print("连接错误:", err)
        return
    end

    local resp, err = client.call(fd, cmd, data)
    if not resp then
        -- 调用失败
        if err == "timeout" then
            -- 超时处理
        elseif err == "closed" then
            -- 连接已关闭
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
