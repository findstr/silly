---
title: silly.net.http
icon: globe
category:
  - API参考
tag:
  - 网络
  - HTTP
  - Web服务
---

# silly.net.http

`silly.net.http` 模块提供了 HTTP/1.1 和 HTTP/2 协议的服务器端和客户端实现。它基于协程构建，提供简洁的异步 API，自动处理协议细节（如分块传输、持久连接、协议协商等）。

## 模块导入

```lua validate
local http = require "silly.net.http"
```

## 核心概念

### 协议支持

- **HTTP/1.1**: 支持持久连接、分块传输、管道化
  - 注意：HTTP/1.1 当前不支持客户端连接池，每次请求会创建新连接
- **HTTP/2**: 支持多路复用、服务器推送、头部压缩
- **自动协议协商**: 通过 ALPN 自动选择协议版本

### Stream 对象

HTTP 模块使用 stream 对象表示 HTTP 连接：
- **服务器端**: handler 函数接收 stream 对象处理请求
- **客户端**: request 函数返回 stream 对象用于读写

---

## 服务器端 API

### http.listen(conf)

创建 HTTP 服务器并开始监听。

- **参数**:
  - `conf`: `table` - 服务器配置表
    - `addr`: `string` (必需) - 监听地址，例如 `"127.0.0.1:8080"` 或 `":8080"`
    - `handler`: `function` (必需) - 请求处理函数 `function(stream)`
    - `certs`: `table[]|nil` (可选) - TLS 证书配置（用于 HTTPS）
      - `cert`: `string` - PEM 格式证书
      - `key`: `string` - PEM 格式私钥
    - `backlog`: `integer|nil` (可选) - 监听队列大小
- **返回值**:
  - 成功: `server` - 服务器对象
  - 失败: `nil, string` - nil 和错误信息
- **示例**:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
    local server, err = http.listen {
        addr = "127.0.0.1:8080",
        handler = function(stream)
            -- 处理请求
            stream:respond(200, {
                ["content-type"] = "text/plain",
                ["content-length"] = #"Hello, World!",
            })
            stream:close("Hello, World!")
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

关闭 HTTP 服务器。

- **参数**: 无
- **返回值**: 无
- **示例**:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
    local server = http.listen {
        addr = ":8080",
        handler = function(stream)
            stream:respond(200, {})
            stream:close("OK")
        end
    }

    -- 稍后关闭服务器
    server:close()
    print("Server closed")
end)
```

---

## 服务器端 Stream API

处理器函数接收的 `stream` 对象提供以下属性和方法：

### stream 属性

- `stream.method`: `string` - HTTP 方法（GET, POST, PUT 等）
- `stream.path`: `string` - 请求路径
- `stream.query`: `table` - 查询参数表
- `stream.header`: `table` - 请求头表（小写键名）
- `stream.version`: `string` - 协议版本（"HTTP/1.1" 或 "HTTP/2"）
- `stream.remoteaddr`: `string` - 客户端地址

### stream:respond(status, headers [, close])

发送响应状态行和头部。

- **参数**:
  - `status`: `integer` - HTTP 状态码（200, 404, 500 等）
  - `headers`: `table` - 响应头表
  - `close`: `boolean|nil` (可选) - 是否立即关闭连接（不发送响应体）
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息
- **示例**:

```lua validate
local http = require "silly.net.http"

-- 假设在 handler 中
local function handler(stream)
    stream:respond(200, {
        ["content-type"] = "application/json",
        ["content-length"] = #'{"status":"ok"}',
    })
    stream:close('{"status":"ok"}')
end
```

### stream:close([body])

发送响应体并关闭连接。

- **参数**:
  - `body`: `string|nil` (可选) - 响应体内容
- **返回值**: 无
- **注意**: 调用此方法后，stream 将不可再使用
- **示例**:

```lua validate
local http = require "silly.net.http"

-- 假设在 handler 中
local function handler(stream)
    stream:respond(200, {
        ["content-type"] = "text/html",
        ["content-length"] = #"<h1>Hello</h1>",
    })
    stream:close("<h1>Hello</h1>")
end
```

### stream:readall()

读取完整的请求体（异步）。

- **参数**: 无
- **返回值**:
  - 成功: `string` - 请求体内容
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 会挂起协程直到读取完整个请求体
- **示例**:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
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
                    stream:close("Received")
                else
                    stream:respond(500, {})
                    stream:close("Read error: " .. (err or "unknown"))
                end
            else
                stream:respond(200, {})
                stream:close("OK")
            end
        end
    }
end)
```

### stream:write(data)

向响应流写入数据（仅 HTTP/1.1）。

- **参数**:
  - `data`: `string` - 要写入的数据
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息
- **注意**: HTTP/2 stream 不支持此方法，使用 `close(body)` 代替
- **示例**:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
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
                stream:close()
            end
        end
    }
