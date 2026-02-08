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

### 升级机制

WebSocket 连接通常由 HTTP 连接升级而来。在 `silly` 中，服务器端需要先使用 `silly.net.http` 接收连接，然后调用 `websocket.upgrade` 将其升级为 WebSocket 连接。

### Socket 对象

WebSocket 连接使用 socket 对象表示：

- **服务器端**: `upgrade` 函数返回 socket 对象
- **客户端**: `connect` 函数返回 socket 对象

---

## 服务器端 API

### websocket.upgrade(stream)

将一个 HTTP stream 升级为 WebSocket 连接。

- **参数**:
  - `stream`: `table` - HTTP stream 对象（由 `http.listen` 的 handler 提供）
- **返回值**:
  - 成功: `socket` - WebSocket socket 对象
  - 失败: `nil, string` - nil 和错误信息
- **注意**:
  - 调用此函数前，stream 必须处于打开状态
  - 升级成功后，不要再操作原有的 stream 对象
- **示例**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"

task.fork(function()
    local server = http.listen {
        addr = ":8080",
        handler = function(stream)
            -- 检查是否是 WebSocket 升级请求
            if stream.header["upgrade"] == "websocket" then
                local sock, err = websocket.upgrade(stream)
                if not sock then
                    print("Upgrade failed:", err)
                    return
                end

                -- WebSocket 通信循环
                while true do
                    local data, typ = sock:read()
                    if not data then
                        break
                    end

                    if typ == "text" then
                        sock:write("Echo: " .. data, "text")
                    elseif typ == "close" then
                        break
                    end
                end

                sock:close()
            else
                -- 处理普通 HTTP 请求
                stream:respond(200, {["content-type"] = "text/plain"})
                stream:closewrite("Not a WebSocket request")
            end
        end
    }

    print("WebSocket server listening on :8080")
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
local task = require "silly.task"
local websocket = require "silly.net.websocket"

task.fork(function()
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
local task = require "silly.task"
local websocket = require "silly.net.websocket"

task.fork(function()
    local sock = websocket.connect("ws://127.0.0.1:8080")
    if not sock then return end

    while true do
        local data, typ = sock:read()
        if not data then break end

        if typ == "text" then
            print("Text:", data)
        elseif typ == "ping" then
            sock:write(data, "pong")
        elseif typ == "close" then
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

### sock:close()

关闭 WebSocket 连接。

- **参数**: 无
- **返回值**: 无
- **注意**:
  - 自动发送 close 帧
  - 调用后 socket 不可再使用

### sock 属性

socket 对象包含以下只读属性：

- `sock.conn`: `table` - 底层连接对象 (tcp 或 tls)
- `sock.stream`: `table` - 关联的 HTTP stream 对象

---

## 使用示例

### 示例1：广播服务器

向所有连接的客户端广播消息：

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"
local channel = require "silly.sync.channel"

task.fork(function()
    local clients = {}
    local broadcast_chan = channel.new()

    -- 广播协程
    task.fork(function()
        while true do
            local message = broadcast_chan:recv()
            for i, sock in ipairs(clients) do
                sock:write(message, "text")
            end
        end
    end)

    http.listen {
        addr = ":8080",
        handler = function(stream)
            if stream.header["upgrade"] == "websocket" then
                local sock = websocket.upgrade(stream)
                if sock then
                    table.insert(clients, sock)

                    while true do
                        local data, typ = sock:read()
                        if not data or typ == "close" then break end
                        if typ == "text" then
                            broadcast_chan:send(data)
                        end
                    end

                    -- 移除客户端 (简化处理，实际需更严谨)
                    for i, v in ipairs(clients) do
                        if v == sock then
                            table.remove(clients, i)
                            break
                        end
                    end
                    sock:close()
                end
            else
                stream:respond(404, {})
                stream:closewrite()
            end
        end
    }
end)
```

### 示例2：安全 WebSocket (WSS)

使用 HTTPS 服务器升级到 WSS：

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"

task.fork(function()
    -- 证书配置 (省略具体内容)
    local certs = {{
        cert = "-----BEGIN CERTIFICATE-----\n...",
        key = "-----BEGIN PRIVATE KEY-----\n..."
    }}

    http.listen {
        addr = ":8443",
        certs = certs,
        handler = function(stream)
            if stream.header["upgrade"] == "websocket" then
                local sock = websocket.upgrade(stream)
                if sock then
                    sock:write("Secure connection established", "text")
                    -- ... 通信循环
                    sock:close()
                end
            end
        end
    }
end)
```
