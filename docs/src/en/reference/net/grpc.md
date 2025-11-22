---
title: silly.net.grpc
icon: network-wired
category:
  - API Reference
tag:
  - Network
  - gRPC
  - RPC
  - Protocol Buffers
---

# silly.net.grpc

The `silly.net.grpc` module provides server-side and client-side implementations of the gRPC protocol. Built on HTTP/2 transport layer, it supports standard Protocol Buffers serialization and implements both Unary RPC and Streaming RPC calling patterns. The framework automatically handles connection management, request routing, error handling and other details, allowing developers to focus on business logic.

## Module Import

```lua validate
local grpc = require "silly.net.grpc"
```

## Core Concepts

### gRPC Protocol

gRPC is Google's open-source high-performance RPC framework based on HTTP/2 and Protocol Buffers:
- **HTTP/2 Transport**: Leverages multiplexing, header compression and other features for performance
- **Protocol Buffers**: Efficient binary serialization format
- **Strongly-typed Interfaces**: Clear service contracts defined through .proto files
- **Streaming Support**: Supports client streams, server streams, and bidirectional streams

### RPC Calling Patterns

The framework supports four gRPC calling patterns:

1. **Unary RPC**: Single request, single response (most common)
2. **Server Streaming RPC**: Single request, multiple response stream
3. **Client Streaming RPC**: Multiple request stream, single response
4. **Bidirectional Streaming RPC**: Bidirectional streaming communication

### Protocol Buffers

Use the protoc module to define and load service interfaces:

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

### Status Codes

gRPC uses standard status codes to represent operation results, defined in the `silly.net.grpc.code` module:

- `code.OK` (0): Success
- `code.Canceled` (1): Operation canceled
- `code.Unknown` (2): Unknown error
- `code.InvalidArgument` (3): Invalid argument
- `code.DeadlineExceeded` (4): Timeout
- `code.NotFound` (5): Resource not found
- `code.AlreadyExists` (6): Resource already exists
- `code.PermissionDenied` (7): Permission denied
- `code.ResourceExhausted` (8): Resource exhausted
- `code.Unauthenticated` (16): Unauthenticated

---

## Server-side API

### registrar.new()

Create a new gRPC service registrar.

- **Parameters**: None
- **Returns**: `registrar` - Service registrar object
- **Example**:

```lua validate
local registrar = require "silly.net.grpc.registrar"

local reg = registrar.new()
```

### registrar:register(proto, service)

Register a service implementation with the registrar.

- **Parameters**:
  - `proto`: `table` - Proto definition loaded by protoc (contains package and service information)
  - `service`: `table` - Service implementation table, keys are method names, values are handler functions
- **Returns**: None
- **Note**: Handler function signature is `function(request) -> response`
- **Example**:

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

Create a gRPC server and start listening.

- **Parameters**:
  - `conf`: `table` - Server configuration table
    - `addr`: `string` (required) - Listen address, e.g. `"127.0.0.1:50051"`
    - `registrar`: `registrar` (required) - Service registrar object
    - `tls`: `boolean|nil` (optional) - Whether to enable TLS, default false
    - `certs`: `table[]|nil` (optional) - TLS certificate configuration (required when tls=true)
      - `cert`: `string` - Certificate in PEM format
      - `key`: `string` - Private key in PEM format
    - `alpnprotos`: `string[]|nil` (optional) - ALPN protocol list, default `{"h2"}`
    - `ciphers`: `string|nil` (optional) - TLS cipher suite configuration
    - `backlog`: `integer|nil` (optional) - Listen queue size
- **Returns**:
  - Success: `server` - Server object
  - Failure: `nil, string` - nil and error message
- **Example**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local task = require "silly.task"

