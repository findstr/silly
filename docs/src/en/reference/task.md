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
local trace = require "silly.trace"
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

### task.readycount()
Get the number of tasks waiting to execute in the ready queue.

- **Returns**: `integer` - Task count

### task.inspect()
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

The task module supports associating distributed trace IDs with each coroutine for cross-service request chain tracing.

> 📖 **Full Documentation**: For detailed distributed tracing API and usage guide, please see the **[silly.trace](./trace.md)** module documentation.

**Quick Example**:

```lua validate
local trace = require "silly.trace"

-- Set node ID (at service startup)
trace.setnode(1)

-- Create new trace (when handling new request)
trace.spawn()

-- Propagate trace to downstream (when calling other services)
local traceid = trace.propagate()

-- Attach upstream trace (when receiving request)
trace.attach(upstream_traceid)
```

**Related APIs**:
- [trace.setnode()](./trace.md#tracesetnodenodeid) - Set node ID
- [trace.spawn()](./trace.md#tracespawn) - Create new trace
- [trace.attach()](./trace.md#traceattachid) - Attach trace
- [trace.propagate()](./trace.md#tracepropagate) - Propagate trace

## Advanced API

::: danger Internal API Warning
The following functions start with `_` and are internal implementation details. **They should not be used in business code**.
:::

### task._create(f)
Create coroutine (internal API).

### task._resume(t, ...)
Resume coroutine execution (internal API).

### task._yield(...)
Suspend current coroutine (internal API).

### task._dispatch_wakeup()
Dispatch tasks in the ready queue (internal API).

### task._start(func)
Start main coroutine (internal API).

### task._exit(status)
Exit process (internal API, use `silly.exit` instead).

### task.hook(create, term)
Set hooks for coroutine creation and termination (advanced usage).

- **Parameters**:
  - `create`: `function|nil` - Creation hook
  - `term`: `function|nil` - Termination hook
- **Returns**: `function, function` - Current resume and yield functions
