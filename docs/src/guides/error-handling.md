---
title: 错误处理最佳实践
icon: shield-alert
category:
  - 操作指南
tag:
  - 错误处理
  - 异常捕获
  - 最佳实践
  - 调试
---

# 错误处理最佳实践

本指南介绍在 Silly 框架中进行错误处理的最佳实践，帮助你构建健壮、可靠的应用程序。

## 简介

### 为什么错误处理很重要？

良好的错误处理是构建生产级应用的基础：

- **稳定性**：防止程序因未处理的错误而崩溃
- **可调试性**：提供清晰的错误信息，快速定位问题
- **用户体验**：返回友好的错误消息，而不是暴露内部实现
- **可维护性**：统一的错误处理模式使代码更易维护

### Silly 框架的错误处理机制

Silly 采用 Lua 的错误处理机制：

- **返回值模式**：函数返回 `(result, error)` 或 `(nil, error)`
- **协程安全**：错误不会跨协程传播，每个协程独立处理
- **堆栈跟踪**：使用 `silly.pcall()` 自动生成堆栈跟踪

## 错误类型

在 Silly 应用中，你会遇到以下几类错误：

### 1. 网络错误

网络操作可能因连接失败、超时、连接断开等原因失败。

**常见场景**：
- TCP/UDP 连接失败
- HTTP 请求超时
- WebSocket 连接断开
- DNS 解析失败

**示例**：

```lua
local silly = require "silly"
local tcp = require "silly.net.tcp"

silly.fork(function()
    -- 网络连接可能失败
    local fd, err = tcp.connect("192.0.2.1:9999")  -- 不支持超时参数
    if not fd then
        print("连接失败:", err)
        -- 处理错误：记录日志、重试、返回错误响应等
        return
    end

    -- 读取数据可能失败
    local data, err = tcp.read(fd, 1024)
    if not data then
        print("读取失败:", err)
        tcp.close(fd)
        return
    end

    -- 成功处理
    print("接收数据:", data)
    tcp.close(fd)
end)
```

### 2. 数据库错误

数据库操作可能因连接失败、SQL 语法错误、约束冲突等原因失败。

**常见场景**：
- 连接池耗尽
- SQL 语法错误
- 主键/唯一键冲突
- 外键约束违反
- 死锁
- 事务超时

**示例**：

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

