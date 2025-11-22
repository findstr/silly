---
title: silly.sync.channel
icon: arrows-left-right
category:
  - API Reference
tag:
  - Synchronization
  - Coroutine
  - Channel
---

# silly.sync.channel

The `silly.sync.channel` module provides a Channel implementation for inter-coroutine communication. A channel is a thread-safe queue that supports a Multi-Producer Single-Consumer (MPSC) model.

## Module Import

```lua validate
local channel = require "silly.sync.channel"
```

## Core Concepts

Channel is a FIFO (First-In-First-Out) queue with the following features:

- **MPSC Model**: Supports multiple producers writing concurrently, but only one consumer can read at a time
- **Blocking Semantics**: When the channel is empty, `pop` operations block the current coroutine until data is available
- **Direct Transfer**: If a coroutine is waiting for data, `push` operations directly wake the waiting coroutine without going through the queue
- **Close Mechanism**: Channels can be closed; after closing, no more data can be written, but remaining data can still be read

## API Reference

### channel.new()

Creates a new channel instance.

- **Returns**: `silly.sync.channel` - The newly created channel object

**Example**:
```lua validate
local channel = require "silly.sync.channel"

local ch = channel.new()
print("Channel created")
```

### channel:push(data)

Pushes data to the channel. If a coroutine is waiting for data, it wakes that coroutine directly; otherwise, the data is placed in the queue.

- **Parameters**:
  - `data`: `any` - The data to send (cannot be `nil`)
- **Returns**:
  - `success`: `boolean` - Whether the push was successful
  - `error`: `string|nil` - Error message (if failed)
    - `"nil data"` - Attempted to push a nil value
    - `"channel closed"` - Channel is closed

**Example**:
```lua validate
local channel = require "silly.sync.channel"

local ch = channel.new()

-- Push data
local ok, err = ch:push("hello")
assert(ok, err)

-- Attempt to push nil (will fail)
ok, err = ch:push(nil)
assert(not ok)
assert(err == "nil data")
```

### channel:pop()

Reads data from the channel. If the channel is empty, the current coroutine blocks until data is available or the channel is closed.

- **Returns**:
  - `data`: `any|nil` - The data read, or `nil` on failure
  - `error`: `string|nil` - Error message
    - `"channel closed"` - Channel is closed and empty

**Note**: This function is asynchronous and suspends the current coroutine.

**Example**:
```lua validate
local silly = require "silly"
local channel = require "silly.sync.channel"

local ch = channel.new()

local task = require "silly.task"

-- Push data in another coroutine
task.fork(function()
    ch:push("world")
end)

-- Block waiting for data
local data, err = ch:pop()
assert(data == "world", "Should receive 'world'")
assert(err == nil)
```

### channel:close()

Closes the channel. After closing, no new data can be pushed, but remaining data in the queue can still be read. If a coroutine is waiting for data, it will be woken and return an error.

- **Returns**: None

**Example**:
```lua validate
local channel = require "silly.sync.channel"

local ch = channel.new()

ch:push("message1")
ch:push("message2")
ch:close()

-- Can still read existing data
assert(ch:pop() == "message1")
assert(ch:pop() == "message2")

-- Reading from empty closed channel returns error
local data, err = ch:pop()
assert(data == nil)
assert(err == "channel closed")

-- Cannot push to closed channel
local ok, err = ch:push("message3")
assert(not ok)
assert(err == "channel closed")
```

### channel:clear()

Clears all pending data in the channel and resets queue indices.

- **Returns**: None

**Example**:
```lua validate
local silly = require "silly"
local channel = require "silly.sync.channel"

local ch = channel.new()

-- Push multiple messages
ch:push("msg1")
ch:push("msg2")
ch:push("msg3")

-- Clear the channel
ch:clear()

local task = require "silly.task"

-- Channel is now empty, pop will block
task.fork(function()
    ch:push("new message")
end)

local data = ch:pop()
assert(data == "new message")
```

## Usage Examples

### Producer-Consumer Pattern

