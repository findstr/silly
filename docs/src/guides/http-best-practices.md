---
title: HTTP 服务最佳实践
icon: star
order: 6
category:
  - 指南
tag:
  - HTTP
  - 性能优化
  - 安全
  - 最佳实践
---

# HTTP 服务最佳实践

本指南提供 Silly 框架中构建高性能、安全、可维护的 HTTP 服务的最佳实践，涵盖性能优化、安全配置、错误处理、路由设计和监控等方面。

## 为什么需要最佳实践

在生产环境中运行 HTTP 服务时，简单的"能跑起来"是不够的。你需要考虑：

- **性能**：如何处理高并发请求？如何减少响应延迟？
- **安全**：如何防止常见的 Web 攻击？如何保护敏感数据？
- **可靠性**：如何优雅地处理错误？如何避免服务崩溃？
- **可维护性**：如何组织代码结构？如何方便调试和监控？

遵循本指南的最佳实践，可以帮助你构建生产级别的 HTTP 服务。

---

## 性能优化

### HTTP/2 优先

HTTP/2 相比 HTTP/1.1 提供多路复用、头部压缩等特性，显著提升性能。Silly 自动支持 HTTP/2，通过 ALPN 协商选择协议版本。

**配置 HTTP/2（HTTPS）**：

```lua
local silly = require "silly"
local http = require "silly.net.http"

-- 使用 TLS 证书启用 HTTPS，自动支持 HTTP/2
http.listen {
    addr = "0.0.0.0:8443",
    certs = {
        {
            cert = io.open("server.crt", "r"):read("*a"),
            key = io.open("server.key", "r"):read("*a"),
        }
    },
    handler = function(stream)
        -- stream.version 可以是 "HTTP/1.1" 或 "HTTP/2"
        print("Protocol:", stream.version)

        stream:respond(200, {
            ["content-type"] = "text/plain",
            ["content-length"] = #"Hello, HTTP/2!",
        })
        stream:close("Hello, HTTP/2!")
    end
}
```

**HTTP/2 的优势**：
- **多路复用**：单个连接可并发处理多个请求，减少连接开销
- **头部压缩**：HPACK 算法压缩请求头，节省带宽
- **服务器推送**：主动推送资源给客户端（Silly 支持）
- **二进制协议**：更高效的解析和传输

**注意**：HTTP/2 需要 HTTPS（TLS）支持，纯 HTTP/2（h2c）通常不推荐。

### Keep-Alive 连接

HTTP/1.1 默认启用 Keep-Alive，但 Silly 的 HTTP 客户端当前不支持连接池，每次请求会创建新连接。

**连接生命周期**：
- 服务器端自动处理连接复用（同一客户端的持久连接）
- 客户端每次请求创建新连接，请求完成后关闭

**客户端请求示例**：

```lua
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
    -- 每次请求创建新连接
    for i = 1, 100 do
        local response = http.GET("http://api.example.com/data/" .. i)
        if response then
            print("Request", i, "completed")
        end
    end
end)
```

注意：虽然不支持连接池，但 HTTP/2 的多路复用特性可以在单个连接上并发处理多个请求。

### 响应压缩（gzip）

对于文本内容（JSON、HTML、CSS），启用 gzip 压缩可以显著减少传输大小。

**实现 gzip 压缩**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local zlib = require "silly.compress.zlib"

local function should_compress(content_type)
    -- 只压缩文本类型
    return content_type:match("text/") or
           content_type:match("json") or
           content_type:match("xml") or
           content_type:match("javascript")
end

local function gzip_compress(data)
    local stream = zlib.deflate(zlib.GZIP)
    local compressed = stream(data, "finish")
    return compressed
end

http.listen {
    addr = ":8080",
    handler = function(stream)
        local accept_encoding = stream.header["accept-encoding"] or ""
        local supports_gzip = accept_encoding:match("gzip")

        local response_body = string.rep("Hello, World! ", 1000) -- 模拟大响应
        local content_type = "text/plain"

        if supports_gzip and should_compress(content_type) then
            -- 压缩响应
            local compressed = gzip_compress(response_body)

            stream:respond(200, {
                ["content-type"] = content_type,
                ["content-encoding"] = "gzip",
                ["content-length"] = #compressed,
                ["vary"] = "Accept-Encoding",
            })
            stream:close(compressed)
        else
            -- 未压缩响应
            stream:respond(200, {
                ["content-type"] = content_type,
                ["content-length"] = #response_body,
            })
            stream:close(response_body)
        end
    end
}
```

**压缩建议**：
- 只压缩大于 1KB 的响应（小响应压缩反而增加开销）
- 不要压缩已压缩的内容（图片、视频等）
- 使用 `vary: Accept-Encoding` 头部支持缓存
- 考虑压缩级别权衡（CPU vs 带宽）

### 流式响应

对于大文件或实时生成的内容，使用流式响应避免内存占用过高。

**HTTP/1.1 流式响应（分块传输）**：

```lua
local silly = require "silly"
local http = require "silly.net.http"