silly.fork(function()
    -- 查询可能失败
    local res, err = db:query("SELECT * FROM users WHERE id = ?", 123)
    if not res then
        print("查询失败:", err.message)
        print("错误码:", err.errno)
        print("SQL状态:", err.sqlstate)

        -- 根据错误码处理
        if err.errno == 1146 then
            print("表不存在，需要创建表")
        elseif err.errno == 2006 then
            print("MySQL 连接已断开，需要重连")
        end
        return
    end

    -- 成功处理
    print("查询到", #res, "条记录")
end)
```

### 3. 业务逻辑错误

应用自身的业务规则验证失败。

**常见场景**：
- 参数验证失败
- 权限不足
- 业务状态不允许操作
- 资源不存在

**示例**：

```lua
local function transfer_money(from_id, to_id, amount)
    -- 参数验证
    if amount <= 0 then
        return nil, "转账金额必须大于0"
    end

    if from_id == to_id then
        return nil, "不能向自己转账"
    end

    -- 检查余额
    local balance = get_balance(from_id)
    if not balance then
        return nil, "账户不存在"
    end

    if balance < amount then
        return nil, "余额不足"
    end

    -- 执行转账...
    return true
end

-- 使用
silly.fork(function()
    local ok, err = transfer_money(1, 2, 100)
    if not ok then
        print("转账失败:", err)
        return
    end
    print("转账成功")
end)
```

### 4. 超时错误

异步操作超时未完成。

**常见场景**：
- HTTP 请求超时
- 数据库查询超时
- RPC 调用超时
- 分布式锁获取超时

**示例**：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local time = require "silly.time"

silly.fork(function()
    -- 设置超时
    local timeout = 5000  -- 5秒

    local timer = time.after(timeout, function()
        print("HTTP 请求超时")
    end)

    local response, err = http.GET("http://slow-api.example.com/data")

    -- 取消超时定时器
    time.cancel(timer)

    if not response then
        print("请求失败:", err)
        return
    end

    print("响应:", response.body)
end)
```

## 错误处理模式

### 1. 返回值检查模式

这是 Silly 中最常见的错误处理模式。

**优点**：
- 明确、易理解
- 强制调用者处理错误
- 性能开销小

**示例**：

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

silly.fork(function()
    -- 基本检查
    local res, err = db:query("SELECT * FROM users")
    if not res then
        print("查询失败:", err.message)
        return
    end

    -- 链式检查
    local user_id = res[1] and res[1].id
    if not user_id then
        print("未找到用户")
        return
    end

    -- 继续处理
    print("用户ID:", user_id)
end)
```

**最佳实践**：

```lua
-- 推荐：立即检查错误
local res, err = db:query("SELECT * FROM users")
if not res then
    print("错误:", err.message)
    return
end

-- 不推荐：延迟检查
local res, err = db:query("SELECT * FROM users")
-- ... 很多其他代码 ...
if not res then  -- 容易忘记检查
    print("错误:", err.message)
end
```

### 2. pcall/xpcall 异常捕获

用于捕获运行时错误和保护关键代码段。

**优点**：
- 防止程序崩溃
- 捕获所有类型的错误（包括 Lua 运行时错误）
- 生成堆栈跟踪

**示例**：

```lua
local silly = require "silly"

silly.fork(function()
    -- 使用 silly.pcall 捕获错误并生成堆栈跟踪
    local ok, result = silly.pcall(function()
        local data = parse_json('{"invalid json}')
        return data
    end)

    if not ok then
        print("捕获到错误:", result)
        -- result 包含完整的堆栈跟踪
        return
    end

    print("解析结果:", result)
end)
```

**使用场景**：

```lua
local silly = require "silly"
local json = require "silly.encoding.json"

-- 1. 保护关键操作
silly.fork(function()
    local ok, err = silly.pcall(function()
        -- 可能抛出异常的代码
        local data = json.decode(user_input)
        process_data(data)
    end)

    if not ok then
        print("处理失败:", err)
    end
end)

-- 2. 保护协程主循环
silly.fork(function()
    while true do
        local ok, err = silly.pcall(function()
            handle_message()
        end)

        if not ok then
            print("消息处理失败:", err)
            -- 继续处理下一条消息，而不是崩溃
        end
    end
end)
```

**xpcall 示例**：

```lua
local silly = require "silly"

-- 自定义错误处理函数
local function error_handler(err)
    print("捕获到错误:", err)
    print("堆栈跟踪:", debug.traceback())
    -- 记录到日志系统
    log_error(err)
    return err
end

silly.fork(function()
    local ok, result = xpcall(function()
        return risky_operation()
    end, error_handler)

    if not ok then
        print("操作失败")
    end
end)
```

### 3. 错误传播

将错误向上传播到调用者。

**示例**：

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

-- 底层函数：直接返回错误
local function get_user_by_id(id)
    local res, err = db:query("SELECT * FROM users WHERE id = ?", id)
    if not res then
        return nil, "数据库错误: " .. err.message
    end

    if #res == 0 then
        return nil, "用户不存在"
    end

    return res[1]
end

-- 中间层函数：添加上下文后传播
local function get_user_email(id)
    local user, err = get_user_by_id(id)
    if not user then
        return nil, "获取邮箱失败: " .. err
    end

    if not user.email then
        return nil, "用户未设置邮箱"
    end

    return user.email
end

-- 顶层函数：处理错误
silly.fork(function()
    local email, err = get_user_email(123)
    if not email then
        print("错误:", err)  -- 包含完整的错误链
        -- 返回给客户端
        return {success = false, error = err}
    end

    print("邮箱:", email)
    return {success = true, email = email}
end)

### 4. 错误恢复

尝试从错误中恢复，继续执行。

**示例**：

```lua
local silly = require "silly"
local tcp = require "silly.net.tcp"
local time = require "silly.time"

-- 带重试的连接函数
local function connect_with_retry(addr, max_retries, retry_delay)
    max_retries = max_retries or 3
    retry_delay = retry_delay or 1000

    for i = 1, max_retries do
        local fd, err = tcp.connect(addr)
        if fd then
            print("连接成功")
            return fd
        end

        print(string.format("连接失败 (尝试 %d/%d): %s", i, max_retries, err))

        if i < max_retries then
            print(string.format("等待 %d 毫秒后重试...", retry_delay))
            time.sleep(retry_delay)
            -- 指数退避
            retry_delay = retry_delay * 2
        end
    end

    return nil, "连接失败，已达到最大重试次数"
end

silly.fork(function()
    local fd, err = connect_with_retry("127.0.0.1:8080", 5, 1000)
    if not fd then
        print("无法连接:", err)
        return
    end

    -- 使用连接...
    tcp.close(fd)
end)
```

**数据库连接恢复**：

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

-- 带重连的查询函数
local function safe_query(sql, ...)
    local max_retries = 2

    for i = 1, max_retries do
        local res, err = db:query(sql, ...)

        if res then
            return res
        end

        -- 检查是否是连接错误
        if err.errno == 2006 or err.errno == 2013 then
            print("MySQL 连接丢失，尝试重连...")
            -- 这里可以重新创建连接池
            -- 实际应用中应该有重连机制
        else
            -- 非连接错误，直接返回
            return nil, err
        end
    end

    return nil, {message = "查询失败，连接无法恢复"}
end

silly.fork(function()
    local res, err = safe_query("SELECT * FROM users")
    if not res then
        print("查询失败:", err.message)
        return
    end

    print("查询成功，记录数:", #res)
end)
```

## 协程错误处理

### silly.fork 中的错误

协程中的错误不会影响其他协程，但需要妥善处理。

**问题示例**：

```lua
local silly = require "silly"

silly.start(function()
    print("主协程开始")

    -- 子协程中的错误不会传播到主协程
    silly.fork(function()
        error("子协程中的错误")  -- 这会导致子协程崩溃
    end)

    silly.fork(function()
        print("其他协程正常运行")  -- 这个协程不受影响
    end)

    print("主协程继续")
end)
```

**解决方案**：在协程入口处捕获错误

```lua
local silly = require "silly"

-- 包装函数：捕获协程中的所有错误
local function safe_fork(func)
    silly.fork(function()
        local ok, err = silly.pcall(func)
        if not ok then
            print("协程错误:", err)
            -- 记录到日志
            silly.error(err)
        end
    end)
end

-- 使用安全的 fork
safe_fork(function()
    error("这个错误会被捕获")
end)

safe_fork(function()
    print("正常执行")
end)
```

### 错误日志记录

使用 `silly.error()` 记录错误和堆栈跟踪。

```lua
local silly = require "silly"

silly.fork(function()
    local ok, err = silly.pcall(function()
        -- 可能出错的代码
        local result = risky_operation()
        return result
    end)

    if not ok then
        -- 使用 silly.error 记录错误（包含堆栈跟踪）
        silly.error(err)
    end
end)
```

### 防止协程崩溃

在长期运行的协程中保护主循环。

```lua
local silly = require "silly"
local time = require "silly.time"

-- 工作协程模板
local function worker_loop()
    while true do
        local ok, err = silly.pcall(function()
            -- 执行工作
            process_task()
        end)

        if not ok then
            print("任务处理失败:", err)
            silly.error(err)
            -- 短暂延迟后继续，避免快速循环
            time.sleep(100)
        end

        -- 等待下一个任务
        time.sleep(1000)
    end
end

silly.fork(worker_loop)
print("工作协程已启动")
```

## HTTP API 错误响应

### 统一错误格式

为 API 定义统一的错误响应格式。

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- 统一的响应格式
local function success_response(data)
    return {
        success = true,
        data = data,
    }
end

local function error_response(code, message, details)
    return {
        success = false,
        error = {
            code = code,
            message = message,
            details = details or {},
        }
    }
end

-- 发送 JSON 响应
local function send_json(stream, status, data)
    local body = json.encode(data)
    stream:respond(status, {
        ["content-type"] = "application/json",
        ["content-length"] = #body,
    })
    stream:close(body)
end

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        -- 成功响应
        if stream.path == "/api/users" then
            send_json(stream, 200, success_response({
                users = {
                    {id = 1, name = "Alice"},
                    {id = 2, name = "Bob"},
                }
            }))
            return
        end

        -- 错误响应
        send_json(stream, 404, error_response(
            "NOT_FOUND",
            "资源不存在",
            {path = stream.path}
        ))
    end
}