task.fork(function()
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

Close the gRPC server.

- **Parameters**: None
- **Returns**:
  - Success: `true`
  - Failure: `false, string` - false and error message
- **Example**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local registrar = require "silly.net.grpc.registrar"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
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

    -- Close server later
    local ok, err = server:close()
    if ok then
        print("Server closed")
    else
        print("Close failed:", err)
    end
end)
```

---

## Client-side API

### grpc.newclient(conf)

Create a gRPC client.

- **Parameters**:
  - `conf`: `table` - Client configuration table
    - `service`: `string` (required) - Service name (corresponds to service name in proto)
    - `endpoints`: `string[]` (required) - List of gRPC server addresses, format `"host:port"`
    - `proto`: `table` (required) - Proto definition loaded by protoc
    - `tls`: `boolean|nil` (optional) - Whether to use TLS, default false
    - `timeout`: `number|nil` (optional) - Request timeout (milliseconds)
- **Returns**:
  - Success: `client` - Client object
  - Failure: `nil, string` - nil and error message
- **Note**: Client object dynamically generates methods with names corresponding to RPC methods defined in proto
- **Load Balancing**: Uses round-robin strategy with multiple endpoints
- **Example**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
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

    -- Client object automatically generates SayHello method
    local response, err = client.SayHello({name = "World"})
    if response then
        print("Response:", response.message)
    else
        print("RPC failed:", err)
    end
end)
```

### client.MethodName(request)

Call an RPC method (Unary RPC).

- **Parameters**:
  - `request`: `table` - Request message object (corresponds to request type defined in proto)
- **Returns**:
  - Success: `table` - Response message object
  - Failure: `nil, string` - nil and error message
- **Async**: Suspends coroutine until response is received or timeout occurs
- **Note**: Method name is determined by proto definition; different services have different methods
- **Example**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
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

    -- Call Multiply method
    local result, err = client.Multiply({x = 6, y = 7})
    if result then
        print("6 * 7 =", result.product)
    else
        print("RPC error:", err)
    end
end)
```

### client.StreamMethod()

Create a streaming RPC connection (Streaming RPC).

- **Parameters**: None
- **Returns**:
  - Success: `stream` - Stream object
  - Failure: `nil, string` - nil and error message
- **Async**: Suspends coroutine until connection is established
- **Note**: Only available when the method defined in proto contains the stream keyword
- **Example**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
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

    -- Create bidirectional stream
    local stream, err = client.BiStream()
    if not stream then
        print("Failed to create stream:", err)
        return
    end

    -- Send data
    stream:write({data = "Hello"})

    -- Read response
    local response, err = stream:read()
    if response then
        print("Received:", response.data)
    end

    stream:close()
end)
```

---

## Streaming RPC API

When an RPC method is defined as streaming (using the `stream` keyword), the client call returns a stream object:

### stream:write(request)

Write a request message to the stream.

- **Parameters**:
  - `request`: `table` - Request message object
- **Returns**:
  - Success: `true`
  - Failure: `false, string` - false and error message
- **Async**: Suspends coroutine until data is sent
- **Applicable**: Client Streaming and Bidirectional Streaming
- **Example**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
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

    -- Upload file in chunks
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

Read a response message from the stream.

- **Parameters**:
  - `timeout`: `number|nil` (optional) - Read timeout (milliseconds)
- **Returns**:
  - Success: `table` - Response message object
  - Failure: `nil, string` - nil and error message
- **Async**: Suspends coroutine until data is received or timeout occurs
- **Applicable**: Server Streaming and Bidirectional Streaming
- **Example**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
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

    -- Send query request
    stream:write({query = "error"})

    -- Continuously read log stream
    while true do
        local entry, err = stream:read(10000)  -- 10 second timeout
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

Close the stream connection.

- **Parameters**: None
- **Returns**: None
- **Note**: Stream object cannot be used after closing
- **Example**:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
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

    -- Send message
    stream:write({text = "Hello"})

    -- Read reply
    local reply = stream:read()
    if reply then
        print("Reply:", reply.text)
    end

    -- Close connection
    stream:close()
end)
```

---

## Usage Examples

### Example 1: Basic Unary RPC

Implement a simple greeting service:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local task = require "silly.task"

task.fork(function()
    -- Define proto
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

    -- Create server
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

    -- Create client
    local client = grpc.newclient {
        service = "Greeter",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["greeter.proto"],
        timeout = 5000,
    }

    -- Call RPC
    local resp1 = client.SayHello({name = "Alice"})
    print(resp1.greeting)  -- Hello, Alice!

    local resp2 = client.SayGoodbye({name = "Bob"})
    print(resp2.greeting)  -- Goodbye, Bob!

    server:close()
end)
```

### Example 2: RPC Call with Error Handling

Complete error handling example:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local task = require "silly.task"

