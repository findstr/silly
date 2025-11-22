---
title: Error Handling Guide
icon: triangle-exclamation
order: 5
category:
  - Guides
tag:
  - Error Handling
  - Exception Catching
  - Debugging
---

# Error Handling Guide

This guide introduces best practices for error handling in the Silly framework, helping you build robust and reliable applications.

## Introduction

### Why Is Error Handling Important?

Good error handling is the foundation of building production-grade applications:

- **Stability**: Prevents program crashes from unhandled errors
- **Debuggability**: Provides clear error messages for quick problem identification
- **User Experience**: Returns friendly error messages instead of exposing internal implementation
- **Maintainability**: Unified error handling patterns make code easier to maintain

### Silly Framework's Error Handling Mechanism

Silly adopts Lua's error handling mechanism:

- **Return Value Pattern**: Functions return `(result, error)` or `(nil, error)`
- **Coroutine Safe**: Errors don't propagate across coroutines, each coroutine handles independently
- **Stack Traces**: Use `silly.pcall()` to automatically generate stack traces

## Error Types

In Silly applications, you'll encounter several types of errors:

### 1. Network Errors

Network operations may fail due to connection failures, timeouts, disconnections, etc.

**Common Scenarios**:
- TCP/UDP connection failures
- HTTP request timeouts
- WebSocket disconnections
- DNS resolution failures

**Example**:

```lua
local silly = require "silly"
local task = require "silly.task"
local tcp = require "silly.net.tcp"

task.fork(function()
    -- Connection may fail
    local conn, err = tcp.connect("127.0.0.1:8080")
    if not conn then
        print("Connection failed:", err)
        -- Handle error: log, retry, return error response, etc.
        return
    end

    -- Reading data may fail
    local data, err = conn:read(1024)
    if err then
        print("Read failed:", err)
        conn:close()
        return
    end

    -- Success handling
    print("Received data:", data)
    conn:close()
end)
```

### 2. Database Errors

Database operations may fail due to connection failures, SQL syntax errors, constraint violations, etc.

**Common Scenarios**:
- Connection pool exhausted
- SQL syntax errors
- Primary key/unique key conflicts
- Foreign key constraint violations
- Deadlocks
- Transaction timeouts

**Example**:

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

