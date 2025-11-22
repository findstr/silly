---
title: silly.store.mysql
icon: database
category:
  - API Reference
tag:
  - Database
  - MySQL
  - Storage
---

# silly.store.mysql

The `silly.store.mysql` module provides a high-performance asynchronous MySQL/MariaDB client based on connection pooling. It uses prepared statements to improve performance and security, supports transactional operations, and is fully compatible with MySQL 5.x/8.x and MariaDB.

## Module Import

```lua validate
local mysql = require "silly.store.mysql"
```

## Core Concepts

### Connection Pool

The connection pool manages the lifecycle of database connections, providing the following features:

- **Automatic Connection Management**: Creates connections on demand, reclaims when idle
- **Connection Reuse**: Reduces connection establishment overhead
- **Concurrency Control**: Limits maximum concurrent connections
- **Health Checks**: Automatically cleans up expired and idle connections
- **Wait Queue**: Automatically queues when connection pool is full

### Prepared Statements

All queries automatically use prepared statements:

- **Performance Optimization**: Statement caching reduces parsing overhead
- **SQL Injection Protection**: Parameters are automatically escaped
- **Type Safety**: Automatic data type conversion
- **Transparent Usage**: Just use `?` placeholders

### Transaction Support

Supports full ACID transactions:

- **BEGIN**: Start transaction
- **COMMIT**: Commit transaction
- **ROLLBACK**: Rollback transaction
- **Auto Rollback**: Uncommitted transactions automatically rollback

---

## Connection Pool API

### mysql.open(opts)

Creates a new MySQL connection pool.

- **Parameters**:
  - `opts`: `table` - Connection pool configuration table
    - `addr`: `string` - Database address in format `"host:port"` (default `"127.0.0.1:3306"`)
    - `user`: `string` - Username
    - `password`: `string` - Password
    - `database`: `string|nil` (optional) - Database name (default empty)
    - `charset`: `string|nil` (optional) - Character set (default `"_default"`, recommend `"utf8mb4"`)
    - `max_open_conns`: `integer|nil` (optional) - Maximum open connections, 0 means unlimited (default 0)
    - `max_idle_conns`: `integer|nil` (optional) - Maximum idle connections (default 0)
    - `max_idle_time`: `integer|nil` (optional) - Maximum idle time for connections (seconds), 0 means unlimited (default 0)
    - `max_lifetime`: `integer|nil` (optional) - Maximum connection lifetime (seconds), 0 means unlimited (default 0)
    - `max_packet_size`: `integer|nil` (optional) - Maximum packet size (bytes), default 1MB
- **Returns**:
  - Success: `pool` - MySQL connection pool object
  - Failure: Never fails (connection established on first query)
- **Example**:

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

Closes the connection pool and releases all connections.

- **Parameters**: None
- **Returns**: None
- **Note**: After closing, the connection pool cannot be used; all coroutines waiting for connections will be woken up with errors
- **Example**:

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

    -- Use connection pool...
    pool:query("SELECT 1")

    -- Close connection pool
    pool:close()
    print("Connection pool closed")
end)
```

### pool:ping()

Checks if the database connection is valid (asynchronous).

- **Parameters**: None
- **Returns**:
  - Success: `ok_packet, nil` - OK response packet and nil
  - Failure: `nil, err_packet` - nil and error packet
- **Async**: Suspends coroutine until response is received
- **Example**:

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

Executes SQL query (asynchronous).

- **Parameters**:
  - `sql`: `string` - SQL statement, use `?` as parameter placeholder
  - `...`: Variable arguments - SQL parameter values (supports nil, boolean, number, string)
- **Returns**:
  - SELECT query: `row[], nil` - Result row array and nil
  - INSERT/UPDATE/DELETE: `ok_packet, nil` - OK response packet and nil
  - Failure: `nil, err_packet` - nil and error packet
- **Async**: Suspends coroutine until query completes
- **Note**:
  - Automatically uses prepared statements
  - Parameter types are automatically converted
  - nil parameter represents SQL NULL
- **Example**:

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

Starts a transaction (asynchronous).

- **Parameters**: None
- **Returns**:
  - Success: `conn, nil` - Transaction connection object and nil
  - Failure: `nil, err_packet` - nil and error packet
- **Async**: Suspends coroutine until transaction begins
- **Note**:
  - The returned connection object must be manually closed (use `conn:close()` or `<close>` marker)
  - Uncommitted or rolled back transactions will automatically rollback when closed
- **Example**:

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

    -- Create test table
    pool:query([[
        CREATE TEMPORARY TABLE accounts (
            id INT PRIMARY KEY,
            balance DECIMAL(10, 2)
        )
    ]])
    pool:query("INSERT INTO accounts VALUES (1, 1000), (2, 500)")

    -- Begin transaction (use <close> for automatic management)
    local tx<close>, err = pool:begin()
    assert(tx, err and err.message)

    -- Transfer operation
    local ok, err = tx:query("UPDATE accounts SET balance = balance - ? WHERE id = ?", 100, 1)
    assert(ok, err and err.message)

    ok, err = tx:query("UPDATE accounts SET balance = balance + ? WHERE id = ?", 100, 2)
    assert(ok, err and err.message)

    -- Commit transaction
    ok, err = tx:commit()
    assert(ok, err and err.message)
    print("Transaction committed")

    -- Verify results
    local res = pool:query("SELECT * FROM accounts ORDER BY id")
    assert(res[1].balance == 900 and res[2].balance == 600)

    pool:close()
end)
```

