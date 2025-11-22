---
title: silly.metrics.counter
description: Prometheus-style counter metric API
category: reference
---

# silly.metrics.counter

::: info Module Description
`silly.metrics.counter` provides Prometheus-style Counter metric type. Counter is a cumulative metric that can only increase, representing a monotonically increasing counter, such as total requests, total errors, or completed tasks. Counter values can only increase or reset to zero (on restart).
:::

## Overview

Counter is one of the simplest metric types in the Prometheus monitoring system. It's suitable for the following scenarios:

- **Request Counting**: Track total HTTP requests, RPC calls, database queries, etc.
- **Error Statistics**: Record cumulative errors, exceptions, and timeouts
- **Task Statistics**: Track completed tasks, processed messages, etc.
- **Resource Usage**: Accumulate sent/received bytes, processed records, etc.

Key characteristics of Counter:

1. **Monotonically Increasing**: Values can only increase, never decrease (except on restart)
2. **Cumulative Statistics**: Records cumulative values from startup to present
3. **Rate Calculation**: Prometheus queries can calculate growth rate (e.g., QPS)
4. **Label Support**: Supports multi-dimensional labels for fine-grained statistics

## Core Concepts

### Counter Types

The module provides two types of Counters:

1. **Simple Counter**: Counter without labels
   - Directly call `inc()` or `add()` methods
   - Suitable for global statistics

2. **Counter Vector**: Counter with labels
   - Must call `labels()` first to select label combination
   - Suitable for multi-dimensional statistics (e.g., by status code, user type)

### Label Mechanism

Labels enable multi-dimensional monitoring:

```lua
local counter = require "silly.metrics.counter"
local vec = counter("http_requests_total", "Total HTTP requests", {"method", "status"})

-- Different label combinations represent different time series
vec:labels("GET", "200"):inc()    -- GET request success
vec:labels("POST", "500"):inc()   -- POST request failure
```

Each label combination creates an independent counter instance, which Prometheus automatically aggregates and queries.

### Best Practices

1. **Naming Convention**: Use `_total` suffix for cumulative values (e.g., `requests_total`)
2. **Unit Description**: Clearly specify units in help text (count, bytes, etc.)
3. **Avoid Decrementing**: Never attempt to decrease a Counter value
4. **Label Cardinality**: Control label value ranges to avoid creating too many time series
5. **Initial Value**: Counters automatically initialize to 0, no manual setup needed

## API Reference

### counter()

Create a new Counter metric.

```lua
local counter = require "silly.metrics.counter"
local c = counter(name, help, labelnames)
```

**Parameters:**

- `name` (string): Metric name, must follow Prometheus naming convention (`[a-zA-Z_:][a-zA-Z0-9_:]*`)
- `help` (string): Metric description text explaining the metric's purpose
- `labelnames` (string[]?): Optional array of label names, creates Counter Vector

**Returns:**

- Without `labelnames`: Returns `silly.metrics.counter` object (Simple Counter)
- With `labelnames`: Returns `silly.metrics.countervec` object (Counter Vector)

**Example:**

```lua validate
local counter = require "silly.metrics.counter"

-- Create simple Counter
local total = counter("app_requests_total", "Total application requests")

-- Create Counter Vector with labels
local errors = counter("app_errors_total", "Total errors by type", {"error_type"})
```

---

### inc()

Increment the Counter value by 1.

```lua
counter:inc()
```

**Parameters:** None

**Returns:** None

**Example:**

```lua validate
local counter = require "silly.metrics.counter"
local requests = counter("requests_total", "Total requests")

-- Increment on each request
requests:inc()
requests:inc()
requests:inc()
-- Now requests.value == 3
```

---

### add()

Increment the Counter value by a specified amount.

```lua
counter:add(v)
```

**Parameters:**

- `v` (number): Value to add, must be >= 0 (non-negative)

**Returns:** None

**Errors:**

- If `v < 0`, throws assertion error: "Counter can only increase"

**Example:**

```lua validate
local counter = require "silly.metrics.counter"
local bytes_sent = counter("network_bytes_sent_total", "Total bytes sent")

-- Accumulate bytes after sending data
bytes_sent:add(1024)   -- Send 1KB
bytes_sent:add(2048)   -- Send 2KB
-- Now bytes_sent.value == 3072

-- Incorrect usage (will throw exception):
-- bytes_sent:add(-100)  -- Cannot pass negative value
```

---

### labels()

Select a counter instance for a specific label combination in a Counter Vector.

