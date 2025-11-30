---
title: silly.trace
icon: route
category:
  - API Reference
tag:
  - Core
  - Distributed Tracing
  - Observability
---

# silly.trace

Distributed tracing module for cross-service request tracking and call chain tracing.

> 💡 **Tip**: The trace module depends on the [silly.task](./task.md) module. Each coroutine can be associated with a trace ID for full-chain tracing.

## Module Import

```lua validate
local trace = require "silly.trace"
```

## Core Concepts

### Trace ID Structure

A trace ID is a 64-bit integer composed of two parts:

```
┌─────────────────────────────┬──────────────┐
│   Root Trace (48 bits)      │ Node (16 bits)│
│   Globally unique trace root│   Node ID      │
└─────────────────────────────┴──────────────┘
```

- **Root Trace (high 48 bits)**: Globally unique trace root ID that identifies a complete request chain
- **Node ID (low 16 bits)**: Current service node ID (range 0-65535)

### Use Cases

- **Microservice Call Chain Tracing**: Track request propagation path across multiple services
- **Log Correlation**: Automatically attach trace ID to logs for aggregation and retrieval
- **Performance Analysis**: Identify slow requests and performance bottlenecks
- **Troubleshooting**: Quickly locate root causes in distributed systems

## API Reference

### trace.setnode(nodeid)

Set the node ID of the current service node for trace ID generation.

- **Parameters**:
  - `nodeid`: `integer` - Node ID (16-bit, range 0-65535)
- **Description**:
  - Typically called once at service startup
  - Each service instance should have a unique node ID
  - Node ID will be embedded in all subsequently generated trace IDs
- **Example**:

```lua validate
local trace = require "silly.trace"

-- Set node ID at service startup
trace.setnode(1001)  -- Set as node 1001
```

### trace.spawn()

Create a new root trace ID and set it as the current coroutine's trace ID.

- **Returns**: `integer` - Previous trace ID (can be used for later restoration)
- **Description**:
  - Used to start a new tracing chain (e.g., handling a new HTTP request)
  - Generates a globally unique root trace ID
  - Automatically includes the current node's node ID
- **Example**:

```lua validate
local trace = require "silly.trace"
local http = require "silly.net.http"

local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        -- Create new trace ID for each new request
        local old_trace = trace.spawn()

        -- Process request...
        handle_request(stream)

        -- Restore old trace context if needed (rare)
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

Set the current coroutine's trace ID to attach to an existing tracing chain.

- **Parameters**:
  - `id`: `integer` - Trace ID to attach
- **Returns**: `integer` - Previous trace ID
- **Description**:
  - Used to receive trace ID from upstream services
  - Implements cross-service tracing chain propagation
- **Example**:

```lua validate
local trace = require "silly.trace"

-- Get upstream trace ID from HTTP request header
local function handle_downstream_request(req)
    local upstream_traceid = tonumber(req.header["X-Trace-ID"])

    if upstream_traceid then
        -- Attach upstream trace ID to continue tracing chain
        trace.attach(upstream_traceid)
    else
        -- No upstream trace, create new one
        trace.spawn()
    end

    -- Subsequent logs will include this trace ID
end
```

### trace.propagate()

Get trace ID for cross-service propagation.

- **Returns**: `integer` - Trace ID for propagation
- **Description**:
  - Preserves original root trace ID (high 48 bits)
  - Replaces node ID with current node's ID (low 16 bits)
  - Used to pass trace ID to downstream services
- **Example**:

```lua validate
local trace = require "silly.trace"
local http = require "silly.net.http"

-- Propagate trace ID when calling downstream service
local function call_downstream_service()
    -- Get trace ID to propagate
    local traceid = trace.propagate()

    -- Pass it in HTTP request header
    local resp = http.get("http://service-b:8080/api", {
        headers = {
            ["X-Trace-ID"] = tostring(traceid)
        }
    })

    return resp
end
```

## Complete Examples

### Example 1: HTTP Microservice Entry Point

```lua validate
local trace = require "silly.trace"
local http = require "silly.net.http"
local logger = require "silly.logger.c"

