---
title: silly.sync.waitgroup
icon: tasks
category:
  - API Reference
tag:
  - Synchronization Primitive
  - Coroutine
  - Concurrency
---

# silly.sync.waitgroup

The WaitGroup module is used to wait for multiple coroutines to complete. Similar to Go's sync.WaitGroup, it allows a main coroutine to wait for a group of concurrent coroutines to finish executing.

## Module Import

```lua validate
local waitgroup = require "silly.sync.waitgroup"
```

## API Documentation

### waitgroup.new()

Creates a new waitgroup instance.

- **Returns**: `silly.sync.waitgroup` - Waitgroup object
- **Example**:
```lua validate
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()
```

### wg:fork(func)

Starts a coroutine and adds it to the waitgroup.

- **Parameters**:
  - `func`: `function` - The function to execute in the new coroutine
- **Returns**: `thread` - The newly created coroutine object
- **Description**:
  - Internal counter automatically increments
  - Counter automatically decrements when coroutine finishes
  - If the coroutine throws an error, it's automatically logged and continues
  - When counter reaches zero, waiting coroutines are automatically woken
- **Example**:
```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- Start a task
local co = wg:fork(function()
    time.sleep(100)
    print("Task completed")
end)
```

### wg:wait()

Waits for all coroutines started via `fork()` to complete.

- **Description**:
  - Blocks the current coroutine until all tasks complete (counter reaches zero)
  - Returns immediately if counter is already 0
  - Only one coroutine can wait on `wait()` at a time
- **Example**:
```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()

    for i = 1, 3 do
        wg:fork(function()
            time.sleep(100)
            print("Task", i, "done")
        end)
    end

    print("Waiting for all tasks...")
    wg:wait()
    print("All tasks completed!")
end)
```

## Usage Examples

### Example 1: Basic Usage - Concurrent Tasks

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local results = {}

    -- Start 5 concurrent tasks
    for i = 1, 5 do
        wg:fork(function()
            time.sleep(100 * i)  -- Simulate tasks with different durations
            results[i] = i * i
            print("Task", i, "completed, result:", results[i])
        end)
    end

    print("All tasks started, waiting...")
    wg:wait()
    print("All tasks finished!")

    -- Print results
    for i, v in ipairs(results) do
        print("Result[" .. i .. "] =", v)
    end
end)
```

### Example 2: Error Handling

Waitgroup automatically handles errors in coroutines without affecting other tasks:

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local success_count = 0

    for i = 1, 5 do
        wg:fork(function()
            time.sleep(50)
            if i == 3 then
                error("Task 3 failed!")  -- This error is caught and logged
            end
            success_count = success_count + 1
            print("Task", i, "succeeded")
        end)
    end

    wg:wait()
    print("Completed. Success count:", success_count)
end)
```

### Example 3: Batch Data Processing

Using waitgroup to process large amounts of data concurrently:

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()

    -- Simulate processing function
    local function process_item(id)
        time.sleep(50)  -- Simulate network request or computation
        return id * 2
    end

    local items = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
    local processed = {}

    for _, item in ipairs(items) do
        wg:fork(function()
            local result = process_item(item)
            processed[item] = result
            print("Processed item", item, "-> result:", result)
        end)
    end

    print("Processing", #items, "items concurrently...")
    wg:wait()
    print("All items processed!")

    -- Verify results
    for k, v in pairs(processed) do
        print("Item", k, "=", v)
    end
end)
```

### Example 4: Limiting Concurrency

While waitgroup itself doesn't limit concurrency, you can combine it with semaphores:

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local max_concurrent = 3
    local semaphore = 0

    local function acquire()
        while semaphore >= max_concurrent do
            time.sleep(10)
        end
        semaphore = semaphore + 1
    end

    local function release()
        semaphore = semaphore - 1
    end

    -- Start 10 tasks, but at most 3 execute concurrently
    for i = 1, 10 do
        acquire()
        wg:fork(function()
            print("Task", i, "started (concurrent:", semaphore .. ")")
            time.sleep(100)
            print("Task", i, "finished")
            release()
        end)
    end

    wg:wait()
    print("All tasks completed with concurrency limit:", max_concurrent)
end)
```

### Example 5: Nested Waitgroups

Waitgroups can be nested for hierarchical concurrency control:

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local main_wg = waitgroup.new()

    -- First group of tasks
    main_wg:fork(function()
        local sub_wg = waitgroup.new()
        print("Group 1 started")

        for i = 1, 3 do
            sub_wg:fork(function()
                time.sleep(50)
                print("  Group 1, Task", i, "done")
            end)
        end

        sub_wg:wait()
        print("Group 1 completed")
    end)

    -- Second group of tasks
    main_wg:fork(function()
        local sub_wg = waitgroup.new()
        print("Group 2 started")

        for i = 1, 2 do
            sub_wg:fork(function()
                time.sleep(80)
                print("  Group 2, Task", i, "done")
            end)
        end

        sub_wg:wait()
        print("Group 2 completed")
    end)

    main_wg:wait()
    print("All groups completed!")
end)
```

## Notes

### 1. Must Use Within Coroutines

Waitgroup's `wait()` method suspends the current coroutine, so it must be called within a coroutine:

```lua validate
local silly = require "silly"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    -- Correct: call wait() within a coroutine
    wg:wait()
end)

-- Wrong: cannot call wait() directly in main thread
-- local wg = waitgroup.new()
-- wg:wait()  -- This will fail!
```

### 2. Single Waiter Limitation

Only one coroutine can wait on `wait()` for a waitgroup instance. If you need multiple wait points, create multiple waitgroup instances.

### 3. Error Handling

Coroutines started with `fork()` that throw errors are automatically caught and logged, without affecting other coroutines. However, error messages are only logged, not directly accessible to the caller.

If you need to collect error information, handle it within the task function:

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local errors = {}

    for i = 1, 5 do
        wg:fork(function()
            local ok, err = pcall(function()
                time.sleep(50)
                if i == 3 then
                    error("simulated error")
                end
            end)
            if not ok then
                errors[i] = err
            end
        end)
    end

    wg:wait()

    -- Check errors
    for i, err in pairs(errors) do
        print("Task", i, "failed:", err)
    end
end)
```

### 4. Don't Modify Waitgroup Internal State in Tasks

While you can access `wg.count`, you should not manually modify it. All count management should be done automatically through `fork()` and internal mechanisms.

### 5. Avoid Deadlock

Ensure all `fork()` tasks eventually complete. If a task loops indefinitely or blocks permanently, `wait()` will never return:

```lua validate
local silly = require "silly"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()

    wg:fork(function()
        -- Wrong: infinite loop causes deadlock
        -- while true do
        --     silly.wait()
        -- end

        -- Correct: task finishes normally
        print("Task done")
    end)

    wg:wait()
    print("Success")
end)
```

## Integration with Other Modules

Waitgroup is commonly used with the following modules:

- [silly](../silly.md) - Coroutine scheduling and task management
- [silly.time](../time.md) - Timers and delays
- [silly.net.http](../net/http.md) - Concurrent HTTP requests
- [silly.net.tcp](../net/tcp.md) - Concurrent TCP connections

## See Also

- [silly](../silly.md) - Core module
- [silly.time](../time.md) - Timer module