```lua
local sub_counter = countervec:labels(...)
```

**Parameters:**

- `...` (string|number): Label values, count must match `labelnames` from creation

**Returns:**

- `silly.metrics.countersub`: Counter instance for the label combination, supports `inc()` or `add()` calls

**Notes:**

- First call creates a new instance (value initialized to 0)
- Subsequent calls with same label combination return the same instance
- Label value order must match `labelnames` definition order

**Example:**

```lua validate
local counter = require "silly.metrics.counter"
local requests = counter("http_requests_total", "Total HTTP requests", {"method", "status"})

-- Categorize statistics by method and status
requests:labels("GET", "200"):inc()
requests:labels("GET", "404"):inc()
requests:labels("POST", "200"):inc()
requests:labels("GET", "200"):inc()  -- Reuse previously created instance

-- Each label combination has independent counter:
-- http_requests_total{method="GET",status="200"} = 2
-- http_requests_total{method="GET",status="404"} = 1
-- http_requests_total{method="POST",status="200"} = 1
```

---

### collect()

Collect the Counter's current value for Prometheus format output.

```lua
counter:collect(buf)
```

**Parameters:**

- `buf` (silly.metrics.metric[]): Array for collecting metrics

**Returns:** None

**Note:**

- This is an internal API, usually called automatically by `silly.metrics.prometheus.gather()`
- Normal user code doesn't need to call this method directly

---

## Usage Examples

### Example 1: Simple Request Counting

Track total application requests.

```lua validate
local counter = require "silly.metrics.counter"

-- Create request counter
local requests_total = counter("app_requests_total", "Total application requests")

-- Simulate request handling
local function handle_request()
    requests_total:inc()
    -- ... business logic processing ...
end

-- Process multiple requests
for i = 1, 100 do
    handle_request()
end

-- Current count: requests_total.value == 100
```

---

### Example 2: HTTP Status Code Statistics

Track requests by HTTP status code.

```lua validate
local counter = require "silly.metrics.counter"

local http_requests = counter(
    "http_requests_total",
    "Total HTTP requests by status code",
    {"status"}
)

-- Simulate HTTP request handling
local function handle_http_request(status_code)
    http_requests:labels(tostring(status_code)):inc()
end

-- Handle various status code requests
handle_http_request(200)  -- Success
handle_http_request(200)
handle_http_request(404)  -- Not found
handle_http_request(500)  -- Server error
handle_http_request(200)

-- Results:
-- http_requests_total{status="200"} = 3
-- http_requests_total{status="404"} = 1
-- http_requests_total{status="500"} = 1
```

---

### Example 3: Multi-dimensional Error Statistics

Track errors by type and service module.

```lua validate
local counter = require "silly.metrics.counter"

local errors_total = counter(
    "service_errors_total",
    "Total errors by type and module",
    {"module", "error_type"}
)

-- Simulate errors from different modules
local function report_error(module, error_type)
    errors_total:labels(module, error_type):inc()
end

-- Record various errors
report_error("database", "timeout")
report_error("database", "connection_failed")
report_error("cache", "timeout")
report_error("database", "timeout")
report_error("api", "invalid_request")

-- Results:
-- service_errors_total{module="database",error_type="timeout"} = 2
-- service_errors_total{module="database",error_type="connection_failed"} = 1
-- service_errors_total{module="cache",error_type="timeout"} = 1
-- service_errors_total{module="api",error_type="invalid_request"} = 1
```

---

### Example 4: Traffic Statistics (Bytes)

Track total bytes sent and received over network.

```lua validate
local counter = require "silly.metrics.counter"

local bytes_sent = counter("network_bytes_sent_total", "Total bytes sent over network")
local bytes_received = counter("network_bytes_received_total", "Total bytes received from network")

-- Simulate data transmission
local function send_data(size)
    bytes_sent:add(size)
end

local function receive_data(size)
    bytes_received:add(size)
end

-- Transfer data
send_data(1024)      -- Send 1KB
receive_data(2048)   -- Receive 2KB
send_data(512)       -- Send 512B
receive_data(4096)   -- Receive 4KB

-- Statistics results:
-- network_bytes_sent_total = 1536 bytes
-- network_bytes_received_total = 6144 bytes
```

---

### Example 5: Game Server Event Statistics

Track various player events in game server.

