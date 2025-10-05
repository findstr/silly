---
title: TCP Echo 服务器教程
icon: network
order: 1
category:
  - 教程
tag:
  - TCP
  - 网络编程
  - 协程
  - 异步I/O
---

# TCP Echo 服务器教程

## 学习目标

通过本教程,你将学习:

- **网络编程基础**: 理解 TCP 服务器的工作原理
- **TCP 协议**: 掌握 TCP 连接的建立、数据传输和关闭
- **Lua 协程**: 学会使用协程处理并发连接
- **异步 I/O**: 理解 Silly 框架的异步编程模型
- **错误处理**: 正确处理网络错误和连接关闭

## 什么是 Echo 服务器?

Echo 服务器是一个简单的网络服务器,它会将客户端发送的数据原封不动地返回。这是学习网络编程的经典入门示例,因为它:

- **简单直观**: 逻辑简单,容易理解
- **实用价值**: 可用于网络连通性测试
- **完整流程**: 涵盖了监听、接收、发送、关闭等完整的网络编程流程

典型的 Echo 服务器工作流程:

```
客户端                     服务器
  |                          |
  |---- "Hello" ------------>|
  |<--- "Hello" -------------|
  |                          |
  |---- "World" ------------>|
  |<--- "World" -------------|
  |                          |
```

## 实现步骤

### Step 1: 创建监听服务器

首先,我们需要在指定的地址和端口上创建一个 TCP 监听服务器:

```lua
local socket = require "silly.net.tcp"

socket.listen("127.0.0.1:9999", function(fd, addr)
    -- fd: 客户端连接的文件描述符
    -- addr: 客户端地址
    print("新客户端连接:", fd, addr)
end)
```

**关键点**:
- `socket.listen()` 会在指定地址上创建监听套接字
- 每当有新客户端连接时,回调函数会被调用
- 回调函数在独立的协程中执行,不会阻塞主线程

### Step 2: 处理客户端连接

在回调函数中,我们需要循环读取客户端数据并回显:

```lua
socket.listen("127.0.0.1:9999", function(fd, addr)
    print("新客户端连接:", fd, addr)

    while true do
        -- 读取一行数据
        local data, err = socket.readline(fd)
        if not data then
            print("读取错误:", err or "连接关闭")
            break
        end

        -- 回显数据
        local ok, werr = socket.write(fd, data)
        if not ok then
            print("写入错误:", werr)
            break
        end
    end
end)
```

### Step 3: 读取和回显数据

Silly 提供了多种读取方式:

- `socket.readline(fd, delim)`: 读取一行(默认分隔符为 `\n`)
- `socket.read(fd, n)`: 读取指定字节数
- `socket.readall(fd, max)`: 读取所有可用数据

对于 Echo 服务器,我们使用 `readline()` 按行读取:

```lua
local line, err = socket.readline(fd)  -- 读取一行(包含 \n)
if not line then
    -- 读取失败,可能是连接关闭或网络错误
    print("读取失败:", err)
    break
end

-- 回显数据
local ok, werr = socket.write(fd, line)
if not ok then
    print("写入失败:", werr)
    break
end
```

### Step 4: 优雅关闭

当连接出现错误或客户端关闭连接时,我们需要清理资源:

```lua
while true do
    local data, err = socket.readline(fd)
    if not data then
        print("连接关闭:", fd, err or "客户端断开")
        break
    end

    local ok, werr = socket.write(fd, data)
    if not ok then
        print("写入失败:", fd, werr)
        break
    end
end

-- 关闭连接
socket.close(fd)
print("已关闭连接:", fd)
```

## 完整代码

下面是一个完整的 Echo 服务器实现,包含服务器和客户端测试代码:

```lua
local silly = require "silly"
local time = require "silly.time"
local crypto = require "silly.crypto.utils"
local socket = require "silly.net.tcp"

-- 启动 Echo 服务器
socket.listen("127.0.0.1:9999", function(fd, addr)
    print("接受连接", fd, addr)

    while true do
        -- 读取一行数据
        local line, err = socket.readline(fd)
        if not line then
            print("读取错误 [fd:", fd, "] ->", err or "连接关闭")
            break
        end

        -- 回显数据
        local ok, werr = socket.write(fd, line)
        if not ok then
            print("写入错误 [fd:", fd, "] ->", werr)
            break
        end
    end

    -- 关闭连接
    print("关闭连接", fd)
    socket.close(fd)
end)

-- 启动测试客户端
-- 创建 3 个客户端进行测试
for i = 1, 3 do
    silly.fork(function()
        -- 连接服务器
        local fd, err = socket.connect("127.0.0.1:9999")
        if not fd then
            print("连接失败:", err)
            return
        end

        print("客户端", i, "已连接, fd:", fd)

        -- 发送 5 条测试消息
        for j = 1, 5 do
            -- 生成随机数据
            local msg = crypto.randomkey(5) .. "\n"
            print("发送 [fd:", fd, "] ->", msg)

            -- 发送数据
            local ok, werr = socket.write(fd, msg)
            if not ok then
                print("发送失败 [fd:", fd, "] ->", werr)
                break
            end

            -- 接收回显数据
            local recv, rerr = socket.readline(fd)
            if not recv then
                print("接收失败 [fd:", fd, "] ->", rerr or "连接关闭")
                break
            end

            print("接收 [fd:", fd, "] ->", recv)

            -- 验证回显数据正确性
            assert(recv == msg, "回显数据不匹配!")

            -- 等待 1 秒
            time.sleep(1000)
        end

        -- 关闭连接
        print("客户端关闭连接", fd)
        socket.close(fd)
    end)
end
```

