---
title: HTTP 服务器教程
icon: server
category:
  - 教程
tag:
  - HTTP
  - Web服务
  - RESTful API
  - 路由
---

# HTTP 服务器教程

本教程将带你从零开始构建一个功能完整的 HTTP 服务器，学习 HTTP 协议基础、路由处理和 JSON API 开发。

## 学习目标

通过本教程，你将学会：

- HTTP 协议的核心概念（请求/响应、状态码、Headers）
- 使用 `silly.net.http` 模块创建 HTTP 服务器
- 实现路由系统处理不同的 URL 路径
- 构建 RESTful JSON API
- 提供静态文件服务
- 处理 GET/POST 请求和查询参数

## HTTP 基础知识

### HTTP 请求/响应模型

HTTP（超文本传输协议）是一种请求-响应协议：

1. **客户端发送请求**：包含方法（GET、POST 等）、路径、头部、请求体
2. **服务器返回响应**：包含状态码（200、404 等）、头部、响应体

### 常见 HTTP 方法

- `GET`：获取资源（不应修改服务器状态）
- `POST`：创建新资源
- `PUT`：更新现有资源
- `DELETE`：删除资源

### 常见 HTTP 状态码

- `200 OK`：请求成功
- `201 Created`：资源创建成功
- `400 Bad Request`：客户端请求错误
- `404 Not Found`：资源不存在
- `500 Internal Server Error`：服务器内部错误

### HTTP Headers

Headers 是键值对，提供请求或响应的元数据：

- `content-type`：内容类型（text/html、application/json 等）
- `content-length`：内容长度（字节数）
- `user-agent`：客户端信息
- `accept`：客户端接受的内容类型

## 实现步骤

### Step 1: 基本 HTTP 服务器

让我们从最简单的 HTTP 服务器开始，它对所有请求返回 "Hello, World!"：

```lua
local silly = require "silly"
local http = require "silly.net.http"

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        local response_body = "Hello, World!"

        stream:respond(200, {
            ["content-type"] = "text/plain",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)
    end
}

print("HTTP server listening on http://127.0.0.1:8080")
```

**代码解析**：

1. `http.listen` 创建 HTTP 服务器并监听地址
2. `handler` 函数处理每个 HTTP 请求
3. `stream:respond(status, headers)` 发送状态码和响应头
4. `stream:close(body)` 发送响应体并关闭连接

**测试服务器**：

```bash
# 运行服务器
./silly http_server.lua

# 在另一个终端测试
curl http://127.0.0.1:8080
```

### Step 2: 路由处理

真实的 Web 服务需要根据不同的路径返回不同内容：

```lua
local silly = require "silly"
local http = require "silly.net.http"

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        local path = stream.path
        local response_body
        local status = 200

        -- 路由匹配
        if path == "/" then
            response_body = "Welcome to the home page!"
        elseif path == "/about" then
            response_body = "This is the about page."
        elseif path == "/contact" then
            response_body = "Contact us at: support@example.com"
        else
            status = 404
            response_body = "404 Not Found: " .. path
        end

        stream:respond(status, {
            ["content-type"] = "text/plain",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)
    end
}

print("HTTP server with routing listening on http://127.0.0.1:8080")
```

**关键概念**：

- `stream.path`：获取请求的 URL 路径
- 使用 `if-elseif-else` 实现简单路由
- 未匹配的路径返回 404 状态码

**测试路由**：

```bash
curl http://127.0.0.1:8080/          # Welcome to the home page!
curl http://127.0.0.1:8080/about     # This is the about page.
curl http://127.0.0.1:8080/unknown   # 404 Not Found: /unknown
```

### Step 3: JSON API

现代 Web 应用通常使用 JSON 格式交换数据。让我们构建一个 RESTful API：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- 模拟数据库
local users = {
    {id = 1, name = "Alice", age = 30},
    {id = 2, name = "Bob", age = 25},
}

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        local method = stream.method
        local path = stream.path

        -- GET /api/users - 获取所有用户
        if method == "GET" and path == "/api/users" then
            local response_body = json.encode(users)
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #response_body,
            })
            stream:close(response_body)

        -- POST /api/users - 创建新用户
        elseif method == "POST" and path == "/api/users" then
            local body, err = stream:readall()
            if not body then
                stream:respond(400, {})
                stream:close("Bad Request: Cannot read body")
                return
            end

            local user = json.decode(body)
            if user and user.name and user.age then
                user.id = #users + 1
                table.insert(users, user)

                local response_body = json.encode(user)
                stream:respond(201, {
                    ["content-type"] = "application/json",
                    ["content-length"] = #response_body,
                })
                stream:close(response_body)
            else
                stream:respond(400, {})
                stream:close("Bad Request: Invalid user data")
            end

        -- GET /api/users?name=Alice - 查询参数
        elseif method == "GET" and path:match("^/api/users%?") then
            local name_filter = stream.query["name"]
            local filtered_users = {}

            for _, user in ipairs(users) do
                if not name_filter or user.name == name_filter then
                    table.insert(filtered_users, user)
                end
            end

            local response_body = json.encode(filtered_users)
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #response_body,
            })
            stream:close(response_body)

        else
            stream:respond(404, {})
            stream:close("Not Found")
        end
    end
}

