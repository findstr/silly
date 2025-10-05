---
title: silly.net.tcp
icon: network-wired
category:
  - API参考
tag:
  - 网络
  - TCP
  - 协议
---

# silly.net.tcp

`silly.net.tcp` 模块提供了一个用于处理 TCP 网络连接的高级异步 API。它基于协程构建，允许使用清晰的、顺序风格的代码，而无需为读取操作使用回调。TCP 是一种面向连接的、可靠的、基于字节流的传输层协议。

## 模块导入

```lua validate
local tcp = require "silly.net.tcp"
```

## 核心概念

### 异步操作

从套接字读取数据的函数，例如 `tcp.read` 和 `tcp.readline`，是**异步的**。这意味着如果数据没有立即可用，它们将暂停当前协程的执行，并在数据到达后恢复执行。这使得单线程的 Silly 服务能够高效地处理许多并发连接。

### 面向连接

TCP 是面向连接的协议，这意味着在数据传输之前必须先建立连接。连接建立后，数据将按顺序可靠地传输，并保证到达顺序与发送顺序一致。

## API 文档

### tcp.listen(addr, disp [, backlog])

启动一个 TCP 服务器在给定地址上进行监听。

- **参数**:
  - `addr`: `string` - 监听的地址，例如 `"127.0.0.1:8080"` 或 `":8080"`
  - `disp`: `async fun(fd: integer, addr: string)` - 连接回调函数，为每个新的客户端连接执行
    - `fd`: 新连接的文件描述符
    - `addr`: 客户端的地址字符串
  - `backlog`: `integer|nil` (可选) - 等待连接队列的最大长度
- **返回值**:
  - 成功: `integer` - 监听器文件描述符 (`listenfd`)
  - 失败: `nil, string` - nil 和错误信息
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local listenfd, err = tcp.listen("127.0.0.1:8080", function(fd, addr)
    print("New connection from:", addr)
    -- 处理连接...
    tcp.close(fd)
end)

if not listenfd then
    print("Listen failed:", err)
end
```

### tcp.connect(ip [, bind])

建立到 TCP 服务器的连接（异步）。

- **参数**:
  - `ip`: `string` - 要连接的服务器地址，例如 `"127.0.0.1:8080"`
  - `bind`: `string|nil` (可选) - 用于绑定客户端套接字的本地地址
- **返回值**:
  - 成功: `integer` - 连接的文件描述符 (`fd`)
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 此函数是异步的，会等待连接建立
- **注意**: 此函数不支持超时参数，如需超时控制，请使用 `silly.time.after()` 配合使用
- **示例**:

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"

silly.fork(function()
    local fd, err = tcp.connect("127.0.0.1:8080")
    if not fd then
        print("Connect failed:", err)
        return
    end
    print("Connected! fd:", fd)
    tcp.close(fd)
end)
```

### tcp.close(fd)

关闭一个 TCP 连接或监听器。

- **参数**:
  - `fd`: `integer` - 要关闭的套接字的文件描述符
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息（如果套接字已关闭或无效）
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local ok, err = tcp.close(fd)
if not ok then
    print("Close failed:", err)
end
```

### tcp.write(fd, data)

将数据写入套接字。从用户的角度来看，此操作是非阻塞的；数据由框架缓冲和发送。

- **参数**:
  - `fd`: `integer` - 套接字的文件描述符
  - `data`: `string|table` - 要发送的数据，可以是字符串或字符串表
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

-- 发送字符串
tcp.write(fd, "Hello, World!\n")

-- 发送多个字符串（零拷贝）
tcp.write(fd, {"HTTP/1.1 200 OK\r\n", "Content-Length: 5\r\n\r\n", "Hello"})
```

### tcp.read(fd, n)

从套接字精确读取 `n` 个字节（异步）。

- **参数**:
  - `fd`: `integer` - 文件描述符
  - `n`: `integer` - 要读取的字节数
- **返回值**:
  - 成功: `string` - 包含 `n` 字节的字符串
  - 失败: `nil, string` - nil 和错误信息（连接关闭或发生错误）
- **异步**: 如果数据不足，会挂起协程直到数据到达
- **示例**:

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"

