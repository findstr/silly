---
title: silly.metrics.registry
description: Prometheus metric registry API
category: reference
---

# silly.metrics.registry

::: info Module Description
`silly.metrics.registry` provides metric Registry functionality for unified management and collection of all Prometheus metric collectors. The registry is a core component of the Prometheus monitoring system, responsible for maintaining the metric collection and providing a unified collection interface.
:::

## Overview

Registry is the core container in the Prometheus monitoring architecture, responsible for managing all Collector instances. Its main functions include:

- **Centralized management**: Uniformly maintains all Counter, Gauge, Histogram and other metric collectors
- **Deduplication protection**: Prevents duplicate registration of the same Collector instance
- **Unified collection**: Provides a single interface to collect current values of all registered metrics
- **Isolation control**: Supports creating multiple independent Registries for metric isolation

Typical application scenarios for Registry:

1. **Global monitoring**: Use default Registry to collect metrics for the entire application
2. **Module isolation**: Create independent Registry for different subsystems to avoid metric conflicts
3. **Custom export**: Create dedicated Registry to export specific metric sets
4. **Test verification**: Create temporary Registry in unit tests to verify metric behavior

## Core Concepts

### Registry and Collector

Relationship between Registry and Collector:

```
Registry
  └─ Collector 1 (Counter)
  └─ Collector 2 (Gauge)
  └─ Collector 3 (Histogram)
  └─ Collector 4 (Custom Collector)
```

- **Registry**: Container, responsible for managing and collecting metrics
- **Collector**: Metric collector, implements `collect(buf)` method to output metrics

### Collector Interface

All objects registered to Registry must implement the Collector interface:

```lua
-- Collector interface definition
interface Collector {
    name: string                    -- Collector name
    collect(self, buf: metric[])    -- Collect metrics to buf array
}
```

Built-in Counter, Gauge, Histogram all implement this interface.

### Deduplication Mechanism

Registry uses reference equality checking to prevent duplicate registration:

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c = counter("test", "Test counter")

reg:register(c)
reg:register(c)  -- Second registration is ignored (same object)
```

Note: Only identical object references are deduplicated; Collectors with the same name but different objects are not blocked.

### Collection Process

Execution flow when calling `registry:collect()`:

1. Create empty metrics array
2. Iterate through all registered Collectors
3. Call each Collector's `collect(metrics)` method
4. Collector appends its metrics to the metrics array
5. Return metrics array containing all metrics

### Default Registry

`silly.metrics.prometheus` module maintains a default Registry internally:

```lua
-- prometheus.lua internal
local R = registry.new()  -- Default global Registry

function M.counter(name, help, labels)
    local ct = counter(name, help, labels)
    R:register(ct)  -- Auto-register to default Registry
    return ct
end
```

Metrics created via `prometheus.counter()` etc. are automatically registered to the default Registry.

## API Reference

### registry.new()

Creates a new metric registry instance.

```lua
local registry = require "silly.metrics.registry"
local reg = registry.new()
```

**Parameters:** None

**Returns:**

- `silly.metrics.registry`: New registry object

**Notes:**

- Each call creates a completely new independent Registry instance
- New Registry is initially empty, contains no Collectors
- Multiple Registries are completely isolated from each other

**Example:**

```lua validate
local registry = require "silly.metrics.registry"

-- Create global Registry
local global_reg = registry.new()

-- Create module-specific Registry
local auth_reg = registry.new()
local api_reg = registry.new()

-- Three Registries are independent
```

---

### registry:register()

Registers a Collector to the Registry.

```lua
registry:register(obj)
```

**Parameters:**

- `obj` (silly.metrics.collector): Collector object to register, must implement `collect(buf)` method

**Returns:** None

**Behavior:**

- If the object already exists in Registry (reference equality), this registration is ignored
- If it's a new object, append to the end of Registry's Collector list
- Does not check name conflicts, allows registering multiple Collectors with same name but different instances

**Example:**

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()

-- Create and register Counter
local requests = counter("requests_total", "Total requests")
reg:register(requests)

-- Create and register Gauge
local gauge = require "silly.metrics.gauge"
local temperature = gauge("cpu_temperature", "CPU temperature")
reg:register(temperature)

-- Duplicate registration of same object is ignored
reg:register(requests)  -- No-op
```

---

### registry:unregister()

Removes a registered Collector from the Registry.

```lua
registry:unregister(obj)
```

**Parameters:**

- `obj` (silly.metrics.collector): Collector object to remove

**Returns:** None

**Behavior:**

- If the object is found (reference equality), remove from Registry
- If object doesn't exist, silently ignore
- Uses `table.remove()` implementation, maintains array continuity

**Notes:**

