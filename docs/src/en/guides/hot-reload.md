---
title: Hot Reload Operation Guide
icon: fire
order: 3
category:
  - Operation Guide
tag:
  - Hot Reload
  - Operations
  - Best Practices
---

# Hot Reload Operation Guide

This guide will teach you how to implement zero-downtime code hot reloading in the Silly framework, allowing you to fix bugs, update features, and adjust configurations without restarting the server.

## Introduction

### What is Hot Reload

Hot Reload refers to dynamically replacing code while a program is running, without needing to restart the process. This is particularly important for server applications that need to run 24/7.

### Advantages

- **Zero Downtime**: No need to restart services, transparent to users
- **Rapid Fixes**: Critical bugs can be fixed and deployed immediately
- **Risk Reduction**: Avoids state loss during restart process
- **Improved Efficiency**: Quickly verify code modifications during development and debugging

### Suitable Scenarios

Hot reloading is suitable for:

- **Bug Fixes**: Correcting business logic errors
- **Feature Updates**: Adding new features or optimizing existing ones
- **Parameter Adjustments**: Modifying configuration parameters, thresholds, etc.
- **Route Updates**: Updating HTTP route handlers
- **Algorithm Optimization**: Optimizing performance-critical code

### Scenarios Not Suitable for Hot Reload

The following situations are not recommended for hot reloading:

- **Core Framework Code**: Such as event loops, message systems, and other low-level code
- **Data Structure Changes**: Need to modify persistent data structures
- **Protocol Changes**: Need to modify network protocol formats
- **Dependency Upgrades**: Need to update C extension modules or third-party libraries
- **Large-Scale Refactoring**: Architectural adjustments involving multiple modules

## Basic Concepts

### Upvalues and Closures

The core of hot reloading is understanding Lua's closure mechanism:

```lua
-- External variable config captured by function get_timeout, becomes an upvalue
local config = {timeout = 1000}

function get_timeout()
    return config.timeout  -- config is an upvalue of get_timeout
end
```

When a function references an external local variable, that variable becomes the function's **upvalue**. During hot reloading, upvalue continuity between old and new functions must be maintained, otherwise runtime state will be lost.

### Upvalue Continuity

Directly replacing functions will cause upvalue loss:

```lua
-- Old code
local count = 100  -- Current value: 100
function increment()
    count = count + 1
    return count
end

-- Incorrect hot reload method
function increment()  -- New function's count is a brand new variable
    count = count + 2  -- count starts from initial value, not 100
    return count
end
-- Result: count value is lost
```

Correct hot reloading needs to connect the new function's upvalues to the old function's upvalues:

```lua
-- Use silly.patch to maintain upvalue continuity
local patch = require "silly.patch"
local P = patch.new()

-- Collect upvalues of old and new functions
local up_old = P:collectupval(old_module)
local up_new = P:collectupval(new_module)

-- Connect upvalues (new function uses old function's upvalues)
P:join(up_new, up_old)

-- Replace function reference
old_module.increment = new_module.increment
-- Result: new function inherits old function's count value (100)
```

## Using silly.patch

### Import Module

```lua
local patch = require "silly.patch"
```

### Basic Process

The standard hot reload process includes 5 steps:

```lua
-- 1. Create patch instance
local P = patch.new()

-- 2. Get old module reference
local old_module = require "mymodule"

-- 3. Load new module (temporary load, doesn't affect package.loaded)
package.loaded["mymodule"] = nil
local new_module = require "mymodule"
package.loaded["mymodule"] = old_module  -- Restore old module reference

-- 4. Collect and connect upvalues
local up_old = P:collectupval(old_module)
local up_new = P:collectupval(new_module)
local absent = P:join(up_new, up_old)  -- new -> old

-- 5. Replace function references
for name, fn in pairs(new_module) do
    if type(fn) == "function" then
        old_module[name] = fn
    end
end

-- Check if there are missing upvalues
if #absent > 0 then
    print("Warning: new module has upvalues not in old module:")
    for _, path in ipairs(absent) do
        print("  " .. path)
    end
end
```

### API Description

#### patch.new()

Creates a new patch instance. Each hot reload operation should use an independent instance.

