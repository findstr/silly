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

从套接字读取数据的函数，例如 `conn:read`，是**异步的**。这意味着如果数据没有立即可用，它们将暂停当前协程的执行，并在数据到达后恢复执行。这使得单线程的 Silly 服务能够高效地处理许多并发连接。

### 面向连接

TCP 是面向连接的协议，这意味着在数据传输之前必须先建立连接。连接建立后，数据将按顺序可靠地传输，并保证到达顺序与发送顺序一致。

## API 文档

### tcp.listen(conf)

启动一个 TCP 服务器在给定地址上进行监听。

- **参数**:
  - `conf`: `table` - 配置表，包含以下字段：
    - `addr`: `string` - 监听的地址，例如 `"127.0.0.1:8080"` 或 `":8080"`
    - `accept`: `async fun(conn)` - 连接回调函数，为每个新的客户端连接执行
      - `conn`: 连接对象（`silly.net.tcp.conn`）
    - `backlog`: `integer|nil` (可选) - 等待连接队列的最大长度
- **返回值**:
  - 成功: `silly.net.tcp.listener` - 监听器对象
  - 失败: `nil, string` - nil 和错误信息
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local listener, err = tcp.listen {
    addr = "127.0.0.1:8080",
    accept = function(conn)
        print("New connection from:", conn.remoteaddr)
        -- 处理连接...
        conn:close()
    end
}

if not listener then
    print("Listen failed:", err)
end
```

### tcp.connect(addr [, opts])

建立到 TCP 服务器的连接（异步）。

- **参数**:
  - `addr`: `string` - 要连接的服务器地址，例如 `"127.0.0.1:8080"`
  - `opts`: `table|nil` (可选) - 配置选项
    - `bind`: `string|nil` - 用于绑定客户端套接字的本地地址
    - `timeout`: `integer|nil` - 连接超时时间（毫秒），如果未设置则无超时限制
- **返回值**:
  - 成功: `silly.net.tcp.conn` - 连接对象
  - 失败: `nil, string` - nil 和错误信息（"connect timeout" 表示连接超时）
- **异步**: 此函数是异步的，会等待连接建立或超时
- **示例**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    -- 基本连接
    local conn, err = tcp.connect("127.0.0.1:8080")
    if not conn then
        print("Connect failed:", err)
        return
    end
    print("Connected! Remote addr:", conn.remoteaddr)
    conn:close()

    -- 带超时的连接（1秒超时）
    local conn2, err2 = tcp.connect("192.0.2.1:80", {timeout = 1000})
    if not conn2 then
        print("Connect failed:", err2)  -- 可能输出 "connect timeout"
        return
    end
    conn2:close()
end)
```

### conn:close()

关闭一个 TCP 连接。

- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息（如果套接字已关闭或无效）
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local conn, err = tcp.connect("127.0.0.1:8080")
if not conn then return end

local ok, err = conn:close()
if not ok then
    print("Close failed:", err)
end
```

### conn:write(data)

将数据写入套接字。从用户的角度来看，此操作是非阻塞的；数据由框架缓冲和发送。

- **参数**:
  - `data`: `string|table` - 要发送的数据，可以是字符串或字符串表
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

-- 发送字符串
conn:write("Hello, World!\n")

-- 发送多个字符串（零拷贝）
conn:write({"HTTP/1.1 200 OK\r\n", "Content-Length: 5\r\n\r\n", "Hello"})
```

### conn:read(n [, timeout])

从套接字精确读取 `n` 个字节或直到找到分隔符从套接字读取数据（异步）。

- **参数**:
  - `n`: `integer|string` - 读取的字节数或分隔符
    - 如果是整数：读取指定字节数
    - 如果是字符串：读取直到遇到该分隔符（包含分隔符）
- **返回值**:
  - 成功: `string` - 读取的数据
  - 失败: `nil, string` - nil 和错误信息
  - **EOF**: `"", "end of file"` - 空字符串和 "end of file" 错误信息
- **异步**: 如果数据未就绪，会挂起协程直到数据到达
- **示例**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn, err = tcp.connect("127.0.0.1:8080")
    if not conn then
        return
    end

    -- 读取一行（以\n结尾）
    local line, err = conn:read("\n")
    if err then  -- 使用 err 判断连接状态（包括 EOF）
        print("Read failed:", err)
        conn:close()
        return
    end

    print("Received:", line)

    -- 读取固定字节数
    local header, err = conn:read(4)
    if err then
        print("Read failed:", err)
        conn:close()
        return
    end

    print("Header:", header)
    conn:close()
