---
title: HTTP Service Best Practices
icon: star
order: 6
category:
  - Guides
tag:
  - HTTP
  - Performance Optimization
  - Security
  - Best Practices
---

# HTTP Service Best Practices

This guide provides best practices for building high-performance, secure, and maintainable HTTP services in the Silly framework, covering performance optimization, security configuration, error handling, routing design, and monitoring.

## Why Best Practices Matter

When running HTTP services in production, simply "making it work" is not enough. You need to consider:

- **Performance**: How to handle high concurrent requests? How to reduce response latency?
- **Security**: How to prevent common web attacks? How to protect sensitive data?
- **Reliability**: How to handle errors gracefully? How to avoid service crashes?
- **Maintainability**: How to organize code structure? How to facilitate debugging and monitoring?

Following the best practices in this guide will help you build production-grade HTTP services.

---

## Performance Optimization

### HTTP/2 Priority

HTTP/2 provides features like multiplexing and header compression compared to HTTP/1.1, significantly improving performance. Silly automatically supports HTTP/2, selecting the protocol version through ALPN negotiation.

**Configure HTTP/2 (HTTPS)**:

```lua
local silly = require "silly"
local http = require "silly.net.http"

-- Enable HTTPS with TLS certificate, automatically supports HTTP/2
http.listen {
    addr = "0.0.0.0:8443",
    certs = {
        {
            cert = io.open("server.crt", "r"):read("*a"),
            key = io.open("server.key", "r"):read("*a"),
        }
    },
    handler = function(stream)
        -- stream.version can be "HTTP/1.1" or "HTTP/2"
        print("Protocol:", stream.version)

        stream:respond(200, {
            ["content-type"] = "text/plain",
            ["content-length"] = #"Hello, HTTP/2!",
        })
        stream:closewrite("Hello, HTTP/2!")
    end
}
```

**HTTP/2 Advantages**:
- **Multiplexing**: Single connection can handle multiple concurrent requests, reducing connection overhead
- **Header Compression**: HPACK algorithm compresses request headers, saving bandwidth
- **Server Push**: Proactively push resources to clients (Silly supports)
- **Binary Protocol**: More efficient parsing and transmission

**Note**: HTTP/2 requires HTTPS (TLS) support; pure HTTP/2 (h2c) is generally not recommended.

### Keep-Alive Connections

HTTP/1.1 enables Keep-Alive by default, but Silly's HTTP client currently does not support connection pooling; each request creates a new connection.

**Connection Lifecycle**:
- Server side automatically handles connection reuse (persistent connections from the same client)
- Client creates a new connection for each request, closing it after completion

**Client Request Example**:

```lua
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    -- Each request creates a new connection
    for i = 1, 100 do
        local response = http.get("http://api.example.com/data/" .. i)
        if response then
            print("Request", i, "completed")
        end
    end
end)
```

Note: Although connection pooling is not supported, HTTP/2's multiplexing feature can handle multiple requests concurrently on a single connection.

### Response Compression (gzip)

For text content (JSON, HTML, CSS), enabling gzip compression can significantly reduce transfer size.

**Implement gzip Compression**:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local zlib = require "silly.compress.zlib"

local function should_compress(content_type)
    -- Only compress text types
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

        local response_body = string.rep("Hello, World! ", 1000) -- Simulate large response
        local content_type = "text/plain"

        if supports_gzip and should_compress(content_type) then
            -- Compress response
            local compressed = gzip_compress(response_body)

            stream:respond(200, {
                ["content-type"] = content_type,
                ["content-encoding"] = "gzip",
                ["content-length"] = #compressed,
                ["vary"] = "Accept-Encoding",
            })
            stream:closewrite(compressed)
        else
            -- Uncompressed response
            stream:respond(200, {
                ["content-type"] = content_type,
                ["content-length"] = #response_body,
            })
            stream:closewrite(response_body)
        end
    end
}
```

**Compression Recommendations**:
- Only compress responses larger than 1KB (small responses have overhead from compression)
- Don't compress already compressed content (images, videos, etc.)
- Use `vary: Accept-Encoding` header for cache support
- Consider compression level tradeoffs (CPU vs bandwidth)

### Streaming Responses

For large files or real-time generated content, use streaming responses to avoid excessive memory usage.

**HTTP/1.1 Streaming Response (Chunked Transfer)**:

```lua
local silly = require "silly"
local http = require "silly.net.http"