- After removal, the Collector no longer appears in `collect()` results
- But the Collector object itself remains valid, can continue to be used or registered to other Registries

**Example:**

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c = counter("test", "Test counter")

-- Register
reg:register(c)

-- Unregister
reg:unregister(c)

-- Unregister again (no-op but doesn't error)
reg:unregister(c)
```

---

### registry:collect()

Collects metric data from all registered Collectors.

```lua
local metrics = registry:collect()
```

**Parameters:** None

**Returns:**

- `silly.metrics.metric[]`: Array containing all metric objects

**Behavior:**

1. Create empty metrics array
2. Iterate through all Collectors in registration order
3. Call each Collector's `collect(metrics)` method
4. Collector appends its metrics to the metrics array
5. Return metrics array

**Notes:**

- Returned metric objects contain `name`, `help`, `kind`, `value` and other fields
- For Vector types (with labels), includes `metrics` and `labelnames` fields
- Metric order depends on Collector registration order
- This is a read-only operation, doesn't modify Collector state

**Example:**

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"
local gauge = require "silly.metrics.gauge"

local reg = registry.new()

-- Register multiple metrics
local requests = counter("requests_total", "Total requests")
requests:inc()
requests:inc()

local temperature = gauge("temperature", "Current temperature")
temperature:set(75.5)

reg:register(requests)
reg:register(temperature)

-- Collect all metrics
local metrics = reg:collect()

-- metrics contains:
-- [1] = {name="requests_total", kind="counter", value=2, help="..."}
-- [2] = {name="temperature", kind="gauge", value=75.5, help="..."}

print("Collected " .. #metrics .. " metrics")
```

---

## Usage Examples

### Example 1: Create Custom Registry

Create independent Registry for specific modules.

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"
local gauge = require "silly.metrics.gauge"

-- Create dedicated Registry for database module
local db_registry = registry.new()

-- Create database-related metrics
local db_queries = counter("db_queries_total", "Total database queries")
local db_connections = gauge("db_connections_active", "Active database connections")
local db_latency = require "silly.metrics.histogram"(
    "db_latency_seconds",
    "Database query latency",
    nil,
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0}
)

-- Register to dedicated Registry
db_registry:register(db_queries)
db_registry:register(db_connections)
db_registry:register(db_latency)

-- Simulate database operations
db_queries:inc()
db_connections:set(25)
db_latency:observe(0.023)

