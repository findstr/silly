---
title: silly.net.grpc
icon: network-wired
category:
  - API参考
tag:
  - 网络
  - gRPC
  - RPC
  - Protocol Buffers
---

# silly.net.grpc

`silly.net.grpc` 模块提供了 gRPC 协议的服务器端和客户端实现。它基于 HTTP/2 传输层，支持标准的 Protocol Buffers 序列化，实现了 Unary RPC 和 Streaming RPC 调用模式。框架自动处理连接管理、请求路由、错误处理等细节，让开发者专注于业务逻辑。

## 模块导入

```lua validate
local grpc = require "silly.net.grpc"
```

## 核心概念

### gRPC 协议

gRPC 是 Google 开源的高性能 RPC 框架，基于 HTTP/2 和 Protocol Buffers：
- **HTTP/2 传输**: 利用多路复用、头部压缩等特性提升性能
- **Protocol Buffers**: 高效的二进制序列化格式
- **强类型接口**: 通过 .proto 文件定义清晰的服务契约
- **流式支持**: 支持客户端流、服务器流、双向流

### RPC 调用模式

框架支持四种 gRPC 调用模式：

1. **Unary RPC**: 单请求单响应（最常用）
2. **Server Streaming RPC**: 单请求多响应流
3. **Client Streaming RPC**: 多请求流单响应
4. **Bidirectional Streaming RPC**: 双向流式通信

### Protocol Buffers

使用 protoc 模块定义和加载服务接口：

```lua validate
local protoc = require "protoc"

local p = protoc:new()
p:load([[
syntax = "proto3";

package mypackage;

message Request {
    string name = 1;
    int32 value = 2;
}

message Response {
    string result = 1;
}

service MyService {
    rpc MyMethod (Request) returns (Response) {}
}
]], "myservice.proto")
```

### 状态码

gRPC 使用标准的状态码表示操作结果，定义在 `silly.net.grpc.code` 模块：

- `code.OK` (0): 成功
- `code.Canceled` (1): 操作被取消
- `code.Unknown` (2): 未知错误
- `code.InvalidArgument` (3): 无效参数
- `code.DeadlineExceeded` (4): 超时
- `code.NotFound` (5): 资源未找到
- `code.AlreadyExists` (6): 资源已存在
- `code.PermissionDenied` (7): 权限不足
- `code.ResourceExhausted` (8): 资源耗尽
- `code.Unauthenticated` (16): 未认证

---

## 服务器端 API

### registrar.new()

创建一个新的 gRPC 服务注册器。

- **参数**: 无
- **返回值**: `registrar` - 服务注册器对象
- **示例**:

```lua validate
local registrar = require "silly.net.grpc.registrar"

local reg = registrar.new()
```

### registrar:register(proto, service)

向注册器注册服务实现。

- **参数**:
  - `proto`: `table` - protoc 加载的 proto 定义（包含 package 和 service 信息）
  - `service`: `table` - 服务实现表，键为方法名，值为处理函数
- **返回值**: 无
- **注意**: 处理函数签名为 `function(request) -> response`
- **示例**:

```lua validate
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

local p = protoc:new()
p:load([[
syntax = "proto3";
package hello;

message HelloRequest {
    string name = 1;
}

message HelloResponse {
    string message = 1;
}

service Greeter {
    rpc SayHello (HelloRequest) returns (HelloResponse) {}
}
]], "hello.proto")

local reg = registrar.new()
reg:register(p.loaded["hello.proto"], {
    SayHello = function(request)
        return {
            message = "Hello, " .. request.name
        }
    end
})
```

### grpc.listen(conf)

创建 gRPC 服务器并开始监听。

- **参数**:
  - `conf`: `table` - 服务器配置表
    - `addr`: `string` (必需) - 监听地址，例如 `"127.0.0.1:50051"`
    - `registrar`: `registrar` (必需) - 服务注册器对象
    - `tls`: `boolean|nil` (可选) - 是否启用 TLS，默认 false
    - `certs`: `table[]|nil` (可选) - TLS 证书配置（tls=true 时必需）
      - `cert`: `string` - PEM 格式证书
      - `key`: `string` - PEM 格式私钥
    - `alpnprotos`: `string[]|nil` (可选) - ALPN 协议列表，默认 `{"h2"}`
    - `ciphers`: `string|nil` (可选) - TLS 密码套件配置
    - `backlog`: `integer|nil` (可选) - 监听队列大小
