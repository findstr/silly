---
title: silly.sync.mutex
icon: lock
category:
  - API参考
tag:
  - 同步
  - 互斥锁
  - 协程
---

# silly.sync.mutex

协程互斥锁模块，提供可重入的互斥锁机制，用于保护协程间的共享资源。支持 Lua 5.4 的 `<close>` 语法自动释放锁。

## 模块导入

```lua validate
local mutex = require "silly.sync.mutex"
```

## API 文档

### mutex.new()

创建一个新的互斥锁管理器。

- **返回值**: `silly.sync.mutex` - 互斥锁管理器对象
- **说明**: 每个锁管理器可以管理多个不同 key 的锁
- **示例**:

```lua validate
local mutex = require "silly.sync.mutex"

local m = mutex.new()
```

### mutex:lock(key)

获取指定 key 的锁。如果锁已被其他协程持有，当前协程将等待直到锁被释放。

- **参数**:
  - `key`: `any` - 锁的标识符，可以是任意类型（通常使用 table 或 string）
- **返回值**: `proxy` - 锁代理对象，包含以下方法和元方法：
  - `unlock()`: 手动释放锁
  - `__close`: 元方法，支持 `<close>` 语法自动释放
- **特性**:
  - **可重入**: 同一协程可以多次获取同一个锁，需要相应次数的释放
  - **阻塞等待**: 如果锁被其他协程持有，当前协程会挂起等待
  - **自动释放**: 使用 `<close>` 语法可以在作用域结束时自动释放锁
- **示例**:

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = "resource_1"

task.fork(function()
    local lock<close> = m:lock(key)
    print("Lock acquired")
    -- 临界区代码
    -- 离开作用域时自动释放锁
end)
```

### proxy:unlock()

手动释放锁。

- **说明**:
  - 对于可重入锁，需要调用相同次数的 `unlock()` 才能完全释放
  - 如果使用 `<close>` 语法，通常不需要手动调用
  - 可以提前调用 `unlock()` 来提前释放锁
- **示例**:

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = "resource_1"

task.fork(function()
    local lock = m:lock(key)
    print("Lock acquired")
    -- 临界区代码
    lock:unlock()  -- 手动释放
    print("Lock released")
end)
```

## 使用示例

### 示例1：基本互斥保护

```lua validate
local silly = require "silly"
local time = require "silly.time"
local mutex = require "silly.sync.mutex"
local waitgroup = require "silly.sync.waitgroup"

local m = mutex.new()
local key = {}
local counter = 0

local wg = waitgroup.new()

-- 创建5个协程同时访问共享资源
for i = 1, 5 do
    wg:fork(function()
        local lock<close> = m:lock(key)
        -- 临界区：读取-修改-写入
        local old_value = counter
        time.sleep(10)  -- 模拟耗时操作
        counter = old_value + 1
        print(string.format("Coroutine %d: %d -> %d", i, old_value, counter))
        -- lock 在此自动释放
    end)
end

wg:wait()
print("Final counter:", counter)  -- 输出: Final counter: 5
```

### 示例2：可重入锁

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = {}

task.fork(function()
    -- 第一次获取锁
    local lock1<close> = m:lock(key)
    print("First lock acquired")

    -- 同一协程可以再次获取同一个锁（可重入）
    local lock2<close> = m:lock(key)
    print("Second lock acquired (reentrant)")

    -- lock2 在此释放，但 lock1 仍持有
    do
        local lock3<close> = m:lock(key)
        print("Third lock acquired (reentrant)")
    end  -- lock3 释放

    print("Still holding outer locks")

    -- lock2 和 lock1 在此依次释放
end)
```

### 示例3：手动释放锁

```lua validate
local silly = require "silly"
local time = require "silly.time"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = "database"

task.fork(function()
    local lock = m:lock(key)
    print("Lock acquired")

    -- 临界区操作
    print("Accessing database...")
    time.sleep(100)

    -- 提前手动释放锁
    lock:unlock()
    print("Lock released early")

    -- 继续执行非临界区代码
    print("Doing other work...")
    time.sleep(100)
end)
```

### 示例4：多个独立的锁

```lua validate
local silly = require "silly"
local time = require "silly.time"
local mutex = require "silly.sync.mutex"
local waitgroup = require "silly.sync.waitgroup"

local m = mutex.new()
local key1 = "resource_1"
local key2 = "resource_2"

local wg = waitgroup.new()

wg:fork(function()
    local lock<close> = m:lock(key1)
    print("Task 1: locked resource_1")
    time.sleep(100)
    print("Task 1: done")
end)

wg:fork(function()
    local lock<close> = m:lock(key2)
    print("Task 2: locked resource_2")
    time.sleep(100)
    print("Task 2: done")
end)

