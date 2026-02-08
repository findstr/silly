---
title: silly.env
icon: gear
category:
  - API Reference
tag:
  - Core
  - Configuration
  - Environment Variables
---

# silly.env

Environment variable and configuration management module, supporting configuration loading from files and command-line arguments.

## Module Import

```lua validate
local env = require "silly.env"
```

## API Functions

### env.get(key)
Get the value of an environment variable.

- **Parameters**:
  - `key`: `string` - Environment variable name, supports dot-separated nested access (e.g., `"server.port"`)
- **Returns**: `any | nil` - Value of the environment variable, or `nil` if not found
- **Example**:
```lua validate
local env = require "silly.env"

local port = env.get("port")
local host = env.get("server.host")
local workers = env.get("server.workers")

print("Port:", port)
print("Host:", host)
print("Workers:", workers)
```

### env.set(key, value)
Set the value of an environment variable.

- **Parameters**:
  - `key`: `string` - Environment variable name, supports dot-separated nested keys (e.g., `"server.port"`)
  - `value`: `any` - Value to set (can be any type)
- **Example**:
```lua validate
local env = require "silly.env"

-- Set top-level key
env.set("debug", true)
env.set("timeout", 30)

-- Set nested key
env.set("server.port", 8080)
env.set("database.host", "127.0.0.1")

print("Debug mode:", env.get("debug"))
print("Server port:", env.get("server.port"))
```

### env.load(filename)
Load environment variables from a configuration file.

- **Parameters**:
  - `filename`: `string` - Configuration file path (Lua format)
- **Returns**:
  - `nil` on success
  - Error message on failure
- **Description**:
  - Configuration file is a Lua file containing variable assignment statements
  - Supports nested table structures
  - Supports `include(filename)` function to include other configuration files
  - Loaded configuration is merged into existing environment variables
- **Example**:

Configuration file `config.lua`:
```lua
-- config.lua
server = {
    host = "0.0.0.0",
    port = 8080,
    workers = 4,
}
database = {
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "password",
}
debug = false
```

Load configuration:
```lua validate
local env = require "silly.env"

local err = env.load("config.lua")
if err then
    print("Failed to load config:", err)
    return
end

local host = env.get("server.host")     -- "0.0.0.0"
local port = env.get("server.port")     -- 8080
local db_host = env.get("database.host") -- "127.0.0.1"
local debug = env.get("debug")          -- false

print(string.format("Server: %s:%s", host, tostring(port)))
print("Debug mode:", debug)
```

## Command-Line Arguments

`silly.env` automatically parses command-line arguments in `--key=value` format.

### Argument Format

```bash
./silly main.lua --key1=value1 --key2=value2
```

- Arguments must start with `--`
- Use `=` to separate key and value
- **Values are parsed as strings** (even if they look like numbers)

### Example

Startup command:
```bash
./silly server.lua --port=8080 --workers=4 --env=production
```

Access in code:
```lua validate
local env = require "silly.env"

local port = env.get("port")        -- "8080" (string)
local workers = env.get("workers")  -- "4" (string)
local environment = env.get("env")  -- "production"

-- Need to convert to numbers
port = tonumber(port) or 8080
workers = tonumber(workers) or 1

print(string.format("Starting server on port %d with %d workers", port, workers))
print("Environment:", environment)
```

## Usage Examples

### Example 1: Basic Configuration Management

```lua validate
local env = require "silly.env"

-- Load configuration file
env.load("config.lua")

-- Read configuration
local server_port = tonumber(env.get("server.port")) or 8080
local server_host = env.get("server.host") or "0.0.0.0"

print(string.format("Server will listen on %s:%d", server_host, server_port))
```

### Example 2: Command-Line Override

```lua validate
local env = require "silly.env"

-- Load configuration file first
env.load("config.lua")

-- Command-line arguments automatically override configuration file values
-- ./silly main.lua --server.port=9090

local port = tonumber(env.get("server.port")) or 8080
print("Port (can be overridden by command line):", port)
```

### Example 3: Using include() to Import Multiple Config Files

Main configuration file `main.config.lua`:
```lua
-- main.config.lua
server = include("server.config.lua")
database = include("database.config.lua")
debug = true
```

Server configuration `server.config.lua`:
```lua
-- server.config.lua
return {
    host = "0.0.0.0",
    port = 8080,
    workers = 4,
}
```

Database configuration `database.config.lua`:
```lua
-- database.config.lua
return {
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "password",
    database = "myapp",
}
```

Load main configuration:
```lua validate
local env = require "silly.env"

env.load("main.config.lua")

-- Access nested configuration
local server_port = env.get("server.port")     -- 8080
local db_host = env.get("database.host")       -- "127.0.0.1"
local db_name = env.get("database.database")   -- "myapp"

print("Server port:", server_port)
print("Database:", db_name)
```

### Example 4: Multi-Environment Configuration

