---
title: silly.hive
icon: cogs
category:
  - API参考
tag:
  - 核心
  - 线程池
  - 并发
---

# silly.hive

工作线程池模块，用于在独立的OS线程中执行阻塞操作（如文件IO、阻塞计算等），避免阻塞主事件循环。

## 模块导入

```lua validate
local hive = require "silly.hive"
```

## 核心概念

Silly采用单线程事件循环模型，所有业务逻辑在主worker线程中执行。对于必须阻塞的操作（如 `os.execute`、阻塞文件读写），可以使用Hive将其分发到独立的worker线程执行，避免阻塞整个服务。

**工作流程**:
1. 使用 `hive.spawn(code)` 创建一个worker
2. 使用 `hive.invoke(worker, ...)` 向worker发送任务
3. Worker在独立线程中执行Lua代码
4. 主协程等待结果，期间事件循环继续运行
5. Worker完成后，通过消息队列返回结果

## API函数

### hive.spawn(code, ...)
创建一个新的worker。

- **参数**:
  - `code`: `string` - Lua代码字符串，必须返回一个函数
  - `...` - 传递给代码的初始化参数
- **返回值**: `silly.hive.worker` - Worker对象
- **说明**:
  - 代码在独立的Lua VM中执行
  - 代码必须返回一个函数，该函数将被 `invoke` 调用
  - 初始化参数通过 `...` 传递
- **示例**:
```lua validate
local hive = require "silly.hive"

local worker = hive.spawn([[
    local init_value = ...
    return function(a, b)
        return a + b + init_value
    end
]], 10)
```

### hive.invoke(worker, ...)
向worker发送任务并等待结果。

- **参数**:
  - `worker`: `silly.hive.worker` - Worker对象
  - `...` - 传递给worker函数的参数
- **返回值**: `...` - Worker函数的返回值
- **错误**: 如果worker抛出异常，会在主协程中重新抛出
- **并发**: 同一worker同时只能处理一个任务（自动串行化）
- **示例**:
```lua validate
local hive = require "silly.hive"

local worker = hive.spawn([[
    local init_value = ...
    return function(a, b)
        return a + b + init_value
    end
]], 10)

local result1, result2 = hive.invoke(worker, 5, 3)
-- result1 = 18 (5 + 3 + 10)
```

### hive.limit(min, max)
设置线程池的大小限制。

- **参数**:
  - `min`: `integer` - 最小线程数
  - `max`: `integer` - 最大线程数
- **说明**:
  - 线程池会根据负载自动扩缩容
  - 空闲线程会在一段时间后自动回收（生产环境60秒，测试环境5秒）
- **示例**:
```lua validate
local hive = require "silly.hive"

hive.limit(2, 8)  -- 最少2个，最多8个线程
```

### hive.threads()
获取当前线程池中的活跃线程数。

- **返回值**: `integer` - 线程数
- **示例**:
```lua validate
local hive = require "silly.hive"

print("Active hive threads:", hive.threads())
```

### hive.prune()
立即清理空闲线程。

- **说明**: 通常不需要手动调用，线程池会自动管理

## 使用示例

### 示例1：执行阻塞命令

```lua validate
local hive = require "silly.hive"

-- 创建执行shell命令的worker
local shell_worker = hive.spawn([[
    return function(cmd)
        local handle = io.popen(cmd)
        local result = handle:read("*a")
        handle:close()
        return result
    end
]])

-- 执行命令（不阻塞主循环）
local output = hive.invoke(shell_worker, "ls -la")
print("Command output:", output)
```

### 示例2：并发执行阻塞操作

```lua validate
local hive = require "silly.hive"
local waitgroup = require "silly.sync.waitgroup"

hive.limit(1, 10)  -- 最多10个并发线程

local wg = waitgroup.new()
for i = 1, 5 do
    wg:fork(function()
        local worker = hive.spawn([[
            return function(n)
                os.execute("sleep 1")  -- 模拟阻塞操作
                return n * 2
            end
        ]])
        local result = hive.invoke(worker, i)
        print("Result:", result)
    end)
end

wg:wait()
print("All tasks completed")
```

