---
title: silly.net
icon: network-wired
category:
  - API参考
tag:
  - 网络
  - Socket
  - 底层API
---

# silly.net

`silly.net` 是 Silly 框架的底层网络模块，提供基础的 TCP/UDP socket 操作。它是 `silly.net.tcp`、`silly.net.udp` 等高级模块的基础。

::: warning 使用建议
对于大多数应用场景，建议使用更高级的模块如 [silly.net.tcp](./net/tcp.md) 或 [silly.net.udp](./net/udp.md)。`silly.net` 模块提供的是底层 API，需要手动管理回调和事件。
:::

## 模块导入

```lua validate
local net = require "silly.net"
```

## 地址格式

所有网络地址使用统一的格式：`"[IP]:Port"`

**IPv4 示例**:
- `"127.0.0.1:8080"` - 本地回环地址
- `"0.0.0.0:9000"` - 监听所有接口
- `":8080"` - 简写形式，等同于 `"0.0.0.0:8080"`

**IPv6 示例**:
- `"[::1]:8080"` - IPv6 本地回环
- `"[2001:db8::1]:9000"` - IPv6 地址
- `"[::]:8080"` - 监听所有 IPv6 接口

## TCP 函数

### net.tcplisten(addr, event, backlog)

在指定地址上创建 TCP 监听器。

**参数**:
- `addr` (string): 监听地址，格式为 `"[IP]:Port"`
- `event` (table): 事件处理器表，包含以下字段：
  - `accept` (function, 可选): `function(fd, listenid, addr)` - 新连接回调
  - `data` (function): `function(fd, ptr, size)` - 数据接收回调
  - `close` (function): `function(fd, errno)` - 连接关闭回调
- `backlog` (integer, 可选): 监听队列大小，默认 256

**返回值**:
- `fd` (integer): 监听套接字文件描述符
- `err` (string): 错误信息（失败时）

**示例**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

local listenfd = net.tcplisten("[::]:8080", {
    accept = function(fd, listenid, addr)
        print("New connection from:", addr)
    end,
    data = function(fd, ptr, size)
        local data = silly.tostring(ptr, size)
        print("Received:", data)
    end,
    close = function(fd, errno)
        print("Connection closed:", fd, errno)
    end,
})

if listenfd then
    print("Listening on port 8080")
end
```

### net.tcpconnect(addr, event, bind)

连接到 TCP 服务器。

**参数**:
- `addr` (string): 服务器地址
- `event` (table): 事件处理器表（同 `tcplisten`，但不需要 `accept`）
- `bind` (string, 可选): 本地绑定地址

**返回值**:
- `fd` (integer): 连接的文件描述符
- `err` (string): 错误信息（失败时）

**示例**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

local fd = net.tcpconnect("127.0.0.1:8080", {
    data = function(fd, ptr, size)
        local data = silly.tostring(ptr, size)
        print("Received:", data)
    end,
    close = function(fd, errno)
        print("Disconnected:", errno)
    end,
})

if fd then
    net.tcpsend(fd, "Hello, Server!\n")
end
```

### net.tcpsend(fd, data, size)

向 TCP 套接字发送数据。

**参数**:
- `fd` (integer): 套接字文件描述符
- `data` (string|lightuserdata|table): 要发送的数据
  - `string`: 直接发送字符串
  - `lightuserdata`: 发送原始内存指针（需指定 `size`）
  - `table`: 发送字符串表（批量发送）
- `size` (integer, 可选): 数据大小（`lightuserdata` 时必需）

**返回值**:
- `ok` (boolean): 是否成功
- `err` (string): 错误信息（失败时）

**示例**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

-- 假设 fd 是已连接的套接字
local fd = 1

-- 发送字符串
net.tcpsend(fd, "Hello\n")

