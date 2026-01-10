---
title: silly.perf
icon: gauge-high
category:
  - API Reference
tag:
  - Core
  - Performance
  - Profiling
---

# silly.perf

Performance profiling module providing high-resolution time measurement and function execution time statistics.

## Module Import

```lua validate
local perf = require "silly.perf"
```

## Time Functions

### perf.hrtime()
Get high-resolution monotonic time in nanoseconds.

- **Returns**: `integer` - Monotonic time in nanoseconds
- **Usage**: High-precision performance measurement
- **Example**:
```lua validate
local perf = require "silly.perf"

local start = perf.hrtime()
-- ... do something ...
local elapsed_ns = perf.hrtime() - start
local elapsed_ms = elapsed_ns / 1e6
print("Elapsed:", elapsed_ms, "ms")
```

## Profiling Functions

### perf.start(name)
Start timing a named code section.

- **Parameters**:
  - `name`: `string` - Code section name
- **Note**: Must be paired with `perf.stop(name)`
- **Example**:
```lua validate
local perf = require "silly.perf"

perf.start("process_data")
-- ... do something ...
perf.stop("process_data")
```

### perf.stop(name)
Stop timing a named code section.

- **Parameters**:
  - `name`: `string` - Code section name (must match `start`)
- **Errors**:
  - Throws error if no corresponding `start` call
  - Throws error if `start` and `stop` are not paired

### perf.yield()
Call before coroutine yield to pause current coroutine's timing.

- **Usage**: Ensures time spent while coroutine is suspended is not counted
- **Example**:
```lua validate
local perf = require "silly.perf"
local silly = require "silly"

-- Use in custom scheduler
perf.yield()
silly.yield()
```

### perf.resume(co)
Call after coroutine resume to restore target coroutine's timing.

- **Parameters**:
  - `co`: `thread` - The resumed coroutine
- **Example**:
```lua validate
local perf = require "silly.perf"

-- Use in custom scheduler
coroutine.resume(co)
perf.resume(co)
```

### perf.dump([name])
Export performance statistics.

- **Parameters**:
  - `name`: `string` (optional) - Specific code section name, omit to return all stats
- **Returns**: `table` - Statistics table
  - If `name` specified: Returns `{time = ns, call = count}`
  - If not specified: Returns `{[name] = {time = ns, call = count}, ...}`
- **Fields**:
  - `time`: Cumulative execution time (nanoseconds)
  - `call`: Call count
- **Example**:
```lua validate
local perf = require "silly.perf"

-- Get all stats
local stats = perf.dump()
for name, data in pairs(stats) do
    print(name, "time:", data.time / 1e6, "ms", "calls:", data.call)
end

-- Get specific stats
local data = perf.dump("process_data")
if data then
    print("process_data:", data.time / 1e6, "ms", data.call, "calls")
end
```

## Usage Examples

### Example 1: Simple Performance Measurement

```lua validate
local perf = require "silly.perf"

local start = perf.hrtime()
local sum = 0
for i = 1, 1000000 do
    sum = sum + i
end
local elapsed = perf.hrtime() - start
print("Elapsed:", elapsed / 1e6, "ms")
```

### Example 2: Function Execution Time Statistics

```lua validate
local perf = require "silly.perf"

local function process_request(data)
    perf.start("process_request")
    -- Simulate processing
    local result = data
    perf.stop("process_request")
    return result
end

-- Simulate multiple calls
for i = 1, 100 do
    process_request("data" .. i)
end

-- View statistics
local stats = perf.dump("process_request")
print("Total time:", stats.time / 1e6, "ms")
print("Calls:", stats.call)
print("Avg time:", stats.time / stats.call / 1e6, "ms")
```

### Example 3: Comparing Multiple Code Sections

```lua validate
local perf = require "silly.perf"

local function method_a()
    perf.start("method_a")
    local t = {}
    for i = 1, 10000 do
        t[i] = i
    end
    perf.stop("method_a")
end

local function method_b()
    perf.start("method_b")
    local t = {}
    for i = 1, 10000 do
        table.insert(t, i)
    end
    perf.stop("method_b")
end

-- Run tests
for _ = 1, 100 do
    method_a()
    method_b()
end

-- Compare results
local stats = perf.dump()
for name, data in pairs(stats) do
    print(name .. ":", data.time / 1e6, "ms total,",
          data.time / data.call / 1e6, "ms avg")
end
```

## Precision Notes

- **hrtime() precision**: Nanosecond level (Linux uses `CLOCK_MONOTONIC`, macOS uses `task_info`)
- **Units**: All time values are in nanoseconds
- **Conversion**:
  - Nanoseconds → Microseconds: `ns / 1e3`
  - Nanoseconds → Milliseconds: `ns / 1e6`
  - Nanoseconds → Seconds: `ns / 1e9`

## Important Notes

1. `start` and `stop` must be strictly paired
2. Same name cannot have nested `start` calls within the same coroutine
3. When using in coroutine environment, use `yield` and `resume` to ensure accurate time statistics
4. Statistics data uses weak tables, related data is automatically garbage collected when coroutine ends

## See Also

- [silly.time](./time.md) - Timer module
- [silly.trace](./trace.md) - Tracing module
