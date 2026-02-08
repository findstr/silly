---
title: 数据库应用教程
icon: database
order: 4
category:
  - 教程
tag:
  - MySQL
  - Redis
  - 数据库
  - 连接池
  - 缓存
---

# 数据库应用教程

本教程将带你构建一个完整的用户管理 API，学习如何在 Silly 框架中集成 MySQL 和 Redis，实现数据持久化和缓存。

## 学习目标

通过本教程，你将学会：

- **MySQL 集成**：使用连接池管理数据库连接
- **CRUD 操作**：实现用户的增删改查
- **Redis 缓存**：提升查询性能
- **事务处理**：保证数据一致性
- **连接池管理**：优化资源使用
- **错误处理**：正确处理数据库错误

## 准备工作

### 安装 MySQL

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

#### 配置 MySQL

```bash
# 登录 MySQL
sudo mysql -u root

# 创建数据库和用户
CREATE DATABASE userdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'silly'@'localhost' IDENTIFIED BY 'silly123';
GRANT ALL PRIVILEGES ON userdb.* TO 'silly'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

### 安装 Redis

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

#### 验证 Redis

```bash
redis-cli ping
# 应该返回 PONG
```

### 创建数据库表

```sql
-- 连接到数据库
mysql -u silly -p userdb

-- 创建用户表
CREATE TABLE users (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(50) NOT NULL,
    email VARCHAR(100) NOT NULL UNIQUE,
    age INT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- 插入测试数据
INSERT INTO users (name, email, age) VALUES
    ('Alice', 'alice@example.com', 30),
    ('Bob', 'bob@example.com', 25);
```

## 实现步骤

### Step 1: 连接 MySQL 数据库

首先，让我们创建 MySQL 连接池并测试连接：

```lua
local silly = require "silly"
local task = require "silly.task"
local mysql = require "silly.store.mysql"

-- 创建 MySQL 连接池
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "silly",
    password = "silly123",
    database = "userdb",
    charset = "utf8mb4",
    max_open_conns = 10,    -- 最大连接数
    max_idle_conns = 5,     -- 最大空闲连接数
    max_idle_time = 600,    -- 空闲连接超时 (10 分钟)
    max_lifetime = 3600,    -- 连接最大生命周期 (1 小时)
}