---

## Transaction Connection API

The transaction connection object (`conn`) is returned by `pool:begin()` and provides the following methods:

### conn:query(sql, ...)

Executes a query in a transaction (asynchronous).

- **Parameters**: Same as `pool:query()`
- **Returns**: Same as `pool:query()`
- **Async**: Suspends coroutine until query completes
- **Example**:

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

    -- Query in transaction
    local res = tx:query("SELECT stock FROM products WHERE id = ?", 1)
    local current_stock = res[1].stock

    -- Update stock
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

Checks if transaction connection is valid (asynchronous).

- **Parameters**: None
- **Returns**: Same as `pool:ping()`
- **Async**: Suspends coroutine until response is received
- **Example**:

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

    -- Check transaction connection
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

Commits transaction (asynchronous).

- **Parameters**: None
- **Returns**:
  - Success: `ok_packet, nil` - OK response packet and nil
  - Failure: `nil, err_packet` - nil and error packet
- **Async**: Suspends coroutine until commit completes
- **Note**:
  - After commit, connection automatically switches to autocommit mode
  - Repeated commits will return an error
  - After commit, still need to call `conn:close()` to return connection
- **Example**:

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

Rolls back transaction (asynchronous).

- **Parameters**: None
- **Returns**:
  - Success: `ok_packet, nil` - OK response packet and nil
  - Failure: `nil, err_packet` - nil and error packet
- **Async**: Suspends coroutine until rollback completes
- **Note**:
  - After rollback, connection automatically switches to autocommit mode
  - Repeated rollbacks will return an error
  - After rollback, still need to call `conn:close()` to return connection
- **Example**:

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

    -- Try to update order
    local ok, err = tx:query("UPDATE orders SET amount = ? WHERE id = ?", -100, 1)

    if ok then
        tx:commit()
        print("Order updated")
    else
        -- Rollback on error
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

Closes transaction connection and returns it to the connection pool.

- **Parameters**: None
- **Returns**: None
- **Note**:
  - If transaction is not committed or rolled back, it will automatically rollback
  - Connection is returned to pool or released
  - Connection object cannot be used after closing
- **Example**:

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

    -- Perform operations...
    tx:query("SELECT 1")

    -- Manual close
    tx:close()

    -- Or use <close> for automatic management
    do
        local tx2<close> = pool:begin()
        tx2:query("SELECT 2")
        -- tx2 automatically closes at end of scope
    end

    pool:close()