http.listen {
    addr = ":8080",
    handler = function(stream)
        if stream.version == "HTTP/1.1" then
            -- 使用分块传输编码
            stream:respond(200, {
                ["content-type"] = "text/plain",
                ["transfer-encoding"] = "chunked",
            })

            -- 分块发送数据
            for i = 1, 10 do
                stream:write("Chunk " .. i .. "\n")
                silly.sleep(100) -- 模拟实时生成
            end

            stream:close() -- 发送结束标记
        else
            -- HTTP/2 不支持 write()，使用 close() 一次性发送
            local data = {}
            for i = 1, 10 do
                data[#data + 1] = "Chunk " .. i .. "\n"
            end

            local response_body = table.concat(data)
            stream:respond(200, {
                ["content-type"] = "text/plain",
                ["content-length"] = #response_body,
            })
            stream:close(response_body)
        end
    end
}
```

**注意**：
- HTTP/2 stream 不支持 `write()` 方法，需要使用 `close(body)` 一次性发送
- 流式响应适合大文件下载、日志输出、Server-Sent Events (SSE) 等场景

### 并发请求优化

使用协程并发处理多个 HTTP 请求，充分利用 Silly 的异步 I/O 能力。

**并发请求示例**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local waitgroup = require "silly.sync.waitgroup"

silly.fork(function()
    local wg = waitgroup.new()
    local results = {}

    -- 并发发起 10 个请求
    for i = 1, 10 do
        wg:fork(function()
            local response = http.GET("http://api.example.com/data/" .. i)
            if response then
                results[i] = response.body
            end
        end)
    end

    wg:wait() -- 等待所有请求完成
    print("All requests completed, results:", #results)
end)
```

**并发处理服务器端请求**：

Silly 的 handler 函数在独立协程中执行，自动实现并发处理：

```lua
http.listen {
    addr = ":8080",
    handler = function(stream)
        -- 每个请求在独立协程中处理
        -- 可以安全地调用阻塞操作（如数据库查询）

        local data = query_database() -- 异步操作

        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #data,
        })
        stream:close(data)
    end
}
```

---

## 安全实践

### CORS 配置

跨域资源共享（CORS）允许浏览器跨域访问 API，正确配置 CORS 头部是 Web API 的基本要求。

**完整的 CORS 中间件**：

```lua
local silly = require "silly"
local http = require "silly.net.http"

-- CORS 配置
local CORS_CONFIG = {
    origins = {"https://example.com", "https://app.example.com"},
    methods = {"GET", "POST", "PUT", "DELETE", "OPTIONS"},
    headers = {"Content-Type", "Authorization", "X-Requested-With"},
    max_age = 86400, -- 预检请求缓存时间（秒）
    allow_credentials = true,
}

local function check_origin(origin)
    if not origin then return false end

    -- 检查是否在白名单中
    for _, allowed in ipairs(CORS_CONFIG.origins) do
        if origin == allowed then
            return true
        end
    end

    return false
end

local function add_cors_headers(stream, origin)
    return {
        ["access-control-allow-origin"] = origin,
        ["access-control-allow-methods"] = table.concat(CORS_CONFIG.methods, ", "),
        ["access-control-allow-headers"] = table.concat(CORS_CONFIG.headers, ", "),
        ["access-control-max-age"] = tostring(CORS_CONFIG.max_age),
        ["access-control-allow-credentials"] =
            CORS_CONFIG.allow_credentials and "true" or "false",
    }
end

http.listen {
    addr = ":8080",
    handler = function(stream)
        local origin = stream.header["origin"]

        -- 处理 OPTIONS 预检请求
        if stream.method == "OPTIONS" then
            if check_origin(origin) then
                local headers = add_cors_headers(stream, origin)
                headers["content-length"] = "0"
                stream:respond(204, headers)
                stream:close()
            else
                stream:respond(403, {["content-length"] = "0"})
                stream:close()
            end
            return
        end

        -- 处理实际请求
        local response_body = '{"status":"ok"}'
        local headers = {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        }

        -- 添加 CORS 头部
        if check_origin(origin) then
            local cors_headers = add_cors_headers(stream, origin)
            for k, v in pairs(cors_headers) do
                headers[k] = v
            end
        end

        stream:respond(200, headers)
        stream:close(response_body)
    end
}
```

**CORS 安全建议**：
- 不要使用 `*` 通配符（除非是公开 API）
- 维护明确的域名白名单
- 避免反射 `Origin` 头部（容易被绕过）
- 生产环境只允许 HTTPS 来源

### Rate Limiting（限流）

限流防止 API 被滥用，保护服务器资源。

**基于 IP 的简单限流**：

```lua
local silly = require "silly"
local http = require "silly.net.http"

-- 限流配置：每分钟最多 100 个请求
local RATE_LIMIT = 100
local WINDOW_SIZE = 60 -- 秒

-- 存储每个 IP 的请求计数
local request_counts = {}

local function check_rate_limit(ip)
    local now = os.time()

    if not request_counts[ip] then
        request_counts[ip] = {count = 0, window_start = now}
    end

    local record = request_counts[ip]

    -- 检查是否需要重置窗口
    if now - record.window_start >= WINDOW_SIZE then
        record.count = 0
        record.window_start = now
    end

    -- 检查是否超过限制
    if record.count >= RATE_LIMIT then
        return false, RATE_LIMIT - record.count
    end

    -- 增加计数
    record.count = record.count + 1
    return true, RATE_LIMIT - record.count
end

-- 清理过期记录（定期执行）
silly.timeout(300000, function() -- 每 5 分钟
    local now = os.time()
    for ip, record in pairs(request_counts) do
        if now - record.window_start > WINDOW_SIZE * 2 then
            request_counts[ip] = nil
        end
    end
end)

http.listen {
    addr = ":8080",
    handler = function(stream)
        local client_ip = stream.remoteaddr:match("^([^:]+)")

        local allowed, remaining = check_rate_limit(client_ip)

        if not allowed then
            -- 返回 429 Too Many Requests
            local error_body = '{"error":"Rate limit exceeded"}'
            stream:respond(429, {
                ["content-type"] = "application/json",
                ["content-length"] = #error_body,
                ["retry-after"] = tostring(WINDOW_SIZE),
                ["x-ratelimit-limit"] = tostring(RATE_LIMIT),
                ["x-ratelimit-remaining"] = "0",
            })
            stream:close(error_body)
            return
        end

        -- 正常处理请求
        local response_body = '{"status":"ok"}'
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
            ["x-ratelimit-limit"] = tostring(RATE_LIMIT),
            ["x-ratelimit-remaining"] = tostring(remaining),
        })
        stream:close(response_body)
    end
}
```

**高级限流方案**：
- **令牌桶算法**：更平滑的限流效果
- **基于用户的限流**：不同用户不同配额
- **分布式限流**：使用 Redis 实现多节点限流
- **动态调整**：根据服务器负载动态调整限制

### 请求大小限制

限制请求体大小防止恶意大文件上传耗尽服务器资源。

**检查 Content-Length 头部**：

```lua
local silly = require "silly"
local http = require "silly.net.http"

local MAX_BODY_SIZE = 10 * 1024 * 1024 -- 10MB

http.listen {
    addr = ":8080",
    handler = function(stream)
        -- 检查 Content-Length
        local content_length = tonumber(stream.header["content-length"] or 0)

        if content_length > MAX_BODY_SIZE then
            local error_body = '{"error":"Payload too large"}'
            stream:respond(413, { -- 413 Payload Too Large
                ["content-type"] = "application/json",
                ["content-length"] = #error_body,
            })
            stream:close(error_body)
            return
        end

        -- 读取请求体
        if stream.method == "POST" or stream.method == "PUT" then
            local body, err = stream:readall()
            if not body then
                stream:respond(400, {})
                stream:close("Bad Request")
                return
            end

            -- 处理请求体
            print("Received body size:", #body)
        end

        stream:respond(200, {})
        stream:close("OK")
    end
}
```

**注意**：
- 始终验证 `content-length` 头部
- 考虑设置合理的超时时间
- 对于文件上传，使用流式处理而非一次性加载到内存

### 超时设置

设置合理的超时避免慢速攻击和资源泄漏。

**使用协程超时保护**：

```lua
local silly = require "silly"
local http = require "silly.net.http"

local REQUEST_TIMEOUT = 30000 -- 30 秒

local function with_timeout(timeout_ms, func)
    local channel = require("silly.sync.channel").new(1)
    local timer_id

    -- 启动任务协程
    silly.fork(function()
        local ok, result = pcall(func)
        channel:push({success = ok, result = result, completed = true})
    end)

    -- 启动超时定时器
    timer_id = silly.timeout(timeout_ms, function()
        channel:push({success = false, result = "timeout", completed = false})
    end)

    -- 等待结果
    local result = channel:pop()

    if result.completed then
        silly.cancel(timer_id) -- 取消定时器
    end

    if not result.success then
        error(result.result)
    end

    return result.result
end

http.listen {
    addr = ":8080",
    handler = function(stream)
        local ok, err = pcall(function()
            with_timeout(REQUEST_TIMEOUT, function()
                -- 处理请求（可能很慢）
                local body = stream:readall()

                -- 模拟慢速操作
                silly.sleep(1000)

                stream:respond(200, {})
                stream:close("OK")
            end)
        end)

        if not ok then
            if err == "timeout" then
                stream:respond(408, {}) -- 408 Request Timeout
                stream:close("Request Timeout")
            else
                stream:respond(500, {})
                stream:close("Internal Server Error")
            end
        end
    end
}
```

---

## 错误处理

### 统一错误响应格式

定义统一的错误响应格式，便于客户端解析和处理。

**标准错误响应格式**：

```lua
local json = require "silly.encoding.json"

-- 错误响应格式
local function error_response(code, message, details)
    return {
        error = {
            code = code,
            message = message,
            details = details,
            timestamp = os.time(),
        }
    }
end

-- 发送错误响应
local function send_error(stream, status, code, message, details)
    local error_body = json.encode(error_response(code, message, details))

    stream:respond(status, {
        ["content-type"] = "application/json; charset=utf-8",
        ["content-length"] = #error_body,
        ["cache-control"] = "no-store",
    })
    stream:close(error_body)
end

-- 使用示例
http.listen {
    addr = ":8080",
    handler = function(stream)
        if stream.method ~= "POST" then
            send_error(stream, 405, "METHOD_NOT_ALLOWED",
                "Only POST method is allowed", {allowed_methods = {"POST"}})
            return
        end

        local body, err = stream:readall()
        if not body then
            send_error(stream, 400, "INVALID_REQUEST",
                "Failed to read request body", {error = err})
            return
        end

        local data = json.decode(body)
        if not data or not data.name then
            send_error(stream, 400, "VALIDATION_ERROR",
                "Missing required field: name", {required_fields = {"name"}})
            return
        end

        -- 正常处理
        local response_body = json.encode({status = "success", data = data})
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)
    end
}
```

**错误响应示例**：

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Missing required field: name",
    "details": {
      "required_fields": ["name"]
    },
    "timestamp": 1699999999
  }
}
```

### 错误码设计

设计清晰的错误码系统，方便问题定位和处理。

**错误码定义**：

```lua
-- 错误码常量
local ErrorCodes = {
    -- 客户端错误 (400-499)
    INVALID_REQUEST = {status = 400, code = "INVALID_REQUEST", message = "Invalid request"},
    UNAUTHORIZED = {status = 401, code = "UNAUTHORIZED", message = "Authentication required"},
    FORBIDDEN = {status = 403, code = "FORBIDDEN", message = "Access denied"},
    NOT_FOUND = {status = 404, code = "NOT_FOUND", message = "Resource not found"},
    METHOD_NOT_ALLOWED = {status = 405, code = "METHOD_NOT_ALLOWED", message = "Method not allowed"},
    VALIDATION_ERROR = {status = 400, code = "VALIDATION_ERROR", message = "Validation failed"},
    RATE_LIMIT_EXCEEDED = {status = 429, code = "RATE_LIMIT_EXCEEDED", message = "Too many requests"},

    -- 服务器错误 (500-599)
    INTERNAL_ERROR = {status = 500, code = "INTERNAL_ERROR", message = "Internal server error"},
    SERVICE_UNAVAILABLE = {status = 503, code = "SERVICE_UNAVAILABLE", message = "Service unavailable"},
    DATABASE_ERROR = {status = 500, code = "DATABASE_ERROR", message = "Database error"},
}