- **返回值**:
  - 成功: `server` - 服务器对象
  - 失败: `nil, string` - nil 和错误信息
- **示例**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package calculator;

    message AddRequest {
        int32 a = 1;
        int32 b = 2;
    }

    message AddResponse {
        int32 result = 1;
    }

    service Calculator {
        rpc Add (AddRequest) returns (AddResponse) {}
    }
    ]], "calc.proto")

    local reg = registrar.new()
    reg:register(p.loaded["calc.proto"], {
        Add = function(req)
            return {result = req.a + req.b}
        end
    })

    local server, err = grpc.listen {
        addr = "127.0.0.1:50051",
        registrar = reg,
    }

    if not server then
        print("Failed to start server:", err)
        return
    end

    print("gRPC server listening on 127.0.0.1:50051")
end)
```

### server:close()

关闭 gRPC 服务器。

- **参数**: 无
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息
- **示例**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local registrar = require "silly.net.grpc.registrar"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package test;
    message Empty {}
    service Test {
        rpc Ping (Empty) returns (Empty) {}
    }
    ]], "test.proto")

    local reg = registrar.new()
    reg:register(p.loaded["test.proto"], {
        Ping = function() return {} end
    })

    local server = grpc.listen {
        addr = ":50051",
        registrar = reg,
    }

    -- 稍后关闭服务器
    local ok, err = server:close()
    if ok then
        print("Server closed")
    else
        print("Close failed:", err)
    end
end)
```

---

## 客户端 API

### grpc.newclient(conf)

创建 gRPC 客户端。

- **参数**:
  - `conf`: `table` - 客户端配置表
    - `service`: `string` (必需) - 服务名称（对应 proto 中的 service 名）
    - `endpoints`: `string[]` (必需) - gRPC 服务器地址列表，格式 `"host:port"`
    - `proto`: `table` (必需) - protoc 加载的 proto 定义
    - `tls`: `boolean|nil` (可选) - 是否使用 TLS，默认 false
    - `timeout`: `number|nil` (可选) - 请求超时时间（毫秒）
- **返回值**:
  - 成功: `client` - 客户端对象
  - 失败: `nil, string` - nil 和错误信息
- **注意**: 客户端对象会动态生成方法，方法名对应 proto 中定义的 RPC 方法
- **负载均衡**: 多个 endpoint 时使用轮询策略
- **示例**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package hello;

    message HelloRequest {
        string name = 1;
    }

    message HelloResponse {
        string message = 1;
    }

    service Greeter {
        rpc SayHello (HelloRequest) returns (HelloResponse) {}
    }
    ]], "hello.proto")

    local client, err = grpc.newclient {
        service = "Greeter",
        endpoints = {"127.0.0.1:50051", "127.0.0.1:50052"},
        proto = p.loaded["hello.proto"],
        timeout = 5000,
    }

    if not client then
        print("Failed to create client:", err)
        return
    end

    -- 客户端对象会自动生成 SayHello 方法
    local response, err = client.SayHello({name = "World"})
    if response then
        print("Response:", response.message)
    else
        print("RPC failed:", err)
    end
end)
```

### client.MethodName(request)

调用 RPC 方法（Unary RPC）。

- **参数**:
  - `request`: `table` - 请求消息对象（对应 proto 中定义的请求类型）
- **返回值**:
  - 成功: `table` - 响应消息对象
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 会挂起协程直到收到响应或超时
- **注意**: 方法名由 proto 定义决定，不同的 service 有不同的方法
- **示例**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package math;

    message MulRequest {
        int32 x = 1;
        int32 y = 2;
    }

    message MulResponse {
        int32 product = 1;
    }

    service MathService {
        rpc Multiply (MulRequest) returns (MulResponse) {}
    }
    ]], "math.proto")

    local client = grpc.newclient {
        service = "MathService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["math.proto"],
    }

    -- 调用 Multiply 方法
    local result, err = client.Multiply({x = 6, y = 7})
    if result then
        print("6 * 7 =", result.product)
    else
        print("RPC error:", err)
    end
end)
```

### client.StreamMethod()

创建流式 RPC 连接（Streaming RPC）。

