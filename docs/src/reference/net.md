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

地址字符串使用 `host:port` 形式，分隔由 `silly.net.addr.parse` 完成：

- **不带 `[...]` 方括号** —— 解析器以 **第一个** `:` 作为 host/port 分隔符。所以 `"127.0.0.1:8080"` 可以工作，但 `"::1:8080"` **不是** IPv6 回环 —— 它会被解析为 `host=""`、`port=":1:8080"`，并在后续校验中失败。
- **带 `[...]` 方括号** —— 任何含 `:` 的 IPv6 字面量都必须用方括号消歧；`]` 后必须紧跟 `:port`。

**IPv4 示例**:
- `"127.0.0.1:8080"` —— 本地回环地址
- `"0.0.0.0:9000"` —— 监听所有 IPv4 接口
- `":8080"` —— 简写：空 host + 端口 8080（监听包装层会把空 host 规范成 `0::0`，即所有接口）

**IPv6 示例**:
- `"[::1]:8080"` —— IPv6 回环（必须方括号）
- `"[::]:8080"` —— 监听所有 IPv6 接口
- `"[2001:db8::1]:443"` —— 任何含 `:` 的 IPv6 字面量都必须方括号

**域名示例**:
- `"example.com:80"`

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
- `err` (`silly.errno?`): 失败时返回的错误码

**示例**:
```lua validate
local silly = require "silly"
local task = require "silly.task"
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

### net.tcpconnect(addr, event, bind, timeout)

连接到 TCP 服务器。

**参数**:
- `addr` (string): 服务器地址
- `event` (table): 事件处理器表（同 `tcplisten`，但不需要 `accept`）
- `bind` (string, 可选): 本地绑定地址（`"ip:port"`）
- `timeout` (integer, 可选): 连接超时（毫秒）；超时时正在建立的 socket 会被关闭并返回 `errno.TIMEDOUT`

**返回值**:
- `fd` (integer): 连接的文件描述符
- `err` (`silly.errno?`): 失败时返回的错误码

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

### net.tcpsend(fd, data[, size])

向 TCP 套接字发送数据。

**参数**:
- `fd` (integer): 套接字文件描述符
- `data` (string|lightuserdata|table): 要发送的数据
  - `string` —— 直接发送，长度取 `#data`
  - `lightuserdata` —— 原始内存指针，**必须**在下一个参数传 `size`
  - `table` —— 字符串数组，按顺序拼接为单个缓冲区
- `size` (integer, 可选): 仅当 `data` 是 `lightuserdata` 时必填

**返回值**:
- `ok` (boolean): 是否成功
- `err` (`silly.errno?`): 失败时返回的错误码

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

### net.tcpmulticast(fd, ptr, size)

向单个 TCP 连接发送一个共享缓冲区（来自 `net.multipack`），过程中无拷贝。发送完成后内部会递减引用计数；当引用计数归零时缓冲区自动释放。

**参数**:
- `fd` (integer): 目标文件描述符
- `ptr` (lightuserdata): 由 `net.multipack` 返回的缓冲区
- `size` (integer): 缓冲区大小（字节）

**返回值**:
- `ok` (boolean): 是否成功入队
- `err` (`silly.errno?`): 失败时返回的错误码

::: tip 多播模式
用 `net.multipack(data, fanout)` 一次分配缓冲区（`fanout` 是预期接收者数量，作为初始引用计数），然后对每个目标 fd 调用一次 `net.tcpmulticast(fd, ptr, size)`。所有发送完成后共享缓冲区会自动释放。
:::

## UDP 函数

### net.udpbind(addr, event)

绑定 UDP 套接字到指定地址。

**参数**:
- `addr` (string): 绑定地址
- `event` (table): 事件处理器表：
  - `data` (function): `function(fd, ptr, size, addr)` - 数据接收回调（注意有 `addr` 参数）
  - `close` (function): `function(fd, errno)` - 关闭回调

（包装函数为对称性接受第三个 `backlog` 参数，但 UDP 没有监听队列，该参数会被忽略。）

**返回值**:
- `fd` (integer): UDP 套接字文件描述符
- `err` (`silly.errno?`): 失败时返回的错误码

