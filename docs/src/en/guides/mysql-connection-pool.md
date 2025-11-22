---
title: MySQL Connection Pool Management Guide
icon: database
order: 2
category:
  - Guides
tag:
  - MySQL
  - Connection Pool
  - Performance
  - Monitoring
---

# MySQL Connection Pool Management Guide

This guide focuses on solving common issues in MySQL connection pool usage, providing practical solutions for configuration optimization, problem diagnosis, and performance tuning.

## Why Do You Need a Connection Pool?

### The Value of Connection Pooling

**1. Reduce Connection Overhead**

Establishing a MySQL connection requires:
- TCP three-way handshake (network round trip)
- MySQL authentication (username/password verification)
- Character set negotiation
- Session state initialization

This typically takes 50-200ms, while reusing a connection from the pool only takes 1-5ms.

**2. Control Resource Usage**

MySQL server has a connection limit (default 151):
```sql
SHOW VARIABLES LIKE 'max_connections';
-- +-------------------+-------+
-- | Variable_name     | Value |
-- +-------------------+-------+
-- | max_connections   | 151   |
-- +-------------------+-------+
```

Connection pooling ensures you don't exceed the server limit.

**3. Improve Concurrency**

```lua
-- Without connection pool: Establish new connection per request (slow)
function handle_request()
    local db = mysql.open{...}  -- 100ms connection overhead
    local result = db:query("SELECT * FROM users")  -- 10ms query
    db:close()
    return result
end

-- With connection pool: Reuse connections (fast)
local pool = mysql.open{...}  -- Establish once

function handle_request()
    local result = pool:query("SELECT * FROM users")  -- 10ms query
    return result
end
```

## Connection Pool Configuration

### Basic Configuration Parameters

```lua
local mysql = require "silly.store.mysql"

local pool = mysql.open {
    -- Connection information
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    charset = "utf8mb4",

    -- Connection pool parameters
    max_open_conns = 20,    -- Maximum open connections (0 = unlimited)
    max_idle_conns = 5,     -- Maximum idle connections (0 = unlimited)
    max_idle_time = 600,    -- Idle connection timeout (seconds, 0 = no timeout)
    max_lifetime = 3600,    -- Maximum connection lifetime (seconds, 0 = unlimited)
    max_packet_size = 1024 * 1024,  -- Maximum packet size (bytes)
}
```

### Parameter Details

#### max_open_conns (Maximum Connections)

Controls the maximum number of concurrent connections to the database.

```lua
-- Set to 20: At most 20 concurrent queries
max_open_conns = 20

-- The 21st request will wait until a connection is released
```

**How to Choose**:
```
max_open_conns = Concurrent Queries × 1.2
```

Examples:
- 100 QPS, each query 50ms → concurrency = 100 × 0.05 = 5 → set to **10**
- 1000 QPS, each query 100ms → concurrency = 1000 × 0.1 = 100 → set to **120**

#### max_idle_conns (Maximum Idle Connections)

Controls the number of idle connections kept in the pool.

```lua
-- Set to 5: Pool keeps 5 idle connections
max_idle_conns = 5

-- Idle connections exceeding 5 will be closed
```

**How to Choose**:
```
max_idle_conns = max_open_conns × 0.3
```

Recommendations:
- **Low load**: `max_idle_conns = 2-5` (save resources)
- **High load**: `max_idle_conns = max_open_conns × 0.5` (fast response)

#### max_idle_time (Idle Timeout)

Maximum time an idle connection stays in the pool.

```lua
-- Set to 600 seconds (10 minutes)
max_idle_time = 600

-- Connections idle for more than 10 minutes will be closed
```

**How to Choose**:
- **Frequent access**: 600-1800 seconds (10-30 minutes)
- **Occasional access**: 60-300 seconds (1-5 minutes)
- **Need to detect disconnections**: 300 seconds (MySQL `wait_timeout` is typically 28800 seconds)

#### max_lifetime (Connection Lifetime)