- **参数**: 无
- **返回值**:
  - 成功: `stream` - 流对象
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 会挂起协程直到连接建立
- **注意**: 仅当 proto 中定义的方法包含 stream 关键字时可用
- **示例**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package stream;

    message DataChunk {
        string data = 1;
    }

    service StreamService {
        rpc BiStream (stream DataChunk) returns (stream DataChunk) {}
    }
    ]], "stream.proto")

    local client = grpc.newclient {
        service = "StreamService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["stream.proto"],
    }

    -- 创建双向流
    local stream, err = client.BiStream()
    if not stream then
        print("Failed to create stream:", err)
        return
    end

    -- 发送数据
    stream:write({data = "Hello"})

    -- 读取响应
    local response, err = stream:read()
    if response then
        print("Received:", response.data)
    end

    stream:close()
end)
```

---

## 流式 RPC API

当 RPC 方法定义为流式时（使用 `stream` 关键字），客户端调用返回流对象：

### stream:write(request)

向流写入请求消息。

- **参数**:
  - `request`: `table` - 请求消息对象
- **返回值**:
  - 成功: `true`
  - 失败: `false, string` - false 和错误信息
- **异步**: 会挂起协程直到数据发送完成
- **适用**: Client Streaming 和 Bidirectional Streaming
- **示例**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package upload;

    message FileChunk {
        bytes data = 1;
    }

    message UploadResponse {
        string file_id = 1;
    }

    service FileService {
        rpc Upload (stream FileChunk) returns (UploadResponse) {}
    }
    ]], "file.proto")

    local client = grpc.newclient {
        service = "FileService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["file.proto"],
    }

    local stream = client.Upload()

    -- 分块上传文件
    for i = 1, 5 do
        local ok, err = stream:write({
            data = string.rep("X", 1024)
        })
        if not ok then
            print("Write failed:", err)
            break
        end
    end

    stream:close()
end)
```

### stream:read([timeout])

从流读取响应消息。

- **参数**:
  - `timeout`: `number|nil` (可选) - 读取超时时间（毫秒）
- **返回值**:
  - 成功: `table` - 响应消息对象
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 会挂起协程直到收到数据或超时
- **适用**: Server Streaming 和 Bidirectional Streaming
- **示例**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package log;

    message LogRequest {
        string query = 1;
    }

    message LogEntry {
        string timestamp = 1;
        string message = 2;
    }

    service LogService {
        rpc StreamLogs (LogRequest) returns (stream LogEntry) {}
    }
    ]], "log.proto")

    local client = grpc.newclient {
        service = "LogService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["log.proto"],
    }

    local stream = client.StreamLogs()

    -- 发送查询请求
    stream:write({query = "error"})

    -- 持续读取日志流
    while true do
        local entry, err = stream:read(10000)  -- 10秒超时
        if not entry then
            print("Stream ended:", err)
            break
        end
        print(entry.timestamp, entry.message)
    end

    stream:close()
end)
```

### stream:close()

关闭流连接。

- **参数**: 无
- **返回值**: 无
- **注意**: 关闭后流对象不可再使用
- **示例**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package chat;

    message Message {
        string text = 1;
    }

    service ChatService {
        rpc Chat (stream Message) returns (stream Message) {}
    }
    ]], "chat.proto")

    local client = grpc.newclient {
        service = "ChatService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["chat.proto"],
    }

    local stream = client.Chat()

    -- 发送消息
    stream:write({text = "Hello"})

    -- 读取回复
    local reply = stream:read()
    if reply then
        print("Reply:", reply.text)
    end

    -- 关闭连接
    stream:close()
end)
```

---

## 使用示例

### 示例1：基础 Unary RPC

实现一个简单的问候服务：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

silly.fork(function()
    -- 定义 proto
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package greeter;

    message HelloRequest {
        string name = 1;
    }

    message HelloResponse {
        string greeting = 1;
    }

    service Greeter {
        rpc SayHello (HelloRequest) returns (HelloResponse) {}
        rpc SayGoodbye (HelloRequest) returns (HelloResponse) {}
    }
    ]], "greeter.proto")

    -- 创建服务器
    local reg = registrar.new()
    reg:register(p.loaded["greeter.proto"], {
        SayHello = function(req)
            return {greeting = "Hello, " .. req.name .. "!"}
        end,
        SayGoodbye = function(req)
            return {greeting = "Goodbye, " .. req.name .. "!"}
        end
    })

    local server = grpc.listen {
        addr = "127.0.0.1:50051",
        registrar = reg,
    }

    print("Greeter server started on 127.0.0.1:50051")

    -- 创建客户端
    local client = grpc.newclient {
        service = "Greeter",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["greeter.proto"],
        timeout = 5000,
    }

    -- 调用 RPC
    local resp1 = client.SayHello({name = "Alice"})
    print(resp1.greeting)  -- Hello, Alice!

    local resp2 = client.SayGoodbye({name = "Bob"})
    print(resp2.greeting)  -- Goodbye, Bob!

    server:close()