task.fork(function()
    -- Query may fail
    local res, err = db:query("SELECT * FROM users WHERE id = ?", 123)
    if not res then
        print("Query failed:", err.message)
        print("Error code:", err.errno)
        print("SQL state:", err.sqlstate)

        -- Handle based on error code
        if err.errno == 1146 then
            print("Table doesn't exist, need to create table")
        elseif err.errno == 2006 then
            print("MySQL connection lost, need to reconnect")
        end
        return
    end

    -- Success handling
    print("Found", #res, "records")
end)
```

### 3. Business Logic Errors

Application's own business rule validation failures.

**Common Scenarios**:
- Parameter validation failures
- Insufficient permissions
- Business state doesn't allow operation
- Resource doesn't exist

**Example**:

```lua
local function transfer_money(from_id, to_id, amount)
    -- Parameter validation
    if amount <= 0 then
        return nil, "Transfer amount must be greater than 0"
    end

    if from_id == to_id then
        return nil, "Cannot transfer to yourself"
    end

    -- Check balance
    local balance = get_balance(from_id)
    if not balance then
        return nil, "Account does not exist"
    end

    if balance < amount then
        return nil, "Insufficient balance"
    end

    -- Execute transfer...
    return true
end

local task = require "silly.task"

-- Usage
task.fork(function()
    local ok, err = transfer_money(1, 2, 100)
    if not ok then
        print("Transfer failed:", err)
        return
    end
    print("Transfer successful")
end)
```

### 4. Timeout Errors

Asynchronous operations time out before completion.

**Common Scenarios**:
- HTTP request timeouts
- Database query timeouts
- RPC call timeouts
- Distributed lock acquisition timeouts

**Example**:

```lua
local silly = require "silly"
local task = require "silly.task"
local http = require "silly.net.http"
local time = require "silly.time"

task.fork(function()
    -- Set timeout
    local timeout = 5000  -- 5 seconds

    local timer = time.after(timeout, function()
        print("HTTP request timeout")
    end)

    local response, err = http.get("http://slow-api.example.com/data")

    -- Cancel timeout timer
    time.cancel(timer)

    if not response then
        print("Request failed:", err)
        return
    end

    print("Response:", response.body)
end)
```

## Error Handling Patterns

### 1. Return Value Check Pattern

This is the most common error handling pattern in Silly.

**Advantages**:
- Clear and easy to understand
- Forces caller to handle errors
- Low performance overhead

**Example**:

```lua
local silly = require "silly"
local task = require "silly.task"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

task.fork(function()
    -- Basic check
    local res, err = db:query("SELECT * FROM users")
    if not res then
        print("Query failed:", err.message)
        return
    end

    -- Chained check
    local user_id = res[1] and res[1].id
    if not user_id then
        print("User not found")
        return
    end

    -- Continue processing
    print("User ID:", user_id)
end)
```

**Best Practices**:

```lua
-- Recommended: Check errors immediately
local res, err = db:query("SELECT * FROM users")
if not res then
    print("Error:", err.message)
    return
end

-- Not recommended: Delayed check
local res, err = db:query("SELECT * FROM users")
-- ... lots of other code ...
if not res then  -- Easy to forget check
    print("Error:", err.message)
end
```

### 2. pcall/xpcall Exception Catching

Used to catch runtime errors and protect critical code sections.

**Advantages**:
- Prevents program crashes
- Catches all types of errors (including Lua runtime errors)
- Generates stack traces

**Example**:

```lua
local silly = require "silly"

local task = require "silly.task"

task.fork(function()
    -- Use silly.pcall to catch errors and generate stack traces
    local ok, result = silly.pcall(function()
        local data = parse_json('{"invalid json}')
        return data
    end)

    if not ok then
        print("Caught error:", result)
        -- result contains complete stack trace
        return
    end

    print("Parse result:", result)
end)
```

**Use Cases**:

```lua
local silly = require "silly"
local json = require "silly.encoding.json"

local task = require "silly.task"

-- 1. Protect critical operations
task.fork(function()
    local ok, err = silly.pcall(function()
        -- Code that may throw exceptions
        local data = json.decode(user_input)
        process_data(data)
    end)

    if not ok then
        print("Processing failed:", err)
    end
end)

-- 2. Protect coroutine main loop
task.fork(function()
    while true do
        local ok, err = silly.pcall(function()
            handle_message()
        end)

        if not ok then
            print("Message processing failed:", err)
            -- Continue processing next message instead of crashing
        end
    end
end)
```

**xpcall Example**:

```lua
local silly = require "silly"

-- Custom error handler
local function error_handler(err)
    print("Caught error:", err)
    print("Stack trace:", debug.traceback())
    -- Log to logging system
    log_error(err)
    return err
end

local task = require "silly.task"

task.fork(function()
    local ok, result = xpcall(function()
        return risky_operation()
    end, error_handler)

    if not ok then
        print("Operation failed")
    end
end)
```

### 3. Error Propagation

Propagate errors up to the caller.

**Example**:

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

-- Low-level function: Return error directly
local function get_user_by_id(id)
    local res, err = db:query("SELECT * FROM users WHERE id = ?", id)
    if not res then
        return nil, "Database error: " .. err.message
    end

    if #res == 0 then
        return nil, "User does not exist"
    end

    return res[1]
end

-- Middle layer function: Add context before propagating
local function get_user_email(id)
    local user, err = get_user_by_id(id)
    if not user then
        return nil, "Failed to get email: " .. err
    end

    if not user.email then
        return nil, "User email not set"
    end

    return user.email
end

local task = require "silly.task"

-- Top-level function: Handle error
task.fork(function()
    local email, err = get_user_email(123)
    if not email then
        print("Error:", err)  -- Contains complete error chain
        -- Return to client
        return {success = false, error = err}
    end

    print("Email:", email)
    return {success = true, email = email}
end)
```

### 4. Error Recovery

Try to recover from errors and continue execution.

**Example**:

```lua
local silly = require "silly"
local tcp = require "silly.net.tcp"
local time = require "silly.time"

-- Connection function with retry
local function connect_with_retry(addr, max_retries, retry_delay)
    max_retries = max_retries or 3
    retry_delay = retry_delay or 1000

    for i = 1, max_retries do
        local fd, err = tcp.connect(addr)
        if fd then
            print("Connection successful")
            return fd
        end

        print(string.format("Connection failed (attempt %d/%d): %s", i, max_retries, err))

        if i < max_retries then
            print(string.format("Waiting %d milliseconds before retry...", retry_delay))
            time.sleep(retry_delay)
            -- Exponential backoff
            retry_delay = retry_delay * 2
        end
    end

    return nil, "Connection failed, max retries reached"
end

local task = require "silly.task"

task.fork(function()
    local fd, err = connect_with_retry("127.0.0.1:8080", 5, 1000)
    if not fd then
        print("Unable to connect:", err)
        return
    end

    -- Use connection...
    tcp.close(fd)
end)
```

**Database Connection Recovery**:

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "root",
    database = "test",
}

