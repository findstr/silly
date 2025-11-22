---
title: HTTP Server Tutorial
icon: server
order: 3
category:
  - Tutorials
tag:
  - HTTP
  - Web Services
  - RESTful API
  - Routing
---

# HTTP Server Tutorial

This tutorial will guide you from scratch to build a fully-functional HTTP server, learning HTTP protocol basics, route handling, and JSON API development.

## Learning Objectives

Through this tutorial, you will learn:

- Core concepts of HTTP protocol (request/response, status codes, headers)
- Using the `silly.net.http` module to create HTTP servers
- Implementing a routing system to handle different URL paths
- Building RESTful JSON APIs
- Serving static files
- Handling GET/POST requests and query parameters

## HTTP Basics

### HTTP Request/Response Model

HTTP (Hypertext Transfer Protocol) is a request-response protocol:

1. **Client sends request**: Contains method (GET, POST, etc.), path, headers, request body
2. **Server returns response**: Contains status code (200, 404, etc.), headers, response body

### Common HTTP Methods

- `GET`: Retrieve a resource (should not modify server state)
- `POST`: Create a new resource
- `PUT`: Update an existing resource
- `DELETE`: Delete a resource

### Common HTTP Status Codes

- `200 OK`: Request successful
- `201 Created`: Resource created successfully
- `400 Bad Request`: Client request error
- `404 Not Found`: Resource does not exist
- `500 Internal Server Error`: Server internal error

### HTTP Headers

Headers are key-value pairs providing metadata about requests or responses:

- `content-type`: Content type (text/html, application/json, etc.)
- `content-length`: Content length (in bytes)
- `user-agent`: Client information
- `accept`: Content types accepted by client

## Implementation Steps

### Step 1: Basic HTTP Server

Let's start with the simplest HTTP server that returns "Hello, World!" to all requests:

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
        stream:closewrite(response_body)
    end
}

print("HTTP server listening on http://127.0.0.1:8080")
```

**Code Explanation**:

1. `http.listen` creates HTTP server and listens on address
2. `handler` function handles each HTTP request
3. `stream:respond(status, headers)` sends status code and response headers
4. `stream:closewrite(body)` sends response body and closes connection

**Testing the Server**:

```bash
# Run server
./silly http_server.lua

# Test in another terminal
curl http://127.0.0.1:8080
```

### Step 2: Route Handling

Real web services need to return different content based on different paths:

```lua
local silly = require "silly"
local http = require "silly.net.http"

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        local path = stream.path
        local response_body
        local status = 200

        -- Route matching
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
        stream:closewrite(response_body)
    end
}

print("HTTP server with routing listening on http://127.0.0.1:8080")
```

**Key Concepts**:

- `stream.path`: Gets the requested URL path
- Uses `if-elseif-else` to implement simple routing
- Unmatched paths return 404 status code

**Testing Routes**:

```bash
curl http://127.0.0.1:8080/          # Welcome to the home page!
curl http://127.0.0.1:8080/about     # This is the about page.
curl http://127.0.0.1:8080/unknown   # 404 Not Found: /unknown
```

### Step 3: JSON API

Modern web applications typically use JSON format for data exchange. Let's build a RESTful API:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- Mock database
local users = {
    {id = 1, name = "Alice", age = 30},
    {id = 2, name = "Bob", age = 25},
}

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        local method = stream.method
        local path = stream.path

        -- GET /api/users - Get all users
        if method == "GET" and path == "/api/users" then
            local response_body = json.encode(users)
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #response_body,
            })
            stream:closewrite(response_body)

        -- POST /api/users - Create new user
        elseif method == "POST" and path == "/api/users" then
            local body, err = stream:readall()
            if not body then
                stream:respond(400, {})
                stream:closewrite("Bad Request: Cannot read body")
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
                stream:closewrite(response_body)
            else
                stream:respond(400, {})
                stream:closewrite("Bad Request: Invalid user data")
            end

        -- GET /api/users?name=Alice - Query parameters
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
            stream:closewrite(response_body)

        else
            stream:respond(404, {})
            stream:closewrite("Not Found")
        end
    end
}

print("JSON API server listening on http://127.0.0.1:8080")
```

**Key Concepts**:

- `stream.method`: HTTP method (GET, POST, etc.)
- `stream:readall()`: Reads complete request body (async operation)
- `json.encode/decode`: JSON serialization and deserialization
- `stream.query`: Query parameters table (e.g., `?name=Alice`)
- Status code 201: Resource created successfully

