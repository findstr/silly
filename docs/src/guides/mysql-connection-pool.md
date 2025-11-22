---
title: MySQL 连接池管理操作指南
icon: database
order: 2
category:
  - 操作指南
tag:
  - MySQL
  - 连接池
  - 性能
  - 监控
---

# MySQL 连接池管理操作指南

本指南专注于解决 MySQL 连接池使用中的常见问题，提供配置优化、问题诊断和性能调优的实用方案。

## 为什么需要连接池？

### 连接池的价值

**1. 减少连接开销**

建立一个 MySQL 连接需要：
- TCP 三次握手（网络往返）
- MySQL 身份验证（用户名/密码验证）
- 字符集协商
- 初始化会话状态

通常需要 50-200ms，而连接池复用连接仅需 1-5ms。

**2. 控制资源使用**

MySQL 服务器的连接数有限制（默认 151）：
```sql
SHOW VARIABLES LIKE 'max_connections';
-- +-------------------+-------+
-- | Variable_name     | Value |
-- +-------------------+-------+
-- | max_connections   | 151   |
-- +-------------------+-------+
```

连接池确保不超过服务器限制。

**3. 提升并发能力**

```lua
-- 无连接池：每次请求都建立新连接（慢）
function handle_request()
    local db = mysql.open{...}  -- 100ms 连接开销
    local result = db:query("SELECT * FROM users")  -- 10ms 查询
    db:close()
    return result
end

-- 有连接池：复用连接（快）
local pool = mysql.open{...}  -- 只建立一次

function handle_request()
    local result = pool:query("SELECT * FROM users")  -- 10ms 查询
    return result
end
```

## 连接池配置

### 基础配置参数

```lua
local mysql = require "silly.store.mysql"

local pool = mysql.open {
    -- 连接信息
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    charset = "utf8mb4",

    -- 连接池参数
    max_open_conns = 20,    -- 最大打开连接数（0 = 无限制）
    max_idle_conns = 5,     -- 最大空闲连接数（0 = 无限制）
    max_idle_time = 600,    -- 空闲连接超时时间（秒，0 = 不超时）
    max_lifetime = 3600,    -- 连接最大生命周期（秒，0 = 不限制）
    max_packet_size = 1024 * 1024,  -- 最大数据包大小（字节）
}
```

### 参数详解

#### max_open_conns（最大连接数）

控制与数据库的最大并发连接数。

```lua
-- 设置为 20：同时最多 20 个查询
max_open_conns = 20

-- 第 21 个请求会等待，直到有连接释放
```

**如何选择**：
```
max_open_conns = 并发查询数 × 1.2
```

示例：
- 100 QPS，每个查询 50ms → 并发 = 100 × 0.05 = 5 → 设置 **10**
- 1000 QPS，每个查询 100ms → 并发 = 1000 × 0.1 = 100 → 设置 **120**

#### max_idle_conns（最大空闲连接）

控制连接池中保持的空闲连接数量。

```lua
-- 设置为 5：连接池保持 5 个空闲连接
max_idle_conns = 5

-- 超过 5 个的空闲连接会被关闭
```

**如何选择**：
```
max_idle_conns = max_open_conns × 0.3
```

建议：
- **低负载**：`max_idle_conns = 2-5`（节省资源）
- **高负载**：`max_idle_conns = max_open_conns × 0.5`（快速响应）

#### max_idle_time（空闲超时）

空闲连接在池中保持的最长时间。

```lua
-- 设置为 600 秒（10 分钟）
max_idle_time = 600

-- 空闲超过 10 分钟的连接会被关闭
```

**如何选择**：
- **频繁访问**：600-1800 秒（10-30 分钟）
- **偶尔访问**：60-300 秒（1-5 分钟）
- **需要检测断线**：300 秒（MySQL `wait_timeout` 通常 28800 秒）

#### max_lifetime（连接生命周期）

连接的最大存活时间（无论是否空闲）。

```lua
-- 设置为 3600 秒（1 小时）
max_lifetime = 3600

-- 连接使用超过 1 小时后会被关闭并重建
```