http.listen {
    addr = ":8080",
    handler = function(stream)
        if stream.version == "HTTP/1.1" then
            -- Use chunked transfer encoding
            stream:respond(200, {
                ["content-type"] = "text/plain",
                ["transfer-encoding"] = "chunked",
            })

            -- Send data in chunks
            for i = 1, 10 do
                stream:write("Chunk " .. i .. "\n")
                silly.sleep(100) -- Simulate real-time generation
            end

            stream:closewrite() -- Send termination marker
        else
            -- HTTP/2 doesn't support write(), use close() to send all at once
            local data = {}
            for i = 1, 10 do
                data[#data + 1] = "Chunk " .. i .. "\n"
            end

            local response_body = table.concat(data)
            stream:respond(200, {
                ["content-type"] = "text/plain",
                ["content-length"] = #response_body,
            })
            stream:closewrite(response_body)
        end
    end
}
```

**Note**:
- HTTP/2 stream does not support `write()` method, need to use `close(body)` to send all at once
- Streaming responses are suitable for large file downloads, log output, Server-Sent Events (SSE), etc.

### Concurrent Request Optimization

Use coroutines to concurrently handle multiple HTTP requests, fully utilizing Silly's async I/O capabilities.

**Concurrent Request Example**:

```lua
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local waitgroup = require "silly.sync.waitgroup"

task.fork(function()
    local wg = waitgroup.new()
    local results = {}

    -- Initiate 10 concurrent requests
    for i = 1, 10 do
        wg:fork(function()
            local response = http.get("http://api.example.com/data/" .. i)
            if response then
                results[i] = response.body
            end
        end)
    end

    wg:wait() -- Wait for all requests to complete
    print("All requests completed, results:", #results)
end)
```

**Concurrent Server-Side Request Handling**:

Silly's handler function executes in independent coroutines, automatically implementing concurrent processing:

```lua
http.listen {
    addr = ":8080",
    handler = function(stream)
        -- Each request is processed in an independent coroutine
        -- Can safely call blocking operations (like database queries)

        local data = query_database() -- Async operation

        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #data,
        })
        stream:closewrite(data)
    end
}
```

---

## Security Practices

### CORS Configuration

Cross-Origin Resource Sharing (CORS) allows browsers to access APIs cross-domain; properly configuring CORS headers is a basic requirement for web APIs.

**Complete CORS Middleware**:

```lua
local silly = require "silly"
local http = require "silly.net.http"

-- CORS configuration
local CORS_CONFIG = {
    origins = {"https://example.com", "https://app.example.com"},
    methods = {"GET", "POST", "PUT", "DELETE", "OPTIONS"},
    headers = {"Content-Type", "Authorization", "X-Requested-With"},
    max_age = 86400, -- Preflight request cache time (seconds)
    allow_credentials = true,
}

local function check_origin(origin)
    if not origin then return false end

    -- Check if in whitelist
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

        -- Handle OPTIONS preflight requests
        if stream.method == "OPTIONS" then
            if check_origin(origin) then
                local headers = add_cors_headers(stream, origin)
                headers["content-length"] = "0"
                stream:respond(204, headers)
                stream:closewrite()
            else
                stream:respond(403, {["content-length"] = "0"})
                stream:closewrite()
            end
            return
        end

        -- Handle actual requests
        local response_body = '{"status":"ok"}'
        local headers = {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        }

        -- Add CORS headers
        if check_origin(origin) then
            local cors_headers = add_cors_headers(stream, origin)
            for k, v in pairs(cors_headers) do
                headers[k] = v
            end
        end

        stream:respond(200, headers)
        stream:closewrite(response_body)
    end
}
```

**CORS Security Recommendations**:
- Don't use `*` wildcard (unless it's a public API)
- Maintain a clear domain whitelist
- Avoid reflecting the `Origin` header (easily bypassed)
- Production environments should only allow HTTPS origins

### Rate Limiting

Rate limiting prevents API abuse and protects server resources.

**IP-based Simple Rate Limiting**:

```lua
local silly = require "silly"
local http = require "silly.net.http"

-- Rate limit configuration: maximum 100 requests per minute
local RATE_LIMIT = 100
local WINDOW_SIZE = 60 -- seconds