-- 便捷函数
local function send_error_code(stream, error_code, details)
    local error_body = json.encode({
        error = {
            code = error_code.code,
            message = error_code.message,
            details = details,
            timestamp = os.time(),
        }
    })

    stream:respond(error_code.status, {
        ["content-type"] = "application/json",
        ["content-length"] = #error_body,
    })
    stream:close(error_body)
end

-- 使用示例
http.listen {
    addr = ":8080",
    handler = function(stream)
        local user = authenticate(stream.header["authorization"])
        if not user then
            send_error_code(stream, ErrorCodes.UNAUTHORIZED)
            return
        end

        -- 正常处理
    end
}
```

### 异常捕获

使用 `pcall` 捕获异常，避免单个请求错误导致服务崩溃。

**全局异常处理器**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
local json = require "silly.encoding.json"

-- 全局错误处理器
local function safe_handler(handler)
    return function(stream)
        local ok, err = pcall(function()
            handler(stream)
        end)

        if not ok then
            -- 记录错误
            logger.error("Request handler error:", err,
                "\nMethod:", stream.method,
                "\nPath:", stream.path,
                "\nRemote:", stream.remoteaddr)

            -- 发送 500 错误（如果还未响应）
            pcall(function()
                local error_body = json.encode({
                    error = {
                        code = "INTERNAL_ERROR",
                        message = "Internal server error",
                        timestamp = os.time(),
                    }
                })

                stream:respond(500, {
                    ["content-type"] = "application/json",
                    ["content-length"] = #error_body,
                })
                stream:close(error_body)
            end)
        end
    end
end

-- 业务处理器
local function my_handler(stream)
    -- 可能抛出异常的代码
    local data = query_database() -- 可能失败

    local response_body = json.encode(data)
    stream:respond(200, {
        ["content-type"] = "application/json",
        ["content-length"] = #response_body,
    })
    stream:close(response_body)
end

-- 使用安全包装器
http.listen {
    addr = ":8080",
    handler = safe_handler(my_handler)
}
```