将代码保存为 `echo-server.lua`。

## 运行和测试

### 启动服务器

```bash
cd /path/to/silly
./silly echo-server.lua
```

你会看到类似的输出:

```
接受连接 4 127.0.0.1:xxxxx
客户端 1 已连接, fd: 5
发送 [fd: 5] -> AbCdE
接收 [fd: 5] -> AbCdE
接受连接 6 127.0.0.1:xxxxx
客户端 2 已连接, fd: 7
...
```

### 使用 telnet 测试

在服务器运行时,打开另一个终端:

```bash
telnet 127.0.0.1 9999
```

然后输入任意文本并按回车:

```
Trying 127.0.0.1...
Connected to 127.0.0.1.
Escape character is '^]'.
Hello Silly!
Hello Silly!
This is a test
This is a test
```

服务器会立即回显你输入的内容。

### 使用客户端代码测试

上面的完整代码已经包含了测试客户端。运行时会自动创建 3 个客户端,每个客户端发送 5 条消息。

如果要单独编写客户端:

```lua
local silly = require "silly"
local socket = require "silly.net.tcp"

silly.fork(function()
    -- 连接服务器
    local fd, err = socket.connect("127.0.0.1:9999")
    if not fd then
        print("连接失败:", err)
        return
    end

    print("已连接到服务器, fd:", fd)

    -- 发送消息
    socket.write(fd, "Hello from client\n")

    -- 接收回显
    local msg, rerr = socket.readline(fd)
    if msg then
        print("收到回显:", msg)
    else
        print("接收失败:", rerr)
    end

    -- 关闭连接
    socket.close(fd)
end)
```

## 代码解析

### 监听函数

```lua
socket.listen(addr, callback, backlog)
```

**参数**:
- `addr`: 监听地址,格式为 `"IP:端口"`,例如 `"127.0.0.1:9999"` 或 `"0.0.0.0:8080"`
- `callback`: 客户端连接回调函数,签名为 `function(fd, addr)`
  - `fd`: 客户端连接的文件描述符
  - `addr`: 客户端地址字符串
- `backlog`: (可选) 监听队列长度,默认为 128

**返回值**:
- 成功: 返回监听套接字的文件描述符
- 失败: 返回 `nil` 和错误信息

**重要特性**:
- 每个客户端连接都会在**独立的协程**中处理
- 协程之间互不阻塞,实现高并发处理
- 当回调函数返回或出错时,框架会自动关闭连接

### 协程处理

Silly 使用 Lua 协程实现异步 I/O:

```lua
-- 每个客户端连接运行在独立协程中
socket.listen("127.0.0.1:9999", function(fd, addr)
    -- 这里的代码在独立协程中运行
    while true do
        local data = socket.readline(fd)  -- 异步读取,不阻塞其他连接
        socket.write(fd, data)            -- 异步写入
    end
end)
```

**协程的优势**:
- **同步风格的代码**: 看起来像同步代码,实际是异步执行
- **高并发**: 可以同时处理成千上万个连接
- **零回调**: 不需要嵌套的回调函数,代码清晰易读

### 读取操作

所有读取操作都是**异步**的:

```lua
-- 读取一行(阻塞直到收到 \n)
local line, err = socket.readline(fd, "\n")

-- 读取指定字节数(阻塞直到收到 n 字节)
local data, err = socket.read(fd, 1024)

-- 读取所有可用数据(立即返回,不阻塞)
local data, err = socket.readall(fd)
```

**返回值**:
- 成功: 返回数据字符串
- 失败: 返回 `nil` 和错误信息(可能是 `nil`,表示连接关闭)

### 写入操作

```lua
local ok, err = socket.write(fd, data)
```

**特性**:
- 写入操作是**非阻塞**的
- 数据会被缓冲到发送队列中
- 如果发送队列满,会返回错误

**返回值**:
- 成功: 返回 `true`
- 失败: 返回 `false` 和错误信息

### 错误处理

网络编程中必须处理各种错误情况:

```lua
-- 读取错误
local data, err = socket.readline(fd)
if not data then
    if err then
        print("网络错误:", err)
    else
        print("客户端正常关闭连接")
    end
    socket.close(fd)
    return
end

-- 写入错误
local ok, werr = socket.write(fd, data)
if not ok then
    print("写入失败:", werr)
    socket.close(fd)
    return
end
```

