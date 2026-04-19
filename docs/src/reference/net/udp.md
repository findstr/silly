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

`silly.net.udp` 模块为 UDP（用户数据报协议）提供高层异步 API。UDP 无连接、面向报文，收发都以独立数据报为单位。

## 模块导入

```lua validate
local udp = require "silly.net.udp"
```

---

## 核心概念

与 TCP 不同，UDP 不建立长连接，每个数据报独立发送。`conn:recvfrom` 是异步的：数据报未到时挂起当前协程，到达后恢复并返回数据与发送方地址。

有两种方式创建 UDP socket：

1. **`udp.bind(address)`**：创建「服务端」socket，绑定到指定地址，可接收来自任意对端的包；发送时需通过 `conn:sendto` 传入目标地址。
2. **`udp.connect(address)`**：创建「客户端」socket，记录默认目标地址，发送时可省略地址。

两者都返回 `silly.net.udp.conn` 对象，后续收发/关闭全部作为对象方法调用。

---

## UDP vs TCP

**UDP 特性:**
- **无连接**: 无握手，包直接发送
- **不可靠**: 可能丢失、重复或乱序
- **轻量**: 协议开销低、延迟低
- **面向报文**: 保留消息边界

**适用场景:**
- 实时游戏（位置同步、状态更新）
- DNS 查询
- 音视频流（容忍丢包）
- 局域网服务发现
- 日志上报（容忍丢包）

**不适合:**
- 文件传输（需要可靠性）
- HTTP/HTTPS（需要有序）
- 数据库连接（需要事务）

---

## 完整示例: 回显服务器

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- 创建绑定了本地地址的服务端 socket
local server, err = udp.bind("127.0.0.1:9989")
assert(server, err)

-- 处理到来的数据报
wg:fork(function()
    local data, addr = server:recvfrom()
    if not data then
        print("Server recv error:", addr)  -- 出错时第二个返回值是 silly.errno
        return
    end
    print("Server received '"..data.."' from", addr)

    server:sendto(data, addr)
end)