Create configuration files for different environments:

`config.development.lua`:
```lua
server = {
    host = "127.0.0.1",
    port = 8080,
}
database = {
    host = "127.0.0.1",
    port = 3306,
}
debug = true
```

`config.production.lua`:
```lua
server = {
    host = "0.0.0.0",
    port = 80,
}
database = {
    host = "db.example.com",
    port = 3306,
}
debug = false
```

Load based on environment:
```lua validate
local env = require "silly.env"

-- Get environment from command line: ./silly main.lua --env=production
local environment = env.get("env") or "development"

-- Load configuration for the environment
local config_file = string.format("config.%s.lua", environment)
env.load(config_file)

local debug = env.get("debug")
print("Environment:", environment)
print("Debug mode:", debug)
```

### Example 5: Dynamic Configuration Modification

```lua validate
local env = require "silly.env"
local signal = require "silly.signal"

-- Initial configuration
env.load("config.lua")

-- Toggle debug mode dynamically via signal
-- Note: SIGUSR2 may be coalesced or dropped when the process is busy.
signal("SIGUSR1", function()
    local debug = env.get("debug")
    env.set("debug", not debug)
    print("Debug mode toggled:", env.get("debug"))
end)
```

## Configuration File Format

Configuration files are Lua files containing variable assignment statements, supporting the following features:

### 1. Nested Table Structures

```lua
server = {
    host = "0.0.0.0",
    port = 8080,
    tls = {
        enabled = true,
        cert = "/path/to/cert.pem",
        key = "/path/to/key.pem",
    }
}
```

Access:
```lua
env.get("server.tls.enabled")  -- true
env.get("server.tls.cert")     -- "/path/to/cert.pem"
```

### 2. Using the include() Function

```lua
server = include("server.config.lua")
database = include("database.config.lua")
-- Can also nest directly
cache = {
    enabled = true,
    ttl = 3600,
}
```

### 3. Lua Expressions

Configuration files support arbitrary Lua expressions:

```lua
workers = os.getenv("NUM_WORKERS") or 4
timeout = 30 * 1000  -- 30 seconds, in milliseconds
allowed_ips = {
    "127.0.0.1",
    "192.168.1.0/24",
}
features = {
    cache = true,
    metrics = true,
    debug = os.getenv("DEBUG") == "1",
}
```

## Notes

::: tip Nested Access
Both `env.get()` and `env.set()` support dot-separated nested key access:
```lua
env.get("server.port")        -- ✅ Supported
env.get("server.tls.enabled") -- ✅ Supported
env.set("server.port", 8080)  -- ✅ Supported
env.set("server.tls.enabled", true) -- ✅ Supported
```
:::

::: warning Command-Line Argument Types
Command-line arguments are always parsed as strings:
```bash
./silly main.lua --port=8080 --workers=4
```

```lua
env.get("port")     -- "8080" (string, not number)
env.get("workers")  -- "4" (string, not number)

-- Need to manually convert
local port = tonumber(env.get("port")) or 8080
local workers = tonumber(env.get("workers")) or 1
```
:::

::: warning Configuration File Security
Configuration files are executable Lua code, ensure:
1. Do not load untrusted configuration files
2. Configuration file permissions should be set to read-only (e.g., `chmod 600 config.lua`)
3. Do not store sensitive information in plain text (such as passwords)
:::

## Typical Use Cases

### 1. Server Startup Configuration

```lua validate
local env = require "silly.env"
local http = require "silly.net.http"

env.load("config.lua")

local port = tonumber(env.get("server.port")) or 8080
local workers = tonumber(env.get("server.workers")) or 1

http.listen {
    addr = "0.0.0.0:" .. port,
    handler = function(stream)
        stream:respond(200, {["content-type"] = "text/plain"})
        stream:closewrite("Hello!")
    end
}

print(string.format("HTTP server started on port %d with %d workers", port, workers))
```

### 2. Database Connection Configuration

```lua validate
local env = require "silly.env"
local mysql = require "silly.store.mysql"

env.load("config.lua")

local db = mysql.open {
    addr = string.format("%s:%s",
        env.get("database.host"),
        env.get("database.port")
    ),
    user = env.get("database.user"),
    password = env.get("database.password"),
    database = env.get("database.database"),
    charset = env.get("database.charset") or "utf8mb4",
}

print("Database connected")
```

### 3. Feature Flags

```lua validate
local env = require "silly.env"

env.load("config.lua")

local enable_cache = env.get("features.cache")
local enable_metrics = env.get("features.metrics")

if enable_cache then
    -- Enable cache module
    print("Cache enabled")
end

if enable_metrics then
    -- Enable metrics
    print("Metrics enabled")
end
```

## See Also

- [silly](./silly.md) - Core module
- [silly.logger](./logger.md) - Logging system (uses `logpath` environment variable)
- [Getting Started](/en/tutorials/) - Complete examples using configuration files
