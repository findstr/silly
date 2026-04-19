---
title: silly.sync.singleflight
icon: arrows-to-circle
category:
  - API Reference
tag:
  - Synchronization
  - Coroutine
  - Deduplication
---

# silly.sync.singleflight

`silly.sync.singleflight` coalesces concurrent calls for the same key so that only one underlying invocation runs at a time. All coroutines that ask for the same key while the work is in flight share the result of that one invocation. This is the classic pattern for cache miss stampedes, thundering-herd upstream calls, and expensive per-key compute.

## Module Import

```lua
local singleflight = require "silly.sync.singleflight"
```

## API

### singleflight.new(fn)

Create a singleflight group bound to the handler function `fn`. All `call(key)` invocations run `fn(key)` underneath; the result is what `call` returns.

- **Parameters**:
  - `fn`: `fun(key):...` - the function to execute once per key. May return multiple values.
- **Returns**: `silly.sync.singleflight` - a group object.

### group:call(key)

Run (or join) the in-flight computation for `key`.

- **Parameters**:
  - `key`: any Lua value usable as a table key (typically a string)
- **Returns**: the values returned by `fn(key)` for whichever coroutine actually executed it.
- **Async**: if a call for `key` is already in flight, suspends the current coroutine until it completes.
- **Errors**: if `fn` raises, every waiter for that key re-raises the same error via Lua's `error()`. Use `pcall` / `silly.pcall` at the call site if you need to tolerate failures.

## Example: Cache fill

```lua
local silly = require "silly"
local task = require "silly.task"
local singleflight = require "silly.sync.singleflight"

local db = {}  -- your database module
local cache = {}

local sf = singleflight.new(function(user_id)
    -- Only one DB hit per user_id even under heavy concurrency.
    local user = db.load_user(user_id)
    cache[user_id] = user
    return user
end)

local function get_user(user_id)
    return cache[user_id] or sf:call(user_id)
end

-- 100 concurrent requests for user 42 result in one DB call.
for i = 1, 100 do
    task.fork(function()
        local user = get_user(42)
        -- ...
    end)
end
```

## Semantics

- **Per-key**: `call("a")` and `call("b")` run in parallel; only duplicate calls for the same key are coalesced.
- **No memoization**: once `fn` returns, the next `call(key)` runs `fn` again. Pair it with your own cache if you want persistence.
- **Error propagation**: an error from `fn` propagates to every waiter. Survivors are free to retry on the next call (a new flight).