**Testing JSON API**:

```bash
# Get all users
curl http://127.0.0.1:8080/api/users

# Create new user
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Charlie","age":35}'

# Query users
curl "http://127.0.0.1:8080/api/users?name=Alice"
```

### Step 4: Static File Service

Web servers typically need to serve static files (HTML, CSS, images, etc.):

```lua
local silly = require "silly"
local http = require "silly.net.http"

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        local path = stream.path

        -- Root path returns HTML page
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
            stream:closewrite(html)

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
            stream:closewrite(html)

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
            stream:closewrite(body)

        else
            stream:respond(404, {
                ["content-type"] = "text/html",
            })
            stream:closewrite("<h1>404 Not Found</h1>")
        end
    end
}

print("Static file server listening on http://127.0.0.1:8080")
```

**Key Concepts**:

- Set correct `content-type`: HTML uses `text/html`, JSON uses `application/json`
- Add `charset=utf-8` to ensure proper Chinese display
- Use multiline strings `[[...]]` to store HTML content

**Testing Static File Service**:

```bash
# Access homepage
curl http://127.0.0.1:8080/

# Access About page
curl http://127.0.0.1:8080/about

# Access API status
curl http://127.0.0.1:8080/api/status
```

## Complete Code

Below is a comprehensive example including all features:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- Mock user data
local users = {
    {id = 1, name = "Alice", age = 30, email = "alice@example.com"},
    {id = 2, name = "Bob", age = 25, email = "bob@example.com"},
}

-- Route handler function
local function handle_request(stream)
    local method = stream.method
    local path = stream.path

    -- Log request
    print(string.format("[%s] %s %s", os.date("%Y-%m-%d %H:%M:%S"), method, path))

    -- Homepage - HTML
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
        stream:closewrite(html)
        return
    end

    -- About page
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
        stream:closewrite(html)
        return
    end

    -- API: Get all users
    if method == "GET" and path == "/api/users" then
        -- Check for query parameters
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
        stream:closewrite(response_body)
        return
    end

    -- API: Create new user
    if method == "POST" and path == "/api/users" then
        local body, err = stream:readall()
        if not body then
            stream:respond(400, {
                ["content-type"] = "application/json",
            })
            stream:closewrite(json.encode({error = "Cannot read request body"}))
            return
        end

        local user = json.decode(body)
        if not user or not user.name or not user.age then
            stream:respond(400, {
                ["content-type"] = "application/json",
            })
            stream:closewrite(json.encode({error = "Invalid user data. Required fields: name, age"}))
            return
        end

        -- Create new user
        user.id = #users + 1
        user.email = user.email or (user.name:lower() .. "@example.com")
        table.insert(users, user)

        local response_body = json.encode(user)
        stream:respond(201, {
            ["content-type"] = "application/json",
            ["content-length"] = #response_body,
        })
        stream:closewrite(response_body)
        return
    end

    -- API: Server status
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
        stream:closewrite(response_body)
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
    stream:closewrite(response_body)
end

-- Start HTTP server
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

-- Optional: Start a client test
local task = require "silly.task"
task.fork(function()
    local response, err = http.get("http://127.0.0.1:8080/api/status")
    if response then
        print("Self-test successful! Server status:", response.body)
    else
        print("Self-test failed:", err)
    end
end)
```

## Running and Testing

### Start the Server

Save the complete code above to `my_http_server.lua`, then run:

```bash
./silly my_http_server.lua
```

You should see output like:

```
===========================================
  Silly HTTP Server Started
===========================================
  Listening on: http://127.0.0.1:8080
  Press Ctrl+C to stop
===========================================
```

### Testing the API

Test various endpoints in another terminal:

```bash
# 1. Access homepage
curl http://127.0.0.1:8080/

# 2. Get all users
curl http://127.0.0.1:8080/api/users

# 3. Create new user
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Charlie","age":35,"email":"charlie@example.com"}'

# 4. Query users by name
curl "http://127.0.0.1:8080/api/users?name=Alice"

# 5. Get server status
curl http://127.0.0.1:8080/api/status

# 6. Test 404
curl http://127.0.0.1:8080/nonexistent

