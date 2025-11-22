# Redis 客户端

`silly.store.redis` 模块提供了一个基于连接池的异步 Redis 客户端，支持所有标准 Redis 命令，并实现了 RESP（Redis 序列化协议）协议。它使用连接复用和自动重连机制，为高性能应用提供可靠的 Redis 访问。

## 模块导入

```lua validate
local redis = require "silly.store.redis"
local silly = require "silly"

-- 创建 Redis 客户端
local db = redis.new {
    addr = "127.0.0.1:6379",
    auth = "password",  -- 可选
    db = 0,             -- 可选，数据库索引
}

local task = require "silly.task"

-- 使用 Redis 客户端
task.fork(function()
    local ok, res = db:ping()
    assert(ok and res == "PONG")
    db:close()
end)
```

## 核心概念

### RESP 协议

Redis 客户端实现了完整的 RESP（Redis Serialization Protocol）协议，支持以下数据类型：

- **简单字符串** (`+`): 返回状态回复，如 `"OK"`, `"PONG"`
- **错误** (`-`): 返回错误信息
- **整数** (`:`): 返回数值结果
- **批量字符串** (`$`): 返回字符串或 nil
- **数组** (`*`): 返回多个值的数组

### 连接池机制

模块实现了内部请求队列机制（socketq）：

- **单连接模式**: 所有请求共享同一个 TCP 连接
- **请求排队**: 多个协程的请求在单个连接上按顺序执行
- **自动重连**: 连接断开时自动重新连接
- **认证支持**: 支持密码认证和数据库选择

**注意**: socketq 不是传统意义上的连接池，它是在**单个 TCP 连接**上对请求进行排队，以实现并发请求（pipeline）。所有操作共用一个连接，而不是维护多个连接的池。

### 命令调用方式

Redis 客户端支持两种命令调用方式：

1. **方法调用**: `db:set("key", "value")`
2. **call 方法**: `db:call("set", "key", "value")`
3. **表参数**: `db:set({"key", "value"})`

所有 Redis 命令都会自动转换为大写发送到服务器。

## API 参考

### redis.new(config)

创建一个新的 Redis 客户端实例。

- **参数**:
  - `config`: `table` - 配置表
    - `addr`: `string` (必需) - Redis 服务器地址，格式为 `"host:port"`
    - `auth`: `string|nil` (可选) - Redis 密码，用于 AUTH 命令
    - `db`: `integer|nil` (可选) - 数据库索引，用于 SELECT 命令
- **返回值**:
  - `silly.store.redis` - Redis 客户端对象
- **异步**: 否
- **示例**:

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

-- 基本连接
local db1 = redis.new {
    addr = "127.0.0.1:6379",
}

-- 带密码和数据库选择
local db2 = redis.new {
    addr = "127.0.0.1:6379",
    auth = "mypassword",
    db = 1,
}

local task = require "silly.task"

task.fork(function()
    local ok = db1:ping()
    assert(ok)
    local ok = db2:ping()
    assert(ok)
    db1:close()
    db2:close()
end)
```

### db:close()

关闭 Redis 连接并释放资源。

- **参数**: 无
- **返回值**: 无
- **异步**: 否
- **示例**:

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    db:set("temp", "value")
    db:close()  -- 关闭连接
end)
```

### db:call(cmd, ...)

通用命令调用接口，可用于调用任何 Redis 命令。

- **参数**:
  - `cmd`: `string` - Redis 命令名称
  - `...`: 命令参数（可变参数或表）
- **返回值**:
  - 成功: `true, result` - 命令执行成功，result 为命令结果
  - 失败: `false, error` - 命令执行失败，error 为错误信息
- **异步**: 是（会挂起协程）
- **示例**:

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- 使用 call 方法
    local ok, res = db:call("set", "key1", "value1")
    assert(ok and res == "OK")

    local ok, res = db:call("get", "key1")
    assert(ok and res == "value1")

    -- 使用表参数
    local ok, res = db:call("mset", {"k1", "v1", "k2", "v2"})
    assert(ok)

    db:close()
