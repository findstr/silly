---
title: silly.sync.channel
icon: arrows-left-right
category:
  - API参考
tag:
  - 同步
  - 协程
  - 通道
---

# silly.sync.channel

`silly.sync.channel` 模块提供了用于协程间通信的通道（Channel）实现。通道是一个线程安全的队列，支持多生产者单消费者（MPSC）模型。

## 模块导入

```lua validate
local channel = require "silly.sync.channel"
```

## 核心概念

Channel 是一个 FIFO（先进先出）队列，支持以下特性：

- **MPSC 模型**: 支持多个生产者同时写入，但同一时刻只能有一个消费者读取
- **阻塞语义**: 当通道为空时，`pop` 操作会阻塞当前协程，直到有数据可读
- **直接传递**: 如果有协程正在等待数据，`push` 操作会直接唤醒等待的协程，而不经过队列
- **关闭机制**: 通道可以被关闭，关闭后不能再写入，但可以读取剩余数据

## API 参考

### channel.new()

创建一个新的通道实例。

- **返回值**: `silly.sync.channel` - 新创建的通道对象

**示例**:
```lua validate
local channel = require "silly.sync.channel"

local ch = channel.new()
print("Channel created")
```

### channel:push(data)

向通道推送数据。如果有协程正在等待数据，会直接唤醒该协程；否则将数据放入队列。

- **参数**:
  - `data`: `any` - 要发送的数据（不能为 `nil`）
- **返回值**:
  - `success`: `boolean` - 是否成功推送
  - `error`: `string|nil` - 错误信息（如果失败）
    - `"nil data"` - 尝试推送 nil 值
    - `"channel closed"` - 通道已关闭

**示例**:
```lua validate
local channel = require "silly.sync.channel"

local ch = channel.new()

-- 推送数据
local ok, err = ch:push("hello")
assert(ok, err)

-- 尝试推送 nil（会失败）
ok, err = ch:push(nil)
assert(not ok)
assert(err == "nil data")
```

### channel:pop()

从通道读取数据。如果通道为空，当前协程会阻塞直到有数据可读或通道被关闭。

- **返回值**:
  - `data`: `any|nil` - 读取到的数据，失败时为 `nil`
  - `error`: `string|nil` - 错误信息
    - `"channel closed"` - 通道已关闭且为空

**注意**: 此函数是异步的，会挂起当前协程。

**示例**:
```lua validate
local silly = require "silly"
local channel = require "silly.sync.channel"

local ch = channel.new()

local task = require "silly.task"

-- 在另一个协程中推送数据
task.fork(function()
    ch:push("world")
end)

-- 阻塞等待数据
local data, err = ch:pop()
assert(data == "world", "Should receive 'world'")
assert(err == nil)
```

### channel:close()

关闭通道。关闭后的通道不能再推送新数据，但可以继续读取队列中的剩余数据。如果有协程正在等待数据，会唤醒该协程并返回错误。

- **返回值**: 无

**示例**:
```lua validate
local channel = require "silly.sync.channel"

local ch = channel.new()

ch:push("message1")
ch:push("message2")
ch:close()

-- 可以读取已有数据
assert(ch:pop() == "message1")
assert(ch:pop() == "message2")

-- 读取空的已关闭通道会返回错误
local data, err = ch:pop()
assert(data == nil)
assert(err == "channel closed")

-- 不能向已关闭的通道推送数据
local ok, err = ch:push("message3")
assert(not ok)
assert(err == "channel closed")
```

### channel:clear()

清空通道中的所有待处理数据，重置队列索引。

- **返回值**: 无

**示例**:
```lua validate
local silly = require "silly"
local channel = require "silly.sync.channel"

local ch = channel.new()

-- 推送多条消息
ch:push("msg1")
ch:push("msg2")
ch:push("msg3")

-- 清空通道
ch:clear()

local task = require "silly.task"

-- 通道现在为空,pop 会阻塞
task.fork(function()
    ch:push("new message")
end)

local data = ch:pop()
assert(data == "new message")
```