-- Store request count for each IP
local request_counts = {}

local function check_rate_limit(ip)
    local now = os.time()

    if not request_counts[ip] then
        request_counts[ip] = {count = 0, window_start = now}
    end

    local record = request_counts[ip]

    -- Check if window needs to be reset
    if now - record.window_start >= WINDOW_SIZE then
        record.count = 0
        record.window_start = now
    end

    -- Check if limit exceeded
    if record.count >= RATE_LIMIT then
        return false, RATE_LIMIT - record.count
    end

    -- Increment count
    record.count = record.count + 1
    return true, RATE_LIMIT - record.count
end

-- Clean up expired records (execute periodically)
time.after(300000, function() -- Every 5 minutes
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
            -- Return 429 Too Many Requests
            local error_body = '{"error":"Rate limit exceeded"}'
            stream:respond(429, {
                ["content-type"] = "application/json",
                ["content-length"] = #error_body,
                ["retry-after"] = tostring(WINDOW_SIZE),
                ["x-ratelimit-limit"] = tostring(RATE_LIMIT),
                ["x-ratelimit-remaining"] = "0",
            })
            stream:closewrite(error_body)
            return
        end

        -- Normal request handling
        local response_body = '{"status":"ok"}'
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
            ["x-ratelimit-limit"] = tostring(RATE_LIMIT),
            ["x-ratelimit-remaining"] = tostring(remaining),
        })
        stream:closewrite(response_body)
    end
}
```

**Advanced Rate Limiting Solutions**:
- **Token Bucket Algorithm**: Smoother rate limiting effect
- **User-based Rate Limiting**: Different quotas for different users
- **Distributed Rate Limiting**: Use Redis for multi-node rate limiting
- **Dynamic Adjustment**: Dynamically adjust limits based on server load

### Request Size Limits

Limit request body size to prevent malicious large file uploads from exhausting server resources.

**Check Content-Length Header**:

```lua
local silly = require "silly"
local http = require "silly.net.http"

local MAX_BODY_SIZE = 10 * 1024 * 1024 -- 10MB

http.listen {
    addr = ":8080",
    handler = function(stream)
        -- Check Content-Length
        local content_length = tonumber(stream.header["content-length"] or 0)

        if content_length > MAX_BODY_SIZE then
            local error_body = '{"error":"Payload too large"}'
            stream:respond(413, { -- 413 Payload Too Large
                ["content-type"] = "application/json",
                ["content-length"] = #error_body,
            })
            stream:closewrite(error_body)
            return
        end

        -- Read request body
        if stream.method == "POST" or stream.method == "PUT" then
            local body, err = stream:readall()
            if not body then
                stream:respond(400, {})
                stream:closewrite("Bad Request")
                return
            end

            -- Process request body
            print("Received body size:", #body)
        end

        stream:respond(200, {})
        stream:closewrite("OK")
    end
}
```

**Note**:
- Always validate the `content-length` header
- Consider setting reasonable timeout values
- For file uploads, use streaming processing instead of loading all at once into memory

### Timeout Settings

Set reasonable timeouts to avoid slow attacks and resource leaks.

**Use Coroutine Timeout Protection**:

```lua
local silly = require "silly"
local http = require "silly.net.http"

local REQUEST_TIMEOUT = 30000 -- 30 seconds

local function with_timeout(timeout_ms, func)
    local channel = require("silly.sync.channel").new(1)
    local timer_id

    -- Start task coroutine
    task.fork(function()
        local ok, result = pcall(func)
        channel:push({success = ok, result = result, completed = true})
    end)

    -- Start timeout timer
    timer_id = time.after(timeout_ms, function()
        channel:push({success = false, result = "timeout", completed = false})
    end)

    -- Wait for result
    local result = channel:pop()

    if result.completed then
        time.cancel(timer_id) -- Cancel timer
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
                -- Handle request (possibly slow)
                local body = stream:readall()

                -- Simulate slow operation
                time.sleep(1000)

                stream:respond(200, {})
                stream:closewrite("OK")
            end)
        end)

        if not ok then
            if err == "timeout" then
                stream:respond(408, {}) -- 408 Request Timeout
                stream:closewrite("Request Timeout")
            else
                stream:respond(500, {})
                stream:closewrite("Internal Server Error")
            end
        end
    end
}
```

---

## Error Handling

### Unified Error Response Format

Define a unified error response format for easy client parsing and handling.

**Standard Error Response Format**:

```lua
local json = require "silly.encoding.json"

