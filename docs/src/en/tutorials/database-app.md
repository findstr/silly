---
title: Database Application Tutorial
icon: database
order: 4
category:
  - Tutorial
tag:
  - MySQL
  - Redis
  - Database
  - Connection Pool
  - Cache
---

# Database Application Tutorial

This tutorial will guide you through building a complete user management API, learning how to integrate MySQL and Redis in the Silly framework for data persistence and caching.

## Learning Objectives

Through this tutorial, you will learn:

- **MySQL Integration**: Managing database connections using connection pools
- **CRUD Operations**: Implementing user create, read, update, and delete
- **Redis Caching**: Improving query performance
- **Transaction Handling**: Ensuring data consistency
- **Connection Pool Management**: Optimizing resource usage
- **Error Handling**: Properly handling database errors

## Prerequisites

### Install MySQL

#### Ubuntu/Debian

```bash
sudo apt-get update
sudo apt-get install mysql-server
sudo systemctl start mysql
```

#### macOS

```bash
brew install mysql
brew services start mysql
```

#### Configure MySQL

```bash
# Login to MySQL
sudo mysql -u root

# Create database and user
CREATE DATABASE userdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'silly'@'localhost' IDENTIFIED BY 'silly123';
GRANT ALL PRIVILEGES ON userdb.* TO 'silly'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

### Install Redis

#### Ubuntu/Debian

```bash
sudo apt-get install redis-server
sudo systemctl start redis
```

#### macOS

```bash
brew install redis
brew services start redis
```

#### Verify Redis

```bash
redis-cli ping
# Should return PONG
```

### Create Database Tables

```sql
-- Connect to database
mysql -u silly -p userdb

-- Create users table
CREATE TABLE users (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(50) NOT NULL,
    email VARCHAR(100) NOT NULL UNIQUE,
    age INT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- Insert test data
INSERT INTO users (name, email, age) VALUES
    ('Alice', 'alice@example.com', 30),
    ('Bob', 'bob@example.com', 25);
```

## Implementation Steps

### Step 1: Connect to MySQL Database

First, let's create a MySQL connection pool and test the connection:

```lua
local silly = require "silly"
local task = require "silly.task"
local mysql = require "silly.store.mysql"

-- Create MySQL connection pool
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "silly",
    password = "silly123",
    database = "userdb",
    charset = "utf8mb4",
    max_open_conns = 10,    -- Maximum connections
    max_idle_conns = 5,     -- Maximum idle connections
    max_idle_time = 600,    -- Idle connection timeout (10 minutes)
    max_lifetime = 3600,    -- Connection maximum lifetime (1 hour)
}

