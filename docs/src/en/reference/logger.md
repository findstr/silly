---
title: silly.logger
icon: file-lines
category:
  - API Reference
tag:
  - Core
  - Logging
  - Debug
---

# silly.logger

Hierarchical logging system with support for dynamic log level adjustment and log file rotation.

## Module Import

```lua validate
local logger = require "silly.logger"
```

## Log Levels

### Level Constants

```lua
logger.DEBUG = 0  -- Debug information
logger.INFO  = 1  -- General information
logger.WARN  = 2  -- Warning information
logger.ERROR = 3  -- Error information
```

Log levels from low to high: DEBUG < INFO < WARN < ERROR

## API Functions

### logger.getlevel()
Get the current log level.

- **Returns**: `integer` - Current level (0-3)
- **Example**:
```lua validate
local logger = require "silly.logger"

local level = logger.getlevel()
print("Current log level:", level)
```

### logger.setlevel(level)
Set the log level.

- **Parameters**:
  - `level`: `integer` - New log level (0-3)
- **Description**: Only logs at or above the set level will be output
- **Example**:
```lua validate
local logger = require "silly.logger"

logger.setlevel(logger.INFO)  -- Only output INFO and above
logger.debug("This will not print")
logger.info("This will print")
```

## Log Output Functions

All non-formatted log functions (`debug`, `info`, `warn`, `error`) accept any number of arguments and serialize each value natively:

- **Strings** are printed as-is (no quoting).
- **Numbers** keep their integer/float representation (no `tostring()` required).
- **Booleans** print as `true` / `false`.
- **Nil** prints as `nil`.
- **Tables** are serialized as `{key=value, [1]=value, ...}` up to depth 5; deeper nesting is truncated with `{...}`.

Consecutive arguments are separated by a space; a newline is appended automatically.

### logger.debug(...)
Output DEBUG level log (level 0).

- **Parameters**: `...` - any number of values (strings, numbers, booleans, nil, tables)
- **Example**:
```lua validate
local logger = require "silly.logger"

local x, y = 10, 20
logger.debug("Variable x =", x, "y =", y)
logger.debug("user profile:", {id = 42, name = "alice", roles = {"admin", "owner"}})
```

### logger.info(...)
Output INFO level log (level 1).

```lua validate
local logger = require "silly.logger"

logger.info("Server started on port", 8080)
```

### logger.warn(...)
Output WARN level log (level 2).

```lua validate
local logger = require "silly.logger"

logger.warn("Connection timeout, retrying...")
```

### logger.error(...)
Output ERROR level log (level 3).

```lua validate
local logger = require "silly.logger"

local err = "connection refused"
logger.error("Database connection failed:", err)
```

## Formatted Log Functions

The `*f` variants (`debugf`, `infof`, `warnf`, `errorf`) take a format string whose **only supported placeholder is `%s`**. Use `%%` to emit a literal `%`. Any other conversion raises an error like `invalid option '%d' to 'format', only support '%s'`.

Despite the `%s` name, the placeholder uses the same native serializer as the non-formatted logs — **you do not need to `tostring()` numbers or tables yourself**.

### logger.debugf(format, ...)
Output formatted DEBUG log.

- **Parameters**:
  - `format`: `string` - format string; placeholder is `%s`, `%%` for a literal `%`
  - `...` - values for each placeholder (any loggable type)
- **Example**:
```lua validate
local logger = require "silly.logger"

local username = "alice"
local user_id = 12345
local timestamp = 1234567890

-- Numbers are serialized directly — no tostring() needed.
logger.debugf("User %s (ID: %s) logged in at %s", username, user_id, timestamp)

-- Tables work too.
logger.debugf("Request headers: %s", {["content-type"] = "application/json"})

-- Literal % via %%.
logger.debugf("progress: %s%%", 42)

-- NOT supported — will raise an error:
-- logger.debugf("id=%d count=%f", user_id, timestamp)
```

### logger.infof(format, ...)
Output formatted INFO log (**only supports `%s` placeholder**).

### logger.warnf(format, ...)
Output formatted WARN log (**only supports `%s` placeholder**).

### logger.errorf(format, ...)
Output formatted ERROR log (**only supports `%s` placeholder**).

## Usage Examples

### Example 1: Basic Logging

