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
  - `"WAIT"` - 等待中
  - `"READY"` - 就绪队列中
  - `"SLEEP"` - 睡眠中
  - `"EXIT"` - 已退出
  - `nil` - 协程已销毁

## 任务统计

### task.taskstat()
获取当前就绪队列中等待执行的任务数量。

- **返回值**: `integer` - 任务数量

### task.tasks()
获取所有协程的状态信息（用于调试）。

- **返回值**: `table` - 协程状态表，格式：
```lua
{
    [thread] = {
        traceback = "stack trace string",
        status = "RUN|WAIT|READY|..."
    }
}
```

## 分布式追踪

### task.tracenode(nodeid)
设置当前节点的节点ID（用于trace ID生成）。

- **参数**:
  - `nodeid`: `integer` - 节点ID（16位，0-65535）
- **示例**:
```lua validate
local task = require "silly.task"

-- 在服务启动时设置节点ID
task.tracenode(1)  -- 设置为节点1
```

### task.tracespawn()
创建新的根追踪ID并设置为当前协程的追踪ID。

- **返回值**: `integer` - 之前的追踪ID（可用于后续恢复）
- **示例**:
```lua validate
local task = require "silly.task"

-- 处理新的HTTP请求时创建新的trace ID
local old_trace = task.tracespawn()
-- ... 处理请求 ...
-- 如需恢复旧的trace context
task.traceset(old_trace)
```

### task.traceset(id)
设置当前协程的追踪ID。

- **参数**:
  - `id`: `integer` - 追踪ID
- **返回值**: `integer` - 之前的追踪ID

### task.tracepropagate()
获取用于跨服务传播的追踪ID（保留root trace，替换node ID为当前节点）。

- **返回值**: `integer` - 传播用的追踪ID
- **示例**:
```lua validate
local task = require "silly.task"

-- 在 RPC 调用时传播 trace ID
local trace_id = task.tracepropagate()
-- 将 trace_id 发送到远程服务
```

## 高级API

::: danger 内部API警告
以下函数以 `_` 开头，属于内部实现细节，**不应在业务代码中使用**。
:::

### task._task_create(f)
创建协程（内部API）。

### task._task_resume(t, ...)
恢复协程执行（内部API）。

### task._task_yield(...)
挂起当前协程（内部API）。

### task._dispatch_wakeup()
调度就绪队列中的任务（内部API）。

### task._start(func)
启动主协程（内部API）。

### task._exit(status)
退出进程（内部API，请使用 `silly.exit`）。

### task.task_hook(create, term)
设置协程创建和终止的钩子函数（高级用法）。

- **参数**:
  - `create`: `function|nil` - 创建钩子
  - `term`: `function|nil` - 终止钩子
- **返回值**: `function, function` - 当前的resume和yield函数