task.fork(function()
    -- Test connection
    local ok, err = db:ping()
    if ok then
        print("MySQL connection successful!")
    else
        print("MySQL connection failed:", err.message)
        return
    end

    -- Query all users
    local users, err = db:query("SELECT * FROM users")
    if users then
        print("User count:", #users)
        for _, user in ipairs(users) do
            print(string.format("  ID=%d, Name=%s, Email=%s, Age=%d",
                user.id, user.name, user.email, user.age))
        end
    else
        print("Query failed:", err.message)
    end

    db:close()
end)
```

**Key Points**:
- `mysql.open()` creates a connection pool (does not connect immediately)
- Actual connection is established on first query
- `db:ping()` is used to validate connection
- All database operations must be executed in coroutines (use `task.fork()` to create coroutines)

### Step 2: Implement User CRUD Operations

Let's implement complete user management functionality:

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

-- Create connection pool
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "silly",
    password = "silly123",
    database = "userdb",
    charset = "utf8mb4",
    max_open_conns = 10,
    max_idle_conns = 5,
}

-- User operations module
local User = {}

-- Create user
function User.create(name, email, age)
    local res, err = db:query(
        "INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
        name, email, age
    )
    if not res then
        return nil, err.message
    end
    return res.last_insert_id
end

-- Get user by ID
function User.get_by_id(id)
    local res, err = db:query(
        "SELECT * FROM users WHERE id = ?",
        id
    )
    if not res then
        return nil, err.message
    end
    if #res == 0 then
        return nil, "User not found"
    end
    return res[1]
end

-- Get all users
function User.get_all()
    local res, err = db:query("SELECT * FROM users ORDER BY id")
    if not res then
        return nil, err.message
    end
    return res
end

-- Update user
function User.update(id, name, email, age)
    local res, err = db:query(
        "UPDATE users SET name = ?, email = ?, age = ? WHERE id = ?",
        name, email, age, id
    )
    if not res then
        return nil, err.message
    end
    if res.affected_rows == 0 then
        return nil, "User not found"
    end
    return true
end

-- Delete user
function User.delete(id)
    local res, err = db:query("DELETE FROM users WHERE id = ?", id)
    if not res then
        return nil, err.message
    end
    if res.affected_rows == 0 then
        return nil, "User not found"
    end
    return true
end

-- Test code
local task = require "silly.task"
task.fork(function()
    print("=== Testing User CRUD Operations ===\n")

    -- 1. Create user
    print("1. Create user")
    local user_id, err = User.create("Charlie", "charlie@example.com", 35)
    if user_id then
        print("   User created successfully, ID:", user_id)
    else
        print("   Creation failed:", err)
    end

    -- 2. Get user
    print("\n2. Get user")
    local user, err = User.get_by_id(user_id)
    if user then
        print(string.format("   ID=%d, Name=%s, Email=%s, Age=%d",
            user.id, user.name, user.email, user.age))
    else
        print("   Get failed:", err)
    end

    -- 3. Get all users
    print("\n3. Get all users")
    local users, err = User.get_all()
    if users then
        print("   User count:", #users)
        for _, u in ipairs(users) do
            print(string.format("     ID=%d, Name=%s, Email=%s",
                u.id, u.name, u.email))
        end
    else
        print("   Get failed:", err)
    end

    -- 4. Update user
    print("\n4. Update user")
    local ok, err = User.update(user_id, "Charlie Wang", "charlie.wang@example.com", 36)
    if ok then
        print("   Update successful")
        local updated_user = User.get_by_id(user_id)
        print(string.format("   After update: Name=%s, Email=%s, Age=%d",
            updated_user.name, updated_user.email, updated_user.age))
    else
        print("   Update failed:", err)
    end

    -- 5. Delete user
    print("\n5. Delete user")
    local ok, err = User.delete(user_id)
    if ok then
        print("   Delete successful")
    else
        print("   Delete failed:", err)
    end

    db:close()
end)
```

**Key Points**:
- Use prepared statements (`?` placeholders) to prevent SQL injection
- Check `affected_rows` to determine if operation succeeded
- `last_insert_id` gets auto-increment primary key value
- Unified error handling pattern

### Step 3: Use Redis Caching

To improve query performance, let's add a Redis caching layer:

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"
local redis = require "silly.store.redis"
local json = require "silly.encoding.json"

-- Create MySQL connection pool
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "silly",
    password = "silly123",
    database = "userdb",
    charset = "utf8mb4",
    max_open_conns = 10,
    max_idle_conns = 5,
}

-- Create Redis connection
local cache = redis.new {
    addr = "127.0.0.1:6379",
    db = 0,
}

-- User operations module (with caching)
local User = {}

-- Cache key generation
local function cache_key(id)
    return "user:" .. id
end

-- Create user
function User.create(name, email, age)
    local res, err = db:query(
        "INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
        name, email, age
    )
    if not res then
        return nil, err.message
    end
    return res.last_insert_id
end

-- Get user by ID (with caching)
function User.get_by_id(id)
    local key = cache_key(id)

    -- 1. Get from cache first
    local ok, cached = cache:get(key)
    if ok and cached then
        print("  [Cache hit] User ID:", id)
        return json.decode(cached)
    end

    print("  [Cache miss] Querying database...")

    -- 2. Cache miss, query database
    local res, err = db:query("SELECT * FROM users WHERE id = ?", id)
    if not res then
        return nil, err.message
    end
    if #res == 0 then
        return nil, "User not found"
    end

    local user = res[1]

    -- 3. Write to cache (5 minute expiration)
    cache:setex(key, 300, json.encode(user))

    return user
end

-- Update user (clear cache)
function User.update(id, name, email, age)
    local res, err = db:query(
        "UPDATE users SET name = ?, email = ?, age = ? WHERE id = ?",
        name, email, age, id
    )
    if not res then
        return nil, err.message
    end
    if res.affected_rows == 0 then
        return nil, "User not found"
    end

    -- Clear cache
    cache:del(cache_key(id))
    print("  [Cache cleared] User ID:", id)

    return true
