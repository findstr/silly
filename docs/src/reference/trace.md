---
title: silly.trace
icon: route
category:
  - API参考
tag:
  - 核心
  - 分布式追踪
  - 可观测性
---

# silly.trace

分布式追踪模块，提供跨服务的请求追踪和调用链追踪功能。

> 💡 **提示**: trace 模块依赖 [silly.task](./task.md) 模块，每个协程可以关联一个 trace ID 用于全链路追踪。

## 模块导入

```lua validate
local trace = require "silly.trace"
```

## 核心概念

### Trace ID 结构

Trace ID 是一个 64 位整数，由两部分组成：

```
┌─────────────────────────────┬──────────────┐
│   Root Trace (48 bits)      │ Node (16 bits)│
│   全局唯一的追踪根 ID        │   节点 ID      │
└─────────────────────────────┴──────────────┘
```

- **Root Trace (高 48 位)**: 全局唯一的追踪根 ID，标识一次完整的请求链路
- **Node ID (低 16 位)**: 当前服务节点的 ID（范围 0-65535）

### 使用场景

- **微服务调用链追踪**: 追踪请求在多个服务间的传播路径
- **日志关联**: 自动将 trace ID 附加到日志中，便于日志聚合和检索
- **性能分析**: 识别慢请求和性能瓶颈
- **问题排查**: 快速定位分布式系统中的问题根因

## API 参考

### trace.setnode(nodeid)

设置当前服务节点的节点 ID，用于生成 trace ID。

- **参数**:
  - `nodeid`: `integer` - 节点 ID（16 位，范围 0-65535）
- **说明**:
  - 通常在服务启动时调用一次
  - 每个服务实例应该有唯一的节点 ID
  - 节点 ID 会被嵌入到后续生成的所有 trace ID 中
- **示例**:

```lua validate
local trace = require "silly.trace"

-- 在服务启动时设置节点 ID
trace.setnode(1001)  -- 设置为节点 1001
```

### trace.spawn()

创建一个新的根 trace ID 并设置为当前协程的 trace ID。

- **返回值**: `integer` - 之前的 trace ID（可用于后续恢复）
- **说明**:
  - 用于开始一个新的追踪链路（如处理新的 HTTP 请求）
  - 生成全局唯一的 root trace ID
  - 自动包含当前节点的 node ID
- **示例**:

```lua validate
local trace = require "silly.trace"
local http = require "silly.net.http"

local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        -- 为每个新请求创建新的 trace ID
        local old_trace = trace.spawn()

        -- 处理请求...
        handle_request(stream)

        -- 如需恢复旧的 trace context（少见）
        -- trace.attach(old_trace)

        stream:respond(200, {
            ["content-type"] = "text/plain",
            ["content-length"] = 2,
        })
        stream:write("ok")
    end
}
```

### trace.attach(id)

设置当前协程的 trace ID，用于附加到已有的追踪链路。

- **参数**:
  - `id`: `integer` - 要附加的 trace ID
- **返回值**: `integer` - 之前的 trace ID
- **说明**:
  - 用于接收上游服务传来的 trace ID
  - 实现跨服务的追踪链路传播
- **示例**:

```lua validate
local trace = require "silly.trace"

-- 从 HTTP 请求头中获取上游的 trace ID
local function handle_downstream_request(req)
    local upstream_traceid = tonumber(req.header["X-Trace-ID"])

    if upstream_traceid then
        -- 附加上游的 trace ID，继续追踪链路
        trace.attach(upstream_traceid)
    else
        -- 没有上游 trace，创建新的
        trace.spawn()
    end

    -- 后续的日志都会包含这个 trace ID
end
```

### trace.propagate()

获取用于跨服务传播的 trace ID。

- **返回值**: `integer` - 传播用的 trace ID
- **说明**:
  - 保留原始的 root trace ID（高 48 位）
  - 替换 node ID 为当前节点的 ID（低 16 位）
  - 用于向下游服务传递 trace ID
- **示例**:

```lua validate
local trace = require "silly.trace"
local http = require "silly.net.http"

-- 调用下游服务时传播 trace ID
local function call_downstream_service()
    -- 获取要传播的 trace ID
    local traceid = trace.propagate()

    -- 在 HTTP 请求头中传递
    local resp = http.get("http://service-b:8080/api", {
        headers = {
            ["X-Trace-ID"] = tostring(traceid)
        }
    })

    return resp
end
```

