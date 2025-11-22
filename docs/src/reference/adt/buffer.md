# Buffer

`silly.adt.buffer` 是一个高效的字节缓冲区实现，用于处理网络数据流的拼接和解析。

## 引入模块

```lua
local buffer = require "silly.adt.buffer"
```

## API 参考

### buffer.new()

创建一个新的缓冲区对象。

- **返回值**: `buffer` - 新的缓冲区对象

### buffer:append(data [, ...])

向缓冲区追加数据。

- **参数**:
  - `data`: `string` | `lightuserdata` - 要追加的数据
  - `...`: `string` | `lightuserdata` - 更多数据
- **返回值**: `integer` - 缓冲区当前的总字节数
- **说明**:
  - 如果参数是 `lightuserdata`，则必须紧跟一个 `integer` 类型的长度参数。
  - 例如: `buf:append(ptr, len)`

### buffer:read(n)

从缓冲区读取指定长度的数据。

- **参数**:
  - `n`: `integer` - 要读取的字节数
- **返回值**:
  1. `string|nil` - 读取的数据，如果缓冲区数据不足则返回 `nil`
  2. `integer` - 缓冲区剩余字节数

### buffer:read(delim)

从缓冲区读取直到遇到指定分隔符的数据（包含分隔符）。

- **参数**:
  - `delim`: `string` - 分隔符（必须是单字符字符串）
- **返回值**:
  1. `string|nil` - 读取的数据（包含分隔符），如果未找到分隔符则返回 `nil`
  2. `integer` - 缓冲区剩余字节数

### buffer:readall()

读取缓冲区中的所有数据。

- **返回值**: `string` - 缓冲区中的所有数据

### buffer:clear()

清空缓冲区。

### buffer:size()

获取缓冲区当前包含的字节数。

- **返回值**: `integer` - 字节数

### buffer:dump()

获取缓冲区的调试信息。

- **返回值**: `table` - 包含缓冲区内部状态的表