end

-- Delete user (clear cache)
function User.delete(id)
    local res, err = db:query("DELETE FROM users WHERE id = ?", id)
    if not res then
        return nil, err.message
    end
    if res.affected_rows == 0 then
        return nil, "User not found"
    end

    -- Clear cache
    cache:del(cache_key(id))
    print("  [Cache cleared] User ID:", id)

    return true
end

-- Test code
local task = require "silly.task"
task.fork(function()
    print("=== Testing Redis Cache ===\n")

    -- Create test user
    local user_id = User.create("David", "david@example.com", 28)
    print("Created user, ID:", user_id, "\n")

    -- First query (cache miss)
    print("1. First query:")
    local user1 = User.get_by_id(user_id)
    print(string.format("   Name=%s, Email=%s\n", user1.name, user1.email))

    -- Second query (cache hit)
    print("2. Second query:")
    local user2 = User.get_by_id(user_id)
    print(string.format("   Name=%s, Email=%s\n", user2.name, user2.email))

    -- Update user (cache cleared)
    print("3. Update user:")
    User.update(user_id, "David Lee", "david.lee@example.com", 29)

    -- Query after update (cache miss, reload)
    print("\n4. Query after update:")
    local user3 = User.get_by_id(user_id)
    print(string.format("   Name=%s, Email=%s\n", user3.name, user3.email))

    -- Cleanup
    User.delete(user_id)

    db:close()
    cache:close()
end)
```

**Key Points**:
- **Cache-through**: Check cache before querying
- **Cache Update**: Clear cache on update/delete
- **Cache Expiration**: Use `SETEX` to set expiration time (300 seconds)
- **Serialization**: Use JSON to serialize Lua tables

### Step 4: Complete HTTP API

Combining with the previous HTTP tutorial, let's build a complete user management API:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local mysql = require "silly.store.mysql"
local redis = require "silly.store.redis"
local json = require "silly.encoding.json"

-- Create MySQL connection pool
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "silly",
    password = "silly123",
    database = "userdb",
    charset = "utf8mb4",
    max_open_conns = 10,
    max_idle_conns = 5,
}

-- Create Redis connection
local cache = redis.new {
    addr = "127.0.0.1:6379",
    db = 0,
}

-- User operations module
local User = {}

function User.create(name, email, age)
    local res, err = db:query(
        "INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
        name, email, age
    )
    if not res then
        return nil, err.message
    end
    return res.last_insert_id
end

function User.get_by_id(id)
    local key = "user:" .. id
    local ok, cached = cache:get(key)
    if ok and cached then
        return json.decode(cached)
    end

    local res, err = db:query("SELECT * FROM users WHERE id = ?", id)
    if not res then
        return nil, err.message
    end
    if #res == 0 then
        return nil, "User not found"
    end

    local user = res[1]
    cache:setex(key, 300, json.encode(user))
    return user
end

function User.get_all()
    local res, err = db:query("SELECT * FROM users ORDER BY id")
    if not res then
        return nil, err.message
    end
    return res
end

function User.update(id, name, email, age)
    local res, err = db:query(
        "UPDATE users SET name = ?, email = ?, age = ? WHERE id = ?",
        name, email, age, id
    )
    if not res then
        return nil, err.message
    end
    if res.affected_rows == 0 then
        return nil, "User not found"
    end
    cache:del("user:" .. id)
    return true
end

function User.delete(id)
    local res, err = db:query("DELETE FROM users WHERE id = ?", id)
    if not res then
        return nil, err.message
    end
    if res.affected_rows == 0 then
        return nil, "User not found"
    end
    cache:del("user:" .. id)
    return true
end

-- HTTP request handling
local function handle_request(stream)
    local method = stream.method
    local path = stream.path

    -- Log request
    print(string.format("[%s] %s %s", os.date("%H:%M:%S"), method, path))

    -- GET /api/users - Get all users
    if method == "GET" and path == "/api/users" then
        local users, err = User.get_all()
        if users then
            local body = json.encode({success = true, data = users})
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #body,
            })
            stream:closewrite(body)
        else
            local body = json.encode({success = false, error = err})
            stream:respond(500, {
                ["content-type"] = "application/json",
                ["content-length"] = #body,
            })
            stream:closewrite(body)
        end
        return
    end

    -- GET /api/users/:id - Get single user
    local user_id = path:match("^/api/users/(%d+)$")
    if method == "GET" and user_id then
        local user, err = User.get_by_id(tonumber(user_id))
        if user then
            local body = json.encode({success = true, data = user})
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #body,
            })
            stream:closewrite(body)
        else
            local body = json.encode({success = false, error = err})
            stream:respond(404, {
                ["content-type"] = "application/json",
                ["content-length"] = #body,
            })
            stream:closewrite(body)
        end
        return
    end

    -- POST /api/users - Create user
    if method == "POST" and path == "/api/users" then
        local body, err = stream:readall()
        if not body then
            local resp = json.encode({success = false, error = "Cannot read request body"})
            stream:respond(400, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
            return
        end

        local data = json.decode(body)
        if not data or not data.name or not data.email then
            local resp = json.encode({
                success = false,
                error = "Missing required fields: name, email"
            })
            stream:respond(400, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
            return
        end

        local id, err = User.create(data.name, data.email, data.age or nil)
        if id then
            local resp = json.encode({
                success = true,
                data = {id = id, name = data.name, email = data.email, age = data.age}
            })
            stream:respond(201, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
        else
            local resp = json.encode({success = false, error = err})
            stream:respond(500, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
        end
        return
    end

    -- PUT /api/users/:id - Update user
    local update_id = path:match("^/api/users/(%d+)$")
    if method == "PUT" and update_id then
        local body, err = stream:readall()
        if not body then
            local resp = json.encode({success = false, error = "Cannot read request body"})
            stream:respond(400, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
            return
        end

        local data = json.decode(body)
        if not data or not data.name or not data.email then
            local resp = json.encode({
                success = false,
                error = "Missing required fields: name, email"
            })
            stream:respond(400, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
            return
        end

        local ok, err = User.update(tonumber(update_id), data.name, data.email, data.age)
        if ok then
            local resp = json.encode({success = true, message = "User updated successfully"})
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
        else
            local resp = json.encode({success = false, error = err})
            local status = err == "User not found" and 404 or 500
            stream:respond(status, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
        end
        return
    end

    -- DELETE /api/users/:id - Delete user
    local delete_id = path:match("^/api/users/(%d+)$")
    if method == "DELETE" and delete_id then
        local ok, err = User.delete(tonumber(delete_id))
        if ok then
            local resp = json.encode({success = true, message = "User deleted successfully"})
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
        else
            local resp = json.encode({success = false, error = err})
            local status = err == "User not found" and 404 or 500
            stream:respond(status, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
        end
        return
    end

    -- 404 Not Found
    local resp = json.encode({success = false, error = "Not Found"})
    stream:respond(404, {
        ["content-type"] = "application/json",
        ["content-length"] = #resp,
    })
    stream:closewrite(resp)
end

-- Start HTTP server
http.listen {
    addr = "127.0.0.1:8080",
    handler = handle_request
}

print("===========================================")
print("  User Management API Server Started")
print("===========================================")
print("  HTTP: http://127.0.0.1:8080")
print("  MySQL: userdb")
print("  Redis: db=0")
print("===========================================")
```

