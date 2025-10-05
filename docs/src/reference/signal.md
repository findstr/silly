---
title: silly.signal
icon: bell
category:
  - API参考
tag:
  - 核心
  - 信号
  - Unix
---

# silly.signal

Unix信号处理模块，用于捕获和处理系统信号（如SIGINT、SIGTERM等）。

## 模块导入

```lua validate
local signal = require "silly.signal"
```

::: tip 模块特性
`silly.signal` 模块导出的是一个函数，而不是表。直接调用该函数即可注册信号处理器。
:::

## API

### signal(sig, handler)
注册信号处理函数。

- **参数**:
  - `sig`: `string` - 信号名称（如 "SIGINT"、"SIGTERM"、"SIGUSR1"等）
  - `handler`: `async fun(sig:string)` - 信号处理函数，接收信号名称作为参数
- **返回值**: `function|nil` - 之前注册的处理函数，如果信号不支持则返回 `nil`
- **说明**:
  - 信号处理函数在独立的协程中异步执行
  - 如果未注册处理函数，默认行为是调用 `silly.exit(0)` 退出进程
  - 可以多次调用以更换处理函数

## 支持的信号

常见的Unix信号（具体支持取决于操作系统）：

| 信号名 | 说明 | 典型用途 |
|--------|------|----------|
| SIGINT | 中断信号 (Ctrl+C) | 用户终止程序 |
| SIGTERM | 终止信号 | 优雅关闭 |
| SIGUSR1 | 用户自定义信号1 | 重新加载配置 |
| SIGUSR2 | 用户自定义信号2 | 自定义操作 |
| SIGHUP | 挂起信号 | 重新加载配置 |

## 使用示例

### 示例1：优雅关闭服务器

```lua validate
local silly = require "silly"
local signal = require "silly.signal"

signal("SIGTERM", function(sig)
    print("Received", sig, "- shutting down gracefully")
    -- 停止接受新连接
    -- stop_accepting_connections()
    -- 等待现有请求完成
    -- wait_for_pending_requests()
    -- 退出
    silly.exit(0)
end)
```

### 示例2：重新加载配置

```lua validate
local signal = require "silly.signal"

signal("SIGUSR1", function(sig)
    print("Received", sig, "- reloading configuration")
    local ok, err = pcall(function()
        -- load_config()
        print("Configuration reloaded successfully")
    end)
    if not ok then
        print("Failed to reload configuration:", err)
    end
end)
```

### 示例3：捕获多个信号

```lua validate
local silly = require "silly"
local signal = require "silly.signal"

local function graceful_shutdown(sig)
    print("Shutting down on signal:", sig)
    -- cleanup_resources()
    silly.exit(0)
end

signal("SIGINT", graceful_shutdown)
signal("SIGTERM", graceful_shutdown)
```

### 示例4：调试模式切换

```lua validate
local signal = require "silly.signal"
local logger = require "silly.logger"

signal("SIGUSR2", function(sig)
    if logger.getlevel() == logger.DEBUG then
        logger.setlevel(logger.INFO)
        print("Debug logging disabled")
    else
        logger.setlevel(logger.DEBUG)
        print("Debug logging enabled")
    end
end)
```

## 默认行为

Silly框架默认为 `SIGINT` 注册了处理函数：

```lua
signal("SIGINT", function(_)
    silly.exit(0)
end)
```

你可以覆盖这个默认行为：

```lua validate
local silly = require "silly"
local signal = require "silly.signal"

signal("SIGINT", function(sig)
    print("Custom SIGINT handler")
    -- 自定义清理逻辑
    silly.exit(0)
end)
```

## 注意事项

::: warning 异步执行
信号处理函数在独立协程中执行，不会阻塞主事件循环。处理函数内可以使用所有异步API（如 `time.sleep`、网络调用等）。
:::

::: warning 线程安全
信号处理是通过Silly的消息系统实现的，确保了线程安全。实际的信号捕获发生在C层，然后通过消息队列传递到Lua层处理。
:::

::: danger 不要长时间阻塞
虽然信号处理器是异步的，但建议尽快完成处理。长时间运行的清理操作应该设置超时或使用 `time.after` 异步执行。
:::

## 与logger的集成

`silly.logger` 模块内部使用 `SIGUSR1` 信号来重新打开日志文件（用于日志轮转）：

```lua
-- logger模块内部注册的SIGUSR1处理器
signal("SIGUSR1", function(_)
    local path = env.get("logpath")
    if path then
        c.openfile(path)  -- 重新打开日志文件
    end
end)
```

如果你需要自己使用 `SIGUSR1`，请注意这个内置行为。

## 平台兼容性

- **Linux/macOS**: 完整支持所有标准Unix信号
- **Windows**: 有限支持（SIGINT、SIGTERM等）

## 参见

- [silly](./silly.md) - 核心调度器
- [silly.logger](./logger.md) - 日志系统