-- Error response format
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

-- Send error response
local function send_error(stream, status, code, message, details)
    local error_body = json.encode(error_response(code, message, details))

    stream:respond(status, {
        ["content-type"] = "application/json; charset=utf-8",
        ["content-length"] = #error_body,
        ["cache-control"] = "no-store",
    })
    stream:closewrite(error_body)
end

-- Usage example
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

        -- Normal processing
        local response_body = json.encode({status = "success", data = data})
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:closewrite(response_body)
    end
}
```

**Error Response Example**:

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

### Error Code Design

Design a clear error code system for easy problem identification and handling.

**Error Code Definition**:

```lua
-- Error code constants
local ErrorCodes = {
    -- Client errors (400-499)
    INVALID_REQUEST = {status = 400, code = "INVALID_REQUEST", message = "Invalid request"},
    UNAUTHORIZED = {status = 401, code = "UNAUTHORIZED", message = "Authentication required"},
    FORBIDDEN = {status = 403, code = "FORBIDDEN", message = "Access denied"},
    NOT_FOUND = {status = 404, code = "NOT_FOUND", message = "Resource not found"},
    METHOD_NOT_ALLOWED = {status = 405, code = "METHOD_NOT_ALLOWED", message = "Method not allowed"},
    VALIDATION_ERROR = {status = 400, code = "VALIDATION_ERROR", message = "Validation failed"},
    RATE_LIMIT_EXCEEDED = {status = 429, code = "RATE_LIMIT_EXCEEDED", message = "Too many requests"},

    -- Server errors (500-599)
    INTERNAL_ERROR = {status = 500, code = "INTERNAL_ERROR", message = "Internal server error"},
    SERVICE_UNAVAILABLE = {status = 503, code = "SERVICE_UNAVAILABLE", message = "Service unavailable"},
    DATABASE_ERROR = {status = 500, code = "DATABASE_ERROR", message = "Database error"},
}

-- Convenience function
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
    stream:closewrite(error_body)
end

-- Usage example
http.listen {
    addr = ":8080",
    handler = function(stream)
        local user = authenticate(stream.header["authorization"])
        if not user then
            send_error_code(stream, ErrorCodes.UNAUTHORIZED)
            return
        end

        -- Normal processing
    end
}
```

### Exception Catching

Use `pcall` to catch exceptions, avoiding service crashes from individual request errors.

**Global Exception Handler**:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
local trace = require "silly.trace"
local json = require "silly.encoding.json"

-- Global error handler
local function safe_handler(handler)
    return function(stream)
        local ok, err = pcall(function()
            handler(stream)
        end)

        if not ok then
            -- Log error
            logger.error("Request handler error:", err,
                "\nMethod:", stream.method,
                "\nPath:", stream.path,
                "\nRemote:", stream.remoteaddr)

            -- Send 500 error (if not already responded)
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
                stream:closewrite(error_body)
            end)
        end
    end
end

-- Business handler
local function my_handler(stream)
    -- Code that may throw exceptions
    local data = query_database() -- May fail

    local response_body = json.encode(data)
    stream:respond(200, {
        ["content-type"] = "application/json",
        ["content-length"] = #response_body,
    })
    stream:closewrite(response_body)
end

-- Use safe wrapper
http.listen {
    addr = ":8080",
    handler = safe_handler(my_handler)
}
```

---

## Routing Design

### RESTful API Design

Follow RESTful principles to design clear and consistent APIs.

**RESTful Resource Example**:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- Mock data storage
local users = {
    {id = 1, name = "Alice", email = "alice@example.com"},
    {id = 2, name = "Bob", email = "bob@example.com"},
}
local next_id = 3

