---
title: silly.patch
icon: arrows-rotate
category:
  - API Reference
tag:
  - Tools
  - Hot Reload
  - Operations
---

# silly.patch

Module hot reload tool supporting runtime replacement of Lua functions and modules without restarting the server to fix bugs or update functionality.

## Module Import

```lua validate
local patch = require "silly.patch"
```

## Core Concepts

The core of hot reloading is maintaining function **upvalue** continuity:

- **Upvalue**: External variables captured by function closure
- **Problem**: Directly replacing function loses original upvalue state
- **Solution**: Connect new function's upvalues to old function's upvalues through debug library

## API

### patch.new()
Create a new patch instance.

- **Returns**: `Patch` - Patch object
- **Description**: Each hot reload operation should use independent patch instance

### patch:collectupval(f_or_t)
Collect all upvalues of a function or module.

- **Parameters**:
  - `f_or_t`: `function|table` - Function or module table
- **Returns**: `table` - Upvalue tree
- **Description**:
  - If function, collects upvalues of that function and all nested functions
  - If table, collects upvalues of all functions in table
  - Returned tree structure contains upvalue name, type, value, index, etc.

### patch:join(f1, up1, f2, up2)
Connect upvalues of old and new functions.

- **Parameters**:
  - `f1`: `function|table` - Old function or module
  - `up1`: `table` - Old function's upvalue tree (returned by `collectupval`)
  - `f2`: `function|table` - New function or module
  - `up2`: `table` - New function's upvalue tree
- **Returns**: `table` - List of missing upvalue paths
- **Description**:
  - Connects `f1`'s upvalues to `f2`'s upvalues
  - Only connects upvalues that exist in both
  - For `_ENV` upvalue, automatically sets to global environment
  - Returns upvalue paths that exist in `f2` but not in `f1`

## Usage Examples

### Example 1: Basic Usage

```lua validate
local patch = require "silly.patch"

-- Create patch instance
local P = patch.new()
print("Patch instance created")
```

::: tip Important Note
The patch module is for advanced hot reload scenarios. Due to its complexity, recommend thorough testing in test environment before using in production. For specific usage, refer to test cases in `test/testpatch.lua`.
:::

### Example 2: Simple Module Hot Reload

```lua
-- Old module mymodule.lua v1
local M = {}
local count = 0

function M.increment()
    count = count + 1
    return count
end

function M.get()
    return count
end

return M
```

```lua
-- New module mymodule.lua v2 (bug fix: add step)
local M = {}
local count = 0
local step = 2  -- New config

function M.increment()
    count = count + step  -- Use step
    return count
end

function M.get()
    return count
end

function M.set_step(n)  -- New function
    step = n
end

return M
```

Hot reload script:

```lua
local patch = require "silly.patch"
local mymodule = require "mymodule"

-- Load new version
package.loaded["mymodule"] = nil
local mymodule_new = require "mymodule"
package.loaded["mymodule"] = mymodule  -- Restore old version reference

-- Perform hot reload
local P = patch.new()
local up1 = P:collectupval(mymodule)
local up2 = P:collectupval(mymodule_new)
local absent = P:join(mymodule_new, up2, mymodule, up1)  -- Args: new func, new upval, old func, old upval

-- Replace functions
for name, fn in pairs(mymodule_new) do
    mymodule[name] = fn
end

-- Check missing upvalues
if #absent > 0 then
    print("Warning: missing upvalues:", table.concat(absent, ", "))
end
```

### Example 3: Hot Reload via console Injection

Can execute hot reload through `silly.console`'s `INJECT` command:

Create hot reload script `/tmp/hotfix.lua`:

```lua
-- /tmp/hotfix.lua
local patch = require "silly.patch"
local mymodule = require "mymodule"

-- Load new version (assuming already deployed to server)
package.loaded["mymodule"] = nil
local mymodule_new = require "mymodule"
package.loaded["mymodule"] = mymodule  -- Restore old version reference

-- Hot reload
local P = patch.new()
local up1 = P:collectupval(mymodule)
local up2 = P:collectupval(mymodule_new)
local absent = P:join(mymodule_new, up2, mymodule, up1)

-- Replace functions
for name, fn in pairs(mymodule_new) do
    mymodule[name] = fn
end

print("Hotfix applied successfully")
if #absent > 0 then
    print("Warning: absent upvalues:", table.concat(absent, ", "))
end
```