```lua validate
local counter = require "silly.metrics.counter"

local player_events = counter(
    "game_player_events_total",
    "Total player events by type",
    {"event_type"}
)

local battle_results = counter(
    "game_battle_results_total",
    "Total battle results",
    {"result"}
)

-- Simulate player events
local function track_event(event_type)
    player_events:labels(event_type):inc()
end

local function track_battle(result)
    battle_results:labels(result):inc()
end

-- Record events
track_event("login")
track_event("logout")
track_event("login")
track_event("purchase")
track_event("login")

track_battle("win")
track_battle("lose")
track_battle("win")
track_battle("draw")

-- Results:
-- game_player_events_total{event_type="login"} = 3
-- game_player_events_total{event_type="logout"} = 1
-- game_player_events_total{event_type="purchase"} = 1
-- game_battle_results_total{result="win"} = 2
-- game_battle_results_total{result="lose"} = 1
-- game_battle_results_total{result="draw"} = 1
```

---

### Example 6: Task Processing Statistics

Track completed and failed async tasks.

```lua validate
local counter = require "silly.metrics.counter"

local tasks_completed = counter(
    "tasks_completed_total",
    "Total completed tasks by priority",
    {"priority"}
)

local tasks_failed = counter(
    "tasks_failed_total",
    "Total failed tasks by reason",
    {"reason"}
)

-- Simulate task processing
local function complete_task(priority)
    tasks_completed:labels(priority):inc()
end

local function fail_task(reason)
    tasks_failed:labels(reason):inc()
end

-- Process tasks
complete_task("high")
complete_task("normal")
complete_task("high")
complete_task("low")
fail_task("timeout")
fail_task("error")
fail_task("timeout")

-- Results:
-- tasks_completed_total{priority="high"} = 2
-- tasks_completed_total{priority="normal"} = 1
-- tasks_completed_total{priority="low"} = 1
-- tasks_failed_total{reason="timeout"} = 2
-- tasks_failed_total{reason="error"} = 1
```

---

### Example 7: API Call Tracing

Track API calls between microservices.

```lua validate
local counter = require "silly.metrics.counter"

local api_calls = counter(
    "api_calls_total",
    "Total API calls between services",
    {"source", "target", "method"}
)

-- Simulate service-to-service calls
local function call_service(source, target, method)
    api_calls:labels(source, target, method):inc()
end

-- Record service calls
call_service("gateway", "user-service", "GetUser")
call_service("gateway", "order-service", "CreateOrder")
call_service("order-service", "payment-service", "ProcessPayment")
call_service("gateway", "user-service", "GetUser")
call_service("user-service", "cache-service", "Get")

-- Results:
-- api_calls_total{source="gateway",target="user-service",method="GetUser"} = 2
-- api_calls_total{source="gateway",target="order-service",method="CreateOrder"} = 1
-- api_calls_total{source="order-service",target="payment-service",method="ProcessPayment"} = 1
-- api_calls_total{source="user-service",target="cache-service",method="Get"} = 1
```

---

### Example 8: Prometheus Integration

Complete example: Create Counter and expose metrics via HTTP.

```lua validate
local counter = require "silly.metrics.counter"
local prometheus = require "silly.metrics.prometheus"
local http = require "silly.net.http"

-- Note: Directly requiring counter module only creates standalone counters
-- To register in Prometheus, use prometheus.counter()

-- Create counter registered via prometheus
local requests_total = prometheus.counter(
    "app_requests_total",
    "Total requests",
    {"path"}
)

local errors_total = prometheus.counter(
    "app_errors_total",
    "Total errors",
    {"type"}
)

-- Simulate request handling
local function handle_request(path)
    requests_total:labels(path):inc()
end

local function handle_error(error_type)
    errors_total:labels(error_type):inc()
end

-- Record some metrics
handle_request("/api/users")
handle_request("/api/orders")
handle_request("/api/users")
handle_error("timeout")

-- Start Prometheus metrics server
local server = http.listen {
    addr = "127.0.0.1:9090",
    handler = function(stream)
        if stream.path == "/metrics" then
            local metrics_data = prometheus.gather()
            stream:respond(200, {
                ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
                ["content-length"] = #metrics_data,
            })
            stream:close(metrics_data)
        else
            stream:respond(404)
            stream:close("Not Found")
        end
    end
}

-- Visit http://127.0.0.1:9090/metrics to view metrics
-- Output format:
-- # HELP app_requests_total Total requests
-- # TYPE app_requests_total counter
-- app_requests_total{path="/api/users"} 2
-- app_requests_total{path="/api/orders"} 1
-- # HELP app_errors_total Total errors
-- # TYPE app_errors_total counter
-- app_errors_total{type="timeout"} 1
```