end)
```

::: tip 错误处理最佳实践
应该使用 `if err then` 来判断连接断开，而不是 `if not data then`。因为在 EOF 时，`conn:read()` 会返回 `"", "end of file"`，此时 `data` 是空字符串（真值），但 `err` 不为 nil。
:::

### conn:readline(delim)

::: warning 已废弃
此方法已废弃，请使用 `conn:read(delim)` 代替。
:::

从套接字读取直到找到特定的分隔符（异步）。这是 `conn:read(delim)` 的别名。

- **参数**:
  - `delim`: `string` - 分隔符（如 `"\n"`）
- **返回值**:
  - 成功: `string` - 一行文本（包括分隔符）
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 如果分隔符未找到，会挂起协程直到收到完整的行
- **示例**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn, err = tcp.connect("127.0.0.1:8080")
    if not conn then
        return
    end

    -- 推荐使用 conn:read("\n") 代替
    -- 读取一行（以\n结尾）
    local line, err = conn:read("\n")
    if not line then
        print("Readline failed:", err)
        conn:close()
        return
    end

    print("Received line:", line)
    conn:close()
end)
```

### conn:unreadbytes()

::: warning 名称变更
此方法替代了旧的 `tcp.recvsize(conn)`。获取当前接收缓冲区中未读取的数据量。
:::

获取接收缓冲区中当前可用但尚未读取的数据量。

- **返回值**: `integer` - 接收缓冲区中的字节数
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

local size = conn:unreadbytes()
print("Buffered data:", size, "bytes")
```

### conn:limit(limit)

设置套接字接收缓冲区的大小限制。这是流控制的关键机制，可防止快速发送方压垮慢速消费方。

- **参数**:
  - `limit`: `integer|nil` - 要缓冲的最大字节数，或 `nil` 禁用限制
- **说明**: 当接收缓冲区达到限制时，TCP 流控制会暂停接收更多数据
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

-- 限制接收缓冲区为8MB
conn:limit(8 * 1024 * 1024)

-- 禁用限制
conn:limit(nil)
```

### conn:unsentbytes()

::: warning 名称变更
此方法替代了旧的 `tcp.sendsize(conn)`。获取发送缓冲区中等待发送的数据量。
:::

获取当前发送缓冲区（已排队但尚未传输）中保存的数据量。

- **返回值**: `integer` - 发送缓冲区中的字节数
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

conn:write("Large data...")
local size = conn:unsentbytes()
print("Pending send:", size, "bytes")
```

### conn:isalive()

检查连接是否仍然有效。

- **返回值**: `boolean` - 如果连接有效且没有错误则返回 `true`
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

if conn:isalive() then
    print("Connection is still alive")
end
```

### conn.remoteaddr

获取连接的远程地址（只读属性）。

> **注意**: `remoteaddr` 是连接对象的属性，直接访问即可，不需要加括号调用。

- **类型**: `string` - 远程地址字符串（格式：`IP:Port`）
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

local conn = tcp.connect("127.0.0.1:8080")
if not conn then return end

print("Remote address:", conn.remoteaddr)
```

### conn:isalive()

检查套接字是否仍被认为是活动的。

- **参数**:
  - `fd`: `integer` - 文件描述符
- **返回值**: `boolean` - 如果套接字已打开且未遇到错误，则返回 `true`，否则返回 `false`
- **示例**:

```lua validate
local tcp = require "silly.net.tcp"

if conn:isalive() then
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
local task = require "silly.task"
local tcp = require "silly.net.tcp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

