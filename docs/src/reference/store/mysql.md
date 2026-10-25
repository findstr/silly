---
title: silly.store.mysql
icon: database
category:
  - API参考
tag:
  - 数据库
  - MySQL
  - 存储
---

# silly.store.mysql

`silly.store.mysql` 模块提供了一个高性能的异步 MySQL/MariaDB 客户端，基于连接池实现。它使用预处理语句提升性能和安全性,支持事务操作,并完全兼容 MySQL 5.x/8.x 和 MariaDB。

## 模块导入

```lua validate
local mysql = require "silly.store.mysql"
```

## 核心概念

### 连接池

连接池管理数据库连接的生命周期，提供以下特性：

- **自动连接管理**: 按需创建连接，空闲时回收
- **连接复用**: 减少连接建立开销
- **并发控制**: 限制最大并发连接数
- **健康检查**: 自动清理过期和空闲连接
- **等待队列**: 连接池满时自动排队等待

### 预处理语句

所有查询自动使用预处理语句（Prepared Statements）：

- **性能优化**: 语句缓存，减少解析开销
- **SQL 注入防护**: 参数自动转义
- **类型安全**: 自动处理数据类型转换
- **透明使用**: 使用 `?` 占位符即可

### 事务支持

支持完整的 ACID 事务：

- **BEGIN**: 开始事务
- **COMMIT**: 提交事务
- **ROLLBACK**: 回滚事务
- **自动回滚**: 未显式提交的事务自动回滚

---

## 连接池 API

### mysql.open(opts)

创建一个新的 MySQL 连接池。

- **参数**:
  - `opts`: `table` - 连接池配置表
    - `addr`: `string` - 数据库地址，格式 `"host:port"`（默认 `"127.0.0.1:3306"`）
    - `connect_timeout`: `integer|nil` (可选) - TCP 建连超时（毫秒）；不设置时不指定建连期限
    - `user`: `string` - 用户名
    - `password`: `string` - 密码
    - `database`: `string|nil` (可选) - 数据库名（默认空）
    - `charset`: `string|nil` (可选) - 字符集（默认 `"_default"`，推荐 `"utf8mb4"`）
    - `max_open_conns`: `integer|nil` (可选) - 最大打开连接数，0 表示无限制（默认 0）
    - `max_idle_conns`: `integer|nil` (可选) - 最大空闲连接数（默认 0）
    - `max_idle_time`: `integer|nil` (可选) - 连接最大空闲时间（秒），0 表示不限制（默认 0）
    - `max_lifetime`: `integer|nil` (可选) - 连接最大生命周期（秒），0 表示不限制（默认 0）
    - `max_packet_size`: `integer|nil` (可选) - 最大数据包大小（字节），默认 1MB
    - `max_stmts`: `integer|nil` (可选) - 每个连接缓存的预处理语句上限（默认 128）；0 表示禁用缓存。达到上限后释放最早缓存的语句。
- **返回值**:
  - 成功: `pool` - MySQL 连接池对象
  - 失败: 从不失败（连接在首次查询时建立）
- **示例**:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local pool = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
        charset = "utf8mb4",
        max_open_conns = 10,
        max_idle_conns = 5,
        max_idle_time = 60,
        max_lifetime = 3600,
    }

    local ok, err = pool:ping()
    if ok then
        print("Database connection successful")
    else
        print("Database connection failed:", err.message)
    end

    pool:close()
end)
```

### pool:close()

关闭连接池，释放所有连接。

- **参数**: 无
- **返回值**: 无
- **注意**: 关闭后连接池不可再使用，所有等待连接的协程将被唤醒并收到错误
- **示例**:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local pool = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
    }

    -- 使用连接池...
    pool:query("SELECT 1")

    -- 关闭连接池
    pool:close()
    print("Connection pool closed")
end)
```

### pool:ping()

检查与数据库的连接是否有效（异步）。

- **参数**: 无
- **返回值**:
  - 成功: `ok_packet, nil` - OK 响应包和 nil
  - 失败: `nil, err_packet` - nil 和错误包
- **异步**: 会挂起协程直到收到响应
- **示例**:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local pool = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
    }

    local ok, err = pool:ping()
    if ok then
        print("Database is alive")
        print("Server status:", ok.server_status)
    else
        print("Ping failed:", err.message)
    end

    pool:close()