---

## 路由设计

### RESTful API 设计

遵循 RESTful 原则设计清晰、一致的 API。

**RESTful 资源示例**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- 模拟数据存储
local users = {
    {id = 1, name = "Alice", email = "alice@example.com"},
    {id = 2, name = "Bob", email = "bob@example.com"},
}
local next_id = 3

-- 路由表
local routes = {
    -- GET /api/users - 获取所有用户
    {method = "GET", pattern = "^/api/users$", handler = function(stream, matches)
        local response_body = json.encode(users)
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)
    end},

    -- GET /api/users/:id - 获取单个用户
    {method = "GET", pattern = "^/api/users/(%d+)$", handler = function(stream, matches)
        local user_id = tonumber(matches[1])
        local user = nil

        for _, u in ipairs(users) do
            if u.id == user_id then
                user = u
                break
            end
        end

        if user then
            local response_body = json.encode(user)
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #response_body,
            })
            stream:close(response_body)
        else
            send_error(stream, 404, "NOT_FOUND", "User not found")
        end
    end},

    -- POST /api/users - 创建用户
    {method = "POST", pattern = "^/api/users$", handler = function(stream, matches)
        local body = stream:readall()
        local user = json.decode(body)

        if not user or not user.name or not user.email then
            send_error(stream, 400, "VALIDATION_ERROR", "Missing required fields")
            return
        end

        user.id = next_id
        next_id = next_id + 1
        table.insert(users, user)

        local response_body = json.encode(user)
        stream:respond(201, { -- 201 Created
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
            ["location"] = "/api/users/" .. user.id,
        })
        stream:close(response_body)
    end},

    -- PUT /api/users/:id - 更新用户
    {method = "PUT", pattern = "^/api/users/(%d+)$", handler = function(stream, matches)
        local user_id = tonumber(matches[1])
        local body = stream:readall()
        local updated = json.decode(body)

        for i, user in ipairs(users) do
            if user.id == user_id then
                user.name = updated.name or user.name
                user.email = updated.email or user.email

                local response_body = json.encode(user)
                stream:respond(200, {
                    ["content-type"] = "application/json",
                    ["content-length"] = #response_body,
                })
                stream:close(response_body)
                return
            end
        end

        send_error(stream, 404, "NOT_FOUND", "User not found")
    end},

    -- DELETE /api/users/:id - 删除用户
    {method = "DELETE", pattern = "^/api/users/(%d+)$", handler = function(stream, matches)
        local user_id = tonumber(matches[1])

        for i, user in ipairs(users) do
            if user.id == user_id then
                table.remove(users, i)
                stream:respond(204, {}) -- 204 No Content
                stream:close()
                return
            end
        end

        send_error(stream, 404, "NOT_FOUND", "User not found")
    end},
}