task.fork(function()
    local wg = waitgroup.new()

    -- 启动服务器
    local listenfd = tcp.listen {
        addr = "127.0.0.1:9988",
        accept = function(conn)
        wg:fork(function()
            print("Client connected:", conn.remoteaddr)

            -- 持续回显数据，直到连接关闭
            while true do
                local line, err = conn:read("\n")
                if not line then
                    print("Client disconnected:", err or "closed")
                    break
                end

                print("Echo:", line)
                conn:write( line)
            end

            conn:close()
        end)
    end }

    print("Echo server listening on 127.0.0.1:9988")

    -- 测试客户端
    wg:fork(function()
        time.sleep(100)  -- 等待服务器启动

        local conn, err = tcp.connect("127.0.0.1:9988")
        if not conn then
            print("Connect failed:", err)
            return
        end

        -- 发送测试消息
        conn:write( "Hello, Echo!\n")
        local response = conn:read("\n")
        print("Received:", response)

        conn:close()
    end)

    wg:wait()
    listenfd:close()
end)
```

### 示例2：HTTP 客户端

一个简单的 HTTP GET 请求客户端：

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn, err = tcp.connect("example.com:80")
    if not conn then
        print("Connect failed:", err)
        return
    end

    -- 发送 HTTP GET 请求
    local request = "GET / HTTP/1.1\r\n"
                 .. "Host: example.com\r\n"
                 .. "Connection: close\r\n"
                 .. "\r\n"

    conn:write( request)
    print("Request sent")

    -- 读取 HTTP 响应
    -- 读取状态行
    -- 读取 HTTP 响应
    -- 读取状态行
    local status = conn:read("\r\n")
    print("Status:", status)

    -- 读取头部
    while true do
        local header = conn:read("\r\n")
        if header == "\r\n" then
            break  -- 空行表示头部结束
        end
        print("Header:", header)
    end

    -- 读取响应体（简化版本，仅读取可用数据）
    local body = conn:read(conn:unreadbytes())
    print("Body length:", #body)

    conn:close()
end)
```

### 示例3：二进制协议

处理二进制协议（长度+数据格式）：

```lua validate
local silly = require "silly"
local task = require "silly.task"
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

task.fork(function()
    local wg = waitgroup.new()

    -- 服务器：接收二进制消息
    local listenfd = tcp.listen {
        addr = "127.0.0.1:9989",
        accept = function(conn)
        wg:fork(function()
            while true do
                -- 读取4字节长度头
                local header, err = conn:read( 4)
                if not header then
                    break
                end

                local length = unpack_uint32(header)
                print("Receiving message of length:", length)

                -- 读取数据体
                local data = conn:read( length)
                if not data then
                    break
                end

                print("Received data:", data)

                -- 回显
                conn:write( header)
                conn:write( data)
            end

            conn:close()
        end)
    end
    }

    -- 客户端：发送二进制消息
    wg:fork(function()
        time.sleep(100)

        local conn = tcp.connect("127.0.0.1:9989")
        if not conn then
            return
        end

        -- 发送消息
        local message = "Binary Protocol Test"
        local header = pack_uint32(#message)

        conn:write( header)
        conn:write( message)
        print("Sent:", message)

        -- 接收回显
        local recv_header = conn:read( 4)
        local recv_length = unpack_uint32(recv_header)
        local recv_data = conn:read( recv_length)
        print("Echoed:", recv_data)

        conn:close()
    end)

    wg:wait()
    listenfd:close()
end)
```

### 示例4：流控制

演示如何使用 `tcp.limit` 控制接收速率：

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

task.fork(function()
    local wg = waitgroup.new()

    -- 服务器：快速发送大量数据
    local listenfd = tcp.listen {
        addr = "127.0.0.1:9990",
        accept = function(conn)
        wg:fork(function()
            -- 发送10MB数据
            local chunk = string.rep("A", 1024 * 1024)
            for i = 1, 10 do
                conn:write( chunk)
                print("Sent chunk", i)
            end
            conn:close()
        end)
    end
    }

    -- 客户端：限制接收缓冲区，慢速消费
    wg:fork(function()
        time.sleep(100)

        local conn = tcp.connect("127.0.0.1:9990")
        if not conn then
            return
        end

        -- 限制接收缓冲区为2MB
        conn:limit( 2 * 1024 * 1024)

        local total = 0
        while true do
            -- 每次只读1MB
            local data = conn:read( 1024 * 1024)
            if not data then
                break
            end

            total = total + #data
            print("Received:", total, "bytes, buffered:", tcp.recvsize(conn))

            -- 模拟慢速处理
            time.sleep(100)
        end

        print("Total received:", total, "bytes")
        conn:close()
    end)

    wg:wait()
    listenfd:close()
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
        local conn = table.remove(self.idle)
        if conn:isalive() then
            return conn
        end
        conn:close()
    end

    -- 创建新连接
    local conn, err = tcp.connect(self.host)
    if not conn then
        return nil, err
    end

    return conn
end

-- 归还连接
function pool:release(conn)
    if not conn:isalive() then
        conn:close()
        return
    end

    -- 如果池未满，放回池中
    if #self.idle < self.max_size then
        table.insert(self.idle, conn)
    else
        conn:close()
    end
end

-- 使用示例
local task = require "silly.task"
task.fork(function()
    -- 发起多个请求，复用连接
    for i = 1, 5 do
        local conn, err = pool:acquire()
        if not conn then
            print("Failed to acquire connection:", err)
            return
        end

        print("Request", i, "using conn:", conn)
        conn:write( "GET / HTTP/1.1\r\n\r\n")

        -- 读取响应（简化）
        time.sleep(100)

        -- 归还连接
        pool:release(conn)
    end
end)
```

## 注意事项

### 1. 必须在协程中调用异步函数

`tcp.connect`、`conn:read` 等异步函数必须在协程中调用：

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

-- 正确：在协程中调用
task.fork(function()
    local conn = tcp.connect("127.0.0.1:8080")
    -- ...
end)

-- 错误：不能在主线程中直接调用
-- local conn = tcp.connect("127.0.0.1:8080")  -- 这会失败！
```

### 2. 及时关闭连接

始终记得关闭不再使用的连接，避免资源泄漏：

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn = tcp.connect("127.0.0.1:8080")
    if not conn then
        return
    end

    -- 使用 pcall 确保即使出错也能关闭连接
    local ok, err = pcall(function()
        -- ... 使用连接 ...
    end)

    conn:close()  -- 始终关闭

    if not ok then
        print("Error:", err)
    end
end)
```

### 3. 检查返回值

始终检查返回值，处理错误情况：

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    local conn, err = tcp.connect("127.0.0.1:8080")
    if not conn then
        print("Connect failed:", err)
        return
    end

    local data, err = conn:read( 100)
    if not data then
        print("Read failed:", err)
        conn:close()
        return
    end

    conn:close()
end)
```