end)
```

### pool:query(sql, ...)

执行 SQL 查询（异步）。

- **参数**:
  - `sql`: `string` - SQL 语句，使用 `?` 作为参数占位符
  - `...`: 可变参数 - SQL 参数值（支持 nil, boolean, number, string）
- **返回值**:
  - SELECT 查询: `row[], nil` - 结果行数组和 nil
  - INSERT/UPDATE/DELETE: `ok_packet, nil` - OK 响应包和 nil
  - 失败: `nil, err_packet` - nil 和错误包
- **异步**: 会挂起协程直到查询完成
- **注意**:
  - 自动使用预处理语句
  - 参数类型自动转换
  - nil 参数表示 SQL NULL
  - 存储过程的多个结果集会被完整读取，各结果集的行按顺序合并到返回数组
- **示例**:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local pool = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    -- CREATE TABLE
    local res, err = pool:query([[
        CREATE TEMPORARY TABLE users (
            id INT PRIMARY KEY AUTO_INCREMENT,
            name VARCHAR(50),
            age INT
        )
    ]])
    assert(res, err and err.message)

    -- INSERT
    res, err = pool:query("INSERT INTO users (name, age) VALUES (?, ?)", "Alice", 30)
    assert(res, err and err.message)
    print("Inserted rows:", res.affected_rows)
    print("Last insert ID:", res.last_insert_id)

    -- SELECT
    res, err = pool:query("SELECT * FROM users WHERE age > ?", 25)
    assert(res, err and err.message)
    for i, row in ipairs(res) do
        print(string.format("Row %d: id=%d, name=%s, age=%d",
            i, row.id, row.name, row.age))
    end

    -- UPDATE
    res, err = pool:query("UPDATE users SET age = ? WHERE name = ?", 31, "Alice")
    assert(res, err and err.message)
    print("Updated rows:", res.affected_rows)

    -- DELETE
    res, err = pool:query("DELETE FROM users WHERE id = ?", 1)
    assert(res, err and err.message)
    print("Deleted rows:", res.affected_rows)

    pool:close()
end)
```

### pool:begin()

开始一个事务（异步）。

- **参数**: 无
- **返回值**:
  - 成功: `conn, nil` - 事务连接对象和 nil
  - 失败: `nil, err_packet` - nil 和错误包
- **异步**: 会挂起协程直到事务开始
- **注意**:
  - 返回的连接对象必须手动关闭（使用 `conn:close()` 或 `<close>` 标记）
  - 未提交或回滚的事务会在关闭时自动回滚
- **示例**:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local pool = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    -- 创建测试表
    pool:query([[
        CREATE TEMPORARY TABLE accounts (
            id INT PRIMARY KEY,
            balance DECIMAL(10, 2)
        )
    ]])
    pool:query("INSERT INTO accounts VALUES (1, 1000), (2, 500)")

    -- 开始事务（使用 <close> 自动管理）
    local tx<close>, err = pool:begin()
    assert(tx, err and err.message)

    -- 转账操作
    local ok, err = tx:query("UPDATE accounts SET balance = balance - ? WHERE id = ?", 100, 1)
    assert(ok, err and err.message)

    ok, err = tx:query("UPDATE accounts SET balance = balance + ? WHERE id = ?", 100, 2)
    assert(ok, err and err.message)

    -- 提交事务
    ok, err = tx:commit()
    assert(ok, err and err.message)
    print("Transaction committed")

    -- 验证结果
    local res = pool:query("SELECT * FROM accounts ORDER BY id")
    assert(res[1].balance == 900 and res[2].balance == 600)

    pool:close()
end)
```

---

## 事务连接 API

事务连接对象（`conn`）由 `pool:begin()` 返回，提供以下方法：

### conn:query(sql, ...)

在事务中执行查询（异步）。

- **参数**: 同 `pool:query()`
- **返回值**: 同 `pool:query()`
- **异步**: 会挂起协程直到查询完成
- **示例**:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local pool = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    pool:query("CREATE TEMPORARY TABLE products (id INT, stock INT)")
    pool:query("INSERT INTO products VALUES (1, 100)")

    local tx<close> = pool:begin()

    -- 在事务中查询
    local res = tx:query("SELECT stock FROM products WHERE id = ?", 1)
    local current_stock = res[1].stock

    -- 更新库存
    if current_stock >= 10 then
        tx:query("UPDATE products SET stock = stock - ? WHERE id = ?", 10, 1)
        tx:commit()
        print("Stock updated")
    else
        tx:rollback()
        print("Insufficient stock")
    end

    pool:close()
end)
```

