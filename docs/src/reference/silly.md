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

核心模块，提供基础工具函数和进程管理功能。

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

请参考 [silly.task](./task.md) 模块。

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

请参考 [silly.task](./task.md) 模块。

## 分布式追踪

请参考 [silly.task](./task.md) 模块。

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

### silly._start(func)
启动主协程（内部API）。

### silly._dispatch_wakeup()
调度就绪队列中的任务（内部API）。

## 参见

- [silly.task](./task.md) - 协程管理和任务调度
- [silly.time](./time.md) - 定时器和时间管理
- [silly.hive](./hive.md) - 工作线程池
- [silly.sync.*](../sync/) - 同步原语
