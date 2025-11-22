---
title: silly.net.http
icon: globe
category:
  - API Reference
tag:
  - Network
  - HTTP
  - Web Services
---

# silly.net.http

The `silly.net.http` module provides server-side and client-side implementation for HTTP/1.1 and HTTP/2 protocols. Built on coroutines, it offers a clean asynchronous API that automatically handles protocol details (such as chunked transfer, persistent connections, protocol negotiation, etc.).

## Module Import

```lua validate
local http = require "silly.net.http"
```

## Core Concepts

### Protocol Support

- **HTTP/1.1**: Supports persistent connections, chunked transfer, pipelining
  - Note: HTTP/1.1 currently does not support client connection pooling; each request creates a new connection
- **HTTP/2**: Supports multiplexing, server push, header compression
- **Automatic Protocol Negotiation**: Automatically selects protocol version via ALPN

### Stream Object

The HTTP module uses stream objects to represent HTTP connections:
- **Server-side**: Handler function receives a stream object to process requests
- **Client-side**: Request function returns a stream object for reading/writing

---

## Server-side API

### http.listen(conf)

Creates an HTTP server and starts listening.

- **Parameters**:
  - `conf`: `table` - Server configuration table
    - `addr`: `string` (required) - Listen address, e.g., `"127.0.0.1:8080"` or `":8080"`
    - `handler`: `function` (required) - Request handler function `function(stream)`
    - `certs`: `table[]|nil` (optional) - TLS certificate configuration (for HTTPS)
      - `cert`: `string` - PEM format certificate
      - `key`: `string` - PEM format private key
    - `backlog`: `integer|nil` (optional) - Listen queue size
- **Returns**:
  - Success: `server` - Server object
  - Failure: `nil, string` - nil and error message
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    local server, err = http.listen {
        addr = "127.0.0.1:8080",
        handler = function(stream)
            -- Handle request
            stream:respond(200, {
                ["content-type"] = "text/plain",
                ["content-length"] = #"Hello, World!",
            })
            stream:closewrite("Hello, World!")
        end
    }

    if not server then
        print("Server start failed:", err)
        return
    end

    print("HTTP server listening on 127.0.0.1:8080")
end)
```

### server:close()

Closes the HTTP server.

- **Parameters**: None
- **Returns**: None
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    local server = http.listen {
        addr = ":8080",
        handler = function(stream)
            stream:respond(200, {})
            stream:closewrite("OK")
        end
    }

    -- Close server later
    server:close()
    print("Server closed")
end)
```

---

## Server-side Stream API

The `stream` object received by the handler function provides the following properties and methods:

### stream Properties

- `stream.method`: `string` - HTTP method (GET, POST, PUT, etc.)
- `stream.path`: `string` - Request path
- `stream.query`: `table` - Query parameters table
- `stream.header`: `table` - Request headers table (lowercase keys)
- `stream.version`: `string` - Protocol version ("HTTP/1.1" or "HTTP/2")
- `stream.remoteaddr`: `string` - Client address

### stream:respond(status, headers [, close])

Sends response status line and headers.

- **Parameters**:
  - `status`: `integer` - HTTP status code (200, 404, 500, etc.)
  - `headers`: `table` - Response headers table
  - `close`: `boolean|nil` (optional) - Whether to immediately close the connection (without sending response body)
- **Returns**:
  - Success: `true`
  - Failure: `false, string` - false and error message
- **Example**:

```lua validate
local http = require "silly.net.http"

-- Assuming inside a handler
local function handler(stream)
    stream:respond(200, {
        ["content-type"] = "application/json",
        ["content-length"] = #'{"status":"ok"}',
    })
    stream:closewrite('{"status":"ok"}')
end
```

### stream:closewrite([body])

Sends response body and closes the connection.

- **Parameters**:
  - `body`: `string|nil` (optional) - Response body content
- **Returns**: None
- **Note**: After calling this method, the stream will no longer be usable
- **Example**:

```lua validate
local http = require "silly.net.http"

-- Assuming inside a handler
local function handler(stream)
    stream:respond(200, {
        ["content-type"] = "text/html",
        ["content-length"] = #"<h1>Hello</h1>",
    })
    stream:closewrite("<h1>Hello</h1>")
end
```

### stream:readall()

Reads the complete request body (asynchronous).

- **Parameters**: None
- **Returns**:
  - Success: `string` - Request body content
  - Failure: `nil, string` - nil and error message
