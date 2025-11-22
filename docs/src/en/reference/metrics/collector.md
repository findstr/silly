---
title: silly.metrics.collector
description: Prometheus metric collector interface and implementation
category: reference
---

# silly.metrics.collector

::: info Module Description
`silly.metrics.collector` defines the interface protocol for Prometheus metric collectors. Collector is an abstract concept used to dynamically generate metric data during each metric collection. By implementing the Collector interface, you can customize complex metric collection logic, supporting runtime statistics, system resource monitoring, and other scenarios.
:::

## Overview

Collector is the core abstraction in the Prometheus monitoring system, used to generate metric data on demand. Unlike static metrics like Counter, Gauge, and Histogram, Collectors dynamically execute collection logic each time the `/metrics` endpoint is accessed.

### Why Do We Need Collectors?

In the following scenarios, Collectors are more appropriate than static metrics:

1. **System resource monitoring**: Collect CPU, memory, network, and other system-level metrics
2. **Runtime statistics**: Query internal process state (like task queue length, connection pool status)
3. **Batch metric generation**: Generate multiple related metrics in one collection
4. **Performance optimization**: Avoid real-time metric update performance overhead, calculate during collection
5. **External data sources**: Read metrics from databases, configuration centers, and other external sources

### Silly Built-in Collectors

The framework automatically registers the following Collectors (no manual creation needed):

- **silly.metrics.collector.silly**: Framework runtime statistics (task queue, timers, network connections)
- **silly.metrics.collector.process**: Process resource monitoring (CPU, memory)
- **silly.metrics.collector.jemalloc**: jemalloc memory allocator statistics (requires compile-time enabling)

## Core Concepts

### Collector Protocol

A Collector is a Lua table implementing the following interface:

```lua
---@class silly.metrics.collector
---@field name string                    -- Collector name (for identification)
---@field new fun(): silly.metrics.collector    -- Constructor
---@field collect fun(self: silly.metrics.collector, buf: silly.metrics.metric[])  -- Collection method
```

**Protocol requirements**:

1. **name field**: String type, identifies the Collector name
2. **new() method**: Returns a new Collector instance
3. **collect() method**: Executes metric collection, appending generated metric objects to the `buf` array

### Collection Process

When Prometheus requests the `/metrics` endpoint, the flow is:

```
1. prometheus.gather() is called
2. registry:collect() iterates through all registered Collectors
3. Each Collector's collect(buf) is called
4. Collector appends metric objects to buf array
5. prometheus formats all metrics in buf to text output
```

### Collector vs Static Metrics

| Feature           | Static Metrics (Counter/Gauge) | Collector                |
|-------------------|-------------------------------|--------------------------|
| Update timing     | Real-time on event           | On-demand during collection |
| Memory usage      | Continuously occupies memory  | Temporarily created during collection |
| Performance overhead | Slight overhead on updates  | Computation overhead during collection |
| Use cases         | High-frequency events, cumulative stats | System state, batch metrics |
| Data persistence  | Retains historical cumulative values | Recalculated each time |

### Metric Object Structure

The `collect()` method needs to append metric objects to the `buf` array. Metric objects can be:

- `silly.metrics.counter`: Counter metric
- `silly.metrics.gauge`: Gauge metric
- `silly.metrics.histogram`: Histogram metric

These objects must contain the following fields:

```lua
{
    name = "metric_name",
    help = "metric_description",
    kind = "counter" | "gauge" | "histogram",
    value = number,         -- Value for simple metrics
    metrics = {...}         -- Multiple label combinations for Vector types (optional)
}
```

## API Reference

### Collector Interface

#### name

The Collector's name, used for identification and debugging.

```lua
collector.name: string
```

**Example:**

```lua validate
local M = {}

function M.new()
    local collector = {
        name = "MyCustomCollector",  -- Set name
        new = M.new,
        collect = function(self, buf)
            -- Collection logic
        end,
    }
    return collector
end
```

---

#### new()

Creates a new Collector instance.

```lua
function collector.new(): silly.metrics.collector
```

**Returns:**

- `silly.metrics.collector`: Newly created Collector instance

**Implementation requirements:**

- Must return a table containing `name`, `new`, `collect` fields
- Can initialize internal state in the instance (like caches, counters, etc.)

**Example:**