## Complete Code

Save the above HTTP API code as `user_api.lua`.

## Running and Testing

### Start Server

```bash
./silly user_api.lua
```

Output:

```
===========================================
  User Management API Server Started
===========================================
  HTTP: http://127.0.0.1:8080
  MySQL: userdb
  Redis: db=0
===========================================
```

### Test API

#### 1. Create User

```bash
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Emma","email":"emma@example.com","age":27}'
```

Response:

```json
{
  "success": true,
  "data": {
    "id": 3,
    "name": "Emma",
    "email": "emma@example.com",
    "age": 27
  }
}
```

#### 2. Get All Users

```bash
curl http://127.0.0.1:8080/api/users
```

Response:

```json
{
  "success": true,
  "data": [
    {"id": 1, "name": "Alice", "email": "alice@example.com", "age": 30, ...},
    {"id": 2, "name": "Bob", "email": "bob@example.com", "age": 25, ...},
    {"id": 3, "name": "Emma", "email": "emma@example.com", "age": 27, ...}
  ]
}
```

#### 3. Get Single User (Test Caching)

```bash
# First query (cache miss)
curl http://127.0.0.1:8080/api/users/3

# Second query (cache hit, faster)
curl http://127.0.0.1:8080/api/users/3
```

#### 4. Update User

