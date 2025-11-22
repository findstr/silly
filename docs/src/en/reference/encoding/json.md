---
title: json
icon: file-code
category:
  - API Reference
tag:
  - Encoding
  - JSON
  - Serialization
---

# json (`silly.encoding.json`)

The `silly.encoding.json` module provides high-performance JSON encoding and decoding functionality. This module is a pure Lua implementation that supports serialization and deserialization of standard JSON data types.

To use this module, you must first `require` it:
```lua
local json = require "silly.encoding.json"
```

---

## Core Concepts

JSON (JavaScript Object Notation) is a lightweight data interchange format. This module supports conversion between Lua data structures and JSON strings:

- **Encoding (encode)**: Convert Lua tables to JSON strings
- **Decoding (decode)**: Parse JSON strings into Lua tables

### Type Mapping

Type mapping between Lua and JSON:

| Lua Type | JSON Type | Description |
|---------|----------|------|
| `table` (array) | Array | Treated as array when the first element exists or table is empty |
| `table` (object) | Object | Treated as object when table is a hash structure |
| `string` | String | Strings automatically escape special characters |
| `number` | Number | Supports integers and floating-point numbers |
| `boolean` | Boolean | `true` and `false` |
| `nil` | `null` | JSON's `null` decodes to Lua's `nil` |

---

## Complete Example

```lua validate
local json = require "silly.encoding.json"

-- 1. Basic type encoding
local simple = {
    name = "Alice",
    age = 30,
    active = true,
    score = 95.5
}
local encoded = json.encode(simple)
print("Encoded result:", encoded)
-- Output: {"name":"Alice","age":30,"active":true,"score":95.5}

-- 2. Array encoding
local arr = {1, 2, 3, "hello", true}
print("Array encoding:", json.encode(arr))
-- Output: [1,2,3,"hello",true]

-- 3. Nested structure encoding
local nested = {
    user = {
        name = "Bob",
        tags = {"developer", "gamer"}
    },
    settings = {
        theme = "dark",
        notifications = true
    }
}
local nested_json = json.encode(nested)
print("Nested encoding:", nested_json)

-- 4. JSON decoding
local json_str = '{"name":"Charlie","age":25,"hobbies":["reading","coding"]}'
local obj, pos = json.decode(json_str)
if obj then
    print("Name:", obj.name)
    print("Age:", obj.age)
    print("Hobbies:", table.concat(obj.hobbies, ", "))
end

-- 5. Handling special characters
local special = {
    text = 'Line1\nLine2\t"quoted"'
}
local escaped = json.encode(special)
print("Escaped encoding:", escaped)
-- Output: {"text":"Line1\nLine2\t\"quoted\""}

local decoded_special = json.decode(escaped)
assert(decoded_special.text == special.text)

-- 6. Error handling
local invalid_json = '{"incomplete":'
local result, err = json.decode(invalid_json)
if not result then
    print("Decode failed:", err)
end
```

---

## API Reference

### Encoding Functions

#### `json.encode(obj)`
Encodes a Lua table to a JSON string.

- `obj` (table): The Lua table to encode. Only table types are supported as top-level objects.
- **Returns**: The encoded JSON string.