### conn:ping()

检查事务连接是否有效（异步）。

- **参数**: 无
- **返回值**: 同 `pool:ping()`
- **异步**: 会挂起协程直到收到响应
- **示例**:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local pool = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
    }

    local tx<close> = pool:begin()

    -- 检查事务连接
    local ok, err = tx:ping()
    if ok then
        print("Transaction connection is healthy")
    else
        print("Transaction connection lost:", err.message)
    end

    tx:commit()
    pool:close()
end)
```

### conn:commit()

提交事务（异步）。

- **参数**: 无
- **返回值**:
  - 成功: `ok_packet, nil` - OK 响应包和 nil
  - 失败: `nil, err_packet` - nil 和错误包
- **异步**: 会挂起协程直到提交完成
- **注意**:
  - 提交后连接自动变为自动提交模式
  - 重复提交会返回错误
  - 提交后仍需调用 `conn:close()` 归还连接
- **示例**:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local pool = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    pool:query("CREATE TEMPORARY TABLE logs (id INT, message TEXT)")

    local tx<close> = pool:begin()

    tx:query("INSERT INTO logs VALUES (1, 'Operation started')")
    tx:query("INSERT INTO logs VALUES (2, 'Operation in progress')")

    local ok, err = tx:commit()
    if ok then
        print("Transaction committed successfully")
    else
        print("Commit failed:", err.message)
    end

    pool:close()
end)
```

### conn:rollback()

回滚事务（异步）。

- **参数**: 无
- **返回值**:
  - 成功: `ok_packet, nil` - OK 响应包和 nil
  - 失败: `nil, err_packet` - nil 和错误包
- **异步**: 会挂起协程直到回滚完成
- **注意**:
  - 回滚后连接自动变为自动提交模式
  - 重复回滚会返回错误
  - 回滚后仍需调用 `conn:close()` 归还连接
- **示例**:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local pool = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    pool:query("CREATE TEMPORARY TABLE orders (id INT, amount DECIMAL(10,2))")
    pool:query("INSERT INTO orders VALUES (1, 1000)")

    local tx<close> = pool:begin()

    -- 尝试更新订单
    local ok, err = tx:query("UPDATE orders SET amount = ? WHERE id = ?", -100, 1)

    if ok then
        tx:commit()
        print("Order updated")
    else
        -- 出错时回滚
        local ok, err = tx:rollback()
        if ok then
            print("Transaction rolled back")
        else
            print("Rollback failed:", err.message)
        end
    end

    pool:close()
end)
```

### conn:close()

关闭事务连接，归还到连接池。

- **参数**: 无
- **返回值**: 无
- **注意**:
  - 如果事务未提交或回滚，将自动回滚
  - 可以重复调用。关闭后，该句柄不能再执行查询，也不会影响复用同一物理连接的后续事务
  - 连接归还到池中或释放
  - 关闭后连接对象不可再使用
- **示例**:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local pool = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
    }

    local tx = pool:begin()

    -- 执行操作...
    tx:query("SELECT 1")

    -- 手动关闭
    tx:close()

    -- 或使用 <close> 自动管理
    do
        local tx2<close> = pool:begin()
        tx2:query("SELECT 2")
        -- tx2 在作用域结束时自动关闭
    end

    pool:close()
end)
```

---

## 数据类型

### ok_packet

执行成功的响应包（INSERT/UPDATE/DELETE/COMMIT/ROLLBACK）。

- **字段**:
  - `type`: `string` - 固定为 `"OK"`
  - `affected_rows`: `integer` - 受影响的行数
  - `last_insert_id`: `integer` - 最后插入的自增 ID
  - `server_status`: `integer` - 服务器状态标志
  - `warning_count`: `integer` - 警告数量
  - `message`: `string|nil` - 服务器消息（可选）

### err_packet

错误响应包。

- **字段**:
  - `type`: `string` - 固定为 `"ERR"`
  - `errno`: `integer|nil` - MySQL 错误码
  - `sqlstate`: `string|nil` - SQLSTATE 错误码
  - `message`: `string` - 错误消息

### row

查询结果行。

- **类型**: `table` - 键值对表
- **键**: `string` - 列名（小写）
- **值**: 数据类型根据 MySQL 类型自动转换：
  - `TINYINT/SMALLINT/INT/BIGINT` → `integer`
  - `FLOAT/DOUBLE` → `number`
  - `DECIMAL` → `string`
  - `VARCHAR/TEXT/BLOB` → `string`
  - `DATE/TIME/DATETIME/TIMESTAMP` → `string`
  - `NULL` → `nil`

