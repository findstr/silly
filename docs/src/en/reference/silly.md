---
title: silly
icon: gear
category:
  - API Reference
tag:
  - Core
  - Coroutine
  - Scheduler
---

# silly

Core module providing basic utility functions and process management functionality.

## Module Import

```lua validate
local silly = require "silly"
```

## Constant Properties

### silly.pid
- **Type**: `integer`
- **Description**: Current process ID

### silly.gitsha1
- **Type**: `string`
- **Description**: Git SHA1 commit hash at build time

### silly.version
- **Type**: `string`
- **Description**: Silly framework version number

## Core Functions

### silly.genid()
Generate a globally unique ID.

- **Returns**: `integer` - Unique ID
- **Example**:
```lua validate
local silly = require "silly"

local id = silly.genid()
```

### silly.tostring(ptr)
Convert a C pointer to its string representation.

- **Parameters**:
  - `ptr`: `lightuserdata` - C pointer
- **Returns**: `string` - Hexadecimal string representation of the pointer

### silly.register(msgtype, handler)
Register a message handler (internal API, should not be used in business code).

- **Parameters**:
  - `msgtype`: `integer` - Message type
  - `handler`: `function` - Handler function

## Coroutine Management

Please refer to the [silly.task](./task.md) module.

### silly.exit(status)
Exit the Silly process.

- **Parameters**:
  - `status`: `integer` - Exit code
- **Example**:
```lua validate
local silly = require "silly"

silly.exit(0)  -- Normal exit
```

## Task Statistics

Please refer to the [silly.task](./task.md) module.

## Distributed Tracing

Please refer to the [silly.task](./task.md) module.

## Error Handling

### silly.error(errmsg)
Log error messages and stack traces.

- **Parameters**:
  - `errmsg`: `string` - Error message

### silly.pcall(f, ...)
Protected call function, catches errors and generates stack traces.

- **Parameters**:
  - `f`: `function` - Function to call
  - `...`: Function arguments
- **Returns**:
  - `boolean` - Whether successful
  - `...` - Function results on success, error message on failure

## Advanced API

::: danger Internal API Warning
The following functions start with `_` and are internal implementation details. **They should not be used in business code**.
:::

### silly._start(func)
Start main coroutine (internal API).

### silly._dispatch_wakeup()
Dispatch tasks in the ready queue (internal API).

## See Also

- [silly.task](./task.md) - Coroutine management and task scheduling
- [silly.time](./time.md) - Timers and time management
- [silly.hive](./hive.md) - Worker thread pool
- [silly.sync.*](../sync/) - Synchronization primitives