```lua validate
local gauge = require "silly.metrics.gauge"

local M = {}
M.__index = M

function M.new()
    -- Create metric objects in constructor
    local active_tasks = gauge("active_tasks", "Number of active tasks")

    local collector = {
        name = "TaskCollector",
        new = M.new,
        collect = function(self, buf)
            -- Dynamically get task count and update metric
            local count = 42  -- Should actually read from system state
            active_tasks:set(count)
            buf[#buf + 1] = active_tasks
        end,
    }
    return collector
end
```

---

#### collect()

Executes metric collection, appending generated metric objects to the `buf` array.

```lua
function collector:collect(buf: silly.metrics.metric[])
```

**Parameters:**

- `buf` (silly.metrics.metric[]): Array for collecting metrics, append generated metrics to the end of this array

**Returns:** None

**Implementation requirements:**

1. Read latest state from system, runtime, or external data sources
2. Update or create metric objects
3. Use `buf[#buf + 1] = metric` to append metrics to array
4. Don't modify existing elements in `buf`
5. Can append multiple metrics

**Example:**

```lua validate
local gauge = require "silly.metrics.gauge"

local M = {}

function M.new()
    -- Create multiple metrics
    local cpu_usage = gauge("cpu_usage_percent", "CPU usage percentage")
    local memory_usage = gauge("memory_usage_bytes", "Memory usage in bytes")

    local collector = {
        name = "SystemCollector",
        new = M.new,
        collect = function(self, buf)
            -- Dynamically collect system data
            cpu_usage:set(45.6)        -- Should read real CPU data
            memory_usage:set(1024000)  -- Should read real memory data

            -- Append multiple metrics
            local len = #buf
            buf[len + 1] = cpu_usage
            buf[len + 2] = memory_usage
        end,
    }
    return collector
end
```

---

### Registry API

#### registry:register()

Registers a Collector to the registry.

```lua
local prometheus = require "silly.metrics.prometheus"
local registry = prometheus.registry()

registry:register(collector)
```

**Parameters:**

- `collector` (silly.metrics.collector): Collector instance to register

**Returns:** None

**Notes:**

- Duplicate registration of the same instance has no effect (determined by object reference)
- After registration, the Collector's `collect()` is called on each `prometheus.gather()`

**Example:**

```lua validate
local prometheus = require "silly.metrics.prometheus"
local gauge = require "silly.metrics.gauge"

-- Create custom Collector
local M = {}
function M.new()
    local metric = gauge("my_metric", "My custom metric")
    return {
        name = "MyCollector",
        new = M.new,
        collect = function(self, buf)
            metric:set(100)
            buf[#buf + 1] = metric
        end,
    }
end

-- Register to global registry
local registry = prometheus.registry()
local my_collector = M.new()
registry:register(my_collector)

-- Now my_metric appears in prometheus.gather() output
```

---

#### registry:unregister()

Removes a Collector from the registry.

```lua
registry:unregister(collector)
```

**Parameters:**

- `collector` (silly.metrics.collector): Collector instance to remove

**Returns:** None

**Example:**

```lua validate
local prometheus = require "silly.metrics.prometheus"
local gauge = require "silly.metrics.gauge"

local M = {}
function M.new()
    local metric = gauge("temp_metric", "Temporary metric")
    return {
        name = "TempCollector",
        new = M.new,
        collect = function(self, buf)
            metric:set(50)
            buf[#buf + 1] = metric
        end,
    }
end

local registry = prometheus.registry()
local temp_collector = M.new()

-- Register
registry:register(temp_collector)

-- Remove when no longer needed
registry:unregister(temp_collector)
```

---

#### registry:collect()

Executes collection logic of all registered Collectors, returning all metrics.

```lua
local metrics = registry:collect()
```

**Returns:**

- `silly.metrics.metric[]`: Array containing all collected metrics

**Notes:**

- This is an internal API, typically called automatically by `prometheus.gather()`
- Normal user code doesn't need to call directly

**Example:**

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- Get global registry
local registry = prometheus.registry()

-- Manually trigger collection (usually not needed)
local metrics = registry:collect()

-- metrics is an array containing all metric objects
for i = 1, #metrics do
    local m = metrics[i]
    print(m.name, m.kind, m.value or "vector")
