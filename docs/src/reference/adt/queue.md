# Queue

`silly.adt.queue` 是一个通用的 FIFO（先进先出）队列实现，支持存储任意 Lua 值。

## 引入模块

```lua
local queue = require "silly.adt.queue"
```

## API 参考

### queue.new()

创建一个新的队列对象。

- **返回值**: `queue` - 新的队列对象

### queue:push(value)

向队列尾部添加一个元素。

- **参数**:
  - `value`: `any` - 要存储的值（不能是 `nil`）
- **返回值**: `integer` - 队列当前的大小

### queue:pop()

从队列头部移除并返回一个元素。

- **返回值**: `any|nil` - 队列头部的元素，如果队列为空则返回 `nil`

### queue:size()

获取队列当前包含的元素数量。

- **返回值**: `integer` - 元素数量

### queue:clear()

清空队列中的所有元素。
