---
title: silly.time
icon: clock
category:
  - API参考
tag:
  - 核心
  - 定时器
  - 时间
---

# silly.time

定时器和时间管理模块，提供高精度定时器（默认10ms分辨率，50ms精度）。

## 模块导入

```lua validate
local time = require "silly.time"
```

## 时间函数

### time.now()
获取当前时间戳（毫秒）。

- **返回值**: `integer` - Unix时间戳（毫秒）
- **示例**:
```lua validate
local time = require "silly.time"

local timestamp = time.now()
print("Current time:", timestamp)
```

### time.monotonic()
获取单调递增的时间（毫秒），不受系统时间调整影响。

- **返回值**: `integer` - 单调时间（毫秒）
- **用途**: 适合用于性能测量和超时计算
- **示例**:
```lua validate
local time = require "silly.time"

local start = time.monotonic()
-- ... do something ...
local elapsed = time.monotonic() - start
print("Elapsed:", elapsed, "ms")
```

## 定时器函数

### time.sleep(ms)
挂起当前协程指定的毫秒数。

- **参数**:
  - `ms`: `integer` - 睡眠时间（毫秒）
- **注意**: 只能在协程中调用
- **示例**:
```lua validate
local time = require "silly.time"

time.sleep(1000)  -- 睡眠1秒
print("Woke up after 1 second")
```

### time.after(ms, func [, userdata])
在指定毫秒后执行回调函数。

- **参数**:
  - `ms`: `integer` - 延迟时间（毫秒）
  - `func`: `function` - 回调函数，签名：`function(userdata|session)`
  - `userdata`: `any` (可选) - 传递给回调的用户数据
- **返回值**: `integer` - 定时器会话ID，可用于取消定时器
- **回调参数**:
  - 如果提供了 `userdata`，回调接收 `userdata`
  - 如果未提供 `userdata`，回调接收定时器的 `session` ID
- **示例**:

```lua validate
local time = require "silly.time"

-- 不带用户数据
time.after(1000, function(session)
    print("Timer expired, session:", session)
end)

-- 带用户数据
time.after(2000, function(data)
    print("Got data:", data)
end, "hello")

-- 带复杂用户数据
time.after(3000, function(config)
    print("Server:", config.host, config.port)
end, {host = "localhost", port = 8080})
```

### time.cancel(session)
取消一个定时器。

- **参数**:
  - `session`: `integer` - 定时器会话ID（由 `time.after` 返回）
- **注意**:
  - 只能取消由 `time.after` 创建的定时器
  - 不能取消 `time.sleep` 创建的定时器
  - 如果定时器已触发但回调尚未执行，取消操作将阻止回调执行
- **示例**:
```lua validate
local time = require "silly.time"

local session = time.after(5000, function()
    print("This will not print")
end)

time.sleep(1000)
time.cancel(session)  -- 取消定时器
print("Timer cancelled")
```

## 使用示例

### 示例1：简单延时执行

```lua validate
local time = require "silly.time"

time.after(1000, function()
    print("Hello after 1 second")
end)
```

### 示例2：定时重试逻辑

```lua validate
local time = require "silly.time"

-- 模拟连接函数
local function connect_to_server(config)
    return false  -- 模拟连接失败
end

local retries = 0
local max_retries = 3
local config = {host = "localhost"}

local function attempt()
    local ok = connect_to_server(config)
    if not ok and retries < max_retries then
        retries = retries + 1
        print("Retry", retries, "after 1 second")
        time.after(1000, attempt)
    else
        print("Max retries reached or connected")
    end
end

attempt()
```

### 示例3：性能测量

```lua validate
local time = require "silly.time"

local start = time.monotonic()
-- 执行一些操作
local sum = 0
for i = 1, 1000000 do
    sum = sum + i
end
local elapsed = time.monotonic() - start
print("Processing took", elapsed, "ms")
```

### 示例4：可取消的延迟操作（防抖）

```lua validate
local time = require "silly.time"

-- 模拟保存函数
local function save_to_disk(data)
    print("Saving:", data)
end

local pending_save = nil
local function schedule_save(data)
    -- 取消之前的保存操作
    if pending_save then
        time.cancel(pending_save)
        print("Cancelled previous save")
    end
    -- 延迟500ms保存（防抖）
    pending_save = time.after(500, function()
        save_to_disk(data)
        pending_save = nil
    end)
end

-- 测试防抖：快速调用多次，只会保存最后一次
schedule_save("data1")
schedule_save("data2")
schedule_save("data3")
```

## 精度说明

Silly的定时器系统特性：
- **分辨率**: 10ms（timer tick interval）
- **精度**: 约50ms
- **适用场景**: 网络超时、定时任务、防抖节流
- **不适用场景**: 高精度实时控制（如音视频同步）

## 与协程配合

定时器与Silly的协程调度系统紧密集成：

```lua validate
local silly = require "silly"
local time = require "silly.time"

silly.fork(function()
    print("Task started")
    time.sleep(1000)  -- 协程睡眠，不阻塞其他任务
    print("Task resumed after 1 second")
end)

-- 主逻辑继续执行，不被阻塞
print("Main logic continues")
```

## 参见

- [silly](./silly.md) - 核心调度器
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