-- Set node ID at service startup
trace.setnode(1)

local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        -- Create trace for each new request
        trace.spawn()

        logger.info("Received request:", stream.path)

        -- Call downstream service
        local traceid = trace.propagate()
        local result = call_service_b(traceid)

        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #result,
        })
        stream:write(result)
    end
}
```

### Example 2: Downstream Service Receiving Trace

```lua validate
local trace = require "silly.trace"
local http = require "silly.net.http"
local logger = require "silly.logger.c"

-- Set node ID at service startup (different from upstream)
trace.setnode(2)

local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        -- Get upstream trace ID from request header
        local upstream_traceid = tonumber(stream.header["x-trace-id"])

        if upstream_traceid then
            trace.attach(upstream_traceid)
            logger.info("Attached upstream trace")
        else
            trace.spawn()
            logger.info("Created new trace")
        end

        -- Process business logic
        local result = process_data()

        stream:respond(200, {
            ["content-type"] = "application/json",
            ["content-length"] = #result,
        })
        stream:closewrite(result)
    end
}
```

### Example 3: Trace Propagation in RPC Calls

```lua validate
local trace = require "silly.trace"
local cluster = require "silly.net.cluster"

-- cluster module automatically handles trace propagation
-- No need to manually pass trace ID

-- Service A: Caller
-- First connect to service B
local peer, err = cluster.connect("127.0.0.1:8989")
assert(peer, err)

-- Call remote service
local result = cluster.call(peer, "api.method", {arg1 = "xxx", arg2 = "YYY"})

-- Service B: Callee
-- Trace ID is automatically propagated, logs will include correct trace ID
```

## Integration with Logging System

All logs output through `silly.logger` automatically include the current coroutine's trace ID:

```lua validate
local trace = require "silly.trace"
local logger = require "silly.logger.c"

trace.setnode(1)
trace.spawn()  -- Assume generated trace ID is 0x1234567890ab0001

logger.info("Processing request")
-- Output: 2025-12-04 10:30:45 1234567890ab0001 I Processing request
--                              ^^^^^^^^^^^^^^^^
--                              Automatically included trace ID
```

## Best Practices

### 1. Node ID Planning

```lua
-- Development: 1-100
-- Testing: 101-200
-- Production: 1001-9999

-- Read from environment variable or config file
local node_id = tonumber(os.getenv("NODE_ID")) or 1
trace.setnode(node_id)
```

### 2. HTTP Header Standardization

```lua
-- Use standard trace header name
local TRACE_HEADER = "x-trace-id"  -- or "x-b3-traceid"

-- Receiver side (server)
local upstream_traceid = tonumber(stream.header[TRACE_HEADER])

-- Sender side (client)
local response = http.get("http://service-b:8080", {
    [TRACE_HEADER] = tostring(trace.propagate())
})
```

### 3. Error Handling

```lua
local function safe_attach_trace(traceid_str)
    local traceid = tonumber(traceid_str)
    if traceid and traceid > 0 then
        trace.attach(traceid)
        return true
    else
        -- Invalid trace ID, create new one
        trace.spawn()
        return false
    end
end
```

### 4. Coroutine Boundary Considerations

```lua
-- ⚠️ Note: Forked coroutines do not automatically inherit trace ID
-- Get trace ID in outer scope, then pass via task.fork's second parameter
local traceid = trace.propagate()

task.fork(function(received_traceid)
    -- Attach the received trace ID
    trace.attach(received_traceid)

    -- Now can trace normally
    do_work()
end, traceid)
```

## Related Documentation

- [silly.task](./task.md) - Coroutine management and task scheduling
- [silly.net.cluster](./net/cluster.md) - RPC cluster communication (automatic trace propagation)
- [silly.logger](./logger.md) - Logging system

## References

- [OpenTelemetry Trace Specification](https://opentelemetry.io/docs/specs/otel/trace/)
- [Distributed Tracing Best Practices](https://www.w3.org/TR/trace-context/)
