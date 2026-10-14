# Queue

`silly.adt.queue` is a general-purpose FIFO (First-In-First-Out) queue implementation that supports storing any Lua values.

## Module Import

```lua
local queue = require "silly.adt.queue"
```

The queue supports generic annotations, for example:

```lua
---@type silly.adt.queue<string>
local q = queue.new()
```

`nil` is also a valid queued value. Because `pop()` returns `nil` for both a queued
`nil` and an empty queue, check `size()` before popping if that distinction matters.

## API Reference

### queue.new()

Creates a new queue object.

- **Returns**: `queue` - A new queue object

### queue:push(value)

Adds an element to the end of the queue.

- **Parameters**:
  - `value`: `T` - The value to store; duplicates, `false` and `nil` are allowed
- **Returns**: `integer` - Current size of the queue

### queue:pop()

Removes and returns an element from the front of the queue.

- **Returns**: `T|nil` - The element at the front of the queue, or `nil` if the queue is empty

### queue:remove(value)

Removes the first matching value in FIFO order and preserves the order of all
remaining elements. Uses raw equality (`rawequal`) without invoking `__eq`.
Lookup and removal take O(n) time; no reverse index is maintained.

- **Parameters**:
  - `value`: `T` - The value to remove, including an explicit `nil`
- **Returns**: `boolean` - `true` if one occurrence was removed, otherwise `false`

### queue:size()

Gets the current number of elements in the queue.

- **Returns**: `integer` - Number of elements

### queue:clear()

Clears all elements from the queue.