---

## 使用示例

### 示例1：基本 CRUD 操作

完整的增删改查示例：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    -- 创建表
    db:query([[
        CREATE TEMPORARY TABLE users (
            id INT PRIMARY KEY AUTO_INCREMENT,
            username VARCHAR(50) UNIQUE NOT NULL,
            email VARCHAR(100),
            age INT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ]])

    -- INSERT - 插入数据
    local res, err = db:query(
        "INSERT INTO users (username, email, age) VALUES (?, ?, ?)",
        "alice", "alice@example.com", 30
    )
    assert(res, err and err.message)
    print("Inserted user ID:", res.last_insert_id)

    -- 批量插入
    db:query("INSERT INTO users (username, age) VALUES (?, ?)", "bob", 25)
    db:query("INSERT INTO users (username, age) VALUES (?, ?)", "charlie", 35)

    -- SELECT - 查询数据
    res, err = db:query("SELECT * FROM users WHERE age >= ?", 30)
    assert(res, err and err.message)
    print("Found users:", #res)
    for _, user in ipairs(res) do
        print(string.format("  ID=%d, username=%s, age=%d",
            user.id, user.username, user.age))
    end

    -- UPDATE - 更新数据
    res, err = db:query("UPDATE users SET age = ? WHERE username = ?", 31, "alice")
    assert(res, err and err.message)
    print("Updated rows:", res.affected_rows)

    -- DELETE - 删除数据
    res, err = db:query("DELETE FROM users WHERE username = ?", "bob")
    assert(res, err and err.message)
    print("Deleted rows:", res.affected_rows)

    db:close()
end)
```

### 示例2：事务处理

银行转账事务示例：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    -- 创建账户表
    db:query([[
        CREATE TEMPORARY TABLE accounts (
            id INT PRIMARY KEY,
            name VARCHAR(50),
            balance DECIMAL(10, 2)
        )
    ]])
    db:query("INSERT INTO accounts VALUES (1, 'Alice', 1000.00)")
    db:query("INSERT INTO accounts VALUES (2, 'Bob', 500.00)")

    -- 转账函数
    local function transfer(from_id, to_id, amount)
        local tx<close>, err = db:begin()
        if not tx then
            return false, "Failed to begin transaction: " .. err.message
        end

        -- 检查余额
        local res, err = tx:query("SELECT balance FROM accounts WHERE id = ?", from_id)
        if not res then
            tx:rollback()
            return false, "Query failed: " .. err.message
        end

        if #res == 0 then
            tx:rollback()
            return false, "Account not found"
        end

        local balance = res[1].balance
        if balance < amount then
            tx:rollback()
            return false, "Insufficient balance"
        end

        -- 扣款
        res, err = tx:query(
            "UPDATE accounts SET balance = balance - ? WHERE id = ?",
            amount, from_id
        )
        if not res then
            tx:rollback()
            return false, "Debit failed: " .. err.message
        end

        -- 到账
        res, err = tx:query(
            "UPDATE accounts SET balance = balance + ? WHERE id = ?",
            amount, to_id
        )
        if not res then
            tx:rollback()
            return false, "Credit failed: " .. err.message
        end

        -- 提交事务
        local ok, err = tx:commit()
        if not ok then
            return false, "Commit failed: " .. err.message
        end

        return true, "Transfer successful"
    end

    -- 执行转账
    local ok, msg = transfer(1, 2, 100)
    print(msg)

    -- 验证结果
    local res = db:query("SELECT * FROM accounts ORDER BY id")
    for _, account in ipairs(res) do
        print(string.format("%s: $%.2f", account.name, account.balance))
    end

    db:close()
end)
```

### 示例3：连接池配置

生产环境的连接池配置示例：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "app_user",
        password = "secure_password",
        database = "production_db",
        charset = "utf8mb4",
        -- 限制最大 20 个并发连接
        max_open_conns = 20,
        -- 保持 5 个空闲连接以快速响应
        max_idle_conns = 5,
        -- 空闲连接 10 分钟后关闭
        max_idle_time = 600,
        -- 连接最多使用 1 小时
        max_lifetime = 3600,
        -- 支持 16MB 数据包
        max_packet_size = 16 * 1024 * 1024,
    }

    -- 定期健康检查（演示运行 2 次）
    local function health_check()
        for i = 1, 2 do
            local ok, err = db:ping()
            if ok then
                print("Database healthy")
            else
                print("Database unhealthy:", err.message)
            end
            if i < 2 then
                silly.sleep(30000)  -- 每 30 秒检查一次
            end
        end
    end

    task.fork(health_check)

    -- 应用逻辑...
    local res = db:query("SELECT COUNT(*) as count FROM users")
    print("Total users:", res[1].count)

    -- 优雅关闭
    db:close()
