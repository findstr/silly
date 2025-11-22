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

### logger.debug(...)
Output DEBUG level log (level 0).

- **Parameters**: `...` - Any number of arguments, will be converted to strings and concatenated
- **Example**:
```lua validate
local logger = require "silly.logger"

local x, y = 10, 20
logger.debug("Variable x =", x, "y =", y)
```

### logger.info(...)
Output INFO level log (level 1).

- **Parameters**: `...` - Any number of arguments
- **Example**:
```lua validate
local logger = require "silly.logger"

logger.info("Server started on port", 8080)
```

### logger.warn(...)
Output WARN level log (level 2).

- **Parameters**: `...` - Any number of arguments
- **Example**:
```lua validate
local logger = require "silly.logger"

logger.warn("Connection timeout, retrying...")
```

### logger.error(...)
Output ERROR level log (level 3).

- **Parameters**: `...` - Any number of arguments
- **Example**:
```lua validate
local logger = require "silly.logger"

local err = "connection refused"
logger.error("Database connection failed:", err)
```

## Formatted Log Functions

### logger.debugf(format, ...)
Output formatted DEBUG log.

- **Parameters**:
  - `format`: `string` - Format string (**only supports `%s` placeholder**)
  - `...` - Format arguments
- **Description**:
  - **Important**: Only supports `%s` placeholder, does not support `%d`, `%f`, `%x`, etc.
  - All arguments will be converted to strings using `%s`
  - Unlike `string.format`, need to convert numbers to strings first
- **Example**:
```lua validate
local logger = require "silly.logger"

local username = "alice"
local user_id = 12345
local timestamp = 1234567890

-- Correct: All arguments use %s
logger.debugf("User %s (ID: %s) logged in at %s", username, tostring(user_id), tostring(timestamp))

-- Wrong: Does not support %d, %f formats
-- logger.debugf("User ID: %d, time: %f", user_id, timestamp)  -- Will not work correctly
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

-- Note: Only supports %s, need to manually convert numbers to strings
logger.infof("User [%s] performed action '%s' at %s",
    tostring(user_id), action, tostring(timestamp))
```

### Example 3: Dynamic Log Level Adjustment

```lua validate
local logger = require "silly.logger"
local signal = require "silly.signal"

-- Use INFO level during normal operation
logger.setlevel(logger.INFO)

-- Switch to DEBUG mode via signal
signal("SIGUSR2", function()
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

-- ❌ Wrong: Does not support %d, %f, %x formats
-- logger.infof("Count: %d, Ratio: %.2f", count, ratio)

-- ✅ Correct: Use %s and manually convert
logger.infof("Count: %s, Ratio: %s", tostring(count), tostring(ratio))

-- ✅ Or use non-formatted function
logger.info("Count:", count, "Ratio:", ratio)
```

This design is to maintain consistency with `string.format`, where all fields can be handled with `%s`.
:::

## See Also

- [silly.signal](./signal.md) - Signal handling (for log rotation)
- [silly](./silly.md) - Core module