-- Query function with reconnect
local function safe_query(sql, ...)
    local max_retries = 2

    for i = 1, max_retries do
        local res, err = db:query(sql, ...)

        if res then
            return res
        end

        -- Check if it's a connection error
        if err.errno == 2006 or err.errno == 2013 then
            print("MySQL connection lost, trying to reconnect...")
            -- Here you can recreate the connection pool
            -- In production, should have reconnect mechanism
        else
            -- Non-connection error, return directly
            return nil, err
        end
    end

    return nil, {message = "Query failed, connection cannot be recovered"}
end

local task = require "silly.task"

task.fork(function()
    local res, err = safe_query("SELECT * FROM users")
    if not res then
        print("Query failed:", err.message)
        return
    end

    print("Query successful, record count:", #res)
end)
```

## Coroutine Error Handling

### Errors in task.fork

Errors in coroutines don't affect other coroutines, but need to be handled properly.

**Problem Example**:

```lua
local silly = require "silly"
local task = require "silly.task"

task._start(function()
    print("Main coroutine starts")

    -- Errors in child coroutine don't propagate to main coroutine
    task.fork(function()
        error("Error in child coroutine")  -- This will crash the child coroutine
    end)

    task.fork(function()
        print("Other coroutine runs normally")  -- This coroutine is unaffected
    end)

    print("Main coroutine continues")
end)
```

**Solution**: Catch errors at coroutine entry point

```lua
local silly = require "silly"

local task = require "silly.task"

-- Wrapper function: Catch all errors in coroutine
local function safe_fork(func)
    task.fork(function()
        local ok, err = silly.pcall(func)
        if not ok then
            print("Coroutine error:", err)
            -- Log error
            silly.error(err)
        end
    end)
end

-- Use safe fork
safe_fork(function()
    error("This error will be caught")
end)

safe_fork(function()
    print("Normal execution")
end)
```

### Error Logging

Use `silly.error()` to log errors and stack traces.

```lua
local silly = require "silly"

task.fork(function()
    local ok, err = silly.pcall(function()
        -- Code that may error
        local result = risky_operation()
        return result
    end)

    if not ok then
        -- Use silly.error to log error (includes stack trace)
        silly.error(err)
    end
end)
```

### Prevent Coroutine Crashes

Protect the main loop in long-running coroutines.

```lua
local silly = require "silly"
local time = require "silly.time"

-- Worker coroutine template
local function worker_loop()
    while true do
        local ok, err = silly.pcall(function()
            -- Execute work
            process_task()
        end)

        if not ok then
            print("Task processing failed:", err)
            silly.error(err)
            -- Short delay before continuing, avoid fast loop
            time.sleep(100)
        end

        -- Wait for next task
        time.sleep(1000)
    end
end

local task = require "silly.task"

task.fork(worker_loop)
print("Worker coroutine started")
```

## HTTP API Error Response

### Unified Error Format

Define a unified error response format for APIs.

```lua
local silly = require "silly"
local http = require "silly.net.http"
local json = require "silly.encoding.json"

-- Unified response format
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

-- Send JSON response
local function send_json(stream, status, data)
    local body = json.encode(data)
    stream:respond(status, {
        ["content-type"] = "application/json",
        ["content-length"] = #body,
    })
    stream:closewrite(body)
end

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        -- Success response
        if stream.path == "/api/users" then
            send_json(stream, 200, success_response({
                users = {
                    {id = 1, name = "Alice"},
                    {id = 2, name = "Bob"},
                }
            }))
            return
        end

        -- Error response
        send_json(stream, 404, error_response(
            "NOT_FOUND",
            "Resource not found",
            {path = stream.path}
        ))
    end
}

print("HTTP server started")
```

## Reference

- [silly API Reference](/en/reference/silly.md) - Core error handling functions
- [silly.net.http API Reference](/en/reference/net/http.md) - HTTP error handling
- [silly.store.mysql API Reference](/en/reference/store/mysql.md) - Database error handling
- [silly.store.redis API Reference](/en/reference/store/redis.md) - Redis error handling
- [Lua Error Handling](https://www.lua.org/pil/8.4.html) - Lua official documentation