task.fork(function()
    -- 测试连接
    local ok, err = db:ping()
    if ok then
        print("MySQL 连接成功!")
    else
        print("MySQL 连接失败:", err.message)
        return
    end

    -- 查询所有用户
    local users, err = db:query("SELECT * FROM users")
    if users then
        print("用户数量:", #users)
        for _, user in ipairs(users) do
            print(string.format("  ID=%d, Name=%s, Email=%s, Age=%d",
                user.id, user.name, user.email, user.age))
        end
    else
        print("查询失败:", err.message)
    end

    db:close()
end)
```

**关键点**：
- `mysql.open()` 创建连接池（不会立即连接）
- 首次查询时才会建立实际连接
- `db:ping()` 用于验证连接是否有效
- 所有数据库操作必须在协程中执行（使用 `task.fork()` 创建协程）

### Step 2: 实现用户 CRUD 操作

让我们实现完整的用户管理功能：

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"

-- 创建连接池
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "silly",
    password = "silly123",
    database = "userdb",
    charset = "utf8mb4",
    max_open_conns = 10,
    max_idle_conns = 5,
}

-- 用户操作模块
local User = {}

-- 创建用户
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

-- 根据 ID 获取用户
function User.get_by_id(id)
    local res, err = db:query(
        "SELECT * FROM users WHERE id = ?",
        id
    )
    if not res then
        return nil, err.message
    end
    if #res == 0 then
        return nil, "用户不存在"
    end
    return res[1]
end

-- 获取所有用户
function User.get_all()
    local res, err = db:query("SELECT * FROM users ORDER BY id")
    if not res then
        return nil, err.message
    end
    return res
end

-- 更新用户
function User.update(id, name, email, age)
    local res, err = db:query(
        "UPDATE users SET name = ?, email = ?, age = ? WHERE id = ?",
        name, email, age, id
    )
    if not res then
        return nil, err.message
    end
    if res.affected_rows == 0 then
        return nil, "用户不存在"
    end
    return true
end

-- 删除用户
function User.delete(id)
    local res, err = db:query("DELETE FROM users WHERE id = ?", id)
    if not res then
        return nil, err.message
    end
    if res.affected_rows == 0 then
        return nil, "用户不存在"
    end
    return true
end

-- 测试代码
local task = require "silly.task"
task.fork(function()
    print("=== 测试用户 CRUD 操作 ===\n")

    -- 1. 创建用户
    print("1. 创建用户")
    local user_id, err = User.create("Charlie", "charlie@example.com", 35)
    if user_id then
        print("   用户创建成功, ID:", user_id)
    else
        print("   创建失败:", err)
    end

    -- 2. 获取用户
    print("\n2. 获取用户")
    local user, err = User.get_by_id(user_id)
    if user then
        print(string.format("   ID=%d, Name=%s, Email=%s, Age=%d",
            user.id, user.name, user.email, user.age))
    else
        print("   获取失败:", err)
    end

    -- 3. 获取所有用户
    print("\n3. 获取所有用户")
    local users, err = User.get_all()
    if users then
        print("   用户数量:", #users)
        for _, u in ipairs(users) do
            print(string.format("     ID=%d, Name=%s, Email=%s",
                u.id, u.name, u.email))
        end
    else
        print("   获取失败:", err)
    end

    -- 4. 更新用户
    print("\n4. 更新用户")
    local ok, err = User.update(user_id, "Charlie Wang", "charlie.wang@example.com", 36)
    if ok then
        print("   更新成功")
        local updated_user = User.get_by_id(user_id)
        print(string.format("   更新后: Name=%s, Email=%s, Age=%d",
            updated_user.name, updated_user.email, updated_user.age))
    else
        print("   更新失败:", err)
    end

    -- 5. 删除用户
    print("\n5. 删除用户")
    local ok, err = User.delete(user_id)
    if ok then
        print("   删除成功")
    else
        print("   删除失败:", err)
    end

    db:close()
end)
```

**关键点**：
- 使用预处理语句（`?` 占位符）防止 SQL 注入
- 检查 `affected_rows` 判断操作是否成功
- `last_insert_id` 获取自增主键值
- 统一的错误处理模式

### Step 3: 使用 Redis 缓存

为了提升查询性能，我们添加 Redis 缓存层：

```lua
local silly = require "silly"
local mysql = require "silly.store.mysql"
local redis = require "silly.store.redis"
local json = require "silly.encoding.json"

-- 创建 MySQL 连接池
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "silly",
    password = "silly123",
    database = "userdb",
    charset = "utf8mb4",
    max_open_conns = 10,
    max_idle_conns = 5,
}

-- 创建 Redis 连接
local cache = redis.new {
    addr = "127.0.0.1:6379",
    db = 0,
}

-- 用户操作模块（带缓存）
local User = {}

-- 缓存 Key 生成
local function cache_key(id)
    return "user:" .. id
end

-- 创建用户
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

-- 根据 ID 获取用户（带缓存）
function User.get_by_id(id)
    local key = cache_key(id)

    -- 1. 先从缓存获取
    local ok, cached = cache:get(key)
    if ok and cached then
        print("  [缓存命中] 用户 ID:", id)
        return json.decode(cached)
    end

    print("  [缓存未命中] 查询数据库...")

    -- 2. 缓存未命中，查询数据库
    local res, err = db:query("SELECT * FROM users WHERE id = ?", id)
    if not res then
        return nil, err.message
    end
    if #res == 0 then
        return nil, "用户不存在"
    end

    local user = res[1]

    -- 3. 写入缓存（过期时间 5 分钟）
    cache:setex(key, 300, json.encode(user))

    return user
end

-- 更新用户（清除缓存）
function User.update(id, name, email, age)
    local res, err = db:query(
        "UPDATE users SET name = ?, email = ?, age = ? WHERE id = ?",
        name, email, age, id
    )
    if not res then
        return nil, err.message
    end
    if res.affected_rows == 0 then
        return nil, "用户不存在"
    end

    -- 清除缓存
    cache:del(cache_key(id))
    print("  [缓存已清除] 用户 ID:", id)

    return true
end

-- 删除用户（清除缓存）
function User.delete(id)
    local res, err = db:query("DELETE FROM users WHERE id = ?", id)
    if not res then
        return nil, err.message
    end
    if res.affected_rows == 0 then
        return nil, "用户不存在"
    end

    -- 清除缓存
    cache:del(cache_key(id))
    print("  [缓存已清除] 用户 ID:", id)

    return true
end

-- 测试代码
local task = require "silly.task"
task.fork(function()
    print("=== 测试 Redis 缓存 ===\n")

    -- 创建测试用户
    local user_id = User.create("David", "david@example.com", 28)
    print("创建用户, ID:", user_id, "\n")

    -- 第一次查询（缓存未命中）
    print("1. 第一次查询用户:")
    local user1 = User.get_by_id(user_id)
    print(string.format("   Name=%s, Email=%s\n", user1.name, user1.email))

    -- 第二次查询（缓存命中）
    print("2. 第二次查询用户:")
    local user2 = User.get_by_id(user_id)
    print(string.format("   Name=%s, Email=%s\n", user2.name, user2.email))

    -- 更新用户（缓存被清除）
    print("3. 更新用户:")
    User.update(user_id, "David Lee", "david.lee@example.com", 29)

    -- 更新后查询（缓存未命中，重新加载）
    print("\n4. 更新后查询用户:")
    local user3 = User.get_by_id(user_id)
    print(string.format("   Name=%s, Email=%s\n", user3.name, user3.email))

    -- 清理
    User.delete(user_id)

    db:close()
    cache:close()
end)
```

**关键点**：
- **缓存穿透**：查询前先检查缓存
- **缓存更新**：更新/删除数据时清除缓存
- **缓存过期**：使用 `SETEX` 设置过期时间（300秒）
- **序列化**：使用 JSON 序列化 Lua 表

### Step 4: 完整的 HTTP API

结合前面的 HTTP 教程，构建完整的用户管理 API：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local mysql = require "silly.store.mysql"
local redis = require "silly.store.redis"
local json = require "silly.encoding.json"

-- 创建 MySQL 连接池
local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "silly",
    password = "silly123",
    database = "userdb",
    charset = "utf8mb4",
    max_open_conns = 10,
    max_idle_conns = 5,
}