Execute in console:

```
console> inject /tmp/hotfix.lua
Hotfix applied successfully
Inject file:/tmp/hotfix.lua Success
```

## Upvalue Tree Structure

The upvalue tree structure returned by `collectupval`:

```lua
{
    ["function_name"] = {
        val = function,      -- Function itself
        upvals = {           -- Upvalue table
            ["upvalue_name"] = {
                idx = integer,     -- Upvalue index
                utype = "string",  -- Upvalue type
                val = any,         -- Upvalue value
                upid = lightuserdata, -- Upvalue ID (for comparison)
                upvals = table,    -- If function, recursive upvalues
            }
        }
    }
}
```

## Notes

::: warning Compatibility Requirements
New and old module upvalue structures should be as similar as possible. If new module removes old module's upvalues, may cause runtime errors.
:::

::: warning Timers and Coroutines
If upvalues are referenced by timers or coroutines, need special care. May need to manually handle function references in these async contexts.
:::

::: danger State Consistency
Hot reload does not automatically migrate data structures. If new version modifies data structures (like table fields), need to write migration code manually.
:::

::: tip Testing Recommendation
Before hot reload, should thoroughly test in test environment to ensure upvalue connections are correct. Can use returned `absent` list to check for missing upvalues.
:::

## Limitations

1. **C Functions**: Cannot hot reload C functions
2. **Metatables**: Does not automatically update metatables, need manual handling
3. **Global References**: If other modules hold references to old functions, won't automatically update
4. **Coroutines**: Already executing coroutine stack frames won't update
5. **Circular References**: Complex circular references may need manual handling

## Best Practices

### 1. Use Module Tables

Define modules as tables rather than independent functions for batch replacement:

```lua
-- Good practice
local M = {}
function M.foo() ... end
function M.bar() ... end
return M

-- Poor practice
local function foo() ... end
local function bar() ... end
return foo
```

### 2. Maintain Upvalue Structure

New version should maintain old version's upvalue structure:

```lua
-- Old version
local config = {timeout = 1000}
function M.get_timeout()
    return config.timeout
end

-- Good new version (maintains config)
local config = {timeout = 2000, retry = 3}  -- Can add new fields
function M.get_timeout()
    return config.timeout
end

-- Poor new version (removes config)
function M.get_timeout()
    return 2000  -- Hardcoded, loses flexibility
end
```

### 3. Check absent List

```lua
local absent = P:join(M2, up2, M1, up1)  -- New module, new upval, old module, old upval
if #absent > 0 then
    print("Warning: missing upvalues:")
    for _, path in ipairs(absent) do
        print("  ", path)
    end
    -- Decide whether to continue
end
```

### 4. Log Hot Reload Operations

```lua
local logger = require "silly.logger"
logger.info("Applying hotfix for mymodule")
-- ... execute hot reload ...
logger.info("Hotfix applied successfully")
```

### 5. Version Control

```lua
-- Add version number in module
local M = {
    VERSION = "1.2.3"
}

-- Check version during hot reload
if mymodule.VERSION ~= "1.2.2" then
    error("Version mismatch, expected 1.2.2, got " .. mymodule.VERSION)
end
```

## Implementation Principle

Hot reload relies on Lua's debug library:

- `debug.getupvalue()`: Get function's upvalue
- `debug.setupvalue()`: Set function's upvalue
- `debug.upvalueid()`: Get upvalue's unique identifier
- `debug.upvaluejoin()`: Make two functions share same upvalue

Basic workflow:

1. Collect all upvalues of old function (including nested functions)
2. Collect all upvalues of new function
3. Traverse new function's upvalues, find same-named upvalues in old function
4. Use `upvaluejoin` to connect new function's upvalues to old function's upvalues
5. Replace old function references with new function

## See Also

- [silly.console](./console.md) - Console (INJECT command)
- [Lua Debug Library](https://www.lua.org/manual/5.4/manual.html#6.10) - Lua debug library documentation
- [Lua Closures](https://www.lua.org/pil/6.1.html) - Lua closures and upvalues
