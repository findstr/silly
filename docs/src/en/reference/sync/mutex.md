---
title: silly.sync.mutex
icon: lock
category:
  - API Reference
tag:
  - Synchronization
  - Mutex
  - Coroutine
---

# silly.sync.mutex

The coroutine mutex module provides a reentrant mutex mechanism for protecting shared resources between coroutines. Supports Lua 5.4's `<close>` syntax for automatic lock release.

## Module Import

```lua validate
local mutex = require "silly.sync.mutex"
```

## API Documentation

### mutex.new()

Creates a new mutex manager.

- **Returns**: `silly.sync.mutex` - Mutex manager object
- **Description**: Each lock manager can manage locks for multiple different keys
- **Example**:

```lua validate
local mutex = require "silly.sync.mutex"

local m = mutex.new()
```

### mutex:lock(key)

Acquires a lock for the specified key. If the lock is held by another coroutine, the current coroutine waits until the lock is released.

- **Parameters**:
  - `key`: `any` - Lock identifier, can be any type (usually a table or string)
- **Returns**: `proxy` - Lock proxy object with the following methods and metamethods:
  - `unlock()`: Manually release the lock
  - `__close`: Metamethod supporting `<close>` syntax for automatic release
- **Features**:
  - **Reentrant**: The same coroutine can acquire the same lock multiple times, requiring corresponding releases
  - **Blocking Wait**: If the lock is held by another coroutine, the current coroutine suspends to wait
  - **Automatic Release**: Using `<close>` syntax automatically releases the lock when the scope ends
- **Example**:

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = "resource_1"

task.fork(function()
    local lock<close> = m:lock(key)
    print("Lock acquired")
    -- Critical section code
    -- Lock is automatically released when leaving scope
end)
```

### proxy:unlock()

Manually releases the lock.

- **Description**:
  - For reentrant locks, you must call `unlock()` the same number of times to fully release
  - If using `<close>` syntax, manual calls are usually not needed
  - Can call `unlock()` early to release the lock prematurely
- **Example**:

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = "resource_1"

task.fork(function()
    local lock = m:lock(key)
    print("Lock acquired")
    -- Critical section code
    lock:unlock()  -- Manual release
    print("Lock released")
end)
```

## Usage Examples

### Example 1: Basic Mutual Exclusion

```lua validate
local silly = require "silly"
local time = require "silly.time"
local mutex = require "silly.sync.mutex"
local waitgroup = require "silly.sync.waitgroup"

local m = mutex.new()
local key = {}
local counter = 0

local wg = waitgroup.new()

-- Create 5 coroutines accessing shared resource concurrently
for i = 1, 5 do
    wg:fork(function()
        local lock<close> = m:lock(key)
        -- Critical section: read-modify-write
        local old_value = counter
        time.sleep(10)  -- Simulate time-consuming operation
        counter = old_value + 1
        print(string.format("Coroutine %d: %d -> %d", i, old_value, counter))
        -- lock is automatically released here
    end)
end

wg:wait()
print("Final counter:", counter)  -- Output: Final counter: 5
```

### Example 2: Reentrant Lock

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = {}

task.fork(function()
    -- First lock acquisition
    local lock1<close> = m:lock(key)
    print("First lock acquired")

    -- Same coroutine can acquire the same lock again (reentrant)
    local lock2<close> = m:lock(key)
    print("Second lock acquired (reentrant)")

    -- lock2 released here, but lock1 still held
    do
        local lock3<close> = m:lock(key)
        print("Third lock acquired (reentrant)")
    end  -- lock3 released

    print("Still holding outer locks")

    -- lock2 and lock1 released sequentially here
end)
```

### Example 3: Manual Lock Release

```lua validate
local silly = require "silly"
local time = require "silly.time"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = "database"

task.fork(function()
    local lock = m:lock(key)
    print("Lock acquired")

    -- Critical section operation
    print("Accessing database...")
    time.sleep(100)

    -- Release lock early manually
    lock:unlock()
    print("Lock released early")

    -- Continue executing non-critical section code
    print("Doing other work...")
    time.sleep(100)
end)
```

### Example 4: Multiple Independent Locks

```lua validate
local silly = require "silly"
local time = require "silly.time"
local mutex = require "silly.sync.mutex"
local waitgroup = require "silly.sync.waitgroup"

local m = mutex.new()
local key1 = "resource_1"
local key2 = "resource_2"

local wg = waitgroup.new()

wg:fork(function()
    local lock<close> = m:lock(key1)
    print("Task 1: locked resource_1")
    time.sleep(100)
    print("Task 1: done")
end)