**如何选择**：
- **防止连接泄漏**：3600 秒（1 小时）
- **频繁重建**：1800 秒（30 分钟）
- **长期稳定**：7200 秒（2 小时）

**注意**：应小于 MySQL 的 `wait_timeout`。

### 不同负载下的推荐配置

#### 低负载应用（内部工具、管理后台）

```lua
local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    charset = "utf8mb4",

    max_open_conns = 5,       -- 最多 5 个并发查询
    max_idle_conns = 2,       -- 保持 2 个空闲连接
    max_idle_time = 300,      -- 5 分钟空闲超时
    max_lifetime = 1800,      -- 30 分钟最大生命周期
}
```

**适用场景**：
- 并发请求 < 10
- QPS < 100
- 查询响应时间 < 100ms

#### 中等负载应用（小型 Web 服务）

```lua
local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    charset = "utf8mb4",

    max_open_conns = 20,      -- 最多 20 个并发查询
    max_idle_conns = 5,       -- 保持 5 个空闲连接
    max_idle_time = 600,      -- 10 分钟空闲超时
    max_lifetime = 3600,      -- 1 小时最大生命周期
}
```

**适用场景**：
- 并发请求 10-50
- QPS 100-1000
- 查询响应时间 < 500ms

#### 高负载应用（大型 API 服务）

```lua
local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    charset = "utf8mb4",

    max_open_conns = 100,     -- 最多 100 个并发查询
    max_idle_conns = 30,      -- 保持 30 个空闲连接
    max_idle_time = 300,      -- 5 分钟空闲超时（快速释放）
    max_lifetime = 3600,      -- 1 小时最大生命周期
}
```

**适用场景**：
- 并发请求 > 50
- QPS > 1000
- 需要快速响应

**注意**：确保 MySQL `max_connections` > 100。

### 配置优化

#### 根据 MySQL 限制调整

```lua
-- 查询 MySQL 的最大连接数
-- mysql> SHOW VARIABLES LIKE 'max_connections';
-- 假设返回 151

local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",

    -- 留 20% 余量给其他客户端
    max_open_conns = math.floor(151 * 0.8),  -- 120
    max_idle_conns = 30,
}
```

#### 避免连接浪费

```lua
-- 不推荐：空闲连接过多
local pool = mysql.open {
    max_open_conns = 100,
    max_idle_conns = 100,  -- ❌ 浪费资源
    max_idle_time = 0,     -- ❌ 永不超时
}

-- 推荐：合理配置
local pool = mysql.open {
    max_open_conns = 100,
    max_idle_conns = 20,   -- ✅ 保持合理数量
    max_idle_time = 300,   -- ✅ 5 分钟超时
}
```

#### 动态调整

根据监控数据动态调整：

```lua
local config = {
    low_traffic = {
        max_open_conns = 10,
        max_idle_conns = 3,
    },
    high_traffic = {
        max_open_conns = 50,
        max_idle_conns = 15,
    },
}

-- 根据时间或负载切换配置
local current_config = is_peak_hour() and config.high_traffic or config.low_traffic

local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    max_open_conns = current_config.max_open_conns,
    max_idle_conns = current_config.max_idle_conns,
}
```

## 常见问题

### 问题 1：Too many connections

#### 错误信息

```
MySQL error: Too many connections (errno: 1040)
```

#### 原因分析

1. **应用连接数超过 MySQL 限制**
   ```sql
   SHOW VARIABLES LIKE 'max_connections';
   -- 默认 151
   ```

2. **连接泄漏**：连接未正确关闭

3. **配置不当**：`max_open_conns` 设置过大

#### 解决方案

**方案 1：增加 MySQL 最大连接数**

```bash
# 编辑 MySQL 配置文件
sudo vim /etc/mysql/my.cnf

# 添加或修改
[mysqld]
max_connections = 500

# 重启 MySQL
sudo systemctl restart mysql
```

或动态修改（重启后失效）：
```sql
SET GLOBAL max_connections = 500;
```