end)
```

---

## 客户端 API

### http.GET(url [, headers])

发送 HTTP GET 请求（异步）。

- **参数**:
  - `url`: `string` - 请求 URL（完整 URL，包含协议和主机）
  - `headers`: `table|nil` (可选) - 请求头表
- **返回值**:
  - 成功: `table` - 响应对象，包含：
    - `status`: `integer` - HTTP 状态码
    - `header`: `table` - 响应头表
    - `body`: `string` - 响应体
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 会挂起协程直到收到完整响应
- **示例**:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
    local response, err = http.GET("http://www.example.com")
    if response then
        print("Status:", response.status)
        print("Body length:", #response.body)
        print("Content-Type:", response.header["content-type"])
    else
        print("GET failed:", err)
    end
end)
```

### http.POST(url [, headers [, body]])

发送 HTTP POST 请求（异步）。

- **参数**:
  - `url`: `string` - 请求 URL
  - `headers`: `table|nil` (可选) - 请求头表
  - `body`: `string|nil` (可选) - 请求体内容
- **返回值**:
  - 成功: `table` - 响应对象（同 GET）
  - 失败: `nil, string` - nil 和错误信息
- **注意**: 如果提供 `body`，会自动设置 `content-length` 头
- **示例**:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

silly.fork(function()
    local request_data = json.encode({
        name = "Alice",
        age = 30
    })

    local response, err = http.POST(
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

发送自定义 HTTP 请求（异步）。

- **参数**:
  - `method`: `string` - HTTP 方法（GET, POST, PUT, DELETE 等）
  - `url`: `string` - 请求 URL
  - `headers`: `table|nil` (可选) - 请求头表
  - `close`: `boolean|nil` (可选) - 是否立即关闭连接
  - `alpn_protos`: `string[]|nil` (可选) - ALPN 协议列表
- **返回值**:
  - 成功: `stream` - HTTP stream 对象
  - 失败: `nil, string` - nil 和错误信息
- **注意**: 返回的 stream 需要手动调用 `close()`
- **示例**:

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
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
        stream:close("Updated data")
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

## 使用示例

### 示例1：基础 HTTP 服务器

简单的 HTTP 服务器，根据路径返回不同内容：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
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
                stream:close("Not Found")
                return
            end

            stream:respond(200, {
                ["content-type"] = "text/plain",
                ["content-length"] = #response_body,
            })
            stream:close(response_body)
        end
    }

    print("Server listening on 127.0.0.1:8080")
end)
```

### 示例2：JSON API 服务器

处理 JSON 请求和响应的 RESTful API 服务器：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

silly.fork(function()
    local users = {
        {id = 1, name = "Alice", age = 30},
        {id = 2, name = "Bob", age = 25},
    }

    local server = http.listen {
        addr = ":8080",
        handler = function(stream)
            if stream.method == "GET" and stream.path == "/api/users" then
                -- 返回用户列表
                local response_body = json.encode(users)
                stream:respond(200, {
                    ["content-type"] = "application/json",
                    ["content-length"] = #response_body,
                })
                stream:close(response_body)

            elseif stream.method == "POST" and stream.path == "/api/users" then
                -- 创建新用户
                local body, err = stream:readall()
                if not body then
                    stream:respond(400, {})
                    stream:close("Bad Request")
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
                    stream:close("Invalid user data")
                end

            else
                stream:respond(404, {})
                stream:close("Not Found")
            end
        end
    }

    print("JSON API server running on port 8080")
end)
```

### 示例3：查询参数处理

解析和使用 URL 查询参数：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
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
            stream:close(response_body)
        end
    }

    print("Server listening on port 8080")
    print("Try: http://localhost:8080?name=Alice&count=5")
end)
```

### 示例4：HTTPS 服务器

使用 TLS 证书创建 HTTPS 服务器：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

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
            stream:close("Hello, HTTPS!")
        end
    }

    print("HTTPS server listening on 127.0.0.1:8443")
end)
```

### 示例5：HTTP 客户端请求

使用 HTTP 客户端API 发送各种请求：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