---

## Important Notes

### 1. Counters Can Only Increase

Counter is designed to be monotonically increasing; attempting to decrease values breaks Prometheus rate calculation logic.

```lua
-- ❌ Wrong: Cannot decrement Counter
local counter = require "silly.metrics.counter"
local c = counter("test", "test counter")
c:add(-10)  -- Will throw error: Counter can only increase
```

If you need a metric that can increase and decrease, use `silly.metrics.gauge`.

---

### 2. Label Cardinality Control

Each unique label combination creates an independent time series. Too many label values lead to:

- Increased memory usage
- Slower Prometheus queries
- Higher storage costs

```lua
-- ❌ Bad: user_id has millions of possible values
local counter = require "silly.metrics.counter"
local logins = counter("user_logins_total", "User logins", {"user_id"})
logins:labels("user_12345"):inc()  -- Creates one time series per user

-- ✅ Good: Use finite categorical labels
local logins_by_type = counter("user_logins_total", "User logins", {"user_type"})
logins_by_type:labels("vip"):inc()      -- Only a few user types
logins_by_type:labels("normal"):inc()
```

**Recommendation**: Keep unique label combinations in the thousands to tens of thousands range.

---

### 3. Label Order Must Be Consistent

When calling `labels()`, parameter order must match the `labelnames` from creation.

```lua
local counter = require "silly.metrics.counter"
local requests = counter("requests_total", "Requests", {"method", "status"})

-- ✅ Correct: Order matches labelnames
requests:labels("GET", "200"):inc()

-- ❌ Wrong: Order reversed (creates different time series)
requests:labels("200", "GET"):inc()  -- Actually {method="200", status="GET"}
```

---

### 4. Naming Conventions

Follow Prometheus official naming best practices:

- Use lowercase letters and underscores
- Prefix with application or library name (e.g., `myapp_`)
- Counters use `_total` suffix
- Include units (e.g., `_bytes`, `_seconds`)

```lua
local counter = require "silly.metrics.counter"

-- ✅ Good naming
local good1 = counter("myapp_requests_total", "Total requests")
local good2 = counter("myapp_bytes_sent_total", "Total bytes sent")

-- ❌ Bad naming
local bad1 = counter("requestCount", "Requests")  -- Uses camelCase
local bad2 = counter("requests", "Requests")      -- Missing _total suffix
```

---

### 5. Register via prometheus.counter()

To expose metrics in Prometheus, use `silly.metrics.prometheus.counter()` instead of directly `require "silly.metrics.counter"`:

```lua
-- ❌ Won't automatically register in Prometheus
local counter = require "silly.metrics.counter"
local c1 = counter("test_total", "Test counter")

-- ✅ Automatically registers in global registry
local prometheus = require "silly.metrics.prometheus"
local c2 = prometheus.counter("test_total", "Test counter")
```

Counters created directly with `silly.metrics.counter` won't appear in `prometheus.gather()` output unless manually registered to registry.

---

### 6. Avoid Creating New Labels in Hot Path

`labels()` first call creates a new instance. Although cached, it's recommended to pre-warm common label combinations:

```lua
local counter = require "silly.metrics.counter"
local requests = counter("requests_total", "Requests", {"status"})

-- ✅ Pre-create common label combinations during initialization
requests:labels("200")
requests:labels("404")
requests:labels("500")

-- Subsequent calls hit cache for better performance
```

---

### 7. Thread Safety

Silly framework uses single-threaded Worker model with all business logic executing in the same thread, so Counter operations are thread-safe without additional locking.

---

### 8. Values Reset After Restart

Counter values are stored in memory and reset to 0 after process restart. This is normal behavior; Prometheus automatically detects and handles Counter resets.

---

## Related APIs

- [silly.metrics.prometheus](./prometheus.md) - Prometheus metrics integration
- [silly.metrics.gauge](./gauge.md) - Gauge metric for values that can increase and decrease
- [silly.metrics.histogram](./histogram.md) - Histogram metric (distribution statistics)
- [silly.net.http](../net/http.md) - HTTP server (for exposing /metrics endpoint)

---

## References

- [Prometheus Counter Official Documentation](https://prometheus.io/docs/concepts/metric_types/#counter)
- [Prometheus Naming Best Practices](https://prometheus.io/docs/practices/naming/)
- [Prometheus Data Model](https://prometheus.io/docs/concepts/data_model/)