end)
```

### 示例2：带错误处理的 RPC 调用

完整的错误处理示例：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package calculator;

    message DivideRequest {
        double dividend = 1;
        double divisor = 2;
    }

    message DivideResponse {
        double quotient = 1;
    }

    service Calculator {
        rpc Divide (DivideRequest) returns (DivideResponse) {}
    }
    ]], "calculator.proto")

    -- 服务器端
    local reg = registrar.new()
    reg:register(p.loaded["calculator.proto"], {
        Divide = function(req)
            if req.divisor == 0 then
                -- 服务端可以返回 nil 或抛出错误
                error("division by zero")
            end
            return {quotient = req.dividend / req.divisor}
        end
    })

    local server = grpc.listen {
        addr = "127.0.0.1:50051",
        registrar = reg,
    }

    -- 客户端
    local client = grpc.newclient {
        service = "Calculator",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["calculator.proto"],
        timeout = 5000,
    }

    -- 正常调用
    local result, err = client.Divide({
        dividend = 10,
        divisor = 2
    })
    if result then
        print("10 / 2 =", result.quotient)
    else
        print("RPC failed:", err)
    end

    -- 错误调用（除零）
    local result2, err2 = client.Divide({
        dividend = 10,
        divisor = 0
    })
    if result2 then
        print("Result:", result2.quotient)
    else
        print("Expected error:", err2)
    end

    server:close()
end)
```

### 示例3：多服务端点负载均衡

使用多个服务器端点实现负载均衡：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package counter;

    message IncrementRequest {
        int32 delta = 1;
    }

    message IncrementResponse {
        int32 value = 1;
    }

    service Counter {
        rpc Increment (IncrementRequest) returns (IncrementResponse) {}
    }
    ]], "counter.proto")

    -- 启动两个服务器实例
    local reg1 = registrar.new()
    local counter1 = 0
    reg1:register(p.loaded["counter.proto"], {
        Increment = function(req)
            counter1 = counter1 + req.delta
            print("Server 1 counter:", counter1)
            return {value = counter1}
        end
    })

    local server1 = grpc.listen {
        addr = "127.0.0.1:50051",
        registrar = reg1,
    }

    local reg2 = registrar.new()
    local counter2 = 0
    reg2:register(p.loaded["counter.proto"], {
        Increment = function(req)
            counter2 = counter2 + req.delta
            print("Server 2 counter:", counter2)
            return {value = counter2}
        end
    })

    local server2 = grpc.listen {
        addr = "127.0.0.1:50052",
        registrar = reg2,
    }

    print("Started two servers on ports 50051 and 50052")

    -- 客户端连接多个端点
    local client = grpc.newclient {
        service = "Counter",
        endpoints = {
            "127.0.0.1:50051",
            "127.0.0.1:50052"
        },
        proto = p.loaded["counter.proto"],
    }

    -- 请求会轮询到两个服务器
    for i = 1, 4 do
        local result = client.Increment({delta = 1})
        print("Client got value:", result.value)
    end

    server1:close()
    server2:close()
end)
```

### 示例4：带超时的 RPC 调用

演示超时控制：

```lua validate
local silly = require "silly"
local time = require "silly.time"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package slow;

    message SlowRequest {
        int32 delay_ms = 1;
    }

    message SlowResponse {
        string result = 1;
    }

    service SlowService {
        rpc SlowMethod (SlowRequest) returns (SlowResponse) {}
    }
    ]], "slow.proto")

    -- 服务器：模拟慢响应
    local reg = registrar.new()
    reg:register(p.loaded["slow.proto"], {
        SlowMethod = function(req)
            time.sleep(req.delay_ms)
            return {result = "Done after " .. req.delay_ms .. "ms"}
        end
    })

    local server = grpc.listen {
        addr = "127.0.0.1:50051",
        registrar = reg,
    }

    -- 客户端：设置短超时
    local client = grpc.newclient {
        service = "SlowService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["slow.proto"],
        timeout = 1000,  -- 1秒超时
    }

    -- 快速请求（应该成功）
    local result1, err1 = client.SlowMethod({delay_ms = 100})
    if result1 then
        print("Fast request:", result1.result)
    else
        print("Fast request failed:", err1)
    end

    -- 慢速请求（应该超时）
    local result2, err2 = client.SlowMethod({delay_ms = 2000})
    if result2 then
        print("Slow request:", result2.result)
    else
        print("Slow request timeout:", err2)
    end

    server:close()