print("JSON API server listening on http://127.0.0.1:8080")
```

**关键概念**：

- `stream.method`：HTTP 方法（GET、POST 等）
- `stream:readall()`：读取完整的请求体（异步操作）
- `json.encode/decode`：JSON 序列化和反序列化
- `stream.query`：查询参数表（如 `?name=Alice`）
- 状态码 201：资源创建成功

**测试 JSON API**：

```bash
# 获取所有用户
curl http://127.0.0.1:8080/api/users

# 创建新用户
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Charlie","age":35}'

# 查询用户
curl "http://127.0.0.1:8080/api/users?name=Alice"
```

### Step 4: 静态文件服务

Web 服务器通常需要提供静态文件（HTML、CSS、图片等）：

```lua
local silly = require "silly"
local http = require "silly.net.http"

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        local path = stream.path

        -- 根路径返回 HTML 页面
        if path == "/" then
            local html = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Silly HTTP Server</title>
</head>
<body>
    <h1>Welcome to Silly HTTP Server</h1>
    <p>This is a static HTML page served by Silly framework.</p>
    <ul>
        <li><a href="/about">About</a></li>
        <li><a href="/api/status">API Status</a></li>
    </ul>
</body>
</html>
]]
            stream:respond(200, {
                ["content-type"] = "text/html; charset=utf-8",
                ["content-length"] = #html,
            })
            stream:close(html)

        elseif path == "/about" then
            local html = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>About</title>
</head>
<body>
    <h1>About Silly Framework</h1>
    <p>Silly is a lightweight server framework built with C and Lua.</p>
    <a href="/">Back to Home</a>
</body>
</html>
]]
            stream:respond(200, {
                ["content-type"] = "text/html; charset=utf-8",
                ["content-length"] = #html,
            })
            stream:close(html)

        elseif path == "/api/status" then
            local json = require "silly.encoding.json"
            local status = {
                server = "Silly HTTP Server",
                version = "1.0",
                uptime = os.time(),
            }
            local body = json.encode(status)
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #body,
            })
            stream:close(body)

        else
            stream:respond(404, {
                ["content-type"] = "text/html",
            })
            stream:close("<h1>404 Not Found</h1>")
        end
    end
}

print("Static file server listening on http://127.0.0.1:8080")
```

**关键概念**：

- 设置正确的 `content-type`：HTML 使用 `text/html`，JSON 使用 `application/json`
- 添加 `charset=utf-8` 确保中文正确显示
- 使用多行字符串 `[[...]]` 存储 HTML 内容

**测试静态文件服务**：

```bash
# 访问首页
curl http://127.0.0.1:8080/

# 访问 About 页面
curl http://127.0.0.1:8080/about

