---
title: WebSocket 聊天室
icon: comments
order: 5
category:
  - 教程
tag:
  - WebSocket
  - 实时通信
  - 聊天室
  - 广播
---

# WebSocket 聊天室

本教程将带你从零开始构建一个功能完整的 WebSocket 聊天室，学习 WebSocket 协议、实时双向通信和广播机制。

## 学习目标

通过本教程，你将学会：

- WebSocket 协议的核心概念和使用场景
- 使用 `silly.net.websocket` 模块创建实时通信服务器
- 实现用户连接管理和在线列表
- 消息广播和点对点私聊
- 处理客户端连接、断开和异常情况
- 使用 HTML5 WebSocket API 构建浏览器客户端

## WebSocket 基础

### 什么是 WebSocket

WebSocket 是一种在单个 TCP 连接上进行全双工通信的协议（RFC 6455）。它提供了：

- **双向实时通信**：服务器和客户端可以随时主动发送消息，无需等待
- **低延迟**：建立连接后，数据传输没有 HTTP 请求/响应的开销
- **持久连接**：连接建立后保持开启，适合长时间通信
- **轻量级**：帧头部只有 2-14 字节，比 HTTP 请求头小得多

### 与 HTTP 的区别

| 特性 | HTTP | WebSocket |
|------|------|-----------|
| 通信模式 | 请求-响应（单向） | 全双工（双向） |
| 连接 | 短连接（或 Keep-Alive） | 长连接 |
| 实时性 | 需要轮询 | 服务器主动推送 |
| 开销 | 每次请求都有完整头部 | 握手后只有小帧头 |
| 使用场景 | 传统网页、API | 聊天、实时推送、游戏 |

### WebSocket 连接流程

1. **HTTP 握手**：客户端发送 HTTP Upgrade 请求
2. **协议升级**：服务器返回 101 状态码，协议切换到 WebSocket
3. **数据传输**：双方通过 WebSocket 帧交换数据
4. **关闭连接**：任一方发送 close 帧关闭连接

### 使用场景

- **即时通讯**：聊天室、在线客服
- **实时推送**：股票行情、消息通知
- **协作应用**：多人编辑、白板
- **游戏**：实时对战、状态同步
- **直播互动**：弹幕、礼物

## 实现步骤

### Step 1: 创建基础 WebSocket 服务器

让我们从最简单的 Echo 服务器开始，它会将客户端发送的消息原样返回：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        if stream.header["upgrade"] ~= "websocket" then
            stream:respond(404, {})
            stream:close("Not Found")
            return
        end

        local sock, err = websocket.upgrade(stream)
        if not sock then
            print("Upgrade failed:", err)
            return
        end

        print("New client connected")

        while true do
            -- 读取客户端消息
            local data, typ = sock:read()
            if not data then
                print("客户端断开:", sock.fd, typ)  -- typ is error message when data is nil
                break
            end

            if typ == "text" then
                print("Received:", data)
                sock:write("Echo: " .. data, "text")
            elseif typ == "close" then
                print("Client closing connection")
                break
            end
        end

        sock:close()
    end
}

print("WebSocket Echo server listening on ws://127.0.0.1:8080")
```

**代码解析**：

1. `http.listen` 和 `websocket.upgrade`：创建 WebSocket 服务器
2. `handler` 函数：处理每个客户端连接（在独立协程中运行）
3. `sock:read()`：异步读取消息，返回数据和帧类型
4. `sock:write(data, type)`：发送消息（text 或 binary）
5. `sock:close()`：关闭连接

**测试服务器**：

保存代码为 `echo_server.lua`，运行：

```bash
./silly echo_server.lua
```

使用浏览器控制台测试：

```javascript
const ws = new WebSocket('ws://127.0.0.1:8080');
ws.onopen = () => ws.send('Hello, Server!');
ws.onmessage = (event) => console.log('Received:', event.data);
```

### Step 2: 处理连接和断开

在真实聊天室中，我们需要管理所有连接的客户端：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"

-- 全局客户端列表
local clients = {}
local next_id = 1

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        if stream.header["upgrade"] ~= "websocket" then
            stream:respond(404, {})
            stream:close("Not Found")
            return
        end

        local sock, err = websocket.upgrade(stream)
        if not sock then
            return
        end

        -- 为客户端分配唯一 ID
        local client_id = next_id
        next_id = next_id + 1

        -- 添加到客户端列表
        clients[client_id] = {
            id = client_id,
            sock = sock,
            name = "User" .. client_id,
        }

        print(string.format("[%s] Client %d connected", os.date("%H:%M:%S"), client_id))

        -- 向客户端发送欢迎消息
        sock:write(string.format("Welcome! You are User%d. Total users: %d",
                                 client_id, #clients), "text")

        -- 消息循环
        while true do
            local data, typ = sock:read()

            if not data or typ == "close" then
                break
            end

            if typ == "text" then
                print(string.format("[User%d] %s", client_id, data))
            end
        end

        -- 从客户端列表移除
        clients[client_id] = nil
        sock:close()
        print(string.format("[%s] Client %d disconnected. Remaining: %d",
                           os.date("%H:%M:%S"), client_id, #clients))
    end
}

print("WebSocket server with connection management on ws://127.0.0.1:8080")
```

**关键改进**：

- 每个客户端分配唯一 ID
- 使用 `clients` 表存储所有连接
- 连接建立时发送欢迎消息
- 断开时从列表中移除客户端

### Step 3: 消息广播