end)
```

---

## Data Types

### ok_packet

Successful response packet (INSERT/UPDATE/DELETE/COMMIT/ROLLBACK).

- **Fields**:
  - `type`: `string` - Fixed as `"OK"`
  - `affected_rows`: `integer` - Number of affected rows
  - `last_insert_id`: `integer` - Last inserted auto-increment ID
  - `server_status`: `integer` - Server status flags
  - `warning_count`: `integer` - Number of warnings
  - `message`: `string|nil` - Server message (optional)

### err_packet

Error response packet.

- **Fields**:
  - `type`: `string` - Fixed as `"ERR"`
  - `errno`: `integer|nil` - MySQL error code
  - `sqlstate`: `string|nil` - SQLSTATE error code
  - `message`: `string` - Error message

### row

Query result row.

- **Type**: `table` - Key-value table
- **Keys**: `string` - Column names (lowercase)
- **Values**: Data types automatically converted based on MySQL types:
  - `TINYINT/SMALLINT/INT/BIGINT` → `integer`
  - `FLOAT/DOUBLE` → `number`
  - `DECIMAL` → `string`
  - `VARCHAR/TEXT/BLOB` → `string`
  - `DATE/TIME/DATETIME/TIMESTAMP` → `string`
  - `NULL` → `nil`

---

## Usage Examples

### Example 1: Basic CRUD Operations

Complete create, read, update, delete example:

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

    -- Create table
    db:query([[
        CREATE TEMPORARY TABLE users (
            id INT PRIMARY KEY AUTO_INCREMENT,
            username VARCHAR(50) UNIQUE NOT NULL,
            email VARCHAR(100),
            age INT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ]])

    -- INSERT - Insert data
    local res, err = db:query(
        "INSERT INTO users (username, email, age) VALUES (?, ?, ?)",
        "alice", "alice@example.com", 30
    )
    assert(res, err and err.message)
    print("Inserted user ID:", res.last_insert_id)

    -- Batch insert
    db:query("INSERT INTO users (username, age) VALUES (?, ?)", "bob", 25)
    db:query("INSERT INTO users (username, age) VALUES (?, ?)", "charlie", 35)

    -- SELECT - Query data
    res, err = db:query("SELECT * FROM users WHERE age >= ?", 30)
    assert(res, err and err.message)
    print("Found users:", #res)
    for _, user in ipairs(res) do
        print(string.format("  ID=%d, username=%s, age=%d",
            user.id, user.username, user.age))
    end

    -- UPDATE - Update data
    res, err = db:query("UPDATE users SET age = ? WHERE username = ?", 31, "alice")
    assert(res, err and err.message)
    print("Updated rows:", res.affected_rows)

    -- DELETE - Delete data
    res, err = db:query("DELETE FROM users WHERE username = ?", "bob")
    assert(res, err and err.message)
    print("Deleted rows:", res.affected_rows)

    db:close()
end)
```

### Example 2: Transaction Processing

Bank transfer transaction example:

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

    -- Create accounts table
    db:query([[
        CREATE TEMPORARY TABLE accounts (
            id INT PRIMARY KEY,
            name VARCHAR(50),
            balance DECIMAL(10, 2)
        )
    ]])
    db:query("INSERT INTO accounts VALUES (1, 'Alice', 1000.00)")
    db:query("INSERT INTO accounts VALUES (2, 'Bob', 500.00)")

    -- Transfer function
    local function transfer(from_id, to_id, amount)
        local tx<close>, err = db:begin()
        if not tx then
            return false, "Failed to begin transaction: " .. err.message
        end

        -- Check balance
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

        -- Debit
        res, err = tx:query(
            "UPDATE accounts SET balance = balance - ? WHERE id = ?",
            amount, from_id
        )
        if not res then
            tx:rollback()
            return false, "Debit failed: " .. err.message
        end

        -- Credit
        res, err = tx:query(
            "UPDATE accounts SET balance = balance + ? WHERE id = ?",
            amount, to_id
        )
        if not res then
            tx:rollback()
            return false, "Credit failed: " .. err.message
        end

        -- Commit transaction
        local ok, err = tx:commit()
        if not ok then
            return false, "Commit failed: " .. err.message
        end

        return true, "Transfer successful"
    end

    -- Execute transfer
    local ok, msg = transfer(1, 2, 100)
    print(msg)

    -- Verify results
    local res = db:query("SELECT * FROM accounts ORDER BY id")
    for _, account in ipairs(res) do
        print(string.format("%s: $%.2f", account.name, account.balance))
    end

    db:close()
end)
```

### Example 3: Connection Pool Configuration

Production environment connection pool configuration example:

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
        -- Limit to 20 concurrent connections
        max_open_conns = 20,
        -- Keep 5 idle connections for fast response
        max_idle_conns = 5,
        -- Close idle connections after 10 minutes
        max_idle_time = 600,
        -- Connections last at most 1 hour
        max_lifetime = 3600,
        -- Support 16MB packets
        max_packet_size = 16 * 1024 * 1024,
    }

    -- Periodic health check (demo runs 2 times)
    local function health_check()
        for i = 1, 2 do
            local ok, err = db:ping()
            if ok then
                print("Database healthy")
            else
                print("Database unhealthy:", err.message)
            end
            if i < 2 then
                silly.sleep(30000)  -- Check every 30 seconds
            end
        end
    end

    task.fork(health_check)

    -- Application logic...
    local res = db:query("SELECT COUNT(*) as count FROM users")
    print("Total users:", res[1].count)

    -- Graceful shutdown
    db:close()
end)
```