**示例**:
```lua validate
local silly = require "silly"
local net = require "silly.net"

local udpfd = net.udpbind("[::]:9000", {
    data = function(fd, ptr, size, addr)
        local data = silly.tostring(ptr, size)
        print("UDP from", addr, ":", data)
        -- 回复客户端
        net.udpsend(fd, data, addr)
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
- `err` (`silly.errno?`): 失败时返回的错误码

### net.udpsend(fd, data, [size,] [addr])

发送 UDP 数据包。参数布局取决于 `data` 的类型：

| `data` 类型 | 调用形式 | 说明 |
|---|---|---|
| `string` | `net.udpsend(fd, str)` 或 `net.udpsend(fd, str, addr)` | 长度取 `#str`；只有未连接的 socket 需要 `addr` |
| `table`（字符串数组） | `net.udpsend(fd, tbl)` 或 `net.udpsend(fd, tbl, addr)` | 字符串按顺序拼接 |
| `lightuserdata` | `net.udpsend(fd, ptr, size)` 或 `net.udpsend(fd, ptr, size, addr)` | 发送原始指针时 `size` **必填** |

**返回值**:
- `ok` (boolean): 是否成功
- `err` (`silly.errno?`): 失败时返回的错误码

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
- `err` (`silly.errno?`): 失败时返回的错误码

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
事件回调函数虽然在协程中执行，但 `ptr` 指针仅在回调同步执行期间有效。一旦回调 yield 或返回，`ptr` 指向的内存可能被释放。因此，**必须在 yield 之前将数据复制为字符串**。
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
- `errno` (`silly.errno`): 连接关闭原因。对端正常关闭时通常为 `errno.EOF`，其他情况为对应的底层错误

## 注意事项

### 1. 事件驱动模型

`silly.net` 使用事件驱动模型，所有 I/O 操作通过回调处理：

```lua validate
local silly = require "silly"
local task = require "silly.task"
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

-- 正确：先复制数据，再在 fork 中处理
local fd2 = net.tcplisten("[::]:8081", {
    data = function(fd, ptr, size)
        local data = silly.tostring(ptr, size) -- 立即复制数据
        task.fork(function()
            -- 现在可以使用异步函数处理 data (string)
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
    task.fork(function()
        local str = silly.tostring(ptr, size) -- ptr 已失效！
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

任何含 `:` 的 IPv6 字面量都必须用 `[IP]:Port` 形式包起来。解析器以 **方括号外的第一个** `:` 作为 host/port 分隔符，所以 `"::1:8080"` 和 `"::1"` 都不是有效的 IPv6 地址：

- IPv4: `"192.168.1.1:8080"`
- IPv6: `"[2001:db8::1]:8080"`（必须方括号）
- 简写: `":8080"` —— 空 host + 端口；监听包装层会把空 host 转换成 `0::0`（同时监听 IPv4/IPv6 所有接口）

## 高级用法

### 自定义协议解析

由于 `net` 模块的 `data` 回调接收的是原始数据指针，需要使用 `silly.adt.buffer` 来管理接收缓冲区：

```lua validate
local silly = require "silly"
local net = require "silly.net"
local buffer = require "silly.adt.buffer"

local buffers = {}

local listenfd = net.tcplisten("[::]:8080", {
    accept = function(fd, listenid, addr)
        buffers[fd] = buffer.new()
    end,
    data = function(fd, ptr, size)
        local buf = buffers[fd]
        if not buf then return end

        buffer.append(buf, ptr, size)

        -- 解析行协议
        while true do
            local line = buffer.read(buf, "\n")
            if not line then break end

            -- 处理一行数据
            print("Line:", line)
        end
    end,
    close = function(fd, errno)
        if buffers[fd] then
            buffer.clear(buffers[fd])
            buffers[fd] = nil
        end
    end,
})
```

::: tip
如果需要更方便的高级 API（如 `read(n)` 或 `read("\n")`），推荐使用 [silly.net.tcp](./net/tcp.md) 或 [silly.net.tls](./net/tls.md) 模块，它们内置了缓冲区管理。
:::

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
- [silly](./silly.md) - 核心模块