# 访问 API 状态
curl http://127.0.0.1:8080/api/status
```

## 完整代码

以下是一个综合示例，包含所有功能：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- 模拟用户数据
local users = {
    {id = 1, name = "Alice", age = 30, email = "alice@example.com"},
    {id = 2, name = "Bob", age = 25, email = "bob@example.com"},
}

-- 路由处理函数
local function handle_request(stream)
    local method = stream.method
    local path = stream.path

    -- 记录请求
    print(string.format("[%s] %s %s", os.date("%Y-%m-%d %H:%M:%S"), method, path))

    -- 首页 - HTML
    if method == "GET" and path == "/" then
        local html = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Silly HTTP Server</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }
        h1 { color: #333; }
        a { color: #007bff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .api-list { background: #f5f5f5; padding: 15px; border-radius: 5px; }
    </style>
</head>
<body>
    <h1>Welcome to Silly HTTP Server</h1>
    <p>A lightweight HTTP server built with Silly framework.</p>

    <h2>Available APIs:</h2>
    <div class="api-list">
        <ul>
            <li><a href="/api/users">GET /api/users</a> - Get all users</li>
            <li>POST /api/users - Create a new user</li>
            <li><a href="/api/users?name=Alice">GET /api/users?name=Alice</a> - Filter users by name</li>
            <li><a href="/api/status">GET /api/status</a> - Server status</li>
        </ul>
    </div>

    <h2>Pages:</h2>
    <ul>
        <li><a href="/about">About</a></li>
    </ul>
</body>
</html>
]]
        stream:respond(200, {
            ["content-type"] = "text/html; charset=utf-8",
            ["content-length"] = #html,
        })
        stream:close(html)
        return
    end

    -- About 页面
    if method == "GET" and path == "/about" then
        local html = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>About - Silly HTTP Server</title>
</head>
<body>
    <h1>About Silly Framework</h1>
    <p>Silly is a high-performance server framework that combines C for performance with Lua for flexibility.</p>
    <p>It achieves 200,000+ requests/second using a single-process, single-thread business logic model.</p>
    <p><a href="/">Back to Home</a></p>
</body>
</html>
]]
        stream:respond(200, {
            ["content-type"] = "text/html; charset=utf-8",
            ["content-length"] = #html,
        })
        stream:close(html)
        return
    end

    -- API: 获取所有用户
    if method == "GET" and path == "/api/users" then
        -- 检查是否有查询参数
        local name_filter = stream.query["name"]
        local result_users = users

        if name_filter then
            result_users = {}
            for _, user in ipairs(users) do
                if user.name == name_filter then
                    table.insert(result_users, user)
                end
            end
        end

        local response_body = json.encode(result_users)
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)
        return
    end

    -- API: 创建新用户
    if method == "POST" and path == "/api/users" then
        local body, err = stream:readall()
        if not body then
            stream:respond(400, {
                ["content-type"] = "application/json",
            })
            stream:close(json.encode({error = "Cannot read request body"}))
            return
        end

        local user = json.decode(body)
        if not user or not user.name or not user.age then
            stream:respond(400, {
                ["content-type"] = "application/json",
            })
            stream:close(json.encode({error = "Invalid user data. Required fields: name, age"}))
            return
        end

        -- 创建新用户
        user.id = #users + 1
        user.email = user.email or (user.name:lower() .. "@example.com")
        table.insert(users, user)

        local response_body = json.encode(user)
        stream:respond(201, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)
        return
    end

    -- API: 服务器状态
    if method == "GET" and path == "/api/status" then
        local status = {
            server = "Silly HTTP Server",
            version = "1.0.0",
            timestamp = os.time(),
            users_count = #users,
            protocol = stream.version,
        }
        local response_body = json.encode(status)
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)
        return
    end

    -- 404 Not Found
    local error_response = {
        error = "Not Found",
        path = path,
        method = method,
    }
    local response_body = json.encode(error_response)
    stream:respond(404, {
        ["content-type"] = "application/json",
        ["content-length"] = #response_body,
    })
    stream:close(response_body)
end

-- 启动 HTTP 服务器
http.listen {
    addr = "127.0.0.1:8080",
    handler = handle_request
}

print("===========================================")
print("  Silly HTTP Server Started")
print("===========================================")
print("  Listening on: http://127.0.0.1:8080")
print("  Press Ctrl+C to stop")
print("===========================================")

-- 可选：启动一个客户端测试
silly.fork(function()
    local response, err = http.GET("http://127.0.0.1:8080/api/status")
    if response then
        print("Self-test successful! Server status:", response.body)
    else
        print("Self-test failed:", err)
    end
end)
```

## 运行和测试

### 启动服务器

保存上面的完整代码到 `my_http_server.lua`，然后运行：

```bash
./silly my_http_server.lua
```

你应该看到如下输出：

```
===========================================
  Silly HTTP Server Started
===========================================
  Listening on: http://127.0.0.1:8080
  Press Ctrl+C to stop
===========================================
```

### 测试 API

在另一个终端中测试各个端点：

```bash
# 1. 访问首页
curl http://127.0.0.1:8080/

# 2. 获取所有用户
curl http://127.0.0.1:8080/api/users

# 3. 创建新用户
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Charlie","age":35,"email":"charlie@example.com"}'

# 4. 按名称查询用户
curl "http://127.0.0.1:8080/api/users?name=Alice"

# 5. 获取服务器状态
curl http://127.0.0.1:8080/api/status

# 6. 测试 404
curl http://127.0.0.1:8080/nonexistent

# 7. 访问 About 页面
curl http://127.0.0.1:8080/about
```

### 使用浏览器测试

也可以在浏览器中打开 http://127.0.0.1:8080，你会看到一个友好的 HTML 页面，点击链接可以浏览不同的页面和 API。

## 代码解析

### 核心组件