-- 路由匹配
local function match_route(method, path)
    for _, route in ipairs(routes) do
        if route.method == method then
            local matches = {path:match(route.pattern)}
            if #matches > 0 or path:match(route.pattern) then
                return route.handler, matches
            end
        end
    end
    return nil
end

http.listen {
    addr = ":8080",
    handler = function(stream)
        local handler, matches = match_route(stream.method, stream.path)

        if handler then
            handler(stream, matches)
        else
            send_error(stream, 404, "NOT_FOUND", "Endpoint not found")
        end
    end
}
```

**RESTful 设计原则**：
- 使用名词表示资源：`/users` 而非 `/getUsers`
- 使用 HTTP 方法表示操作：GET（查询）、POST（创建）、PUT（更新）、DELETE（删除）
- 使用层级表示关系：`/users/1/posts/2`
- 使用查询参数过滤：`/users?status=active&limit=10`
- 使用正确的状态码：200（成功）、201（创建）、204（无内容）、404（未找到）

### 路由表组织

将路由定义组织成模块化结构，提高可维护性。

**模块化路由示例**：

```lua
-- routes/users.lua
local json = require "silly.encoding.json"

local UserRoutes = {}

function UserRoutes.list(stream)
    -- GET /api/users
    local users = get_all_users()
    local response_body = json.encode(users)
    stream:respond(200, {
        ["content-type"] = "application/json",
        ["content-length"] = #response_body,
    })
    stream:close(response_body)
end

function UserRoutes.get(stream, user_id)
    -- GET /api/users/:id
    local user = get_user_by_id(user_id)
    if user then
        local response_body = json.encode(user)
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)
    else
        send_error(stream, 404, "NOT_FOUND", "User not found")
    end
end

function UserRoutes.create(stream)
    -- POST /api/users
    local body = stream:readall()
    local user = json.decode(body)
    local created = create_user(user)

    local response_body = json.encode(created)
    stream:respond(201, {
        ["content-type"] = "application/json",
        ["content-length"] = #response_body,
        ["location"] = "/api/users/" .. created.id,
    })
    stream:close(response_body)
end

return UserRoutes
```

```lua
-- main.lua
local silly = require "silly"
local http = require "silly.net.http"
local UserRoutes = require "routes.users"
local ProductRoutes = require "routes.products"

-- 路由定义
local routes = {
    {method = "GET", pattern = "^/api/users$", handler = UserRoutes.list},
    {method = "GET", pattern = "^/api/users/(%d+)$", handler = UserRoutes.get},
    {method = "POST", pattern = "^/api/users$", handler = UserRoutes.create},

    {method = "GET", pattern = "^/api/products$", handler = ProductRoutes.list},
    {method = "GET", pattern = "^/api/products/(%d+)$", handler = ProductRoutes.get},
}

-- 启动服务器
http.listen {
    addr = ":8080",
    handler = function(stream)
        local handler, matches = match_route(stream.method, stream.path)
        if handler then
            handler(stream, table.unpack(matches))
        else
            send_error(stream, 404, "NOT_FOUND", "Endpoint not found")
        end
    end
}
```

### 中间件模式

实现中间件系统，实现横切关注点（日志、认证、CORS 等）。

**中间件实现**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"

-- 中间件链
local function chain(middlewares, final_handler)
    return function(stream)
        local index = 1

        local function next()
            if index <= #middlewares then
                local middleware = middlewares[index]
                index = index + 1
                middleware(stream, next)
            else
                final_handler(stream)
            end
        end

        next()
    end
end

-- 日志中间件
local function logging_middleware(stream, next)
    local start = os.clock()

    logger.info("Request:", stream.method, stream.path, "from", stream.remoteaddr)

    next() -- 继续处理

    local duration = os.clock() - start
    logger.info("Response:", stream.method, stream.path,
        "completed in", string.format("%.3fms", duration * 1000))
end

-- 认证中间件
local function auth_middleware(stream, next)
    local token = stream.header["authorization"]

    if not token or not validate_token(token) then
        send_error(stream, 401, "UNAUTHORIZED", "Invalid or missing token")
        return -- 不调用 next()，中断链
    end

    -- 将用户信息附加到 stream
    stream.user = extract_user_from_token(token)

    next() -- 继续处理
end

-- CORS 中间件
local function cors_middleware(stream, next)
    local origin = stream.header["origin"]

    -- 处理 OPTIONS 预检请求
    if stream.method == "OPTIONS" then
        stream:respond(204, {
            ["access-control-allow-origin"] = origin or "*",
            ["access-control-allow-methods"] = "GET, POST, PUT, DELETE",
            ["access-control-allow-headers"] = "Content-Type, Authorization",
            ["content-length"] = "0",
        })
        stream:close()
        return
    end

    -- 为实际请求添加 CORS 头部（需要修改响应）
    -- 注意：这里简化处理，实际需要在响应时添加头部
    stream.cors_origin = origin

    next()
end

-- 业务处理器
local function my_handler(stream)
    local response_body = '{"status":"ok"}'
    stream:respond(200, {
        ["content-type"] = "application/json",
        ["content-length"] = #response_body,
        ["access-control-allow-origin"] = stream.cors_origin or "*",
    })
    stream:close(response_body)
end

-- 组合中间件
local handler = chain({
    logging_middleware,
    cors_middleware,
    auth_middleware,
}, my_handler)

http.listen {
    addr = ":8080",
    handler = handler
}
```

---

## 监控和日志

### 访问日志

记录每个请求的详细信息，便于审计和问题排查。

**结构化访问日志**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
local json = require "silly.encoding.json"