Maximum lifetime of a connection (regardless of whether it's idle).

```lua
-- Set to 3600 seconds (1 hour)
max_lifetime = 3600

-- Connections used for more than 1 hour will be closed and recreated
```

**How to Choose**:
- **Prevent connection leaks**: 3600 seconds (1 hour)
- **Frequent recreation**: 1800 seconds (30 minutes)
- **Long-term stability**: 7200 seconds (2 hours)

**Note**: Should be less than MySQL's `wait_timeout`.

### Recommended Configurations for Different Loads

#### Low Load Applications (Internal Tools, Admin Dashboards)

```lua
local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    charset = "utf8mb4",

    max_open_conns = 5,       -- At most 5 concurrent queries
    max_idle_conns = 2,       -- Keep 2 idle connections
    max_idle_time = 300,      -- 5 minute idle timeout
    max_lifetime = 1800,      -- 30 minute maximum lifetime
}
```

**Use Cases**:
- Concurrent requests < 10
- QPS < 100
- Query response time < 100ms

#### Medium Load Applications (Small Web Services)

```lua
local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    charset = "utf8mb4",

    max_open_conns = 20,      -- At most 20 concurrent queries
    max_idle_conns = 5,       -- Keep 5 idle connections
    max_idle_time = 600,      -- 10 minute idle timeout
    max_lifetime = 3600,      -- 1 hour maximum lifetime
}
```

**Use Cases**:
- Concurrent requests 10-50
- QPS 100-1000
- Query response time < 500ms

#### High Load Applications (Large API Services)

```lua
local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    charset = "utf8mb4",

    max_open_conns = 100,     -- At most 100 concurrent queries
    max_idle_conns = 30,      -- Keep 30 idle connections
    max_idle_time = 300,      -- 5 minute idle timeout (fast release)
    max_lifetime = 3600,      -- 1 hour maximum lifetime
}
```

**Use Cases**:
- Concurrent requests > 50
- QPS > 1000
- Need fast response

**Note**: Ensure MySQL `max_connections` > 100.

### Configuration Optimization

#### Adjust Based on MySQL Limits

```lua
-- Query MySQL's maximum connections
-- mysql> SHOW VARIABLES LIKE 'max_connections';
-- Assume returns 151

local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",

    -- Leave 20% headroom for other clients
    max_open_conns = math.floor(151 * 0.8),  -- 120
    max_idle_conns = 30,
}
```

#### Avoid Connection Waste

```lua
-- Not recommended: Too many idle connections
local pool = mysql.open {
    max_open_conns = 100,
    max_idle_conns = 100,  -- ❌ Wastes resources
    max_idle_time = 0,     -- ❌ Never timeout
}

-- Recommended: Reasonable configuration
local pool = mysql.open {
    max_open_conns = 100,
    max_idle_conns = 20,   -- ✅ Keep reasonable amount
    max_idle_time = 300,   -- ✅ 5 minute timeout
}
```

#### Dynamic Adjustment

Dynamically adjust based on monitoring data:

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

-- Switch configuration based on time or load
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

## Common Issues

### Issue 1: Too many connections

#### Error Message

```
MySQL error: Too many connections (errno: 1040)
```

#### Root Cause

1. **Application connections exceed MySQL limit**
   ```sql
   SHOW VARIABLES LIKE 'max_connections';
   -- Default 151
   ```

2. **Connection leak**: Connections not properly closed

3. **Misconfiguration**: `max_open_conns` set too high

#### Solutions

**Solution 1: Increase MySQL Maximum Connections**

```bash
# Edit MySQL configuration file
sudo vim /etc/mysql/my.cnf

# Add or modify
[mysqld]
max_connections = 500

# Restart MySQL
sudo systemctl restart mysql
```

Or modify dynamically (lost after restart):
```sql
SET GLOBAL max_connections = 500;
```

**Solution 2: Check for Connection Leaks**

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
    -- ❌ Wrong example: Transaction connection not closed
    local tx = pool:begin()
    tx:query("SELECT 1")
    -- Forgot to call tx:close() or tx:commit()
    -- Connection leak!
end)

task.fork(function()
    -- ✅ Correct example: Use <close> for automatic management
    local tx<close> = pool:begin()
    tx:query("SELECT 1")
    tx:commit()
    -- tx automatically closed, connection returned to pool
end)
```

**Solution 3: Reduce max_open_conns**

```lua
-- Assume 5 application instances
-- MySQL max_connections = 151
-- Each instance at most: 151 / 5 = 30