-- Collect database module metrics
local metrics = db_registry:collect()
print("Database module metrics:", #metrics)
```

---

### Example 2: Multi-Registry Isolated Management

Create independent Registries for different subsystems to achieve metric isolation.

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

-- Create independent Registries for different services
local auth_registry = registry.new()
local api_registry = registry.new()
local cache_registry = registry.new()

-- Authentication service metrics
local auth_attempts = counter("auth_attempts_total", "Total authentication attempts")
auth_registry:register(auth_attempts)

-- API service metrics
local api_requests = counter("api_requests_total", "Total API requests")
api_registry:register(api_requests)

-- Cache service metrics
local cache_hits = counter("cache_hits_total", "Total cache hits")
cache_registry:register(cache_hits)

-- Services operate independently
auth_attempts:inc()
api_requests:add(10)
cache_hits:add(100)

-- Collect each service's metrics independently
local auth_metrics = auth_registry:collect()
local api_metrics = api_registry:collect()
local cache_metrics = cache_registry:collect()

print("Auth service metrics:", #auth_metrics)  -- 1
print("API service metrics:", #api_metrics)    -- 1
print("Cache service metrics:", #cache_metrics)  -- 1
```

---

### Example 3: Dynamic Registration and Removal

Dynamically manage Collector registration status at runtime.

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()

-- Create multiple Collectors
local c1 = counter("metric1", "Metric 1")
local c2 = counter("metric2", "Metric 2")
local c3 = counter("metric3", "Metric 3")

-- Initial registration
reg:register(c1)
reg:register(c2)

c1:inc()
c2:inc()

-- Collect metrics (2)
local metrics1 = reg:collect()
print("Registered 2 Collectors:", #metrics1)  -- 2

-- Add new Collector
reg:register(c3)
c3:inc()

-- Collect metrics (3)
local metrics2 = reg:collect()
print("Registered 3 Collectors:", #metrics2)  -- 3

-- Remove one Collector
reg:unregister(c2)

-- Collect metrics (2)
local metrics3 = reg:collect()
print("After removal, 2 Collectors remaining:", #metrics3)  -- 2
```

---

### Example 4: Custom Collector

Implement custom Collector and register to Registry.

```lua validate
local registry = require "silly.metrics.registry"

-- Create custom Collector
local function create_system_collector()
    local collector = {
        name = "system_collector"
    }

    function collector:collect(buf)
        -- Collect system information (simulated)
        buf[#buf + 1] = {
            name = "system_uptime_seconds",
            help = "System uptime in seconds",
            kind = "gauge",
            value = 3600  -- 1 hour
        }

        buf[#buf + 1] = {
            name = "system_memory_used_bytes",
            help = "Memory used in bytes",
            kind = "gauge",
            value = 1024 * 1024 * 512  -- 512 MB
        }
    end

    return collector
end

-- Register custom Collector
local reg = registry.new()
local sys_collector = create_system_collector()
reg:register(sys_collector)

-- Collect metrics
local metrics = reg:collect()
print("Custom Collector output " .. #metrics .. " metrics")  -- 2

for i, m in ipairs(metrics) do
    print(string.format("%s = %s", m.name, m.value))
end
```

---

### Example 5: Registry Merging

Merge and collect metrics from multiple Registries.

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

-- Create multiple sub-Registries
local reg1 = registry.new()
local reg2 = registry.new()

local c1 = counter("module1_requests", "Module 1 requests")
local c2 = counter("module2_requests", "Module 2 requests")

c1:inc()
c2:add(5)

reg1:register(c1)
reg2:register(c2)

-- Create aggregated Registry
local aggregated_reg = registry.new()

-- Create aggregator Collector
local aggregator = {
    name = "aggregator",
    registries = {reg1, reg2}
}

function aggregator:collect(buf)
    for _, reg in ipairs(self.registries) do
        local metrics = reg:collect()
        for _, m in ipairs(metrics) do
            buf[#buf + 1] = m
        end
    end
end

aggregated_reg:register(aggregator)

-- Collect all sub-Registry metrics at once
local all_metrics = aggregated_reg:collect()
print("Merged collection of " .. #all_metrics .. " metrics")  -- 2
```

---

### Example 6: Prevent Duplicate Registration

Verify Registry's deduplication protection mechanism.

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c = counter("test", "Test counter")

-- Register same object multiple times
reg:register(c)
reg:register(c)
reg:register(c)

-- Collect metrics (only 1)
local metrics = reg:collect()
print("Duplicate registration validation:", #metrics, "metrics")  -- 1

-- Note: Same name but different objects are not deduplicated
local c2 = counter("test", "Test counter")  -- New object
reg:register(c2)

local metrics2 = reg:collect()
print("Different object registration:", #metrics2, "metrics")  -- 2 (not recommended)
```

---

### Example 7: Temporary Registry in Test Environment

Use temporary Registry in unit tests to verify metric behavior.

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

-- Test function: verify counter functionality
local function test_counter_increments()
    -- Create temporary Registry (doesn't affect global)
    local test_reg = registry.new()

    -- Create test Counter
    local test_counter = counter("test_requests", "Test requests")
    test_reg:register(test_counter)

    -- Execute operations
    test_counter:inc()
    test_counter:inc()
    test_counter:add(3)

    -- Verify results
    local metrics = test_reg:collect()
    assert(#metrics == 1, "Should have only 1 metric")
    assert(metrics[1].value == 5, "Value should be 5")

    print("✓ Test passed: Counter accumulates correctly")
end

-- Run test
test_counter_increments()
```

---

### Example 8: Integration with Prometheus Export

Combined with Prometheus formatted output, expose custom Registry metrics via HTTP.

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"
local gauge = require "silly.metrics.gauge"

-- Create custom Registry
local custom_reg = registry.new()

-- Register business metrics
local orders = counter("business_orders_total", "Total orders", {"status"})
local revenue = gauge("business_revenue_dollars", "Current revenue in dollars")

orders:labels("completed"):add(100)
orders:labels("pending"):add(20)
orders:labels("cancelled"):add(5)
revenue:set(45678.90)

custom_reg:register(orders)
custom_reg:register(revenue)

-- Simplified Prometheus formatting function
local function format_metrics(metrics)
    local lines = {}

    for _, m in ipairs(metrics) do
        lines[#lines + 1] = "# HELP " .. m.name .. " " .. m.help
        lines[#lines + 1] = "# TYPE " .. m.name .. " " .. m.kind

        if m.metrics then
            -- Labeled metrics
            for label_str, metric_obj in pairs(m.metrics) do
                lines[#lines + 1] = string.format(
                    "%s{%s} %s",
                    m.name,
                    label_str,
                    metric_obj.value
                )
            end
        else
            -- Simple metrics
            lines[#lines + 1] = string.format("%s %s", m.name, m.value)
        end
    end

    return table.concat(lines, "\n")
end

-- Collect and format metrics
local metrics = custom_reg:collect()
local output = format_metrics(metrics)
print(output)

-- Output example:
-- # HELP business_orders_total Total orders
-- # TYPE business_orders_total counter
-- business_orders_total{status="completed"} 100
-- business_orders_total{status="pending"} 20
-- business_orders_total{status="cancelled"} 5
-- # HELP business_revenue_dollars Current revenue in dollars
-- # TYPE business_revenue_dollars gauge
-- business_revenue_dollars 45678.90
```

---

## Important Notes

### 1. Registry Doesn't Check Name Conflicts

Registry only checks for duplicate object references, doesn't validate Collector name conflicts:

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()

-- Create two Counters with same name but different instances
local c1 = counter("test", "Test 1")
local c2 = counter("test", "Test 2")

reg:register(c1)
reg:register(c2)  -- Not blocked (different objects)

-- Collection will show two metrics with same name (not recommended)
local metrics = reg:collect()  -- Contains 2 metrics with name="test"
```

**Recommendation**: Application layer should ensure Collector name uniqueness.

---

### 2. Deduplication Based on Object Reference

Registry uses `==` operator to determine if objects are identical, only reference equality is deduplicated:

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c1 = counter("test", "Test")

reg:register(c1)
reg:register(c1)  -- ✅ Deduplication successful (same reference)

-- Even with identical parameters, newly created object is a different reference
local c2 = counter("test", "Test")
reg:register(c2)  -- ❌ Not deduplicated (different reference)
```

---

### 3. Collector Must Implement Correct Interface

Objects registered to Registry must implement `collect(self, buf)` method:

```lua
local registry = require "silly.metrics.registry"

local reg = registry.new()

-- ❌ Error: object has no collect method
local invalid_collector = {
    name = "invalid"
}
reg:register(invalid_collector)

-- Calling collect() will error: attempt to call a nil value (method 'collect')
-- local metrics = reg:collect()
```

---

### 4. collect() Returns References

The metrics array returned by `collect()` contains references to Collector objects, not copies:

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c = counter("test", "Test")
reg:register(c)

local metrics1 = reg:collect()
c:inc()  -- Modify Counter value

local metrics2 = reg:collect()
-- metrics1[1] and metrics2[1] point to the same object
-- Both value fields reflect the latest value
```

If snapshots are needed, should deep copy the metrics array.

---

### 5. Removing Collector Doesn't Affect Object Itself

`unregister()` only removes reference from Registry, doesn't destroy the Collector object:

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c = counter("test", "Test")

reg:register(c)
c:inc()

reg:unregister(c)  -- Remove from Registry

-- Counter object is still valid, can continue to use
c:inc()
print(c.value)  -- 2

-- Can register to other Registry
local another_reg = registry.new()
another_reg:register(c)
```

---

### 6. Default Registry is Global Singleton

The default Registry maintained internally by `silly.metrics.prometheus` is a global singleton, all metrics created via `prometheus.counter()` etc. register to the same Registry:

```lua
local prometheus = require "silly.metrics.prometheus"

-- These all register to the same global Registry
local c1 = prometheus.counter("metric1", "Metric 1")
local c2 = prometheus.counter("metric2", "Metric 2")

-- Can collect all metrics via prometheus.gather()
local output = prometheus.gather()
```

If isolation is needed, should use `registry.new()` to create independent Registry and manually register Collectors.

---

### 7. Registry is Not Thread-Safe

Silly framework uses single-threaded Worker model, all Registry operations execute in the same thread, so no thread safety concerns. But if used in extensions from other languages, concurrent protection is needed.

---

### 8. Collection Order Matches Registration Order

`collect()` collects metrics in Collector registration order:

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()

local c1 = counter("aaa", "AAA")
local c2 = counter("bbb", "BBB")
local c3 = counter("ccc", "CCC")

reg:register(c2)
reg:register(c1)
reg:register(c3)

local metrics = reg:collect()
-- metrics order: c2, c1, c3 (registration order, not alphabetical)
```

If specific order is needed, should control during registration, or manually sort after collection.

---

## See Also

- [silly.metrics.prometheus](./prometheus.md) - Prometheus metrics integration (uses default Registry)
- [silly.metrics.counter](./counter.md) - Counter metric type
- [silly.metrics.gauge](./gauge.md) - Gauge metric type
- [silly.metrics.histogram](./histogram.md) - Histogram metric type

---

## References

- [Prometheus Registry concept](https://prometheus.io/docs/instrumenting/writing_clientlibs/#overall-structure)
- [Prometheus Collector interface](https://prometheus.io/docs/instrumenting/writing_clientlibs/#collector)
- [Prometheus data model](https://prometheus.io/docs/concepts/data_model/)