# 7. Access About page
curl http://127.0.0.1:8080/about
```

### Testing with Browser

You can also open http://127.0.0.1:8080 in a browser to see a friendly HTML page, and click links to browse different pages and APIs.

## Code Analysis

### Core Components

1. **Routing System**: Uses `method + path` combination to match different processing logic
2. **Async Reading**: `stream:readall()` asynchronously reads POST request body
3. **JSON Processing**: Uses `json.encode/decode` to handle JSON data
4. **Query Parameters**: Access URL query parameters via `stream.query`
5. **Error Handling**: Check input validity, return appropriate status codes

### Stream Object Properties

- `stream.method`: HTTP method (GET, POST, PUT, etc.)
- `stream.path`: Request path (excluding query string)
- `stream.query`: Query parameters table (key-value pairs)
- `stream.header`: Request headers table (keys in lowercase)
- `stream.version`: Protocol version ("HTTP/1.1" or "HTTP/2")
- `stream.remoteaddr`: Client address

### Response Methods

- `stream:respond(status, headers)`: Send status code and response headers
- `stream:closewrite(body)`: Send response body and close connection
- `stream:readall()`: Read complete request body (async)

### Best Practices

1. **Always Set Content-Length**: Avoids chunked transfer overhead
2. **Check Return Values**: `readall()` can fail, need to check errors
3. **Use Correct Status Codes**: 200 (success), 201 (created), 400 (bad request), 404 (not found)
4. **Set Correct Content-Type**: JSON uses `application/json`, HTML uses `text/html`
5. **Log Requests**: Facilitates debugging and monitoring

## Extension Exercises

Try these exercises to deepen understanding:

### Exercise 1: Update and Delete Users

Implement `PUT /api/users/:id` and `DELETE /api/users/:id` endpoints:

```lua
-- Hint: Need to parse ID from path
-- Example: /api/users/1 -> id = 1
local id = path:match("^/api/users/(%d+)$")
if id then
    id = tonumber(id)
    -- Execute update or delete based on method
end
```

### Exercise 2: Middleware System

Implement a simple middleware system for logging and authentication:

```lua
-- Middleware function
local function auth_middleware(stream)
    local token = stream.header["authorization"]
    if not token or token ~= "Bearer secret-token" then
        return false, "Unauthorized"
    end
    return true
end

-- Use in handler
local ok, err = auth_middleware(stream)
if not ok then
    stream:respond(401, {})
    stream:closewrite(err)
    return
end
```

### Exercise 3: Request Body Size Limit

Add request body size checking to prevent malicious large file uploads:

```lua
local content_length = tonumber(stream.header["content-length"])
if content_length and content_length > 1024 * 1024 then  -- 1MB limit
    stream:respond(413, {})  -- Payload Too Large
    stream:closewrite("Request body too large")
    return
end
```

### Exercise 4: CORS Support

Add Cross-Origin Resource Sharing (CORS) support to allow browser cross-domain API access:

```lua
-- Add CORS headers to all responses
local function cors_headers()
    return {
        ["access-control-allow-origin"] = "*",
        ["access-control-allow-methods"] = "GET, POST, PUT, DELETE, OPTIONS",
        ["access-control-allow-headers"] = "Content-Type, Authorization",
    }
end

-- Handle OPTIONS preflight request
if method == "OPTIONS" then
    local headers = cors_headers()
    headers["content-length"] = 0
    stream:respond(204, headers)
    stream:closewrite()
    return
end
```

### Exercise 5: Performance Benchmarking

Use `wrk` or `ab` tools to test server performance:

```bash
# Install wrk (Ubuntu/Debian)
sudo apt-get install wrk

# Benchmark test
wrk -t4 -c100 -d30s http://127.0.0.1:8080/api/status
```

Observe Silly framework's high-performance behavior!

## Next Steps

Congratulations on completing the HTTP Server tutorial! You have mastered building web applications basics. Next you can learn:

- **Database Integration**: Connect MySQL, PostgreSQL, or Redis (see [Database Application Tutorial](./database-app.md))
- **WebSocket**: Implement real-time communication (see [silly.net.websocket](../reference/net/websocket.md))
- **HTTPS/TLS**: Add encryption support (see [silly.net.tls](../reference/net/tls.md))
- **gRPC**: Build high-performance RPC services (see [silly.net.grpc](../reference/net/grpc.md))
- **Cluster Deployment**: Multi-node architecture (see [silly.net.cluster](../reference/net/cluster.md))

## References

- [silly.net.http API Reference](../reference/net/http.md)
- [silly.encoding.json API Reference](../reference/encoding/json.md)
- [HTTP/1.1 Specification (RFC 7230)](https://datatracker.ietf.org/doc/html/rfc7230)
- [RESTful API Design Guide](https://restfulapi.net/)