end)
```

### 示例5：TLS 加密的 gRPC 服务

使用 TLS 保护 gRPC 通信：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package secure;

    message SecureRequest {
        string secret = 1;
    }

    message SecureResponse {
        string result = 1;
    }

    service SecureService {
        rpc ProcessSecret (SecureRequest) returns (SecureResponse) {}
    }
    ]], "secure.proto")

    -- 测试用的自签名证书
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

    -- TLS 服务器
    local reg = registrar.new()
    reg:register(p.loaded["secure.proto"], {
        ProcessSecret = function(req)
            return {result = "Processed: " .. req.secret}
        end
    })

    local server = grpc.listen {
        addr = "127.0.0.1:50051",
        registrar = reg,
        tls = true,
        alpnprotos = {"h2"},
        certs = {
            {
                cert = cert_pem,
                key = key_pem,
            }
        },
    }

    print("Secure gRPC server started")

    -- TLS 客户端
    local client = grpc.newclient {
        service = "SecureService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["secure.proto"],
        tls = true,
    }

    local result = client.ProcessSecret({
        secret = "my-sensitive-data"
    })

    if result then
        print("Secure response:", result.result)
    end

    server:close()
end)
```

### 示例6：并发 RPC 调用

使用协程实现并发请求：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local waitgroup = require "silly.sync.waitgroup"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package api;

    message GetRequest {
        int32 id = 1;
    }

    message GetResponse {
        int32 id = 1;
        string data = 2;
    }

    service DataService {
        rpc GetData (GetRequest) returns (GetResponse) {}
    }
    ]], "api.proto")

    -- 服务器
    local reg = registrar.new()
    reg:register(p.loaded["api.proto"], {
        GetData = function(req)
            return {
                id = req.id,
                data = "Data for ID " .. req.id
            }
        end
    })

    local server = grpc.listen {
        addr = "127.0.0.1:50051",
        registrar = reg,
    }

    -- 客户端
    local client = grpc.newclient {
        service = "DataService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["api.proto"],
    }

    -- 并发请求多个资源
    local wg = waitgroup.new()
    local results = {}

    for i = 1, 10 do
        wg:fork(function()
            local result = client.GetData({id = i})
            if result then
                results[i] = result.data
                print("Received:", result.data)
            end
        end)
    end

    wg:wait()
    print("All requests completed, got", #results, "results")

    server:close()
end)
```

### 示例7：服务器流式 RPC

演示服务器流式响应：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package events;

    message EventRequest {
        string topic = 1;
    }

    message Event {
        int32 sequence = 1;
        string message = 2;
    }

    service EventService {
        rpc Subscribe (EventRequest) returns (stream Event) {}
    }
    ]], "events.proto")

    -- 注意：当前实现主要支持 Unary RPC
    -- 完整的流式 RPC 需要服务器端的额外实现
    -- 这里展示客户端如何处理流式响应

    local reg = registrar.new()
    reg:register(p.loaded["events.proto"], {
        Subscribe = function(req)
            -- Unary 版本：返回单个事件
            return {
                sequence = 1,
                message = "Event for topic: " .. req.topic
            }
        end
    })

    local server = grpc.listen {
        addr = "127.0.0.1:50051",
        registrar = reg,
    }

    local client = grpc.newclient {
        service = "EventService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["events.proto"],
    }

    -- 对于流式方法，调用返回流对象
    local stream, err = client.Subscribe()
    if stream then
        -- 写入请求
        stream:write({topic = "notifications"})

        -- 读取流式响应
        local event = stream:read(5000)
        if event then
            print("Event:", event.sequence, event.message)
        end

        stream:close()
    end

    server:close()
end)
```

### 示例8：复杂数据结构的 RPC

