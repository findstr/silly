---
title: silly.signal
icon: bell
category:
  - API Reference
tag:
  - Core
  - Signal
  - Unix
---

# silly.signal

Unix signal handling module for capturing and handling system signals (such as SIGINT, SIGTERM, etc.).

## Module Import

```lua validate
local signal = require "silly.signal"
```

::: tip Module Feature
The `silly.signal` module exports a function, not a table. Call the function directly to register signal handlers.
:::

## API

### signal(sig, handler)
Register a signal handler function.

- **Parameters**:
  - `sig`: `string` - Signal name (e.g., "SIGINT", "SIGTERM", "SIGUSR1", etc.)
  - `handler`: `async fun(sig:string)` - Signal handler function, receives signal name as parameter
- **Returns**: `function|nil` - Previously registered handler, or `nil` if signal not supported
- **Description**:
  - Signal handler executes asynchronously in a separate coroutine
  - If no handler is registered, default behavior is to call `silly.exit(0)` to exit the process
  - Can be called multiple times to replace the handler

## Supported Signals

Common Unix signals (specific support depends on operating system):

| Signal | Description | Typical Use |
|--------|-------------|-------------|
| SIGINT | Interrupt signal (Ctrl+C) | User terminates program |
| SIGTERM | Termination signal | Graceful shutdown |
| SIGUSR1 | User-defined signal 1 | Reload configuration |
| SIGUSR2 | User-defined signal 2 | May conflict with internal watchdog; can be dropped under load |
| SIGHUP | Hangup signal | Reload configuration |

## Usage Examples

### Example 1: Graceful Server Shutdown

```lua validate
local silly = require "silly"
local signal = require "silly.signal"

signal("SIGTERM", function(sig)
    print("Received", sig, "- shutting down gracefully")
    -- Stop accepting new connections
    -- stop_accepting_connections()
    -- Wait for existing requests to complete
    -- wait_for_pending_requests()
    -- Exit
    silly.exit(0)
end)
```

### Example 2: Reload Configuration

```lua validate
local signal = require "silly.signal"

signal("SIGUSR1", function(sig)
    print("Received", sig, "- reloading configuration")
    local ok, err = pcall(function()
        -- load_config()
        print("Configuration reloaded successfully")
    end)
    if not ok then
        print("Failed to reload configuration:", err)
    end
end)
```

### Example 3: Capture Multiple Signals

```lua validate
local silly = require "silly"
local signal = require "silly.signal"

local function graceful_shutdown(sig)
    print("Shutting down on signal:", sig)
    -- cleanup_resources()
    silly.exit(0)
end

signal("SIGINT", graceful_shutdown)
signal("SIGTERM", graceful_shutdown)
```

### Example 4: Debug Mode Toggle

```lua validate
local signal = require "silly.signal"
local logger = require "silly.logger"

-- Note: SIGUSR2 may be coalesced or dropped when the process is busy.
signal("SIGUSR1", function(sig)
    if logger.getlevel() == logger.DEBUG then
        logger.setlevel(logger.INFO)
        print("Debug logging disabled")
    else
        logger.setlevel(logger.DEBUG)
        print("Debug logging enabled")
    end
end)
```

## Default Behavior

Silly framework registers a default handler for `SIGINT`:

```lua
signal("SIGINT", function(_)
    silly.exit(0)
end)
```

You can override this default behavior:

```lua validate
local silly = require "silly"
local signal = require "silly.signal"

signal("SIGINT", function(sig)
    print("Custom SIGINT handler")
    -- Custom cleanup logic
    silly.exit(0)
end)
```

## Notes

::: warning Async Execution
Signal handlers execute in separate coroutines and do not block the main event loop. Handlers can use all async APIs (such as `time.sleep`, network calls, etc.).
:::

::: warning Signal number limit
Only signals numbered `0-31` are supported. Signals outside this range cannot be registered.
:::

::: warning Thread Safety
Signal handling is implemented through Silly's message system, ensuring thread safety. Actual signal capture happens at the C layer, then passed to the Lua layer through message queue for handling.
:::

::: warning SIGUSR2 may be dropped
`SIGUSR2` shares the internal watchdog channel and may be coalesced or dropped under load. Avoid using it for critical controls.
:::

::: danger Do Not Block for Long Time
Although signal handlers are async, it's recommended to complete processing quickly. Long-running cleanup operations should set timeouts or use `time.after` for async execution.
:::

## Integration with logger

The `silly.logger` module internally uses `SIGUSR1` signal to reopen log files (for log rotation):

```lua
-- SIGUSR1 handler registered internally by logger module
signal("SIGUSR1", function(_)
    local path = env.get("logpath")
    if path then
        c.openfile(path)  -- Reopen log file
    end
end)
```

If you need to use `SIGUSR1` yourself, be aware of this built-in behavior.

## Platform Compatibility

- **Linux/macOS**: Full support for all standard Unix signals
- **Windows**: Limited support (SIGINT, SIGTERM, etc.)

## See Also

- [silly](./silly.md) - Core module
- [silly.logger](./logger.md) - Logging system