silly.fork(function()
    local fd, err = tcp.connect("127.0.0.1:8080")
    if not fd then
        return
    end

    -- 读取4字节的消息头
    local header, err = tcp.read(fd, 4)
    if not header then
        print("Read failed:", err)
        tcp.close(fd)
        return
    end

    print("Header:", header)
    tcp.close(fd)
end)
```

### tcp.readline(fd [, delim])

从套接字读取直到找到特定的分隔符（异步）。

- **参数**:
  - `fd`: `integer` - 文件描述符
  - `delim`: `string|nil` (可选) - 分隔符，默认为 `"\n"`
- **返回值**:
  - 成功: `string` - 一行文本（包括分隔符）
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 如果分隔符未找到，会挂起协程直到收到完整的行
- **示例**:

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"

silly.fork(function()
    local fd, err = tcp.connect("127.0.0.1:8080")
    if not fd then
        return
    end

    -- 读取一行（以\n结尾）
    local line, err = tcp.readline(fd)
    if not line then
        print("Readline failed:", err)
        tcp.close(fd)
        return
    end

    print("Received line:", line)
    tcp.close(fd)
end)
```

### tcp.readall(fd [, max])

读取套接字接收缓冲区中当前可用的所有数据。此函数**不是**异步的；它会立即返回任何可用的数据。

- **参数**:
  - `fd`: `integer` - 文件描述符
  - `max`: `integer|nil` (可选) - 要读取的最大字节数
- **返回值**:
  - 成功: `string` - 包含可用数据的字符串（可能为空）
  - 失败: `nil, string` - nil 和错误信息（套接字无效）
- **非异步**: 立即返回，不会挂起协程
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