处理嵌套和复杂的 Protocol Buffers 消息：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package user;

    message Address {
        string street = 1;
        string city = 2;
        string country = 3;
    }

    message User {
        int32 id = 1;
        string name = 2;
        repeated string emails = 3;
        Address address = 4;
        map<string, string> metadata = 5;
    }

    message CreateUserRequest {
        User user = 1;
    }

    message CreateUserResponse {
        User user = 1;
        bool success = 2;
    }

    service UserService {
        rpc CreateUser (CreateUserRequest) returns (CreateUserResponse) {}
    }
    ]], "user.proto")

    -- 服务器
    local reg = registrar.new()
    local next_id = 1

    reg:register(p.loaded["user.proto"], {
        CreateUser = function(req)
            local user = req.user
            user.id = next_id
            next_id = next_id + 1

            print("Created user:", user.name)
            print("Address:", user.address.city, user.address.country)
            print("Emails:", table.concat(user.emails, ", "))

            return {
                user = user,
                success = true
            }
        end
    })

    local server = grpc.listen {
        addr = "127.0.0.1:50051",
        registrar = reg,
    }

    -- 客户端
    local client = grpc.newclient {
        service = "UserService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["user.proto"],
    }

    local response = client.CreateUser({
        user = {
            name = "Alice Smith",
            emails = {
                "alice@example.com",
                "asmith@work.com"
            },
            address = {
                street = "123 Main St",
                city = "Springfield",
                country = "USA"
            },
            metadata = {
                department = "Engineering",
                level = "Senior"
            }
        }
    })

    if response and response.success then
        print("User created with ID:", response.user.id)
    end

    server:close()
end)
```

---

## 注意事项

### 1. 协程要求

所有 gRPC API（服务器和客户端）必须在协程中调用：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"

-- 错误：不能在主线程调用
-- local client = grpc.newclient(...)  -- 会失败

-- 正确：在协程中调用
silly.fork(function()
    local client = grpc.newclient({
        -- ...
    })
    -- 正常使用
end)
```

### 2. HTTP/2 依赖

gRPC 依赖 HTTP/2 传输层：
- 服务器自动使用 HTTP/2
- TLS 场景使用 ALPN 协商 `h2` 协议
- 客户端会自动检测并使用 HTTP/2

### 3. Protocol Buffers 版本

使用 proto3 语法（推荐）：

```lua validate
local protoc = require "protoc"

local p = protoc:new()

-- 推荐：使用 proto3
p:load([[
syntax = "proto3";
package myapp;
-- ...
]], "myapp.proto")
```

### 4. 错误处理

始终检查返回值，gRPC 调用可能失败：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package test;
    message Req {}
    message Resp {}
    service Test {
        rpc Call (Req) returns (Resp) {}
    }
    ]], "test.proto")

    local client, err = grpc.newclient {
        service = "Test",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["test.proto"],
    }

    if not client then
        print("Failed to create client:", err)
        return
    end

    local response, err = client.Call({})
    if not response then
        print("RPC call failed:", err)
        return
    end

    -- 处理成功响应
end)
```

### 5. 消息大小限制

服务器端限制单个消息大小为 4MB：

```lua
-- grpc.lua 中的常量
local MAX_LEN = 4*1024*1024  -- 4MB
```

超过限制会返回 `ResourceExhausted` 错误。

### 6. 超时设置

客户端超时是可选的，建议设置合理的超时值：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package test;
    message Empty {}
    service Test {
        rpc Ping (Empty) returns (Empty) {}
    }
    ]], "test.proto")

    local client = grpc.newclient {
        service = "Test",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["test.proto"],
        timeout = 5000,  -- 5秒超时（推荐设置）
    }

    -- 超时后返回 nil 和错误信息
    local result, err = client.Ping({})
    if not result then
        print("Request timeout or failed:", err)
    end
end)
```

### 7. 服务注册顺序

必须先注册服务，再启动服务器：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package test;
    message Empty {}
    service Test {
        rpc Ping (Empty) returns (Empty) {}
    }
    ]], "test.proto")

    local reg = registrar.new()

    -- 1. 先注册服务
    reg:register(p.loaded["test.proto"], {
        Ping = function() return {} end
    })

    -- 2. 再启动服务器
    local server = grpc.listen {
        addr = ":50051",
        registrar = reg,
    }

    server:close()