### 示例3：Worker复用

```lua validate
local hive = require "silly.hive"

-- 创建一个可重用的计算worker
local calc_worker = hive.spawn([[
    local config = ...  -- 接收初始化配置
    return function(operation, a, b)
        if operation == "add" then
            return a + b
        elseif operation == "mul" then
            return a * b
        end
    end
]], {precision = 2})

-- 多次调用同一worker
local sum = hive.invoke(calc_worker, "add", 10, 20)
local product = hive.invoke(calc_worker, "mul", 10, 20)
print(sum, product)  -- 30, 200
```

### 示例4：异常处理

```lua validate
local hive = require "silly.hive"

local worker = hive.spawn([[
    return function(x)
        if x < 0 then
            error("Negative number not allowed")
        end
        return math.sqrt(x)
    end
]])

local ok, result = pcall(hive.invoke, worker, -5)
if not ok then
    print("Worker error:", result)
end
```

### 示例5：读取文件（在silly.stdin内部使用）

```lua validate
-- silly.stdin 内部实现原理
local stdin_worker = hive.spawn([[
    local stdin = io.stdin
    return function(fn, ...)
        return stdin[fn](stdin, ...)
    end
]])

-- 在协程中读取stdin（不阻塞）
local line = hive.invoke(stdin_worker, "read", "*l")
```

## Worker并发模型

重要特性：**同一worker在任意时刻只处理一个任务**。

```lua
local worker = hive.spawn([[ return function() os.execute("sleep 1") end ]])

local task = require "silly.task"

-- 两个协程同时调用同一worker
task.fork(function()
    print("Task 1 start")
    hive.invoke(worker)  -- 立即执行
    print("Task 1 done")
end)

task.fork(function()
    print("Task 2 start")
    hive.invoke(worker)  -- 等待Task 1完成
    print("Task 2 done")
end)

-- 输出:
-- Task 1 start
-- Task 2 start
-- (1秒后)
-- Task 1 done
-- (再1秒)
-- Task 2 done
```

这是通过 `silly.sync.mutex` 实现的：

```lua
-- hive.invoke 内部使用互斥锁
function M.invoke(worker, ...)
    local l<close> = lock:lock(worker)  -- 每个worker一把锁
    -- ... 发送任务并等待结果
end
```

## 线程池管理

Hive自动管理线程池生命周期：

1. **启动时**: 不创建任何线程
2. **需要时**: 根据任务数创建线程（最多 `max` 个）
3. **空闲时**: 60秒后自动回收空闲线程（最少保留 `min` 个，测试环境下为5秒）

自动清理通过定时器实现：

```lua
-- 每秒执行一次清理
local prune_timer
prune_timer = function()
    c.prune()
    time.after(1000, prune_timer)
end
```

## 注意事项

::: warning Worker隔离
每个worker运行在独立的Lua VM中，无法访问主VM的全局变量。所有数据必须通过参数传递。
:::

::: warning 数据序列化
参数和返回值通过消息队列传递，会经过序列化。支持的类型：
- ✅ nil, boolean, number, string
- ✅ table（递归序列化）
- ❌ function, thread, userdata（不可序列化）
:::

::: danger 避免滥用
Hive的目的是处理**必须阻塞**的操作。不要用它来：
- 执行纯Lua计算（直接在主线程执行更快）
- 执行异步IO（使用silly.net.*等模块）
- 绕过单线程模型（会引入复杂性）
:::

::: tip 适用场景
- 调用阻塞的系统命令（`os.execute`）
- 读取stdin（`io.stdin:read`）
- 使用不支持异步的C库
- CPU密集计算（如图像处理、加密）
:::

## 参见

- [silly.sync.mutex](./sync/mutex.md) - 互斥锁（hive内部使用）
- [silly.sync.waitgroup](./sync/waitgroup.md) - 协程等待组
- [silly](./silly.md) - 核心模块