-- Route table
local routes = {
    -- GET /api/users - Get all users
    {method = "GET", pattern = "^/api/users$", handler = function(stream, matches)
        local response_body = json.encode(users)
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:closewrite(response_body)
    end},

    -- GET /api/users/:id - Get single user
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
            stream:closewrite(response_body)
        else
            send_error(stream, 404, "NOT_FOUND", "User not found")
        end
    end},

    -- POST /api/users - Create user
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
        stream:closewrite(response_body)
    end},

    -- PUT /api/users/:id - Update user
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
                stream:closewrite(response_body)
                return
            end
        end

        send_error(stream, 404, "NOT_FOUND", "User not found")
    end},

    -- DELETE /api/users/:id - Delete user
    {method = "DELETE", pattern = "^/api/users/(%d+)$", handler = function(stream, matches)
        local user_id = tonumber(matches[1])

        for i, user in ipairs(users) do
            if user.id == user_id then
                table.remove(users, i)
                stream:respond(204, {}) -- 204 No Content
                stream:closewrite()
                return
            end
        end

        send_error(stream, 404, "NOT_FOUND", "User not found")
    end},
}

-- Route matching
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

**RESTful Design Principles**:
- Use nouns for resources: `/users` not `/getUsers`
- Use HTTP methods for operations: GET (query), POST (create), PUT (update), DELETE (delete)
- Use hierarchy for relationships: `/users/1/posts/2`
- Use query parameters for filtering: `/users?status=active&limit=10`
- Use correct status codes: 200 (success), 201 (created), 204 (no content), 404 (not found)

### Route Table Organization

Organize route definitions into modular structures for improved maintainability.

**Modular Route Example**:

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
    stream:closewrite(response_body)
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
        stream:closewrite(response_body)
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
    stream:closewrite(response_body)
end

return UserRoutes
```

```lua
-- main.lua
local silly = require "silly"
local http = require "silly.net.http"
local UserRoutes = require "routes.users"
local ProductRoutes = require "routes.products"

-- Route definitions
local routes = {
    {method = "GET", pattern = "^/api/users$", handler = UserRoutes.list},
    {method = "GET", pattern = "^/api/users/(%d+)$", handler = UserRoutes.get},
    {method = "POST", pattern = "^/api/users$", handler = UserRoutes.create},

    {method = "GET", pattern = "^/api/products$", handler = ProductRoutes.list},
    {method = "GET", pattern = "^/api/products/(%d+)$", handler = ProductRoutes.get},
}

-- Start server
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

### Middleware Pattern

Implement a middleware system for cross-cutting concerns (logging, authentication, CORS, etc.).

**Middleware Implementation**:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
local trace = require "silly.trace"

-- Middleware chain
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

-- Logging middleware
local function logging_middleware(stream, next)
    local start = os.clock()

    logger.info("Request:", stream.method, stream.path, "from", stream.remoteaddr)

    next() -- Continue processing

    local duration = os.clock() - start
    logger.info("Response:", stream.method, stream.path,
        "completed in", string.format("%.3fms", duration * 1000))
end

-- Authentication middleware
local function auth_middleware(stream, next)
    local token = stream.header["authorization"]

    if not token or not validate_token(token) then
        send_error(stream, 401, "UNAUTHORIZED", "Invalid or missing token")
        return -- Don't call next(), interrupt chain
    end

    -- Attach user info to stream
    stream.user = extract_user_from_token(token)

    next() -- Continue processing
end

-- CORS middleware
local function cors_middleware(stream, next)
    local origin = stream.header["origin"]

    -- Handle OPTIONS preflight requests
    if stream.method == "OPTIONS" then
        stream:respond(204, {
            ["access-control-allow-origin"] = origin or "*",
            ["access-control-allow-methods"] = "GET, POST, PUT, DELETE",
            ["access-control-allow-headers"] = "Content-Type, Authorization",
            ["content-length"] = "0",
        })
        stream:closewrite()
        return
    end

    -- Add CORS headers for actual requests (need to modify response)
    -- Note: Simplified here, actually need to add headers when responding
    stream.cors_origin = origin

    next()
end

-- Business handler
local function my_handler(stream)
    local response_body = '{"status":"ok"}'
    stream:respond(200, {
        ["content-type"] = "application/json",
        ["content-length"] = #response_body,
        ["access-control-allow-origin"] = stream.cors_origin or "*",
    })
    stream:closewrite(response_body)
end

-- Combine middlewares
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

## Monitoring and Logging

### Access Logs

Record detailed information for each request for audit and troubleshooting.