end)
```

### 示例4：NULL 值处理

处理 NULL 值的示例：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    -- 创建表（允许 NULL）
    db:query([[
        CREATE TEMPORARY TABLE profiles (
            id INT PRIMARY KEY AUTO_INCREMENT,
            username VARCHAR(50) NOT NULL,
            email VARCHAR(100),
            phone VARCHAR(20)
        )
    ]])

    -- 插入包含 NULL 的数据
    db:query(
        "INSERT INTO profiles (username, email, phone) VALUES (?, ?, ?)",
        "alice", "alice@example.com", nil  -- phone 为 NULL
    )
    db:query(
        "INSERT INTO profiles (username, email, phone) VALUES (?, ?, ?)",
        "bob", nil, "1234567890"  -- email 为 NULL
    )

    -- 查询并处理 NULL
    local res = db:query("SELECT * FROM profiles")
    for _, profile in ipairs(res) do
        print(string.format(
            "Username: %s, Email: %s, Phone: %s",
            profile.username,
            profile.email or "N/A",
            profile.phone or "N/A"
        ))
    end

    -- 查询 NULL 值
    res = db:query("SELECT * FROM profiles WHERE email IS NULL")
    print("Profiles without email:", #res)

    db:close()
end)
```

### 示例5：日期和时间类型

处理日期和时间类型：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    -- 创建表
    db:query([[
        CREATE TEMPORARY TABLE events (
            id INT PRIMARY KEY AUTO_INCREMENT,
            name VARCHAR(100),
            event_date DATE,
            event_time TIME,
            created_at DATETIME,
            updated_at TIMESTAMP
        )
    ]])

    -- 插入日期时间数据
    db:query([[
        INSERT INTO events (name, event_date, event_time, created_at)
        VALUES (?, ?, ?, ?)
    ]], "Conference", "2025-12-25", "14:30:00", "2025-10-13 10:00:00")

    -- 查询日期时间
    local res = db:query("SELECT * FROM events WHERE event_date >= ?", "2025-01-01")
    for _, event in ipairs(res) do
        print(string.format(
            "Event: %s, Date: %s, Time: %s, Created: %s",
            event.name,
            event.event_date,
            event.event_time,
            event.created_at
        ))
    end

    -- 使用 NOW() 等 MySQL 函数
    db:query([[
        INSERT INTO events (name, event_date, event_time, created_at)
        VALUES (?, CURDATE(), CURTIME(), NOW())
    ]], "Today's Event")

    res = db:query("SELECT name, created_at FROM events WHERE DATE(created_at) = CURDATE()")
    print("Today's events:", #res)

    db:close()
end)
```

### 示例6：大数据量处理

处理大数据量的最佳实践：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
        max_packet_size = 64 * 1024 * 1024,  -- 64MB
    }

    -- 创建表
    db:query([[
        CREATE TEMPORARY TABLE documents (
            id INT PRIMARY KEY AUTO_INCREMENT,
            title VARCHAR(200),
            content TEXT
        )
    ]])

    -- 批量插入（分批处理）
    local batch_size = 100
    local total_docs = 500

    for batch_start = 1, total_docs, batch_size do
        local batch_end = math.min(batch_start + batch_size - 1, total_docs)

        for i = batch_start, batch_end do
            db:query(
                "INSERT INTO documents (title, content) VALUES (?, ?)",
                string.format("Document %d", i),
                string.rep("Content ", 100)  -- 模拟较大内容
            )
        end

        print(string.format("Inserted documents %d-%d", batch_start, batch_end))
    end

    -- 分页查询大结果集
    local page_size = 50
    local page = 1

    while true do
        local offset = (page - 1) * page_size
        local res = db:query(
            "SELECT id, title FROM documents ORDER BY id LIMIT ? OFFSET ?",
            page_size, offset
        )

        if #res == 0 then
            break
        end

        print(string.format("Page %d: %d documents", page, #res))
        page = page + 1
    end

    -- 查询统计信息
    local res = db:query([[
        SELECT
            COUNT(*) as total,
            AVG(LENGTH(content)) as avg_size,
            MAX(LENGTH(content)) as max_size
        FROM documents
    ]])
    print(string.format(
        "Total: %d, Avg size: %.0f bytes, Max size: %d bytes",
        res[1].total, res[1].avg_size, res[1].max_size
    ))

    db:close()
end)
```