end)
```

### db:pipeline(requests, results)

批量执行 Redis 命令，所有命令在一次网络往返中完成。

- **参数**:
  - `requests`: `table` - 命令数组，每个元素是一个命令参数数组
  - `results`: `table` (可选) - 结果数组，如果提供则填充所有命令的返回值
- **返回值**:
  - 不提供 results: `boolean, result` - 返回最后一个命令的结果
  - 提供 results: `true, count` - 返回 true 和结果数量
- **异步**: 是（会挂起协程）
- **示例**:

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- 不获取结果的 pipeline
    local ok, res = db:pipeline({
        {"SET", "p1", "v1"},
        {"SET", "p2", "v2"},
        {"SET", "p3", "v3"},
    })
    assert(ok)

    -- 获取所有结果
    local results = {}
    local ok, count = db:pipeline({
        {"GET", "p1"},
        {"GET", "p2"},
        {"GET", "p3"},
    }, results)
    assert(ok and count == 6)  -- 3个命令，每个2个返回值 (ok, value)
    assert(results[2] == "v1")
    assert(results[4] == "v2")
    assert(results[6] == "v3")

    db:close()
end)
```

### db:select(dbid)

切换数据库。注意：此方法已废弃，应在创建客户端时指定数据库。

- **参数**:
  - `dbid`: `integer` - 数据库索引
- **返回值**: 抛出错误
- **异步**: 否
- **说明**: 此方法会抛出错误，提示应在 `redis.new()` 时指定 `db` 参数

### Redis 命令方法

所有标准 Redis 命令都可以作为方法调用。命令名会自动转换为大写。以下是常用命令的分类说明：

#### 字符串操作

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    -- SET/GET
    db:set("mykey", "myvalue")
    local ok, val = db:get("mykey")
    assert(val == "myvalue")

    -- INCR/DECR
    db:set("counter", 0)
    local ok, val = db:incr("counter")
    assert(val == 1)

    -- MSET/MGET
    db:mset("k1", "v1", "k2", "v2")
    local ok, vals = db:mget("k1", "k2")
    assert(vals[1] == "v1" and vals[2] == "v2")

    db:close()
end)
```

#### 哈希操作

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    -- HSET/HGET
    db:hset("user:1", "name", "Alice")
    local ok, name = db:hget("user:1", "name")
    assert(name == "Alice")

    -- HMSET/HMGET
    db:hmset("user:2", "name", "Bob", "age", "30")
    local ok, vals = db:hmget("user:2", "name", "age")
    assert(vals[1] == "Bob" and vals[2] == "30")

    -- HGETALL
    local ok, all = db:hgetall("user:2")
    assert(all[1] == "name" and all[2] == "Bob")

    db:close()
end)
```

#### 列表操作

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    -- LPUSH/RPUSH
    db:del("mylist")
    db:lpush("mylist", "a")
    db:rpush("mylist", "b")

    -- LPOP/RPOP
    local ok, val = db:lpop("mylist")
    assert(val == "a")

    -- LRANGE
    db:rpush("list2", "1", "2", "3")
    local ok, vals = db:lrange("list2", 0, -1)
    assert(#vals == 3)

    db:close()
end)
```

#### 集合操作

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    -- SADD/SMEMBERS
    db:del("myset")
    db:sadd("myset", "a", "b", "c")
    local ok, members = db:smembers("myset")
    assert(#members == 3)

    -- SISMEMBER
    local ok, is_member = db:sismember("myset", "a")
    assert(is_member == 1)

    db:close()
end)
```

#### 有序集合操作

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    -- ZADD
    db:del("leaderboard")
    db:zadd("leaderboard", 100, "player1", 200, "player2")

    -- ZRANGE
    local ok, players = db:zrange("leaderboard", 0, -1)
    assert(players[1] == "player1")

    -- ZREVRANGE (带分数)
    local ok, data = db:zrevrange("leaderboard", 0, -1, "WITHSCORES")
    assert(data[1] == "player2" and data[2] == "200")

    db:close()
end)
```

#### 键操作

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    -- EXISTS
    db:set("testkey", "value")
    local ok, exists = db:exists("testkey")
    assert(exists == 1)

    -- DEL
    local ok, count = db:del("testkey")
    assert(count == 1)

    -- KEYS
    db:set("key1", "v1")
    db:set("key2", "v2")
    local ok, keys = db:keys("key*")
    assert(#keys >= 2)

    -- EXPIRE/TTL
    db:set("expkey", "value")
    db:expire("expkey", 60)
    local ok, ttl = db:ttl("expkey")
    assert(ttl > 0 and ttl <= 60)

    db:close()
end)
```

