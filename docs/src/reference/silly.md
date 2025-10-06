---
title: silly
icon: gear
category:
  - API参考
tag:
  - 核心
  - 协程
  - 调度器
---

# silly

核心调度器模块，提供协程管理、任务调度和分布式追踪功能。

## 模块导入

```lua validate
local silly = require "silly"
```

## 常量属性

### silly.pid
- **类型**: `integer`
- **说明**: 当前进程ID

### silly.gitsha1
- **类型**: `string`
- **说明**: 构建时的Git SHA1版本号

### silly.version
- **类型**: `string`
- **说明**: Silly框架版本号

## 核心函数

### silly.genid()
生成全局唯一ID。

- **返回值**: `integer` - 唯一ID
- **示例**:
```lua validate
local silly = require "silly"

local id = silly.genid()
```

### silly.tostring(ptr)
将C指针转换为字符串表示。

- **参数**:
  - `ptr`: `lightuserdata` - C指针
- **返回值**: `string` - 指针的十六进制字符串表示

### silly.register(msgtype, handler)
注册消息处理函数（内部API，业务代码不应使用）。

- **参数**:
  - `msgtype`: `integer` - 消息类型
  - `handler`: `function` - 处理函数

## 协程管理

### silly.running()
获取当前正在运行的协程。

- **返回值**: `thread` - 当前协程
- **示例**:
```lua validate
local silly = require "silly"

local current_task = silly.running()
```

### silly.fork(func)
创建并调度一个新协程执行异步任务。

- **参数**:
  - `func`: `async fun()` - 异步函数
- **返回值**: `thread` - 新创建的协程
- **示例**:
```lua validate
local silly = require "silly"

silly.fork(function()
    print("Hello from forked task")
end)
```

### silly.wait()
挂起当前协程，等待被唤醒。

- **返回值**: `any` - 唤醒时传入的数据
- **注意**: 必须在协程中调用，且协程状态必须为 "RUN"
- **示例**:
```lua validate
local silly = require "silly"

silly.fork(function()
    local data = silly.wait()
    print("Woken up with data:", data)
end)
```

### silly.wakeup(task, result)
唤醒一个正在等待的协程。

- **参数**:
  - `task`: `thread` - 要唤醒的协程
  - `result`: `any` - 传递给协程的数据
- **注意**: 目标协程状态必须为 "WAIT"
- **示例**:
```lua validate
local silly = require "silly"
local time = require "silly.time"
local task
silly.fork(function()
    task = silly.wait()
    print("Got:", task)
end)
-- 延迟唤醒，确保协程已经进入wait状态
time.after(10, function()
    silly.wakeup(task, "hello")
end)
```

### silly.status(task)
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

### silly.exit(status)
退出Silly进程。

- **参数**:
  - `status`: `integer` - 退出码
- **示例**:
```lua validate
local silly = require "silly"

silly.exit(0)  -- 正常退出
```

## 任务统计

### silly.taskstat()
获取当前就绪队列中等待执行的任务数量。

- **返回值**: `integer` - 任务数量

### silly.tasks()
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

### silly.tracenew()
创建新的追踪ID，或返回当前协程的追踪ID。

- **返回值**: `integer` - 追踪ID

### silly.trace(id)
设置当前协程的追踪ID。

- **参数**:
  - `id`: `integer` - 追踪ID
- **返回值**: `integer` - 之前的追踪ID

### silly.tracespan(message)
为当前追踪添加一个span标记。

- **参数**:
  - `message`: `string` - span消息
- **示例**:
```lua validate
local silly = require "silly"

silly.tracespan("database query started")
```

### silly.tracepropagate()
生成新的追踪ID（用于跨服务传播）。

- **返回值**: `integer` - 新的追踪ID

## 错误处理

### silly.error(errmsg)
记录错误信息和堆栈跟踪。

- **参数**:
  - `errmsg`: `string` - 错误消息

### silly.pcall(f, ...)
受保护调用函数，捕获错误并生成堆栈跟踪。

- **参数**:
  - `f`: `function` - 要调用的函数
  - `...`: 函数参数
- **返回值**:
  - `boolean` - 是否成功
  - `...` - 成功时返回函数结果，失败时返回错误信息

## 高级API

::: danger 内部API警告
以下函数以 `_` 开头，属于内部实现细节，**不应在业务代码中使用**。
:::

### silly._task_create(f)
创建协程（内部API）。

### silly._task_resume(t, ...)
恢复协程执行（内部API）。

### silly._task_yield(...)
挂起当前协程（内部API）。

### silly._dispatch_wakeup()
调度就绪队列中的任务（内部API）。

### silly._start(func)
启动主协程（内部API）。

### silly.task_hook(create, term)
设置协程创建和终止的钩子函数（高级用法）。

- **参数**:
  - `create`: `function|nil` - 创建钩子
  - `term`: `function|nil` - 终止钩子
- **返回值**: `function, function` - 当前的resume和yield函数

## 参见

- [silly.time](./time.md) - 定时器和时间管理
- [silly.hive](./hive.md) - 工作线程池
- [silly.sync.*](../sync/) - 同步原语