silly.fork(function()
    -- GET 请求
    local response, err = http.GET("http://www.example.com")
    if response then
        print("GET Status:", response.status)
        print("Body length:", #response.body)
    end

    -- 带请求头的 GET 请求
    local response2, err = http.GET("http://api.example.com/data", {
        ["user-agent"] = "Silly HTTP Client",
        ["accept"] = "application/json",
    })

    -- POST 请求
    local post_data = json.encode({action = "create", value = 42})
    local response3, err = http.POST(
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

### 示例6：文件上传服务器

处理文件上传的 HTTP 服务器：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
    local server = http.listen {
        addr = ":8080",
        handler = function(stream)
            if stream.method == "POST" and stream.path == "/upload" then
                local content_type = stream.header["content-type"] or ""

                if content_type:find("multipart/form-data", 1, true) then
                    -- 读取上传的文件内容
                    local body, err = stream:readall()
                    if body then
                        print("Received upload, size:", #body)

                        -- 在实际应用中，这里应该解析 multipart 数据
                        -- 并保存文件

                        stream:respond(200, {
                            ["content-type"] = "text/plain",
                            ["content-length"] = #"Upload successful",
                        })
                        stream:close("Upload successful")
                    else
                        stream:respond(500, {})
                        stream:close("Upload failed")
                    end
                else
                    stream:respond(400, {})
                    stream:close("Invalid content type")
                end
            else
                stream:respond(404, {})
                stream:close("Not Found")
            end
        end
    }

    print("File upload server running on port 8080")
end)
```

---

## 注意事项

### 1. 协程要求

所有 HTTP API（服务器和客户端）必须在协程中调用：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

-- 错误：不能在主线程调用
-- local response = http.GET("http://example.com")  -- 会失败

-- 正确：在协程中调用
silly.fork(function()
    local response = http.GET("http://example.com")
    -- ...
end)
```

### 2. Content-Length 头部

发送响应时应该设置正确的 `content-length` 头部：

```lua validate
local http = require "silly.net.http"

-- 假设在 handler 中
local function handler(stream)
    local body = "Response body"

    -- 正确：设置 content-length
    stream:respond(200, {
        ["content-type"] = "text/plain",
        ["content-length"] = #body,
    })
    stream:close(body)
end
```

### 3. HTTP/2 vs HTTP/1.1

HTTP/2 和 HTTP/1.1 在使用上略有不同：

```lua validate
local http = require "silly.net.http"

-- 假设在 handler 中
local function handler(stream)
    stream:respond(200, {["content-type"] = "text/plain"})

    if stream.version == "HTTP/2" then
        -- HTTP/2: 使用 close 发送body
        stream:close("Hello, HTTP/2!")
    else
        -- HTTP/1.1: 可以使用 write 或 close
        stream:write("Hello, ")
        stream:write("HTTP/1.1!")
        stream:close()
    end
end
```

### 4. 请求头键名

请求头和响应头的键名都是小写的：

```lua validate
local http = require "silly.net.http"

-- 假设在 handler 中
local function handler(stream)
    -- 正确：使用小写键名
    local content_type = stream.header["content-type"]
    local user_agent = stream.header["user-agent"]

    -- 错误：大写键名可能找不到
    -- local ct = stream.header["Content-Type"]  -- 可能为 nil
end
```

### 5. 查询参数类型

查询参数总是字符串类型，需要手动转换：

```lua validate
local http = require "silly.net.http"

-- 假设在 handler 中
local function handler(stream)
    -- stream.query["page"] 是字符串 "5"
    local page = tonumber(stream.query["page"]) or 1

    -- stream.query["debug"] 是字符串 "true"
    local debug = stream.query["debug"] == "true"
end
```

### 6. 错误处理

始终检查返回值，处理可能的错误：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
    local response, err = http.GET("http://example.com")
    if not response then
        print("Request failed:", err)
        return
    end

    if response.status ~= 200 then
        print("HTTP error:", response.status)
        return
    end

    -- 处理成功响应
    print("Body:", response.body)
end)
```

---

## 性能建议

### 1. 连接复用

HTTP/1.1 和 HTTP/2 都支持连接复用，避免频繁创建连接：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
    -- HTTP 模块会自动复用连接（针对同一主机）
    for i = 1, 10 do
        local response = http.GET("http://example.com/api/data?id=" .. i)
        if response then
            print("Request", i, "status:", response.status)
        end
    end
end)
```

### 2. 并发请求

使用协程实现并发 HTTP 请求：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local waitgroup = require "silly.sync.waitgroup"

silly.fork(function()
    local wg = waitgroup.new()
    local urls = {
        "http://api1.example.com/data",
        "http://api2.example.com/info",
        "http://api3.example.com/status",
    }

    for i, url in ipairs(urls) do
        wg:fork(function()
            local response = http.GET(url)
            if response then
                print("URL", i, "status:", response.status)
            end
        end)
    end

    wg:wait()
    print("All requests completed")
end)
```

### 3. 流式处理

对于大文件，考虑使用流式处理而不是一次性读取：

```lua validate
local silly = require "silly"
local http = require "silly.net.http"

silly.fork(function()
    http.listen {
        addr = ":8080",
        handler = function(stream)
            if stream.method == "POST" then
                -- 对于大文件，可以分块读取和处理
                -- 注意：当前版本的 readall() 会一次性读取全部
                -- 考虑未来版本提供分块读取 API

                local body = stream:readall()
                -- 处理 body...

                stream:respond(200, {})
                stream:close("OK")
            end
        end
    }
end)
```

---

## 参见

- [silly](../silly.md) - 核心调度器
- [silly.net.tcp](./tcp.md) - TCP 协议
- [silly.net.tls](./tls.md) - TLS/SSL 加密
- [silly.encoding.json](../encoding/json.md) - JSON 编解码
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