local function access_log(stream, status, duration, response_size)
    local log_entry = {
        timestamp = os.date("%Y-%m-%dT%H:%M:%S"),
        method = stream.method,
        path = stream.path,
        query = stream.query,
        status = status,
        duration_ms = string.format("%.3f", duration * 1000),
        response_size = response_size,
        remote_addr = stream.remoteaddr,
        user_agent = stream.header["user-agent"] or "",
        referer = stream.header["referer"] or "",
        protocol = stream.version,
    }

    logger.info("ACCESS", json.encode(log_entry))
end

http.listen {
    addr = ":8080",
    handler = function(stream)
        local start = os.clock()

        -- 处理请求
        local response_body = '{"status":"ok"}'
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)

        -- 记录访问日志
        local duration = os.clock() - start
        access_log(stream, 200, duration, #response_body)
    end
}
```

**日志输出示例**：

```
[INFO] ACCESS {"timestamp":"2025-10-14T10:30:45","method":"GET","path":"/api/users","query":{},"status":200,"duration_ms":"1.234","response_size":123,"remote_addr":"127.0.0.1:54321","user_agent":"curl/7.68.0","referer":"","protocol":"HTTP/1.1"}
```

### 性能指标

使用 Prometheus 指标监控服务性能。

**集成 Prometheus 监控**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local prometheus = require "silly.metrics.prometheus"

-- 定义指标
local http_requests_total = prometheus.counter(
    "http_requests_total",
    "Total number of HTTP requests",
    {"method", "path", "status"}
)

local http_request_duration_seconds = prometheus.histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    {"method", "path"},
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0}
)

local http_request_size_bytes = prometheus.histogram(
    "http_request_size_bytes",
    "HTTP request size in bytes",
    nil,
    {100, 1000, 10000, 100000, 1000000}
)

local http_response_size_bytes = prometheus.histogram(
    "http_response_size_bytes",
    "HTTP response size in bytes",
    nil,
    {100, 1000, 10000, 100000, 1000000}
)

local http_requests_in_flight = prometheus.gauge(
    "http_requests_in_flight",
    "Current number of HTTP requests being processed"
)

http.listen {
    addr = ":8080",
    handler = function(stream)
        local start = os.clock()
        http_requests_in_flight:inc()

        -- 记录请求大小
        local request_size = tonumber(stream.header["content-length"] or 0)
        http_request_size_bytes:observe(request_size)

        -- Metrics 端点
        if stream.path == "/metrics" then
            local metrics = prometheus.gather()
            stream:respond(200, {
                ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
                ["content-length"] = #metrics,
            })
            stream:close(metrics)
            http_requests_in_flight:dec()
            return
        end

        -- 业务处理
        local response_body = '{"status":"ok"}'
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)

        -- 记录指标
        local duration = os.clock() - start
        http_request_duration_seconds:labels(stream.method, stream.path):observe(duration)
        http_response_size_bytes:observe(#response_body)
        http_requests_total:labels(stream.method, stream.path, "200"):inc()
        http_requests_in_flight:dec()
    end
}
```

**配置 Prometheus 抓取**：

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'silly_http_server'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: '/metrics'
    scrape_interval: 15s
```

### 请求追踪

使用 Trace ID 追踪请求在系统中的流转。

**实现请求追踪**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"

-- 生成 Trace ID
local function generate_trace_id()
    local random = math.random
    return string.format("%08x%08x%08x%08x",
        random(0, 0xffffffff),
        random(0, 0xffffffff),
        random(0, 0xffffffff),
        random(0, 0xffffffff))
end

-- 带追踪的日志
local function trace_log(trace_id, level, ...)
    logger[level]("[" .. trace_id .. "]", ...)
end

http.listen {
    addr = ":8080",
    handler = function(stream)
        -- 从请求头获取或生成 Trace ID
        local trace_id = stream.header["x-trace-id"] or generate_trace_id()

        trace_log(trace_id, "info", "Request started:", stream.method, stream.path)

        -- 处理请求
        local ok, err = pcall(function()
            -- 业务逻辑
            trace_log(trace_id, "debug", "Processing request")

            -- 模拟调用其他服务
            local service_response = call_external_service(trace_id)

            trace_log(trace_id, "debug", "External service responded")

            local response_body = '{"status":"ok"}'
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #response_body,
                ["x-trace-id"] = trace_id, -- 返回 Trace ID
            })
            stream:close(response_body)
        end)

        if not ok then
            trace_log(trace_id, "error", "Request failed:", err)
            stream:respond(500, {["x-trace-id"] = trace_id})
            stream:close("Internal Server Error")
        end

        trace_log(trace_id, "info", "Request completed")
    end
}

-- 调用外部服务时传递 Trace ID
function call_external_service(trace_id)
    local response = http.GET("http://other-service/api", {
        ["x-trace-id"] = trace_id,
    })
    return response
end
```

**日志输出示例**：

```
[INFO] [a1b2c3d4e5f60718] Request started: GET /api/users
[DEBUG] [a1b2c3d4e5f60718] Processing request
[DEBUG] [a1b2c3d4e5f60718] External service responded
[INFO] [a1b2c3d4e5f60718] Request completed
```

---

## 部署建议

### 反向代理（Nginx）

使用 Nginx 作为反向代理，提供 SSL 终止、负载均衡、静态文件服务等功能。

**Nginx 配置示例**：