**Supported data types**:
- `string`: Strings, automatically escapes special characters (`"`, `\`, `\b`, `\f`, `\n`, `\r`, `\t`)
- `number`: Numbers (integers and floating-point)
- `boolean`: Boolean values (`true`/`false`)
- `table`: Tables (as arrays or objects)

**Array vs Object determination**:
- If the table's first element (`[1]`) exists, or the table is empty, it's encoded as a JSON array
- Otherwise, it's encoded as a JSON object

**Example**:
```lua validate
local json = require "silly.encoding.json"

-- Object encoding
local obj = {name = "test", value = 42}
print(json.encode(obj))
-- Output: {"name":"test","value":42}

-- Array encoding
local arr = {1, 2, 3}
print(json.encode(arr))
-- Output: [1,2,3]

-- Empty table encodes to empty array
print(json.encode({}))
-- Output: []

-- Nested structure
local nested = {
    items = {
        {id = 1, name = "item1"},
        {id = 2, name = "item2"}
    }
}
print(json.encode(nested))
-- Output: {"items":[{"id":1,"name":"item1"},{"id":2,"name":"item2"}]}
```

---

### Decoding Functions

#### `json.decode(str)`
Parses a JSON string into a Lua table.

- `str` (string): The JSON string to parse.
- **Returns**:
  - On success: Returns the parsed Lua table and end position `(obj, pos)`
  - On failure: Returns `nil, error` (error message)

**Supported JSON types**:
- Object: Decodes to Lua table (hash table)
- Array: Decodes to Lua table (array)
- String: Decodes to Lua string, automatically handles escape sequences
- Number: Decodes to Lua number, supports scientific notation
- Boolean: `true`/`false` decode to Lua boolean values
- `null`: Decodes to Lua's `nil`

**Example**:
```lua validate
local json = require "silly.encoding.json"

-- Decode object
local obj, pos = json.decode('{"name":"Alice","age":30}')
print(obj.name, obj.age)
-- Output: Alice  30

-- Decode array
local arr = json.decode('[1,2,3,4,5]')
print(arr[1], arr[3])
-- Output: 1  3

-- Decode null
local with_null = json.decode('{"value":null}')
print(with_null.value == nil)
-- Output: true

-- Scientific notation
local scientific = json.decode('{"number":-1.23e5}')
print(scientific.number)
-- Output: -123000.0

-- Error handling
local invalid, err = json.decode('{"bad":}')
if not invalid then
    print("Parse failed:", err)
end
```

---

## Special Character Handling

This module automatically handles escape characters in JSON:

### Escaping During Encoding

During encoding, the following characters are automatically escaped:

| Character | Escape Sequence | Description |
|-----|---------|------|
| `"` | `\"` | Double quote |
| `\` | `\\` | Backslash |
| `\b` | `\\b` | Backspace |
| `\f` | `\\f` | Form feed |
| `\n` | `\\n` | Newline |
| `\r` | `\\r` | Carriage return |
| `\t` | `\\t` | Tab |

### Unescaping During Decoding

During decoding, escape sequences in JSON are automatically converted to their corresponding characters.

**Example**:
```lua validate
local json = require "silly.encoding.json"

-- Encode escape characters
local text = {
    message = 'Hello\nWorld\t"quoted"'
}
local encoded = json.encode(text)
print("Encoded:", encoded)
-- Output: {"message":"Hello\\nWorld\\t\\"quoted\\""}

-- Decode escape characters
local decoded = json.decode(encoded)
print("Decoded:", decoded.message)
-- Output: Hello
--       World  "quoted"

-- Backslash handling
local backslash = {path = "C:\\Users\\test"}
local bs_encoded = json.encode(backslash)
print("Path encoded:", bs_encoded)
-- Output: {"path":"C:\\\\Users\\\\test"}

local bs_decoded = json.decode(bs_encoded)
assert(bs_decoded.path == backslash.path)
```

---

## Advanced Usage

### Handling Large Data

This module can handle large JSON data and deeply nested structures:

```lua validate
local json = require "silly.encoding.json"

-- Long string handling
local long_str = string.rep("a", 10000)
local encoded = json.encode({data = long_str})
local decoded = json.decode(encoded)
assert(decoded.data == long_str)
print("Long string test passed")

-- Deep nesting
local deep = {}
local current = deep
for i = 1, 50 do
    current[1] = {}
    current = current[1]
end

local deep_encoded = json.encode(deep)
local deep_decoded = json.decode(deep_encoded)
print("Deep nesting test passed")

-- Large array
local large_arr = {}
for i = 1, 1000 do
    large_arr[i] = i
end
local arr_encoded = json.encode(large_arr)
local arr_decoded = json.decode(arr_encoded)
assert(#arr_decoded == 1000)
print("Large array test passed")
```

### Sparse Array Handling

Note: Lua sparse arrays will only include the contiguous array portion when encoded:

```lua validate
local json = require "silly.encoding.json"

-- Sparse array
local sparse = {[1] = 1, [3] = 3}  -- Missing [2]
local encoded = json.encode(sparse)
print("Sparse array encoding:", encoded)
-- Output: [1]  (only includes contiguous portion)

-- Mixed array/object
local mixed = {[1] = "first", name = "test"}
local mixed_encoded = json.encode(mixed)
print("Mixed structure:", mixed_encoded)
-- Output: ["first"]  (treated as array when [1] exists)
```

### Error Handling Pattern

Always check return values when decoding:

```lua validate
local json = require "silly.encoding.json"

local test_cases = {
    '{"valid":true}',           -- Valid
    '{"missing":',              -- Missing closing brace
    '[1,,2]',                   -- Invalid comma
    '{"empty":}',               -- Empty value
    '{"wrong":tru}',            -- Invalid boolean
}

for i, json_str in ipairs(test_cases) do
    local obj, err = json.decode(json_str)
    if obj then
        print(string.format("Test %d: Decode successful", i))
    else
        print(string.format("Test %d: Decode failed - %s", i, err))
    end
end
```

---

## Important Notes

### 1. Type Limitations

- **Unsupported types**: Functions, userdata, threads, etc. cannot be encoded
- **Top-level type**: `json.encode()` only accepts table types as arguments
- **nil values**: `nil` values in objects are ignored during encoding

### 2. Array vs Object

Determination rules:
- If `table[1] ~= nil` or `next(table) == nil`, it's treated as an array
- Otherwise, it's treated as an object

This means:
```lua
{}                    -- Encodes to []
{1, 2, 3}            -- Encodes to [1,2,3]
{[1]=1, [3]=3}       -- Encodes to [1] (sparse array only takes contiguous portion)
{name="test"}        -- Encodes to {"name":"test"}
{[1]=1, name="test"} -- Encodes to [1] (treated as array when [1] exists)
```

### 3. Number Precision

- Supports Lua's full number range
- Supports scientific notation (e.g., `1.23e5`)
- Very large numbers may lose precision (limited by floating-point)

### 4. Unicode Support

- UTF-8 strings can be handled normally
- Chinese and other Unicode characters are encoded directly, not converted to `\uXXXX` format

### 5. Performance Considerations

- Pure Lua implementation, performance suitable for most application scenarios
- For extremely high performance requirements, consider using a C-implemented JSON library
- Avoid encoding overly deep nested structures to maintain performance

### 6. Thread Safety

- This module is stateless and can be used safely across different coroutines
- Each `encode/decode` call is independent

---

## Practical Examples

### HTTP API Response

```lua validate
local json = require "silly.encoding.json"

-- Build API response
local function api_response(success, data, message)
    return json.encode({
        success = success,
        data = data,
        message = message or "",
        timestamp = os.time()
    })
end

-- Success response
local success_resp = api_response(true, {
    user = {id = 123, name = "Alice"},
    items = {1, 2, 3}
}, "Operation successful")
print("Success response:", success_resp)

-- Error response
local error_resp = api_response(false, nil, "User not found")
print("Error response:", error_resp)
```

### Configuration File Processing

```lua validate
local json = require "silly.encoding.json"

-- Configuration object
local config = {
    server = {
        host = "127.0.0.1",
        port = 8080,
        timeout = 30
    },
    database = {
        host = "localhost",
        port = 3306,
        name = "mydb"
    },
    features = {
        "logging",
        "caching",
        "monitoring"
    }
}

-- Save configuration (in real use, write to file)
local config_json = json.encode(config)
print("Config JSON:", config_json)

-- Load configuration
local loaded_config = json.decode(config_json)
print("Server port:", loaded_config.server.port)
print("Database name:", loaded_config.database.name)
```

### Data Validation

```lua validate
local json = require "silly.encoding.json"

-- Validate JSON format
local function validate_json(json_str)
    local obj, err = json.decode(json_str)
    if not obj then
        return false, "JSON format error: " .. (err or "unknown")
    end

    -- Validate required fields
    if not obj.name or not obj.age then
        return false, "Missing required fields"
    end

    -- Validate types
    if type(obj.age) ~= "number" then
        return false, "age must be a number"
    end

    return true, obj
end

-- Test validation
local valid_json = '{"name":"Bob","age":25}'
local ok, result = validate_json(valid_json)
if ok then
    print("Validation passed:", result.name)
end

local invalid_json = '{"name":"Bob"}'
local ok2, err2 = validate_json(invalid_json)
if not ok2 then
    print("Validation failed:", err2)
end
```

---

## Related Modules

- **silly.net.http**: HTTP protocol implementation, uses JSON internally for request/response handling
- **silly.net.websocket**: WebSocket protocol, commonly used for transmitting JSON data
- **silly.net.grpc**: gRPC support, can be used complementarily with JSON

---

## See Also

- [silly.encoding.base64](./base64.md): Base64 encoding/decoding
- [silly.net.http](../net/http.md): HTTP server and client
- [silly.net.websocket](../net/websocket.md): WebSocket protocol support