## 完整示例

### 示例 1: HTTP 微服务入口

```lua validate
local trace = require "silly.trace"
local http = require "silly.net.http"
local logger = require "silly.logger.c"

-- 服务启动时设置节点 ID
trace.setnode(1)

local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        -- 为每个新请求创建 trace
        trace.spawn()

        logger.info("Received request:", stream.path)

        -- 调用下游服务
        local traceid = trace.propagate()
        local result = call_service_b(traceid)

        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #result,
        })
        stream:closewrite(result)
    end
}
```

### 示例 2: 下游服务接收 trace

```lua validate
local trace = require "silly.trace"
local http = require "silly.net.http"
local logger = require "silly.logger.c"

-- 服务启动时设置节点 ID（不同于上游）
trace.setnode(2)

local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        -- 从请求头获取上游的 trace ID
        local upstream_traceid = tonumber(stream.header["x-trace-id"])

        if upstream_traceid then
            trace.attach(upstream_traceid)
            logger.info("Attached upstream trace")
        else
            trace.spawn()
            logger.info("Created new trace")
        end

        -- 处理业务逻辑
        local result = process_data()

        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #result,
        })
        stream:closewrite(result)
    end
}
```

### 示例 3: RPC 调用中的 trace 传播

```lua
local trace = require "silly.trace"
local cluster = require "silly.net.cluster"

-- cluster 模块会自动处理 trace 传播
-- 无需手动传递 trace ID

-- 服务 A: 调用方
-- 先连接到服务 B
local peer, err = cluster.connect("127.0.0.1:8989")
assert(peer, err)

-- 调用远程服务
local result = cluster.call(peer, "api.method", {arg1 = "xxx", arg2 = "YYY"})

-- 服务 B: 被调用方
-- trace ID 会自动传播，日志会自动包含正确的 trace ID
```

## 与日志系统集成

所有通过 `silly.logger` 输出的日志会自动包含当前协程的 trace ID：

```lua validate
local trace = require "silly.trace"
local logger = require "silly.logger.c"

trace.setnode(1)
trace.spawn()  -- 假设生成的 trace ID 是 0x1234567890ab0001

logger.info("Processing request")
-- 输出: 2025-12-04 10:30:45 1234567890ab0001 I Processing request
--                              ^^^^^^^^^^^^^^^^
--                              自动包含的 trace ID
```

## 最佳实践

### 1. 节点 ID 规划

```lua
-- 开发环境：1-100
-- 测试环境：101-200
-- 生产环境：1001-9999

-- 从环境变量或配置文件读取
local node_id = tonumber(os.getenv("NODE_ID")) or 1
trace.setnode(node_id)
```

### 2. HTTP 头标准化

```lua
-- 使用标准的 trace 头名称
local TRACE_HEADER = "x-trace-id"  -- 或 "x-b3-traceid"

-- 接收端（服务器）
local upstream_traceid = tonumber(stream.header[TRACE_HEADER])

-- 发送端（客户端）
local response = http.get("http://service-b:8080", {
    [TRACE_HEADER] = tostring(trace.propagate())
})
```

### 3. 错误处理

```lua
local function safe_attach_trace(traceid_str)
    local traceid = tonumber(traceid_str)
    if traceid and traceid > 0 then
        trace.attach(traceid)
        return true
    else
        -- 无效的 trace ID，创建新的
        trace.spawn()
        return false
    end
end
```

### 4. 协程边界注意事项

```lua
-- ⚠️ 注意：fork 的新协程不会自动继承 trace ID
-- 需要在外层先获取 trace ID，然后通过 task.fork 的第二个参数传入
local traceid = trace.propagate()

task.fork(function(received_traceid)
    -- 附加传入的 trace ID
    trace.attach(received_traceid)

    -- 现在可以正常追踪了
    do_work()
end, traceid)
```

## 相关文档

- [silly.task](./task.md) - 协程管理和任务调度
- [silly.net.cluster](./net/cluster.md) - RPC 集群通信（自动 trace 传播）
- [silly.logger](./logger.md) - 日志系统

## 参考

- [OpenTelemetry Trace Specification](https://opentelemetry.io/docs/specs/otel/trace/)
- [Distributed Tracing Best Practices](https://www.w3.org/TR/trace-context/)