local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    max_open_conns = 30,  -- Don't exceed allocated amount
}
```

### Issue 2: Connection Leak Detection

#### Symptoms

- Application performance degrades after running for a while
- MySQL connection count continuously grows
- "Too many connections" error occurs

#### Detection Methods

**Method 1: Monitor Active Connections**

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

-- Periodically check connection count
task.fork(function()
    while true do
        local res = pool:query("SHOW PROCESSLIST")
        local conn_count = #res
        print(string.format("[%s] Active connections: %d",
            os.date("%Y-%m-%d %H:%M:%S"), conn_count))

        -- Warning threshold
        if conn_count > 100 then
            print("⚠️ Warning: Connection count too high, possible connection leak!")
        end

        time.sleep(10000)  -- Check every 10 seconds
    end
end)
```

**Method 2: Track Transaction Connections**

```lua
local transaction_counter = 0

-- Wrap pool:begin()
local original_begin = pool.begin

function pool:begin()
    local tx, err = original_begin(self)
    if not tx then
        return nil, err
    end

    transaction_counter = transaction_counter + 1
    local tx_id = transaction_counter
    print(string.format("Transaction #%d started", tx_id))

    -- Wrap tx:close()
    local original_close = tx.close
    function tx:close()
        print(string.format("Transaction #%d ended", tx_id))
        return original_close(self)
    end

    return tx, err
end
```

#### Prevention Measures

**1. Always Use `<close>` Marker**

```lua
-- ✅ Recommended
task.fork(function()
    local tx<close> = pool:begin()
    -- tx will be automatically closed regardless of errors
    tx:query("UPDATE users SET age = 30 WHERE id = 1")
    tx:commit()
end)
```

**2. Use pcall for Protection**

```lua
task.fork(function()
    local tx<close> = pool:begin()

    local ok, err = pcall(function()
        tx:query("UPDATE users SET age = 30 WHERE id = 1")
        tx:query("UPDATE accounts SET balance = 100 WHERE user_id = 1")
        tx:commit()
    end)

    if not ok then
        print("Transaction failed:", err)
        tx:rollback()
    end
end)
```

**3. Set Timeouts**

```lua
local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    max_lifetime = 600,  -- Connection used at most 10 minutes
    max_idle_time = 300, -- Close after 5 minutes idle
}
```

### Issue 3: Connection Timeout

#### Error Message

```
MySQL error: Lost connection to MySQL server during query
```

#### Root Cause

1. **Unstable network**: Connection interrupted
2. **Query takes too long**: Exceeds MySQL timeout setting
3. **Connection idle too long**: Exceeds `wait_timeout`

#### Solutions

**Solution 1: Increase MySQL Timeout**

```sql
-- Check current timeout settings
SHOW VARIABLES LIKE '%timeout%';

-- Increase timeout (8 hours)
SET GLOBAL wait_timeout = 28800;
SET GLOBAL interactive_timeout = 28800;
```

**Solution 2: Use ping to Detect Connection**

```lua
local silly = require "silly"
local task = require "silly.task"
local mysql = require "silly.store.mysql"

local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
}

-- Ping before query
task.fork(function()
    local ok, err = pool:ping()
    if not ok then
        print("Connection lost:", err.message)
        -- Recreate connection pool
        pool:close()
        pool = mysql.open {...}
    end

    -- Execute query
    local res = pool:query("SELECT * FROM users")
end)
```

**Solution 3: Set Reasonable Connection Lifetime**

```lua
local pool = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",

    -- Less than MySQL wait_timeout (default 28800 seconds)
    max_lifetime = 3600,   -- 1 hour
    max_idle_time = 600,   -- 10 minutes
}
```

### Issue 4: Reconnection Mechanism

#### Implement Auto-Reconnect

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
    local retry_delay = 1000  -- 1 second

    for attempt = 1, max_retries do
        local res, err = self.pool:query(sql, ...)

        if res then
            -- Success, reset reconnect counter
            self.reconnect_attempts = 0
            return res, nil
        end

        -- Check if connection error
        if err and (err.message:match("Lost connection") or
                   err.message:match("MySQL server has gone away")) then
            print(string.format("Connection lost, attempting reconnect (%d/%d)...",
                attempt, max_retries))

            -- Try to reconnect
            local ok = self:reconnect()
            if ok then
                -- Retry query
                time.sleep(retry_delay)
            else
                break
            end
        else
            -- Other error, return directly
            return nil, err
        end
    end

    return nil, {message = "Query failed, maximum retries reached"}
end

