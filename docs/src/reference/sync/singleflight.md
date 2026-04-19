---
title: silly.sync.singleflight
icon: arrows-to-circle
category:
  - API参考
tag:
  - 同步
  - 协程
  - 去重
---

# silly.sync.singleflight

`silly.sync.singleflight` 对同一 key 的并发调用做合并：同一时刻只有一次真正的底层执行，其它协程共享这次执行的结果。典型用途是缓存击穿、上游雪崩、昂贵的按 key 计算等。

## 模块导入

```lua
local singleflight = require "silly.sync.singleflight"
```

## API

### singleflight.new(fn)

创建一个绑定处理函数 `fn` 的 singleflight 组。所有 `call(key)` 调用底层都是 `fn(key)`，其返回值就是 `call` 的返回值。

- **参数**:
  - `fn`: `fun(key):...` - 每个 key 上真正执行一次的函数，可以返回多个值。
- **返回值**: `silly.sync.singleflight` - 组对象。

### group:call(key)

对 `key` 执行（或加入）进行中的计算。

- **参数**:
  - `key`: 任何可做 Lua table 键的值（通常是字符串）
- **返回值**: 对于真正执行 `fn(key)` 的协程——`fn` 的返回值；对于其它等待者——同一次执行的返回值。
- **异步**: 如果 `key` 已有进行中的调用，会挂起当前协程直到完成。
- **错误**: 若 `fn` 抛错，该 key 上所有等待者都会通过 `error()` 重新抛出同一份错误。如需容错，调用侧用 `pcall` / `silly.pcall` 包一层。

## 示例：缓存填充

```lua
local silly = require "silly"
local task = require "silly.task"
local singleflight = require "silly.sync.singleflight"

local db = {}  -- 你的数据库模块
local cache = {}

local sf = singleflight.new(function(user_id)
    -- 即使高并发，每个 user_id 也只会命中一次 DB
    local user = db.load_user(user_id)
    cache[user_id] = user
    return user
end)

local function get_user(user_id)
    return cache[user_id] or sf:call(user_id)
end

-- 对 user 42 的 100 个并发请求只产生 1 次 DB 调用
for i = 1, 100 do
    task.fork(function()
        local user = get_user(42)
        -- ...
    end)
end
```

## 语义

- **按 key 合并**: `call("a")` 和 `call("b")` 并行；只有同 key 重复调用被合并。
- **不做记忆化**: `fn` 返回后，下一次 `call(key)` 会重新执行 `fn`；持久化需自行维护缓存。
- **错误传播**: `fn` 的错误会广播到该 key 上所有等待者。下次调用会发起新一轮 flight，可重试。