```lua
local P = patch.new()
```

#### P:collectupval(module)

Collects all function upvalues in a module, returns an upvalue tree structure.

```lua
local up = P:collectupval(mymodule)
-- up is a tree structure containing all function and upvalue information
```

#### P:join(up_new, up_old)

Connects new function upvalues to old function upvalues, maintaining state continuity.

```lua
local absent = P:join(up_new, up_old)
-- absent is an array containing upvalue paths that exist in new module but not in old module
```

**Note the order**: The first parameter is the new module's upvalues, the second parameter is the old module's upvalues.

## Complete Examples

### Example 1: Hot Reload HTTP Routes

Suppose you have an HTTP service that needs to modify the handling logic of a certain route.

**Old Version (route.lua v1):**

```lua
local M = {}
local access_count = 0

function M.handle_request(req, res)
    access_count = access_count + 1
    res:status(200)
    res:send("Hello, visitor #" .. access_count)
end

function M.get_stats()
    return {total = access_count}
end

return M
```

**New Version (route.lua v2):**

```lua
local M = {}
local access_count = 0
local error_count = 0  -- New error counter

function M.handle_request(req, res)
    access_count = access_count + 1

    -- New error handling logic
    if not req.params.name then
        error_count = error_count + 1
        res:status(400)
        res:send("Error: name is required")
        return
    end

    res:status(200)
    res:send("Hello, " .. req.params.name .. " (visitor #" .. access_count .. ")")
end

function M.get_stats()
    return {
        total = access_count,
        errors = error_count  -- New field
    }
end

return M
```

**Hot Reload Script (hotfix_route.lua):**

```lua
local patch = require "silly.patch"
local logger = require "silly.logger"

-- Get old module
local route = require "route"

-- Record state before hot reload
local old_stats = route.get_stats()
logger.info("Before hotfix - Stats:", old_stats)

-- Load new module
package.loaded["route"] = nil
local route_new = require "route"
package.loaded["route"] = route  -- Restore old reference

-- Perform hot reload
local P = patch.new()
local up_old = P:collectupval(route)
local up_new = P:collectupval(route_new)
local absent = P:join(up_new, up_old)

-- Replace functions
for name, fn in pairs(route_new) do
    if type(fn) == "function" then
        route[name] = fn
    end
end

-- Check results
if #absent > 0 then
    logger.warn("New upvalues detected:", table.concat(absent, ", "))
    -- error_count is a new upvalue, needs manual initialization
    -- Since join creates new upvalues with default value 0, usually no extra handling needed
end

-- Verify state preservation
local new_stats = route.get_stats()
logger.info("After hotfix - Stats:", new_stats)

logger.info("Hotfix applied successfully")
```

### Example 2: Hot Reload Business Logic Module

**Old Version (game.lua v1):**

```lua
local M = {}
local player_data = {}

function M.add_player(id, name)
    player_data[id] = {
        name = name,
        score = 0
    }
end

function M.add_score(id, points)
    if player_data[id] then
        player_data[id].score = player_data[id].score + points
    end
end

function M.get_player(id)
    return player_data[id]
end

return M
```

**New Version (game.lua v2):**

```lua
local M = {}
local player_data = {}

function M.add_player(id, name)
    player_data[id] = {
        name = name,
        score = 0,
        level = 1,  -- New level system
        exp = 0     -- New experience points
    }
end

function M.add_score(id, points)
    if player_data[id] then
        player_data[id].score = player_data[id].score + points

        -- New: gain experience
        local exp = math.floor(points / 10)
        M.add_exp(id, exp)
    end
end

-- New function
function M.add_exp(id, exp)
    local player = player_data[id]
    if not player then
        return
    end

    player.exp = player.exp + exp

    -- Level up logic
    while player.exp >= player.level * 100 do
        player.exp = player.exp - player.level * 100
        player.level = player.level + 1
    end
end

function M.get_player(id)
    return player_data[id]
end

return M
```

**Hot Reload Script (hotfix_game.lua):**