-- 这两个任务可以并发执行，因为它们锁定不同的资源

wg:wait()
```

### 示例5：异常安全

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = {}

task.fork(function()
    local lock<close> = m:lock(key)
    print("Lock acquired")

    -- 即使发生错误，<close> 也会确保锁被释放
    error("Something went wrong!")

    -- 这行代码不会执行
    print("This won't print")

    -- 但锁会在协程退出时自动释放
end)
```

### 示例6：模拟读写场景

```lua validate
local silly = require "silly"
local time = require "silly.time"
local mutex = require "silly.sync.mutex"
local waitgroup = require "silly.sync.waitgroup"

local m = mutex.new()
local cache = {}
local cache_key = "cache_lock"

local function read_cache(key)
    local lock<close> = m:lock(cache_key)
    return cache[key]
end

local function write_cache(key, value)
    local lock<close> = m:lock(cache_key)
    cache[key] = value
    time.sleep(10)  -- 模拟写入延迟
end

local wg = waitgroup.new()

-- 写入操作
wg:fork(function()
    write_cache("user:1", {name = "Alice", age = 30})
    print("Written to cache")
end)

-- 读取操作（等待写入完成）
wg:fork(function()
    time.sleep(5)  -- 稍后读取
    local data = read_cache("user:1")
    if data then
        print("Read from cache:", data.name)
    else
        print("Cache miss")
    end
end)

wg:wait()
```

## 注意事项

### 1. 必须在协程中使用

互斥锁依赖于 Silly 的协程调度系统，必须在协程上下文中使用：

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()

-- 错误：不能在主线程直接使用
-- local lock = m:lock("key")  -- 这会导致问题

-- 正确：在协程中使用
task.fork(function()
    local lock<close> = m:lock("key")
    print("This is correct")
end)
```

### 2. 推荐使用 `<close>` 语法

使用 Lua 5.4 的 `<close>` 语法可以确保锁一定会被释放，即使发生异常：

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()

task.fork(function()
    -- 推荐：使用 <close>
    local lock<close> = m:lock("key")
    -- ... 临界区代码 ...
    -- 自动释放，即使发生异常
end)
```

### 3. 避免死锁

注意锁的获取顺序，避免循环等待导致死锁：

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local waitgroup = require "silly.sync.waitgroup"

local m = mutex.new()
local key1 = "A"
local key2 = "B"

local wg = waitgroup.new()

-- 死锁示例（不要这样做！）
wg:fork(function()
    local lock1<close> = m:lock(key1)
    print("Task 1: locked A")
    silly.sleep(10)
    local lock2<close> = m:lock(key2)  -- 等待 B
    print("Task 1: locked B")
end)

wg:fork(function()
    local lock2<close> = m:lock(key2)
    print("Task 2: locked B")
    silly.sleep(10)
    local lock1<close> = m:lock(key1)  -- 等待 A，死锁！
    print("Task 2: locked A")
end)

-- 解决方案：统一锁的获取顺序
-- 总是先锁 key1，再锁 key2
```

### 4. 理解可重入特性

同一协程可以多次获取同一个锁，但需要相应次数的释放：

```lua validate
local silly = require "silly"
local mutex = require "silly.sync.mutex"
local task = require "silly.task"

local m = mutex.new()
local key = {}

task.fork(function()
    local lock1 = m:lock(key)  -- 第1次获取
    local lock2 = m:lock(key)  -- 第2次获取（可重入）
    local lock3 = m:lock(key)  -- 第3次获取（可重入）

    lock3:unlock()  -- 释放第3次
    lock2:unlock()  -- 释放第2次
    lock1:unlock()  -- 释放第1次，锁完全释放

    -- 现在其他协程可以获取这个锁了
end)
```

### 5. key 的选择

- `key` 可以是任意 Lua 值（string、number、table 等）
- 建议使用 table 作为 key，避免命名冲突：

```lua validate
local mutex = require "silly.sync.mutex"

local m = mutex.new()

-- 推荐：使用唯一的 table 作为 key
local user_lock = {}
local cache_lock = {}

-- 不推荐：使用字符串可能冲突
-- local lock1 = m:lock("user")
-- local lock2 = m:lock("user")  -- 相同的字符串，会阻塞
```

## 性能说明

- 锁对象使用对象池（`lockcache` 和 `proxycache`）来减少 GC 压力
- 使用弱表（`weak mode = "v"`）自动回收不再使用的锁对象
- 锁的获取和释放操作都是 O(1) 时间复杂度
- 适合高频率的锁操作场景

## 参见

- [silly.sync.waitgroup](./waitgroup.md) - 协程等待组
- [silly](../silly.md) - 核心模块
- [silly.time](../time.md) - 定时器模块