### 示例7：并发查询

使用协程实现并发查询：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
        max_open_conns = 5,  -- 允许 5 个并发连接
    }

    -- 创建测试表
    db:query([[
        CREATE TEMPORARY TABLE stats (
            category VARCHAR(50),
            count INT
        )
    ]])

    -- 插入测试数据
    local categories = {"A", "B", "C", "D", "E"}
    for _, cat in ipairs(categories) do
        db:query("INSERT INTO stats VALUES (?, ?)", cat, math.random(100, 1000))
    end

    -- 并发查询
    local wg = waitgroup.new()
    local results = {}

    for i, category in ipairs(categories) do
        wg:fork(function()
            local res = db:query("SELECT count FROM stats WHERE category = ?", category)
            if res then
                results[i] = {
                    category = category,
                    count = res[1].count,
                }
                print(string.format("Category %s: %d", category, res[1].count))
            end
        end)
    end

    -- 等待所有查询完成
    wg:wait()
    print("All queries completed")

    -- 汇总结果
    local total = 0
    for _, result in ipairs(results) do
        total = total + result.count
    end
    print("Total count:", total)

    db:close()
end)
```

### 示例8：错误处理

完整的错误处理示例：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    -- 辅助函数：安全执行查询
    local function safe_query(db, sql, ...)
        local res, err = db:query(sql, ...)
        if not res then
            print("Query failed:", sql)
            print("Error code:", err.errno or "N/A")
            print("SQL state:", err.sqlstate or "N/A")
            print("Message:", err.message)
            return nil
        end
        return res
    end

    -- 创建表
    db:query([[
        CREATE TEMPORARY TABLE products (
            id INT PRIMARY KEY,
            name VARCHAR(50) UNIQUE
        )
    ]])

    -- 成功插入
    local res = safe_query(db, "INSERT INTO products VALUES (?, ?)", 1, "Product A")
    if res then
        print("Insert successful, affected rows:", res.affected_rows)
    end

    -- 重复主键错误
    res = safe_query(db, "INSERT INTO products VALUES (?, ?)", 1, "Product B")
    -- 输出: Error code: 1062, Message: Duplicate entry '1' for key 'PRIMARY'

    -- UNIQUE 约束错误
    db:query("INSERT INTO products VALUES (?, ?)", 2, "Product A")
    res = safe_query(db, "INSERT INTO products VALUES (?, ?)", 3, "Product A")
    -- 输出: Error code: 1062, Message: Duplicate entry 'Product A' for key 'name'

    -- 表不存在错误
    res = safe_query(db, "SELECT * FROM non_existent_table")
    -- 输出: Error code: 1146, Message: Table '*.non_existent_table' doesn't exist

    -- 语法错误
    res = safe_query(db, "SELCT * FROM products")
    -- 输出: Error code: 1064, Message: You have an error in your SQL syntax

    -- 连接错误处理
    local bad_db = mysql.open {
        addr = "127.0.0.1:3307",  -- 错误端口
        user = "root",
        password = "root",
    }
    res, err = bad_db:ping()
    if not res then
        print("Connection error:", err.message)
    end

    db:close()
end)
```

---

## 注意事项

### 1. 协程要求

所有数据库操作必须在协程中执行：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

-- 错误：不能在主线程调用
-- local db = mysql.open{...}
-- db:query("SELECT 1")  -- 会挂起导致死锁

-- 正确：在协程中调用
task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
    }
    local res = db:query("SELECT 1")
    -- ...
    db:close()
end)
```

### 2. 连接池生命周期

连接池应该在应用启动时创建，关闭时销毁，而不是每次查询都创建：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

-- 不推荐：每次查询创建连接池
task.fork(function()
    local db = mysql.open{addr = "127.0.0.1:3306", user = "root", password = "root"}
    db:query("SELECT 1")
    db:close()
end)

-- 推荐：复用连接池
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    max_open_conns = 10,
    max_idle_conns = 5,
}

task.fork(function()
    -- 查询 1
    db:query("SELECT 1")
end)

task.fork(function()
    -- 查询 2（复用连接池）
    db:query("SELECT 2")
end)
```