**Structured Access Logs**:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
local trace = require "silly.trace"
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

        -- Handle request
        local response_body = '{"status":"ok"}'
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:closewrite(response_body)

        -- Log access
        local duration = os.clock() - start
        access_log(stream, 200, duration, #response_body)
    end
}
```

**Log Output Example**:

```
[INFO] ACCESS {"timestamp":"2025-10-14T10:30:45","method":"GET","path":"/api/users","query":{},"status":200,"duration_ms":"1.234","response_size":123,"remote_addr":"127.0.0.1:54321","user_agent":"curl/7.68.0","referer":"","protocol":"HTTP/1.1"}
```

### Performance Metrics

Use Prometheus metrics to monitor service performance.

**Integrate Prometheus Monitoring**:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local prometheus = require "silly.metrics.prometheus"

-- Define metrics
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

        -- Record request size
        local request_size = tonumber(stream.header["content-length"] or 0)
        http_request_size_bytes:observe(request_size)

        -- Metrics endpoint
        if stream.path == "/metrics" then
            local metrics = prometheus.gather()
            stream:respond(200, {
                ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
                ["content-length"] = #metrics,
            })
            stream:closewrite(metrics)
            http_requests_in_flight:dec()
            return
        end

        -- Business processing
        local response_body = '{"status":"ok"}'
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:closewrite(response_body)

        -- Record metrics
        local duration = os.clock() - start
        http_request_duration_seconds:labels(stream.method, stream.path):observe(duration)
        http_response_size_bytes:observe(#response_body)
        http_requests_total:labels(stream.method, stream.path, "200"):inc()
        http_requests_in_flight:dec()
    end
}
```

**Configure Prometheus Scraping**:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'silly_http_server'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: '/metrics'
    scrape_interval: 15s
```

### Request Tracing

Use Trace ID to track request flow through the system.

**Implement Request Tracing**:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
local trace = require "silly.trace"

http.listen {
    addr = ":8080",
    handler = function(stream)
        -- Get or generate Trace ID from request header
        local trace_id = tonumber(stream.header["x-trace-id"])
        if trace_id then
            trace.attach(trace_id)
        else
            trace.spawn()
            trace_id = trace.propagate()  -- For returning to client
        end

        logger.info("Request started:", stream.method, stream.path)

        -- Handle request
        local ok, err = pcall(function()
            -- Business logic
            logger.debug("Processing request")

            -- Simulate calling other services
            local service_response = call_external_service()

            logger.debug("External service responded")

            local response_body = '{"status":"ok"}'
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #response_body,
                ["x-trace-id"] = tostring(trace_id), -- Return Trace ID
            })
            stream:closewrite(response_body)
        end)

        if not ok then
            logger.error("Request failed:", err)
            stream:respond(500, {["x-trace-id"] = tostring(trace_id)})
            stream:closewrite("Internal Server Error")
        end

        logger.info("Request completed")
    end
}

-- Automatically pass current Trace ID when calling external services
function call_external_service()
    local trace_id = trace.propagate()
    local response = http.get("http://other-service/api", {
        ["x-trace-id"] = tostring(trace_id),
    })
    return response
end
```

**Log Output Example**:

```
[INFO] [a1b2c3d4e5f60718] Request started: GET /api/users
[DEBUG] [a1b2c3d4e5f60718] Processing request
[DEBUG] [a1b2c3d4e5f60718] External service responded
[INFO] [a1b2c3d4e5f60718] Request completed
```

---

## Deployment Recommendations

### Reverse Proxy (Nginx)

Use Nginx as a reverse proxy to provide SSL termination, load balancing, static file serving, etc.

**Nginx Configuration Example**:

```nginx
upstream silly_backend {
    # Load balancing configuration
    least_conn; # Least connections algorithm

    server 127.0.0.1:8080 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8081 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8082 max_fails=3 fail_timeout=30s;

    # Health check (requires nginx-plus or tengine)
    # check interval=3000 rise=2 fall=3 timeout=1000;
}

# HTTP server (redirect to HTTPS)
server {
    listen 80;
    server_name api.example.com;

    # Redirect to HTTPS
    return 301 https://$server_name$request_uri;
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name api.example.com;

    # SSL certificate
    ssl_certificate /etc/nginx/ssl/api.example.com.crt;
    ssl_certificate_key /etc/nginx/ssl/api.example.com.key;

    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Client request body size limit
    client_max_body_size 10M;

    # Timeout settings
    proxy_connect_timeout 10s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;

    # Static files
    location /static/ {
        alias /var/www/static/;
        expires 7d;
        add_header Cache-Control "public, immutable";
    }

    # API proxy
    location /api/ {
        proxy_pass http://silly_backend;

        # Pass client information
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Disable buffering (for streaming responses)
        proxy_buffering off;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Metrics endpoint (restrict access)
    location /metrics {
        allow 10.0.0.0/8; # Only allow internal network access
        deny all;

        proxy_pass http://silly_backend;
        proxy_set_header Host $host;
    }

    # Health check endpoint
    location /health {
        proxy_pass http://silly_backend;
        access_log off; # Don't log health checks
    }
}
```

