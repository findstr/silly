---
title: silly.hive
icon: cogs
category:
  - API Reference
tag:
  - Core
  - Thread Pool
  - Concurrency
---

# silly.hive

Worker thread pool module for executing blocking operations (such as file I/O, blocking computations, etc.) in independent OS threads, avoiding blocking the main event loop.

## Module Import

```lua validate
local hive = require "silly.hive"
```

## Core Concepts

Silly uses a single-threaded event loop model where all business logic executes in the main worker thread. For operations that must block (such as `os.execute`, blocking file read/write), Hive can dispatch them to independent worker threads, avoiding blocking the entire service.

**Workflow**:
1. Create a worker using `hive.spawn(code)`
2. Send tasks to worker using `hive.invoke(worker, ...)`
3. Worker executes Lua code in independent thread
4. Main coroutine waits for result while event loop continues running
5. Worker returns result through message queue when done

## API Functions

### hive.spawn(code, ...)
Create a new worker.

- **Parameters**:
  - `code`: `string` - Lua code string, must return a function
  - `...` - Initialization parameters passed to the code
- **Returns**: `silly.hive.worker` - Worker object
- **Description**:
  - Code executes in independent Lua VM
  - Code must return a function that will be called by `invoke`
  - Initialization parameters passed via `...`
- **Example**:
```lua validate
local hive = require "silly.hive"

local worker = hive.spawn([[
    local init_value = ...
    return function(a, b)
        return a + b + init_value
    end
]], 10)
```

### hive.invoke(worker, ...)
Send task to worker and wait for result.

- **Parameters**:
  - `worker`: `silly.hive.worker` - Worker object
  - `...` - Arguments passed to worker function
- **Returns**: `...` - Return values from worker function
- **Error**: If worker throws exception, it will be re-thrown in main coroutine
- **Concurrency**: Same worker can only process one task at a time (automatically serialized)
- **Example**:
```lua validate
local hive = require "silly.hive"

local worker = hive.spawn([[
    local init_value = ...
    return function(a, b)
        return a + b + init_value
    end
]], 10)

local result1, result2 = hive.invoke(worker, 5, 3)
-- result1 = 18 (5 + 3 + 10)
```

### hive.limit(min, max)
Set thread pool size limits.

- **Parameters**:
  - `min`: `integer` - Minimum number of threads
  - `max`: `integer` - Maximum number of threads
- **Description**:
  - Thread pool automatically scales based on load
  - Idle threads are automatically reclaimed after a period (60 seconds in production, 5 seconds in test)
- **Example**:
```lua validate
local hive = require "silly.hive"

hive.limit(2, 8)  -- Minimum 2, maximum 8 threads
```

### hive.threads()
Get the number of active threads in the thread pool.

- **Returns**: `integer` - Thread count
- **Example**:
```lua validate
local hive = require "silly.hive"

print("Active hive threads:", hive.threads())
```

### hive.prune()
Immediately clean up idle threads.

- **Description**: Usually not needed to call manually, thread pool manages automatically

## Usage Examples

### Example 1: Execute Blocking Commands

```lua validate
local hive = require "silly.hive"

-- Create worker to execute shell commands
local shell_worker = hive.spawn([[
    return function(cmd)
        local handle = io.popen(cmd)
        local result = handle:read("*a")
        handle:close()
        return result
    end
]])

-- Execute command (does not block main loop)
local output = hive.invoke(shell_worker, "ls -la")
print("Command output:", output)
```

### Example 2: Concurrent Blocking Operations

```lua validate
local hive = require "silly.hive"
local waitgroup = require "silly.sync.waitgroup"

hive.limit(1, 10)  -- Maximum 10 concurrent threads

local wg = waitgroup.new()
for i = 1, 5 do
    wg:fork(function()
        local worker = hive.spawn([[
            return function(n)
                os.execute("sleep 1")  -- Simulate blocking operation
                return n * 2
            end
        ]])
        local result = hive.invoke(worker, i)
        print("Result:", result)
    end)
end

wg:wait()
print("All tasks completed")
```