This is a typical producer-consumer example demonstrating how to use channels to pass data between coroutines.

```lua validate
local channel = require "silly.sync.channel"
local waitgroup = require "silly.sync.waitgroup"

local ch = channel.new()
local wg = waitgroup.new()

-- Producer: generate 5 tasks
wg:fork(function()
    for i = 1, 5 do
        print("Producer: sending", i)
        ch:push(i)
    end
    ch:close()  -- Close channel when done
    print("Producer: done")
end)

-- Consumer: process tasks until channel closes
wg:fork(function()
    while true do
        local data, err = ch:pop()
        if err == "channel closed" then
            print("Consumer: channel closed")
            break
        end
        print("Consumer: received", data)
    end
    print("Consumer: done")
end)

wg:wait()
```



### Buffered Task Queue

Channels have built-in queues that can be used as task buffers.

```lua validate
local channel = require "silly.sync.channel"
local waitgroup = require "silly.sync.waitgroup"
local time = require "silly.time"

local ch = channel.new()
local wg = waitgroup.new()

-- Fast producer: push multiple tasks at once
wg:fork(function()
    for i = 1, 10 do
        ch:push({id = i, task = "process data"})
    end
    ch:close()
    print("Producer finished quickly")
end)

-- Slow consumer: processing each task takes time
wg:fork(function()
    while true do
        local task, err = ch:pop()
        if err == "channel closed" then
            break
        end
        print("Processing task", task.id)
        time.sleep(100)  -- Simulate time-consuming operation
    end
    print("Consumer finished all tasks")
end)

wg:wait()
```

### Timeout Control

Combine with timers to implement timeout for channel operations.

```lua validate
local silly = require "silly"
local channel = require "silly.sync.channel"
local time = require "silly.time"

local ch = channel.new()
local timeout = false

local task = require "silly.task"

task.fork(function()
    -- Wait for data or timeout
    local current_co = task.running()

    -- Set timeout timer
    local timer = time.after(500, function()
        timeout = true
        task.wakeup(current_co)
    end)

    -- Try to read data
    local data, err = ch:pop()

    if timeout then
        print("Operation timed out")
    else
        time.cancel(timer)
        print("Received data:", data)
    end
end)

-- Simulate delayed data arrival (exceeds timeout)
time.after(1000, function()
    ch:push("late data")
end)
```

## Notes

1. **Nil Value Restriction**: Channels cannot transmit `nil` values. If you need to represent "empty", use a special marker value (like `false` or an empty table).

2. **Memory Limit**: The channel queue size cannot exceed 2GB (0x7FFFFFFF bytes). If the queue grows too large, `push` operations will trigger assertion failures.

3. **Coroutine Blocking**: `pop` operations are blocking and must be called within a coroutine. Calling in the main thread or C functions will cause errors.

4. **Single Consumer**: Channels are designed for the MPSC model, allowing only one coroutine to block on `pop` at a time. If multiple coroutines call `pop` simultaneously, behavior is undefined (may cause assertion failures or data races).

5. **Close Order**: After closing a channel, data in the queue can still be read. Only when the queue is empty does `pop` return a "channel closed" error.

6. **Clear Operation**: `clear()` discards all pending data but does not close the channel. Ensure no important data is lost when using it.

7. **Error Handling**: Always check return values from `push` and `pop`, especially in scenarios where the channel might be closed.

## Implementation Details

Channels use two indices (`popi` and `pushi`) to manage the internal queue:

- `popi`: Next read position
- `pushi`: Next write position
- When `popi == pushi`, the queue is empty
- When the queue is fully consumed, both indices reset to 1 to avoid infinite growth

The efficiency of channels lies in:
- When a coroutine is waiting, data is transferred directly without going through the queue
- Using Lua tables as circular buffers avoids frequent memory allocation
- Implementing zero-overhead blocking through coroutine `wait/wakeup` mechanisms

## See Also

- [silly](../silly.md) - Core module
- [silly.sync.waitgroup](./waitgroup.md) - Coroutine wait group
- [silly.time](../time.md) - Timer management
