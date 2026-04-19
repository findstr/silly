---
title: silly.task
icon: list-unordered
category:
  - API参考
tag:
  - 核心
  - 协程
  - 调度器
---

# silly.task

协程管理和任务调度模块，提供协程的创建、挂起、唤醒以及分布式追踪功能。

## 模块导入

```lua validate
local task = require "silly.task"
local trace = require "silly.trace"
```

## 协程管理

### task.running()
获取当前正在运行的协程。

- **返回值**: `thread` - 当前协程
- **示例**:
```lua validate
local task = require "silly.task"

local current_task = task.running()
```

### task.fork(func, userdata)
创建并调度一个新协程执行异步任务。

- **参数**:
  - `func`: `async fun()` - 异步函数
  - `userdata`: `any` (可选) - 传递给唤醒时的参数（通常用于内部机制，业务层较少使用）
- **返回值**: `thread` - 新创建的协程
- **示例**:
```lua validate
local task = require "silly.task"

task.fork(function()
    print("Hello from forked task")
end)
```

### task.wait()
挂起当前协程，等待被唤醒。

- **返回值**: `any` - 唤醒时传入的数据
- **注意**: 必须在协程中调用，且协程状态必须为 "RUN"
- **示例**:
```lua validate
local task = require "silly.task"

task.fork(function()
    local data = task.wait()
    print("Woken up with data:", data)
end)
```

### task.wakeup(task, result)
唤醒一个正在等待的协程。

- **参数**:
  - `task`: `thread` - 要唤醒的协程
  - `result`: `any` - 传递给协程的数据
- **注意**: 目标协程状态必须为 "WAIT"
- **示例**:
```lua validate
local task = require "silly.task"
local time = require "silly.time"

local t
task.fork(function()
    t = task.running()
    local data = task.wait()
    print("Got:", data)
end)

-- 延迟唤醒，确保协程已经进入wait状态
time.after(10, function()
    task.wakeup(t, "hello")
end)
```

### task.status(task)
获取协程的当前状态。

- **参数**:
  - `task`: `thread` - 目标协程
- **返回值**: `string|nil` - 状态字符串，可能的值：
  - `"RUN"` - 正在运行
  - `"WAIT"` - 已挂起，等待 `task.wakeup` 唤醒（通常由 `task.wait` 触发）
  - `"READY"` - 已就绪，等待下一次调度恢复
  - `nil` - 协程未被追踪（未知、已结束，或从未通过 `task.fork` 创建）

## 任务统计

### task.readycount()
获取当前就绪队列中等待执行的任务数量。

- **返回值**: `integer` - 任务数量

### task.inspect()
获取所有协程的状态信息（用于调试）。

- **返回值**: `table` - 协程状态表，格式：
```lua
{
    [thread] = {
        traceback = "stack trace string",
        status = "RUN|WAIT|READY"
    }
}
```

## 分布式追踪

task 模块支持为每个协程关联分布式追踪 ID，用于实现跨服务的请求链路追踪。

> 📖 **完整文档**: 详细的分布式追踪 API 和使用指南请参见 **[silly.trace](./trace.md)** 模块文档。

**快速示例**：

```lua validate
local trace = require "silly.trace"

-- 设置节点 ID（服务启动时）
trace.setnode(1)

-- 创建新的 trace（处理新请求时）
trace.spawn()

-- 传播 trace 到下游（调用其他服务时）
local traceid = trace.propagate()

-- 附加上游的 trace（接收请求时）
trace.attach(upstream_traceid)
```

**相关 API**:
- [trace.setnode()](./trace.md#tracesetnodenodeid) - 设置节点 ID
- [trace.spawn()](./trace.md#tracespawn) - 创建新 trace
- [trace.attach()](./trace.md#traceattachid) - 附加 trace
- [trace.propagate()](./trace.md#tracepropagate) - 传播 trace

## 高级API

::: danger 内部API警告
以下函数以 `_` 开头，属于内部实现细节，**不应在业务代码中使用**。
:::

### task._create(f)
创建协程（内部API）。

### task._resume(t, ...)
恢复协程执行（内部API）。

### task._yield(...)
挂起当前协程（内部API）。

### task._dispatch_wakeup()
调度就绪队列中的任务（内部API）。

### task._start(func)
启动主协程（内部API）。

### task._exit(status)
退出进程（内部API，请使用 `silly.exit`）。

### task.hook(create, term)
设置协程创建和终止的钩子函数（高级用法）。

- **参数**:
  - `create`: `function|nil` - 创建钩子
  - `term`: `function|nil` - 终止钩子
- **返回值**: `function, function` - 当前的resume和yield函数