**方案 2：检查连接泄漏**

```lua
local silly = require "silly"
local task = require "silly.task"
local mysql = require "silly.store.mysql"

local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    max_open_conns = 10,
}

task.fork(function()
    -- ❌ 错误示例：事务连接未关闭
    local tx = pool:begin()
    tx:query("SELECT 1")
    -- 忘记调用 tx:close() 或 tx:commit()
    -- 连接泄漏！
end)

task.fork(function()
    -- ✅ 正确示例：使用 <close> 自动管理
    local tx<close> = pool:begin()
    tx:query("SELECT 1")
    tx:commit()
    -- tx 自动关闭，连接归还到池
end)
```

**方案 3：降低 max_open_conns**

```lua
-- 假设有 5 个应用实例
-- MySQL max_connections = 151
-- 每个实例最多：151 / 5 = 30

local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    max_open_conns = 30,  -- 不超过分配数量
}
```

### 问题 2：连接泄漏检测

#### 症状

- 应用运行一段时间后性能下降
- MySQL 连接数持续增长
- 出现 "Too many connections" 错误

#### 检测方法

**方法 1：监控活跃连接**

```lua
local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local mysql = require "silly.store.mysql"

local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

-- 定期检查连接数
task.fork(function()
    while true do
        local res = pool:query("SHOW PROCESSLIST")
        local conn_count = #res
        print(string.format("[%s] 活跃连接数: %d",
            os.date("%Y-%m-%d %H:%M:%S"), conn_count))

        -- 警告阈值
        if conn_count > 100 then
            print("⚠️ 警告：连接数过高，可能存在连接泄漏！")
        end

        time.sleep(10000)  -- 每 10 秒检查一次
    end
end)
```

**方法 2：追踪事务连接**

```lua
local transaction_counter = 0

-- 包装 pool:begin()
local original_begin = pool.begin

function pool:begin()
    local tx, err = original_begin(self)
    if not tx then
        return nil, err
    end

    transaction_counter = transaction_counter + 1
    local tx_id = transaction_counter
    print(string.format("事务 #%d 开始", tx_id))

    -- 包装 tx:close()
    local original_close = tx.close
    function tx:close()
        print(string.format("事务 #%d 结束", tx_id))
        return original_close(self)
    end

    return tx, err
end
```

#### 预防措施

**1. 始终使用 `<close>` 标记**

```lua
-- ✅ 推荐
task.fork(function()
    local tx<close> = pool:begin()
    -- 无论是否出错，tx 都会自动关闭
    tx:query("UPDATE users SET age = 30 WHERE id = 1")
    tx:commit()
end)
```

**2. 使用 pcall 保护**

```lua
task.fork(function()
    local tx<close> = pool:begin()

    local ok, err = pcall(function()
        tx:query("UPDATE users SET age = 30 WHERE id = 1")
        tx:query("UPDATE accounts SET balance = 100 WHERE user_id = 1")
        tx:commit()
    end)

    if not ok then
        print("事务失败:", err)
        tx:rollback()
    end
end)
```

**3. 设置超时**

```lua
local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    max_lifetime = 600,  -- 连接最多使用 10 分钟
    max_idle_time = 300, -- 空闲 5 分钟后关闭
}
```

### 问题 3：连接超时

#### 错误信息

```
MySQL error: Lost connection to MySQL server during query
```

#### 原因分析

1. **网络不稳定**：连接被中断
2. **查询时间过长**：超过 MySQL 超时设置
3. **连接空闲太久**：超过 `wait_timeout`

#### 解决方案

**方案 1：增加 MySQL 超时时间**

```sql
-- 查看当前超时设置
SHOW VARIABLES LIKE '%timeout%';

-- 增加超时时间（8 小时）
SET GLOBAL wait_timeout = 28800;
SET GLOBAL interactive_timeout = 28800;
```

**方案 2：使用 ping 检测连接**