### Example 4: NULL Value Handling

Example of handling NULL values:

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

    -- Create table (allow NULL)
    db:query([[
        CREATE TEMPORARY TABLE profiles (
            id INT PRIMARY KEY AUTO_INCREMENT,
            username VARCHAR(50) NOT NULL,
            email VARCHAR(100),
            phone VARCHAR(20)
        )
    ]])

    -- Insert data with NULL
    db:query(
        "INSERT INTO profiles (username, email, phone) VALUES (?, ?, ?)",
        "alice", "alice@example.com", nil  -- phone is NULL
    )
    db:query(
        "INSERT INTO profiles (username, email, phone) VALUES (?, ?, ?)",
        "bob", nil, "1234567890"  -- email is NULL
    )

    -- Query and handle NULL
    local res = db:query("SELECT * FROM profiles")
    for _, profile in ipairs(res) do
        print(string.format(
            "Username: %s, Email: %s, Phone: %s",
            profile.username,
            profile.email or "N/A",
            profile.phone or "N/A"
        ))
    end

    -- Query NULL values
    res = db:query("SELECT * FROM profiles WHERE email IS NULL")
    print("Profiles without email:", #res)

    db:close()
end)
```

### Example 5: Date and Time Types

Handling date and time types:

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

    -- Create table
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

    -- Insert date/time data
    db:query([[
        INSERT INTO events (name, event_date, event_time, created_at)
        VALUES (?, ?, ?, ?)
    ]], "Conference", "2025-12-25", "14:30:00", "2025-10-13 10:00:00")

    -- Query date/time
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

    -- Use MySQL functions like NOW()
    db:query([[
        INSERT INTO events (name, event_date, event_time, created_at)
        VALUES (?, CURDATE(), CURTIME(), NOW())
    ]], "Today's Event")

    res = db:query("SELECT name, created_at FROM events WHERE DATE(created_at) = CURDATE()")
    print("Today's events:", #res)

    db:close()
end)
```

### Example 6: Large Data Handling

Best practices for handling large amounts of data:

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

    -- Create table
    db:query([[
        CREATE TEMPORARY TABLE documents (
            id INT PRIMARY KEY AUTO_INCREMENT,
            title VARCHAR(200),
            content TEXT
        )
    ]])

    -- Batch insert (process in batches)
    local batch_size = 100
    local total_docs = 500

    for batch_start = 1, total_docs, batch_size do
        local batch_end = math.min(batch_start + batch_size - 1, total_docs)

        for i = batch_start, batch_end do
            db:query(
                "INSERT INTO documents (title, content) VALUES (?, ?)",
                string.format("Document %d", i),
                string.rep("Content ", 100)  -- Simulate larger content
            )
        end

        print(string.format("Inserted documents %d-%d", batch_start, batch_end))
    end

    -- Paginated query for large result sets
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

    -- Query statistics
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

### Example 7: Concurrent Queries

Using coroutines for concurrent queries:

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
        max_open_conns = 5,  -- Allow 5 concurrent connections
    }

    -- Create test table
    db:query([[
        CREATE TEMPORARY TABLE stats (
            category VARCHAR(50),
            count INT
        )
    ]])

    -- Insert test data
    local categories = {"A", "B", "C", "D", "E"}
    for _, cat in ipairs(categories) do
        db:query("INSERT INTO stats VALUES (?, ?)", cat, math.random(100, 1000))
    end

    -- Concurrent queries
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

    -- Wait for all queries to complete
    wg:wait()
    print("All queries completed")

    -- Aggregate results
    local total = 0
    for _, result in ipairs(results) do
        total = total + result.count
    end
    print("Total count:", total)

    db:close()