- **Asynchronous**: Suspends the coroutine until the entire request body is read
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    http.listen {
        addr = ":8080",
        handler = function(stream)
            if stream.method == "POST" then
                local body, err = stream:readall()
                if body then
                    print("Received POST data:", body)
                    stream:respond(200, {
                        ["content-type"] = "text/plain",
                        ["content-length"] = #"Received",
                    })
                    stream:closewrite("Received")
                else
                    stream:respond(500, {})
                    stream:closewrite("Read error: " .. (err or "unknown"))
                end
            else
                stream:respond(200, {})
                stream:closewrite("OK")
            end
        end
    }
end)
```

### stream:write(data)

Writes data to the response stream (HTTP/1.1 only).

- **Parameters**:
  - `data`: `string` - Data to write
- **Returns**:
  - Success: `true`
  - Failure: `false, string` - false and error message
- **Note**: HTTP/2 streams do not support this method; use `close(body)` instead
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    http.listen {
        addr = ":8080",
        handler = function(stream)
            if stream.version == "HTTP/1.1" then
                stream:respond(200, {
                    ["content-type"] = "text/plain",
                    ["transfer-encoding"] = "chunked",
                })
                stream:write("Chunk 1\n")
                stream:write("Chunk 2\n")
                stream:closewrite()
            end
        end
    }
end)
```

---

## Client-side API

### http.get(url [, headers])

Sends an HTTP GET request (asynchronous).

- **Parameters**:
  - `url`: `string` - Request URL (complete URL including protocol and host)
  - `headers`: `table|nil` (optional) - Request headers table
- **Returns**:
  - Success: `table` - Response object containing:
    - `status`: `integer` - HTTP status code
    - `header`: `table` - Response headers table
    - `body`: `string` - Response body
  - Failure: `nil, string` - nil and error message
- **Asynchronous**: Suspends the coroutine until the complete response is received
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    local response, err = http.get("http://www.example.com")
    if response then
        print("Status:", response.status)
        print("Body length:", #response.body)
        print("Content-Type:", response.header["content-type"])
    else
        print("GET failed:", err)
    end
end)
```

### http.post(url [, headers [, body]])

Sends an HTTP POST request (asynchronous).

- **Parameters**:
  - `url`: `string` - Request URL
  - `headers`: `table|nil` (optional) - Request headers table
  - `body`: `string|nil` (optional) - Request body content
- **Returns**:
  - Success: `table` - Response object (same as GET)
  - Failure: `nil, string` - nil and error message
- **Note**: If `body` is provided, the `content-length` header is automatically set
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

task.fork(function()
    local request_data = json.encode({
        name = "Alice",
        age = 30
    })

    local response, err = http.post(
        "http://api.example.com/users",
        {
            ["content-type"] = "application/json",
        },
        request_data
    )

    if response then
        print("Status:", response.status)
        print("Response:", response.body)
    else
        print("POST failed:", err)
    end
end)
```

### http.request(method, url [, headers [, close [, alpn_protos]]])

Sends a custom HTTP request (asynchronous).

- **Parameters**:
  - `method`: `string` - HTTP method (GET, POST, PUT, DELETE, etc.)
  - `url`: `string` - Request URL
  - `headers`: `table|nil` (optional) - Request headers table
  - `close`: `boolean|nil` (optional) - Whether to immediately close the connection
  - `alpn_protos`: `string[]|nil` (optional) - ALPN protocol list
- **Returns**:
  - Success: `stream` - HTTP stream object
  - Failure: `nil, string` - nil and error message
- **Note**: The returned stream needs to be manually closed by calling `close()`
- **Example**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    local stream<close>, err = http.request(
        "PUT",
        "http://api.example.com/data",
        {
            ["content-type"] = "text/plain",
            ["content-length"] = #"Updated data",
        },
        false,
        {"http/1.1", "h2"}
    )

    if not stream then
        print("Request failed:", err)
        return
    end

    if stream.version == "HTTP/2" then
        stream:closewrite("Updated data")
    else
        stream:write("Updated data")
    end

    local status, header = stream:readheader()
    if status then
        print("Status:", status)
    end