print("HTTP 服务器已启动")
```

### 错误码设计

使用语义化的错误码。

```lua
-- 定义错误码常量
local ErrorCode = {
    -- 客户端错误 (400-499)
    BAD_REQUEST = {code = "BAD_REQUEST", status = 400, message = "请求参数错误"},
    UNAUTHORIZED = {code = "UNAUTHORIZED", status = 401, message = "未授权"},
    FORBIDDEN = {code = "FORBIDDEN", status = 403, message = "禁止访问"},
    NOT_FOUND = {code = "NOT_FOUND", status = 404, message = "资源不存在"},
    CONFLICT = {code = "CONFLICT", status = 409, message = "资源冲突"},
    VALIDATION_ERROR = {code = "VALIDATION_ERROR", status = 422, message = "数据验证失败"},

    -- 服务器错误 (500-599)
    INTERNAL_ERROR = {code = "INTERNAL_ERROR", status = 500, message = "服务器内部错误"},
    DATABASE_ERROR = {code = "DATABASE_ERROR", status = 500, message = "数据库错误"},
    SERVICE_UNAVAILABLE = {code = "SERVICE_UNAVAILABLE", status = 503, message = "服务不可用"},
}

-- 错误处理函数
local function handle_error(stream, error_code, details)
    local response = {
        success = false,
        error = {
            code = error_code.code,
            message = error_code.message,
            details = details or {},
        }
    }
    send_json(stream, error_code.status, response)