function DBPool:reconnect()
    self.reconnect_attempts = self.reconnect_attempts + 1

    if self.reconnect_attempts > self.max_reconnect_attempts then
        print("❌ Maximum reconnect attempts exceeded, giving up")
        return false
    end

    -- Close old connection pool
    pcall(function()
        self.pool:close()
    end)

    -- Create new connection pool
    local ok, err = pcall(function()
        self.pool = mysql.open(self.config)
        local res, err = self.pool:ping()
        if not res then
            error(err.message)
        end
    end)

    if ok then
        print("✅ Reconnect successful")
        return true
    else
        print("❌ Reconnect failed:", err)
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
    -- Automatically handles reconnection
    local res, err = db:query("SELECT * FROM users")
    if res then
        print("Query successful:", #res)
    else
        print("Query failed:", err.message)
    end

    db:close()
end)
```

## Best Practices

### 1. Connection Lifecycle Management

#### Create Connection Pool at Application Startup

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

-- Global connection pool (created at application startup)
local DB = mysql.open {
    addr = "127.0.0.1:3306",
    user = "app_user",
    password = "app_password",
    database = "mydb",
    max_open_conns = 20,
    max_idle_conns = 5,
}

-- Export interface
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

#### Graceful Shutdown at Application Exit

```lua
local silly = require "silly"
local signal = require "silly.signal"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

-- Listen for exit signal
signal.signal("INT", function()
    print("Exit signal received, shutting down...")

    -- Close connection pool
    pool:close()
    print("Connection pool closed")

    -- Exit application
    os.exit(0)
end)

print("Application started, press Ctrl+C to exit")
```

### 2. Transaction Handling

#### Use `<close>` for Automatic Management

```lua
local silly = require "silly"
local task = require "silly.task"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