```lua
local patch = require "silly.patch"
local logger = require "silly.logger"

local game = require "game"

-- Load new version
package.loaded["game"] = nil
local game_new = require "game"
package.loaded["game"] = game

-- Perform hot reload
local P = patch.new()
local up_old = P:collectupval(game)
local up_new = P:collectupval(game_new)
local absent = P:join(up_new, up_old)

-- Replace functions
for name, fn in pairs(game_new) do
    if type(fn) == "function" then
        game[name] = fn
    end
end

-- Data migration: add new fields for existing players
-- Note: directly manipulate player_data in upvalues
local player_count = 0
for id, player in pairs(up_old.add_player.upvals.player_data.val) do
    if not player.level then
        player.level = 1
        player.exp = 0
        player_count = player_count + 1
    end
end

logger.info("Migrated " .. player_count .. " existing players")
logger.info("Hotfix applied successfully")
```

### Example 3: Hot Reload Configuration File

**Old Version (config.lua v1):**

```lua
local M = {}

local settings = {
    max_connections = 1000,
    timeout = 30,
    log_level = "INFO"
}

function M.get(key)
    return settings[key]
end

function M.set(key, value)
    settings[key] = value
end

function M.get_all()
    return settings
end

return M
```

**New Version (config.lua v2):**

```lua
local M = {}

local settings = {
    max_connections = 1000,
    timeout = 30,
    log_level = "INFO",
    enable_cache = true,      -- New
    cache_ttl = 300          -- New
}

-- New: configuration validation
local validators = {
    max_connections = function(v)
        return type(v) == "number" and v > 0 and v <= 10000
    end,
    timeout = function(v)
        return type(v) == "number" and v > 0
    end,
    log_level = function(v)
        local valid = {DEBUG = true, INFO = true, WARN = true, ERROR = true}
        return valid[v] ~= nil
    end
}

function M.get(key)
    return settings[key]
end

function M.set(key, value)
    -- New: configuration validation
    if validators[key] and not validators[key](value) then
        error("Invalid value for " .. key)
    end
    settings[key] = value
end

function M.get_all()
    return settings
end

return M
```

**Hot Reload Script (hotfix_config.lua):**

```lua
local patch = require "silly.patch"
local logger = require "silly.logger"

local config = require "config"

-- Save current configuration values
local old_settings = config.get_all()

-- Load new version
package.loaded["config"] = nil
local config_new = require "config"
package.loaded["config"] = config

-- Perform hot reload
local P = patch.new()
local up_old = P:collectupval(config)
local up_new = P:collectupval(config_new)
local absent = P:join(up_new, up_old)

-- Special handling: merge new configuration items
local old_settings_uv = up_old.get.upvals.settings.val
local new_settings_uv = up_new.get.upvals.settings.val

for key, value in pairs(new_settings_uv) do
    if old_settings_uv[key] == nil then
        old_settings_uv[key] = value
        logger.info("Added new config: " .. key .. " = " .. tostring(value))
    end
end

-- Replace functions (new set function includes validation logic)
for name, fn in pairs(config_new) do
    if type(fn) == "function" then
        config[name] = fn
    end
end

logger.info("Config hotfix applied successfully")
```

## Best Practices

### 1. Module Organization Recommendations

#### Use Module Tables Instead of Independent Functions

```lua
-- ✅ Recommended: use module table
local M = {}

function M.foo()
    -- ...
end

function M.bar()
    -- ...
end

return M
```

```lua
-- ❌ Not Recommended: independent function
local function foo()
    -- ...
end

return foo  -- Difficult to hot reload multiple functions
```

#### Keep Upvalue Structure Stable

```lua
-- ✅ Recommended: maintain upvalue structure
-- Old version
local config = {timeout = 1000}
function M.get_timeout()
    return config.timeout
end

-- New version (add new field, keep original structure)
local config = {timeout = 2000, retry = 3}
function M.get_timeout()
    return config.timeout
end
```

```lua
-- ❌ Not Recommended: delete upvalue
-- Old version
local config = {timeout = 1000}
function M.get_timeout()
    return config.timeout
end

-- New version (deleted config upvalue)
function M.get_timeout()
    return 2000  -- Hardcoded, loses flexibility
end
```