end)
```

---

## Usage Examples

### Example 1: Basic HTTP Server

A simple HTTP server that returns different content based on path:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    local server = http.listen {
        addr = "127.0.0.1:8080",
        handler = function(stream)
            local path = stream.path
            local response_body

            if path == "/" then
                response_body = "Welcome to the home page!"
            elseif path == "/about" then
                response_body = "This is the about page."
            else
                stream:respond(404, {
                    ["content-type"] = "text/plain",
                    ["content-length"] = #"Not Found",
                })
                stream:closewrite("Not Found")
                return
            end

            stream:respond(200, {
                ["content-type"] = "text/plain",
                ["content-length"] = #response_body,
            })
            stream:closewrite(response_body)
        end
    }

    print("Server listening on 127.0.0.1:8080")
end)
```

### Example 2: JSON API Server

A RESTful API server that handles JSON requests and responses:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

task.fork(function()
    local users = {
        {id = 1, name = "Alice", age = 30},
        {id = 2, name = "Bob", age = 25},
    }

    local server = http.listen {
        addr = ":8080",
        handler = function(stream)
            if stream.method == "GET" and stream.path == "/api/users" then
                -- Return user list
                local response_body = json.encode(users)
                stream:respond(200, {
                    ["content-type"] = "application/json",
                    ["content-length"] = #response_body,
                })
                stream:closewrite(response_body)

            elseif stream.method == "POST" and stream.path == "/api/users" then
                -- Create new user
                local body, err = stream:readall()
                if not body then
                    stream:respond(400, {})
                    stream:closewrite("Bad Request")
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
                    stream:closewrite("Invalid user data")
                end

            else
                stream:respond(404, {})
                stream:closewrite("Not Found")
            end
        end
    }

    print("JSON API server running on port 8080")
end)
```

### Example 3: Query Parameter Processing

Parsing and using URL query parameters:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    local server = http.listen {
        addr = ":8080",
        handler = function(stream)
            local name = stream.query["name"] or "Guest"
            local count = tonumber(stream.query["count"]) or 1

            local response_body = string.format(
                "Hello, %s! Count: %d",
                name,
                count
            )

            stream:respond(200, {
                ["content-type"] = "text/plain",
                ["content-length"] = #response_body,
            })
            stream:closewrite(response_body)
        end
    }

    print("Server listening on port 8080")
    print("Try: http://localhost:8080?name=Alice&count=5")
end)
```

### Example 4: HTTPS Server

Creating an HTTPS server with TLS certificates:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
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

    local server = http.listen {
        addr = "127.0.0.1:8443",
        certs = {
            {
                cert = cert_pem,
                key = key_pem,
            }
        },
        handler = function(stream)
            stream:respond(200, {
                ["content-type"] = "text/plain",
                ["content-length"] = #"Hello, HTTPS!",
            })
            stream:closewrite("Hello, HTTPS!")
        end
    }

    print("HTTPS server listening on 127.0.0.1:8443")
end)
```

### Example 5: HTTP Client Requests

Using the HTTP client API to send various requests:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

task.fork(function()
    -- GET request
    local response, err = http.get("http://www.example.com")
    if response then
        print("GET Status:", response.status)
        print("Body length:", #response.body)
    end

    -- GET request with headers
    local response2, err = http.get("http://api.example.com/data", {
        ["user-agent"] = "Silly HTTP Client",
        ["accept"] = "application/json",
    })

    -- POST request
    local post_data = json.encode({action = "create", value = 42})
    local response3, err = http.post(
        "http://api.example.com/action",
        {["content-type"] = "application/json"},
        post_data
    )

    if response3 then
        print("POST Status:", response3.status)
        local result = json.decode(response3.body)
        print("Result:", result.message or "N/A")
    end
end)
```

### Example 6: File Upload Server

An HTTP server that handles file uploads:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    local server = http.listen {
        addr = ":8080",
        handler = function(stream)
            if stream.method == "POST" and stream.path == "/upload" then
                local content_type = stream.header["content-type"] or ""

                if content_type:find("multipart/form-data", 1, true) then
                    -- Read uploaded file content
                    local body, err = stream:readall()
                    if body then
                        print("Received upload, size:", #body)

                        -- In a real application, multipart data should be parsed
                        -- and the file saved here

                        stream:respond(200, {
                            ["content-type"] = "text/plain",
                            ["content-length"] = #"Upload successful",
                        })
                        stream:closewrite("Upload successful")
                    else
                        stream:respond(500, {})
                        stream:closewrite("Upload failed")
                    end
                else
                    stream:respond(400, {})
                    stream:closewrite("Invalid content type")
                end
            else
                stream:respond(404, {})
                stream:closewrite("Not Found")
            end
        end
    }

    print("File upload server running on port 8080")
end)
```

---

## Important Notes

### 1. Coroutine Requirement

All HTTP APIs (server and client) must be called within a coroutine:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

-- Wrong: Cannot call in main thread
-- local response = http.get("http://example.com")  -- Will fail

-- Correct: Call within a coroutine
task.fork(function()
    local response = http.get("http://example.com")
    -- ...
end)
```