```lua validate
local logger = require "silly.logger"

logger.setlevel(logger.DEBUG)

logger.debug("Application starting")
logger.info("Listening on 0.0.0.0:8080")
logger.warn("Configuration file not found, using defaults")
logger.error("Failed to connect to database")
```

### Example 2: Formatted Logging

```lua validate
local logger = require "silly.logger"

local user_id = 12345
local action = "login"
local timestamp = os.time()

-- Native types (numbers, strings, tables) serialize directly — no tostring().
logger.infof("User [%s] performed action '%s' at %s", user_id, action, timestamp)

-- Tables are structured:
logger.infof("context: %s", {user = user_id, action = action})
```

### Example 3: Dynamic Log Level Adjustment

```lua validate
local logger = require "silly.logger"
local signal = require "silly.signal"

-- Use INFO level during normal operation
logger.setlevel(logger.INFO)

-- Switch to DEBUG mode via signal
-- Note: SIGUSR2 may be coalesced or dropped when the process is busy.
signal("SIGUSR1", function()
    if logger.getlevel() == logger.DEBUG then
        logger.setlevel(logger.INFO)
        logger.info("Switched to INFO level")
    else
        logger.setlevel(logger.DEBUG)
        logger.info("Switched to DEBUG level")
    end
end)
```

### Example 4: Conditional Logging

```lua validate
local logger = require "silly.logger"

local function process_request(req)
    if logger.getlevel() <= logger.DEBUG then
        -- Only serialize request in DEBUG mode (avoid performance overhead)
        logger.debug("Request:", json.encode(req))
    end

    -- Processing logic
    local ok, err = handle(req)
    if not ok then
        logger.error("Request processing failed:", err)
    end
end
```

## Log Rotation

Silly supports log file rotation. Sending `SIGUSR1` signal will reopen the log file:

```bash
# Perform log rotation
mv /path/to/app.log /path/to/app.log.old
kill -USR1 <pid>  # Reopen log file
```

This functionality is handled automatically internally by `silly.logger` module:

```lua
-- Internal implementation
signal("SIGUSR1", function(_)
    local path = env.get("logpath")
    if path then
        c.openfile(path)  -- Reopen log file
    end
end)
```

## Performance Optimization

The logging system is performance-optimized:

1. **Level Filtering**: Log function calls below current level are replaced with empty functions (nop), zero overhead
2. **Lazy Formatting**: Formatted logs (`*f` functions) only perform formatting when log will be output

```lua
-- This call is completely optimized away at INFO level
logger.setlevel(logger.INFO)
logger.debug("Expensive operation:", serialize_large_object())
-- serialize_large_object() will not be called
```

## Log Output Target

Log output target is configured via `logpath` environment variable:

- **Not set**: Output to standard error (stderr)
- **Set path**: Output to specified file

```bash
# Specify log file at startup
./silly main.lua --logpath=/var/log/myapp.log
```

## Notes

::: tip Dynamic Optimization
When calling `logger.setlevel()`, the logging system dynamically replaces log function implementations:
- Filtered levels → Empty function (nop)
- Visible levels → Actual C function
This ensures zero overhead for low-level log calls.
:::

::: warning Avoid Side Effects
Do not perform operations with side effects in log arguments:
```lua
-- ❌ Wrong: Even if log is filtered, counter will increment
logger.debug("Count:", counter = counter + 1)

-- ✅ Correct: Calculate first, then log
counter = counter + 1
logger.debug("Count:", counter)
```
:::

::: warning Format Limitations
Log formatting functions (`*f` series) **only support `%s` placeholder**:
```lua
local count = 42
local ratio = 0.75

-- ❌ Wrong: %d, %f, %x raise an error at call time
-- logger.infof("Count: %d, Ratio: %.2f", count, ratio)

-- ✅ Correct: use %s — numbers, booleans, tables serialize natively
logger.infof("Count: %s, Ratio: %s", count, ratio)

-- ✅ Or use the non-formatted function
logger.info("Count:", count, "Ratio:", ratio)
```

Unlike `string.format`, the `%s` placeholder here does not call `tostring()` — the underlying C serializer prints native Lua values directly, so you never need to convert numbers or tables yourself.
:::

## See Also

- [silly.signal](./signal.md) - Signal handling (for log rotation)
- [silly](./silly.md) - Core module
