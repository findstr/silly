---
title: silly.net.websocket
icon: plug
category:
  - API参考
tag:
  - 网络
  - WebSocket
  - 实时通信
---

# silly.net.websocket

`silly.net.websocket` 模块提供了完整的 WebSocket 协议实现（RFC 6455），支持服务器端和客户端。它基于协程构建，提供简洁的异步 API，自动处理握手、帧编解码、分片、掩码等协议细节。

## 模块导入

```lua validate
local websocket = require "silly.net.websocket"
```

## 核心概念

### WebSocket 协议

WebSocket 是一种在单个 TCP 连接上进行全双工通信的协议，主要特点：

- **双向通信**: 服务器和客户端可以随时主动发送消息
- **低延迟**: 相比 HTTP 轮询，WebSocket 避免了频繁的握手开销
- **帧类型**: 支持文本帧、二进制帧和控制帧（ping/pong/close）
- **自动分片**: 大消息自动分片传输，透明处理

### 帧类型

WebSocket 支持以下帧类型：

- **text**: 文本消息（UTF-8 编码）
- **binary**: 二进制消息
- **ping**: 心跳探测帧
- **pong**: 心跳响应帧
- **close**: 连接关闭帧
- **continuation**: 分片延续帧（自动处理）

### Socket 对象

WebSocket 连接使用 socket 对象表示：

- **服务器端**: handler 函数接收 socket 对象处理连接
- **客户端**: connect 函数返回 socket 对象用于通信

---

## 服务器端 API

### websocket.listen(conf)

创建 WebSocket 服务器并开始监听。

- **参数**:
  - `conf`: `table` - 服务器配置表
    - `addr`: `string` (必需) - 监听地址，例如 `"127.0.0.1:8080"` 或 `":8080"`
    - `handler`: `function` (必需) - 连接处理函数 `function(sock)`
    - `tls`: `boolean|nil` (可选) - 是否启用 TLS（WebSocket Secure）
    - `certs`: `table[]|nil` (可选) - TLS 证书配置（仅当 `tls = true` 时）
      - `cert`: `string` - PEM 格式证书
      - `key`: `string` - PEM 格式私钥
    - `backlog`: `integer|nil` (可选) - 监听队列大小
- **返回值**:
  - 成功: `server` - 服务器对象
  - 失败: `nil, string` - nil 和错误信息
- **注意**: 自动处理 HTTP 握手升级到 WebSocket 协议
- **示例**:

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local server, err = websocket.listen {
        addr = "127.0.0.1:8080",
        handler = function(sock)
            -- 读取客户端消息
            local data, typ = sock:read()
            if data and typ == "text" then
                print("Received:", data)

                -- 回复消息
                sock:write("Echo: " .. data, "text")
            end

            sock:close()
        end
    }

    if not server then
        print("Server start failed:", err)
        return
    end

    print("WebSocket server listening on 127.0.0.1:8080")
end)
```

### server:close()

关闭 WebSocket 服务器。

- **参数**: 无
- **返回值**: 无
- **示例**:

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local server = websocket.listen {
        addr = ":8080",
        handler = function(sock)
            sock:close()
        end
    }

    -- 稍后关闭服务器
    server:close()
    print("Server closed")
end)
```

---

## 客户端 API

### websocket.connect(url [, header])

连接到 WebSocket 服务器（异步）。

- **参数**:
  - `url`: `string` - WebSocket URL（`ws://` 或 `wss://` 开头）
  - `header`: `table|nil` (可选) - 自定义 HTTP 请求头
- **返回值**:
  - 成功: `socket` - WebSocket socket 对象
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 会挂起协程直到连接建立或失败
- **注意**:
  - 使用 `ws://` 表示普通连接，`wss://` 表示 TLS 加密连接
  - 自动发送 WebSocket 握手请求
- **示例**:

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock, err = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        print("Connect failed:", err)
        return
    end

    print("Connected to WebSocket server")

    -- 发送消息
    sock:write("Hello, Server!", "text")

    -- 读取响应
    local data, typ = sock:read()
    if data then
        print("Received:", data)
    end

    sock:close()