```lua
local silly = require "silly"
local task = require "silly.task"
local mysql = require "silly.store.mysql"

local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
}

-- 查询前先 ping
task.fork(function()
    local ok, err = pool:ping()
    if not ok then
        print("连接已断开:", err.message)
        -- 重建连接池
        pool:close()
        pool = mysql.open {...}
    end

    -- 执行查询
    local res = pool:query("SELECT * FROM users")
end)
```

**方案 3：设置合理的连接生命周期**

```lua
local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",

    -- 小于 MySQL wait_timeout（默认 28800 秒）
    max_lifetime = 3600,   -- 1 小时
    max_idle_time = 600,   -- 10 分钟
}
```

### 问题 4：重连机制

#### 实现自动重连

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local DBPool = {}
DBPool.__index = DBPool

function DBPool.new(config)
    local self = setmetatable({}, DBPool)
    self.config = config
    self.pool = mysql.open(config)
    self.reconnect_attempts = 0
    self.max_reconnect_attempts = 5
    return self
end

function DBPool:query(sql, ...)
    local max_retries = 3
    local retry_delay = 1000  -- 1 秒

    for attempt = 1, max_retries do
        local res, err = self.pool:query(sql, ...)

        if res then
            -- 成功，重置重连计数
            self.reconnect_attempts = 0
            return res, nil
        end

        -- 检查是否是连接错误
        if err and (err.message:match("Lost connection") or
                   err.message:match("MySQL server has gone away")) then
            print(string.format("连接断开，尝试重连 (%d/%d)...",
                attempt, max_retries))

            -- 尝试重建连接
            local ok = self:reconnect()
            if ok then
                -- 重试查询
                time.sleep(retry_delay)
            else
                break
            end
        else
            -- 其他错误，直接返回
            return nil, err
        end
    end

    return nil, {message = "查询失败，已达到最大重试次数"}
end

function DBPool:reconnect()
    self.reconnect_attempts = self.reconnect_attempts + 1

    if self.reconnect_attempts > self.max_reconnect_attempts then
        print("❌ 超过最大重连次数，放弃重连")
        return false
    end

    -- 关闭旧连接池
    pcall(function()
        self.pool:close()
    end)

    -- 创建新连接池
    local ok, err = pcall(function()
        self.pool = mysql.open(self.config)
        local res, err = self.pool:ping()
        if not res then
            error(err.message)
        end
    end)

    if ok then
        print("✅ 重连成功")
        return true
    else
        print("❌ 重连失败:", err)
        return false
    end
end

function DBPool:close()
    self.pool:close()
end