-- 客户端协程
wg:fork(function()
    time.sleep(100)

    local client, cerr = udp.connect("127.0.0.1:9989")
    assert(client, cerr)

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

## API 参考

### Socket 创建

#### `udp.bind(address)`

创建绑定了本地地址的 UDP socket，通常用于服务端。

- **参数**:
  - `address` (`string`): 待绑定地址，格式 `"IP:PORT"`
    - IPv4: `"127.0.0.1:8080"` 或 `":8080"`（所有接口）
    - IPv6: `"[::1]:8080"` 或 `"[::]:8080"`（所有接口）
- **返回值**:
  - 成功: `silly.net.udp.conn`
  - 失败: `nil, silly.errno` - 见 [silly.errno](../errno.md)

```lua validate
local udp = require "silly.net.udp"

local sock, err = udp.bind("127.0.0.1:8989")
if not sock then
    print("Bind failed:", err)
else
    print("绑定到 8989")
end
```

#### `udp.connect(address [, opts])`

创建 UDP socket 并记录默认目标地址，通常用于客户端。

- **参数**:
  - `address` (`string`): 默认目标地址，例如 `"127.0.0.1:8080"`
  - `opts` (`table|nil`, 可选):
    - `bindaddr` (`string|nil`): 客户端本地绑定地址
- **返回值**:
  - 成功: `silly.net.udp.conn`
  - 失败: `nil, silly.errno`
- **说明**: 「connected」UDP socket 仍是无连接的，`connect` 只是记录默认目标。

```lua validate
local udp = require "silly.net.udp"

local sock, err = udp.connect("127.0.0.1:8989")
if not sock then
    print("Connect failed:", err)
else
    print("已连接")
end
```

### 收发

#### `conn:sendto(data [, address])`

发送一个数据报。

- **参数**:
  - `data` (`string | string[]`): 要发送的内容；若传数组，各片段零拷贝拼接
  - `address` (`string|nil`): 目标地址
    - `udp.bind` 创建的 socket: **必填**
    - `udp.connect` 创建的 socket: 可选（省略则使用默认地址）
- **返回值**:
  - 成功: `true`
  - 失败: `false, silly.errno`
- **不会 yield。**

```lua validate
local udp = require "silly.net.udp"

-- 绑定的 socket：必须传目标
local server = udp.bind(":9001")
server:sendto("Hello", "127.0.0.1:8080")

-- connect 的 socket：可省略目标
local client = udp.connect("127.0.0.1:9001")
client:sendto("Hi there")

-- 批量发送
client:sendto({"Header: ", "Value\n", "Body"})
```

#### `conn:recvfrom([timeout])`

异步等待并接收一个数据报。

- **参数**:
  - `timeout` (`integer|nil`): 单次调用超时（毫秒）
- **返回值**:
  - 成功: `data, address`
    - `data` (`string`): 载荷
    - `address` (`string`): 发送方地址，格式 `"IP:PORT"`
  - 失败: `nil, silly.errno` - 例如 `timeout` 触发时为 `errno.TIMEDOUT`，套接字已关闭时为 `errno.CLOSED`
- **异步**: 数据未就绪时挂起协程，直到数据到达、超时触发或 socket 关闭。

```lua validate
local silly = require "silly"
local task = require "silly.task"
local udp = require "silly.net.udp"

local sock = udp.bind(":9002")

task.fork(function()
    while true do
        local data, addr = sock:recvfrom()
        if not data then
            print("Recv error:", addr)  -- 出错时第二个返回值是 errno
            break
        end
        print("收到", #data, "bytes 来自", addr)
        sock:sendto(data, addr)
    end
end)
```

### 管理

#### `conn:close()`

关闭 UDP socket。

- **返回值**: 成功 `true`；若已关闭则 `false, silly.errno`。
- **说明**: 关闭时，所有正在 `recvfrom` 阻塞的协程会被唤醒并返回错误。

#### `conn:isalive()`

socket 仍然打开且未记录错误时返回 `true`。

#### `conn:unsentbytes()`

返回内核发送缓冲区中尚未发出的字节数，用于监控背压。

#### `conn:unreadbytes()`

返回本地已排队但尚未通过 `recvfrom` 消费的字节总数。

#### `conn.fd`

只读整数 fd。调用 `close` 之后被置为 `nil`。

---

## 使用示例

### 示例 1: 简单 UDP 服务器

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

### 示例 2: 带超时的 UDP 客户端

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

        local data, e = sock:recvfrom(500)  -- 500 ms 超时
        if not data then
            if e == errno.TIMEDOUT then
                print("第", i, "条消息无响应（超时）")
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

### 示例 3: 广播

```lua validate
local silly = require "silly"
local udp = require "silly.net.udp"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- 接收端 1
wg:fork(function()
    local sock = udp.bind("127.0.0.1:9001")
    local data, addr = sock:recvfrom()
    print("Receiver 1 got:", data, "from", addr)
    sock:close()
end)

-- 接收端 2
wg:fork(function()
    local sock = udp.bind("127.0.0.1:9002")
    local data, addr = sock:recvfrom()
    print("Receiver 2 got:", data, "from", addr)
    sock:close()
end)

-- 发送端（向多个接收端广播）
wg:fork(function()
    local sock = udp.bind(":0")  -- 绑定任意端口
    local msg = "Broadcast message"

    sock:sendto(msg, "127.0.0.1:9001")
    sock:sendto(msg, "127.0.0.1:9002")

    print("已广播给 2 个接收端")
    sock:close()
end)

wg:wait()
```

---

## 注意事项

### 1. 报文大小上限

UDP 载荷受路径 MTU 限制（以太网常见 1500 字节）。安全上限约 1472 字节（1500 − 20 IP − 8 UDP）。超过会触发 IP 分片，提升丢包概率。

### 2. 丢包与乱序

UDP 不保证顺序与到达。若协议需要，请在用户态加序号、重传、可靠性逻辑。

### 3. 地址格式

必须使用 `"IP:PORT"`：

```lua validate
local udp = require "silly.net.udp"

local ok1 = udp.bind("127.0.0.1:8080")  -- IPv4
local ok2 = udp.bind("[::1]:8081")      -- IPv6
local ok3 = udp.bind(":8082")           -- 所有接口（IPv4）

-- 以下会失败：
-- udp.bind("localhost:8080")  -- 必须是 IP 字面量
-- udp.bind("8080")            -- 缺 :
```

### 4. 资源清理

记得关闭 socket。对象也有 GC 终结器兜底，但依赖它会延迟释放。

---

## 参见

- [silly.net.tcp](./tcp.md) - TCP 协议
- [silly.net.websocket](./websocket.md) - WebSocket 协议
- [silly.net.dns](./dns.md) - DNS 解析
- [silly.errno](../errno.md) - 传输层错误码
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