wg:fork(function()
    local lock<close> = m:lock(key2)
    print("Task 2: locked resource_2")
    time.sleep(100)
    print("Task 2: done")
end)

-- These two tasks can execute concurrently as they lock different resources

wg:wait()
```

### Example 5: Exception Safety

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = {}

task.fork(function()
    local lock<close> = m:lock(key)
    print("Lock acquired")

    -- Even if an error occurs, <close> ensures the lock is released
    error("Something went wrong!")

    -- This line won't execute
    print("This won't print")

    -- But the lock will be automatically released when the coroutine exits
end)
```

### Example 6: Simulating Read-Write Scenarios

```lua validate
local silly = require "silly"
local time = require "silly.time"
local mutex = require "silly.sync.mutex"
local waitgroup = require "silly.sync.waitgroup"

local m = mutex.new()
local cache = {}
local cache_key = "cache_lock"

local function read_cache(key)
    local lock<close> = m:lock(cache_key)
    return cache[key]
end

local function write_cache(key, value)
    local lock<close> = m:lock(cache_key)
    cache[key] = value
    time.sleep(10)  -- Simulate write delay
end

local wg = waitgroup.new()

-- Write operation
wg:fork(function()
    write_cache("user:1", {name = "Alice", age = 30})
    print("Written to cache")
end)

-- Read operation (waits for write to complete)
wg:fork(function()
    time.sleep(5)  -- Read later
    local data = read_cache("user:1")
    if data then
        print("Read from cache:", data.name)
    else
        print("Cache miss")
    end
end)

wg:wait()
```

## Notes

### 1. Must Use Within Coroutines

Mutexes depend on Silly's coroutine scheduling system and must be used within a coroutine context:

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()

-- Wrong: cannot use directly in main thread
-- local lock = m:lock("key")  -- This will cause problems

-- Correct: use within a coroutine
task.fork(function()
    local lock<close> = m:lock("key")
    print("This is correct")
end)
```

### 2. Recommend Using `<close>` Syntax

Using Lua 5.4's `<close>` syntax ensures the lock will definitely be released, even if exceptions occur:

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()

task.fork(function()
    -- Recommended: use <close>
    local lock<close> = m:lock("key")
    -- ... critical section code ...
    -- Automatically released, even if exceptions occur
end)
```

### 3. Avoid Deadlock

Pay attention to lock acquisition order to avoid circular waiting leading to deadlock:

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local waitgroup = require "silly.sync.waitgroup"

local m = mutex.new()
local key1 = "A"
local key2 = "B"

local wg = waitgroup.new()

-- Deadlock example (don't do this!)
wg:fork(function()
    local lock1<close> = m:lock(key1)
    print("Task 1: locked A")
    silly.sleep(10)
    local lock2<close> = m:lock(key2)  -- Wait for B
    print("Task 1: locked B")
end)

wg:fork(function()
    local lock2<close> = m:lock(key2)
    print("Task 2: locked B")
    silly.sleep(10)
    local lock1<close> = m:lock(key1)  -- Wait for A, deadlock!
    print("Task 2: locked A")
end)

-- Solution: unify lock acquisition order
-- Always lock key1 first, then key2
```

### 4. Understanding Reentrancy

The same coroutine can acquire the same lock multiple times, but requires corresponding releases:

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = {}

task.fork(function()
    local lock1 = m:lock(key)  -- 1st acquisition
    local lock2 = m:lock(key)  -- 2nd acquisition (reentrant)
    local lock3 = m:lock(key)  -- 3rd acquisition (reentrant)

    lock3:unlock()  -- Release 3rd
    lock2:unlock()  -- Release 2nd
    lock1:unlock()  -- Release 1st, lock fully released

    -- Now other coroutines can acquire this lock
end)
```

### 5. Key Selection

- `key` can be any Lua value (string, number, table, etc.)
- Recommend using tables as keys to avoid naming conflicts:

```lua validate
local mutex = require "silly.sync.mutex"

local m = mutex.new()

-- Recommended: use unique tables as keys
local user_lock = {}
local cache_lock = {}

-- Not recommended: strings may conflict
-- local lock1 = m:lock("user")
-- local lock2 = m:lock("user")  -- Same string, will block
```

## Performance Notes

- Lock objects use object pools (`lockcache` and `proxycache`) to reduce GC pressure
- Uses weak tables (`weak mode = "v"`) to automatically recycle unused lock objects
- Lock acquisition and release operations are O(1) time complexity
- Suitable for high-frequency lock operation scenarios

## See Also

- [silly.sync.waitgroup](./waitgroup.md) - Coroutine wait group
- [silly](../silly.md) - Core module
- [silly.time](../time.md) - Timer module