```nginx
upstream silly_backend {
    # 负载均衡配置
    least_conn; # 最少连接算法

    server 127.0.0.1:8080 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8081 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8082 max_fails=3 fail_timeout=30s;

    # 健康检查（需要 nginx-plus 或 tengine）
    # check interval=3000 rise=2 fall=3 timeout=1000;
}

# HTTP 服务器（重定向到 HTTPS）
server {
    listen 80;
    server_name api.example.com;

    # 重定向到 HTTPS
    return 301 https://$server_name$request_uri;
}

# HTTPS 服务器
server {
    listen 443 ssl http2;
    server_name api.example.com;

    # SSL 证书
    ssl_certificate /etc/nginx/ssl/api.example.com.crt;
    ssl_certificate_key /etc/nginx/ssl/api.example.com.key;

    # SSL 配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 客户端请求体大小限制
    client_max_body_size 10M;

    # 超时设置
    proxy_connect_timeout 10s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;

    # 静态文件
    location /static/ {
        alias /var/www/static/;
        expires 7d;
        add_header Cache-Control "public, immutable";
    }

    # API 代理
    location /api/ {
        proxy_pass http://silly_backend;

        # 传递客户端信息
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 禁用缓冲（用于流式响应）
        proxy_buffering off;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Metrics 端点（限制访问）
    location /metrics {
        allow 10.0.0.0/8; # 只允许内网访问
        deny all;

        proxy_pass http://silly_backend;
        proxy_set_header Host $host;
    }

    # 健康检查端点
    location /health {
        proxy_pass http://silly_backend;
        access_log off; # 不记录健康检查日志
    }
}
```

**在 Silly 中读取真实 IP**：

```lua
http.listen {
    addr = ":8080",
    handler = function(stream)
        -- 从 Nginx 传递的头部获取真实 IP
        local real_ip = stream.header["x-real-ip"] or
                       stream.header["x-forwarded-for"] or
                       stream.remoteaddr

        print("Client IP:", real_ip)

        -- 处理请求
    end
}
```

### 负载均衡

使用多进程或多实例实现负载均衡，充分利用多核 CPU。

**多进程部署脚本**：

```bash
#!/bin/bash
# start_cluster.sh

INSTANCES=4
BASE_PORT=8080

for i in $(seq 1 $INSTANCES); do
    PORT=$((BASE_PORT + i - 1))
    ./silly main.lua --port=$PORT &
    echo "Started instance $i on port $PORT"
done

echo "All instances started"
```

**在 Silly 中读取端口配置**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local env = require "silly.env"

local port = tonumber(env.get("port")) or 8080

http.listen {
    addr = "0.0.0.0:" .. port,
    handler = function(stream)
        -- 处理请求
    end
}

silly.start(function()
    print("Server started on port", port)
end)
```

**运行服务器**：

```bash
./silly main.lua --port=8080
./silly main.lua --port=8081
./silly main.lua --port=8082
./silly main.lua --port=8083
```

### 健康检查

实现健康检查端点，便于负载均衡器监控服务状态。

**健康检查端点**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- 健康状态
local health_status = {
    healthy = true,
    last_check = os.time(),
    checks = {},
}

-- 检查数据库连接
local function check_database()
    local ok, err = pcall(function()
        -- 执行简单查询
        query_database("SELECT 1")
    end)
    return ok, ok and "ok" or err
end

-- 检查缓存连接
local function check_cache()
    local ok, err = pcall(function()
        -- Ping 缓存
        cache_ping()
    end)
    return ok, ok and "ok" or err
end

-- 执行所有健康检查
local function perform_health_check()
    health_status.checks.database = {check_database()}
    health_status.checks.cache = {check_cache()}
    health_status.last_check = os.time()

    -- 判断整体健康状态
    health_status.healthy = health_status.checks.database[1] and
                           health_status.checks.cache[1]
end

-- 定期健康检查
silly.timeout(10000, function() -- 每 10 秒
    perform_health_check()
end)

http.listen {
    addr = ":8080",
    handler = function(stream)
        if stream.path == "/health" then
            -- 简单健康检查（快速响应）
            if health_status.healthy then
                stream:respond(200, {})
                stream:close("OK")
            else
                stream:respond(503, {})
                stream:close("Unhealthy")
            end
        elseif stream.path == "/health/detailed" then
            -- 详细健康检查（包含依赖状态）
            perform_health_check()

            local response_body = json.encode({
                healthy = health_status.healthy,
                timestamp = os.time(),
                last_check = health_status.last_check,
                checks = health_status.checks,
            })

            local status = health_status.healthy and 200 or 503
            stream:respond(status, {
                ["content-type"] = "application/json",
                ["content-length"] = #response_body,
            })
            stream:close(response_body)
        else
            -- 其他请求
        end
    end
}
```

**Kubernetes 健康检查配置**：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: silly-http-server
spec:
  containers:
  - name: silly
    image: silly-http-server:latest
    ports:
    - containerPort: 8080
    livenessProbe:
      httpGet:
        path: /health
        port: 8080
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 5
      failureThreshold: 3
    readinessProbe:
      httpGet:
        path: /health/detailed
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 5
      timeoutSeconds: 3
      failureThreshold: 2