**常见错误**:
- 连接关闭: `err` 为 `nil` 或 `"socket closed"`
- 网络错误: `err` 包含具体错误信息(如 `"Connection reset by peer"`)
- 主动关闭: `err` 为 `"active closed"`

## 扩展练习

### 1. 支持多客户端并发

当前代码已经支持多客户端,但你可以尝试:

```lua
-- 添加连接计数
local connections = 0

socket.listen("127.0.0.1:9999", function(fd, addr)
    connections = connections + 1
    print(string.format("新连接 [%d] 来自 %s, 当前连接数: %d",
        fd, addr, connections))

    while true do
        local line, err = socket.readline(fd)
        if not line then break end
        socket.write(fd, line)
    end

    connections = connections - 1
    socket.close(fd)
    print(string.format("连接关闭 [%d], 剩余连接数: %d",
        fd, connections))
end)
```

### 2. 添加超时处理

使用 `silly.timeout()` 添加超时机制:

```lua
local time = require "silly.time"

socket.listen("127.0.0.1:9999", function(fd, addr)
    print("新连接:", fd, addr)

    -- 设置 30 秒超时
    local timeout_timer = time.timeout(30000, function()
        print("连接超时:", fd)
        socket.close(fd)
    end)

    while true do
        local line, err = socket.readline(fd)
        if not line then break end

        -- 有数据活动,重置超时
        time.cancel(timeout_timer)
        timeout_timer = time.timeout(30000, function()
            print("连接超时:", fd)
            socket.close(fd)
        end)

        socket.write(fd, line)
    end

    time.cancel(timeout_timer)
    socket.close(fd)
end)
```

### 3. 添加数据统计

记录每个连接的数据传输量:

```lua
socket.listen("127.0.0.1:9999", function(fd, addr)
    local bytes_recv = 0
    local bytes_sent = 0
    local msg_count = 0

    print("新连接:", fd, addr)

    while true do
        local line, err = socket.readline(fd)
        if not line then break end

        bytes_recv = bytes_recv + #line
        msg_count = msg_count + 1

        local ok = socket.write(fd, line)
        if ok then
            bytes_sent = bytes_sent + #line
        else
            break
        end
    end

    socket.close(fd)
    print(string.format("连接 [%d] 统计: 接收 %d 字节, 发送 %d 字节, 消息数 %d",
        fd, bytes_recv, bytes_sent, msg_count))
end)
```

### 4. 实现简单的协议

让 Echo 服务器支持简单的命令:

```lua
socket.listen("127.0.0.1:9999", function(fd, addr)
    socket.write(fd, "欢迎使用 Silly Echo 服务器!\n")
    socket.write(fd, "输入 'help' 查看命令\n")

    while true do
        socket.write(fd, "> ")
        local line, err = socket.readline(fd)
        if not line then break end

        local cmd = line:match("^%s*(.-)%s*$")  -- 去除空白

        if cmd == "help" then
            socket.write(fd, "命令列表:\n")
            socket.write(fd, "  help  - 显示此帮助\n")
            socket.write(fd, "  time  - 显示服务器时间\n")
            socket.write(fd, "  quit  - 断开连接\n")
        elseif cmd == "time" then
            socket.write(fd, os.date() .. "\n")
        elseif cmd == "quit" then
            socket.write(fd, "再见!\n")
            break
        else
            socket.write(fd, "回显: " .. line)
        end
    end

    socket.close(fd)
end)
```

### 5. 性能测试

编写压力测试客户端:

```lua
local silly = require "silly"
local socket = require "silly.net.tcp"

local client_count = 100  -- 100 个并发客户端
local msg_per_client = 100  -- 每个客户端发送 100 条消息

local start_time = os.time()
local total_messages = 0

for i = 1, client_count do
    silly.fork(function()
        local fd = socket.connect("127.0.0.1:9999")
        if not fd then return end

        for j = 1, msg_per_client do
            socket.write(fd, "test message\n")
            local msg = socket.readline(fd)
            if msg then
                total_messages = total_messages + 1
            end
        end

        socket.close(fd)

        if i == client_count then
            local elapsed = os.time() - start_time
            print(string.format("完成: %d 消息, 用时 %d 秒, %.2f msg/s",
                total_messages, elapsed, total_messages / elapsed))
        end
    end)
end
```

## 下一步

恭喜你完成了 TCP Echo 服务器教程!现在你已经掌握了:

- Silly 框架的基本使用
- TCP 服务器的实现
- 协程和异步 I/O
- 错误处理和资源管理

接下来,你可以学习:

- **[HTTP 服务器教程](./http-server.md)**: 构建 Web 应用
- **[WebSocket 教程](./websocket-server.md)**: 实现实时通信
- **[RPC 教程](./rpc-server.md)**: 构建分布式系统

继续探索 Silly 框架的强大功能!
