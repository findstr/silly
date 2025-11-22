---
title: gauge
icon: tachometer-alt
category:
  - API Reference
tag:
  - metrics
  - gauge
  - monitoring
---

# silly.metrics.gauge

Gauge metric module provides monitoring functionality for values that can increase and decrease, suitable for tracking current state and dynamically changing values.

## Module Overview

`silly.metrics.gauge` module implements the Prometheus Gauge metric type, used to represent values that can arbitrarily go up and down. Unlike Counter (which only increases), Gauge is suitable for recording instantaneous states such as:

- **System Resources**: Current memory usage, CPU usage, disk space
- **Network Connections**: Active connections, WebSocket connections, database connection pool status
- **Queue Status**: Message queue length, task queue depth
- **Business Metrics**: Online user count, inventory quantity, temperature sensor readings

Gauge supports setting values directly (`set()`), incrementing/decrementing (`inc()`/`dec()`), and adding/subtracting specific amounts (`add()`/`sub()`), providing flexible state management capabilities.

## Module Import

```lua validate
local gauge = require "silly.metrics.gauge"

-- Create a simple Gauge without labels
local temperature = gauge("room_temperature_celsius", "Room temperature")
temperature:set(25.5)
temperature:inc()  -- 26.5
temperature:dec()  -- 25.5

-- Create a GaugeVec with labels
local connections = gauge("active_connections", "Active connections", {"protocol", "state"})
connections:labels("http", "established"):set(42)
connections:labels("websocket", "established"):set(15)

print("Temperature:", temperature.value)
print("HTTP connections:", connections:labels("http", "established").value)
```

::: tip Standalone Usage
`gauge` must be imported separately via `require "silly.metrics.gauge"` and cannot be accessed directly through `prometheus.gauge()`. If you need automatic registration to Prometheus Registry, use `prometheus.gauge()`.
:::

## Core Concepts

### Gauge vs Counter

Understanding the difference between Gauge and Counter is key to using monitoring metrics correctly:

| Feature | Gauge | Counter |
|---------|-------|---------|
| **Value Changes** | Can increase and decrease | Only increases |
| **Represents** | Current state/instantaneous value | Cumulative total |
| **Typical Scenarios** | Memory usage, connections | Total requests, total errors |
| **Supported Operations** | set, inc, dec, add, sub | inc, add |
| **PromQL Queries** | Display current value directly | Usually use rate() to calculate rate |

**Selection Principle**:
- If resetting to zero after restart makes sense (e.g., connection count), use **Gauge**
- If you need to count total event occurrences, use **Counter**
- If you need to calculate rate of change (e.g., QPS), use **Counter** + `rate()`

### Label System

Labels are used to create multiple dimensional time series for the same metric:

```lua validate
local gauge = require "silly.metrics.gauge"

-- Create Gauge with two labels
local memory_usage = gauge(
    "memory_usage_bytes",
    "Memory usage by type and pool",
    {"type", "pool"}
)

-- Different label combinations represent different time series
memory_usage:labels("heap", "default"):set(1024 * 1024 * 100)
memory_usage:labels("heap", "large"):set(1024 * 1024 * 50)
memory_usage:labels("stack", "default"):set(1024 * 1024 * 10)

-- Each label combination is an independent Gauge instance
print(memory_usage:labels("heap", "default").value)  -- 104857600
```

**Important Constraints**:
- Label order must match creation order
- Label values should be finite, predictable categories
- Avoid using high-cardinality values (e.g., user IDs, timestamps) as labels

### Gauge Internal State

Each Gauge instance maintains a simple numeric field:

```lua
{
    name = "gauge_name",      -- Metric name
    help = "description",     -- Description text
    kind = "gauge",           -- Type identifier
    value = 0,                -- Current value (initialized to 0)
}
```

For GaugeVec (Gauge with labels), each label combination creates an independent sub-instance (gaugesub), each maintaining its own `value`.

## API Reference

### gauge(name, help, labelnames)

Create a new Gauge metric.

