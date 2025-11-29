# Contributing

We welcome contributions to the Silly framework. To maintain code quality and consistency, please adhere to the following guidelines when submitting code.

## Naming Conventions

### 1. Public API

All public-facing APIs should be named using one or two words, without underscores. The preferred style is all lowercase.

- **GOOD:** `silly.fork`, `silly.net.connect`
- **BAD:** `silly.socket_close`

### 2. Internal Functions

Internal functions, which are not part of the public API, can use underscores. A leading underscore is encouraged to explicitly mark functions as "private" or "internal".

- **GOOD:** `_dispatch_wakeup`, `local my_internal_helper`

### 3. Constructors

Constructors should be named based on the type of table they return:

- **`new()`**: Use `new` for constructors that return an object supporting method call syntax (`:` or `.`). The implementation can use metatables, closures, or direct function assignment - the key is that the returned object has callable methods.
  - **Standard usage**: `M.new()` - Use dot notation for direct construction without inheritance
  - **Inheritance support**: `M:new()` - Use colon notation when implementing inheritance. Note that inheritance applies to the metatable (e.g., if `A` inherits from `B`, then `A.id` might be resolved through `B.id` via `__index`)
- **`create()`**: Use `create` for constructors that return a plain data table or configuration object without methods (i.e., a pure data structure).

**Example of inheritance pattern:**
```lua
-- parent.lua
local M = {}
M.__index = M
function M.new()
    return setmetatable({}, M)
end
M.id = "parent"

-- child.lua
local Parent = require "parent"
local M = setmetatable({}, {__index = Parent})
M.__index = M
function M:new()  -- Use colon to inherit from Parent
    return setmetatable({}, self)
end
-- M.id will resolve to "parent" through inheritance
```