end

-- 使用示例
http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        if stream.path == "/api/users" and stream.method == "POST" then
            local body, err = stream:readall()
            if not body then
                handle_error(stream, ErrorCode.BAD_REQUEST, {
                    reason = "无法读取请求体"
                })
                return
            end

            local user = json.decode(body)
            if not user or not user.name or not user.email then
                handle_error(stream, ErrorCode.VALIDATION_ERROR, {
                    missing_fields = {"name", "email"}
                })
                return
            end

            -- 处理用户创建...
            send_json(stream, 201, success_response({
                user = {id = 123, name = user.name, email = user.email}
            }))
        end
    end
}
```

### 用户友好的错误消息

提供清晰、可操作的错误消息。

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- 验证函数
local function validate_user(user)
    local errors = {}

    if not user.name then
        table.insert(errors, {
            field = "name",
            message = "姓名不能为空"
        })
    elseif #user.name < 2 then
        table.insert(errors, {
            field = "name",
            message = "姓名至少需要2个字符"
        })
    end

    if not user.email then
        table.insert(errors, {
            field = "email",
            message = "邮箱不能为空"
        })
    elseif not user.email:match("^[%w._%+-]+@[%w.-]+%.[%a]+$") then
        table.insert(errors, {
            field = "email",
            message = "邮箱格式不正确"
        })
    end

    if user.age and (user.age < 18 or user.age > 120) then
        table.insert(errors, {
            field = "age",
            message = "年龄必须在18到120之间"
        })
    end

    if #errors > 0 then
        return nil, errors
    end

    return true
end

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        if stream.path == "/api/users" and stream.method == "POST" then
            local body = stream:readall()
            local user = json.decode(body)

            -- 验证数据
            local ok, errors = validate_user(user)
            if not ok then
                send_json(stream, 422, {
                    success = false,
                    error = {
                        code = "VALIDATION_ERROR",
                        message = "数据验证失败，请检查以下字段",
                        validation_errors = errors
                    }
                })
                return
            end

            -- 创建用户...
            send_json(stream, 201, success_response({
                user = user
            }))
        end
    end
}

print("HTTP API 服务器已启动")
```

## 数据库错误处理

### 连接失败处理

MySQL 连接池会自动管理连接，但仍需要处理查询时可能出现的连接错误。

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
    max_open_conns = 10,
    max_idle_conns = 5,
}

-- 安全查询函数
local function safe_query(sql, ...)
    local res, err = db:query(sql, ...)

    if res then
        return res
    end

    -- 记录错误信息
    print("查询失败:", err.message)
    print("错误码:", err.errno or "N/A")

    return nil, err
end