- **Parameters**:
  - `name`: `string` - Metric name, must follow Prometheus naming convention (`[a-zA-Z_:][a-zA-Z0-9_:]*`)
  - `help`: `string` - Metric description text
  - `labelnames`: `table | nil` - Label name list (optional), e.g., `{"method", "status"}`
- **Returns**:
  - `gauge` - Gauge object when without labels
  - `gaugevec` - GaugeVec object when with labels
- **Example**:

```lua validate
local gauge = require "silly.metrics.gauge"

-- Create Gauge without labels
local temperature = gauge("room_temperature_celsius", "Current room temperature")
print(temperature.name)  -- "room_temperature_celsius"
print(temperature.kind)  -- "gauge"
print(temperature.value) -- 0

-- Create GaugeVec with labels
local connections = gauge(
    "active_connections",
    "Number of active connections",
    {"protocol", "state"}
)
print(connections.name)  -- "active_connections"
print(#connections.labelnames)  -- 2
```

### gauge:set(value)

Set the Gauge's current value. This is the most common Gauge operation, directly setting the value to a specified number.

- **Parameters**:
  - `value`: `number` - New value to set
- **Returns**: None
- **Example**:

```lua validate
local gauge = require "silly.metrics.gauge"

local temperature = gauge("temperature_celsius", "Temperature sensor reading")

-- Set temperature value directly
temperature:set(25.5)
print(temperature.value)  -- 25.5

temperature:set(26.0)
print(temperature.value)  -- 26.0

-- Can set any value, including negative numbers
temperature:set(-5.2)
print(temperature.value)  -- -5.2

-- Can set to 0
temperature:set(0)
print(temperature.value)  -- 0
```

### gauge:inc()

Increase the Gauge value by 1. Used in counting scenarios like connection establishment, task enqueueing, etc.

- **Parameters**: None
- **Returns**: None
- **Example**:

```lua validate
local gauge = require "silly.metrics.gauge"

local connections = gauge("active_connections", "Active connections")
connections:set(10)
print(connections.value)  -- 10

-- New connection established
connections:inc()
print(connections.value)  -- 11

connections:inc()
print(connections.value)  -- 12

-- Multiple calls accumulate
for i = 1, 5 do
    connections:inc()
end
print(connections.value)  -- 17
```

### gauge:dec()

Decrease the Gauge value by 1. Used in counting scenarios like connection closing, task dequeueing, etc.

- **Parameters**: None
- **Returns**: None
- **Example**:

```lua validate
local gauge = require "silly.metrics.gauge"

local queue_size = gauge("queue_size", "Current queue size")
queue_size:set(10)
print(queue_size.value)  -- 10

-- Task dequeued
queue_size:dec()
print(queue_size.value)  -- 9

queue_size:dec()
print(queue_size.value)  -- 8

-- Can decrease to negative (though usually shouldn't)
for i = 1, 15 do
    queue_size:dec()
end
print(queue_size.value)  -- -7
```

### gauge:add(value)

Increase the Gauge value by a specified amount. Supports both positive and negative numbers; negative is equivalent to subtraction.

- **Parameters**:
  - `value`: `number` - Amount to add (can be negative)
- **Returns**: None
- **Note**:
  - Warning: Current source code has a bug where `add()` is hardcoded to add 1; verify actual usage
- **Example**:

```lua validate
local gauge = require "silly.metrics.gauge"

local balance = gauge("account_balance", "Account balance")
balance:set(100)
print(balance.value)  -- 100

-- Add 50 (due to bug, actually only adds 1)
balance:add(50)
print(balance.value)  -- 101 (expected 150, but bug causes only +1)

-- Add again (due to bug, actually only adds 1)
balance:add(25)
print(balance.value)  -- 102 (expected 175, but bug causes only +1)
```

::: warning Source Code Bug
Current implementation has `add(v)` hardcoded as `self.value = self.value + 1`, ignoring parameter `v`. For adding specific amounts, use these workarounds:
- Use `gauge:set(gauge.value + v)` to manually add
- Or directly modify source code: change `self.value = self.value + 1` to `self.value = self.value + v`
:::