### 2. Modules to Avoid Hot Reloading

The following types of modules are not recommended for hot reloading:

```lua
-- ❌ Core event loop
local silly = require "silly"

-- ❌ Low-level network modules
local tcp = require "silly.net.tcp"

-- ❌ Modules with complex state
local M = {}
local state_machine = create_complex_state()  -- State machine difficult to migrate

-- ✅ Business logic modules (suitable for hot reload)
local M = {}
function M.handle_user_request(req)
    -- Pure business logic, easy to hot reload
end
```

### 3. Version Management

Add version information to modules for easier tracking and verification:

```lua
local M = {
    VERSION = "1.2.3",
    BUILD_TIME = "2025-10-14T12:00:00Z"
}

-- Business logic...

return M
```

Check version during hot reload:

```lua
local expected_version = "1.2.2"
if mymodule.VERSION ~= expected_version then
    error(string.format(
        "Version mismatch: expected %s, got %s",
        expected_version,
        mymodule.VERSION
    ))
end

-- Perform hot reload...

-- Verify after update
assert(mymodule.VERSION == "1.2.3", "Hotfix failed: version not updated")
```

### 4. Rollback Mechanism

Prepare a rollback plan in case hot reload fails:

```lua
local patch = require "silly.patch"
local logger = require "silly.logger"

-- Backup old version
local backup = {}
for name, fn in pairs(mymodule) do
    backup[name] = fn
end

-- Attempt hot reload
local success, err = pcall(function()
    -- Load new version
    package.loaded["mymodule"] = nil
    local mymodule_new = require "mymodule"
    package.loaded["mymodule"] = mymodule

    -- Perform hot reload
    local P = patch.new()
    local up_old = P:collectupval(mymodule)
    local up_new = P:collectupval(mymodule_new)
    local absent = P:join(up_new, up_old)

    -- Check missing upvalues
    if #absent > 3 then  -- Assume maximum 3 new upvalues allowed
        error("Too many missing upvalues: " .. table.concat(absent, ", "))
    end

    -- Replace functions
    for name, fn in pairs(mymodule_new) do
        if type(fn) == "function" then
            mymodule[name] = fn
        end
    end
end)

if not success then
    logger.error("Hotfix failed:", err)
    logger.info("Rolling back...")

    -- Roll back to old version
    for name, fn in pairs(backup) do
        mymodule[name] = fn
    end

    logger.info("Rollback completed")
else
    logger.info("Hotfix applied successfully")
end
```

### 5. Record Hot Reload Logs

```lua
local logger = require "silly.logger"
local time = require "silly.time"

local function log_hotfix(module_name, version_old, version_new, success, error_msg)
    local log_entry = {
        timestamp = time.now(),
        module = module_name,
        version_old = version_old,
        version_new = version_new,
        success = success,
        error = error_msg
    }

    if success then
        logger.info("Hotfix applied:", log_entry)
    else
        logger.error("Hotfix failed:", log_entry)
    end

    -- Optional: write to database or file
end

-- Usage example
local old_version = mymodule.VERSION
-- Perform hot reload...
local success, err = pcall(apply_hotfix)
local new_version = mymodule.VERSION

log_hotfix("mymodule", old_version, new_version, success, err)
```

### 6. Handling Asynchronous Context

If module functions are referenced by timers or coroutines, special handling is needed:

```lua
-- Problem example: timer holds old function reference
local M = {}
local count = 0

function M.timer_func()
    count = count + 1
    print("Count:", count)
end

-- Start timer
local time = require "silly.time"
local function repeat_call(ms, func)
    local function loop()
        func()
        time.after(ms, loop)
    end
    loop()
end
repeat_call(1000, M.timer_func)  -- Timer holds reference to timer_func
```

Solution 1: Use indirect invocation

```lua
local M = {}
local count = 0
local timer_func  -- Forward declaration

function timer_func()
    count = count + 1
    print("Count:", count)
end

-- Use wrapper function
function M.timer_wrapper()
    timer_func()  -- Indirect call via upvalue
end

M.timer_func = timer_func

-- Start timer
repeat_call(1000, M.timer_wrapper)

-- During hot reload, timer_func is an upvalue of timer_wrapper
-- Can be correctly updated via patch
```