-- 发送多个字符串
net.tcpsend(fd, {"Line 1\n", "Line 2\n", "Line 3\n"})
```

### net.tcpmulticast(fd, data, size, addr)

向多个 TCP 连接广播数据。

**参数**:
- `fd` (integer): 起始文件描述符（实际上是一个占位符）
- `data` (lightuserdata): 数据指针
- `size` (integer): 数据大小
- `addr` (string, 可选): 目标地址过滤

**返回值**:
- `ok` (boolean): 是否成功
- `err` (string): 错误信息

::: tip 高级功能
此函数用于高效地向多个连接发送相同的数据，内部使用零拷贝技术。
:::

## UDP 函数

### net.udpbind(addr, event, backlog)

绑定 UDP 套接字到指定地址。

**参数**:
- `addr` (string): 绑定地址
- `event` (table): 事件处理器表：
  - `data` (function): `function(fd, ptr, size, addr)` - 数据接收回调（注意有 `addr` 参数）
  - `close` (function): `function(fd, errno)` - 关闭回调
- `backlog` (integer, 可选): 未使用（UDP 没有监听队列）

**返回值**:
- `fd` (integer): UDP 套接字文件描述符
- `err` (string): 错误信息

**示例**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

local udpfd = net.udpbind("[::]:9000", {
    data = function(fd, ptr, size, addr)
        local data = silly.tostring(ptr, size)
        print("UDP from", addr, ":", data)
        -- 回复客户端
        net.udpsend(fd, data, size, addr)
    end,
    close = function(fd, errno)
        print("UDP closed:", errno)
    end,
})
```

### net.udpconnect(addr, event, bind)

连接到 UDP 服务器（伪连接，仅设置默认目标地址）。

**参数**:
- `addr` (string): 服务器地址
- `event` (table): 事件处理器表
- `bind` (string, 可选): 本地绑定地址

**返回值**:
- `fd` (integer): UDP 套接字文件描述符
- `err` (string): 错误信息

### net.udpsend(fd, data, size_or_addr, addr)

发送 UDP 数据包。

**参数**:
- `fd` (integer): UDP 套接字文件描述符
- `data` (string|lightuserdata|table): 要发送的数据
- `size_or_addr` (integer|string, 可选):
  - 如果 `data` 是 `lightuserdata`，这是数据大小
  - 如果 `data` 是字符串且套接字未连接，这是目标地址
- `addr` (string, 可选): 目标地址（当第三参数是 size 时使用）

**返回值**:
- `ok` (boolean): 是否成功
- `err` (string): 错误信息

**示例**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

-- 假设 fd 是已连接或绑定的 UDP 套接字
local fd = 1

-- 已连接的 UDP 套接字
net.udpsend(fd, "Hello UDP\n")

-- 未连接的 UDP 套接字，指定目标地址
net.udpsend(fd, "Hello\n", "127.0.0.1:9000")
```

## 通用函数

### net.close(fd)

关闭网络套接字。

**参数**:
- `fd` (integer): 套接字文件描述符

**返回值**:
- `ok` (boolean): 是否成功
- `err` (string): 错误信息

**示例**:
```lua validate
local net = require "silly.net"

-- 假设 fd 是已打开的套接字
local fd = 1

local ok, err = net.close(fd)
if not ok then
    print("Close error:", err)
end
```

### net.sendsize(fd)

获取发送缓冲区大小。

**参数**:
- `fd` (integer): 套接字文件描述符

**返回值**:
- `size` (integer): 发送缓冲区中的字节数

**示例**:
```lua validate
local net = require "silly.net"

-- 假设 fd 是已连接的套接字
local fd = 1

local pending = net.sendsize(fd)
if pending > 1024 * 1024 then
    print("Warning: send buffer is large")
