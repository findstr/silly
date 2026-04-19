---
title: silly.logger
icon: file-lines
category:
  - API参考
tag:
  - 核心
  - 日志
  - 调试
---

# silly.logger

分级日志系统，支持动态调整日志级别和日志文件轮转。

## 模块导入

```lua validate
local logger = require "silly.logger"
```

## 日志级别

### 级别常量

```lua
logger.DEBUG = 0  -- 调试信息
logger.INFO  = 1  -- 一般信息
logger.WARN  = 2  -- 警告信息
logger.ERROR = 3  -- 错误信息
```

日志级别从低到高：DEBUG < INFO < WARN < ERROR

## API函数

### logger.getlevel()
获取当前日志级别。

- **返回值**: `integer` - 当前级别（0-3）
- **示例**:
```lua validate
local logger = require "silly.logger"

local level = logger.getlevel()
print("Current log level:", level)
```

### logger.setlevel(level)
设置日志级别。

- **参数**:
  - `level`: `integer` - 新的日志级别（0-3）
- **说明**: 只有大于等于设定级别的日志会被输出
- **示例**:
```lua validate
local logger = require "silly.logger"

logger.setlevel(logger.INFO)  -- 只输出INFO及以上级别
logger.debug("This will not print")
logger.info("This will print")
```

## 日志输出函数

所有非格式化日志函数（`debug`、`info`、`warn`、`error`）接受任意数量的参数，并按原生类型分别序列化：

- **字符串** 原样输出（不加引号）。
- **数字** 保留整数/浮点表示（不需要 `tostring()`）。
- **布尔值** 输出 `true` / `false`。
- **Nil** 输出 `nil`。
- **表** 序列化为 `{key=value, [1]=value, ...}` 形式，最大深度为 5；超过部分截断为 `{...}`。

相邻参数之间用空格分隔，行末自动换行。

### logger.debug(...)
输出DEBUG级别日志（级别0）。

- **参数**: `...` - 任意数量的值（字符串、数字、布尔、nil、表）
- **示例**:
```lua validate
local logger = require "silly.logger"

local x, y = 10, 20
logger.debug("Variable x =", x, "y =", y)
logger.debug("user profile:", {id = 42, name = "alice", roles = {"admin", "owner"}})
```

### logger.info(...)
输出INFO级别日志（级别1）。

```lua validate
local logger = require "silly.logger"

logger.info("Server started on port", 8080)
```

### logger.warn(...)
输出WARN级别日志（级别2）。

```lua validate
local logger = require "silly.logger"

logger.warn("Connection timeout, retrying...")
```

### logger.error(...)
输出ERROR级别日志（级别3）。

```lua validate
local logger = require "silly.logger"

local err = "connection refused"
logger.error("Database connection failed:", err)
```

## 格式化日志函数

`*f` 系列函数（`debugf`、`infof`、`warnf`、`errorf`）接受一个格式串，**只支持 `%s` 占位符**；用 `%%` 输出字面量 `%`。任何其他转换符都会抛出形如 `invalid option '%d' to 'format', only support '%s'` 的错误。

虽然名为 `%s`，这里的占位符与非格式化日志使用同一个原生序列化器 —— **数字、表都不需要先 `tostring()` 自行转换**。

### logger.debugf(format, ...)
输出格式化的DEBUG日志。

- **参数**:
  - `format`: `string` - 格式字符串，占位符为 `%s`，`%%` 表示字面 `%`
  - `...` - 每个占位符对应的值（任意可记录类型）
- **示例**:
```lua validate
local logger = require "silly.logger"

local username = "alice"
local user_id = 12345
local timestamp = 1234567890

-- 数字会直接序列化，无需 tostring()
logger.debugf("User %s (ID: %s) logged in at %s", username, user_id, timestamp)

-- 表也支持
logger.debugf("Request headers: %s", {["content-type"] = "application/json"})

-- 通过 %% 输出字面量 %
logger.debugf("progress: %s%%", 42)

-- 不支持 —— 会直接抛错：
-- logger.debugf("id=%d count=%f", user_id, timestamp)
```

### logger.infof(format, ...)
输出格式化的INFO日志（**只支持 `%s` 占位符**）。

### logger.warnf(format, ...)
输出格式化的WARN日志（**只支持 `%s` 占位符**）。

### logger.errorf(format, ...)
输出格式化的ERROR日志（**只支持 `%s` 占位符**）。

## 使用示例

### 示例1：基础日志记录

