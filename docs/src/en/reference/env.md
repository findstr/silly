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
  - `key`: `string` - Environment variable name. Keys are looked up **as literal strings**: `env.get("server.port")` returns the entry stored under exactly `"server.port"`. Dot-separated keys work at runtime because `env.load` flattens nested tables in the config file into dotted flat keys (see [Configuration File Format](#configuration-file-format) below).
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
  - `key`: `string` - Environment variable name. As with `env.get`, the key is used **literally** — `env.set("server.port", 8080)` stores under the exact key `"server.port"`, not as a nested table.
  - `value`: `any` - Value to set (can be any type)
- **Example**:
```lua validate
local env = require "silly.env"

-- Set top-level key
env.set("debug", true)
env.set("timeout", 30)

-- Set nested key (literal string key — does not create a nested table)
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
  - Supports nested table structures; nested tables are **flattened** into dotted keys (`server = { port = 8080 }` becomes `env.get("server.port")`)
  - Inside a config file, `include(filename)` loads another config file into the same shared environment, and `ENV(name)` is shorthand for `os.getenv(name)`
  - **First-writer-wins**: if a key was already set (by command-line args or an earlier `env.set` / `env.load`), the file does **not** overwrite it — this is what makes `--key=value` overrides on the command line work without further coding
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

`include(name)` runs another config file in the same shared environment — the assignments inside that file land in the same key namespace, so split files compose by writing to top-level names.

Main configuration file `main.config.lua`:
```lua
-- main.config.lua
include("server.config.lua")
include("database.config.lua")
debug = true
```

Server configuration `server.config.lua`:
```lua
-- server.config.lua
server = {
    host = "0.0.0.0",
    port = 8080,
    workers = 4,
}
```

Database configuration `database.config.lua`:
```lua
-- database.config.lua
database = {
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

-- Access flattened keys
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

### 2. Using the include() and ENV() Helpers

Inside a config file the loader injects two helpers:

- `include(name)` — load another config file into the same shared environment. Assignments inside the included file land in the same flat key namespace; the call itself returns nothing, so write `include("server.config.lua")` (not `server = include(...)`).
- `ENV(name)` — short alias for `os.getenv(name)`, useful for pulling secrets/overrides from process environment variables.

```lua
include("server.config.lua")
include("database.config.lua")

-- Read from process environment
secret = ENV("APP_SECRET") or "dev-default"

cache = {
    enabled = true,
    ttl = 3600,
}
```

### 3. Lua Expressions

Configuration files support arbitrary Lua expressions. Use the loader-injected `ENV(name)` helper to pull values from the OS environment:

```lua
workers = ENV("NUM_WORKERS") or 4
timeout = 30 * 1000  -- 30 seconds, in milliseconds
allowed_ips = {
    "127.0.0.1",
    "192.168.1.0/24",
}
features = {
    cache = true,
    metrics = true,
    debug = ENV("DEBUG") == "1",
}
```

## Notes

::: tip Dot-Separated Keys
Both `env.get()` and `env.set()` use the **literal string** as the key. Dotted keys read like nested access only because `env.load` flattens nested tables into dotted flat keys when it loads the config:

```lua
-- In config.lua:
server = { tls = { enabled = true, cert = "/path/to/cert.pem" } }

-- After env.load("config.lua"):
env.get("server.tls.enabled") -- ✅ true
env.get("server.tls.cert")    -- ✅ "/path/to/cert.pem"

-- env.set goes by literal string key too — no nested table is created:
env.set("server.tls.enabled", false)  -- updates the flat key "server.tls.enabled"
```
:::

::: warning First-Writer-Wins
`env.load` **does not overwrite** keys that already exist. Command-line `--key=value` arguments are populated before any `env.load` call, so they always win. The same rule applies between successive `env.load` calls — the first file to set a key keeps that value.
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