local db = DBPool.new {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

task.fork(function()
    -- 自动处理重连
    local res, err = db:query("SELECT * FROM users")
    if res then
        print("查询成功:", #res)
    else
        print("查询失败:", err.message)
    end

    db:close()
end)
```

## 最佳实践

### 1. 连接生命周期管理

#### 应用启动时创建连接池

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

-- 全局连接池（应用启动时创建）
local DB = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    max_open_conns = 20,
    max_idle_conns = 5,
}

-- 导出接口
return {
    query = function(sql, ...)
        return DB:query(sql, ...)
    end,

    begin = function()
        return DB:begin()
    end,

    close = function()
        DB:close()
    end,
}
```

#### 应用关闭时优雅关闭

```lua
local silly = require "silly"
local signal = require "silly.signal"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

-- 监听退出信号
signal.signal("INT", function()
    print("收到退出信号，正在关闭...")

    -- 关闭连接池
    pool:close()
    print("连接池已关闭")

    -- 退出应用
    os.exit(0)
end)

print("应用已启动，按 Ctrl+C 退出")
```

### 2. 事务处理

#### 使用 `<close>` 自动管理

```lua
local silly = require "silly"
local task = require "silly.task"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

task.fork(function()
    -- 使用 <close> 确保事务连接被关闭
    local tx<close> = pool:begin()

    -- 执行操作
    tx:query("UPDATE accounts SET balance = balance - 100 WHERE id = 1")
    tx:query("UPDATE accounts SET balance = balance + 100 WHERE id = 2")

    -- 提交事务
    local ok, err = tx:commit()
    if not ok then
        print("提交失败:", err.message)
        tx:rollback()
    end

    -- tx 自动关闭
end)
```

#### 事务错误处理

```lua
local function transfer(from_id, to_id, amount)
    local tx<close>, err = pool:begin()
    if not tx then
        return nil, "无法开始事务: " .. err.message
    end

    -- 使用 pcall 捕获所有错误
    local ok, err = pcall(function()
        -- 扣款
        local res, err = tx:query(
            "UPDATE accounts SET balance = balance - ? WHERE id = ?",
            amount, from_id
        )
        if not res then
            error(err.message)
        end

        -- 到账
        res, err = tx:query(
            "UPDATE accounts SET balance = balance + ? WHERE id = ?",
            amount, to_id
        )
        if not res then
            error(err.message)
        end

        -- 提交
        res, err = tx:commit()
        if not res then
            error(err.message)
        end
    end)

    if not ok then
        tx:rollback()
        return nil, err
    end

    return true
end
```

### 3. 避免长事务

长事务会占用连接，导致其他请求等待。

#### 问题示例

```lua
-- ❌ 错误：长事务
task.fork(function()
    local tx<close> = pool:begin()

    -- 大量查询（占用连接很久）
    for i = 1, 10000 do
        tx:query("INSERT INTO logs VALUES (?, ?)", i, "log message")
    end

    tx:commit()
end)
```

#### 改进方案

**方案 1：分批处理**

```lua
-- ✅ 正确：分批处理
task.fork(function()
    local batch_size = 100

    for batch = 1, 100 do
        local tx<close> = pool:begin()

        -- 每批处理 100 条
        for i = 1, batch_size do
            local id = (batch - 1) * batch_size + i
            tx:query("INSERT INTO logs VALUES (?, ?)", id, "log message")
        end

        tx:commit()
        -- 释放连接，让其他请求使用
    end
end)
```

**方案 2：批量插入**

```lua
-- ✅ 正确：批量插入
task.fork(function()
    local values = {}
    for i = 1, 10000 do
        table.insert(values, string.format("(%d, 'log message')", i))
    end

    -- 单条 SQL 插入所有数据
    pool:query("INSERT INTO logs VALUES " .. table.concat(values, ","))
end)
```

### 4. 预热连接池

应用启动时预先建立连接，避免第一次请求慢。

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    max_open_conns = 20,
    max_idle_conns = 5,
}

-- 预热连接池
local function warmup_pool(count)
    print("正在预热连接池...")

    local tasks = {}
    for i = 1, count do
        table.insert(tasks, task.fork(function()
            local ok, err = pool:ping()
            if ok then
                print(string.format("连接 #%d 就绪", i))
            else
                print(string.format("连接 #%d 失败: %s", i, err.message))
            end
        end))
    end

    -- 等待所有连接建立
    for _, task in ipairs(tasks) do
        silly.wait(task)
    end

    print(string.format("连接池预热完成，已建立 %d 个连接", count))
end

-- 预热 5 个连接
warmup_pool(5)

print("应用已启动")
```

## 监控指标

### 1. 活跃连接数

实时监控 MySQL 活跃连接。

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

-- 监控活跃连接
task.fork(function()
    while true do
        local res = pool:query([[
            SELECT COUNT(*) as count
            FROM information_schema.PROCESSLIST
            WHERE User = 'app_user'
        ]])

        if res then
            local active_conns = res[1].count
            print(string.format("[%s] 活跃连接: %d",
                os.date("%H:%M:%S"), active_conns))

            -- 告警
            if active_conns > 50 then
                print("⚠️ 警告：活跃连接过多")
            end
        end

        silly.sleep(5000)  -- 每 5 秒检查
    end
end)
```

### 2. 查询等待时间

监控查询等待连接的时间。

```lua
local function timed_query(pool, sql, ...)
    local wait_start = silly.time.now()

    -- 执行查询（可能需要等待连接）
    local query_start = silly.time.now()
    local res, err = pool:query(sql, ...)
    local query_end = silly.time.now()

    local wait_time = query_start - wait_start
    local query_time = query_end - query_start

    -- 记录慢等待
    if wait_time > 100 then
        print(string.format("⚠️ 慢等待: 等待连接 %.2fms", wait_time))
    end

    -- 记录慢查询
    if query_time > 1000 then
        print(string.format("⚠️ 慢查询: %.2fms - %s", query_time, sql))
    end

    return res, err
end

-- 使用
task.fork(function()
    local res, err = timed_query(pool, "SELECT * FROM users WHERE id = ?", 1)
end)
```

### 3. 错误率

监控数据库操作的错误率。

```lua
local stats = {
    total = 0,
    success = 0,
    error = 0,
}

local function tracked_query(pool, sql, ...)
    stats.total = stats.total + 1

    local res, err = pool:query(sql, ...)

    if res then
        stats.success = stats.success + 1
    else
        stats.error = stats.error + 1
        print("查询错误:", err.message)
    end

    return res, err
end

-- 定期输出统计
task.fork(function()
    while true do
        silly.sleep(60000)  -- 每分钟

        if stats.total > 0 then
            local error_rate = (stats.error / stats.total) * 100
            print(string.format(
                "统计: 总计=%d, 成功=%d, 失败=%d, 错误率=%.2f%%",
                stats.total, stats.success, stats.error, error_rate
            ))

            if error_rate > 5 then
                print("⚠️ 警告：错误率过高")
            end

            -- 重置统计
            stats.total = 0
            stats.success = 0
            stats.error = 0
        end
    end
end)
```

### 4. 完整监控面板

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

local metrics = {
    queries = {total = 0, success = 0, error = 0},
    wait_times = {},
    query_times = {},
}

-- 包装查询函数
local function monitored_query(sql, ...)
    local wait_start = silly.time.now()
    local query_start = silly.time.now()
    local res, err = pool:query(sql, ...)
    local query_end = silly.time.now()

    -- 记录指标
    metrics.queries.total = metrics.queries.total + 1
    if res then
        metrics.queries.success = metrics.queries.success + 1
    else
        metrics.queries.error = metrics.queries.error + 1
    end

    table.insert(metrics.wait_times, query_start - wait_start)
    table.insert(metrics.query_times, query_end - query_start)

    -- 保持最近 100 条记录
    if #metrics.wait_times > 100 then
        table.remove(metrics.wait_times, 1)
    end
    if #metrics.query_times > 100 then
        table.remove(metrics.query_times, 1)
    end

    return res, err
end

-- 计算平均值
local function average(tbl)
    if #tbl == 0 then return 0 end
    local sum = 0
    for _, v in ipairs(tbl) do
        sum = sum + v
    end
    return sum / #tbl
end

-- 定期输出监控报告
task.fork(function()
    while true do
        silly.sleep(60000)  -- 每分钟

        print("\n========== 数据库监控报告 ==========")
        print(string.format("时间: %s", os.date("%Y-%m-%d %H:%M:%S")))
        print(string.format("查询总数: %d", metrics.queries.total))
        print(string.format("成功: %d (%.1f%%)",
            metrics.queries.success,
            metrics.queries.total > 0 and (metrics.queries.success / metrics.queries.total * 100) or 0
        ))
        print(string.format("失败: %d (%.1f%%)",
            metrics.queries.error,
            metrics.queries.total > 0 and (metrics.queries.error / metrics.queries.total * 100) or 0
        ))
        print(string.format("平均等待时间: %.2fms", average(metrics.wait_times)))
        print(string.format("平均查询时间: %.2fms", average(metrics.query_times)))
        print("====================================\n")

        -- 重置计数
        metrics.queries = {total = 0, success = 0, error = 0}
    end
end)

-- 导出接口
return {
    query = monitored_query,
}
```

## 性能调优

### 1. 连接数计算公式

根据应用特性计算最佳连接数。

#### 公式

```
max_open_conns = (QPS × 平均查询时间) ÷ 1000 × 安全系数

其中：
- QPS: 每秒查询数
- 平均查询时间: 单位毫秒
- 安全系数: 1.2-1.5（预留余量）
```

#### 示例计算

**场景 1：简单查询**
- QPS: 1000
- 平均查询时间: 10ms
- 安全系数: 1.2

```
max_open_conns = (1000 × 10) ÷ 1000 × 1.2 = 12
```

**场景 2：复杂查询**
- QPS: 500
- 平均查询时间: 100ms
- 安全系数: 1.5

```
max_open_conns = (500 × 100) ÷ 1000 × 1.5 = 75
```

#### 实际测量

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

-- 测试查询性能
local function benchmark()
    local total_queries = 1000
    local start = silly.time.now()

    for i = 1, total_queries do
        pool:query("SELECT * FROM users WHERE id = ?", i % 100)
    end

    local elapsed = silly.time.now() - start
    local qps = total_queries / (elapsed / 1000)
    local avg_time = elapsed / total_queries

    print(string.format("QPS: %.0f", qps))
    print(string.format("平均查询时间: %.2fms", avg_time))

    -- 计算推荐连接数
    local recommended = math.ceil((qps * avg_time) / 1000 * 1.2)
    print(string.format("推荐 max_open_conns: %d", recommended))
end

benchmark()
```

### 2. 批量操作优化

#### 批量插入

```lua
-- ❌ 慢：逐条插入
for i = 1, 1000 do
    pool:query("INSERT INTO logs VALUES (?, ?)", i, "message")
end

-- ✅ 快：批量插入
local values = {}
for i = 1, 1000 do
    table.insert(values, string.format("(%d, 'message')", i))
end
pool:query("INSERT INTO logs VALUES " .. table.concat(values, ","))
```

#### 批量查询（IN 子句）

```lua
-- ❌ 慢：逐条查询
local users = {}
for _, id in ipairs(user_ids) do
    local res = pool:query("SELECT * FROM users WHERE id = ?", id)
    if res and #res > 0 then
        table.insert(users, res[1])
    end
end

-- ✅ 快：批量查询
local ids = table.concat(user_ids, ",")
local users = pool:query("SELECT * FROM users WHERE id IN (" .. ids .. ")")
```

### 3. 预处理语句缓存

Silly 自动缓存预处理语句，相同 SQL 会复用。

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

task.fork(function()
    -- 第一次执行：准备语句
    pool:query("SELECT * FROM users WHERE id = ?", 1)

    -- 后续执行：复用预处理语句（更快）
    for i = 2, 1000 do
        pool:query("SELECT * FROM users WHERE id = ?", i)
    end
end)
```

**优化建议**：
- 使用参数化查询（`?` 占位符）
- 避免动态拼接 SQL
- 相同结构的查询使用相同 SQL

```lua
-- ❌ 不推荐：无法复用预处理语句
pool:query("SELECT * FROM users WHERE id = " .. id)

-- ✅ 推荐：复用预处理语句
pool:query("SELECT * FROM users WHERE id = ?", id)
```

### 4. 索引优化

确保查询使用索引。

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

-- 使用 EXPLAIN 分析查询
task.fork(function()
    local sql = "SELECT * FROM users WHERE email = ?"
    local res = pool:query("EXPLAIN " .. sql, "user@example.com")

    print("查询分析:")
    for _, row in ipairs(res) do
        print(string.format("  type: %s, key: %s, rows: %d",
            row.type, row.key or "NULL", row.rows))
    end

    -- 检查是否使用索引
    if res[1].key == nil then
        print("⚠️ 警告：查询未使用索引，考虑添加索引")
        print("  建议: CREATE INDEX idx_email ON users(email);")
    end
end)
```

## 参考资料

- [silly.store.mysql API 参考](/reference/store/mysql.md)
- [数据库应用教程](/tutorials/database-app.md)
- [MySQL 连接池最佳实践](https://dev.mysql.com/doc/connector-j/8.0/en/connector-j-usagenotes-j2ee-concepts-connection-pooling.html)
- [Go database/sql 包设计理念](https://go.dev/doc/database/manage-connections)
