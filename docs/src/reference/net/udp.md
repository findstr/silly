---
title: silly.net.udp
icon: network-wired
category:
  - API参考
tag:
  - 网络
  - UDP
  - 协议
---

# udp (`silly.net.udp`)

`silly.net.udp` 模块为 UDP (用户数据报协议) 网络提供了一个高级异步 API。UDP 是一种无连接的、面向消息的协议，这意味着您发送和接收的是离散的数据包（数据报）。

## 模块导入

```lua validate
local udp = require "silly.net.udp"
```

---

## 核心概念

与 TCP 不同，UDP 不建立持久连接。每个数据包都是独立发送的。主要的读取函数 `udp.recvfrom` 是异步的，它会暂停当前协程直到接收到一个数据报，并返回数据和发送方的地址。

创建 UDP 套接字主要有两种方式：
1.  **`udp.bind(address)`**: 创建一个"服务器"套接字，在特定地址上监听，并可以从任何来源接收数据包。在发送响应时，您必须在 `udp.sendto` 中指定目标地址。
2.  **`udp.connect(address)`**: 创建一个"客户端"套接字，它有一个默认的目标地址。您可以使用 `udp.sendto` 发送数据包，而无需每次都指定地址。

---

## UDP vs TCP

**UDP 特性：**
- **无连接**: 不需要握手，直接发送数据包
- **不可靠**: 数据包可能丢失、重复或乱序到达
- **轻量**: 协议开销小，延迟低
- **面向消息**: 保持消息边界

**适用场景：**
- 实时游戏（位置同步、状态更新）
- DNS 查询
- 音视频流（允许少量丢包）
- 局域网服务发现
- 日志收集（允许丢失）

**不适用场景：**
- 文件传输（需要可靠性）
- HTTP/HTTPS（需要顺序保证）
- 数据库连接（需要事务性）

---

## 完整示例：回显服务器

此示例演示了一个简单的 UDP 回显服务器和一个发送消息并接收回显的客户端。这展示了两种套接字类型。

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- 1. 创建一个绑定到地址的服务器套接字。
local server_fd, err = udp.bind("127.0.0.1:9989")
assert(server_fd, err)

-- 2. 派生一个协程来处理传入的数据包。
wg:fork(function()
    -- 5. 等待来自任何来源的数据包。
    local data, addr = udp.recvfrom(server_fd)
    if not data then
        print("Server recv error:", addr)
        return
    end
    print("Server received '"..data.."' from", addr)

    -- 6. 将数据回显给原始发送方。
    udp.sendto(server_fd, data, addr)
end)

-- 派生客户端协程
wg:fork(function()
    -- 给服务器一点启动时间。
    time.sleep(100)

    -- 3. 创建一个连接到服务器的客户端套接字。
    local client_fd, cerr = udp.connect("127.0.0.1:9989")
    assert(client_fd, cerr)

    -- 4. 发送一条消息。因为套接字是"连接的"，所以 sendto 不需要地址。
    local msg = "Hello, UDP!"
    print("Client sending '"..msg.."'")
    udp.sendto(client_fd, msg)

    -- 7. 等待回显。
    local data, addr = udp.recvfrom(client_fd)
    if data then
        print("Client received '"..data.."' from", addr)
        assert(data == msg)
    end

    -- 8. 清理客户端。
    udp.close(client_fd)
end)

wg:wait() -- 等待服务器和客户端协程完成
udp.close(server_fd) -- 清理服务器
```

---

## API 参考

### 套接字创建

#### `udp.bind(address)`
创建一个 UDP 套接字并将其绑定到本地地址。这通常用于服务器。

- **参数**:
  - `address` (`string`): 要绑定的地址，格式：`"IP:PORT"`
    - IPv4: `"127.0.0.1:8080"` 或 `":8080"` (监听所有接口)
    - IPv6: `"[::1]:8080"` 或 `"[::]:8080"` (监听所有接口)
- **返回值**: 成功时返回文件描述符 (`fd`)，失败时返回 `nil, error`
- **示例**:
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
创建一个 UDP 套接字并为出站数据包设置默认目标地址。这通常用于客户端。

- **参数**:
  - `address` (`string`): 默认目标地址，例如 `"127.0.0.1:8080"`
  - `bind_address` (`string`, 可选): 用于绑定客户端套接字的本地地址
- **返回值**: 成功时返回文件描述符 (`fd`)，失败时返回 `nil, error`
- **注意**: "连接"的 UDP 套接字仍然是无连接的，只是设置了默认目标地址
- **示例**:
```lua validate
local udp = require "silly.net.udp"