聊天室的核心功能是将一个用户的消息广播给所有其他用户：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"

local clients = {}
local next_id = 1

-- 广播消息给所有客户端（除了发送者）
local function broadcast(sender_id, message)
    local sender_name = clients[sender_id] and clients[sender_id].name or "Unknown"
    local full_message = string.format("[%s] %s", sender_name, message)

    local success_count = 0
    for id, client in pairs(clients) do
        if id ~= sender_id then  -- 不发送给自己
            local ok = client.sock:write(full_message, "text")
            if ok then
                success_count = success_count + 1
            end
        end
    end

    return success_count
end

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        if stream.header["upgrade"] ~= "websocket" then
            stream:respond(404, {})
            stream:close("Not Found")
            return
        end

        local sock, err = websocket.upgrade(stream)
        if not sock then
            return
        end

        local client_id = next_id
        next_id = next_id + 1

        clients[client_id] = {
            id = client_id,
            sock = sock,
            name = "User" .. client_id,
        }

        print(string.format("[JOIN] User%d connected. Total: %d", client_id, #clients))

        -- 欢迎消息
        sock:write(string.format("Welcome! You are User%d", client_id), "text")

        -- 通知其他用户
        broadcast(client_id, string.format("User%d joined the chat", client_id))

        -- 消息循环
        while true do
            local data, typ = sock:read()

            if not data or typ == "close" then
                break
            end

            if typ == "text" then
                print(string.format("[MSG] User%d: %s", client_id, data))

                -- 广播消息
                local count = broadcast(client_id, data)
                print(string.format("  -> Broadcasted to %d clients", count))
            elseif typ == "ping" then
                -- 回复心跳
                sock:write(data, "pong")
            end
        end

        -- 客户端断开
        clients[client_id] = nil
        sock:close()

        -- 通知其他用户
        broadcast(0, string.format("User%d left the chat", client_id))
        print(string.format("[LEAVE] User%d disconnected. Remaining: %d",
                           client_id, #clients))
    end
}

print("WebSocket Chat Room listening on ws://127.0.0.1:8080")
print("Open multiple browser tabs to test!")
```

**广播机制**：

- `broadcast()` 函数遍历所有客户端发送消息
- 使用发送者 ID 避免回显给自己
- 处理发送失败情况（客户端可能已断开）
- 用户加入/离开时通知所有人

### Step 4: 用户管理和在线列表

添加用户名设置和在线用户列表功能：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"
local json = require "silly.encoding.json"

local clients = {}
local next_id = 1

-- 广播消息
local function broadcast(sender_id, msg_type, content)
    local message = json.encode({
        type = msg_type,
        from_id = sender_id,
        from_name = clients[sender_id] and clients[sender_id].name or "System",
        content = content,
        timestamp = os.time(),
    })

    for id, client in pairs(clients) do
        if id ~= sender_id then
            client.sock:write(message, "text")
        end
    end
end

-- 获取在线用户列表
local function get_users_list()
    local users = {}
    for id, client in pairs(clients) do
        table.insert(users, {
            id = id,
            name = client.name,
        })
    end
    return users
end

-- 发送消息给指定客户端
local function send_to_client(client_id, msg_type, content)
    local client = clients[client_id]
    if client then
        local message = json.encode({
            type = msg_type,
            content = content,
            timestamp = os.time(),
        })
        return client.sock:write(message, "text")
    end
    return false
end

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        if stream.header["upgrade"] ~= "websocket" then
            stream:respond(404, {})
            stream:close("Not Found")
            return
        end

        local sock, err = websocket.upgrade(stream)
        if not sock then
            return
        end

        local client_id = next_id
        next_id = next_id + 1

        clients[client_id] = {
            id = client_id,
            sock = sock,
            name = "User" .. client_id,
        }

        print(string.format("[%s] User%d connected", os.date("%H:%M:%S"), client_id))

        -- 发送欢迎消息
        send_to_client(client_id, "welcome", {
            user_id = client_id,
            message = "Welcome to the chat room!",
        })

        -- 发送在线用户列表
        send_to_client(client_id, "users", get_users_list())

        -- 通知其他用户
        broadcast(client_id, "join", {
            user_id = client_id,
            user_name = clients[client_id].name,
        })

        -- 消息循环
        while true do
            local data, typ = sock:read()

            if not data or typ == "close" then
                break
            end

            if typ == "text" then
                local msg = json.decode(data)

                if msg and msg.type == "set_name" then
                    -- 设置用户名
                    local old_name = clients[client_id].name
                    clients[client_id].name = msg.name or old_name
                    print(string.format("[RENAME] User%d: %s -> %s",
                                       client_id, old_name, clients[client_id].name))

                    send_to_client(client_id, "name_changed", {
                        old_name = old_name,
                        new_name = clients[client_id].name,
                    })

                    broadcast(client_id, "user_update", get_users_list())

                elseif msg and msg.type == "message" then
                    -- 普通消息
                    print(string.format("[MSG] %s: %s",
                                       clients[client_id].name, msg.content))
                    broadcast(client_id, "message", msg.content)

                elseif msg and msg.type == "get_users" then
                    -- 请求用户列表
                    send_to_client(client_id, "users", get_users_list())
                end
            elseif typ == "ping" then
                sock:write(data, "pong")
            end
        end

        -- 客户端断开
        local user_name = clients[client_id].name
        clients[client_id] = nil
        sock:close()

        broadcast(0, "leave", {
            user_id = client_id,
            user_name = user_name,
        })

        print(string.format("[%s] %s (User%d) disconnected. Remaining: %d",
                           os.date("%H:%M:%S"), user_name, client_id, #clients))
    end
}

print("========================================")
print("  WebSocket Chat Room Started")
print("========================================")
print("  Server: ws://127.0.0.1:8080")
print("  Features:")
print("    - User management")
print("    - Online user list")
print("    - Message broadcast")
print("========================================")
```

**JSON 消息协议**：

客户端发送消息格式：
```json
{
  "type": "message|set_name|get_users",
  "content": "消息内容",
  "name": "新用户名"
}
```

服务器推送消息格式：
```json
{
  "type": "welcome|message|join|leave|users",
  "from_id": 用户ID,
  "from_name": "用户名",
  "content": "内容或数据对象",
  "timestamp": 时间戳
}
```

### Step 5: 私聊功能

添加点对点私聊功能：

```lua
-- 在上面代码基础上添加私聊处理

-- 发送私聊消息
local function send_private_message(from_id, to_id, content)
    local from_client = clients[from_id]
    local to_client = clients[to_id]

    if not from_client or not to_client then
        return false, "User not found"
    end

    local message = json.encode({
        type = "private_message",
        from_id = from_id,
        from_name = from_client.name,
        content = content,
        timestamp = os.time(),
    })

    local ok = to_client.sock:write(message, "text")
    if ok then
        -- 也发送给发送者（确认消息）
        local confirm = json.encode({
            type = "private_message_sent",
            to_id = to_id,
            to_name = to_client.name,
            content = content,
            timestamp = os.time(),
        })
        from_client.sock:write(confirm, "text")
    end

    return ok
end

-- 在消息循环中添加私聊处理
elseif msg and msg.type == "private_message" then
    -- 私聊消息
    local to_id = tonumber(msg.to_id)
    if to_id and clients[to_id] then
        local ok = send_private_message(client_id, to_id, msg.content)
        print(string.format("[PRIVATE] %s -> %s: %s",
                           clients[client_id].name,
                           clients[to_id].name,
                           msg.content))
    else
        send_to_client(client_id, "error", {
            message = "User not found or offline"
        })
    end
end
```

## 完整代码

### 服务器端完整代码

保存为 `chat_server.lua`：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"
local json = require "silly.encoding.json"
local time = require "silly.time"

-- 全局状态
local clients = {}
local next_id = 1
local server_start_time = os.time()

-- 工具函数：安全的 JSON 编码
local function safe_json_encode(data)
    local ok, result = pcall(json.encode, data)
    if ok then
        return result
    else
        print("[ERROR] JSON encode failed:", result)
        return nil
    end
end

-- 广播消息给所有客户端（除了发送者）
local function broadcast(sender_id, msg_type, content)
    local sender_name = clients[sender_id] and clients[sender_id].name or "System"
    local message = safe_json_encode({
        type = msg_type,
        from_id = sender_id,
        from_name = sender_name,
        content = content,
        timestamp = os.time(),
    })

    if not message then
        return 0
    end

    local success_count = 0
    local failed_clients = {}

    for id, client in pairs(clients) do
        if id ~= sender_id then
            local ok = client.sock:write(message, "text")
            if ok then
                success_count = success_count + 1
            else
                table.insert(failed_clients, id)
            end
        end
    end

    -- 清理发送失败的客户端
    for _, id in ipairs(failed_clients) do
        print(string.format("[WARN] Failed to send to User%d, marking for cleanup", id))
        clients[id] = nil
    end

    return success_count
end

-- 获取在线用户列表
local function get_users_list()
    local users = {}
    for id, client in pairs(clients) do
        table.insert(users, {
            id = id,
            name = client.name,
            connected_at = client.connected_at,
        })
    end
    return users
end

-- 发送消息给指定客户端
local function send_to_client(client_id, msg_type, content)
    local client = clients[client_id]
    if not client then
        return false
    end

    local message = safe_json_encode({
        type = msg_type,
        content = content,
        timestamp = os.time(),
    })

    if not message then
        return false
    end

    return client.sock:write(message, "text")
end

-- 发送私聊消息
local function send_private_message(from_id, to_id, content)
    local from_client = clients[from_id]
    local to_client = clients[to_id]

    if not from_client or not to_client then
        return false, "User not found"
    end

    -- 发送给接收者
    local message = safe_json_encode({
        type = "private_message",
        from_id = from_id,
        from_name = from_client.name,
        content = content,
        timestamp = os.time(),
    })

    if not message then
        return false, "Message encode failed"
    end

    local ok = to_client.sock:write(message, "text")

    if ok then
        -- 发送确认给发送者
        local confirm = safe_json_encode({
            type = "private_message_sent",
            to_id = to_id,
            to_name = to_client.name,
            content = content,
            timestamp = os.time(),
        })

        if confirm then
            from_client.sock:write(confirm, "text")
        end
    end

    return ok
end

-- 获取服务器统计信息
local function get_server_stats()
    return {
        users_online = #clients,
        uptime_seconds = os.time() - server_start_time,
        server_time = os.date("%Y-%m-%d %H:%M:%S"),
    }
end

-- WebSocket 服务器
http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        if stream.header["upgrade"] ~= "websocket" then
            stream:respond(404, {})
            stream:close("Not Found")
            return
        end

        local sock, err = websocket.upgrade(stream)
        if not sock then
            return
        end

        local client_id = next_id
        next_id = next_id + 1

        -- 创建客户端对象
        clients[client_id] = {
            id = client_id,
            sock = sock,
            name = "User" .. client_id,
            connected_at = os.time(),
        }

        print(string.format("[%s] User%d connected from %s",
                           os.date("%H:%M:%S"), client_id, sock.stream.remoteaddr or "unknown"))

        -- 发送欢迎消息
        send_to_client(client_id, "welcome", {
            user_id = client_id,
            user_name = clients[client_id].name,
            message = "Welcome to the chat room!",
            server_stats = get_server_stats(),
        })

        -- 发送在线用户列表
        send_to_client(client_id, "users", get_users_list())

        -- 通知其他用户有人加入
        broadcast(client_id, "join", {
            user_id = client_id,
            user_name = clients[client_id].name,
            users_online = #clients,
        })

        -- 消息处理循环
        while true do
            local data, typ = sock:read()

            -- 连接断开或关闭
            if not data or typ == "close" then
                break
            end

            -- 处理文本消息
            if typ == "text" then
                local msg = json.decode(data)

                if not msg or not msg.type then
                    send_to_client(client_id, "error", {
                        message = "Invalid message format"
                    })
                    goto continue
                end

                -- 设置用户名
                if msg.type == "set_name" then
                    local new_name = msg.name

                    if not new_name or new_name == "" or #new_name > 20 then
                        send_to_client(client_id, "error", {
                            message = "Invalid name (1-20 characters required)"
                        })
                        goto continue
                    end

                    local old_name = clients[client_id].name
                    clients[client_id].name = new_name

                    print(string.format("[RENAME] User%d: %s -> %s",
                                       client_id, old_name, new_name))

                    send_to_client(client_id, "name_changed", {
                        old_name = old_name,
                        new_name = new_name,
                    })

                    broadcast(client_id, "user_renamed", {
                        user_id = client_id,
                        old_name = old_name,
                        new_name = new_name,
                    })

                -- 群聊消息
                elseif msg.type == "message" then
                    if not msg.content or msg.content == "" then
                        goto continue
                    end

                    print(string.format("[MSG] %s (User%d): %s",
                                       clients[client_id].name, client_id, msg.content))

                    local count = broadcast(client_id, "message", msg.content)
                    print(string.format("  -> Broadcasted to %d clients", count))

                -- 私聊消息
                elseif msg.type == "private_message" then
                    local to_id = tonumber(msg.to_id)

                    if not to_id or not clients[to_id] then
                        send_to_client(client_id, "error", {
                            message = "User not found or offline"
                        })
                        goto continue
                    end

                    if not msg.content or msg.content == "" then
                        goto continue
                    end

                    local ok = send_private_message(client_id, to_id, msg.content)

                    if ok then
                        print(string.format("[PRIVATE] %s -> %s: %s",
                                           clients[client_id].name,
                                           clients[to_id].name,
                                           msg.content))
                    end

                -- 请求用户列表
                elseif msg.type == "get_users" then
                    send_to_client(client_id, "users", get_users_list())

                -- 请求服务器状态
                elseif msg.type == "get_stats" then
                    send_to_client(client_id, "stats", get_server_stats())

                else
                    send_to_client(client_id, "error", {
                        message = "Unknown message type: " .. msg.type
                    })
                end

                ::continue::

            -- 处理 ping/pong 心跳
            elseif typ == "ping" then
                sock:write(data, "pong")
            end
        end

        -- 客户端断开处理
        local user_name = clients[client_id].name
        clients[client_id] = nil
        sock:close()

        -- 通知其他用户
        broadcast(0, "leave", {
            user_id = client_id,
            user_name = user_name,
            users_online = #clients,
        })

        print(string.format("[%s] %s (User%d) disconnected. Remaining: %d",
                           os.date("%H:%M:%S"), user_name, client_id, #clients))
    end
}

-- 启动服务器
print("========================================")
print("  WebSocket Chat Room Server")
print("========================================")
print("  Server: ws://127.0.0.1:8080")
print("  Started at:", os.date("%Y-%m-%d %H:%M:%S"))
print("")
print("  Features:")
print("    - User management (set nickname)")
print("    - Online user list")
print("    - Public chat (broadcast)")
print("    - Private chat (1-to-1)")
print("    - Automatic cleanup")
print("")
print("  Press Ctrl+C to stop")
print("========================================")
```

### HTML 客户端完整代码

保存为 `chat_client.html`：

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WebSocket 聊天室</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }

        .container {
            display: flex;
            width: 100%;
            max-width: 1200px;
            height: 90vh;
            background: white;
            border-radius: 15px;
            box-shadow: 0 10px 40px rgba(0, 0, 0, 0.3);
            overflow: hidden;
        }

        /* 侧边栏 */
        .sidebar {
            width: 280px;
            background: #f8f9fa;
            border-right: 1px solid #dee2e6;
            display: flex;
            flex-direction: column;
        }

        .sidebar-header {
            padding: 20px;
            background: #667eea;
            color: white;
        }

        .sidebar-header h2 {
            font-size: 20px;
            margin-bottom: 10px;
        }

        .user-info {
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .user-info input {
            flex: 1;
            padding: 8px;
            border: none;
            border-radius: 5px;
            font-size: 14px;
        }

        .user-info button {
            padding: 8px 15px;
            background: white;
            color: #667eea;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            font-weight: bold;
        }

        .user-info button:hover {
            background: #f0f0f0;
        }

        .online-users {
            flex: 1;
            overflow-y: auto;
            padding: 15px;
        }

        .online-users h3 {
            font-size: 14px;
            color: #6c757d;
            margin-bottom: 10px;
            text-transform: uppercase;
        }

        .user-item {
            padding: 10px;
            margin-bottom: 5px;
            background: white;
            border-radius: 8px;
            cursor: pointer;
            transition: all 0.2s;
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .user-item:hover {
            background: #e9ecef;
            transform: translateX(5px);
        }

        .user-item.active {
            background: #667eea;
            color: white;
        }

        .user-avatar {
            width: 32px;
            height: 32px;
            border-radius: 50%;
            background: #667eea;
            color: white;
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: bold;
            font-size: 14px;
        }

        .user-item.active .user-avatar {
            background: white;
            color: #667eea;
        }

        /* 主聊天区域 */
        .chat-area {
            flex: 1;
            display: flex;
            flex-direction: column;
            background: white;
        }

        .chat-header {
            padding: 20px;
            border-bottom: 1px solid #dee2e6;
            background: #f8f9fa;
        }

        .chat-header h2 {
            font-size: 18px;
            color: #333;
        }

        .connection-status {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: bold;
            margin-left: 10px;
        }

        .status-connected {
            background: #28a745;
            color: white;
        }

        .status-disconnected {
            background: #dc3545;
            color: white;
        }

        .status-connecting {
            background: #ffc107;
            color: #333;
        }

        .messages {
            flex: 1;
            overflow-y: auto;
            padding: 20px;
            background: #fafafa;
        }

        .message {
            margin-bottom: 15px;
            animation: slideIn 0.3s ease;
        }

        @keyframes slideIn {
            from {
                opacity: 0;
                transform: translateY(10px);
            }
            to {
                opacity: 1;
                transform: translateY(0);
            }
        }

        .message-header {
            display: flex;
            align-items: center;
            gap: 10px;
            margin-bottom: 5px;
        }

        .message-sender {
            font-weight: bold;
            color: #667eea;
        }

        .message-time {
            font-size: 11px;
            color: #6c757d;
        }

        .message-content {
            padding: 10px 15px;
            background: white;
            border-radius: 10px;
            box-shadow: 0 1px 2px rgba(0, 0, 0, 0.1);
            max-width: 70%;
            word-wrap: break-word;
        }

        .message.own .message-content {
            background: #667eea;
            color: white;
            margin-left: auto;
        }

        .message.own .message-sender {
            color: #667eea;
        }

        .message.system {
            text-align: center;
        }

        .message.system .message-content {
            background: #e9ecef;
            color: #6c757d;
            display: inline-block;
            font-size: 13px;
            padding: 8px 15px;
            max-width: 100%;
        }

        .message.private {
            background: #fff3cd;
            padding: 10px;
            border-radius: 10px;
        }

        .message.private .message-content {
            background: #fffaeb;
            border-left: 3px solid #ffc107;
        }

        /* 输入区域 */
        .input-area {
            padding: 20px;
            border-top: 1px solid #dee2e6;
            background: white;
        }

        .input-wrapper {
            display: flex;
            gap: 10px;
            align-items: center;
        }

        .input-wrapper input {
            flex: 1;
            padding: 12px 15px;
            border: 2px solid #dee2e6;
            border-radius: 25px;
            font-size: 14px;
            outline: none;
            transition: border-color 0.2s;
        }

        .input-wrapper input:focus {
            border-color: #667eea;
        }

        .input-wrapper button {
            padding: 12px 30px;
            background: #667eea;
            color: white;
            border: none;
            border-radius: 25px;
            cursor: pointer;
            font-weight: bold;
            transition: all 0.2s;
        }

        .input-wrapper button:hover {
            background: #5568d3;
            transform: scale(1.05);
        }

        .input-wrapper button:active {
            transform: scale(0.95);
        }

        .private-mode {
            padding: 8px 15px;
            background: #ffc107;
            color: #333;
            border-radius: 20px;
            font-size: 12px;
            font-weight: bold;
            cursor: pointer;
        }

        .private-mode:hover {
            background: #e0a800;
        }

        /* 滚动条美化 */
        ::-webkit-scrollbar {
            width: 8px;
        }

        ::-webkit-scrollbar-track {
            background: #f1f1f1;
        }

        ::-webkit-scrollbar-thumb {
            background: #888;
            border-radius: 4px;
        }

        ::-webkit-scrollbar-thumb:hover {
            background: #555;
        }
    </style>
</head>
<body>
    <div class="container">
        <!-- 侧边栏 -->
        <div class="sidebar">
            <div class="sidebar-header">
                <h2>WebSocket 聊天室</h2>
                <div class="user-info">
                    <input type="text" id="nameInput" placeholder="输入昵称" maxlength="20">
                    <button onclick="setName()">设置</button>
                </div>
            </div>
            <div class="online-users">
                <h3>在线用户 (<span id="userCount">0</span>)</h3>
                <div id="userList"></div>
            </div>
        </div>

        <!-- 聊天区域 -->
        <div class="chat-area">
            <div class="chat-header">
                <h2>
                    公共聊天
                    <span id="connectionStatus" class="connection-status status-connecting">连接中...</span>
                </h2>
            </div>
            <div class="messages" id="messages"></div>
            <div class="input-area">
                <div class="input-wrapper">
                    <span id="privateMode" class="private-mode" style="display: none;"
                          onclick="cancelPrivateMode()">
                        私聊: <span id="privateTo"></span> ✕
                    </span>
                    <input type="text" id="messageInput" placeholder="输入消息..."
                           onkeypress="if(event.key==='Enter') sendMessage()">
                    <button onclick="sendMessage()">发送</button>
                </div>
            </div>
        </div>
    </div>

    <script>
        // WebSocket 连接
        let ws = null;
        let myUserId = null;
        let myUserName = 'User';
        let privateTargetId = null;
        let privateTargetName = null;

        // DOM 元素
        const messagesDiv = document.getElementById('messages');
        const messageInput = document.getElementById('messageInput');
        const userList = document.getElementById('userList');
        const userCount = document.getElementById('userCount');
        const connectionStatus = document.getElementById('connectionStatus');
        const nameInput = document.getElementById('nameInput');
        const privateMode = document.getElementById('privateMode');
        const privateTo = document.getElementById('privateTo');

        // 连接 WebSocket 服务器
        function connect() {
            updateConnectionStatus('connecting');

            ws = new WebSocket('ws://127.0.0.1:8080');

            ws.onopen = () => {
                console.log('WebSocket connected');
                updateConnectionStatus('connected');
            };

            ws.onmessage = (event) => {
                const msg = JSON.parse(event.data);
                console.log('Received:', msg);
                handleMessage(msg);
            };

            ws.onerror = (error) => {
                console.error('WebSocket error:', error);
            };

            ws.onclose = () => {
                console.log('WebSocket disconnected');
                updateConnectionStatus('disconnected');

                // 5 秒后自动重连
                setTimeout(() => {
                    addSystemMessage('尝试重新连接...');
                    connect();
                }, 5000);
            };
        }

        // 处理接收到的消息
        function handleMessage(msg) {
            switch (msg.type) {
                case 'welcome':
                    myUserId = msg.content.user_id;
                    myUserName = msg.content.user_name;
                    nameInput.value = myUserName;
                    addSystemMessage(msg.content.message);
                    break;

                case 'users':
                    updateUserList(msg.content);
                    break;

                case 'message':
                    addMessage(msg.from_name, msg.content, false, msg.from_id === myUserId);
                    break;

                case 'private_message':
                    addMessage(msg.from_name, msg.content, true, false);
                    break;

                case 'private_message_sent':
                    addMessage('你 → ' + msg.to_name, msg.content, true, true);
                    break;

                case 'join':
                    addSystemMessage(`${msg.content.user_name} 加入了聊天室`);
                    break;

                case 'leave':
                    addSystemMessage(`${msg.content.user_name} 离开了聊天室`);
                    break;

                case 'user_renamed':
                    addSystemMessage(`${msg.content.old_name} 改名为 ${msg.content.new_name}`);
                    break;

                case 'name_changed':
                    myUserName = msg.content.new_name;
                    addSystemMessage(`你的昵称已更改为: ${msg.content.new_name}`);
                    break;

                case 'error':
                    addSystemMessage('错误: ' + msg.content.message);
                    break;

                default:
                    console.log('Unknown message type:', msg.type);
            }
        }

        // 发送消息
        function sendMessage() {
            const text = messageInput.value.trim();
            if (!text || !ws || ws.readyState !== WebSocket.OPEN) {
                return;
            }

            let message;
            if (privateTargetId) {
                // 私聊消息
                message = {
                    type: 'private_message',
                    to_id: privateTargetId,
                    content: text
                };
            } else {
                // 公共消息
                message = {
                    type: 'message',
                    content: text
                };
            }

            ws.send(JSON.stringify(message));
            messageInput.value = '';
        }

        // 设置用户名
        function setName() {
            const newName = nameInput.value.trim();
            if (!newName || !ws || ws.readyState !== WebSocket.OPEN) {
                return;
            }

            ws.send(JSON.stringify({
                type: 'set_name',
                name: newName
            }));
        }

        // 添加消息到聊天区域
        function addMessage(sender, content, isPrivate, isOwn) {
            const msgDiv = document.createElement('div');
            msgDiv.className = 'message' + (isOwn ? ' own' : '') + (isPrivate ? ' private' : '');

            const time = new Date().toLocaleTimeString('zh-CN', {
                hour: '2-digit',
                minute: '2-digit'
            });

            msgDiv.innerHTML = `
                <div class="message-header">
                    <span class="message-sender">${sender}</span>
                    <span class="message-time">${time}</span>
                    ${isPrivate ? '<span class="message-time">[私聊]</span>' : ''}
                </div>
                <div class="message-content">${escapeHtml(content)}</div>
            `;

            messagesDiv.appendChild(msgDiv);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        }

        // 添加系统消息
        function addSystemMessage(text) {
            const msgDiv = document.createElement('div');
            msgDiv.className = 'message system';
            msgDiv.innerHTML = `<div class="message-content">${escapeHtml(text)}</div>`;
            messagesDiv.appendChild(msgDiv);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        }

        // 更新在线用户列表
        function updateUserList(users) {
            userList.innerHTML = '';
            userCount.textContent = users.length;

            users.forEach(user => {
                const userDiv = document.createElement('div');
                userDiv.className = 'user-item' + (user.id === myUserId ? ' active' : '');
                userDiv.innerHTML = `
                    <div class="user-avatar">${user.name.substring(0, 1).toUpperCase()}</div>
                    <span>${user.name}</span>
                `;

                if (user.id !== myUserId) {
                    userDiv.onclick = () => startPrivateChat(user.id, user.name);
                }

                userList.appendChild(userDiv);
            });
        }

        // 开始私聊
        function startPrivateChat(userId, userName) {
            privateTargetId = userId;
            privateTargetName = userName;
            privateTo.textContent = userName;
            privateMode.style.display = 'inline-block';
            messageInput.placeholder = `正在私聊 ${userName}...`;
            messageInput.focus();
        }

        // 取消私聊模式
        function cancelPrivateMode() {
            privateTargetId = null;
            privateTargetName = null;
            privateMode.style.display = 'none';
            messageInput.placeholder = '输入消息...';
        }

        // 更新连接状态
        function updateConnectionStatus(status) {
            const statusTexts = {
                connecting: '连接中...',
                connected: '已连接',
                disconnected: '已断开'
            };

            connectionStatus.textContent = statusTexts[status];
            connectionStatus.className = 'connection-status status-' + status;
        }

        // HTML 转义
        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }

        // 页面加载时连接
        window.onload = () => {
            connect();
            messageInput.focus();
        };
    </script>
</body>
</html>
```

## 运行和测试

### 启动服务器

```bash
# 进入 Silly 目录
cd /home/zhoupy/silly

# 运行聊天服务器
./silly chat_server.lua
```

你应该看到如下输出：

```
========================================
  WebSocket Chat Room Server
========================================
  Server: ws://127.0.0.1:8080
  Started at: 2025-10-14 10:30:00

  Features:
    - User management (set nickname)
    - Online user list
    - Public chat (broadcast)
    - Private chat (1-to-1)
    - Automatic cleanup

  Press Ctrl+C to stop
========================================
```

### 使用浏览器测试

1. **打开 HTML 客户端**：在浏览器中打开 `chat_client.html`
2. **设置昵称**：在左侧输入框输入你的昵称，点击"设置"
3. **发送消息**：在底部输入框输入消息，按回车或点击"发送"
4. **查看在线用户**：左侧显示所有在线用户

### 多客户端测试

打开多个浏览器标签页或窗口，体验多人聊天：

1. 打开 3-4 个标签页，每个设置不同的昵称
2. 在一个标签发送消息，观察其他标签是否收到
3. 点击侧边栏用户名，尝试私聊功能
4. 关闭某个标签，观察其他标签是否显示离开消息

### 使用命令行测试

也可以使用 `websocat` 或 `wscat` 工具测试：

```bash
# 安装 websocat (Ubuntu)
sudo wget -qO /usr/local/bin/websocat https://github.com/vi/websocat/releases/download/v1.11.0/websocat.x86_64-unknown-linux-musl
sudo chmod +x /usr/local/bin/websocat

# 连接服务器
websocat ws://127.0.0.1:8080

# 发送消息（JSON 格式）
{"type":"message","content":"Hello from terminal!"}
{"type":"set_name","name":"Terminal User"}
```

## 代码解析

### 连接管理

服务器使用 `clients` 表维护所有连接：

```lua
clients[client_id] = {
    id = client_id,           -- 唯一 ID
    sock = sock,              -- WebSocket socket 对象
    name = "User" .. client_id,  -- 用户名
    connected_at = os.time(), -- 连接时间
}
```

每个客户端连接在独立的协程中处理，互不阻塞。

### 消息路由

通过 JSON 消息的 `type` 字段实现消息路由：

- `message`：群聊消息（广播）
- `private_message`：私聊消息（点对点）
- `set_name`：设置昵称
- `get_users`：获取在线用户列表
- `get_stats`：获取服务器统计

### 广播机制

`broadcast()` 函数遍历所有客户端发送消息：

```lua
for id, client in pairs(clients) do
    if id ~= sender_id then  -- 跳过发送者
        client.sock:write(message, "text")
    end
end
```

使用 `sock:write()` 异步发送，不会阻塞其他客户端。如果发送失败，自动清理断开的客户端。

### 错误处理

- **发送失败**：标记并清理断开的客户端
- **无效消息**：返回错误消息给客户端
- **连接断开**：通知其他用户，清理资源
- **JSON 解析错误**：使用 `pcall` 捕获异常

### 心跳保活

服务器自动回复 ping 帧：

```lua
elseif typ == "ping" then
    sock:write(data, "pong")
end
```

浏览器会自动发送 ping，无需客户端代码处理。

## 扩展练习

尝试以下练习来增强聊天室功能：

### 练习 1: 聊天历史

保存最近 100 条消息，新用户连接时发送历史：

```lua
local message_history = {}
local MAX_HISTORY = 100

-- 保存消息到历史
local function save_to_history(sender_name, content)
    table.insert(message_history, {
        sender = sender_name,
        content = content,
        timestamp = os.time(),
    })

    -- 限制历史长度
    if #message_history > MAX_HISTORY then
        table.remove(message_history, 1)
    end
end

-- 发送历史给新用户
send_to_client(client_id, "history", message_history)
```

### 练习 2: 房间功能

实现多个聊天房间：

```lua
local rooms = {
    general = {},  -- 大厅
    random = {},   -- 随机
    gaming = {},   -- 游戏
}

-- 客户端加入房间
clients[client_id].room = "general"

-- 广播时只发送给同一房间的用户
for id, client in pairs(clients) do
    if client.room == sender_room and id ~= sender_id then
        client.sock:write(message, "text")
    end
end
```

### 练习 3: 表情和图片

支持 Emoji 和图片链接：

```lua
-- 客户端发送
{"type":"message","content":"Hello 😊"}
{"type":"image","url":"https://example.com/image.png"}

-- 服务器广播
if msg.type == "image" then
    broadcast(client_id, "image", {url = msg.url})
end
```

HTML 客户端渲染图片：

```javascript
if (msg.type === 'image') {
    msgDiv.innerHTML = `<img src="${msg.content.url}" style="max-width: 300px;">`;
}
```

### 练习 4: 用户认证

添加简单的密码认证：

```lua
-- 客户端连接时发送认证
{"type":"auth","username":"alice","password":"secret"}

-- 服务器验证
local function authenticate(username, password)
    -- 检查用户名和密码
    return password == "secret"
end

if msg.type == "auth" then
    if authenticate(msg.username, msg.password) then
        send_to_client(client_id, "auth_success", {})
    else
        sock:close()
    end
end
```

### 练习 5: 输入状态提示

显示"某某正在输入..."提示：

```lua
-- 客户端发送输入状态
{"type":"typing","is_typing":true}

-- 服务器广播
broadcast(client_id, "typing", {
    user_id = client_id,
    user_name = clients[client_id].name,
    is_typing = msg.is_typing
})
```

HTML 客户端显示提示：

```javascript
// 输入框 oninput 事件
messageInput.oninput = () => {
    ws.send(JSON.stringify({type: 'typing', is_typing: true}));
    clearTimeout(typingTimeout);
    typingTimeout = setTimeout(() => {
        ws.send(JSON.stringify({type: 'typing', is_typing: false}));
    }, 1000);
};
```

### 练习 6: 消息已读回执

实现消息已读功能：

```lua
-- 客户端确认已读
{"type":"read","message_id":123}

-- 服务器通知发送者
send_to_client(original_sender_id, "message_read", {
    message_id = 123,
    read_by = client_id,
    read_at = os.time()
})
```

### 练习 7: 管理员功能

添加管理员权限（踢人、禁言）：

```lua
-- 检查是否是管理员
local function is_admin(client_id)
    return clients[client_id] and clients[client_id].is_admin
end

-- 踢出用户
if msg.type == "kick" and is_admin(client_id) then
    local target_id = tonumber(msg.target_id)
    if clients[target_id] then
        send_to_client(target_id, "kicked", {
            reason = msg.reason or "Kicked by admin"
        })
        clients[target_id].sock:close()
    end
end
```

## 性能优化

### 1. 消息批量发送

当同时广播多条消息时，批量发送减少系统调用：

```lua
-- 收集要广播的消息
local pending_messages = {}

-- 批量发送
local function flush_messages()
    for client_id, messages in pairs(pending_messages) do
        local combined = table.concat(messages, "\n")
        clients[client_id].sock:write(combined, "text")
    end
    pending_messages = {}
end
```

### 2. 连接数限制

防止资源耗尽：

```lua
local MAX_CLIENTS = 1000

if #clients >= MAX_CLIENTS then
    sock:write("Server is full", "text")
    sock:close()
    return
end
```

### 3. 消息大小限制

防止恶意大消息：

```lua
if #data > 10240 then  -- 10KB limit
    send_to_client(client_id, "error", {
        message = "Message too large"
    })
    goto continue
end
```

### 4. 广播优化

使用 channel 实现异步广播：

```lua
local channel = require "silly.sync.channel"
local task = require "silly.task"
local broadcast_chan = channel.new()

-- 广播协程
task.fork(function()
    while true do
        local msg = broadcast_chan:recv()
        broadcast(msg.sender_id, msg.type, msg.content)
    end
end)

-- 消息处理时投递到 channel
broadcast_chan:send({
    sender_id = client_id,
    type = "message",
    content = msg.content
})
```

## 总结

恭喜完成 WebSocket 聊天室教程！你已经学会了：

- WebSocket 协议的工作原理和使用场景
- 使用 `silly.net.websocket` 构建实时通信服务器
- 实现用户管理、消息广播和私聊功能
- 处理连接生命周期和异常情况
- 使用 HTML5 WebSocket API 构建浏览器客户端
- JSON 消息协议设计和路由

### 学到的技能

1. **WebSocket 编程**：双向实时通信模型
2. **协程并发**：每个连接独立协程处理
3. **状态管理**：维护全局客户端列表
4. **消息路由**：基于消息类型分发处理
5. **广播模式**：一对多消息传递
6. **错误处理**：异常检测和资源清理

## 下一步

继续学习更多 Silly 框架功能：

- **HTTP + WebSocket 混合**：同一端口提供 HTTP 和 WebSocket（参考 [silly.net.http](../reference/net/http.md)）
- **数据库持久化**：保存聊天历史到 MySQL/Redis（参考 [silly.store](../reference/store/README.md)）
- **TLS/WSS**：加密的 WebSocket 连接（参考 [silly.net.tls](../reference/net/tls.md)）
- **集群部署**：多服务器聊天室（参考 [silly.net.cluster](../reference/net/cluster.md)）
- **性能测试**：压力测试和性能优化（参考 [silly.metrics](../reference/metrics/prometheus.md)）

## 参考资料

- [silly.net.websocket API 参考](../reference/net/websocket.md)
- [silly.encoding.json API 参考](../reference/encoding/json.md)
- [silly.sync.channel API 参考](../reference/sync/channel.md)
- [WebSocket 协议规范 (RFC 6455)](https://datatracker.ietf.org/doc/html/rfc6455)
- [MDN WebSocket API 文档](https://developer.mozilla.org/zh-CN/docs/Web/API/WebSocket)