### Example 3: Worker Reuse

```lua validate
local hive = require "silly.hive"

-- Create reusable calculation worker
local calc_worker = hive.spawn([[
    local config = ...  -- Receive initialization config
    return function(operation, a, b)
        if operation == "add" then
            return a + b
        elseif operation == "mul" then
            return a * b
        end
    end
]], {precision = 2})

-- Call same worker multiple times
local sum = hive.invoke(calc_worker, "add", 10, 20)
local product = hive.invoke(calc_worker, "mul", 10, 20)
print(sum, product)  -- 30, 200
```

### Example 4: Exception Handling

```lua validate
local hive = require "silly.hive"

local worker = hive.spawn([[
    return function(x)
        if x < 0 then
            error("Negative number not allowed")
        end
        return math.sqrt(x)
    end
]])

local ok, result = pcall(hive.invoke, worker, -5)
if not ok then
    print("Worker error:", result)
end
```

### Example 5: Reading Files (used internally in silly.stdin)

```lua validate
-- silly.stdin internal implementation principle
local stdin_worker = hive.spawn([[
    local stdin = io.stdin
    return function(fn, ...)
        return stdin[fn](stdin, ...)
    end
]])

-- Read stdin in coroutine (non-blocking)
local line = hive.invoke(stdin_worker, "read", "*l")
```

## Worker Concurrency Model

Important characteristic: **A worker only processes one task at any time**.

```lua
local worker = hive.spawn([[ return function() os.execute("sleep 1") end ]])

local task = require "silly.task"

-- Two coroutines call same worker simultaneously
task.fork(function()
    print("Task 1 start")
    hive.invoke(worker)  -- Executes immediately
    print("Task 1 done")
end)

task.fork(function()
    print("Task 2 start")
    hive.invoke(worker)  -- Waits for Task 1 to complete
    print("Task 2 done")
end)

-- Output:
-- Task 1 start
-- Task 2 start
-- (after 1 second)
-- Task 1 done
-- (after another second)
-- Task 2 done
```

This is implemented using `silly.sync.mutex`:

```lua
-- hive.invoke internally uses mutex lock
function M.invoke(worker, ...)
    local l<close> = lock:lock(worker)  -- One lock per worker
    -- ... send task and wait for result
end
```

## Thread Pool Management

Hive automatically manages thread pool lifecycle:

1. **At startup**: No threads created
2. **When needed**: Creates threads based on task count (up to `max`)
3. **When idle**: Idle threads automatically reclaimed after 60 seconds (minimum `min` retained, 5 seconds in test environment)

Automatic cleanup implemented via timer:

```lua
-- Execute cleanup every second
local prune_timer
prune_timer = function()
    c.prune()
    time.after(1000, prune_timer)
end
```

## Notes

::: warning Worker Isolation
Each worker runs in an independent Lua VM and cannot access global variables from main VM. All data must be passed via parameters.
:::

::: warning Data Serialization
Parameters and return values pass through message queue and undergo serialization. Supported types:
- ✅ nil, boolean, number, string
- ✅ table (recursive serialization)
- ❌ function, thread, userdata (not serializable)
:::

::: danger Avoid Overuse
Hive is designed for operations that **must block**. Do not use it for:
- Pure Lua computations (executing directly in main thread is faster)
- Async I/O (use silly.net.* modules)
- Bypassing single-threaded model (introduces complexity)
:::

::: tip Use Cases
- Calling blocking system commands (`os.execute`)
- Reading stdin (`io.stdin:read`)
- Using C libraries that don't support async
- CPU-intensive computations (such as image processing, encryption)
:::

## See Also

- [silly.sync.mutex](./sync/mutex.md) - Mutex lock (used internally by hive)
- [silly.sync.waitgroup](./sync/waitgroup.md) - Coroutine wait group
- [silly](./silly.md) - Core module
