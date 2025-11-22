# Queue

`silly.adt.queue` is a general-purpose FIFO (First-In-First-Out) queue implementation that supports storing any Lua values.

## Module Import

```lua
local queue = require "silly.adt.queue"
```

## API Reference

### queue.new()

Creates a new queue object.

- **Returns**: `queue` - A new queue object

### queue:push(value)

Adds an element to the end of the queue.

- **Parameters**:
  - `value`: `any` - The value to store (cannot be `nil`)
- **Returns**: `integer` - Current size of the queue

### queue:pop()

Removes and returns an element from the front of the queue.

- **Returns**: `any|nil` - The element at the front of the queue, or `nil` if the queue is empty

### queue:size()

Gets the current number of elements in the queue.

- **Returns**: `integer` - Number of elements

### queue:clear()

Clears all elements from the queue.