silly.fork(function()
    local res, err = safe_query("SELECT * FROM users")
    if not res then
        print("无法查询用户表")
        return
    end

    print("查询成功，记录数:", #res)
end)
```

### 死锁处理

检测并重试死锁事务。

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

-- 带死锁重试的事务函数
local function transaction_with_deadlock_retry(func, max_retries)
    max_retries = max_retries or 3

    for i = 1, max_retries do
        local tx<close>, err = db:begin()
        if not tx then
            return nil, "无法开始事务: " .. err.message
        end

        -- 执行事务操作
        local ok, result = silly.pcall(function()
            return func(tx)
        end)

        if not ok then
            tx:rollback()
            return nil, "事务执行失败: " .. result
        end

        -- 尝试提交
        local commit_ok, commit_err = tx:commit()
        if commit_ok then
            return result
        end

        -- 检查是否是死锁错误 (1213)
        if commit_err.errno == 1213 then
            print(string.format("检测到死锁 (尝试 %d/%d)，重试中...",
                i, max_retries))
            if i < max_retries then
                -- 短暂延迟后重试
                time.sleep(math.random(10, 100))
            end
        else
            -- 其他错误，不重试
            return nil, "提交失败: " .. commit_err.message
        end
    end

    return nil, "事务失败：达到最大重试次数"
end
```

### 事务回滚

正确处理事务中的错误。

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

-- 创建测试表
silly.fork(function()
    db:query([[
        CREATE TEMPORARY TABLE accounts (
            id INT PRIMARY KEY,
            balance DECIMAL(10, 2) NOT NULL CHECK (balance >= 0)
        )
    ]])
    db:query("INSERT INTO accounts VALUES (1, 1000), (2, 500)")
end)

-- 转账函数（带错误处理）
local function transfer(from_id, to_id, amount)
    -- 参数验证
    if amount <= 0 then
        return nil, "转账金额必须大于0"
    end

    -- 开始事务
    local tx<close>, err = db:begin()
    if not tx then
        return nil, "无法开始事务: " .. err.message
    end

    -- 检查源账户余额
    local res, err = tx:query("SELECT balance FROM accounts WHERE id = ?", from_id)
    if not res then
        tx:rollback()
        return nil, "查询失败: " .. err.message
    end

    if #res == 0 then
        tx:rollback()
        return nil, "源账户不存在"
    end

    local balance = tonumber(res[1].balance)
    if balance < amount then
        tx:rollback()
        return nil, string.format("余额不足 (当前: %.2f, 需要: %.2f)", balance, amount)
    end

    -- 检查目标账户是否存在
    res, err = tx:query("SELECT id FROM accounts WHERE id = ?", to_id)
    if not res then
        tx:rollback()
        return nil, "查询失败: " .. err.message
    end

    if #res == 0 then
        tx:rollback()
        return nil, "目标账户不存在"
    end

    -- 扣款
    res, err = tx:query(
        "UPDATE accounts SET balance = balance - ? WHERE id = ?",
        amount, from_id
    )
    if not res then
        tx:rollback()
        return nil, "扣款失败: " .. err.message
    end

    -- 到账
    res, err = tx:query(
        "UPDATE accounts SET balance = balance + ? WHERE id = ?",
        amount, to_id
    )
    if not res then
        tx:rollback()
        return nil, "到账失败: " .. err.message
    end

    -- 提交事务
    local ok, err = tx:commit()
    if not ok then
        return nil, "提交失败: " .. err.message
    end

    return true, "转账成功"
end

-- 测试
silly.fork(function()
    print("=== 测试转账功能 ===\n")

    -- 1. 成功转账
    print("1. 正常转账:")
    local ok, msg = transfer(1, 2, 100)
    print("  结果:", msg)

    -- 2. 余额不足
    print("\n2. 余额不足:")
    ok, msg = transfer(2, 1, 10000)
    print("  结果:", msg)

    -- 3. 账户不存在
    print("\n3. 账户不存在:")
    ok, msg = transfer(1, 999, 50)
    print("  结果:", msg)

    -- 4. 金额无效
    print("\n4. 金额无效:")
    ok, msg = transfer(1, 2, -50)
    print("  结果:", msg)

    -- 验证余额
    print("\n=== 最终余额 ===")
    local res = db:query("SELECT * FROM accounts ORDER BY id")
    for _, account in ipairs(res) do
        print(string.format("账户 %d: %.2f 元", account.id, account.balance))
    end

    db:close()
end)

## 完整示例：带完整错误处理的 API

以下是一个生产级的用户管理 API，展示了所有错误处理最佳实践。

```lua
local silly = require "silly"
local http = require "silly.net.http"
local mysql = require "silly.store.mysql"
local json = require "silly.encoding.json"

-- ============ 错误码定义 ============
local ErrorCode = {
    BAD_REQUEST = {code = "BAD_REQUEST", status = 400},
    NOT_FOUND = {code = "NOT_FOUND", status = 404},
    CONFLICT = {code = "CONFLICT", status = 409},
    VALIDATION_ERROR = {code = "VALIDATION_ERROR", status = 422},
    INTERNAL_ERROR = {code = "INTERNAL_ERROR", status = 500},
    DATABASE_ERROR = {code = "DATABASE_ERROR", status = 500},
}

-- ============ 响应辅助函数 ============
local function send_json(stream, status, data)
    local body = json.encode(data)
    stream:respond(status, {
        ["content-type"] = "application/json",
        ["content-length"] = #body,
    })
    stream:close(body)
end

local function success_response(data)
    return {success = true, data = data}
end

local function error_response(error_code, message, details)
    return {
        success = false,
        error = {
            code = error_code.code,
            message = message,
            details = details or {},
        }
    }
end

local function handle_error(stream, error_code, message, details)
    send_json(stream, error_code.status, error_response(error_code, message, details))
end

-- ============ 数据库连接 ============
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
    charset = "utf8mb4",
    max_open_conns = 10,
    max_idle_conns = 5,
}

-- ============ 用户验证 ============
local function validate_user(user)
    local errors = {}

    if not user.name or user.name == "" then
        table.insert(errors, {field = "name", message = "姓名不能为空"})
    elseif #user.name < 2 or #user.name > 50 then
        table.insert(errors, {field = "name", message = "姓名长度必须在2-50个字符之间"})
    end

    if not user.email or user.email == "" then
        table.insert(errors, {field = "email", message = "邮箱不能为空"})
    elseif not user.email:match("^[%w._%+-]+@[%w.-]+%.[%a]+$") then
        table.insert(errors, {field = "email", message = "邮箱格式不正确"})
    end

    if user.age then
        local age = tonumber(user.age)
        if not age or age < 1 or age > 150 then
            table.insert(errors, {field = "age", message = "年龄必须在1-150之间"})
        end
    end

    return #errors == 0, errors
end

-- ============ 数据库操作 ============
local User = {}

-- 创建用户
function User.create(name, email, age)
    local res, err = db:query(
        "INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
        name, email, age
    )

    if not res then
        -- 检查是否是重复邮箱
        if err.errno == 1062 and err.message:match("email") then
            return nil, "EMAIL_DUPLICATE", "该邮箱已被使用"
        end
        return nil, "DATABASE_ERROR", err.message
    end

    return res.last_insert_id
end

-- 获取用户
function User.get_by_id(id)
    local res, err = db:query("SELECT * FROM users WHERE id = ?", id)

    if not res then
        return nil, "DATABASE_ERROR", err.message
    end

    if #res == 0 then
        return nil, "NOT_FOUND", "用户不存在"
    end

    return res[1]
end

-- 更新用户
function User.update(id, name, email, age)
    local res, err = db:query(
        "UPDATE users SET name = ?, email = ?, age = ? WHERE id = ?",
        name, email, age, id
    )

    if not res then
        if err.errno == 1062 and err.message:match("email") then
            return nil, "EMAIL_DUPLICATE", "该邮箱已被其他用户使用"
        end
        return nil, "DATABASE_ERROR", err.message
    end

    if res.affected_rows == 0 then
        return nil, "NOT_FOUND", "用户不存在"
    end

    return true
end

-- 删除用户
function User.delete(id)
    local res, err = db:query("DELETE FROM users WHERE id = ?", id)

    if not res then
        return nil, "DATABASE_ERROR", err.message
    end

    if res.affected_rows == 0 then
        return nil, "NOT_FOUND", "用户不存在"
    end

    return true
end

-- ============ HTTP 请求处理 ============
local function handle_request(stream)
    local method = stream.method
    local path = stream.path

    -- 日志记录
    print(string.format("[%s] %s %s", os.date("%H:%M:%S"), method, path))

    -- 使用 pcall 保护处理函数
    local ok, err = silly.pcall(function()
        -- POST /api/users - 创建用户
        if method == "POST" and path == "/api/users" then
            local body, err = stream:readall()
            if not body then
                handle_error(stream, ErrorCode.BAD_REQUEST, "无法读取请求体")
                return
            end

            local user = json.decode(body)
            if not user then
                handle_error(stream, ErrorCode.BAD_REQUEST, "无效的 JSON 格式")
                return
            end

            -- 验证数据
            local valid, errors = validate_user(user)
            if not valid then
                handle_error(stream, ErrorCode.VALIDATION_ERROR, "数据验证失败", {
                    validation_errors = errors
                })
                return
            end

            -- 创建用户
            local user_id, err_code, err_msg = User.create(user.name, user.email, user.age)
            if not user_id then
                if err_code == "EMAIL_DUPLICATE" then
                    handle_error(stream, ErrorCode.CONFLICT, err_msg)
                else
                    handle_error(stream, ErrorCode.DATABASE_ERROR, err_msg)
                end
                return
            end

            -- 返回成功响应
            send_json(stream, 201, success_response({
                user = {
                    id = user_id,
                    name = user.name,
                    email = user.email,
                    age = user.age
                }
            }))
            return
        end

        -- GET /api/users/:id - 获取用户
        local user_id = path:match("^/api/users/(%d+)$")
        if method == "GET" and user_id then
            local user, err_code, err_msg = User.get_by_id(tonumber(user_id))
            if not user then
                if err_code == "NOT_FOUND" then
                    handle_error(stream, ErrorCode.NOT_FOUND, err_msg)
                else
                    handle_error(stream, ErrorCode.DATABASE_ERROR, err_msg)
                end
                return
            end

            send_json(stream, 200, success_response({user = user}))
            return
        end

        -- PUT /api/users/:id - 更新用户
        local update_id = path:match("^/api/users/(%d+)$")
        if method == "PUT" and update_id then
            local body = stream:readall()
            if not body then
                handle_error(stream, ErrorCode.BAD_REQUEST, "无法读取请求体")
                return
            end

            local user = json.decode(body)
            if not user then
                handle_error(stream, ErrorCode.BAD_REQUEST, "无效的 JSON 格式")
                return
            end

            local valid, errors = validate_user(user)
            if not valid then
                handle_error(stream, ErrorCode.VALIDATION_ERROR, "数据验证失败", {
                    validation_errors = errors
                })
                return
            end

            local ok, err_code, err_msg = User.update(
                tonumber(update_id), user.name, user.email, user.age
            )
            if not ok then
                if err_code == "NOT_FOUND" then
                    handle_error(stream, ErrorCode.NOT_FOUND, err_msg)
                elseif err_code == "EMAIL_DUPLICATE" then
                    handle_error(stream, ErrorCode.CONFLICT, err_msg)
                else
                    handle_error(stream, ErrorCode.DATABASE_ERROR, err_msg)
                end
                return
            end

            send_json(stream, 200, success_response({message = "用户更新成功"}))
            return
        end

        -- DELETE /api/users/:id - 删除用户
        local delete_id = path:match("^/api/users/(%d+)$")
        if method == "DELETE" and delete_id then
            local ok, err_code, err_msg = User.delete(tonumber(delete_id))
            if not ok then
                if err_code == "NOT_FOUND" then
                    handle_error(stream, ErrorCode.NOT_FOUND, err_msg)
                else
                    handle_error(stream, ErrorCode.DATABASE_ERROR, err_msg)
                end
                return
            end

            send_json(stream, 200, success_response({message = "用户删除成功"}))
            return
        end

        -- 404 - 路由不存在
        handle_error(stream, ErrorCode.NOT_FOUND, "请求的资源不存在", {
            path = path,
            method = method
        })
    end)

    -- 捕获未处理的异常
    if not ok then
        print("请求处理异常:", err)
        silly.error(err)
        send_json(stream, 500, error_response(
            ErrorCode.INTERNAL_ERROR,
            "服务器内部错误",
            {message = "请联系管理员"}
        ))
    end
end

-- ============ 启动服务器 ============
http.listen {
    addr = "127.0.0.1:8080",
    handler = handle_request
}

-- 测试数据库连接
local ok, err = db:ping()
if not ok then
    print("数据库连接失败:", err.message)
    silly.exit(1)
    return
end

-- 创建测试表
db:query([[
    CREATE TABLE IF NOT EXISTS users (
        id INT PRIMARY KEY AUTO_INCREMENT,
        name VARCHAR(50) NOT NULL,
        email VARCHAR(100) UNIQUE NOT NULL,
        age INT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    )
]])

print("===========================================")
print("  用户管理 API 服务器已启动")
print("===========================================")
print("  HTTP: http://127.0.0.1:8080")
print("  数据库: 已连接")
print("===========================================")
```

## 测试完整示例

保存上述代码为 `user_api.lua`，然后测试：

```bash
# 启动服务器
./silly user_api.lua

# 创建用户（成功）
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice","email":"alice@example.com","age":30}'

# 创建用户（验证失败）
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"A","email":"invalid-email","age":200}'

# 创建用户（邮箱重复）
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Bob","email":"alice@example.com","age":25}'

# 获取用户（成功）
curl http://127.0.0.1:8080/api/users/1

# 获取用户（不存在）
curl http://127.0.0.1:8080/api/users/9999

# 更新用户（成功）
curl -X PUT http://127.0.0.1:8080/api/users/1 \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice Wang","email":"alice.wang@example.com","age":31}'

# 删除用户（成功）
curl -X DELETE http://127.0.0.1:8080/api/users/1
```

## 最佳实践总结

### 1. 始终检查返回值

```lua
-- 推荐
local res, err = db:query("SELECT * FROM users")
if not res then
    print("错误:", err.message)
    return
end

-- 不推荐
local res = db:query("SELECT * FROM users")  -- 忽略错误
```

### 2. 使用 pcall 保护关键代码

```lua
local ok, err = silly.pcall(function()
    -- 可能出错的代码
    return risky_operation()
end)

if not ok then
    print("错误:", err)
    silly.error(err)  -- 记录堆栈跟踪
end
```

### 3. 提供有意义的错误消息

```lua
-- 推荐：包含上下文信息
return nil, string.format("用户 %d 余额不足 (当前: %.2f, 需要: %.2f)",
    user_id, balance, amount)

-- 不推荐：模糊的错误
return nil, "操作失败"
```

### 4. 统一错误格式

```lua
-- 定义标准错误响应格式
local function error_response(code, message, details)
    return {
        success = false,
        error = {
            code = code,
            message = message,
            details = details or {},
            timestamp = os.time(),
        }
    }
end
```

### 5. 记录错误日志

```lua
local logger = require "silly.logger"

if not res then
    logger.error("数据库查询失败", {
        query = sql,
        error = err.message,
        errno = err.errno,
        trace_id = silly.tracenew(),
    })
end
```

### 6. 优雅降级

```lua
-- 主功能失败时提供备选方案
local data, err = get_from_cache(key)
if not data then
    print("缓存未命中，从数据库加载:", err)
    data, err = get_from_database(key)
    if data then
        set_cache(key, data)  -- 回填缓存
    end
end
```

### 7. 超时保护

```lua
local time = require "silly.time"

local timer = time.after(5000, function()
    print("操作超时")
    -- 清理资源
end)

local result = long_running_operation()

time.cancel(timer)
```

### 8. 事务错误处理

```lua
local tx<close>, err = db:begin()
if not tx then
    return nil, "无法开始事务"
end

local ok, err = silly.pcall(function()
    -- 事务操作
    tx:query("...")
    tx:query("...")
end)

if ok then
    tx:commit()
else
    tx:rollback()
    return nil, err
end
```

## 参考资料

- [silly API 参考](../reference/silly.md) - 核心错误处理函数
- [silly.net.http API 参考](../reference/net/http.md) - HTTP 错误处理
- [silly.store.mysql API 参考](../reference/store/mysql.md) - 数据库错误处理
- [silly.store.redis API 参考](../reference/store/redis.md) - Redis 错误处理
- [Lua 错误处理](https://www.lua.org/pil/8.4.html) - Lua 官方文档