1. **路由系统**：使用 `method + path` 组合匹配不同的处理逻辑
2. **异步读取**：`stream:readall()` 异步读取 POST 请求体
3. **JSON 处理**：使用 `json.encode/decode` 处理 JSON 数据
4. **查询参数**：通过 `stream.query` 访问 URL 查询参数
5. **错误处理**：检查输入有效性，返回合适的状态码

### Stream 对象属性

- `stream.method`：HTTP 方法（GET、POST、PUT 等）
- `stream.path`：请求路径（不包含查询字符串）
- `stream.query`：查询参数表（键值对）
- `stream.header`：请求头表（键名小写）
- `stream.version`：协议版本（"HTTP/1.1" 或 "HTTP/2"）
- `stream.remoteaddr`：客户端地址

### 响应方法

- `stream:respond(status, headers)`：发送状态码和响应头
- `stream:close(body)`：发送响应体并关闭连接
- `stream:readall()`：读取完整请求体（异步）

### 最佳实践

1. **始终设置 Content-Length**：避免分块传输的开销
2. **检查返回值**：`readall()` 可能失败，需要检查错误
3. **使用正确的状态码**：200（成功）、201（创建）、400（错误请求）、404（未找到）
4. **设置正确的 Content-Type**：JSON 使用 `application/json`，HTML 使用 `text/html`
5. **记录请求日志**：便于调试和监控

## 扩展练习

尝试以下练习来加深理解：

### 练习 1: 更新和删除用户

实现 `PUT /api/users/:id` 和 `DELETE /api/users/:id` 端点：

```lua
-- 提示：需要解析 path 中的 ID
-- 例如：/api/users/1 -> id = 1
local id = path:match("^/api/users/(%d+)$")
if id then
    id = tonumber(id)
    -- 根据 method 执行更新或删除
end
```

### 练习 2: 中间件系统

实现一个简单的中间件系统，用于日志记录和身份验证：

```lua
-- 中间件函数
local function auth_middleware(stream)
    local token = stream.header["authorization"]
    if not token or token ~= "Bearer secret-token" then
        return false, "Unauthorized"
    end
    return true
end

-- 在 handler 中使用
local ok, err = auth_middleware(stream)
if not ok then
    stream:respond(401, {})
    stream:close(err)
    return
end
```

### 练习 3: 请求体大小限制

添加请求体大小检查，防止恶意大文件上传：

```lua
local content_length = tonumber(stream.header["content-length"])
if content_length and content_length > 1024 * 1024 then  -- 1MB limit
    stream:respond(413, {})  -- Payload Too Large
    stream:close("Request body too large")
    return
end
```

### 练习 4: CORS 支持

添加跨域资源共享（CORS）支持，允许浏览器跨域访问 API：

```lua
-- 在所有响应中添加 CORS 头部
local function cors_headers()
    return {
        ["access-control-allow-origin"] = "*",
        ["access-control-allow-methods"] = "GET, POST, PUT, DELETE, OPTIONS",
        ["access-control-allow-headers"] = "Content-Type, Authorization",
    }
end

-- 处理 OPTIONS 预检请求
if method == "OPTIONS" then
    local headers = cors_headers()
    headers["content-length"] = 0
    stream:respond(204, headers)
    stream:close()
    return
end
```

### 练习 5: 性能基准测试

使用 `wrk` 或 `ab` 工具测试服务器性能：

```bash
# 安装 wrk (Ubuntu/Debian)
sudo apt-get install wrk

# 基准测试
wrk -t4 -c100 -d30s http://127.0.0.1:8080/api/status
```

观察 Silly 框架的高性能表现！

## 下一步

恭喜完成 HTTP 服务器教程！你已经掌握了构建 Web 应用的基础。接下来可以学习：

- **数据库集成**：连接 MySQL、PostgreSQL 或 Redis（参考 [数据库应用教程](./database-app.md)）
- **WebSocket**：实现实时通信（参考 [silly.net.websocket](../reference/net/websocket.md)）
- **HTTPS/TLS**：添加加密支持（参考 [silly.net.tls](../reference/net/tls.md)）
- **gRPC**：构建高性能 RPC 服务（参考 [silly.net.grpc](../reference/net/grpc.md)）
- **集群部署**：多节点架构（参考 [silly.net.cluster](../reference/net/cluster.md)）

## 参考资料

- [silly.net.http API 参考](../reference/net/http.md)
- [silly.encoding.json API 参考](../reference/encoding/json.md)
- [HTTP/1.1 规范 (RFC 7230)](https://datatracker.ietf.org/doc/html/rfc7230)
- [RESTful API 设计指南](https://restfulapi.net/)