### 2. Content-Length Header

When sending responses, the correct `content-length` header should be set:

```lua validate
local http = require "silly.net.http"

-- Assuming inside a handler
local function handler(stream)
    local body = "Response body"

    -- Correct: Set content-length
    stream:respond(200, {
        ["content-type"] = "text/plain",
        ["content-length"] = #body,
    })
    stream:closewrite(body)
end
```

### 3. HTTP/2 vs HTTP/1.1

HTTP/2 and HTTP/1.1 have slightly different usage:

```lua validate
local http = require "silly.net.http"

-- Assuming inside a handler
local function handler(stream)
    stream:respond(200, {["content-type"] = "text/plain"})

    if stream.version == "HTTP/2" then
        -- HTTP/2: Use close to send body
        stream:closewrite("Hello, HTTP/2!")
    else
        -- HTTP/1.1: Can use write or close
        stream:write("Hello, ")
        stream:write("HTTP/1.1!")
        stream:closewrite()
    end
end
```

### 4. Header Key Names

Request and response header keys are all lowercase:

```lua validate
local http = require "silly.net.http"

-- Assuming inside a handler
local function handler(stream)
    -- Correct: Use lowercase keys
    local content_type = stream.header["content-type"]
    local user_agent = stream.header["user-agent"]

    -- Wrong: Uppercase keys may not be found
    -- local ct = stream.header["Content-Type"]  -- May be nil
end
```

### 5. Query Parameter Types

Query parameters are always strings and need manual conversion:

```lua validate
local http = require "silly.net.http"

-- Assuming inside a handler
local function handler(stream)
    -- stream.query["page"] is the string "5"
    local page = tonumber(stream.query["page"]) or 1

    -- stream.query["debug"] is the string "true"
    local debug = stream.query["debug"] == "true"
end
```

### 6. Error Handling

Always check return values and handle possible errors:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"

task.fork(function()
    local response, err = http.get("http://example.com")
    if not response then
        print("Request failed:", err)
        return
    end

    if response.status ~= 200 then
        print("HTTP error:", response.status)
        return
    end

    -- Handle successful response
    print("Body:", response.body)
end)
```

---

## Performance Recommendations

### 1. Connection Reuse

Both HTTP/1.1 and HTTP/2 support connection reuse, avoiding frequent connection creation:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local task = require "silly.task"

task.fork(function()
    -- HTTP module will automatically reuse connections (for the same host)
    for i = 1, 10 do
        local response = http.get("http://example.com/api/data?id=" .. i)
        if response then
            print("Request", i, "status:", response.status)
        end
    end
end)
```

### 2. Concurrent Requests

Use coroutines to implement concurrent HTTP requests:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local urls = {
        "http://api1.example.com/data",
        "http://api2.example.com/info",
        "http://api3.example.com/status",
    }

    for i, url in ipairs(urls) do
        wg:fork(function()
            local response = http.get(url)
            if response then
                print("URL", i, "status:", response.status)
            end
        end)
    end

    wg:wait()
    print("All requests completed")
end)
```

### 3. Streaming Processing

For large files, consider using streaming processing instead of reading all at once:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local task = require "silly.task"

task.fork(function()
    http.listen {
        addr = ":8080",
        handler = function(stream)
            if stream.method == "POST" then
                -- For large files, chunked reading and processing can be used
                -- Note: Current version of readall() reads everything at once
                -- Consider future versions providing chunked read API

                local body = stream:readall()
                -- Process body...

                stream:respond(200, {})
                stream:closewrite("OK")
            end
        end
    }
end)
```

---

## See Also

- [silly](../silly.md) - Core module
- [silly.net.tcp](./tcp.md) - TCP protocol
- [silly.net.tls](./tls.md) - TLS/SSL encryption
- [silly.encoding.json](../encoding/json.md) - JSON encoding/decoding
- [silly.sync.waitgroup](../sync/waitgroup.md) - Coroutine wait group