```bash
curl -X PUT http://127.0.0.1:8080/api/users/3 \
  -H "Content-Type: application/json" \
  -d '{"name":"Emma Watson","email":"emma.watson@example.com","age":28}'
```

Response:

```json
{
  "success": true,
  "message": "User updated successfully"
}
```

#### 5. Delete User

```bash
curl -X DELETE http://127.0.0.1:8080/api/users/3
```

Response:

```json
{
  "success": true,
  "message": "User deleted successfully"
}
```

#### 6. Test Error Handling

```bash
# Missing required fields
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Test"}'

# User not found
curl http://127.0.0.1:8080/api/users/9999

# Duplicate email
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Duplicate","email":"alice@example.com","age":30}'
```

## Code Analysis

### Connection Pool Configuration

```lua
local db = mysql.open {
    max_open_conns = 10,    -- Maximum concurrent connections
    max_idle_conns = 5,     -- Keep 5 idle connections
    max_idle_time = 600,    -- Close after 10 minutes idle
    max_lifetime = 3600,    -- Connection max lifetime 1 hour
}
```

**Configuration Recommendations**:
- **Low Load**: `max_open_conns=5`, `max_idle_conns=2`
- **Medium Load**: `max_open_conns=20`, `max_idle_conns=5`
- **High Load**: `max_open_conns=100`, `max_idle_conns=20`

### Transaction Handling

For operations requiring consistency guarantees, use transactions:

```lua
-- Transfer example
function transfer(from_id, to_id, amount)
    local tx<close>, err = db:begin()
    if not tx then
        return nil, "Cannot begin transaction: " .. err.message
    end

    -- Check balance
    local res, err = tx:query(
        "SELECT balance FROM accounts WHERE id = ?",
        from_id
    )
    if not res or #res == 0 then
        tx:rollback()
        return nil, "Account not found"
    end

    local balance = tonumber(res[1].balance)
    if balance < amount then
        tx:rollback()
        return nil, "Insufficient balance"
    end

    -- Deduct
    local ok, err = tx:query(
        "UPDATE accounts SET balance = balance - ? WHERE id = ?",
        amount, from_id
    )
    if not ok then
        tx:rollback()
        return nil, "Deduction failed: " .. err.message
    end

    -- Credit
    ok, err = tx:query(
        "UPDATE accounts SET balance = balance + ? WHERE id = ?",
        amount, to_id
    )
    if not ok then
        tx:rollback()
        return nil, "Credit failed: " .. err.message
    end

    -- Commit transaction
    ok, err = tx:commit()
    if not ok then
        return nil, "Commit failed: " .. err.message
    end

    return true
end
```

**Key Points**:
- Use `<close>` marker to automatically manage transaction lifecycle
- Call `tx:rollback()` on any error
- Must call `tx:commit()` on success

### Caching Strategies

Common caching strategies:

#### 1. Cache-Aside

```lua
function get_user(id)
    -- 1. Check cache
    local cached = cache:get("user:" .. id)
    if cached then
        return json.decode(cached)
    end

    -- 2. Query database
    local user = db:query("SELECT * FROM users WHERE id = ?", id)[1]

    -- 3. Write cache
    if user then
        cache:setex("user:" .. id, 300, json.encode(user))
    end

    return user
end
```

#### 2. Write-Through

```lua
function update_user(id, data)
    -- 1. Update database
    db:query("UPDATE users SET name = ? WHERE id = ?", data.name, id)

    -- 2. Update cache
    local user = db:query("SELECT * FROM users WHERE id = ?", id)[1]
    cache:setex("user:" .. id, 300, json.encode(user))
end
```

#### 3. Write-Behind

```lua
function update_user(id, data)
    -- 1. Update cache first
    cache:setex("user:" .. id, 300, json.encode(data))

    -- 2. Asynchronously write to database
    local task = require "silly.task"
    task.fork(function()
        db:query("UPDATE users SET name = ? WHERE id = ?", data.name, id)
    end)
end
```

### Error Handling

Unified error handling pattern:

```lua
-- Wrap database operations
local function safe_query(query_fn, ...)
    local res, err = query_fn(...)
    if not res then
        print("Database error:", err.message)
        if err.errno then
            -- MySQL error codes
            if err.errno == 1062 then
                return nil, "Duplicate data"
            elseif err.errno == 1146 then
                return nil, "Table does not exist"
            end
        end
        return nil, "Database error: " .. err.message
    end
    return res
end

-- Usage
local res, err = safe_query(db.query, db, "SELECT * FROM users")
if not res then
    -- Handle error
    return {success = false, error = err}
end
```

## Extension Exercises

### Exercise 1: Pagination

Implement pagination for user list:

```lua
-- GET /api/users?page=1&size=10
function User.get_page(page, size)
    page = page or 1
    size = size or 10
    local offset = (page - 1) * size

    -- Query total count
    local count_res = db:query("SELECT COUNT(*) as total FROM users")
    local total = count_res[1].total

    -- Query paginated data
    local res, err = db:query(
        "SELECT * FROM users ORDER BY id LIMIT ? OFFSET ?",
        size, offset
    )
    if not res then
        return nil, err.message
    end

    return {
        data = res,
        page = page,
        size = size,
        total = total,
        total_pages = math.ceil(total / size)
    }
end
```

### Exercise 2: Batch Operations

Implement batch user creation:

```lua
function User.batch_create(users)
    local tx<close>, err = db:begin()
    if not tx then
        return nil, "Cannot begin transaction"
    end

    local ids = {}
    for _, user in ipairs(users) do
        local res, err = tx:query(
            "INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
            user.name, user.email, user.age
        )
        if not res then
            tx:rollback()
            return nil, "Insert failed: " .. err.message
        end
        table.insert(ids, res.last_insert_id)
    end

    local ok, err = tx:commit()
    if not ok then
        return nil, "Commit failed: " .. err.message
    end

    return ids
end
```

### Exercise 3: Cache Warmup

Preload hot data on application startup:

```lua
function User.warmup_cache()
    -- Load recently accessed users
    local res = db:query([[
        SELECT * FROM users
        ORDER BY updated_at DESC
        LIMIT 100
    ]])

    for _, user in ipairs(res) do
        local key = "user:" .. user.id
        cache:setex(key, 3600, json.encode(user))
    end

    print("Cache warmup complete, loaded", #res, "users")
end

-- Call on startup
local task = require "silly.task"
task.fork(function()
    User.warmup_cache()
    -- ...
end)
```

### Exercise 4: Cache Update Strategy

Implement smarter cache updates:

```lua
-- Batch delete cache
function User.invalidate_cache_pattern(pattern)
    local ok, keys = cache:keys(pattern)
    if ok and keys then
        for _, key in ipairs(keys) do
            cache:del(key)
        end
        print("Deleted", #keys, "cache keys")
    end
end

-- Delete related caches when updating user
function User.update(id, name, email, age)
    local ok, err = db:query(
        "UPDATE users SET name = ?, email = ?, age = ? WHERE id = ?",
        name, email, age, id
    )
    if ok then
        -- Delete single user cache
        cache:del("user:" .. id)
        -- Delete list caches
        User.invalidate_cache_pattern("users:list:*")
    end
    return ok, err
end
```

### Exercise 5: Performance Monitoring

Add database operation performance monitoring:

```lua
local function timed_query(query_fn, ...)
    local start = silly.time.now()
    local res, err = query_fn(...)
    local elapsed = silly.time.now() - start

    -- Slow query warning (over 100ms)
    if elapsed > 100 then
        print(string.format("[Slow Query] %.2fms", elapsed))
    end

    return res, err
end

-- Usage
local res, err = timed_query(db.query, db, "SELECT * FROM users")
```

## Next Steps

Congratulations on completing the Database Application tutorial! You have mastered:

- MySQL connection pool management
- Complete CRUD operations
- Redis cache integration
- Transaction handling
- HTTP API development

Next, you can learn:

- **[WebSocket Chat Room](./websocket-chat.md)**: Implement real-time communication
- **[Cluster Deployment](../reference/net/cluster.md)**: Build distributed systems
- **[MySQL Connection Pool Management](../guides/mysql-connection-pool.md)**: Optimize database performance

## References

- [silly.store.mysql API Reference](../reference/store/mysql.md)
- [silly.store.redis API Reference](../reference/store/redis.md)
- [silly.net.http API Reference](../reference/net/http.md)
- [MySQL 8.0 Documentation](https://dev.mysql.com/doc/)
- [Redis Command Reference](https://redis.io/commands/)