end)
```

---

## Socket API

连接建立后，socket 对象提供以下方法进行通信。

### sock:read()

读取一个 WebSocket 消息（异步）。

- **参数**: 无
- **返回值**:
  - 成功: `string, string` - 消息数据和帧类型
  - 失败: `nil, string, string` - nil、错误信息和部分数据
- **帧类型**: `"text"`, `"binary"`, `"ping"`, `"pong"`, `"close"`, `"continuation"`
- **异步**: 会挂起协程直到收到完整消息
- **注意**:
  - 自动处理分片消息，返回完整内容
  - 返回 `close` 类型时，连接即将关闭
- **示例**:

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    -- 循环读取消息
    while true do
        local data, typ = sock:read()

        if not data then
            print("Connection closed or error")
            break
        end

        if typ == "text" then
            print("Text message:", data)
        elseif typ == "binary" then
            print("Binary message, length:", #data)
        elseif typ == "ping" then
            print("Received ping:", data)
            sock:write(data, "pong")  -- 回复 pong
        elseif typ == "close" then
            print("Close frame received")
            break
        end
    end

    sock:close()
end)
```

### sock:write(data [, type])

发送 WebSocket 消息（异步）。

- **参数**:
  - `data`: `string|nil` - 要发送的数据（可为空字符串或 nil）
  - `type`: `string|nil` (可选) - 帧类型，默认 `"binary"`
    - 可选值: `"text"`, `"binary"`, `"ping"`, `"pong"`, `"close"`
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息
- **注意**:
  - 控制帧（ping/pong/close）的数据长度不能超过 125 字节
  - 大消息（>= 64KB）会自动分片发送
  - 文本消息应该是有效的 UTF-8 编码
- **示例**:

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    -- 发送文本消息
    local ok, err = sock:write("Hello, World!", "text")
    if not ok then
        print("Send failed:", err)
        sock:close()
        return
    end

    -- 发送二进制消息
    local binary_data = string.char(0x01, 0x02, 0x03, 0x04)
    sock:write(binary_data, "binary")

    -- 发送 ping
    sock:write("ping", "ping")

    -- 发送大消息（自动分片）
    local large_data = string.rep("A", 1024 * 1024)  -- 1MB
    sock:write(large_data, "binary")

    sock:close()
end)
```

### sock:close()

关闭 WebSocket 连接。

- **参数**: 无
- **返回值**: 无
- **注意**:
  - 自动发送 close 帧
  - 调用后 socket 不可再使用
- **示例**:

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    sock:write("Goodbye", "text")

    -- 优雅关闭连接
    sock:close()
    print("Connection closed")
end)
```

### sock 属性

socket 对象包含以下只读属性：

- `sock.fd`: `integer` - 底层文件描述符
- `sock.stream`: `table` - HTTP stream 对象（包含原始连接信息）

---

## 使用示例

### 示例1：基础 Echo 服务器

简单的 WebSocket Echo 服务器，回显客户端消息：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local server = websocket.listen {
        addr = "127.0.0.1:8080",
        handler = function(sock)
            print("New WebSocket connection")

            while true do
                local data, typ = sock:read()

                if not data then
                    print("Connection closed")
                    break
                end

                if typ == "text" then
                    print("Received:", data)
                    sock:write("Echo: " .. data, "text")
                elseif typ == "binary" then
                    print("Binary data, length:", #data)
                    sock:write(data, "binary")  -- Echo back
                elseif typ == "close" then
                    print("Close frame received")
                    break
                end
            end

            sock:close()
        end
    }

    print("Echo server listening on 127.0.0.1:8080")
end)
```

### 示例2：WebSocket 客户端

连接到 WebSocket 服务器并交换消息：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock, err = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        print("Connect failed:", err)
        return
    end

    print("Connected to server")

    -- 发送多个消息
    for i = 1, 5 do
        local message = "Message " .. i
        local ok = sock:write(message, "text")

        if ok then
            print("Sent:", message)

            -- 读取响应
            local data, typ = sock:read()
            if data and typ == "text" then
                print("Received:", data)
            end
        end
    end

    sock:close()
    print("Client disconnected")
end)
```

### 示例3：心跳保活

使用 ping/pong 帧实现连接保活：