**Read Real IP in Silly**:

```lua
http.listen {
    addr = ":8080",
    handler = function(stream)
        -- Get real IP from Nginx passed headers
        local real_ip = stream.header["x-real-ip"] or
                       stream.header["x-forwarded-for"] or
                       stream.remoteaddr

        print("Client IP:", real_ip)

        -- Handle request
    end
}
```

### Load Balancing

Use multi-process or multi-instance deployment for load balancing, fully utilizing multi-core CPUs.

**Multi-Process Deployment Script**:

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

**Read Port Configuration in Silly**:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local env = require "silly.env"

local port = tonumber(env.get("port")) or 8080

http.listen {
    addr = "0.0.0.0:" .. port,
    handler = function(stream)
        -- Handle request
    end
}

print("Server started on port", port)
```

**Run Servers**:

```bash
./silly main.lua --port=8080
./silly main.lua --port=8081
./silly main.lua --port=8082
./silly main.lua --port=8083
```

### Health Checks

Implement health check endpoints for load balancer to monitor service status.

**Health Check Endpoint**:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- Health status
local health_status = {
    healthy = true,
    last_check = os.time(),
    checks = {},
}

-- Check database connection
local function check_database()
    local ok, err = pcall(function()
        -- Execute simple query
        query_database("SELECT 1")
    end)
    return ok, ok and "ok" or err
end

-- Check cache connection
local function check_cache()
    local ok, err = pcall(function()
        -- Ping cache
        cache_ping()
    end)
    return ok, ok and "ok" or err
end

-- Perform all health checks
local function perform_health_check()
    health_status.checks.database = {check_database()}
    health_status.checks.cache = {check_cache()}
    health_status.last_check = os.time()

    -- Determine overall health status
    health_status.healthy = health_status.checks.database[1] and
                           health_status.checks.cache[1]
end

-- Periodic health check
silly.timeout(10000, function() -- Every 10 seconds
    perform_health_check()
end)

http.listen {
    addr = ":8080",
    handler = function(stream)
        if stream.path == "/health" then
            -- Simple health check (fast response)
            if health_status.healthy then
                stream:respond(200, {})
                stream:closewrite("OK")
            else
                stream:respond(503, {})
                stream:closewrite("Unhealthy")
            end
        elseif stream.path == "/health/detailed" then
            -- Detailed health check (includes dependency status)
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
            stream:closewrite(response_body)
        else
            -- Other requests
        end
    end
}
```

**Kubernetes Health Check Configuration**:

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

## Complete Example: Production-Grade HTTP Service

Below is a complete example integrating all best practices:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"
local logger = require "silly.logger"
local trace = require "silly.trace"
local prometheus = require "silly.metrics.prometheus"

-- Configuration
local CONFIG = {
    port = tonumber(os.getenv("PORT")) or 8080,
    max_body_size = 10 * 1024 * 1024, -- 10MB
    request_timeout = 30000, -- 30 seconds
    rate_limit = 100, -- 100 requests per minute
}

-- Error code definitions
local ErrorCodes = {
    VALIDATION_ERROR = {status = 400, code = "VALIDATION_ERROR", message = "Validation failed"},
    UNAUTHORIZED = {status = 401, code = "UNAUTHORIZED", message = "Authentication required"},
    RATE_LIMIT_EXCEEDED = {status = 429, code = "RATE_LIMIT_EXCEEDED", message = "Too many requests"},
    INTERNAL_ERROR = {status = 500, code = "INTERNAL_ERROR", message = "Internal server error"},
}

