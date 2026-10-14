# Queue

`silly.adt.queue` 是一个通用的 FIFO（先进先出）队列实现，支持存储任意 Lua 值。

## 引入模块

```lua
local queue = require "silly.adt.queue"
```

队列支持泛型注解，例如：

```lua
---@type silly.adt.queue<string>
local q = queue.new()
```

`nil` 也可以入队。由于 `pop()` 对队列中的 `nil` 和空队列都会返回 `nil`，
如果需要区分，应在弹出前检查 `size()`。

## API 参考

### queue.new()

创建一个新的队列对象。

- **返回值**: `queue` - 新的队列对象

### queue:push(value)

向队列尾部添加一个元素。

- **参数**:
  - `value`: `T` - 要存储的值；允许重复值、`false` 和 `nil`
- **返回值**: `integer` - 队列当前的大小

### queue:pop()

从队列头部移除并返回一个元素。

- **返回值**: `T|nil` - 队列头部的元素，如果队列为空则返回 `nil`

### queue:remove(value)

按 FIFO 顺序删除第一个匹配的值，并保持其余元素的顺序。
使用原始相等比较（`rawequal`），不会调用 `__eq`。
查找和删除的时间复杂度为 O(n)，不维护反向索引。

- **参数**:
  - `value`: `T` - 要删除的值，也可以显式传入 `nil`
- **返回值**: `boolean` - 删除了一个匹配项时返回 `true`，未找到时返回 `false`

### queue:size()

获取队列当前包含的元素数量。

- **返回值**: `integer` - 元素数量

### queue:clear()

清空队列中的所有元素。