task.fork(function()
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

    -- Server side
    local reg = registrar.new()
    reg:register(p.loaded["calculator.proto"], {
        Divide = function(req)
            if req.divisor == 0 then
                -- Server can return nil or throw an error
                error("division by zero")
            end
            return {quotient = req.dividend / req.divisor}
        end
    })

    local server = grpc.listen {
        addr = "127.0.0.1:50051",
        registrar = reg,
    }

    -- Client side
    local client = grpc.newclient {
        service = "Calculator",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["calculator.proto"],
        timeout = 5000,
    }

    -- Normal call
    local result, err = client.Divide({
        dividend = 10,
        divisor = 2
    })
    if result then
        print("10 / 2 =", result.quotient)
    else
        print("RPC failed:", err)
    end

    -- Error call (division by zero)
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

### Example 3: Multi-Endpoint Load Balancing

Use multiple server endpoints for load balancing:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local task = require "silly.task"

task.fork(function()
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

    -- Start two server instances
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

    -- Client connects to multiple endpoints
    local client = grpc.newclient {
        service = "Counter",
        endpoints = {
            "127.0.0.1:50051",
            "127.0.0.1:50052"
        },
        proto = p.loaded["counter.proto"],
    }

    -- Requests will be distributed to both servers
    for i = 1, 4 do
        local result = client.Increment({delta = 1})
        print("Client got value:", result.value)
    end

    server1:close()
    server2:close()
end)
```

### Example 4: RPC Call with Timeout

Demonstrate timeout control:

```lua validate
local silly = require "silly"
local time = require "silly.time"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local task = require "silly.task"

task.fork(function()
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

    -- Server: simulate slow response
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

    -- Client: set short timeout
    local client = grpc.newclient {
        service = "SlowService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["slow.proto"],
        timeout = 1000,  -- 1 second timeout
    }

    -- Fast request (should succeed)
    local result1, err1 = client.SlowMethod({delay_ms = 100})
    if result1 then
        print("Fast request:", result1.result)
    else
        print("Fast request failed:", err1)
    end

    -- Slow request (should timeout)
    local result2, err2 = client.SlowMethod({delay_ms = 2000})
    if result2 then
        print("Slow request:", result2.result)
    else
        print("Slow request timeout:", err2)
    end

    server:close()
end)
```

### Example 5: TLS-Encrypted gRPC Service

Use TLS to secure gRPC communication:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local task = require "silly.task"

task.fork(function()
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

    -- Test self-signed certificate
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

    -- TLS server
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

    -- TLS client
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

### Example 6: Concurrent RPC Calls

Use coroutines for concurrent requests:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
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

    -- Server
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

    -- Client
    local client = grpc.newclient {
        service = "DataService",
        endpoints = {"127.0.0.1:50051"},
        proto = p.loaded["api.proto"],
    }

    -- Concurrent requests for multiple resources
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

### Example 7: Server Streaming RPC

Demonstrate server streaming response:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local task = require "silly.task"

task.fork(function()
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

    -- Note: Current implementation primarily supports Unary RPC
    -- Full streaming RPC requires additional server-side implementation
    -- This shows how client handles streaming response

    local reg = registrar.new()
    reg:register(p.loaded["events.proto"], {
        Subscribe = function(req)
            -- Unary version: return single event
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

    -- For streaming methods, call returns stream object
    local stream, err = client.Subscribe()
    if stream then
        -- Write request
        stream:write({topic = "notifications"})

        -- Read streaming response
        local event = stream:read(5000)
        if event then
            print("Event:", event.sequence, event.message)
        end

        stream:close()
    end

    server:close()
end)
```

### Example 8: Complex Data Structures in RPC

Handle nested and complex Protocol Buffers messages:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local task = require "silly.task"

task.fork(function()
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

    -- Server
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

    -- Client
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

## Notes

### 1. Coroutine Requirement

All gRPC APIs (server and client) must be called within a coroutine:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local task = require "silly.task"

-- Wrong: cannot call in main thread
-- local client = grpc.newclient(...)  -- will fail

-- Correct: call in coroutine
task.fork(function()
    local client = grpc.newclient({
        -- ...
    })
    -- normal usage
end)
```

### 2. HTTP/2 Dependency

gRPC relies on HTTP/2 transport layer:
- Server automatically uses HTTP/2
- TLS scenarios use ALPN to negotiate `h2` protocol
- Client automatically detects and uses HTTP/2

### 3. Protocol Buffers Version

Use proto3 syntax (recommended):

```lua validate
local protoc = require "protoc"

local p = protoc:new()

-- Recommended: use proto3
p:load([[
syntax = "proto3";
package myapp;
-- ...
]], "myapp.proto")
```

### 4. Error Handling

Always check return values; gRPC calls may fail:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
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

    -- Handle successful response
end)
```

### 5. Message Size Limit

Server-side limits single message size to 4MB:

```lua
-- Constant in grpc.lua
local MAX_LEN = 4*1024*1024  -- 4MB
```

Exceeding the limit returns a `ResourceExhausted` error.

### 6. Timeout Settings

Client timeout is optional; setting a reasonable timeout is recommended:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
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
        timeout = 5000,  -- 5 second timeout (recommended)
    }

    -- Returns nil and error message on timeout
    local result, err = client.Ping({})
    if not result then
        print("Request timeout or failed:", err)
    end
end)
```

### 7. Service Registration Order

Services must be registered before starting the server:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local task = require "silly.task"

task.fork(function()
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

    -- 1. Register service first
    reg:register(p.loaded["test.proto"], {
        Ping = function() return {} end
    })

    -- 2. Then start server
    local server = grpc.listen {
        addr = ":50051",
        registrar = reg,
    }

    server:close()
end)
```