```

---

## 完整示例：生产级 HTTP 服务

以下是一个综合所有最佳实践的完整示例：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"
local logger = require "silly.logger"
local prometheus = require "silly.metrics.prometheus"

-- 配置
local CONFIG = {
    port = tonumber(os.getenv("PORT")) or 8080,
    max_body_size = 10 * 1024 * 1024, -- 10MB
    request_timeout = 30000, -- 30 秒
    rate_limit = 100, -- 每分钟 100 个请求
}

-- 错误码定义
local ErrorCodes = {
    VALIDATION_ERROR = {status = 400, code = "VALIDATION_ERROR", message = "Validation failed"},
    UNAUTHORIZED = {status = 401, code = "UNAUTHORIZED", message = "Authentication required"},
    RATE_LIMIT_EXCEEDED = {status = 429, code = "RATE_LIMIT_EXCEEDED", message = "Too many requests"},
    INTERNAL_ERROR = {status = 500, code = "INTERNAL_ERROR", message = "Internal server error"},
}

-- Prometheus 指标
local metrics = {
    requests = prometheus.counter("http_requests_total", "Total requests",
        {"method", "path", "status"}),
    duration = prometheus.histogram("http_request_duration_seconds", "Request duration",
        {"method", "path"}, {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0}),
    in_flight = prometheus.gauge("http_requests_in_flight", "Requests in flight"),
}

-- 限流
local rate_limiter = {}
local function check_rate_limit(ip)
    local now = os.time()
    local record = rate_limiter[ip]

    if not record or now - record.window >= 60 then
        rate_limiter[ip] = {count = 1, window = now}
        return true
    end

    if record.count >= CONFIG.rate_limit then
        return false
    end

    record.count = record.count + 1
    return true
end

-- 错误响应
local function send_error(stream, error_code, details)
    local error_body = json.encode({
        error = {
            code = error_code.code,
            message = error_code.message,
            details = details,
            timestamp = os.time(),
        }
    })

    stream:respond(error_code.status, {
        ["content-type"] = "application/json",
        ["content-length"] = #error_body,
    })
    stream:close(error_body)
end

-- 中间件：日志
local function logging_middleware(stream, next)
    local trace_id = stream.header["x-trace-id"] or
        string.format("%08x", math.random(0, 0xffffffff))
    stream.trace_id = trace_id

    logger.info("[" .. trace_id .. "] Request:", stream.method, stream.path,
        "from", stream.remoteaddr)

    next()
end

-- 中间件：限流
local function rate_limit_middleware(stream, next)
    local ip = stream.remoteaddr:match("^([^:]+)")

    if not check_rate_limit(ip) then
        send_error(stream, ErrorCodes.RATE_LIMIT_EXCEEDED)
        return
    end

    next()
end

-- 中间件：请求大小检查
local function body_size_middleware(stream, next)
    local content_length = tonumber(stream.header["content-length"] or 0)

    if content_length > CONFIG.max_body_size then
        stream:respond(413, {})
        stream:close("Payload Too Large")
        return
    end

    next()
end

-- 业务路由
local routes = {
    {method = "GET", pattern = "^/api/users$", handler = function(stream)
        local users = {{id = 1, name = "Alice"}, {id = 2, name = "Bob"}}
        local response_body = json.encode(users)
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:close(response_body)
    end},

    {method = "GET", pattern = "^/health$", handler = function(stream)
        stream:respond(200, {})
        stream:close("OK")
    end},

    {method = "GET", pattern = "^/metrics$", handler = function(stream)
        local metrics_data = prometheus.gather()
        stream:respond(200, {
            ["content-type"] = "text/plain; version=0.0.4",
            ["content-length"] = #metrics_data,
        })
        stream:close(metrics_data)
    end},
}

-- 路由匹配
local function match_route(method, path)
    for _, route in ipairs(routes) do
        if route.method == method and path:match(route.pattern) then
            return route.handler
        end
    end
    return nil
end

-- 主处理器
local function main_handler(stream)
    local start = os.clock()
    metrics.in_flight:inc()

    local handler = match_route(stream.method, stream.path)

    if handler then
        local ok, err = pcall(handler, stream)
        if not ok then
            logger.error("[" .. stream.trace_id .. "] Handler error:", err)
            send_error(stream, ErrorCodes.INTERNAL_ERROR)
        end
    else
        stream:respond(404, {})
        stream:close("Not Found")
    end

    local duration = os.clock() - start
    metrics.duration:labels(stream.method, stream.path):observe(duration)
    metrics.requests:labels(stream.method, stream.path, "200"):inc()
    metrics.in_flight:dec()
end

-- 中间件链
local function chain(middlewares, handler)
    return function(stream)
        local index = 1
        local function next()
            if index <= #middlewares then
                local middleware = middlewares[index]
                index = index + 1
                middleware(stream, next)
            else
                handler(stream)
            end
        end
        next()
    end
end

-- 启动服务器
local handler = chain({
    logging_middleware,
    rate_limit_middleware,
    body_size_middleware,
}, main_handler)

http.listen {
    addr = "0.0.0.0:" .. CONFIG.port,
    handler = handler
}

silly.start(function()
    logger.info("HTTP server started on port", CONFIG.port)
end)
```

---

## 总结

本指南涵盖了构建生产级 HTTP 服务的关键最佳实践：

1. **性能优化**：HTTP/2、连接复用、响应压缩、流式传输、并发处理
2. **安全实践**：CORS 配置、限流、请求大小限制、超时设置
3. **错误处理**：统一错误格式、错误码设计、异常捕获
4. **路由设计**：RESTful API、模块化路由、中间件模式
5. **监控日志**：访问日志、Prometheus 指标、请求追踪
6. **部署建议**：Nginx 反向代理、负载均衡、健康检查

遵循这些实践，可以构建高性能、安全、可维护的 HTTP 服务。

## 参考资料

- [silly.net.http API 参考](../reference/net/http.md)
- [HTTP 服务器教程](../tutorials/http-server.md)
- [silly.metrics.prometheus](../reference/metrics/prometheus.md)
- [silly.logger](../reference/logger.md)
- [Nginx 官方文档](https://nginx.org/en/docs/)
- [HTTP/2 规范 (RFC 7540)](https://datatracker.ietf.org/doc/html/rfc7540)