-- Prometheus metrics
local metrics = {
    requests = prometheus.counter("http_requests_total", "Total requests",
        {"method", "path", "status"}),
    duration = prometheus.histogram("http_request_duration_seconds", "Request duration",
        {"method", "path"}, {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0}),
    in_flight = prometheus.gauge("http_requests_in_flight", "Requests in flight"),
}

-- Rate limiting
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

-- Error response
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
    stream:closewrite(error_body)
end

-- Middleware: logging
local function logging_middleware(stream, next)
    -- Set or create trace ID
    local trace_id = tonumber(stream.header["x-trace-id"])
    if trace_id then
        trace.attach(trace_id)
    else
        trace.spawn()
    end

    logger.info("Request:", stream.method, stream.path, "from", stream.remoteaddr)

    next()
end

-- Middleware: rate limiting
local function rate_limit_middleware(stream, next)
    local ip = stream.remoteaddr:match("^([^:]+)")

    if not check_rate_limit(ip) then
        send_error(stream, ErrorCodes.RATE_LIMIT_EXCEEDED)
        return
    end

    next()
end

-- Middleware: request size check
local function body_size_middleware(stream, next)
    local content_length = tonumber(stream.header["content-length"] or 0)

    if content_length > CONFIG.max_body_size then
        stream:respond(413, {})
        stream:closewrite("Payload Too Large")
        return
    end

    next()
end

-- Business routes
local routes = {
    {method = "GET", pattern = "^/api/users$", handler = function(stream)
        local users = {{id = 1, name = "Alice"}, {id = 2, name = "Bob"}}
        local response_body = json.encode(users)
        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:closewrite(response_body)
    end},

    {method = "GET", pattern = "^/health$", handler = function(stream)
        stream:respond(200, {})
        stream:closewrite("OK")
    end},

    {method = "GET", pattern = "^/metrics$", handler = function(stream)
        local metrics_data = prometheus.gather()
        stream:respond(200, {
            ["content-type"] = "text/plain; version=0.0.4",
            ["content-length"] = #metrics_data,
        })
        stream:closewrite(metrics_data)
    end},
}

-- Route matching
local function match_route(method, path)
    for _, route in ipairs(routes) do
        if route.method == method and path:match(route.pattern) then
            return route.handler
        end
    end
    return nil
end

-- Main handler
local function main_handler(stream)
    local start = os.clock()
    metrics.in_flight:inc()

    local handler = match_route(stream.method, stream.path)

    if handler then
        local ok, err = pcall(handler, stream)
        if not ok then
            logger.error("Handler error:", err)
            send_error(stream, ErrorCodes.INTERNAL_ERROR)
        end
    else
        stream:respond(404, {})
        stream:closewrite("Not Found")
    end

    local duration = os.clock() - start
    metrics.duration:labels(stream.method, stream.path):observe(duration)
    metrics.requests:labels(stream.method, stream.path, "200"):inc()
    metrics.in_flight:dec()
end

-- Middleware chain
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

-- Start server
local handler = chain({
    logging_middleware,
    rate_limit_middleware,
    body_size_middleware,
}, main_handler)

http.listen {
    addr = "0.0.0.0:" .. CONFIG.port,
    handler = handler
}

logger.info("HTTP server started on port", CONFIG.port)
```

---

## Summary

This guide covers the key best practices for building production-grade HTTP services:

1. **Performance Optimization**: HTTP/2, connection reuse, response compression, streaming, concurrent processing
2. **Security Practices**: CORS configuration, rate limiting, request size limits, timeout settings
3. **Error Handling**: Unified error format, error code design, exception catching
4. **Routing Design**: RESTful API, modular routes, middleware pattern
5. **Monitoring and Logging**: Access logs, Prometheus metrics, request tracing
6. **Deployment Recommendations**: Nginx reverse proxy, load balancing, health checks

Following these practices will help you build high-performance, secure, and maintainable HTTP services.

## References

- [silly.net.http API Reference](../reference/net/http.md)
- [HTTP Server Tutorial](../tutorials/http-server.md)
- [silly.metrics.prometheus](../reference/metrics/prometheus.md)
- [silly.logger](../reference/logger.md)
- [Nginx Official Documentation](https://nginx.org/en/docs/)
- [HTTP/2 Specification (RFC 7540)](https://datatracker.ietf.org/doc/html/rfc7540)