#### 服务器命令

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    -- PING
    local ok, res = db:ping()
    assert(ok and res == "PONG")

    -- ECHO
    local ok, res = db:echo("hello")
    assert(res == "hello")

    -- DBSIZE
    local ok, size = db:dbsize()
    assert(type(size) == "number")

    -- TYPE
    db:set("strkey", "value")
    local ok, typ = db:type("strkey")
    assert(typ == "string")

    db:close()
end)
```

## 使用示例

### 基本键值操作

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- 设置和获取
    db:set("username", "alice")
    local ok, name = db:get("username")
    assert(name == "alice")

    -- 检查键是否存在
    local ok, exists = db:exists("username")
    assert(exists == 1)

    -- 删除键
    local ok, count = db:del("username")
    assert(count == 1)

    db:close()
end)
```

### 使用哈希存储对象

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- 存储用户信息
    local user_id = "user:1001"
    db:hmset(user_id,
        "name", "Alice",
        "email", "alice@example.com",
        "age", "25"
    )

    -- 获取单个字段
    local ok, name = db:hget(user_id, "name")
    assert(name == "Alice")

    -- 获取所有字段
    local ok, fields = db:hgetall(user_id)
    -- fields = {"name", "Alice", "email", "alice@example.com", "age", "25"}
    assert(fields[1] == "name")

    -- 增加数值字段
    db:hincrby(user_id, "age", 1)
    local ok, age = db:hget(user_id, "age")
    assert(age == "26")

    db:close()
end)
```

### 批量操作（Pipeline）

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- 批量设置多个键（无需返回值）
    db:pipeline({
        {"SET", "batch:1", "value1"},
        {"SET", "batch:2", "value2"},
        {"SET", "batch:3", "value3"},
        {"SET", "batch:4", "value4"},
        {"SET", "batch:5", "value5"},
    })

    -- 批量获取并处理结果
    local results = {}
    db:pipeline({
        {"GET", "batch:1"},
        {"GET", "batch:2"},
        {"GET", "batch:3"},
        {"GET", "batch:4"},
        {"GET", "batch:5"},
    }, results)

    -- results 为 {true, "value1", true, "value2", ...}
    for i = 2, #results, 2 do
        assert(results[i] == "value" .. (i // 2))
    end

    db:close()
end)
```

### 计数器实现

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    local counter_key = "page:views"

    -- 初始化计数器
    db:set(counter_key, 0)

    -- 增加计数
    local ok, count = db:incr(counter_key)
    assert(count == 1)

    -- 增加指定数值
    local ok, count = db:incrby(counter_key, 10)
    assert(count == 11)

    -- 获取当前值
    local ok, count = db:get(counter_key)
    assert(count == "11")

    db:close()
end)
```

### 排行榜实现

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    local leaderboard = "game:leaderboard"

    -- 添加玩家分数
    db:zadd(leaderboard, 1000, "player1")
    db:zadd(leaderboard, 1500, "player2")
    db:zadd(leaderboard, 1200, "player3")

    -- 获取排名前 3 的玩家（降序）
    local ok, top3 = db:zrevrange(leaderboard, 0, 2, "WITHSCORES")
    -- top3 = {"player2", "1500", "player3", "1200", "player1", "1000"}
    assert(top3[1] == "player2")

    -- 获取玩家排名（从 0 开始）
    local ok, rank = db:zrevrank(leaderboard, "player1")
    assert(rank == 2)  -- 第三名

    -- 增加玩家分数
    db:zincrby(leaderboard, 500, "player1")
    local ok, score = db:zscore(leaderboard, "player1")
    assert(score == "1500")

    db:close()
end)
```

