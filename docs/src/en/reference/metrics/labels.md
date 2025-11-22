---
title: silly.metrics.labels
description: Metric label management and serialization API
category: reference
---

# silly.metrics.labels

::: info Module Description
`silly.metrics.labels` is the underlying label management module of the Silly framework metrics system. It's responsible for label caching optimization and Prometheus format serialization, providing efficient multi-dimensional label support for Counter, Gauge, Histogram, and other metric types.
:::

## Overview

`silly.metrics.labels` is an internal module, primarily providing label management functionality for metric vectors (Metric Vector). Its core responsibilities include:

- **Label key generation**: Combines label names and values to generate unique cache keys
- **Prometheus formatting**: Serializes labels to Prometheus format strings (like `method="GET",status="200"`)
- **Performance optimization**: Uses multi-level caching to avoid repeated serialization, improving hot path performance

This module is used internally by `silly.metrics.counter`, `silly.metrics.gauge`, `silly.metrics.histogram`, and other metric types. Normal user code typically doesn't need to call this module directly, but uses it indirectly through metric objects' `labels()` method.

## Core Concepts

### Labels

In the Prometheus monitoring system, labels are used to implement multi-dimensional metric statistics. Each metric can have multiple label dimensions, each dimension with multiple possible values:

```lua
-- Example: HTTP request metric has two label dimensions
http_requests_total{method="GET", status="200"} = 1024
http_requests_total{method="POST", status="500"} = 5
```

Each unique label combination corresponds to an independent time series.

### Label Cardinality

Label cardinality refers to the number of possible label value combinations. For example:

- Label `method` has 4 values: GET, POST, PUT, DELETE
- Label `status` has 5 values: 200, 404, 500, 502, 503
- Total cardinality = 4 × 5 = 20 time series

**Important**: High cardinality labels (like user_id, session_id) cause time series explosion, severely affecting performance and storage.

### Label Caching Mechanism

`silly.metrics.labels` uses a multi-level cache structure to optimize label serialization:

```
labelcache (table)
├── value1 (table)
│   ├── value2 (table)
│   │   └── value3 → "label1=\"value1\",label2=\"value2\",label3=\"value3\""
│   └── value2' → "label1=\"value1\",label2=\"value2'\""
└── value1' (table)
    └── value2 → "label1=\"value1'\",label2=\"value2\""
```

This design ensures the same label combination only needs serialization once, subsequent queries return cached results directly.

### Prometheus Label Format

The module serializes labels to Prometheus text format:

```
labelname1="value1",labelname2="value2",labelname3="value3"
```

Note:
- Label names and values connected with `=`
- Values wrapped in double quotes `"`
- Multiple labels separated by commas `,`
- No comma after the last label

## API Reference

### key()

Generates a unique cache key for the label combination, creates and caches the Prometheus format label string if it doesn't exist.

```lua
local key_string = labels.key(lcache, lnames, values)
```

**Parameters:**

- `lcache` (table): Label cache table, typically managed by metric vector object
- `lnames` (string[]): Label name array, defining label order and names
- `values` (table): Label value array, corresponds one-to-one with `lnames`

**Returns:**

- `string`: Prometheus format label string, like `method="GET",status="200"`

**Assertions:**

- Triggers assertion error if `#lnames ≠ #values`

**Algorithm description:**

1. Recursively find or create nested tables in `lcache` by label value order
2. Use the last label value as final cache key
3. If cache doesn't exist, call internal `compose()` function to generate label string
4. Cache and return the generated string

**Example:**

```lua validate
local labels = require "silly.metrics.labels"

-- Prepare label cache (typically managed by metric vector object)
local cache = {}

-- Define label names
local labelnames = {"method", "status"}

-- Generate label key
local key1 = labels.key(cache, labelnames, {"GET", "200"})
print("Key 1:", key1)  -- method="GET",status="200"

local key2 = labels.key(cache, labelnames, {"POST", "500"})
print("Key 2:", key2)  -- method="POST",status="500"

-- Same label combination returns cached result
local key3 = labels.key(cache, labelnames, {"GET", "200"})
print("Key 3:", key3)  -- method="GET",status="200" (from cache)
assert(key1 == key3)   -- Same reference
```

---

## Usage Examples

### Example 1: Basic Label Serialization

Demonstrates how to use `key()` function to serialize labels.

```lua validate
local labels = require "silly.metrics.labels"

-- Create cache table
local cache = {}
local labelnames = {"region", "server"}

-- Serialize different label combinations
local k1 = labels.key(cache, labelnames, {"us-east", "web01"})
print("K1:", k1)  -- region="us-east",server="web01"

local k2 = labels.key(cache, labelnames, {"eu-west", "web02"})
print("K2:", k2)  -- region="eu-west",server="web02"

local k3 = labels.key(cache, labelnames, {"ap-south", "web03"})
print("K3:", k3)  -- region="ap-south",server="web03"
```

---

### Example 2: Cache Verification

Verify that same label combination indeed returns cached result.