## 使用示例

### 生产者-消费者模式

这是一个典型的生产者-消费者示例，展示了如何使用通道在协程间传递数据。

```lua validate
local channel = require "silly.sync.channel"
local waitgroup = require "silly.sync.waitgroup"

local ch = channel.new()
local wg = waitgroup.new()

-- 生产者：生成 5 个任务
wg:fork(function()
    for i = 1, 5 do
        print("Producer: sending", i)
        ch:push(i)
    end
    ch:close()  -- 完成后关闭通道
    print("Producer: done")
end)

-- 消费者：处理任务直到通道关闭
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



### 带缓冲的任务队列

通道内部实现了队列，可以作为任务缓冲区使用。

```lua validate
local channel = require "silly.sync.channel"
local waitgroup = require "silly.sync.waitgroup"
local time = require "silly.time"

local ch = channel.new()
local wg = waitgroup.new()

-- 快速生产者：一次性推送多个任务
wg:fork(function()
    for i = 1, 10 do
        ch:push({id = i, task = "process data"})
    end
    ch:close()
    print("Producer finished quickly")
end)

-- 慢速消费者：处理每个任务需要时间
wg:fork(function()
    while true do
        local task, err = ch:pop()
        if err == "channel closed" then
            break
        end
        print("Processing task", task.id)
        time.sleep(100)  -- 模拟耗时操作
    end
    print("Consumer finished all tasks")
end)

wg:wait()
```

### 超时控制

结合定时器实现带超时的通道操作。

```lua validate
local silly = require "silly"
local channel = require "silly.sync.channel"
local time = require "silly.time"

local ch = channel.new()
local timeout = false

local task = require "silly.task"

task.fork(function()
    -- 等待数据或超时
    local current_co = task.running()

    -- 设置超时定时器
    local timer = time.after(500, function()
        timeout = true
        task.wakeup(current_co)
    end)

    -- 尝试读取数据
    local data, err = ch:pop()

    if timeout then
        print("Operation timed out")
    else
        time.cancel(timer)
        print("Received data:", data)
    end
end)

-- 模拟延迟到达的数据（超过超时时间）
time.after(1000, function()
    ch:push("late data")
end)
```

## 注意事项

1. **nil 值限制**: 通道不能传输 `nil` 值。如果需要表示"空"，可以使用特殊标记值（如 `false` 或空表）。

2. **内存限制**: 通道队列大小不能超过 2GB（0x7FFFFFFF 字节）。如果队列增长过大，`push` 操作会触发断言失败。

3. **协程阻塞**: `pop` 操作是阻塞的，必须在协程中调用。在主线程或 C 函数中调用会导致错误。

4. **单消费者**: 通道设计为 MPSC 模型，同一时刻只允许一个协程在 `pop` 上阻塞。如果多个协程同时调用 `pop`，行为是未定义的（可能会导致断言失败或数据竞争）。

5. **关闭顺序**: 关闭通道后，队列中的数据仍然可以被读取。只有当队列为空时，`pop` 才会返回 "channel closed" 错误。

6. **清空操作**: `clear()` 会丢弃所有待处理的数据，但不会关闭通道。使用时需确保不会丢失重要数据。

7. **错误处理**: 始终检查 `push` 和 `pop` 的返回值，特别是在通道可能被关闭的场景中。

## 实现细节

通道使用两个索引（`popi` 和 `pushi`）来管理内部队列：

- `popi`: 下一个读取位置
- `pushi`: 下一个写入位置
- 当 `popi == pushi` 时，队列为空
- 当队列完全消费完毕后，两个索引会重置为 1，避免无限增长

通道的高效之处在于：
- 当有协程等待时，数据直接传递，不经过队列
- 使用 Lua 表作为环形缓冲区，避免频繁的内存分配
- 通过协程的 `wait/wakeup` 机制实现零开销的阻塞

## 参见

- [silly](../silly.md) - 核心模块
- [silly.sync.waitgroup](./waitgroup.md) - 协程等待组
- [silly.time](../time.md) - 定时器管理