local fd, err = udp.connect("127.0.0.1:8989")
if not fd then
    print("Connect failed:", err)
else
    print("Connected to server, fd:", fd)
end
```

### 发送和接收

#### `udp.sendto(fd, data, [address])`
发送一个数据报。

- **参数**:
  - `fd` (`integer`): UDP 套接字的文件描述符
  - `data` (`string | table`): 要发送的数据包内容
    - `string`: 直接发送字符串
    - `table`: 多个字符串片段的数组，会自动拼接
  - `address` (`string`, 可选): 目标地址
    - 对于 `bind` 创建的套接字：**必需**
    - 对于 `connect` 创建的套接字：可选（省略则使用默认地址）
- **返回值**: 成功时返回 `true`，失败时返回 `false, error`
- **示例**:
```lua validate
local udp = require "silly.net.udp"

-- bind 套接字需要指定地址
local server_fd = udp.bind(":9001")
udp.sendto(server_fd, "Hello", "127.0.0.1:8080")

-- connect 套接字可以省略地址
local client_fd = udp.connect("127.0.0.1:9001")
udp.sendto(client_fd, "Hi there")

-- 发送多个片段
udp.sendto(client_fd, {"Header: ", "Value\n", "Body"})
```

#### `udp.recvfrom(fd)`
异步等待并接收单个数据报。

- **参数**:
  - `fd` (`integer`): 文件描述符
- **返回值**:
  - 成功时: `data, address`
    - `data` (`string`): 数据包内容
    - `address` (`string`): 发送方的地址（格式：`"IP:PORT"`）
  - 失败时: `nil, error`
- **注意**: 这是一个异步函数，会暂停当前协程直到收到数据
- **示例**:
```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"

local fd = udp.bind(":9002")