-- 创建 Redis 连接
local cache = redis.new {
    addr = "127.0.0.1:6379",
    db = 0,
}

-- 用户操作模块
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
        return nil, "用户不存在"
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
        return nil, "用户不存在"
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
        return nil, "用户不存在"
    end
    cache:del("user:" .. id)
    return true
end

-- HTTP 请求处理
local function handle_request(stream)
    local method = stream.method
    local path = stream.path

    -- 记录请求
    print(string.format("[%s] %s %s", os.date("%H:%M:%S"), method, path))

    -- GET /api/users - 获取所有用户
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

    -- GET /api/users/:id - 获取单个用户
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

    -- POST /api/users - 创建用户
    if method == "POST" and path == "/api/users" then
        local body, err = stream:readall()
        if not body then
            local resp = json.encode({success = false, error = "无法读取请求体"})
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
                error = "缺少必填字段: name, email"
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

    -- PUT /api/users/:id - 更新用户
    local update_id = path:match("^/api/users/(%d+)$")
    if method == "PUT" and update_id then
        local body, err = stream:readall()
        if not body then
            local resp = json.encode({success = false, error = "无法读取请求体"})
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
                error = "缺少必填字段: name, email"
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
            local resp = json.encode({success = true, message = "用户更新成功"})
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
        else
            local resp = json.encode({success = false, error = err})
            local status = err == "用户不存在" and 404 or 500
            stream:respond(status, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
        end
        return
    end

    -- DELETE /api/users/:id - 删除用户
    local delete_id = path:match("^/api/users/(%d+)$")
    if method == "DELETE" and delete_id then
        local ok, err = User.delete(tonumber(delete_id))
        if ok then
            local resp = json.encode({success = true, message = "用户删除成功"})
            stream:respond(200, {
                ["content-type"] = "application/json",
                ["content-length"] = #resp,
            })
            stream:closewrite(resp)
        else
            local resp = json.encode({success = false, error = err})
            local status = err == "用户不存在" and 404 or 500
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

-- 启动 HTTP 服务器
http.listen {
    addr = "127.0.0.1:8080",
    handler = handle_request
}

print("===========================================")
print("  用户管理 API 服务器已启动")
print("===========================================")
print("  HTTP: http://127.0.0.1:8080")
print("  MySQL: userdb")
print("  Redis: db=0")
print("===========================================")
```

## 完整代码

将上面的 HTTP API 代码保存为 `user_api.lua`。

## 运行和测试

### 启动服务器

```bash
./silly user_api.lua
```

输出：

```
===========================================
  用户管理 API 服务器已启动
===========================================
  HTTP: http://127.0.0.1:8080
  MySQL: userdb
  Redis: db=0
===========================================
```

### 测试 API

#### 1. 创建用户

```bash
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Emma","email":"emma@example.com","age":27}'
```

响应：

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

#### 2. 获取所有用户

```bash
curl http://127.0.0.1:8080/api/users
```

响应：

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

#### 3. 获取单个用户（测试缓存）

```bash
# 第一次查询（缓存未命中）
curl http://127.0.0.1:8080/api/users/3

# 第二次查询（缓存命中，更快）
curl http://127.0.0.1:8080/api/users/3
```

#### 4. 更新用户

```bash
curl -X PUT http://127.0.0.1:8080/api/users/3 \
  -H "Content-Type: application/json" \
  -d '{"name":"Emma Watson","email":"emma.watson@example.com","age":28}'
```

响应：

```json
{
  "success": true,
  "message": "用户更新成功"
}
```

#### 5. 删除用户

```bash
curl -X DELETE http://127.0.0.1:8080/api/users/3
```

响应：

```json
{
  "success": true,
  "message": "用户删除成功"
}
```

#### 6. 测试错误处理

```bash
# 缺少必填字段
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Test"}'

# 用户不存在
curl http://127.0.0.1:8080/api/users/9999

# 重复邮箱
curl -X POST http://127.0.0.1:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Duplicate","email":"alice@example.com","age":30}'
```

## 代码解析

### 连接池配置

```lua
local db = mysql.open {
    max_open_conns = 10,    -- 最大并发连接数
    max_idle_conns = 5,     -- 保持 5 个空闲连接
    max_idle_time = 600,    -- 空闲 10 分钟后关闭
    max_lifetime = 3600,    -- 连接最多使用 1 小时
}
```

**配置建议**：
- **低负载**：`max_open_conns=5`, `max_idle_conns=2`
- **中等负载**：`max_open_conns=20`, `max_idle_conns=5`
- **高负载**：`max_open_conns=100`, `max_idle_conns=20`

### 事务处理

对于需要保证一致性的操作，使用事务：

```lua
-- 转账示例
function transfer(from_id, to_id, amount)
    local tx<close>, err = db:begin()
    if not tx then
        return nil, "无法开始事务: " .. err.message
    end

    -- 检查余额
    local res, err = tx:query(
        "SELECT balance FROM accounts WHERE id = ?",
        from_id
    )
    if not res or #res == 0 then
        tx:rollback()
        return nil, "账户不存在"
    end

    local balance = tonumber(res[1].balance)
    if balance < amount then
        tx:rollback()
        return nil, "余额不足"
    end

    -- 扣款
    local ok, err = tx:query(
        "UPDATE accounts SET balance = balance - ? WHERE id = ?",
        amount, from_id
    )
    if not ok then
        tx:rollback()
        return nil, "扣款失败: " .. err.message
    end

    -- 到账
    ok, err = tx:query(
        "UPDATE accounts SET balance = balance + ? WHERE id = ?",
        amount, to_id
    )
    if not ok then
        tx:rollback()
        return nil, "到账失败: " .. err.message
    end

    -- 提交事务
    ok, err = tx:commit()
    if not ok then
        return nil, "提交失败: " .. err.message
    end

    return true
end
```

**关键点**：
- 使用 `<close>` 标记自动管理事务生命周期
- 任何错误都要调用 `tx:rollback()`
- 成功后必须调用 `tx:commit()`

### 缓存策略

常见的缓存策略：

#### 1. Cache-Aside（旁路缓存）

```lua
function get_user(id)
    -- 1. 查缓存
    local cached = cache:get("user:" .. id)
    if cached then
        return json.decode(cached)
    end

    -- 2. 查数据库
    local user = db:query("SELECT * FROM users WHERE id = ?", id)[1]

    -- 3. 写缓存
    if user then
        cache:setex("user:" .. id, 300, json.encode(user))
    end

    return user
end
```

#### 2. Write-Through（写穿）

```lua
function update_user(id, data)
    -- 1. 更新数据库
    db:query("UPDATE users SET name = ? WHERE id = ?", data.name, id)

    -- 2. 更新缓存
    local user = db:query("SELECT * FROM users WHERE id = ?", id)[1]
    cache:setex("user:" .. id, 300, json.encode(user))
end
```

#### 3. Write-Behind（写回）

```lua
function update_user(id, data)
    -- 1. 先更新缓存
    cache:setex("user:" .. id, 300, json.encode(data))

    -- 2. 异步写入数据库
    local task = require "silly.task"
    task.fork(function()
        db:query("UPDATE users SET name = ? WHERE id = ?", data.name, id)
    end)
end
```

### 错误处理

统一的错误处理模式：

```lua
-- 封装数据库操作
local function safe_query(query_fn, ...)
    local res, err = query_fn(...)
    if not res then
        print("数据库错误:", err.message)
        if err.errno then
            -- MySQL 错误码
            if err.errno == 1062 then
                return nil, "数据重复"
            elseif err.errno == 1146 then
                return nil, "表不存在"
            end
        end
        return nil, "数据库错误: " .. err.message
    end
    return res
end

-- 使用
local res, err = safe_query(db.query, db, "SELECT * FROM users")
if not res then
    -- 处理错误
    return {success = false, error = err}
end
```

## 扩展练习

### 练习 1: 分页查询

实现用户列表的分页功能：

```lua
-- GET /api/users?page=1&size=10
function User.get_page(page, size)
    page = page or 1
    size = size or 10
    local offset = (page - 1) * size

    -- 查询总数
    local count_res = db:query("SELECT COUNT(*) as total FROM users")
    local total = count_res[1].total

    -- 查询分页数据
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

### 练习 2: 批量操作

实现批量创建用户：

```lua
function User.batch_create(users)
    local tx<close>, err = db:begin()
    if not tx then
        return nil, "无法开始事务"
    end

    local ids = {}
    for _, user in ipairs(users) do
        local res, err = tx:query(
            "INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
            user.name, user.email, user.age
        )
        if not res then
            tx:rollback()
            return nil, "插入失败: " .. err.message
        end
        table.insert(ids, res.last_insert_id)
    end

    local ok, err = tx:commit()
    if not ok then
        return nil, "提交失败: " .. err.message
    end

    return ids
end
```

### 练习 3: 缓存预热

应用启动时预加载热点数据：

```lua
function User.warmup_cache()
    -- 加载最近访问的用户
    local res = db:query([[
        SELECT * FROM users
        ORDER BY updated_at DESC
        LIMIT 100
    ]])

    for _, user in ipairs(res) do
        local key = "user:" .. user.id
        cache:setex(key, 3600, json.encode(user))
    end

    print("缓存预热完成，加载", #res, "个用户")
end

-- 在启动时调用
local task = require "silly.task"
task.fork(function()
    User.warmup_cache()
    -- ...
end)
```

### 练习 4: 缓存更新策略

实现更智能的缓存更新：

```lua
-- 批量删除缓存
function User.invalidate_cache_pattern(pattern)
    local ok, keys = cache:keys(pattern)
    if ok and keys then
        for _, key in ipairs(keys) do
            cache:del(key)
        end
        print("已删除", #keys, "个缓存键")
    end
end

-- 更新用户时，删除相关缓存
function User.update(id, name, email, age)
    local ok, err = db:query(
        "UPDATE users SET name = ?, email = ?, age = ? WHERE id = ?",
        name, email, age, id
    )
    if ok then
        -- 删除单个用户缓存
        cache:del("user:" .. id)
        -- 删除列表缓存
        User.invalidate_cache_pattern("users:list:*")
    end
    return ok, err
end
```

### 练习 5: 性能监控

添加数据库操作性能监控：

```lua
local function timed_query(query_fn, ...)
    local start = silly.time.now()
    local res, err = query_fn(...)
    local elapsed = silly.time.now() - start

    -- 慢查询警告（超过 100ms）
    if elapsed > 100 then
        print(string.format("[慢查询] %.2fms", elapsed))
    end

    return res, err
end

-- 使用
local res, err = timed_query(db.query, db, "SELECT * FROM users")
```

## 下一步

恭喜完成数据库应用教程！你已经掌握了：

- MySQL 连接池管理
- 完整的 CRUD 操作
- Redis 缓存集成
- 事务处理
- HTTP API 开发

接下来可以学习：

- **[WebSocket 聊天室](./websocket-chat.md)**：实现实时通信
- **[集群部署](../reference/net/cluster.md)**：构建分布式系统
- **[MySQL 连接池管理](../guides/mysql-connection-pool.md)**：优化数据库性能

## 参考资料

- [silly.store.mysql API 参考](../reference/store/mysql.md)
- [silly.store.redis API 参考](../reference/store/redis.md)
- [silly.net.http API 参考](../reference/net/http.md)
- [MySQL 8.0 文档](https://dev.mysql.com/doc/)
- [Redis 命令参考](https://redis.io/commands/)
