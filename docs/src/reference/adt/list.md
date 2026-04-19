---
title: silly.adt.list
icon: list
category:
  - API参考
tag:
  - 数据结构
  - 链表
---

# silly.adt.list

`silly.adt.list` 是按「值」寻址的双向链表。插入、删除和查找都是 O(1)，而且可以直接用值当游标，无需显式节点句柄。代价是：**同一个值最多只能出现一次**——重复插入会抛错。

## 模块导入

```lua
local list = require "silly.adt.list"
```

## 什么时候用它

- 需要 LRU 风格的有序结构，频繁在两端移动元素。
- 需要按值做 O(1) 删除（而不是按下标）。
- 迭代顺序要反映插入顺序。

若只需普通 FIFO，`silly.adt.queue` 更轻且允许重复。

## API

### list.new()

创建一个空 list。

- **返回值**: `silly.adt.list`

### list:pushback(v)

在尾部追加 `v`。

- **参数**: `v` — 任何非 nil 值；不能已经在 list 中。
- **抛错**: `v` 为 nil 或已经存在。

### list:pushfront(v)

在头部插入 `v`，约束与 `pushback` 相同。

### list:popfront()

弹出并返回头元素；list 为空时返回 `nil`。

### list:popback()

弹出并返回尾元素；list 为空时返回 `nil`。

### list:remove(v)

O(1) 删除值 `v`。若 `v` 不在 list 中，返回 `nil, "removed"`。

### list:front()

返回头元素但不删除（为空返回 `nil`）。

### list:back()

返回尾元素但不删除（为空返回 `nil`）。

### list:size()

返回元素数量。

### list:clear()

清空所有元素。

### list:values()

返回从头到尾的迭代器，可用于 `for v in list:values() do ... end`。

## 示例：LRU

```lua
local list = require "silly.adt.list"

local function new_lru(capacity)
    local self = {
        keys = list.new(),
        values = {},
        capacity = capacity,
    }

    function self:get(k)
        local v = self.values[k]
        if v == nil then return nil end
        self.keys:remove(k)
        self.keys:pushback(k)  -- 标记为最近使用
        return v
    end

    function self:set(k, v)
        if self.values[k] ~= nil then
            self.keys:remove(k)
        elseif self.keys:size() >= self.capacity then
            local oldest = self.keys:popfront()
            self.values[oldest] = nil
        end
        self.values[k] = v
        self.keys:pushback(k)
    end

    return self
end

local cache = new_lru(3)
cache:set("a", 1); cache:set("b", 2); cache:set("c", 3)
cache:get("a")                 -- "a" 变最新
cache:set("d", 4)              -- 淘汰 "b"（最久未用）
```

## 注意事项

- **值本身就是节点句柄**——不要压入两个相等的值。如需重复，使用包装 table（`{id=123}`）。
- 所有单步操作都是常量时间；迭代与 `clear` 为 O(n)。
- 非线程安全——但 silly 的业务逻辑本身是单线程的，所以不成问题。