```lua validate
local logger = require "silly.logger"

logger.setlevel(logger.DEBUG)

logger.debug("Application starting")
logger.info("Listening on 0.0.0.0:8080")
logger.warn("Configuration file not found, using defaults")
logger.error("Failed to connect to database")
```

### 示例2：格式化日志

```lua validate
local logger = require "silly.logger"

local user_id = 12345
local action = "login"
local timestamp = os.time()

-- 数字、字符串、表都会原生序列化，无需 tostring()
logger.infof("User [%s] performed action '%s' at %s", user_id, action, timestamp)

-- 表会被结构化输出
logger.infof("context: %s", {user = user_id, action = action})
```

### 示例3：动态调整日志级别

```lua validate
local logger = require "silly.logger"
local signal = require "silly.signal"

-- 正常运行时使用INFO级别
logger.setlevel(logger.INFO)

-- 通过信号切换到DEBUG模式
-- 注意：SIGUSR2 在程序繁忙时可能被合并或丢失，请避免用于关键操作。
signal("SIGUSR1", function()
    if logger.getlevel() == logger.DEBUG then
        logger.setlevel(logger.INFO)
        logger.info("Switched to INFO level")
    else
        logger.setlevel(logger.DEBUG)
        logger.info("Switched to DEBUG level")
    end
end)
```

### 示例4：条件日志

```lua validate
local logger = require "silly.logger"

local function process_request(req)
    if logger.getlevel() <= logger.DEBUG then
        -- 只在DEBUG模式下序列化请求（避免性能开销）
        logger.debug("Request:", json.encode(req))
    end

    -- 处理逻辑
    local ok, err = handle(req)
    if not ok then
        logger.error("Request processing failed:", err)
    end
end
```

## 日志轮转

Silly支持日志文件轮转。发送 `SIGUSR1` 信号会重新打开日志文件：

```bash
# 执行日志轮转
mv /path/to/app.log /path/to/app.log.old
kill -USR1 <pid>  # 重新打开日志文件
```

这个功能由 `silly.logger` 模块内部自动处理：

```lua
-- 内部实现
signal("SIGUSR1", function(_)
    local path = env.get("logpath")
    if path then
        c.openfile(path)  -- 重新打开日志文件
    end
end)
```

## 性能优化

日志系统经过性能优化：

1. **级别过滤**: 低于当前级别的日志函数调用被替换为空函数（nop），零开销
2. **延迟格式化**: 格式化日志（`*f`函数）只在日志会被输出时才执行格式化

```lua
-- 这个调用在INFO级别下完全被优化掉
logger.setlevel(logger.INFO)
logger.debug("Expensive operation:", serialize_large_object())
-- serialize_large_object() 不会被调用
```

## 日志输出目标

日志输出目标通过环境变量 `logpath` 配置：

- **未设置**: 输出到标准错误（stderr）
- **设置路径**: 输出到指定文件

```bash
# 启动时指定日志文件
./silly main.lua --logpath=/var/log/myapp.log
```

## 注意事项

::: tip 动态优化
调用 `logger.setlevel()` 时，日志系统会动态替换日志函数的实现：
- 被过滤的级别 → 空函数（nop）
- 可见的级别 → 实际的C函数
这确保了低级别日志调用的零开销。
:::

::: warning 避免副作用
不要在日志参数中执行有副作用的操作：
```lua
-- ❌ 错误：即使日志被过滤，counter也会增加
logger.debug("Count:", counter = counter + 1)

-- ✅ 正确：先计算，再日志
counter = counter + 1
logger.debug("Count:", counter)
```
:::

::: warning 格式化限制
日志格式化函数（`*f` 系列）**只支持 `%s` 占位符**：
```lua
local count = 42
local ratio = 0.75

-- ❌ 错误：%d, %f, %x 会在调用时直接抛错
-- logger.infof("Count: %d, Ratio: %.2f", count, ratio)

-- ✅ 正确：使用 %s —— 数字、布尔、表都会原生序列化
logger.infof("Count: %s, Ratio: %s", count, ratio)

-- ✅ 或者使用非格式化函数
logger.info("Count:", count, "Ratio:", ratio)
```

与 `string.format` 不同，这里的 `%s` 不会调用 `tostring()` —— 底层 C 序列化器直接打印原生 Lua 值，所以你永远不需要手动转换数字或表。
:::

## 参见

- [silly.signal](./signal.md) - 信号处理（用于日志轮转）
- [silly](./silly.md) - 核心模块
