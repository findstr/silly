---
title: WebSocket Chat Room
icon: comments
order: 5
category:
  - Tutorial
tag:
  - WebSocket
  - Real-time Communication
  - Chat Room
  - Broadcasting
---

# WebSocket Chat Room

This tutorial will guide you through building a fully functional WebSocket chat room from scratch, learning about the WebSocket protocol, real-time bidirectional communication, and broadcasting mechanisms.

## Learning Objectives

Through this tutorial, you will learn:

- Core concepts and use cases of the WebSocket protocol
- Creating real-time communication servers with the `silly.net.websocket` module
- Implementing user connection management and online lists
- Message broadcasting and point-to-point private chat
- Handling client connections, disconnections, and exceptions
- Building browser clients with the HTML5 WebSocket API

## WebSocket Basics

### What is WebSocket

WebSocket is a protocol for full-duplex communication over a single TCP connection (RFC 6455). It provides:

- **Bidirectional Real-time Communication**: Servers and clients can send messages proactively at any time without waiting
- **Low Latency**: After connection establishment, data transmission has no HTTP request/response overhead
- **Persistent Connection**: The connection remains open after establishment, suitable for long-term communication
- **Lightweight**: Frame headers are only 2-14 bytes, much smaller than HTTP request headers

### Differences from HTTP

| Feature | HTTP | WebSocket |
|---------|------|-----------|
| Communication Mode | Request-Response (unidirectional) | Full-duplex (bidirectional) |
| Connection | Short-lived (or Keep-Alive) | Long-lived |
| Real-time | Requires polling | Server push |
| Overhead | Full headers per request | Small frame headers after handshake |
| Use Cases | Traditional web, APIs | Chat, real-time push, games |

### WebSocket Connection Flow

1. **HTTP Handshake**: Client sends HTTP Upgrade request
2. **Protocol Upgrade**: Server returns 101 status code, protocol switches to WebSocket
3. **Data Transfer**: Both parties exchange data through WebSocket frames
4. **Connection Close**: Either party sends close frame to close connection

### Use Cases

- **Instant Messaging**: Chat rooms, online customer service
- **Real-time Push**: Stock quotes, message notifications
- **Collaborative Apps**: Multi-user editing, whiteboards
- **Games**: Real-time battles, state synchronization
- **Live Streaming Interaction**: Bullet comments, gifts

## Implementation Steps

### Step 1: Create Basic WebSocket Server

Let's start with the simplest Echo server that returns messages sent by clients:

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

**Code Explanation**:

1. `http.listen` and `websocket.upgrade`: Create WebSocket server
2. `handler` function: Handle each client connection (runs in independent coroutine)
3. `sock:read()`: Asynchronously read messages, returns data and frame type
4. `sock:write(data, type)`: Send messages (text or binary)
5. `sock:close()`: Close connection

**Test Server**:

Save code as `echo_server.lua` and run:

```bash
./silly echo_server.lua
```

Test with browser console:

```javascript
const ws = new WebSocket('ws://127.0.0.1:8080');
ws.onopen = () => ws.send('Hello, Server!');
ws.onmessage = (event) => console.log('Received:', event.data);
```

### Step 2: Handle Connections and Disconnections

In a real chat room, we need to manage all connected clients:

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

**Key Improvements**:

- Assign unique ID to each client
- Use `clients` table to store all connections
- Send welcome message on connection
- Remove client from list on disconnection

### Step 3: Message Broadcasting

The core feature of chat rooms is broadcasting one user's message to all other users:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"

local clients = {}
local next_id = 1

-- 广播消息给所有客户端(除了发送者)
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

**Broadcasting Mechanism**:

- `broadcast()` function iterates through all clients to send messages
- Uses sender ID to avoid echoing to self
- Handles send failures (client may be disconnected)
- Notifies everyone when users join/leave

### Step 4: User Management and Online List

Add username setting and online user list functionality:

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

**JSON Message Protocol**:

Client message format:
```json
{
  "type": "message|set_name|get_users",
  "content": "Message content",
  "name": "New username"
}
```

Server push message format:
```json
{
  "type": "welcome|message|join|leave|users",
  "from_id": "User ID",
  "from_name": "Username",
  "content": "Content or data object",
  "timestamp": "Timestamp"
}
```

### Step 5: Private Chat Feature

Add point-to-point private chat functionality:

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
        -- 也发送给发送者(确认消息)
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

## Complete Code

### Complete Server Code

Save as `chat_server.lua`:

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

-- 工具函数: 安全的 JSON 编码
local function safe_json_encode(data)
    local ok, result = pcall(json.encode, data)
    if ok then
        return result
    else
        print("[ERROR] JSON encode failed:", result)
        return nil
    end