```lua validate
local labels = require "silly.metrics.labels"

local cache = {}
local labelnames = {"method", "path"}

-- First call, create cache
local key1 = labels.key(cache, labelnames, {"GET", "/api/users"})

-- Second identical call, return from cache
local key2 = labels.key(cache, labelnames, {"GET", "/api/users"})

-- Verify it's exactly the same string object (same address)
print("Key 1:", key1)
print("Key 2:", key2)
print("Same object:", key1 == key2)  -- true

-- Different label values create new object
local key3 = labels.key(cache, labelnames, {"POST", "/api/orders"})
print("Key 3:", key3)
print("Different:", key1 ~= key3)  -- true
```

---

### Example 3: Single Label Scenario

Demonstrates single label dimension serialization.

```lua validate
local labels = require "silly.metrics.labels"

local cache = {}
local labelnames = {"status"}

-- Single label serialization
local k1 = labels.key(cache, labelnames, {"200"})
print(k1)  -- status="200"

local k2 = labels.key(cache, labelnames, {"404"})
print(k2)  -- status="404"

local k3 = labels.key(cache, labelnames, {"500"})
print(k3)  -- status="500"
```

---

### Example 4: Multi-Label Scenario

Demonstrates multi-label dimension serialization.

```lua validate
local labels = require "silly.metrics.labels"

local cache = {}
local labelnames = {"method", "endpoint", "status", "datacenter"}

-- 4 label dimensions
local key = labels.key(cache, labelnames, {
    "POST",
    "/api/orders",
    "201",
    "us-west-2"
})

print(key)
-- Output: method="POST",endpoint="/api/orders",status="201",datacenter="us-west-2"
```

---

### Example 5: Numeric Label Values

Label values can be numbers, automatically converted to strings.

```lua validate
local labels = require "silly.metrics.labels"

local cache = {}
local labelnames = {"user_type", "level", "score"}

-- Numbers automatically convert to strings
local key = labels.key(cache, labelnames, {"premium", 10, 9500})
print(key)
-- Output: user_type="premium",level="10",score="9500"
```

---

### Example 6: Integration with Counter

Demonstrates how labels module is used internally by Counter Vector.

```lua validate
local counter = require "silly.metrics.counter"

-- Create Counter Vector
local requests = counter("http_requests_total", "Total HTTP requests", {"method", "status"})

-- Counter internally uses silly.metrics.labels to generate cache keys
requests:labels("GET", "200"):inc()
requests:labels("POST", "201"):inc()
requests:labels("GET", "200"):inc()  -- Reuse cache

-- View internal structure (for demo only, don't access internal fields in actual code)
print("Label names:", table.concat(requests.labelnames, ", "))  -- method, status

-- View generated label combinations (metrics table keys are labels.key() return values)
for k, v in pairs(requests.metrics) do
    print("Label key:", k, "Value:", v.value)
end
-- Output example:
-- Label key: method="GET",status="200" Value: 2
-- Label key: method="POST",status="201" Value: 1
```

---

### Example 7: Label Cardinality Analysis

Demonstrates impact of different label combination counts on memory.

```lua validate
local labels = require "silly.metrics.labels"

local cache = {}
local labelnames = {"region", "server_type"}

-- Simulate creating multiple label combinations
local regions = {"us-east", "us-west", "eu-west", "ap-south"}
local server_types = {"web", "api", "db", "cache"}

local count = 0
for _, region in ipairs(regions) do
    for _, server_type in ipairs(server_types) do
        local key = labels.key(cache, labelnames, {region, server_type})
        count = count + 1
        print(string.format("[%d] %s", count, key))
    end
end

print("\nTotal unique label combinations:", count)
-- Output: 4 regions × 4 server_types = 16 time series
```

---

### Example 8: High Cardinality Problem Demo

Demonstrates issues with using high cardinality labels (like user_id).

```lua validate
local labels = require "silly.metrics.labels"

-- Simulate using user_id as label (not recommended!)
local cache = {}
local labelnames = {"user_id"}

-- Assume 10000 users, each creating a time series
local user_count = 10000
local memory_estimate = 0

for i = 1, user_count do
    local key = labels.key(cache, labelnames, {tostring(i)})
    -- Each label string occupies approximately 20-30 bytes
    memory_estimate = memory_estimate + #key
end

print(string.format("Created %d time series", user_count))
print(string.format("Estimated label cache memory: ~%f KB", memory_estimate / 1024))
print("\n⚠️  WARNING: High cardinality labels can cause:")
print("  - Excessive memory usage")
print("  - Slow Prometheus queries")
print("  - High storage costs")
print("\n✅ SOLUTION: Use bounded labels like 'user_type' instead of 'user_id'")
```

---

## Important Notes

### 1. Should Not Use This Module Directly

`silly.metrics.labels` is a low-level module, typically should not be used directly in business code. Should use indirectly through metric objects' `labels()` method:

```lua
-- ❌ Not recommended: Use labels module directly
local labels = require "silly.metrics.labels"
local cache = {}
local key = labels.key(cache, {"method"}, {"GET"})

-- ✅ Recommended: Use through metric object
local counter = require "silly.metrics.counter"
local requests = counter("requests_total", "Total requests", {"method"})
requests:labels("GET"):inc()  -- Internally calls labels.key() automatically
```

---

### 2. Label Value Order Must Be Consistent

When calling `key()`, the order of the `values` array must match `lnames`:

```lua
local labels = require "silly.metrics.labels"
local cache = {}
local labelnames = {"method", "status"}

-- ✅ Correct: Order matches
local k1 = labels.key(cache, labelnames, {"GET", "200"})

-- ❌ Error: Order reversed generates different label string
local k2 = labels.key(cache, labelnames, {"200", "GET"})
-- k2 = method="200",status="GET" (Wrong!)
```

---

### 3. Label Values Automatically Convert to Strings

Numeric type label values are converted to strings via `tostring()`:

```lua
local labels = require "silly.metrics.labels"
local cache = {}
local labelnames = {"port"}

local key = labels.key(cache, labelnames, {8080})
print(key)  -- port="8080" (number converted to string)
```

Note: `8080` and `"8080"` generate the same label string.

---

### 4. Avoid High Cardinality Labels

Each unique label combination creates independent cache entry and time series. High cardinality labels (like user_id, session_id) cause:

- **Memory explosion**: Millions of users = millions of time series
- **Performance degradation**: Prometheus queries slow down
- **Storage cost**: Time series database storage cost grows linearly

**Best practices**:

```lua
-- ❌ Bad: user_id has million-level cardinality
local labelnames = {"user_id"}

-- ✅ Good: user_type has only a few values
local labelnames = {"user_type"}  -- vip, normal, guest

-- ❌ Bad: ip_address has hundreds of thousands of possibilities
local labelnames = {"ip_address"}

-- ✅ Good: region has only a few data centers
local labelnames = {"region"}  -- us-east, eu-west, ap-south
```

**Recommendation**: Unique label combinations for a single metric should be kept **within 1000**, max not exceeding 10000.

---

### 5. Label Names Must Follow Conventions

Although the `labels` module doesn't validate label names, Prometheus requires label names follow these conventions:

- Can only contain letters, numbers, underscores
- Cannot start with a number
- Cannot start with `__` double underscore (reserved for Prometheus internal use)

```lua
-- ✅ Valid label names
local labelnames = {"method", "status_code", "datacenter_1"}

-- ❌ Invalid label names
local bad_names = {"method-type", "1st_label", "__internal"}
```

---

### 6. Cache Table Managed by Caller

The `lcache` cache table's lifecycle is managed by the caller (metric object). Different metric objects have independent cache tables:

```lua
local counter = require "silly.metrics.counter"

local c1 = counter("metric1", "First metric", {"label1"})
local c2 = counter("metric2", "Second metric", {"label1"})

-- c1 and c2 have their own independent labelcache
-- c1.labelcache and c2.labelcache don't affect each other
```

---

### 7. Label Strings Are Immutable

The string returned by `key()` is a cached reference, should not be modified:

```lua
local labels = require "silly.metrics.labels"
local cache = {}
local key = labels.key(cache, {"method"}, {"GET"})

-- ❌ Don't try to modify label string
-- Lua strings are immutable, but don't rely on return value for other purposes
```

---

### 8. Thread Safety Note

Since Silly uses single-threaded Worker model, all `silly.metrics.labels` operations execute in the same thread, so it's thread-safe without locking.

---

### 9. Memory Optimization

The `compose()` function uses a global `buf` table for string concatenation, avoiding creation of many temporary strings:

```lua
-- Internal implementation uses table.concat optimization
local buf = {}  -- Global reuse
buf[1] = 'method="'
buf[2] = 'GET'
buf[3] = '",status="'
buf[4] = '200'
buf[5] = '"'
local str = table.concat(buf)
```

This design significantly reduces GC pressure in high-frequency call scenarios.

---

## Related APIs

- [silly.metrics.counter](./counter.md) - Counter metric type (uses labels module internally)
- [silly.metrics.gauge](./gauge.md) - Gauge metric type (uses labels module internally)
- [silly.metrics.histogram](./histogram.md) - Histogram metric type (uses labels module internally)
- [silly.metrics.prometheus](./prometheus.md) - Prometheus metrics integration

---

## References

- [Prometheus data model](https://prometheus.io/docs/concepts/data_model/)
- [Prometheus label best practices](https://prometheus.io/docs/practices/naming/)
- [Label cardinality and performance optimization](https://www.robustperception.io/cardinality-is-key)
- [Lua string optimization tips](https://www.lua.org/pil/11.6.html)

---

## See Also

- [Prometheus metrics system overview](./prometheus.md#core-concepts)
- [How to choose appropriate label dimensions](./prometheus.md#label-design-best-practices)
- [Monitoring system performance optimization](./prometheus.md#performance-optimization-recommendations)