Solution 2: Restart timer

```lua
-- Stop old timer
if M.timer_handle then
    time.cancel(M.timer_handle)
end

-- Perform hot reload...

-- Start new timer
M.timer_handle = repeat_call(1000, M.timer_func)
```

### 7. Test Hot Reload

Be sure to thoroughly test in a test environment before using in production:

```lua
-- test_hotfix.lua
local patch = require "silly.patch"
local testaux = require "test.testaux"

-- Load old version
local M1 = require "mymodule"

-- Perform some operations, establish state
M1.add_data("key1", "value1")
M1.add_data("key2", "value2")
assert(M1.count() == 2, "Initial state")

-- Perform hot reload
package.loaded["mymodule"] = nil
local M2 = require "mymodule"
package.loaded["mymodule"] = M1

local P = patch.new()
local up1 = P:collectupval(M1)
local up2 = P:collectupval(M2)
P:join(up2, up1)

for k, v in pairs(M2) do
    if type(v) == "function" then
        M1[k] = v
    end
end

-- Verify state preservation
assert(M1.count() == 2, "State preserved after hotfix")
assert(M1.get_data("key1") == "value1", "Data preserved")

-- Test new functionality
M1.new_function()
assert(M1.count() == 3, "New function works")

print("Hotfix test passed")
```

## Troubleshooting

### Common Error 1: Upvalue Loss

**Symptoms**:

```
attempt to index a nil value (upvalue 'config')
```

**Cause**: New function's upvalues were not correctly connected to old function's upvalues.

**Solution**:

```lua
-- Check absent list
local absent = P:join(up_new, up_old)
if #absent > 0 then
    print("Missing upvalues:", table.concat(absent, ", "))
    -- Manually handle missing upvalues
end
```

### Common Error 2: Parameter Order Wrong

**Symptoms**: After hot reload, module state is reset to initial values.

**Cause**: Wrong parameter order for `P:join()`.

**Solution**:

```lua
-- ❌ Wrong: reversed order
P:join(up_old, up_new)  -- Will overwrite old with new upvalues

-- ✅ Correct: new -> old
P:join(up_new, up_old)  -- New function uses old upvalues
```

### Common Error 3: Global Variable Pollution

**Symptoms**: Unexpected global variables appear after hot reload.

**Cause**: New module uses global variables.

**Solution**:

```lua
-- Use isolated environment to load new module
local ENV = setmetatable({}, {__index = _ENV})
local new_module = loadfile("mymodule.lua", "bt", ENV)()

-- After hot reload, merge needed global variables to _ENV
for k, v in pairs(ENV) do
    if not _ENV[k] or type(v) == "function" then
        _ENV[k] = v
    end
end
```

### Common Error 4: Circular Reference Issues

**Symptoms**: Stack overflow or infinite loop after hot reload.

**Cause**: Circular references between modules not properly handled.

**Solution**:

```lua
-- Update all modules first, then connect upvalues
local modules = {"module_a", "module_b", "module_c"}
local old_modules = {}
local new_modules = {}

-- 1. Load all new modules
for _, name in ipairs(modules) do
    old_modules[name] = require(name)
    package.loaded[name] = nil
    new_modules[name] = require(name)
    package.loaded[name] = old_modules[name]
end

-- 2. Perform hot reload uniformly
for _, name in ipairs(modules) do
    local P = patch.new()
    local up_old = P:collectupval(old_modules[name])
    local up_new = P:collectupval(new_modules[name])
    P:join(up_new, up_old)

    for k, v in pairs(new_modules[name]) do
        if type(v) == "function" then
            old_modules[name][k] = v
        end
    end
end
```

### Debugging Tips

#### 1. Print Upvalue Tree Structure

```lua
local function print_upval_tree(up, indent)
    indent = indent or 0
    local prefix = string.rep("  ", indent)

    for name, info in pairs(up) do
        if type(info) == "table" and info.upvals then
            print(prefix .. name .. ":")
            for uname, uinfo in pairs(info.upvals) do
                print(prefix .. "  [" .. uinfo.idx .. "] " .. uname ..
                      " (" .. uinfo.utype .. ")")
            end
            print_upval_tree(info.upvals, indent + 1)
        end
    end
end

-- Usage
local up = P:collectupval(mymodule)
print_upval_tree(up)
```