task.fork(function()
    -- Use <close> to ensure transaction connection is closed
    local tx<close> = pool:begin()

    -- Execute operations
    tx:query("UPDATE accounts SET balance = balance - 100 WHERE id = 1")
    tx:query("UPDATE accounts SET balance = balance + 100 WHERE id = 2")

    -- Commit transaction
    local ok, err = tx:commit()
    if not ok then
        print("Commit failed:", err.message)
        tx:rollback()
    end

    -- tx automatically closed
end)
```

#### Transaction Error Handling

```lua
local function transfer(from_id, to_id, amount)
    local tx<close>, err = pool:begin()
    if not tx then
        return nil, "Cannot begin transaction: " .. err.message
    end

    -- Use pcall to catch all errors
    local ok, err = pcall(function()
        -- Debit
        local res, err = tx:query(
            "UPDATE accounts SET balance = balance - ? WHERE id = ?",
            amount, from_id
        )
        if not res then
            error(err.message)
        end

        -- Credit
        res, err = tx:query(
            "UPDATE accounts SET balance = balance + ? WHERE id = ?",
            amount, to_id
        )
        if not res then
            error(err.message)
        end

        -- Commit
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

### 3. Avoid Long Transactions

Long transactions occupy connections, causing other requests to wait.

#### Problem Example

```lua
-- ❌ Wrong: Long transaction
task.fork(function()
    local tx<close> = pool:begin()

    -- Many queries (occupies connection for long time)
    for i = 1, 10000 do
        tx:query("INSERT INTO logs VALUES (?, ?)", i, "log message")
    end

    tx:commit()
end)
```

#### Improvement Solutions

**Solution 1: Batch Processing**

```lua
-- ✅ Correct: Batch processing
task.fork(function()
    local batch_size = 100

    for batch = 1, 100 do
        local tx<close> = pool:begin()

        -- Process 100 items per batch
        for i = 1, batch_size do
            local id = (batch - 1) * batch_size + i
            tx:query("INSERT INTO logs VALUES (?, ?)", id, "log message")
        end

        tx:commit()
        -- Release connection for other requests
    end
end)
```

**Solution 2: Bulk Insert**

```lua
-- ✅ Correct: Bulk insert
task.fork(function()
    local values = {}
    for i = 1, 10000 do
        table.insert(values, string.format("(%d, 'log message')", i))
    end

    -- Single SQL to insert all data
    pool:query("INSERT INTO logs VALUES " .. table.concat(values, ","))
end)
```

### 4. Warm Up Connection Pool

Establish connections in advance at application startup to avoid slow first request.

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

-- Warm up connection pool
local function warmup_pool(count)
    print("Warming up connection pool...")

    local tasks = {}
    for i = 1, count do
        table.insert(tasks, task.fork(function()
            local ok, err = pool:ping()
            if ok then
                print(string.format("Connection #%d ready", i))
            else
                print(string.format("Connection #%d failed: %s", i, err.message))
            end
        end))
    end

    -- Wait for all connections to establish
    for _, task in ipairs(tasks) do
        silly.wait(task)
    end

    print(string.format("Connection pool warmup complete, %d connections established", count))
end

-- Warm up 5 connections
warmup_pool(5)

print("Application started")
```

## Monitoring Metrics

### 1. Active Connection Count

Monitor MySQL active connections in real-time.

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

-- Monitor active connections
task.fork(function()
    while true do
        local res = pool:query([[
            SELECT COUNT(*) as count
            FROM information_schema.PROCESSLIST
            WHERE User = 'app_user'
        ]])

        if res then
            local active_conns = res[1].count
            print(string.format("[%s] Active connections: %d",
                os.date("%H:%M:%S"), active_conns))

            -- Alert
            if active_conns > 50 then
                print("⚠️ Warning: Too many active connections")
            end
        end

        silly.sleep(5000)  -- Check every 5 seconds
    end
end)
```

### 2. Query Wait Time

Monitor time spent waiting for connections.

```lua
local function timed_query(pool, sql, ...)
    local wait_start = silly.time.now()

    -- Execute query (may need to wait for connection)
    local query_start = silly.time.now()
    local res, err = pool:query(sql, ...)
    local query_end = silly.time.now()

    local wait_time = query_start - wait_start
    local query_time = query_end - query_start

    -- Log slow wait
    if wait_time > 100 then
        print(string.format("⚠️ Slow wait: Waited %.2fms for connection", wait_time))
    end

    -- Log slow query
    if query_time > 1000 then
        print(string.format("⚠️ Slow query: %.2fms - %s", query_time, sql))
    end

    return res, err
end

-- Usage
task.fork(function()
    local res, err = timed_query(pool, "SELECT * FROM users WHERE id = ?", 1)
end)
```

### 3. Error Rate

Monitor error rate of database operations.

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
        print("Query error:", err.message)
    end

    return res, err
end

-- Periodically output statistics
task.fork(function()
    while true do
        silly.sleep(60000)  -- Every minute

        if stats.total > 0 then
            local error_rate = (stats.error / stats.total) * 100
            print(string.format(
                "Statistics: Total=%d, Success=%d, Failed=%d, Error rate=%.2f%%",
                stats.total, stats.success, stats.error, error_rate
            ))

            if error_rate > 5 then
                print("⚠️ Warning: Error rate too high")
            end

            -- Reset statistics
            stats.total = 0
            stats.success = 0
            stats.error = 0
        end
    end
end)
```

### 4. Complete Monitoring Dashboard

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

local metrics = {
    queries = {total = 0, success = 0, error = 0},
    wait_times = {},
    query_times = {},
}

-- Wrap query function
local function monitored_query(sql, ...)
    local wait_start = silly.time.now()
    local query_start = silly.time.now()
    local res, err = pool:query(sql, ...)
    local query_end = silly.time.now()

    -- Record metrics
    metrics.queries.total = metrics.queries.total + 1
    if res then
        metrics.queries.success = metrics.queries.success + 1
    else
        metrics.queries.error = metrics.queries.error + 1
    end

    table.insert(metrics.wait_times, query_start - wait_start)
    table.insert(metrics.query_times, query_end - query_start)

    -- Keep last 100 records
    if #metrics.wait_times > 100 then
        table.remove(metrics.wait_times, 1)
    end
    if #metrics.query_times > 100 then
        table.remove(metrics.query_times, 1)
    end

    return res, err
end

-- Calculate average
local function average(tbl)
    if #tbl == 0 then return 0 end
    local sum = 0
    for _, v in ipairs(tbl) do
        sum = sum + v
    end
    return sum / #tbl
end

-- Periodically output monitoring report
task.fork(function()
    while true do
        silly.sleep(60000)  -- Every minute

        print("\n========== Database Monitoring Report ==========")
        print(string.format("Time: %s", os.date("%Y-%m-%d %H:%M:%S")))
        print(string.format("Total queries: %d", metrics.queries.total))
        print(string.format("Success: %d (%.1f%%)",
            metrics.queries.success,
            metrics.queries.total > 0 and (metrics.queries.success / metrics.queries.total * 100) or 0
        ))
        print(string.format("Failed: %d (%.1f%%)",
            metrics.queries.error,
            metrics.queries.total > 0 and (metrics.queries.error / metrics.queries.total * 100) or 0
        ))
        print(string.format("Average wait time: %.2fms", average(metrics.wait_times)))
        print(string.format("Average query time: %.2fms", average(metrics.query_times)))
        print("====================================\n")

        -- Reset counters
        metrics.queries = {total = 0, success = 0, error = 0}
    end
end)

-- Export interface
return {
    query = monitored_query,
}
```

## Performance Tuning

### 1. Connection Count Calculation Formula

Calculate optimal connection count based on application characteristics.

#### Formula

```
max_open_conns = (QPS × Average Query Time) ÷ 1000 × Safety Factor

Where:
- QPS: Queries Per Second
- Average Query Time: In milliseconds
- Safety Factor: 1.2-1.5 (reserve headroom)
```

#### Example Calculations

**Scenario 1: Simple Queries**
- QPS: 1000
- Average query time: 10ms
- Safety factor: 1.2

```
max_open_conns = (1000 × 10) ÷ 1000 × 1.2 = 12
```

**Scenario 2: Complex Queries**
- QPS: 500
- Average query time: 100ms
- Safety factor: 1.5

```
max_open_conns = (500 × 100) ÷ 1000 × 1.5 = 75
```

#### Actual Measurement

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

-- Test query performance
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
    print(string.format("Average query time: %.2fms", avg_time))

    -- Calculate recommended connection count
    local recommended = math.ceil((qps * avg_time) / 1000 * 1.2)
    print(string.format("Recommended max_open_conns: %d", recommended))
end

benchmark()
```

### 2. Batch Operation Optimization

#### Batch Insert

```lua
-- ❌ Slow: Insert one by one
for i = 1, 1000 do
    pool:query("INSERT INTO logs VALUES (?, ?)", i, "message")
end

-- ✅ Fast: Batch insert
local values = {}
for i = 1, 1000 do
    table.insert(values, string.format("(%d, 'message')", i))
end
pool:query("INSERT INTO logs VALUES " .. table.concat(values, ","))
```

#### Batch Query (IN Clause)

```lua
-- ❌ Slow: Query one by one
local users = {}
for _, id in ipairs(user_ids) do
    local res = pool:query("SELECT * FROM users WHERE id = ?", id)
    if res and #res > 0 then
        table.insert(users, res[1])
    end
end

-- ✅ Fast: Batch query
local ids = table.concat(user_ids, ",")
local users = pool:query("SELECT * FROM users WHERE id IN (" .. ids .. ")")
```

### 3. Prepared Statement Caching

Silly automatically caches prepared statements, reusing the same SQL.

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

task.fork(function()
    -- First execution: Prepare statement
    pool:query("SELECT * FROM users WHERE id = ?", 1)

    -- Subsequent executions: Reuse prepared statement (faster)
    for i = 2, 1000 do
        pool:query("SELECT * FROM users WHERE id = ?", i)
    end
end)
```

**Optimization Recommendations**:
- Use parameterized queries (`?` placeholders)
- Avoid dynamically concatenating SQL
- Use same SQL for queries with same structure

```lua
-- ❌ Not recommended: Cannot reuse prepared statement
pool:query("SELECT * FROM users WHERE id = " .. id)

-- ✅ Recommended: Reuse prepared statement
pool:query("SELECT * FROM users WHERE id = ?", id)
```

### 4. Index Optimization

Ensure queries use indexes.

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local pool = mysql.open {...}

-- Use EXPLAIN to analyze query
task.fork(function()
    local sql = "SELECT * FROM users WHERE email = ?"
    local res = pool:query("EXPLAIN " .. sql, "user@example.com")

    print("Query analysis:")
    for _, row in ipairs(res) do
        print(string.format("  type: %s, key: %s, rows: %d",
            row.type, row.key or "NULL", row.rows))
    end

    -- Check if index is used
    if res[1].key == nil then
        print("⚠️ Warning: Query not using index, consider adding index")
        print("  Suggestion: CREATE INDEX idx_email ON users(email);")
    end
end)
```

## References

- [silly.store.mysql API Reference](/en/reference/store/mysql.md)
- [Database Application Tutorial](/en/tutorials/database-app.md)
- [MySQL Connection Pooling Best Practices](https://dev.mysql.com/doc/connector-j/8.0/en/connector-j-usagenotes-j2ee-concepts-connection-pooling.html)
- [Go database/sql Package Design Philosophy](https://go.dev/doc/database/manage-connections)