end

-- 广播消息给所有客户端(除了发送者)
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

### Complete HTML Client Code

Save as `chat_client.html`:

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

## Running and Testing

### Start Server

```bash
# 进入 Silly 目录
cd /home/zhoupy/silly

# 运行聊天服务器
./silly chat_server.lua
```

You should see output like:

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

### Test with Browser

1. **Open HTML Client**: Open `chat_client.html` in your browser
2. **Set Nickname**: Enter your nickname in the left input box and click "Set"
3. **Send Messages**: Type messages in the bottom input box and press Enter or click "Send"
4. **View Online Users**: The left sidebar displays all online users

### Multi-client Testing

Open multiple browser tabs or windows to experience multi-user chat:

1. Open 3-4 tabs, set different nicknames for each
2. Send a message in one tab and observe if other tabs receive it
3. Click on usernames in the sidebar to try the private chat feature
4. Close a tab and observe if other tabs show the leave message

### Testing with Command Line

You can also use `websocat` or `wscat` tools for testing:

```bash
# Install websocat (Ubuntu)
sudo wget -qO /usr/local/bin/websocat https://github.com/vi/websocat/releases/download/v1.11.0/websocat.x86_64-unknown-linux-musl
sudo chmod +x /usr/local/bin/websocat

# Connect to server
websocat ws://127.0.0.1:8080

# Send messages (JSON format)
{"type":"message","content":"Hello from terminal!"}
{"type":"set_name","name":"Terminal User"}
```

## Code Analysis

### Connection Management

The server uses a `clients` table to maintain all connections:

```lua
clients[client_id] = {
    id = client_id,           -- Unique ID
    sock = sock,              -- WebSocket socket object
    name = "User" .. client_id,  -- Username
    connected_at = os.time(), -- Connection time
}
```

Each client connection is handled in an independent coroutine without blocking each other.

### Message Routing

Message routing is implemented through the `type` field in JSON messages:

- `message`: Group chat message (broadcast)
- `private_message`: Private message (point-to-point)
- `set_name`: Set nickname
- `get_users`: Get online user list
- `get_stats`: Get server statistics

### Broadcasting Mechanism

The `broadcast()` function iterates through all clients to send messages:

```lua
for id, client in pairs(clients) do
    if id ~= sender_id then  -- Skip sender
        client.sock:write(message, "text")
    end
end
```

Uses `sock:write()` for asynchronous sending without blocking other clients. Automatically cleans up disconnected clients if send fails.

### Error Handling

- **Send Failure**: Mark and clean up disconnected clients
- **Invalid Messages**: Return error messages to clients
- **Connection Lost**: Notify other users, clean up resources
- **JSON Parse Errors**: Use `pcall` to catch exceptions

### Heartbeat Keep-alive

Server automatically replies to ping frames:

```lua
elseif typ == "ping" then
    sock:write(data, "pong")
end
```

Browsers automatically send pings, no client code handling needed.

## Extension Exercises

Try these exercises to enhance chat room functionality:

### Exercise 1: Chat History

Save the last 100 messages, send history to new users:

```lua
local message_history = {}
local MAX_HISTORY = 100

-- Save message to history
local function save_to_history(sender_name, content)
    table.insert(message_history, {
        sender = sender_name,
        content = content,
        timestamp = os.time(),
    })

    -- Limit history length
    if #message_history > MAX_HISTORY then
        table.remove(message_history, 1)
    end
end

-- Send history to new user
send_to_client(client_id, "history", message_history)
```

### Exercise 2: Room Feature

Implement multiple chat rooms:

```lua
local rooms = {
    general = {},  -- Lobby
    random = {},   -- Random
    gaming = {},   -- Gaming
}

-- Client joins room
clients[client_id].room = "general"

-- Only send to users in same room when broadcasting
for id, client in pairs(clients) do
    if client.room == sender_room and id ~= sender_id then
        client.sock:write(message, "text")
    end
end
```

### Exercise 3: Emojis and Images

Support Emoji and image links:

```lua
-- Client sends
{"type":"message","content":"Hello 😊"}
{"type":"image","url":"https://example.com/image.png"}

-- Server broadcasts
if msg.type == "image" then
    broadcast(client_id, "image", {url = msg.url})
end
```

HTML client renders images:

```javascript
if (msg.type === 'image') {
    msgDiv.innerHTML = `<img src="${msg.content.url}" style="max-width: 300px;">`;
}
```

### Exercise 4: User Authentication

Add simple password authentication:

```lua
-- Client sends auth on connect
{"type":"auth","username":"alice","password":"secret"}

-- Server validates
local function authenticate(username, password)
    -- Check username and password
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

### Exercise 5: Typing Indicator

Show "someone is typing..." indicator:

```lua
-- Client sends typing status
{"type":"typing","is_typing":true}

-- Server broadcasts
broadcast(client_id, "typing", {
    user_id = client_id,
    user_name = clients[client_id].name,
    is_typing = msg.is_typing
})
```

HTML client shows indicator:

```javascript
// Input field oninput event
messageInput.oninput = () => {
    ws.send(JSON.stringify({type: 'typing', is_typing: true}));
    clearTimeout(typingTimeout);
    typingTimeout = setTimeout(() => {
        ws.send(JSON.stringify({type: 'typing', is_typing: false}));
    }, 1000);
};
```

### Exercise 6: Read Receipts

Implement message read functionality:

```lua
-- Client confirms read
{"type":"read","message_id":123}

-- Server notifies sender
send_to_client(original_sender_id, "message_read", {
    message_id = 123,
    read_by = client_id,
    read_at = os.time()
})
```

### Exercise 7: Admin Features

Add admin privileges (kick, mute):

```lua
-- Check if admin
local function is_admin(client_id)
    return clients[client_id] and clients[client_id].is_admin
end

-- Kick user
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

## Performance Optimization

### 1. Batch Message Sending

When broadcasting multiple messages simultaneously, batch sending reduces system calls:

```lua
-- Collect messages to broadcast
local pending_messages = {}

-- Batch send
local function flush_messages()
    for client_id, messages in pairs(pending_messages) do
        local combined = table.concat(messages, "\n")
        clients[client_id].sock:write(combined, "text")
    end
    pending_messages = {}
end
```

### 2. Connection Limit

Prevent resource exhaustion:

```lua
local MAX_CLIENTS = 1000

if #clients >= MAX_CLIENTS then
    sock:write("Server is full", "text")
    sock:close()
    return
end
```

### 3. Message Size Limit

Prevent malicious large messages:

```lua
if #data > 10240 then  -- 10KB limit
    send_to_client(client_id, "error", {
        message = "Message too large"
    })
    goto continue
end
```

### 4. Broadcasting Optimization

Use channel for asynchronous broadcasting:

```lua
local channel = require "silly.sync.channel"
local task = require "silly.task"
local broadcast_chan = channel.new()

-- Broadcasting coroutine
task.fork(function()
    while true do
        local msg = broadcast_chan:recv()
        broadcast(msg.sender_id, msg.type, msg.content)
    end
end)

-- Post to channel during message processing
broadcast_chan:send({
    sender_id = client_id,
    type = "message",
    content = msg.content
})
```

## Summary

Congratulations on completing the WebSocket Chat Room tutorial! You have learned:

- How WebSocket protocol works and its use cases
- Building real-time communication servers with `silly.net.websocket`
- Implementing user management, message broadcasting, and private chat features
- Handling connection lifecycle and exceptions
- Building browser clients with HTML5 WebSocket API
- JSON message protocol design and routing

### Skills Learned

1. **WebSocket Programming**: Bidirectional real-time communication model
2. **Coroutine Concurrency**: Independent coroutine handling for each connection
3. **State Management**: Maintaining global client list
4. **Message Routing**: Distribution based on message type
5. **Broadcasting Pattern**: One-to-many message delivery
6. **Error Handling**: Exception detection and resource cleanup

## Next Steps

Continue learning more Silly framework features:

- **HTTP + WebSocket Hybrid**: Provide HTTP and WebSocket on the same port (see [silly.net.http](../reference/net/http.md))
- **Database Persistence**: Save chat history to MySQL/Redis (see [silly.store](../reference/store/README.md))
- **TLS/WSS**: Encrypted WebSocket connections (see [silly.net.tls](../reference/net/tls.md))
- **Cluster Deployment**: Multi-server chat rooms (see [silly.net.cluster](../reference/net/cluster.md))
- **Performance Testing**: Stress testing and performance optimization (see [silly.metrics](../reference/metrics/prometheus.md))

## References

- [silly.net.websocket API Reference](../reference/net/websocket.md)
- [silly.encoding.json API Reference](../reference/encoding/json.md)
- [silly.sync.channel API Reference](../reference/sync/channel.md)
- [WebSocket Protocol Specification (RFC 6455)](https://datatracker.ietf.org/doc/html/rfc6455)
- [MDN WebSocket API Documentation](https://developer.mozilla.org/zh-CN/docs/Web/API/WebSocket)