### 分布式锁（简单实现）

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    local lock_key = "lock:resource"
    local lock_value = "unique_token_123"
    local ttl = 30  -- 锁过期时间

    -- 尝试获取锁（NX = 不存在时设置，EX = 过期时间）
    local ok, res = db:set(lock_key, lock_value, "NX", "EX", ttl)

    if res == "OK" then
        -- 成功获取锁，执行业务逻辑
        -- ... do work ...

        -- 释放锁（使用 Lua 脚本确保原子性）
        local script = [[
            if redis.call("get", KEYS[1]) == ARGV[1] then
                return redis.call("del", KEYS[1])
            else
                return 0
            end
        ]]
        local ok, released = db:eval(script, 1, lock_key, lock_value)
        assert(released == 1)
    else
        -- 获取锁失败
        print("Failed to acquire lock")
    end

    db:close()
end)
```

### 发布订阅（需要多个连接）

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

-- 订阅者
local subscriber = redis.new {
    addr = "127.0.0.1:6379",
}

-- 发布者
local publisher = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- 注意：subscribe 会阻塞连接，实际使用需要独立连接
    -- 这里仅作为示例展示命令调用方式

    -- 发布消息
    local ok, receivers = publisher:publish("news", "Hello World")
    -- receivers 为接收到消息的订阅者数量

    publisher:close()
    subscriber:close()
end)
```

### Lua 脚本执行

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- 使用 EVAL 执行 Lua 脚本
    local script = [[
        local key = KEYS[1]
        local value = ARGV[1]
        redis.call('SET', key, value)
        return redis.call('GET', key)
    ]]

    local ok, result = db:eval(script, 1, "mykey", "myvalue")
    assert(result == "myvalue")

    -- 使用 EVALSHA (需要先加载脚本)
    local ok, sha = db:script("LOAD", script)
    local ok, result = db:evalsha(sha, 1, "mykey", "newvalue")
    assert(result == "newvalue")

    db:close()
end)
```

## 注意事项

### 错误处理

所有 Redis 命令都返回 `(ok, result)` 两个值：

- 成功时：`ok = true`, `result` 为命令结果
- 失败时：`ok = false`, `result` 为错误信息字符串

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    -- 正确的错误处理
    local ok, result = db:get("somekey")
    if not ok then
        print("Error:", result)
    else
        print("Value:", result or "nil")
    end

    db:close()
end)
```

### 协程安全

- 所有 Redis 命令必须在 `task.fork()` 创建的协程中调用
- 多个协程可以安全地共享同一个 Redis 客户端实例
- 连接池会自动处理并发请求的排队

### nil 值处理

Redis 返回 nil 时（如键不存在），`result` 为 Lua 的 `nil`：

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    db:del("nonexist")
    local ok, val = db:get("nonexist")
    assert(ok == true)      -- 命令成功执行
    assert(val == nil)      -- 但值为 nil

    db:close()
end)
```

### 数据类型转换

- 所有参数都会使用 `tostring()` 转换为字符串
- 整数返回值会自动转换为 Lua 数字
- 批量字符串返回为 Lua 字符串
- 数组返回为 Lua 表

### 连接生命周期

- 创建客户端时不会立即连接
- 第一次命令调用时自动连接
- 连接断开时自动重连
- 必须显式调用 `close()` 来释放连接
- 所有请求在同一个 TCP 连接上排队执行

## 性能建议

### 使用 Pipeline

当需要执行多个独立命令时，使用 pipeline 可以显著提升性能：

```lua
-- 慢（多次网络往返）
for i = 1, 100 do
    db:set("key" .. i, "value" .. i)
end

-- 快（一次网络往返）
local commands = {}
for i = 1, 100 do
    commands[i] = {"SET", "key" .. i, "value" .. i}
end
db:pipeline(commands)
```

### 批量操作命令

优先使用 Redis 的批量命令：

- 使用 `MSET/MGET` 而不是多次 `SET/GET`
- 使用 `HMSET/HMGET` 而不是多次 `HSET/HGET`
- 使用 `SADD` 的多参数形式

### 避免大 KEY

- 避免在单个 KEY 中存储过多数据
- HASH、LIST、SET、ZSET 应控制元素数量
- 大数据集考虑分片存储

### 连接复用

- 在应用中复用 Redis 客户端实例
- 避免频繁创建和销毁连接
- 使用单例模式管理 Redis 连接
- 注意：所有请求在单个连接上串行执行，如需真正的并发，考虑创建多个客户端实例

## 参见

- [silly.store.mysql](/reference/store/mysql.md) - MySQL 客户端
- [silly.store.etcd](/reference/store/etcd.md) - etcd 客户端