silly.fork(function()
    while true do
        local data, addr = udp.recvfrom(fd)
        if not data then
            print("Recv error:", addr)
            break
        end
        print("Received", #data, "bytes from", addr)
        -- 回显数据
        udp.sendto(fd, data, addr)
    end
end)
```

### 管理

#### `udp.close(fd)`
关闭一个 UDP 套接字。

- **参数**:
  - `fd` (`integer`): 要关闭的套接字的文件描述符
- **返回值**: 成功时返回 `true`，如果套接字已关闭则返回 `false, error`
- **注意**: 关闭套接字会唤醒所有等待 `recvfrom` 的协程，并返回错误
- **示例**:
```lua validate
local udp = require "silly.net.udp"

local fd = udp.bind(":9003")
local ok, err = udp.close(fd)
if not ok then
    print("Close failed:", err)
end
```

#### `udp.sendsize(fd)`
获取当前发送缓冲区中保存的数据量。

- **参数**:
  - `fd` (`integer`): 文件描述符
- **返回值**: `integer` - 发送缓冲区中的字节数
- **用途**: 监控网络拥塞，实现流控
- **示例**:
```lua validate
local udp = require "silly.net.udp"

local fd = udp.connect("127.0.0.1:9004")
udp.sendto(fd, "data")
local pending = udp.sendsize(fd)
print("Pending bytes:", pending)
```

#### `udp.isalive(fd)`
检查套接字是否仍被认为是活动的。

- **参数**:
  - `fd` (`integer`): 文件描述符
- **返回值**: `boolean` - 如果套接字已打开且未遇到错误，则返回 `true`，否则返回 `false`
- **示例**:
```lua validate
local udp = require "silly.net.udp"

local fd = udp.bind(":9005")
print("Socket alive:", udp.isalive(fd))
udp.close(fd)
print("Socket alive:", udp.isalive(fd))
```

---

## 使用示例

### 示例1：简单的 UDP 服务器

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"

local fd = udp.bind(":8989")
print("UDP server listening on port 8989")

silly.fork(function()
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

### 示例2：UDP 客户端

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local time = require "silly.time"

local fd, err = udp.connect("127.0.0.1:8989")
if not fd then
    print("Connect error:", err)
    return
end

silly.fork(function()
    -- 发送多条消息
    for i = 1, 5 do
        local msg = "Message " .. i
        udp.sendto(fd, msg)
        print("Sent:", msg)
        local data, addr = udp.recvfrom(fd)
        if not data then
            print("No response for message", i)
        end
        time.sleep(500) -- 消息间隔
    end
    udp.close(fd)
end)
```

### 示例3：广播消息

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- 接收方1
wg:fork(function()
    local fd = udp.bind("127.0.0.1:9001")
    local data, addr = udp.recvfrom(fd)
    print("Receiver 1 got:", data, "from", addr)
    udp.close(fd)
end)

-- 接收方2
wg:fork(function()
    local fd = udp.bind("127.0.0.1:9002")
    local data, addr = udp.recvfrom(fd)
    print("Receiver 2 got:", data, "from", addr)
    udp.close(fd)
end)

-- 发送方（广播到多个接收方）
wg:fork(function()
    local fd = udp.bind(":0") -- 绑定到任意端口
    local msg = "Broadcast message"

    udp.sendto(fd, msg, "127.0.0.1:9001")
    udp.sendto(fd, msg, "127.0.0.1:9002")

    print("Broadcast sent to 2 receivers")
    udp.close(fd)
end)

wg:wait()
```

### 示例4：心跳检测

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- 心跳服务器
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

-- 心跳客户端
wg:fork(function()
    time.sleep(50) -- 等待服务器启动

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

## 注意事项

### 1. 数据包大小限制

UDP 数据包受 MTU（最大传输单元）限制：
- **以太网 MTU**: 通常为 1500 字节
- **安全大小**: 建议不超过 1472 字节（1500 - 20 IP 头 - 8 UDP 头）
- **超过 MTU**: 会导致 IP 分片，增加丢包风险

```lua validate
local udp = require "silly.net.udp"

local fd = udp.bind(":9020")

-- 好的做法：小数据包
udp.sendto(fd, string.rep("x", 1000), "127.0.0.1:9020")

-- 不推荐：大数据包（可能分片）
udp.sendto(fd, string.rep("x", 10000), "127.0.0.1:9020")
```

### 2. 无序和丢包

UDP 不保证数据包顺序和到达，需要应用层处理：

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"

local fd = udp.bind(":9021")

silly.fork(function()
    local sequence = {}
    for i = 1, 10 do
        local data, addr = udp.recvfrom(fd)
        if data then
            local seq = tonumber(data:match("SEQ:(%d+)"))
            sequence[#sequence + 1] = seq
        end
    end
    -- 检查是否按序到达
    print("Received sequence:", table.concat(sequence, ","))
end)
```

### 3. 缓冲区溢出

快速发送可能导致缓冲区满：

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

### 4. 地址格式

确保地址格式正确：

```lua validate
local udp = require "silly.net.udp"

-- 正确的格式
local fd1 = udp.bind("127.0.0.1:8080")  -- IPv4
local fd2 = udp.bind("[::1]:8081")      -- IPv6
local fd3 = udp.bind(":8082")           -- 所有接口 (IPv4)

-- 错误的格式（会失败）
-- local fd4 = udp.bind("localhost:8080")  -- 需要IP地址
-- local fd5 = udp.bind("8080")            -- 缺少冒号
```

### 5. 资源清理

总是记得关闭套接字：

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"

silly.fork(function()
    local fd = udp.bind(":9030")
    -- ... 使用套接字 ...
    udp.close(fd)  -- 确保清理
end)
```

---

## 性能建议

### 1. 批量发送

减少系统调用次数：

```lua validate
local udp = require "silly.net.udp"

local fd = udp.connect("127.0.0.1:9040")

-- 使用表批量发送
udp.sendto(fd, {
    "header1\n",
    "header2\n",
    "body content"
})
```

### 2. 监控缓冲区

避免发送缓冲区溢出：

```lua validate
local udp = require "silly.net.udp"

local fd = udp.connect("127.0.0.1:9041")

local function safe_send(data)
    local buffer_size = udp.sendsize(fd)
    if buffer_size > 1024 * 1024 then  -- 1MB 阈值
        print("Warning: send buffer is", buffer_size, "bytes")
        return false
    end
    return udp.sendto(fd, data)
end
```

### 3. 合理的超时

实现应用层超时机制：

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local time = require "silly.time"

local function recv_with_timeout(fd, timeout_ms)
    local result = nil
    local task = silly.fork(function()
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

## 参见

- [silly.net.tcp](./tcp.md) - TCP 网络协议
- [silly.net.websocket](./websocket.md) - WebSocket 协议
- [silly.net.dns](./dns.md) - DNS 解析
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