### 3. 事务连接管理

事务连接必须手动关闭，推荐使用 `<close>` 标记：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
    }

    -- 不推荐：可能泄漏连接
    local tx = db:begin()
    tx:query("SELECT 1")
    if some_condition then
        return  -- tx 未关闭，连接泄漏！
    end
    tx:close()

    -- 推荐：使用 <close> 自动管理
    do
        local tx<close> = db:begin()
        tx:query("SELECT 1")
        if some_condition then
            return  -- tx 自动关闭
        end
        tx:commit()
        -- tx 在作用域结束时自动关闭
    end

    db:close()
end)
```

### 4. 参数类型

SQL 参数支持以下 Lua 类型：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    db:query([[
        CREATE TEMPORARY TABLE types_test (
            id INT,
            str VARCHAR(50),
            num INT,
            flag BOOLEAN,
            nullable VARCHAR(50)
        )
    ]])

    -- 支持的类型
    db:query(
        "INSERT INTO types_test VALUES (?, ?, ?, ?, ?)",
        123,         -- number → INT
        "hello",     -- string → VARCHAR
        42,          -- number → INT
        true,        -- boolean → 1 (TINYINT)
        nil          -- nil → NULL
    )

    local res = db:query("SELECT * FROM types_test")
    local row = res[1]
    assert(row.id == 123)
    assert(row.str == "hello")
    assert(row.num == 42)
    assert(row.flag == 1)  -- boolean 读回为整数
    assert(row.nullable == nil)

    db:close()
end)
```

### 5. 字符集配置

推荐使用 `utf8mb4` 字符集以支持完整的 Unicode（包括 emoji）：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
        charset = "utf8mb4",  -- 支持 emoji 和完整 Unicode
    }

    db:query([[
        CREATE TEMPORARY TABLE messages (
            id INT PRIMARY KEY AUTO_INCREMENT,
            content VARCHAR(200)
        ) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
    ]])

    -- 插入包含 emoji 的文本
    db:query("INSERT INTO messages (content) VALUES (?)", "Hello 👋 World 🌍!")

    local res = db:query("SELECT * FROM messages")
    print(res[1].content)  -- 输出: Hello 👋 World 🌍!

    db:close()
end)
```

### 6. 错误处理

始终检查返回值并处理错误：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
    }

    -- 方式 1：使用 assert
    local res, err = db:query("SELECT 1 as num")
    assert(res, err and err.message)
    print(res[1].num)

    -- 方式 2：使用 if 判断
    res, err = db:query("SELECT * FROM non_existent_table")
    if not res then
        print("Query failed:", err.message)
        print("Error code:", err.errno)
        -- 处理错误...
        db:close()
        return
    end

    -- 方式 3：使用 pcall 保护
    local ok, res, err = pcall(function()
        return db:query("SELECT 1")
    end)
    if not ok then
        print("Exception:", res)
    elseif not res then
        print("Query error:", err.message)
    end

    db:close()
end)
```

### 7. 预处理语句缓存

预处理语句会自动缓存，相同 SQL 会复用：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    db:query("CREATE TEMPORARY TABLE cache_test (id INT, val INT)")

    -- 首次执行：准备语句
    db:query("INSERT INTO cache_test VALUES (?, ?)", 1, 100)

    -- 后续执行：复用已准备的语句（更快）
    for i = 2, 100 do
        db:query("INSERT INTO cache_test VALUES (?, ?)", i, i * 100)
    end

    -- 不同的 SQL 会创建新的预处理语句
    db:query("SELECT * FROM cache_test WHERE id = ?", 1)
    db:query("SELECT * FROM cache_test WHERE val > ?", 500)

    db:close()
end)
```

### 8. 连接池配置建议

根据应用负载合理配置连接池：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"

-- 低负载应用（如内部工具）
local db_low = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    max_open_conns = 5,
    max_idle_conns = 2,
    max_idle_time = 300,  -- 5 分钟
    max_lifetime = 1800,  -- 30 分钟
}

-- 中等负载应用（如小型 API 服务）
local db_medium = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    max_open_conns = 20,
    max_idle_conns = 5,
    max_idle_time = 600,   -- 10 分钟
    max_lifetime = 3600,   -- 1 小时
}

-- 高负载应用（如大型 Web 服务）
local db_high = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    max_open_conns = 100,
    max_idle_conns = 20,
    max_idle_time = 300,   -- 5 分钟（快速释放）
    max_lifetime = 3600,   -- 1 小时
}

local task = require "silly.task"

task.fork(function()
    -- 使用相应的连接池...
    db_low:close()
    db_medium:close()
    db_high:close()
end)
```