### gauge:sub(value)

Decrease the Gauge value by a specified amount.

- **Parameters**:
  - `value`: `number` - Amount to subtract
- **Returns**: None
- **Example**:

```lua validate
local gauge = require "silly.metrics.gauge"

local memory = gauge("memory_free_bytes", "Free memory in bytes")
memory:set(1024 * 1024 * 100)  -- 100 MB
print(memory.value)  -- 104857600

-- Subtract 10 MB
memory:sub(1024 * 1024 * 10)
print(memory.value)  -- 94371840

-- Subtract 20 MB
memory:sub(1024 * 1024 * 20)
print(memory.value)  -- 73400320

-- Can use floating point
memory:sub(1024.5)
print(memory.value)  -- 73399295.5
```

### gaugevec:labels(...)

Get or create a Gauge instance with specified label values. If the label combination doesn't exist, automatically creates a new Gauge instance.

- **Parameters**:
  - `...`: `string|number` - Label values, count and order must match `labelnames` from creation
- **Returns**:
  - `gaugesub` - Gauge sub-instance, supports `set()`, `inc()`, `dec()`, `add()`, `sub()` methods
- **Example**:

```lua validate
local gauge = require "silly.metrics.gauge"

local cpu_usage = gauge(
    "cpu_usage_percent",
    "CPU usage percentage by core",
    {"core"}
)

-- Set usage for different CPU cores
cpu_usage:labels("0"):set(45.2)
cpu_usage:labels("1"):set(78.9)
cpu_usage:labels("2"):set(23.5)
cpu_usage:labels("3"):set(56.1)

-- Read specific label values
print(cpu_usage:labels("0").value)  -- 45.2
print(cpu_usage:labels("1").value)  -- 78.9

-- Multiple labels
local memory_usage = gauge(
    "memory_usage_bytes",
    "Memory usage by type and pool",
    {"type", "pool"}
)

memory_usage:labels("heap", "default"):set(1024 * 1024 * 100)
memory_usage:labels("heap", "large"):set(1024 * 1024 * 50)
memory_usage:labels("stack", "default"):set(1024 * 1024 * 10)

print(memory_usage:labels("heap", "default").value)  -- 104857600
```

### gaugevec.collect(self, buf)

Collect metric data to buffer. This method is mainly for internal use (e.g., Prometheus Registry); regular users typically don't need to call it directly.

- **Parameters**:
  - `self`: `gauge` - Gauge object
  - `buf`: `table` - Buffer array for collecting metrics
- **Returns**: None
- **Description**:
  - Appends current Gauge object to end of `buf` array
  - Used in Prometheus `gather()` flow
- **Example**:

```lua validate
local gauge = require "silly.metrics.gauge"

local temperature = gauge("temperature_celsius", "Temperature")
temperature:set(25.5)

-- Manually collect metrics
local buf = {}
temperature:collect(buf)

print(#buf)  -- 1
print(buf[1].name)  -- "temperature_celsius"
print(buf[1].value)  -- 25.5
print(buf[1].kind)  -- "gauge"
```

## Usage Examples

### Example 1: Monitor Active Connections

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local gauge = require "silly.metrics.gauge"
local task = require "silly.task"

-- Create active connection counter
local active_connections = gauge(
    "http_active_connections",
    "Current number of active HTTP connections"
)

task.fork(function()
    local server = http.listen {
        addr = "0.0.0.0:8080",
        handler = function(stream)
            -- Connection established, increase count
            active_connections:inc()
            print("Active connections:", active_connections.value)

            -- Process request
            stream:respond(200, {["content-type"] = "text/plain"})
            stream:closewrite("Hello World")

            -- Connection closed, decrease count
            active_connections:dec()
            print("Active connections:", active_connections.value)
        end
    }

    print("HTTP server listening on :8080")
end)
```

(Due to length constraints, I'll provide the remaining metric files in separate responses. Let me continue with the most important ones.)