#### 2. Compare Old and New Upvalues

```lua
local function compare_upvals(up_old, up_new)
    local old_keys = {}
    local new_keys = {}

    for name, info in pairs(up_old) do
        if info.upvals then
            for uname in pairs(info.upvals) do
                old_keys[name .. "." .. uname] = true
            end
        end
    end

    for name, info in pairs(up_new) do
        if info.upvals then
            for uname in pairs(info.upvals) do
                local key = name .. "." .. uname
                new_keys[key] = true
                if not old_keys[key] then
                    print("+ New upvalue: " .. key)
                end
            end
        end
    end

    for key in pairs(old_keys) do
        if not new_keys[key] then
            print("- Removed upvalue: " .. key)
        end
    end
end

-- Usage
compare_upvals(up_old, up_new)
```

#### 3. Verify Hot Reload Results

```lua
local function verify_hotfix(old_module, new_module)
    -- Check if functions are correctly replaced
    for name, fn in pairs(new_module) do
        if type(fn) == "function" then
            if old_module[name] ~= fn then
                print("Warning: " .. name .. " not replaced")
            end
        end
    end

    -- Check version number
    if old_module.VERSION and new_module.VERSION then
        if old_module.VERSION == new_module.VERSION then
            print("Warning: VERSION not updated")
        else
            print("Version updated: " .. old_module.VERSION ..
                  " -> " .. new_module.VERSION)
        end
    end
end

-- Usage
verify_hotfix(old_module, new_module)
```

## Production Environment Practices

### Executing Hot Reload via Console

The Silly framework supports dynamically injecting code through console, which is the most common hot reload method in production environments.

**1. Prepare Hot Reload Script**

Save the hot reload script to the server (e.g., `/tmp/hotfix_20251014.lua`):

```lua
-- /tmp/hotfix_20251014.lua
local patch = require "silly.patch"
local logger = require "silly.logger"

logger.info("Starting hotfix 20251014...")

-- Perform hot reload
local mymodule = require "mymodule"
package.loaded["mymodule"] = nil
local mymodule_new = require "mymodule"
package.loaded["mymodule"] = mymodule

local P = patch.new()
local up_old = P:collectupval(mymodule)
local up_new = P:collectupval(mymodule_new)
local absent = P:join(up_new, up_old)

for name, fn in pairs(mymodule_new) do
    if type(fn) == "function" then
        mymodule[name] = fn
    end
end

logger.info("Hotfix 20251014 completed successfully")

if #absent > 0 then
    logger.warn("New upvalues:", table.concat(absent, ", "))
end
```

**2. Connect to Console and Execute**

```bash
# Connect to console (assuming console listens on 127.0.0.1:2345)
telnet 127.0.0.1 2345

# Or use nc
nc 127.0.0.1 2345
```

Execute in console:

```
console> inject /tmp/hotfix_20251014.lua
[INFO] Starting hotfix 20251014...
[INFO] Hotfix 20251014 completed successfully
Inject file:/tmp/hotfix_20251014.lua Success
```

### Batch Hot Reload

If you need to update multiple servers:

```bash
#!/bin/bash
# batch_hotfix.sh

SERVERS="server1:2345 server2:2345 server3:2345"
HOTFIX_SCRIPT="/tmp/hotfix_20251014.lua"

for server in $SERVERS; do
    echo "Applying hotfix to $server..."
    echo "inject $HOTFIX_SCRIPT" | nc -w 3 ${server/:/ }

    if [ $? -eq 0 ]; then
        echo "✓ $server hotfix completed"
    else
        echo "✗ $server hotfix failed"
    fi
done
```

## See Also

- [silly.patch API Reference](/en/reference/patch.md) - Detailed API documentation
- [silly.console](/en/reference/console.md) - Console usage guide
- [Lua Debug Library](https://www.lua.org/manual/5.4/manual.html#6.10) - Lua debug library documentation
