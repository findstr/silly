# Buffer

`silly.adt.buffer` is an efficient byte buffer implementation for handling network data stream concatenation and parsing.

## Module Import

```lua
local buffer = require "silly.adt.buffer"
```

## API Reference

### buffer.new()

Creates a new buffer object.

- **Returns**: `buffer` - A new buffer object

### buffer:append(data [, ...])

Appends data to the buffer.

- **Parameters**:
  - `data`: `string` | `lightuserdata` - Data to append
  - `...`: `string` | `lightuserdata` - Additional data
- **Returns**: `integer` - Current total bytes in the buffer
- **Notes**:
  - If the parameter is `lightuserdata`, it must be followed by an `integer` type length parameter.
  - Example: `buf:append(ptr, len)`

### buffer:read(n)

Reads a specified number of bytes from the buffer.

- **Parameters**:
  - `n`: `integer` - Number of bytes to read
- **Returns**:
  1. `string|nil` - The read data, or `nil` if buffer has insufficient data
  2. `integer` - Remaining bytes in the buffer

### buffer:read(delim)

Reads data from the buffer until encountering the specified delimiter (including the delimiter).

- **Parameters**:
  - `delim`: `string` - Delimiter (must be a single-character string)
- **Returns**:
  1. `string|nil` - The read data (including delimiter), or `nil` if delimiter not found
  2. `integer` - Remaining bytes in the buffer

### buffer:readall()

Reads all data from the buffer.

- **Returns**: `string` - All data in the buffer

### buffer:clear()

Clears the buffer.

### buffer:size()

Gets the current number of bytes in the buffer.

- **Returns**: `integer` - Number of bytes

### buffer:dump()

Gets debug information about the buffer.

- **Returns**: `table` - A table containing the buffer's internal state
