---
title: silly.sync.waitgroup
icon: tasks
category:
  - API参考
tag:
  - 同步原语
  - 协程
  - 并发
---

# silly.sync.waitgroup

等待组（WaitGroup）模块，用于等待多个协程完成。类似于 Go 语言的 sync.WaitGroup，它允许主协程等待一组并发协程全部执行完毕。

## 模块导入

```lua validate
local waitgroup = require "silly.sync.waitgroup"
```

## API 文档

### waitgroup.new()

创建一个新的等待组实例。

- **返回值**: `silly.sync.waitgroup` - 等待组对象
- **示例**:
```lua validate
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()
```

### wg:fork(func)

启动一个协程并将其加入等待组。

- **参数**:
  - `func`: `function` - 要在新协程中执行的函数
- **返回值**: `thread` - 新创建的协程对象
- **说明**:
  - 内部计数器自动递增
  - 协程执行完毕后计数器自动递减
  - 如果协程抛出错误，会自动记录日志并继续
  - 当计数器归零时，会自动唤醒等待的协程
- **示例**:
```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"

local wg = waitgroup.new()

-- 启动一个任务
local co = wg:fork(function()
    time.sleep(100)
    print("Task completed")
end)
```

### wg:wait()

等待所有通过 `fork()` 启动的协程完成。

- **说明**:
  - 阻塞当前协程，直到所有任务完成（计数器归零）
  - 如果计数器已经为0，立即返回
  - 只能有一个协程在 `wait()` 上等待
- **示例**:
```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()

    for i = 1, 3 do
        wg:fork(function()
            time.sleep(100)
            print("Task", i, "done")
        end)
    end

    print("Waiting for all tasks...")
    wg:wait()
    print("All tasks completed!")
end)
```

## 使用示例

### 示例1：基本用法 - 并发任务

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local results = {}

    -- 启动5个并发任务
    for i = 1, 5 do
        wg:fork(function()
            time.sleep(100 * i)  -- 模拟不同耗时的任务
            results[i] = i * i
            print("Task", i, "completed, result:", results[i])
        end)
    end

    print("All tasks started, waiting...")
    wg:wait()
    print("All tasks finished!")

    -- 打印结果
    for i, v in ipairs(results) do
        print("Result[" .. i .. "] =", v)
    end
end)
```

### 示例2：错误处理

waitgroup 自动处理协程中的错误，不会因为单个任务失败而影响其他任务：

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local success_count = 0

    for i = 1, 5 do
        wg:fork(function()
            time.sleep(50)
            if i == 3 then
                error("Task 3 failed!")  -- 这个错误会被捕获并记录
            end
            success_count = success_count + 1
            print("Task", i, "succeeded")
        end)
    end

    wg:wait()
    print("Completed. Success count:", success_count)
end)
```

### 示例3：批量数据处理

使用 waitgroup 并发处理大量数据：

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()

    -- 模拟处理函数
    local function process_item(id)
        time.sleep(50)  -- 模拟网络请求或计算
        return id * 2
    end

    local items = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
    local processed = {}

    for _, item in ipairs(items) do
        wg:fork(function()
            local result = process_item(item)
            processed[item] = result
            print("Processed item", item, "-> result:", result)
        end)
    end

    print("Processing", #items, "items concurrently...")
    wg:wait()
    print("All items processed!")

    -- 验证结果
    for k, v in pairs(processed) do
        print("Item", k, "=", v)
    end
end)
```

### 示例4：限制并发数

虽然 waitgroup 本身不限制并发数，但可以结合信号量实现并发控制：

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local max_concurrent = 3
    local semaphore = 0

    local function acquire()
        while semaphore >= max_concurrent do
            time.sleep(10)
        end
        semaphore = semaphore + 1
    end

    local function release()
        semaphore = semaphore - 1
    end

    -- 启动10个任务，但最多同时执行3个
    for i = 1, 10 do
        acquire()
        wg:fork(function()
            print("Task", i, "started (concurrent:", semaphore .. ")")
            time.sleep(100)
            print("Task", i, "finished")
            release()
        end)
    end

    wg:wait()
    print("All tasks completed with concurrency limit:", max_concurrent)
end)
```

### 示例5：嵌套等待组

waitgroup 可以嵌套使用，实现层次化的并发控制：

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local main_wg = waitgroup.new()

    -- 第一组任务
    main_wg:fork(function()
        local sub_wg = waitgroup.new()
        print("Group 1 started")

        for i = 1, 3 do
            sub_wg:fork(function()
                time.sleep(50)
                print("  Group 1, Task", i, "done")
            end)
        end

        sub_wg:wait()
        print("Group 1 completed")
    end)

    -- 第二组任务
    main_wg:fork(function()
        local sub_wg = waitgroup.new()
        print("Group 2 started")

        for i = 1, 2 do
            sub_wg:fork(function()
                time.sleep(80)
                print("  Group 2, Task", i, "done")
            end)
        end

        sub_wg:wait()
        print("Group 2 completed")
    end)

    main_wg:wait()
    print("All groups completed!")
end)
```

## 注意事项

### 1. 只能在协程中使用

waitgroup 的 `wait()` 方法会挂起当前协程，因此必须在协程中调用：

```lua validate
local silly = require "silly"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    -- 正确：在协程中调用 wait()
    wg:wait()
end)

-- 错误：不能在主线程中直接调用 wait()
-- local wg = waitgroup.new()
-- wg:wait()  -- 这会失败！
```

### 2. 单个等待者限制

一个 waitgroup 实例只能有一个协程在 `wait()` 上等待。如果需要多个等待点，请创建多个 waitgroup 实例。

### 3. 错误处理

`fork()` 启动的协程如果抛出错误，会被自动捕获并记录日志，不会影响其他协程。但错误信息只会记录到日志中，调用者无法直接获取错误。

如果需要收集错误信息，可以在任务函数中自行处理：

```lua validate
local silly = require "silly"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local errors = {}

    for i = 1, 5 do
        wg:fork(function()
            local ok, err = pcall(function()
                time.sleep(50)
                if i == 3 then
                    error("simulated error")
                end
            end)
            if not ok then
                errors[i] = err
            end
        end)
    end

    wg:wait()

    -- 检查错误
    for i, err in pairs(errors) do
        print("Task", i, "failed:", err)
    end
end)
```

### 4. 不要在任务中修改 waitgroup 内部状态

虽然可以获取 `wg.count`，但不应该手动修改它。所有计数管理都应该通过 `fork()` 和内部机制自动完成。

### 5. 避免死锁

确保所有 `fork()` 的任务最终都能完成。如果任务无限循环或永久阻塞，`wait()` 将永远不会返回：

```lua validate
local silly = require "silly"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()

    wg:fork(function()
        -- 错误：无限循环，导致死锁
        -- while true do
        --     silly.wait()
        -- end

        -- 正确：任务会正常结束
        print("Task done")
    end)

    wg:wait()
    print("Success")
end)
```

## 与其他模块配合

waitgroup 常与以下模块配合使用：

- [silly](../silly.md) - 协程调度和任务管理
- [silly.time](../time.md) - 定时器和延时
- [silly.net.http](../net/http.md) - HTTP 并发请求
- [silly.net.tcp](../net/tcp.md) - TCP 并发连接

## 参见

- [silly](../silly.md) - 核心模块
- [silly.time](../time.md) - 定时器模块