---

## 性能建议

### 1. 使用预处理语句

所有查询自动使用预处理语句，相同 SQL 会复用：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    db:query("CREATE TEMPORARY TABLE perf_test (id INT, val INT)")

    -- 高效：SQL 相同，复用预处理语句
    local start = silly.time.now()
    for i = 1, 1000 do
        db:query("INSERT INTO perf_test VALUES (?, ?)", i, i * 10)
    end
    local elapsed = silly.time.now() - start
    print(string.format("Prepared statement: %.2f ms", elapsed))

    db:close()
end)
```

### 2. 批量操作

大量数据操作时使用批量插入：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    db:query("CREATE TEMPORARY TABLE batch_test (id INT, val INT)")

    -- 低效：逐行插入
    local start = silly.time.now()
    for i = 1, 100 do
        db:query("INSERT INTO batch_test VALUES (?, ?)", i, i)
    end
    print("Individual inserts:", silly.time.now() - start, "ms")

    -- 高效：批量插入（构建大 SQL）
    local values = {}
    for i = 1, 100 do
        table.insert(values, string.format("(%d, %d)", i, i))
    end
    start = silly.time.now()
    db:query("INSERT INTO batch_test VALUES " .. table.concat(values, ","))
    print("Batch insert:", silly.time.now() - start, "ms")

    db:close()
end)
```

### 3. 合理配置连接池

根据并发量调整连接池大小：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    -- 场景：10 个并发查询
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
        max_open_conns = 10,  -- 匹配并发数
        max_idle_conns = 5,   -- 保持一半空闲连接
    }

    local wg = waitgroup.new()
    local start = silly.time.now()

    for i = 1, 10 do
        wg:fork(function()
            db:query("SELECT SLEEP(0.1)")
        end)
    end

    wg:wait()
    local elapsed = silly.time.now() - start
    print(string.format("10 concurrent queries: %.0f ms", elapsed))

    db:close()
end)
```

### 4. 使用事务减少往返

需要多次操作时使用事务：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    db:query("CREATE TEMPORARY TABLE txn_test (id INT, val INT)")

    -- 低效：每次查询单独提交
    local start = silly.time.now()
    for i = 1, 100 do
        db:query("INSERT INTO txn_test VALUES (?, ?)", i, i)
    end
    print("Without transaction:", silly.time.now() - start, "ms")

    db:query("DELETE FROM txn_test")

    -- 高效：批量操作在一个事务中
    start = silly.time.now()
    local tx<close> = db:begin()
    for i = 1, 100 do
        tx:query("INSERT INTO txn_test VALUES (?, ?)", i, i)
    end
    tx:commit()
    print("With transaction:", silly.time.now() - start, "ms")

    db:close()
end)
```

### 5. 索引优化

合理使用索引加速查询：

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

task.fork(function()
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
    }

    -- 创建表并添加索引
    db:query([[
        CREATE TEMPORARY TABLE indexed_test (
            id INT PRIMARY KEY AUTO_INCREMENT,
            user_id INT,
            email VARCHAR(100),
            created_at TIMESTAMP,
            INDEX idx_user_id (user_id),
            INDEX idx_email (email)
        )
    ]])

    -- 插入测试数据
    for i = 1, 1000 do
        db:query(
            "INSERT INTO indexed_test (user_id, email) VALUES (?, ?)",
            i % 100,
            string.format("user%d@example.com", i)
        )
    end

    -- 使用索引的查询（快）
    local start = silly.time.now()
    local res = db:query("SELECT * FROM indexed_test WHERE user_id = ?", 50)
    print(string.format("Indexed query: %.2f ms, rows: %d",
        silly.time.now() - start, #res))

    -- 使用 EXPLAIN 分析查询
    res = db:query("EXPLAIN SELECT * FROM indexed_test WHERE user_id = ?", 50)
    print("Query uses index:", res[1].key)

    db:close()
end)
```

---

## 参见

- [silly](../silly.md) - 核心模块
- [silly.store.redis](./redis.md) - Redis 客户端
- [silly.store.etcd](./etcd.md) - Etcd 客户端
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
- [silly.encoding.json](../encoding/json.md) - JSON 编解码