-- 读取所有可用数据
local data = tcp.readall(fd)
print("Available data:", #data, "bytes")

-- 最多读取1024字节
local data = tcp.readall(fd, 1024)
```

### tcp.limit(fd, limit)

设置套接字接收缓冲区的大小限制。这是流控制的关键机制，可防止快速发送方压垮慢速消费方。

- **参数**:
  - `fd`: `integer` - 文件描述符
  - `limit`: `integer` - 要缓冲的最大字节数
- **返回值**:
  - 成功: `integer|boolean` - 当前限制大小或 true
  - 失败: `false` - 套接字无效
- **说明**: 当接收缓冲区达到限制时，TCP 流控制会暂停接收更多数据
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

-- 限制接收缓冲区为8MB
tcp.limit(fd, 8 * 1024 * 1024)
```

### tcp.recvsize(fd)

获取当前接收缓冲区中保存的数据量。

- **参数**:
  - `fd`: `integer` - 文件描述符
- **返回值**: `integer` - 接收缓冲区中的字节数
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local size = tcp.recvsize(fd)
print("Buffered data:", size, "bytes")
```

### tcp.sendsize(fd)

获取当前发送缓冲区（已排队但尚未传输）中保存的数据量。

- **参数**:
  - `fd`: `integer` - 文件描述符
- **返回值**: `integer` - 发送缓冲区中的字节数
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local size = tcp.sendsize(fd)
print("Pending send:", size, "bytes")
```

### tcp.isalive(fd)

检查套接字是否仍被认为是活动的。

- **参数**:
  - `fd`: `integer` - 文件描述符
- **返回值**: `boolean` - 如果套接字已打开且未遇到错误，则返回 `true`，否则返回 `false`
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

if tcp.isalive(fd) then
    print("Connection is alive")
else
    print("Connection is closed or has error")
end
```

## 使用示例

### 示例1：Echo 服务器

一个简单的回显服务器，将接收到的数据原样返回给客户端：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

silly.fork(function()
    local wg = waitgroup.new()

    -- 启动服务器
    local listenfd = tcp.listen("127.0.0.1:9988", function(fd, addr)
        wg:fork(function()
            print("Client connected:", addr)

            -- 持续回显数据，直到连接关闭
            while true do
                local line, err = tcp.readline(fd)
                if not line then
                    print("Client disconnected:", err or "closed")
                    break
                end

                print("Echo:", line)
                tcp.write(fd, line)
            end

            tcp.close(fd)
        end)
    end)

    print("Echo server listening on 127.0.0.1:9988")

    -- 测试客户端
    wg:fork(function()
        time.sleep(100)  -- 等待服务器启动

        local fd, err = tcp.connect("127.0.0.1:9988")
        if not fd then
            print("Connect failed:", err)
            return
        end

        -- 发送测试消息
        tcp.write(fd, "Hello, Echo!\n")
        local response = tcp.readline(fd)
        print("Received:", response)

        tcp.close(fd)
    end)

    wg:wait()
    tcp.close(listenfd)
end)
```

### 示例2：HTTP 客户端

一个简单的 HTTP GET 请求客户端：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"

silly.fork(function()
    local fd, err = tcp.connect("example.com:80")
    if not fd then
        print("Connect failed:", err)
        return
    end

    -- 发送 HTTP GET 请求
    local request = "GET / HTTP/1.1\r\n"
                 .. "Host: example.com\r\n"
                 .. "Connection: close\r\n"
                 .. "\r\n"

    tcp.write(fd, request)
    print("Request sent")

    -- 读取 HTTP 响应
    -- 读取状态行
    local status = tcp.readline(fd, "\r\n")
    print("Status:", status)

    -- 读取头部
    while true do
        local header = tcp.readline(fd, "\r\n")
        if header == "\r\n" then
            break  -- 空行表示头部结束
        end
        print("Header:", header)
    end

    -- 读取响应体（简化版本，仅读取可用数据）
    local body = tcp.readall(fd)
    print("Body length:", #body)

    tcp.close(fd)
end)
```

### 示例3：二进制协议

处理二进制协议（长度+数据格式）：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

-- 辅助函数：整数与字节转换
local function pack_uint32(n)
    return string.char(
        n >> 24 & 0xFF,
        n >> 16 & 0xFF,
        n >> 8 & 0xFF,
        n & 0xFF
    )
end

local function unpack_uint32(s)
    local b1, b2, b3, b4 = string.byte(s, 1, 4)
    return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
end

silly.fork(function()
    local wg = waitgroup.new()

    -- 服务器：接收二进制消息
    local listenfd = tcp.listen("127.0.0.1:9989", function(fd, addr)
        wg:fork(function()
            while true do
                -- 读取4字节长度头
                local header, err = tcp.read(fd, 4)
                if not header then
                    break
                end

                local length = unpack_uint32(header)
                print("Receiving message of length:", length)

                -- 读取数据体
                local data = tcp.read(fd, length)
                if not data then
                    break
                end

                print("Received data:", data)

                -- 回显
                tcp.write(fd, header)
                tcp.write(fd, data)
            end

            tcp.close(fd)
        end)
    end)

    -- 客户端：发送二进制消息
    wg:fork(function()
        time.sleep(100)

        local fd = tcp.connect("127.0.0.1:9989")
        if not fd then
            return
        end

        -- 发送消息
        local message = "Binary Protocol Test"
        local header = pack_uint32(#message)

        tcp.write(fd, header)
        tcp.write(fd, message)
        print("Sent:", message)

        -- 接收回显
        local recv_header = tcp.read(fd, 4)
        local recv_length = unpack_uint32(recv_header)
        local recv_data = tcp.read(fd, recv_length)
        print("Echoed:", recv_data)

        tcp.close(fd)
    end)

    wg:wait()
    tcp.close(listenfd)
end)
```

### 示例4：流控制

演示如何使用 `tcp.limit` 控制接收速率：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

silly.fork(function()
    local wg = waitgroup.new()

    -- 服务器：快速发送大量数据
    local listenfd = tcp.listen("127.0.0.1:9990", function(fd, addr)
        wg:fork(function()
            -- 发送10MB数据
            local chunk = string.rep("A", 1024 * 1024)
            for i = 1, 10 do
                tcp.write(fd, chunk)
                print("Sent chunk", i)
            end
            tcp.close(fd)
        end)
    end)

    -- 客户端：限制接收缓冲区，慢速消费
    wg:fork(function()
        time.sleep(100)

        local fd = tcp.connect("127.0.0.1:9990")
        if not fd then
            return
        end

        -- 限制接收缓冲区为2MB
        tcp.limit(fd, 2 * 1024 * 1024)

        local total = 0
        while true do
            -- 每次只读1MB
            local data = tcp.read(fd, 1024 * 1024)
            if not data then
                break
            end

            total = total + #data
            print("Received:", total, "bytes, buffered:", tcp.recvsize(fd))

            -- 模拟慢速处理
            time.sleep(100)
        end

        print("Total received:", total, "bytes")
        tcp.close(fd)
    end)

    wg:wait()
    tcp.close(listenfd)
end)
```

### 示例5：连接池

实现一个简单的 TCP 连接池：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"
local time = require "silly.time"

-- 连接池
local pool = {
    idle = {},      -- 空闲连接
    max_size = 10,  -- 最大连接数
    host = "127.0.0.1:8080"
}

-- 获取连接
function pool:acquire()
    -- 优先使用空闲连接
    if #self.idle > 0 then
        local fd = table.remove(self.idle)
        if tcp.isalive(fd) then
            return fd
        end
        tcp.close(fd)
    end

    -- 创建新连接
    local fd, err = tcp.connect(self.host)
    if not fd then
        return nil, err
    end

    return fd
end

-- 归还连接
function pool:release(fd)
    if not tcp.isalive(fd) then
        tcp.close(fd)
        return
    end

    -- 如果池未满，放回池中
    if #self.idle < self.max_size then
        table.insert(self.idle, fd)
    else
        tcp.close(fd)
    end
end

-- 使用示例
silly.fork(function()
    -- 发起多个请求，复用连接
    for i = 1, 5 do
        local fd, err = pool:acquire()
        if not fd then
            print("Failed to acquire connection:", err)
            return
        end

        print("Request", i, "using fd:", fd)
        tcp.write(fd, "GET / HTTP/1.1\r\n\r\n")

        -- 读取响应（简化）
        time.sleep(100)

        -- 归还连接
        pool:release(fd)
    end
end)
```

## 注意事项

### 1. 必须在协程中调用异步函数

`tcp.connect`、`tcp.read`、`tcp.readline` 等异步函数必须在协程中调用：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"

-- 正确：在协程中调用
silly.fork(function()
    local fd = tcp.connect("127.0.0.1:8080")
    -- ...
end)

-- 错误：不能在主线程中直接调用
-- local fd = tcp.connect("127.0.0.1:8080")  -- 这会失败！
```

### 2. 及时关闭连接

始终记得关闭不再使用的连接，避免资源泄漏：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"

silly.fork(function()
    local fd = tcp.connect("127.0.0.1:8080")
    if not fd then
        return
    end

    -- 使用 pcall 确保即使出错也能关闭连接
    local ok, err = pcall(function()
        -- ... 使用连接 ...
    end)

    tcp.close(fd)  -- 始终关闭

    if not ok then
        print("Error:", err)
    end
end)
```

### 3. 检查返回值

始终检查返回值，处理错误情况：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"

silly.fork(function()
    local fd, err = tcp.connect("127.0.0.1:8080")
    if not fd then
        print("Connect failed:", err)
        return
    end

    local data, err = tcp.read(fd, 100)
    if not data then
        print("Read failed:", err)
        tcp.close(fd)
        return
    end

    tcp.close(fd)
end)
```

### 4. 流控制

对于大数据传输，使用 `tcp.limit` 限制接收缓冲区，防止内存耗尽：

```lua validate
local tcp = require "silly.net.tcp"

-- 限制接收缓冲区为8MB
tcp.limit(fd, 8 * 1024 * 1024)
```

### 5. 发送缓冲区管理

写入大量数据时，检查发送缓冲区大小，避免内存积压：

```lua validate
local tcp = require "silly.net.tcp"
local time = require "silly.time"

-- 如果发送缓冲区过大，等待一段时间
if tcp.sendsize(fd) > 10 * 1024 * 1024 then
    time.sleep(100)
end
```

### 6. 半关闭状态

TCP 支持半关闭（一方关闭写但仍可读）。`tcp.close` 会完全关闭连接。

### 7. 监听器不要关闭太早

确保在所有连接处理完成之前不要关闭监听器：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"
local waitgroup = require "silly.sync.waitgroup"

silly.fork(function()
    local wg = waitgroup.new()

    local listenfd = tcp.listen("127.0.0.1:8080", function(fd, addr)
        wg:fork(function()
            -- 处理连接
            tcp.close(fd)
        end)
    end)

    -- 等待所有连接处理完成
    wg:wait()

    -- 现在可以安全关闭监听器
    tcp.close(listenfd)
end)
```

## 性能建议

### 1. 批量写入

使用字符串表进行批量写入，减少系统调用：

```lua validate
local tcp = require "silly.net.tcp"

-- 推荐：批量写入（零拷贝）
tcp.write(fd, {"header", "body1", "body2"})

-- 避免：多次调用
tcp.write(fd, "header")
tcp.write(fd, "body1")
tcp.write(fd, "body2")
```

### 2. 合理设置接收缓冲区限制

根据应用特点设置合理的缓冲区大小：

```lua validate
local tcp = require "silly.net.tcp"

-- 小消息场景：较小的缓冲区
tcp.limit(fd, 64 * 1024)  -- 64KB

-- 大文件传输：较大的缓冲区
tcp.limit(fd, 8 * 1024 * 1024)  -- 8MB
```

### 3. 避免频繁的小读取

尽量使用 `tcp.readline` 或一次读取更多数据：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"

silly.fork(function()
    local fd = tcp.connect("127.0.0.1:8080")
    if not fd then return end

    -- 推荐：按行读取
    local line = tcp.readline(fd)

    -- 推荐：读取固定大小
    local data = tcp.read(fd, 1024)

    -- 避免：频繁的小读取
    -- for i = 1, 1024 do
    --     tcp.read(fd, 1)  -- 性能差
    -- end

    tcp.close(fd)
end)
```

## 参见

- [silly](../silly.md) - 核心调度器
- [silly.time](../time.md) - 定时器模块
- [silly.net.udp](./udp.md) - UDP 协议支持
- [silly.net.tls](./tls.md) - TLS/SSL 支持
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