```lua validate
local silly = require "silly"
local time = require "silly.time"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local server = websocket.listen {
        addr = "127.0.0.1:8080",
        handler = function(sock)
            print("Client connected")

            -- 启动心跳协程
            silly.fork(function()
                while true do
                    time.sleep(5000)  -- 每 5 秒发送 ping
                    local ok = sock:write("heartbeat", "ping")
                    if not ok then
                        print("Ping failed, connection lost")
                        break
                    end
                    print("Sent ping")
                end
            end)

            -- 处理消息
            while true do
                local data, typ = sock:read()

                if not data then
                    break
                end

                if typ == "pong" then
                    print("Received pong:", data)
                elseif typ == "text" then
                    sock:write("Received: " .. data, "text")
                elseif typ == "close" then
                    break
                end
            end

            sock:close()
            print("Client disconnected")
        end
    }

    print("Server with heartbeat listening on 127.0.0.1:8080")
end)
```

### 示例4：广播服务器

向所有连接的客户端广播消息：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"
local channel = require "silly.sync.channel"

silly.fork(function()
    local clients = {}
    local broadcast_chan = channel.new()

    -- 广播协程
    silly.fork(function()
        while true do
            local message = broadcast_chan:recv()

            -- 向所有客户端发送消息
            for i, sock in ipairs(clients) do
                local ok = sock:write(message, "text")
                if not ok then
                    -- 移除断开的客户端
                    table.remove(clients, i)
                end
            end

            print("Broadcasted to", #clients, "clients")
        end
    end)

    local server = websocket.listen {
        addr = "127.0.0.1:8080",
        handler = function(sock)
            -- 添加新客户端
            table.insert(clients, sock)
            print("Client connected, total:", #clients)

            sock:write("Welcome to broadcast server!", "text")

            -- 读取客户端消息并广播
            while true do
                local data, typ = sock:read()

                if not data or typ == "close" then
                    break
                end

                if typ == "text" then
                    -- 广播消息
                    broadcast_chan:send(data)
                end
            end

            -- 移除断开的客户端
            for i, client in ipairs(clients) do
                if client == sock then
                    table.remove(clients, i)
                    break
                end
            end

            sock:close()
            print("Client disconnected, remaining:", #clients)
        end
    }

    print("Broadcast server listening on 127.0.0.1:8080")
end)
```

### 示例5：JSON 消息通信

使用 JSON 格式进行结构化通信：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"
local json = require "silly.encoding.json"

silly.fork(function()
    local server = websocket.listen {
        addr = "127.0.0.1:8080",
        handler = function(sock)
            print("Client connected")

            while true do
                local data, typ = sock:read()

                if not data or typ == "close" then
                    break
                end

                if typ == "text" then
                    -- 解析 JSON 消息
                    local message = json.decode(data)

                    if message and message.type == "request" then
                        print("Request:", message.action)

                        -- 构造 JSON 响应
                        local response = {
                            type = "response",
                            action = message.action,
                            status = "success",
                            data = {
                                timestamp = os.time(),
                                echo = message.payload
                            }
                        }

                        sock:write(json.encode(response), "text")
                    end
                end
            end

            sock:close()
        end
    }

    print("JSON WebSocket server listening on 127.0.0.1:8080")
end)
```

### 示例6：安全 WebSocket（WSS）

使用 TLS 加密创建安全的 WebSocket 服务器：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local cert_pem = [[-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUPc2faaWEjGh1RklF9XPAgYS5WSMwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI1MTAwOTA5NDc1M1oXDTM1MTAw
NzA5NDc1M1owFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEApmUl+7J8zeWdOH6aiNwRSOcFePTxuAyYsAEewVtBCAEv
LVGxQtrsVvd6UosEd0aO/Qz3hvV32wYzI0ZzjGGfy0lCCx9YB05SyYY+KpDwe/os
Mf4RtBS/jN1dVX7TiRQ3KsngMFSXp2aC6IpI5ngF0PS/o2qbwkU19FCELE6G5WnA
fniUaf7XEwrhAkMAczJovqOu4BAhBColr7cQK7CQK6VNEhQBzM/N/hGmIniPbC7k
TjqyohWoLGPT+xQAe8WB39zbIHl+xEDoGAYaaI8I7TlcQWwCOIxdm+w67CQmC/Fy
GTX5fPoK96drushzwvAKphQrpQwT5MxTDvoE9xgbhQIDAQABo1MwUTAdBgNVHQ4E
FgQUsjX1LC+0rS4Ls5lcE8yg5P85LqQwHwYDVR0jBBgwFoAUsjX1LC+0rS4Ls5lc
E8yg5P85LqQwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEADqDJ
HQxRjFPSxIk5EMrxkqxE30LoWKJeW9vqublQU/qHfMo7dVTwfsAvFpTJfL7Zhhqw
l20ijbQVxPtDwPB8alQ/ScP5VRqC2032KTi9CqUqTj+y58oDxgjnm06vr5d8Xkmm
nR2xhUecGkzFYlDoXo1w8XttMUefyHS6HWLXvu94V7Y/8YB4lBCEnwFnhgkYB9CG
RsleiOiZDsaHhnNQsnM+Xl1UJVxJlMStl+Av2rCTAj/LMHniXQ+9QKI/7pNDUeCL
qSdxZephYkeRF8C/i9R5G/gAL40kUFz0sgyXuv/kss3rrxsshKKTRbxnRm1k/J73
9ZiztVOeqpcxFxmf7Q==
-----END CERTIFICATE-----
]]

    local key_pem = [[-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCmZSX7snzN5Z04
fpqI3BFI5wV49PG4DJiwAR7BW0EIAS8tUbFC2uxW93pSiwR3Ro79DPeG9XfbBjMj
RnOMYZ/LSUILH1gHTlLJhj4qkPB7+iwx/hG0FL+M3V1VftOJFDcqyeAwVJenZoLo
ikjmeAXQ9L+japvCRTX0UIQsToblacB+eJRp/tcTCuECQwBzMmi+o67gECEEKiWv
txArsJArpU0SFAHMz83+EaYieI9sLuROOrKiFagsY9P7FAB7xYHf3NsgeX7EQOgY
BhpojwjtOVxBbAI4jF2b7DrsJCYL8XIZNfl8+gr3p2u6yHPC8AqmFCulDBPkzFMO
+gT3GBuFAgMBAAECggEAD5uyVetWuKuetVNu5IKcHnYJNeDoIacQ1YWtYF7SeVE/
HyWoFojZnYjGUSLYLuYP+J20RFUXQpTQzDDKGvN3XUbIaqmshLbsnhm5EB4baM29
Qo0+FOHTW//RxvjIF/Ys/JcGMBJnTV0Yz35VO0Ur6n9i0I3qAW2jk4DP/SX6kl9T
4iJj2Y+69y0bHjesfO71nCUUH6Ym2CHJRd6A4tCeYQr3U/CXOWggpUuPTXFWptt7
uSJjbTQgwUF5H83ih1CUdto1G5LPBUXVD5x2XZshgwZsL1au9kH2l/83BAHKK8io
LQ8FekLN6FLD83mvEwFPyrVhfipbeUz3bKrgEzvOmwKBgQDUbrAgRYCLxxpmguiN
0aPV85xc+VPL+dh865QHhJ0pH/f3fah/U7van/ayfG45aIA+DI7qohGzf03xFnO4
O51RHcRhnjDbXWY5l0ZpOIpvHLLCm8gqIAkX9bt7UyE+PxRSNvUt3kVFT3ZYnYCx
Wb1kiV1oRAzTf1l0X0qamFPqdwKBgQDIhV8OWTBrsuC0U3hmvNB+DPEHnyPWBHvI
+HMflas5gJiZ+3KvrS3vBOXFB3qfTD1LQwUPqeqY0Q41Svvsq2IQAkKedJDdMuPU
RoKaV/Qln85nmibscNcwVGQNUKTeSCJQ43ktrWT01UinamsSEOYTceMqwW10LDaF
Ff1MbKNs4wKBgQDMEPiIR7vQipdF2oNjmPt1z+tpNOnWjE/20KcHAdGna9pcmQ2A
IwPWZMwrcXTBGS34bT/tDXtLnwNUkWjglgPtpFa+H6R3ViWZNUSiV3pEeqEOaW/D
Z7rUlW5gbd8FWLtAryKfyWFpz4e0YLj7pWVWas6cFqLrmO5p6BBWqfYSyQKBgHyp
rjcVa+0JAHobircUm+pB0XeTkIv1rZ98FtaEDjdpo3XXxa1CVVRMDy03QRzYISMx
P2xFjvwCvHqVa5nv0r9xKEmq3oUmpk3KqFecZsUdXQ074QcOADqjvLAqetVWsz7m
rOeg7SrpjonGt1o7904Pd9OU/Z9D/YEv8pIY2GFRAoGASEf3+igRFSECUxLh9LZC
scAxCHh9sz15swDD/rdtEqLKGcxlu74YKkBnyQ/yWA4d/enPnvdP98ThXdXnX0X4
v1HSCliKZXW8cusnBRD2IOyxuIUV/qiMfARylMvlLBccgJR8+olH9f/yF2EFWhoy
125zQzr/ESlTL+5IWeNf2sM=
-----END PRIVATE KEY-----
]]

    local server = websocket.listen {
        tls = true,
        addr = "127.0.0.1:8443",
        certs = {
            {
                cert = cert_pem,
                key = key_pem,
            }
        },
        handler = function(sock)
            sock:write("Secure connection established", "text")

            while true do
                local data, typ = sock:read()
                if not data or typ == "close" then
                    break
                end

                if typ == "text" then
                    sock:write("Secure echo: " .. data, "text")
                end
            end

            sock:close()
        end
    }

    print("Secure WebSocket (WSS) server listening on 127.0.0.1:8443")
end)
```

### 示例7：二进制数据传输

传输二进制数据（如图片、文件等）：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local server = websocket.listen {
        addr = "127.0.0.1:8080",
        handler = function(sock)
            print("Client connected")

            while true do
                local data, typ = sock:read()

                if not data or typ == "close" then
                    break
                end

                if typ == "binary" then
                    print("Received binary data, size:", #data)

                    -- 处理二进制数据
                    -- 例如：保存文件、处理图片等

                    -- 发送确认
                    local response = string.pack(">I4I4",
                        0x01,      -- 类型：确认
                        #data      -- 接收的字节数
                    )
                    sock:write(response, "binary")
                end
            end

            sock:close()
        end
    }

    print("Binary WebSocket server listening on 127.0.0.1:8080")
end)
```

### 示例8：自动重连客户端

实现自动重连的健壮客户端：

```lua validate
local silly = require "silly"
local time = require "silly.time"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local url = "ws://127.0.0.1:8080"
    local reconnect_delay = 1000  -- 1 秒
    local max_reconnect_delay = 30000  -- 最大 30 秒

    while true do
        local sock, err = websocket.connect(url)

        if not sock then
            print("Connect failed:", err)
            print("Reconnecting in", reconnect_delay / 1000, "seconds...")
            time.sleep(reconnect_delay)

            -- 指数退避
            reconnect_delay = math.min(reconnect_delay * 2, max_reconnect_delay)
            goto continue
        end

        print("Connected to server")
        reconnect_delay = 1000  -- 重置延迟

        -- 通信循环
        while true do
            -- 发送消息
            local ok = sock:write("Hello from auto-reconnect client", "text")
            if not ok then
                print("Send failed, reconnecting...")
                break
            end

            -- 读取响应
            local data, typ = sock:read()
            if not data then
                print("Read failed, reconnecting...")
                break
            end

            if typ == "close" then
                print("Server closed connection")
                break
            end

            print("Received:", data)
            time.sleep(5000)  -- 等待 5 秒后继续
        end

        sock:close()

        ::continue::
    end
end)
```

---

## 注意事项

### 1. 协程要求

所有 WebSocket API 必须在协程中调用：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

-- 错误：不能在主线程调用
-- local sock = websocket.connect("ws://example.com")  -- 会失败

-- 正确：在协程中调用
silly.fork(function()
    local sock = websocket.connect("ws://example.com")
    -- ...
end)
```

### 2. 控制帧大小限制

根据 RFC 6455，控制帧（ping/pong/close）的有效载荷不能超过 125 字节：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    -- 正确：小于 125 字节
    sock:write("ping", "ping")

    -- 错误：超过 125 字节会失败
    local large_ping = string.rep("A", 200)
    local ok, err = sock:write(large_ping, "ping")
    if not ok then
        print("Error:", err)  -- "all control frames MUST have a payload length of 125 bytes or less"
    end

    sock:close()
end)
```

### 3. 自动分片

大消息会自动分片传输，对应用透明：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    -- 发送 1MB 消息，自动分片
    local large_message = string.rep("X", 1024 * 1024)
    sock:write(large_message, "binary")

    -- 接收时自动重组
    local data, typ = sock:read()
    print("Received complete message, size:", #data)  -- 1048576

    sock:close()
end)
```

### 4. 文本 vs 二进制

文本帧应该是有效的 UTF-8 编码：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    -- 正确：文本使用 UTF-8
    sock:write("Hello, 世界!", "text")

    -- 二进制可以是任意字节
    local binary_data = string.char(0x00, 0xFF, 0xFE, 0xFD)
    sock:write(binary_data, "binary")

    sock:close()
end)
```

### 5. 心跳处理

处理 ping 帧时应该回复 pong：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    while true do
        local data, typ = sock:read()

        if not data then
            break
        end

        if typ == "ping" then
            -- 必须回复 pong，携带相同的数据
            sock:write(data, "pong")
        elseif typ == "text" then
            print("Message:", data)
        elseif typ == "close" then
            break
        end
    end

    sock:close()
end)
```

### 6. 优雅关闭

应该等待对方的 close 帧：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    sock:write("Goodbye", "text")

    -- sock:close() 会发送 close 帧
    -- 标准做法是等待对方的 close 帧
    local data, typ = sock:read()
    if typ == "close" then
        print("Received close frame from server")
    end

    sock:close()
end)
```

### 7. 错误处理

始终检查返回值：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock, err = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        print("Connect failed:", err)
        return
    end

    local ok, err = sock:write("test", "text")
    if not ok then
        print("Write failed:", err)
        sock:close()
        return
    end

    local data, typ = sock:read()
    if not data then
        print("Read failed:", typ)  -- typ 包含错误信息
        sock:close()
        return
    end

    print("Success:", data)
    sock:close()
end)
```

---

## 性能建议

### 1. 消息批量发送

批量发送多个小消息以减少系统调用：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    -- 低效：多次发送
    for i = 1, 100 do
        sock:write("Message " .. i, "text")
    end

    -- 高效：合并消息
    local messages = {}
    for i = 1, 100 do
        messages[i] = "Message " .. i
    end
    sock:write(table.concat(messages, "\n"), "text")

    sock:close()
end)
```