end)
```

### Example 8: Error Handling

Complete error handling example:

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

    -- Helper function: Safe query execution
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

    -- Create table
    db:query([[
        CREATE TEMPORARY TABLE products (
            id INT PRIMARY KEY,
            name VARCHAR(50) UNIQUE
        )
    ]])

    -- Successful insert
    local res = safe_query(db, "INSERT INTO products VALUES (?, ?)", 1, "Product A")
    if res then
        print("Insert successful, affected rows:", res.affected_rows)
    end

    -- Duplicate primary key error
    res = safe_query(db, "INSERT INTO products VALUES (?, ?)", 1, "Product B")
    -- Output: Error code: 1062, Message: Duplicate entry '1' for key 'PRIMARY'

    -- UNIQUE constraint error
    db:query("INSERT INTO products VALUES (?, ?)", 2, "Product A")
    res = safe_query(db, "INSERT INTO products VALUES (?, ?)", 3, "Product A")
    -- Output: Error code: 1062, Message: Duplicate entry 'Product A' for key 'name'

    -- Table doesn't exist error
    res = safe_query(db, "SELECT * FROM non_existent_table")
    -- Output: Error code: 1146, Message: Table '*.non_existent_table' doesn't exist

    -- Syntax error
    res = safe_query(db, "SELCT * FROM products")
    -- Output: Error code: 1064, Message: You have an error in your SQL syntax

    -- Connection error handling
    local bad_db = mysql.open {
        addr = "127.0.0.1:3307",  -- Wrong port
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

## Notes

### 1. Coroutine Requirement

All database operations must be executed in coroutines:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

-- Wrong: Cannot call in main thread
-- local db = mysql.open{...}
-- db:query("SELECT 1")  -- Will hang causing deadlock

-- Correct: Call in coroutine
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

### 2. Connection Pool Lifecycle

Connection pools should be created at application startup and destroyed at shutdown, not created for each query:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local task = require "silly.task"

-- Not recommended: Create connection pool for each query
task.fork(function()
    local db = mysql.open{addr = "127.0.0.1:3306", user = "root", password = "root"}
    db:query("SELECT 1")
    db:close()
end)

-- Recommended: Reuse connection pool
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    max_open_conns = 10,
    max_idle_conns = 5,
}

task.fork(function()
    -- Query 1
    db:query("SELECT 1")
end)

task.fork(function()
    -- Query 2 (reuse connection pool)
    db:query("SELECT 2")
end)
```

### 3. Transaction Connection Management

Transaction connections must be manually closed; recommend using the `<close>` marker:

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

    -- Not recommended: May leak connections
    local tx = db:begin()
    tx:query("SELECT 1")
    if some_condition then
        return  -- tx not closed, connection leaked!
    end
    tx:close()

    -- Recommended: Use <close> for automatic management
    do
        local tx<close> = db:begin()
        tx:query("SELECT 1")
        if some_condition then
            return  -- tx automatically closes
        end
        tx:commit()
        -- tx automatically closes at end of scope
    end

    db:close()
end)
```

### 4. Parameter Types

SQL parameters support the following Lua types:

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

    -- Supported types
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
    assert(row.flag == 1)  -- boolean reads back as integer
    assert(row.nullable == nil)

    db:close()
end)
```

### 5. Character Set Configuration

Recommend using `utf8mb4` character set to support full Unicode (including emoji):

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
        charset = "utf8mb4",  -- Support emoji and full Unicode
    }

    db:query([[
        CREATE TEMPORARY TABLE messages (
            id INT PRIMARY KEY AUTO_INCREMENT,
            content VARCHAR(200)
        ) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
    ]])

    -- Insert text containing emoji
    db:query("INSERT INTO messages (content) VALUES (?)", "Hello 👋 World 🌍!")

    local res = db:query("SELECT * FROM messages")
    print(res[1].content)  -- Output: Hello 👋 World 🌍!

    db:close()
end)
```

### 6. Error Handling

Always check return values and handle errors:

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

    -- Method 1: Use assert
    local res, err = db:query("SELECT 1 as num")
    assert(res, err and err.message)
    print(res[1].num)

    -- Method 2: Use if statement
    res, err = db:query("SELECT * FROM non_existent_table")
    if not res then
        print("Query failed:", err.message)
        print("Error code:", err.errno)
        -- Handle error...
        db:close()
        return
    end

    -- Method 3: Use pcall protection
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

### 7. Prepared Statement Caching

Prepared statements are automatically cached; identical SQL will be reused:

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

    -- First execution: Prepare statement
    db:query("INSERT INTO cache_test VALUES (?, ?)", 1, 100)

    -- Subsequent executions: Reuse prepared statement (faster)
    for i = 2, 100 do
        db:query("INSERT INTO cache_test VALUES (?, ?)", i, i * 100)
    end

    -- Different SQL creates new prepared statement
    db:query("SELECT * FROM cache_test WHERE id = ?", 1)
    db:query("SELECT * FROM cache_test WHERE val > ?", 500)

    db:close()
end)
```

