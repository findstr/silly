---
title: silly.task
icon: list-unordered
category:
  - API Reference
tag:
  - Core
  - Coroutine
  - Scheduler
---

# silly.task

Coroutine management and task scheduling module, providing coroutine creation, suspension, wakeup, and distributed tracing functionality.

## Module Import

```lua validate
local task = require "silly.task"
```

## Coroutine Management

### task.running()
Get the currently running coroutine.

- **Returns**: `thread` - Current coroutine
- **Example**:
```lua validate
local task = require "silly.task"

local current_task = task.running()
```

### task.fork(func, userdata)
Create and schedule a new coroutine to execute an async task.

- **Parameters**:
  - `func`: `async fun()` - Async function
  - `userdata`: `any` (optional) - Parameter passed to wakeup (usually for internal mechanisms, rarely used in business layer)
- **Returns**: `thread` - Newly created coroutine
- **Example**:
```lua validate
local task = require "silly.task"

task.fork(function()
    print("Hello from forked task")
end)
```

### task.wait()
Suspend the current coroutine and wait to be woken up.

- **Returns**: `any` - Data passed during wakeup
- **Note**: Must be called within a coroutine, and coroutine status must be "RUN"
- **Example**:
```lua validate
local task = require "silly.task"

task.fork(function()
    local data = task.wait()
    print("Woken up with data:", data)
end)
```

### task.wakeup(task, result)
Wake up a waiting coroutine.

- **Parameters**:
  - `task`: `thread` - Coroutine to wake up
  - `result`: `any` - Data to pass to the coroutine
- **Note**: Target coroutine status must be "WAIT"
- **Example**:
```lua validate
local task = require "silly.task"
local time = require "silly.time"

local t
task.fork(function()
    t = task.running()
    local data = task.wait()
    print("Got:", data)
end)

-- Delayed wakeup to ensure coroutine has entered wait state
time.after(10, function()
    task.wakeup(t, "hello")
end)
```

### task.status(task)
Get the current status of a coroutine.

- **Parameters**:
  - `task`: `thread` - Target coroutine
- **Returns**: `string|nil` - Status string, possible values:
  - `"RUN"` - Running
  - `"WAIT"` - Waiting
  - `"READY"` - In ready queue
  - `"SLEEP"` - Sleeping
  - `"EXIT"` - Exited
  - `nil` - Coroutine destroyed

## Task Statistics

### task.taskstat()
Get the number of tasks waiting to execute in the ready queue.

- **Returns**: `integer` - Task count

### task.tasks()
Get status information of all coroutines (for debugging).

- **Returns**: `table` - Coroutine status table, format:
```lua
{
    [thread] = {
        traceback = "stack trace string",
        status = "RUN|WAIT|READY|..."
    }
}
```

## Distributed Tracing

### task.tracenode(nodeid)
Set the node ID of the current node (for trace ID generation).

- **Parameters**:
  - `nodeid`: `integer` - Node ID (16-bit, 0-65535)
- **Example**:
```lua validate
local task = require "silly.task"

-- Set node ID at service startup
task.tracenode(1)  -- Set as node 1
```

### task.tracespawn()
Create a new root trace ID and set it as the current coroutine's trace ID.

- **Returns**: `integer` - Previous trace ID (can be used for later restoration)
- **Example**:
```lua validate
local task = require "silly.task"

-- Create new trace ID when handling new HTTP request
local old_trace = task.tracespawn()
-- ... process request ...
-- Restore old trace context if needed
task.traceset(old_trace)
```

### task.traceset(id)
Set the trace ID of the current coroutine.

- **Parameters**:
  - `id`: `integer` - Trace ID
- **Returns**: `integer` - Previous trace ID

### task.tracepropagate()
Get trace ID for cross-service propagation (preserves root trace, replaces node ID with current node).

- **Returns**: `integer` - Trace ID for propagation
- **Example**:
```lua validate
local task = require "silly.task"

-- Propagate trace ID in RPC call
local trace_id = task.tracepropagate()
-- Send trace_id to remote service
```

## Advanced API

::: danger Internal API Warning
The following functions start with `_` and are internal implementation details. **They should not be used in business code**.
:::

### task._task_create(f)
Create coroutine (internal API).

### task._task_resume(t, ...)
Resume coroutine execution (internal API).

### task._task_yield(...)
Suspend current coroutine (internal API).

### task._dispatch_wakeup()
Dispatch tasks in the ready queue (internal API).

### task._start(func)
Start main coroutine (internal API).

### task._exit(status)
Exit process (internal API, use `silly.exit` instead).

### task.task_hook(create, term)
Set hooks for coroutine creation and termination (advanced usage).

- **Parameters**:
  - `create`: `function|nil` - Creation hook
  - `term`: `function|nil` - Termination hook
- **Returns**: `function, function` - Current resume and yield functions