end
```

## 事件处理

### accept 回调

在新的 TCP 连接建立时调用。

**参数**:
- `fd` (integer): 新连接的文件描述符
- `listenid` (integer): 监听套接字的文件描述符
- `addr` (string): 客户端地址

::: warning 回调限制
事件回调函数**不能 yield**（调用会挂起的异步函数）。如果需要执行异步操作，应使用 `silly.fork()` 创建新协程。
:::

### data 回调

接收到数据时调用。

**TCP 参数**:
- `fd` (integer): 连接的文件描述符
- `ptr` (lightuserdata): 数据指针
- `size` (integer): 数据大小

**UDP 参数**:
- `fd` (integer): UDP 套接字文件描述符
- `ptr` (lightuserdata): 数据指针
- `size` (integer): 数据大小
- `addr` (string): 发送方地址

::: tip 数据生命周期
`ptr` 指针仅在回调函数执行期间有效。如果需要保存数据，必须使用 `silly.tostring()` 复制它。
:::

### close 回调

连接关闭时调用。

**参数**:
- `fd` (integer): 套接字文件描述符
- `errno` (integer): 错误码（0 表示正常关闭）

## 注意事项

### 1. 事件驱动模型

`silly.net` 使用事件驱动模型，所有 I/O 操作通过回调处理：

```lua validate
local silly = require "silly"
local net = require "silly.net"

-- 错误：回调中不能 yield
local fd = net.tcplisten("[::]:8080", {
    data = function(fd, ptr, size)
        -- silly.wait() -- ❌ 这会导致错误
        local data = silly.tostring(ptr, size)
        net.tcpsend(fd, data) -- ✓ 同步操作可以
    end,
    close = function(fd, errno) end,
})

-- 正确：使用 fork 创建新协程处理异步操作
local fd2 = net.tcplisten("[::]:8081", {
    data = function(fd, ptr, size)
        silly.fork(function()
            local data = silly.tostring(ptr, size)
            -- 现在可以使用异步函数了
            -- process_async(data)
            net.tcpsend(fd, "OK\n")
        end)
    end,
    close = function(fd, errno) end,
})
```

### 2. 内存管理

接收到的数据指针 (`lightuserdata`) 必须及时转换为字符串：

```lua
data = function(fd, ptr, size)
    -- ✓ 正确：立即复制
    local str = silly.tostring(ptr, size)

    -- ❌ 错误：ptr 离开回调后失效
    silly.fork(function()
        local str = silly.tostring(ptr, size) -- ptr 已失效
    end)
end
```

### 3. 文件描述符复用

文件描述符可能会被操作系统复用，不要在回调外保存 `fd` 并长期使用：

```lua
local saved_fd

-- ❌ 危险：fd 可能已经关闭并被复用
data = function(fd, ptr, size)
    saved_fd = fd
end

-- 稍后...
net.tcpsend(saved_fd, "data") -- saved_fd 可能已指向其他连接
```

### 4. IPv6 支持

地址格式严格遵循 `[IP]:Port` 格式：
- IPv4: `"192.168.1.1:8080"`
- IPv6: `"[2001:db8::1]:8080"` （方括号必需）
- 简写: `":8080"` 自动选择 IPv4 或 IPv6

## 高级用法

### 自定义协议解析

结合 `silly.netstream` 和 `silly.netpacket` 实现自定义协议：

```lua validate
local silly = require "silly"
local net = require "silly.net"
local netstream = require "silly.netstream"

local streams = {}

local listenfd = net.tcplisten("[::]:8080", {
    accept = function(fd, listenid, addr)
        streams[fd] = netstream.new(fd)
    end,
    data = function(fd, ptr, size)
        local stream = streams[fd]
        if not stream then return end

        netstream.push(stream, ptr, size)

        -- 解析行协议
        while true do
            local line = netstream.readline(stream, "\n")
            if not line then break end

            -- 处理一行数据
            print("Line:", line)
        end
    end,
    close = function(fd, errno)
        if streams[fd] then
            netstream.free(streams[fd])
            streams[fd] = nil
        end
    end,
})
```

## 性能考虑

### 批量发送

使用表批量发送可减少系统调用：

```lua
-- 单次发送多个消息
net.tcpsend(fd, {
    "Message 1\n",
    "Message 2\n",
    "Message 3\n",
})
```

### 避免频繁关闭

频繁创建/销毁连接会影响性能，考虑使用连接池。

## 参见

- [silly.net.tcp](./net/tcp.md) - 高级 TCP API（推荐使用）
- [silly.net.udp](./net/udp.md) - 高级 UDP API（推荐使用）
- [silly](./silly.md) - 核心调度器