### 8. Connection Pool Configuration Recommendations

Configure connection pool based on application load:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"

-- Low load application (e.g., internal tools)
local db_low = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    max_open_conns = 5,
    max_idle_conns = 2,
    max_idle_time = 300,  -- 5 minutes
    max_lifetime = 1800,  -- 30 minutes
}

-- Medium load application (e.g., small API service)
local db_medium = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    max_open_conns = 20,
    max_idle_conns = 5,
    max_idle_time = 600,   -- 10 minutes
    max_lifetime = 3600,   -- 1 hour
}

-- High load application (e.g., large web service)
local db_high = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    max_open_conns = 100,
    max_idle_conns = 20,
    max_idle_time = 300,   -- 5 minutes (quick release)
    max_lifetime = 3600,   -- 1 hour
}

local task = require "silly.task"

task.fork(function()
    -- Use appropriate connection pool...
    db_low:close()
    db_medium:close()
    db_high:close()
end)
```

---

## Performance Recommendations

### 1. Use Prepared Statements

All queries automatically use prepared statements; identical SQL is reused:

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

    -- Efficient: SQL is identical, reuses prepared statement
    local start = silly.time.now()
    for i = 1, 1000 do
        db:query("INSERT INTO perf_test VALUES (?, ?)", i, i * 10)
    end
    local elapsed = silly.time.now() - start
    print(string.format("Prepared statement: %.2f ms", elapsed))

    db:close()
end)
```

### 2. Batch Operations

Use batch insert for large data operations:

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

    -- Inefficient: Insert row by row
    local start = silly.time.now()
    for i = 1, 100 do
        db:query("INSERT INTO batch_test VALUES (?, ?)", i, i)
    end
    print("Individual inserts:", silly.time.now() - start, "ms")

    -- Efficient: Batch insert (build large SQL)
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

### 3. Proper Connection Pool Configuration

Adjust connection pool size based on concurrency:

```lua validate
local silly = require "silly"
local mysql = require "silly.store.mysql"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    -- Scenario: 10 concurrent queries
    local db = mysql.open {
        addr = "127.0.0.1:3306",
        user = "root",
        password = "root",
        database = "test",
        max_open_conns = 10,  -- Match concurrency
        max_idle_conns = 5,   -- Keep half idle connections
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

### 4. Use Transactions to Reduce Round Trips

Use transactions when multiple operations are needed:

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

    -- Inefficient: Each query commits separately
    local start = silly.time.now()
    for i = 1, 100 do
        db:query("INSERT INTO txn_test VALUES (?, ?)", i, i)
    end
    print("Without transaction:", silly.time.now() - start, "ms")

    db:query("DELETE FROM txn_test")

    -- Efficient: Batch operations in one transaction
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

### 5. Index Optimization

Use indexes appropriately to speed up queries:

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

    -- Create table and add indexes
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

    -- Insert test data
    for i = 1, 1000 do
        db:query(
            "INSERT INTO indexed_test (user_id, email) VALUES (?, ?)",
            i % 100,
            string.format("user%d@example.com", i)
        )
    end

    -- Indexed query (fast)
    local start = silly.time.now()
    local res = db:query("SELECT * FROM indexed_test WHERE user_id = ?", 50)
    print(string.format("Indexed query: %.2f ms, rows: %d",
        silly.time.now() - start, #res))

    -- Use EXPLAIN to analyze query
    res = db:query("EXPLAIN SELECT * FROM indexed_test WHERE user_id = ?", 50)
    print("Query uses index:", res[1].key)

    db:close()
end)
```

---

## See Also

- [silly](../silly.md) - Core module
- [silly.store.redis](./redis.md) - Redis client
- [silly.store.etcd](./etcd.md) - Etcd client
- [silly.sync.waitgroup](../sync/waitgroup.md) - Coroutine wait group
- [silly.encoding.json](../encoding/json.md) - JSON encoding/decoding