### 2. 使用二进制帧

对于非文本数据，使用二进制帧性能更好：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    -- 数字数据使用二进制编码
    local data = string.pack(">I4I4f", 12345, 67890, 3.14159)
    sock:write(data, "binary")

    local received = sock:read()
    if received then
        local a, b, c = string.unpack(">I4I4f", received)
        print("Received:", a, b, c)
    end

    sock:close()
end)
```

### 3. 连接复用

对于高频通信，保持长连接而不是频繁重连：

```lua validate
local silly = require "silly"
local time = require "silly.time"
local websocket = require "silly.net.websocket"

silly.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then
        return
    end

    -- 保持连接，持续通信
    for i = 1, 1000 do
        sock:write("Request " .. i, "text")
        local data = sock:read()
        -- 处理响应...
        time.sleep(100)  -- 短暂延迟
    end

    sock:close()
end)
```

### 4. 并发连接

使用协程实现并发 WebSocket 连接：

```lua validate
local silly = require "silly"
local websocket = require "silly.net.websocket"
local waitgroup = require "silly.sync.waitgroup"

silly.fork(function()
    local wg = waitgroup.new()

    -- 创建多个并发连接
    for i = 1, 10 do
        wg:fork(function()
            local sock = websocket.connect("ws://127.0.0.1:8080")
            if sock then
                sock:write("Hello from client " .. i, "text")
                local data = sock:read()
                print("Client", i, "received:", data)
                sock:close()
            end
        end)
    end

    wg:wait()
    print("All clients completed")
end)
```

---

## 参见

- [silly](../silly.md) - 核心调度器
- [silly.net.http](./http.md) - HTTP 协议（WebSocket 基于 HTTP 升级）
- [silly.net.tcp](./tcp.md) - TCP 协议
- [silly.net.tls](./tls.md) - TLS/SSL 加密
- [silly.encoding.json](../encoding/json.md) - JSON 编解码
- [silly.sync.channel](../sync/channel.md) - 协程通道
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