end)
```

### 8. 负载均衡策略

客户端使用简单的轮询（Round-Robin）策略：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package test;
    message Empty {}
    service Test {
        rpc Ping (Empty) returns (Empty) {}
    }
    ]], "test.proto")

    -- 请求会按顺序分发到三个端点
    local client = grpc.newclient {
        service = "Test",
        endpoints = {
            "server1.example.com:50051",  -- 第1个请求
            "server2.example.com:50051",  -- 第2个请求
            "server3.example.com:50051",  -- 第3个请求
            -- 第4个请求回到 server1...
        },
        proto = p.loaded["test.proto"],
    }

    -- 10 个请求会均匀分布到 3 个服务器
    for i = 1, 10 do
        client.Ping({})
    end
end)
```

---

## 性能建议

### 1. 连接复用

gRPC 基于 HTTP/2，自动复用连接：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package test;
    message Request {
        int32 id = 1;
    }
    message Response {
        string data = 1;
    }
    service Test {
        rpc Get (Request) returns (Response) {}
    }
    ]], "test.proto")

    local client = grpc.newclient {
        service = "Test",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["test.proto"],
    }

    -- HTTP/2 连接会被自动复用
    for i = 1, 100 do
        client.Get({id = i})
    end
    -- 所有请求共享同一个 TCP 连接
end)
```

### 2. 并发调用

使用 waitgroup 实现并发 RPC 请求：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local waitgroup = require "silly.sync.waitgroup"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package test;
    message Request {
        int32 id = 1;
    }
    message Response {
        string data = 1;
    }
    service Test {
        rpc Get (Request) returns (Response) {}
    }
    ]], "test.proto")

    local client = grpc.newclient {
        service = "Test",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["test.proto"],
    }

    local wg = waitgroup.new()

    -- 并发发送 20 个请求
    for i = 1, 20 do
        wg:fork(function()
            local result = client.Get({id = i})
            if result then
                print("Got result for ID", i)
            end
        end)
    end

    wg:wait()
    print("All concurrent requests completed")
end)
```

### 3. 消息设计

优化 Protocol Buffers 消息结构：

- 使用合适的字段类型（int32 vs int64）
- 避免过大的消息（受 4MB 限制）
- 使用 repeated 和 map 提高表达能力
- 避免深度嵌套

```lua validate
local protoc = require "protoc"

local p = protoc:new()
p:load([[
syntax = "proto3";
package optimize;

// 好的设计：字段类型合适，结构清晰
message GoodRequest {
    int32 user_id = 1;           // 用户ID通常不需要 int64
    repeated string tags = 2;    // 使用 repeated 而不是分隔的字符串
    map<string, int32> counts = 3; // 使用 map 而不是列表
}

// 避免：过深的嵌套
message BadRequest {
    message Level1 {
        message Level2 {
            message Level3 {
                string data = 1;  // 3层嵌套，不推荐
            }
            Level3 level3 = 1;
        }
        Level2 level2 = 1;
    }
    Level1 level1 = 1;
}
]], "optimize.proto")
```

### 4. 服务器端池化

对于高负载场景，启动多个服务器实例：

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"

silly.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package test;
    message Empty {}
    service Test {
        rpc Ping (Empty) returns (Empty) {}
    }
    ]], "test.proto")

    local servers = {}

    -- 启动多个服务器实例，监听不同端口
    for port = 50051, 50054 do
        local reg = registrar.new()
        reg:register(p.loaded["test.proto"], {
            Ping = function() return {} end
        })

        servers[#servers + 1] = grpc.listen {
            addr = "127.0.0.1:" .. port,
            registrar = reg,
        }

        print("Server started on port", port)
    end

    -- 清理
    for _, server in ipairs(servers) do
        server:close()
    end
end)
```

### 5. 批量处理

对于大量小请求，考虑批量处理：

```lua validate
local protoc = require "protoc"

local p = protoc:new()
p:load([[
syntax = "proto3";
package batch;

message Item {
    int32 id = 1;
    string name = 2;
}

// 推荐：批量请求
message BatchGetRequest {
    repeated int32 ids = 1;
}

message BatchGetResponse {
    repeated Item items = 1;
}

service DataService {
    rpc BatchGet (BatchGetRequest) returns (BatchGetResponse) {}
}
]], "batch.proto")

-- 批量获取比单个循环调用更高效
```

---

## 参见

- [silly](../silly.md) - 核心调度器
- [silly.net.http](./http.md) - HTTP 协议（gRPC 的传输层）
- [silly.net.tcp](./tcp.md) - TCP 协议
- [silly.net.tls](./tls.md) - TLS/SSL 加密
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