### 8. Load Balancing Strategy

Client uses simple round-robin strategy:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
    local p = protoc:new()
    p:load([[
    syntax = "proto3";
    package test;
    message Empty {}
    service Test {
        rpc Ping (Empty) returns (Empty) {}
    }
    ]], "test.proto")

    -- Requests are distributed to three endpoints in order
    local client = grpc.newclient {
        service = "Test",
        endpoints = {
            "server1.example.com:50051",  -- 1st request
            "server2.example.com:50051",  -- 2nd request
            "server3.example.com:50051",  -- 3rd request
            -- 4th request goes back to server1...
        },
        proto = p.loaded["test.proto"],
    }

    -- 10 requests will be evenly distributed across 3 servers
    for i = 1, 10 do
        client.Ping({})
    end
end)
```

---

## Performance Recommendations

### 1. Connection Reuse

gRPC is based on HTTP/2, automatically reuses connections:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local task = require "silly.task"

task.fork(function()
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

    -- HTTP/2 connection is automatically reused
    for i = 1, 100 do
        client.Get({id = i})
    end
    -- All requests share the same TCP connection
end)
```

### 2. Concurrent Calls

Use waitgroup for concurrent RPC requests:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
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

    -- Send 20 concurrent requests
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

### 3. Message Design

Optimize Protocol Buffers message structure:

- Use appropriate field types (int32 vs int64)
- Avoid overly large messages (limited by 4MB)
- Use repeated and map for better expressiveness
- Avoid deep nesting

```lua validate
local protoc = require "protoc"

local p = protoc:new()
p:load([[
syntax = "proto3";
package optimize;

// Good design: appropriate field types, clear structure
message GoodRequest {
    int32 user_id = 1;           // User ID typically doesn't need int64
    repeated string tags = 2;    // Use repeated instead of delimited strings
    map<string, int32> counts = 3; // Use map instead of list
}

// Avoid: too much nesting
message BadRequest {
    message Level1 {
        message Level2 {
            message Level3 {
                string data = 1;  // 3 levels of nesting, not recommended
            }
            Level3 level3 = 1;
        }
        Level2 level2 = 1;
    }
    Level1 level1 = 1;
}
]], "optimize.proto")
```

### 4. Server-side Pooling

For high-load scenarios, start multiple server instances:

```lua validate
local silly = require "silly"
local grpc = require "silly.net.grpc"
local protoc = require "protoc"
local registrar = require "silly.net.grpc.registrar"
local task = require "silly.task"

task.fork(function()
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

    -- Start multiple server instances on different ports
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

    -- Cleanup
    for _, server in ipairs(servers) do
        server:close()
    end
end)
```

### 5. Batch Processing

For many small requests, consider batch processing:

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

// Recommended: batch request
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

-- Batch fetching is more efficient than individual loop calls
```

---

## See Also

- [silly](../silly.md) - Core module
- [silly.net.http](./http.md) - HTTP protocol (transport layer for gRPC)
- [silly.net.tcp](./tcp.md) - TCP protocol
- [silly.net.tls](./tls.md) - TLS/SSL encryption
- [silly.sync.waitgroup](../sync/waitgroup.md) - Coroutine wait group