### 4. 流控制

对于大数据传输，使用 `tcp.limit` 限制接收缓冲区，防止内存耗尽：

```lua validate
local tcp = require "silly.net.tcp"

-- 限制接收缓冲区为8MB
conn:limit( 8 * 1024 * 1024)
```

### 5. 发送缓冲区管理

写入大量数据时，检查发送缓冲区大小，避免内存积压：

```lua validate
local tcp = require "silly.net.tcp"
local time = require "silly.time"

-- 如果发送缓冲区过大，等待一段时间
if tcp.sendsize(conn) > 10 * 1024 * 1024 then
    time.sleep(100)
end
```

### 6. 半关闭状态

TCP 支持半关闭（一方关闭写但仍可读）。`tcp.close` 会完全关闭连接。

### 7. 监听器不要关闭太早

确保在所有连接处理完成之前不要关闭监听器：

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"
local waitgroup = require "silly.sync.waitgroup"

task.fork(function()
    local wg = waitgroup.new()

    local listenfd = tcp.listen {
        addr = "127.0.0.1:8080",
        accept = function(conn)
        wg:fork(function()
            -- 处理连接
            conn:close()
        end)
    end
    }

    -- 等待所有连接处理完成
    wg:wait()

    -- 现在可以安全关闭监听器
    listenfd:close()
end)
```

## 性能建议

### 1. 批量写入

使用字符串表进行批量写入，减少系统调用：

```lua validate
local tcp = require "silly.net.tcp"

-- 推荐：批量写入（零拷贝）
conn:write( {"header", "body1", "body2"})

-- 避免：多次调用
conn:write( "header")
conn:write( "body1")
conn:write( "body2")
```

### 2. 合理设置接收缓冲区限制

根据应用特点设置合理的缓冲区大小：

```lua validate
local tcp = require "silly.net.tcp"

-- 小消息场景：较小的缓冲区
conn:limit( 64 * 1024)  -- 64KB

-- 大文件传输：较大的缓冲区
conn:limit( 8 * 1024 * 1024)  -- 8MB
```

### 3. 避免频繁的小读取

尽量使用 `conn:read(delim)` 或一次读取更多数据：

```lua validate
local silly = require "silly"
local tcp = require "silly.net.tcp"

local task = require "silly.task"

task.fork(function()
    local conn = tcp.connect("127.0.0.1:8080")
    if not conn then return end

    -- 推荐：按行读取
    local line = conn:read("\n")

    -- 推荐：读取固定大小
    local data = conn:read( 1024)

    -- 避免：频繁的小读取
    -- for i = 1, 1024 do
    --     conn:read( 1)  -- 性能差
    -- end

    conn:close()
end)
```

## 参见

- [silly](../silly.md) - 核心模块
- [silly.time](../time.md) - 定时器模块
- [silly.net.udp](./udp.md) - UDP 协议支持
- [silly.net.tls](./tls.md) - TLS/SSL 支持
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