end
```

---

## Usage Examples

### Example 1: Simple Count Collector

Create a simple Collector that collects fixed values.

```lua validate
local gauge = require "silly.metrics.gauge"
local prometheus = require "silly.metrics.prometheus"

local SimpleCollector = {}

function SimpleCollector.new()
    -- Create metrics in constructor
    local uptime_metric = gauge("app_uptime_seconds", "Application uptime in seconds")
    local start_time = os.time()

    local collector = {
        name = "SimpleCollector",
        new = SimpleCollector.new,
        collect = function(self, buf)
            -- Calculate runtime on each collection
            local uptime = os.time() - start_time
            uptime_metric:set(uptime)
            buf[#buf + 1] = uptime_metric
        end,
    }
    return collector
end

-- Register to Prometheus
local registry = prometheus.registry()
local simple_collector = SimpleCollector.new()
registry:register(simple_collector)

-- Now app_uptime_seconds appears in /metrics output
-- Each /metrics access updates uptime value
```

---

### Example 2: Multi-Metric Collector

One Collector can generate multiple related metrics.

```lua validate
local gauge = require "silly.metrics.gauge"
local counter = require "silly.metrics.counter"
local prometheus = require "silly.metrics.prometheus"

local AppStatsCollector = {}

function AppStatsCollector.new()
    -- Create multiple metrics
    local active_users = gauge("app_active_users", "Number of active users")
    local total_requests = counter("app_total_requests", "Total requests processed")
    local queue_size = gauge("app_queue_size", "Message queue size")

    -- Simulate internal state
    local request_count = 0

    local collector = {
        name = "AppStatsCollector",
        new = AppStatsCollector.new,
        collect = function(self, buf)
            -- Simulate reading data from system state
            active_users:set(math.random(50, 200))
            queue_size:set(math.random(0, 100))

            -- Accumulate request count
            request_count = request_count + math.random(10, 50)
            total_requests.value = request_count

            -- Append multiple metrics
            local len = #buf
            buf[len + 1] = active_users
            buf[len + 2] = total_requests
            buf[len + 3] = queue_size
        end,
    }
    return collector
end

-- Register
local registry = prometheus.registry()
local app_stats = AppStatsCollector.new()
registry:register(app_stats)
```

---

### Example 3: Vector Collector with Labels

Collect multi-dimensional label metrics.

```lua validate
local gauge = require "silly.metrics.gauge"
local prometheus = require "silly.metrics.prometheus"

local PoolCollector = {}

function PoolCollector.new()
    -- Create labeled Gauge Vector
    local pool_connections = gauge(
        "pool_connections",
        "Number of connections in pool",
        {"pool_name", "state"}
    )

    local collector = {
        name = "PoolCollector",
        new = PoolCollector.new,
        collect = function(self, buf)
            -- Simulate multiple connection pool states
            local pools = {
                {name = "mysql", active = 10, idle = 5},
                {name = "redis", active = 20, idle = 15},
                {name = "postgres", active = 8, idle = 12},
            }

            for _, pool in ipairs(pools) do
                pool_connections:labels(pool.name, "active"):set(pool.active)
                pool_connections:labels(pool.name, "idle"):set(pool.idle)
            end

            buf[#buf + 1] = pool_connections
        end,
    }
    return collector
end

-- Register
local registry = prometheus.registry()
local pool_collector = PoolCollector.new()
registry:register(pool_collector)

-- Output example:
-- pool_connections{pool_name="mysql",state="active"} 10
-- pool_connections{pool_name="mysql",state="idle"} 5
-- pool_connections{pool_name="redis",state="active"} 20
-- pool_connections{pool_name="redis",state="idle"} 15
```

---

### Example 4: Cache Status Collector

Collect cache hit rate and other statistics.

```lua validate
local gauge = require "silly.metrics.gauge"
local counter = require "silly.metrics.counter"
local prometheus = require "silly.metrics.prometheus"

local CacheCollector = {}

function CacheCollector.new()
    -- Create metrics
    local cache_size = gauge("cache_entries", "Number of cached entries")
    local cache_hits = counter("cache_hits_total", "Total cache hits")
    local cache_misses = counter("cache_misses_total", "Total cache misses")
    local cache_hit_ratio = gauge("cache_hit_ratio", "Cache hit ratio (0-1)")

    -- Simulate internal cache state
    local cache = {}
    local hits = 0
    local misses = 0

    local collector = {
        name = "CacheCollector",
        new = CacheCollector.new,
        collect = function(self, buf)
            -- Simulate cache operations
            hits = hits + math.random(100, 200)
            misses = misses + math.random(10, 30)

            -- Calculate cache size
            local size = math.random(500, 1000)
            cache_size:set(size)

            -- Update counters
            cache_hits.value = hits
            cache_misses.value = misses

            -- Calculate hit ratio
            local total = hits + misses
            local ratio = total > 0 and (hits / total) or 0
            cache_hit_ratio:set(ratio)

            -- Append metrics
            local len = #buf
            buf[len + 1] = cache_size
            buf[len + 2] = cache_hits
            buf[len + 3] = cache_misses
            buf[len + 4] = cache_hit_ratio
        end,
    }
    return collector
end

-- Register
local registry = prometheus.registry()
local cache_collector = CacheCollector.new()
registry:register(cache_collector)
```

---

### Example 5: Task Queue Collector

Monitor async task queue status.

```lua validate
local gauge = require "silly.metrics.gauge"
local prometheus = require "silly.metrics.prometheus"

local QueueCollector = {}

function QueueCollector.new()
    -- Create queue-related metrics
    local queue_size = gauge(
        "queue_size",
        "Number of tasks in queue",
        {"priority"}
    )
    local queue_oldest_age = gauge(
        "queue_oldest_task_seconds",
        "Age of oldest task in queue (seconds)",
        {"priority"}
    )

    local collector = {
        name = "QueueCollector",
        new = QueueCollector.new,
        collect = function(self, buf)
            -- Simulate queue states at different priorities
            local queues = {
                {priority = "high", size = 5, oldest = 2},
                {priority = "normal", size = 20, oldest = 10},
                {priority = "low", size = 50, oldest = 30},
            }

            for _, q in ipairs(queues) do
                queue_size:labels(q.priority):set(q.size)
                queue_oldest_age:labels(q.priority):set(q.oldest)
            end

            local len = #buf
            buf[len + 1] = queue_size
            buf[len + 2] = queue_oldest_age
        end,
    }
    return collector
end

-- Register
local registry = prometheus.registry()
local queue_collector = QueueCollector.new()
registry:register(queue_collector)
```

---

### Example 6: External Data Source Collector

Read metric data from configuration files or databases.

```lua validate
local gauge = require "silly.metrics.gauge"
local prometheus = require "silly.metrics.prometheus"

local ConfigCollector = {}

function ConfigCollector.new()
    -- Create configuration-related metrics
    local config_version = gauge("config_version", "Current configuration version")
    local config_reload_time = gauge("config_last_reload_timestamp", "Last config reload timestamp")

    local collector = {
        name = "ConfigCollector",
        new = ConfigCollector.new,
        collect = function(self, buf)
            -- Simulate reading data from config source
            -- In real applications, read from files, etcd, consul, etc.
            local version = 123  -- Configuration version number
            local reload_time = os.time()  -- Last reload time

            config_version:set(version)
            config_reload_time:set(reload_time)

            local len = #buf
            buf[len + 1] = config_version
            buf[len + 2] = config_reload_time
        end,
    }
    return collector
end

-- Register
local registry = prometheus.registry()
local config_collector = ConfigCollector.new()
registry:register(config_collector)
```

---

### Example 7: Silly Framework Built-in Collector Example

See how the framework implements built-in Collectors (reference source code).

```lua validate
local gauge = require "silly.metrics.gauge"
local counter = require "silly.metrics.counter"

-- Simplified Silly framework Collector implementation
local SillyCollector = {}

function SillyCollector.new()
    -- Create framework internal metrics
    local worker_backlog = gauge(
        "silly_worker_backlog",
        "Number of pending messages in worker queue"
    )
    local tcp_connections = gauge(
        "silly_tcp_connections",
        "Number of active TCP connections"
    )
    local bytes_sent = counter(
        "silly_network_sent_bytes_total",
        "Total bytes sent via network"
    )

    local last_bytes_sent = 0

    local collector = {
        name = "SillyCollector",
        new = SillyCollector.new,
        collect = function(self, buf)
            -- Simulate reading statistics from C module
            -- Real implementation calls silly.metrics.c.workerstat() etc. C APIs
            local backlog = math.random(0, 50)
            local connections = math.random(10, 100)
            local current_bytes_sent = math.random(10000, 50000)

            -- Update Gauge metrics
            worker_backlog:set(backlog)
            tcp_connections:set(connections)

            -- Update Counter (calculate delta)
            if current_bytes_sent > last_bytes_sent then
                bytes_sent:add(current_bytes_sent - last_bytes_sent)
            end
            last_bytes_sent = current_bytes_sent

            -- Append metrics
            local len = #buf
            buf[len + 1] = worker_backlog
            buf[len + 2] = tcp_connections
            buf[len + 3] = bytes_sent
        end,
    }
    return collector
end

-- Framework auto-registers built-in Collectors, users don't need manual operation
```

---

### Example 8: Complete Integration Example

Create custom Collector and expose metrics via HTTP.

```lua validate
local gauge = require "silly.metrics.gauge"
local prometheus = require "silly.metrics.prometheus"
local http = require "silly.net.http"

-- Create business Collector
local BusinessCollector = {}

function BusinessCollector.new()
    local online_players = gauge("game_online_players", "Number of online players")
    local active_battles = gauge("game_active_battles", "Number of active battles")

    -- Simulate game state
    local player_count = 0

    local collector = {
        name = "BusinessCollector",
        new = BusinessCollector.new,
        collect = function(self, buf)
            -- Dynamically update player count
            player_count = math.random(100, 500)
            online_players:set(player_count)

            -- Battle count is approximately 20% of players
            active_battles:set(math.floor(player_count * 0.2))

            local len = #buf
            buf[len + 1] = online_players
            buf[len + 2] = active_battles
        end,
    }
    return collector
end

-- Register custom Collector
local registry = prometheus.registry()
local business_collector = BusinessCollector.new()
registry:register(business_collector)

-- Start HTTP server to expose metrics
local server = http.listen {
    addr = "127.0.0.1:9090",
    handler = function(stream)
        if stream.path == "/metrics" then
            -- Calling gather() triggers all Collectors' collect()
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

-- Access http://127.0.0.1:9090/metrics to view metrics
-- Output includes:
-- 1. Built-in Collector metrics (silly, process, jemalloc)
-- 2. Custom BusinessCollector metrics
```

---

## Important Notes

### 1. collect() Performance Overhead

`collect()` is called each time `/metrics` is accessed, should avoid executing time-consuming operations.

```lua
-- Error: Execute expensive operations in collect()
local collector = {
    collect = function(self, buf)
        -- ❌ Bad: Large file I/O
        local f = io.open("/large/file.log", "r")
        local content = f:read("*a")
        f:close()

        -- ❌ Bad: Complex computation
        for i = 1, 1000000 do
            -- Large computation
        end

        -- ❌ Bad: Network requests
        -- http.get("http://external-service/stats")
    end
}

-- Correct: Lightweight operations
local collector = {
    collect = function(self, buf)
        -- ✅ Good: Read in-memory state
        local count = get_cached_count()
        metric:set(count)
        buf[#buf + 1] = metric
    end
}
```

**Recommendation**: Move expensive operations to background tasks, `collect()` only reads cached results.

---

### 2. Metric Object Reuse

Create metric objects in `new()`, reuse them in `collect()`.

```lua
-- ❌ Error: Create new objects on each collect
local BadCollector = {}
function BadCollector.new()
    return {
        name = "BadCollector",
        new = BadCollector.new,
        collect = function(self, buf)
            -- Create new gauge object each collection (wastes memory)
            local g = gauge("my_metric", "My metric")
            g:set(100)
            buf[#buf + 1] = g
        end,
    }
end

-- ✅ Correct: Create in constructor, reuse in collect
local GoodCollector = {}
function GoodCollector.new()
    -- Create once, reuse many times
    local g = gauge("my_metric", "My metric")

    return {
        name = "GoodCollector",
        new = GoodCollector.new,
        collect = function(self, buf)
            g:set(100)  -- Only update value
            buf[#buf + 1] = g
        end,
    }
end
```

---

### 3. Avoid Modifying Existing Elements in buf

Only append new elements to `buf`, don't modify or delete existing elements.

```lua
local collector = {
    collect = function(self, buf)
        -- ❌ Error: Modify existing elements
        buf[1] = nil

        -- ❌ Error: Insert in middle
        table.insert(buf, 1, metric)

        -- ✅ Correct: Append to end
        buf[#buf + 1] = metric
    end
}
```

---

### 4. Counter Delta Calculation

For cumulative values (like byte counts), need to save last value and calculate delta.

```lua
local counter = require "silly.metrics.counter"

local MyCollector = {}
function MyCollector.new()
    local bytes_sent = counter("bytes_sent_total", "Total bytes sent")
    local last_value = 0  -- Save last cumulative value

    return {
        name = "MyCollector",
        new = MyCollector.new,
        collect = function(self, buf)
            -- Assume system returns cumulative total
            local current_value = get_system_bytes_sent()

            -- Calculate delta and update Counter
            if current_value > last_value then
                bytes_sent:add(current_value - last_value)
            end
            last_value = current_value

            buf[#buf + 1] = bytes_sent
        end,
    }
end
```

This is because Counter's `add()` is a cumulative operation, while system statistics typically return cumulative totals.

---

### 5. Built-in Collectors Auto-Register

Framework has auto-registered the following Collectors, no manual operation needed:

```lua
-- These Collectors auto-register when silly.metrics.prometheus module loads
-- Users don't need and shouldn't manually register

-- silly.metrics.collector.silly
-- silly.metrics.collector.process
-- silly.metrics.collector.jemalloc (only when compiled with jemalloc)
```

To disable built-in Collectors, can manually `unregister`:

```lua validate
local prometheus = require "silly.metrics.prometheus"
local silly_collector = require "silly.metrics.collector.silly"

local registry = prometheus.registry()

-- Remove built-in Silly Collector (not recommended)
-- Note: This requires access to the specific collector instance, usually not recommended
```

---

### 6. Label Consistency

Same metric name must maintain consistent label names across different collection periods.

```lua
-- ❌ Error: Inconsistent labels
local g = gauge("my_metric", "My metric", {"label1"})

-- First collection
g:labels("value1"):set(100)
buf[#buf + 1] = g

-- Second collection (error: changed label name)
g = gauge("my_metric", "My metric", {"label2"})  -- label2 differs from label1
g:labels("value2"):set(200)
buf[#buf + 1] = g

-- ✅ Correct: Keep label names consistent
local g = gauge("my_metric", "My metric", {"label1"})

-- Always use same label names
g:labels("value1"):set(100)
g:labels("value2"):set(200)
```

---

### 7. Exception Handling

Errors in `collect()` affect the entire metric collection process, should handle errors properly.

```lua
local collector = {
    collect = function(self, buf)
        -- ✅ Good: Catch exceptions to avoid collection failure
        local ok, err = pcall(function()
            local value = might_throw_error()
            metric:set(value)
            buf[#buf + 1] = metric
        end)

        if not ok then
            -- Log error
            print("Collector error:", err)
            -- Can set default value or skip this metric
        end
    end
}
```

---

### 8. Thread Safety

Silly uses single-threaded Worker model, business logic executes in the same thread. But `collect()` is synchronous call, should avoid blocking operations.

```lua
local collector = {
    collect = function(self, buf)
        -- ❌ Bad: Blocking network request
        -- local response = http.get("http://slow-service/stats")  -- Will block

        -- ✅ Good: Use background task to update cache, collect only reads cache
        local cached_stats = get_stats_from_cache()
        metric:set(cached_stats)
        buf[#buf + 1] = metric
    end
}
```

---

## See Also

- [silly.metrics.prometheus](./prometheus.md) - Prometheus metrics integration and formatting
- [silly.metrics.counter](./counter.md) - Counter metric
- [silly.metrics.gauge](./gauge.md) - Gauge metric
- [silly.metrics.histogram](./histogram.md) - Histogram metric
- [silly.net.http](../net/http.md) - HTTP server (for exposing /metrics endpoint)

## References

- [Prometheus Collector interface](https://prometheus.io/docs/instrumenting/writing_exporters/)
- [Prometheus client best practices](https://prometheus.io/docs/practices/instrumentation/)
- [Prometheus data model](https://prometheus.io/docs/concepts/data_model/)
