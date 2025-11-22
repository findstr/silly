---
title: silly.time
icon: clock
category:
  - API Reference
tag:
  - Core
  - Timer
  - Time
---

# silly.time

Timer and time management module, providing high-precision timers (default 10ms resolution, 50ms accuracy).

## Module Import

```lua validate
local time = require "silly.time"
```

## Time Functions

### time.now()
Get current timestamp (milliseconds).

- **Returns**: `integer` - Unix timestamp (milliseconds)
- **Example**:
```lua validate
local time = require "silly.time"

local timestamp = time.now()
print("Current time:", timestamp)
```

### time.monotonic()
Get monotonically increasing time (milliseconds), unaffected by system time adjustments.

- **Returns**: `integer` - Monotonic time (milliseconds)
- **Use Case**: Suitable for performance measurement and timeout calculation
- **Example**:
```lua validate
local time = require "silly.time"

local start = time.monotonic()
-- ... do something ...
local elapsed = time.monotonic() - start
print("Elapsed:", elapsed, "ms")
```

## Timer Functions

### time.sleep(ms)
Suspend the current coroutine for the specified milliseconds.

- **Parameters**:
  - `ms`: `integer` - Sleep duration (milliseconds)
- **Note**: Can only be called within a coroutine
- **Example**:
```lua validate
local time = require "silly.time"

time.sleep(1000)  -- Sleep for 1 second
print("Woke up after 1 second")
```

### time.after(ms, func [, userdata])
Execute callback function after specified milliseconds.

- **Parameters**:
  - `ms`: `integer` - Delay time (milliseconds)
  - `func`: `function` - Callback function, signature: `function(userdata|session)`
  - `userdata`: `any` (optional) - User data passed to callback
- **Returns**: `integer` - Timer session ID, can be used to cancel the timer
- **Callback Parameters**:
  - If `userdata` is provided, callback receives `userdata`
  - If `userdata` is not provided, callback receives timer's `session` ID
- **Example**:

```lua validate
local time = require "silly.time"

-- Without user data
time.after(1000, function(session)
    print("Timer expired, session:", session)
end)

-- With user data
time.after(2000, function(data)
    print("Got data:", data)
end, "hello")

-- With complex user data
time.after(3000, function(config)
    print("Server:", config.host, config.port)
end, {host = "localhost", port = 8080})
```

### time.cancel(session)
Cancel a timer.

- **Parameters**:
  - `session`: `integer` - Timer session ID (returned by `time.after`)
- **Note**:
  - Can only cancel timers created with `time.after`
  - Cannot cancel timers created with `time.sleep`
  - If timer has triggered but callback hasn't executed, cancel will prevent callback execution
- **Example**:
```lua validate
local time = require "silly.time"

local session = time.after(5000, function()
    print("This will not print")
end)

time.sleep(1000)
time.cancel(session)  -- Cancel timer
print("Timer cancelled")
```

## Usage Examples

### Example 1: Simple Delayed Execution

```lua validate
local time = require "silly.time"

time.after(1000, function()
    print("Hello after 1 second")
end)
```

### Example 2: Retry Logic with Timer

```lua validate
local time = require "silly.time"

-- Mock connection function
local function connect_to_server(config)
    return false  -- Simulate connection failure
end

local retries = 0
local max_retries = 3
local config = {host = "localhost"}

local function attempt()
    local ok = connect_to_server(config)
    if not ok and retries < max_retries then
        retries = retries + 1
        print("Retry", retries, "after 1 second")
        time.after(1000, attempt)
    else
        print("Max retries reached or connected")
    end
end

attempt()
```

### Example 3: Performance Measurement

```lua validate
local time = require "silly.time"

local start = time.monotonic()
-- Execute some operations
local sum = 0
for i = 1, 1000000 do
    sum = sum + i
end
local elapsed = time.monotonic() - start
print("Processing took", elapsed, "ms")
```

### Example 4: Cancelable Delayed Operation (Debounce)

```lua validate
local time = require "silly.time"

-- Mock save function
local function save_to_disk(data)
    print("Saving:", data)
end

local pending_save = nil
local function schedule_save(data)
    -- Cancel previous save operation
    if pending_save then
        time.cancel(pending_save)
        print("Cancelled previous save")
    end
    -- Delay 500ms save (debounce)
    pending_save = time.after(500, function()
        save_to_disk(data)
        pending_save = nil
    end)
end

-- Test debounce: call multiple times quickly, only saves last one
schedule_save("data1")
schedule_save("data2")
schedule_save("data3")
```

## Precision Notes

Silly timer system characteristics:
- **Resolution**: 10ms (timer tick interval)
- **Accuracy**: Approximately 50ms
- **Suitable For**: Network timeouts, scheduled tasks, debounce/throttle
- **Not Suitable For**: High-precision real-time control (such as audio/video sync)

## Working with Coroutines

Timers are tightly integrated with Silly's coroutine scheduling system:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"

task.fork(function()
    print("Task started")
    time.sleep(1000)  -- Coroutine sleeps, doesn't block other tasks
    print("Task resumed after 1 second")
end)

-- Main logic continues executing, not blocked
print("Main logic continues")
```

## See Also

- [silly](./silly.md) - Core module
- [silly.sync.waitgroup](./sync/waitgroup.md) - Coroutine wait group
