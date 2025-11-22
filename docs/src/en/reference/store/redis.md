# Redis Client

The `silly.store.redis` module provides an asynchronous Redis client based on connection pooling, supporting all standard Redis commands and implementing the RESP (Redis Serialization Protocol). It uses connection reuse and automatic reconnection mechanisms to provide reliable Redis access for high-performance applications.

## Module Import

```lua validate
local redis = require "silly.store.redis"
local silly = require "silly"

-- Create Redis client
local db = redis.new {
    addr = "127.0.0.1:6379",
    auth = "password",  -- Optional
    db = 0,             -- Optional, database index
}

local task = require "silly.task"

-- Use Redis client
task.fork(function()
    local ok, res = db:ping()
    assert(ok and res == "PONG")
    db:close()
end)
```

## Core Concepts

### RESP Protocol

The Redis client implements the complete RESP (Redis Serialization Protocol), supporting the following data types:

- **Simple Strings** (`+`): Returns status replies like `"OK"`, `"PONG"`
- **Errors** (`-`): Returns error information
- **Integers** (`:`): Returns numeric results
- **Bulk Strings** (`$`): Returns strings or nil
- **Arrays** (`*`): Returns arrays of multiple values

### Connection Pool Mechanism

The module implements an internal request queue mechanism (socketq):

- **Single Connection Mode**: All requests share a single TCP connection
- **Request Queuing**: Requests from multiple coroutines execute sequentially on a single connection
- **Automatic Reconnection**: Automatically reconnects when connection drops
- **Authentication Support**: Supports password authentication and database selection

**Note**: socketq is not a traditional connection pool - it queues requests on a **single TCP connection** to enable concurrent requests (pipelining). All operations share one connection rather than maintaining a pool of multiple connections.

### Command Invocation Methods

The Redis client supports multiple command invocation methods:

1. **Method Call**: `db:set("key", "value")`
2. **call Method**: `db:call("set", "key", "value")`
3. **Table Arguments**: `db:set({"key", "value"})`

All Redis commands are automatically converted to uppercase before being sent to the server.

## API Reference

### redis.new(config)

Creates a new Redis client instance.

- **Parameters**:
  - `config`: `table` - Configuration table
    - `addr`: `string` (required) - Redis server address in format `"host:port"`
    - `auth`: `string|nil` (optional) - Redis password for AUTH command
    - `db`: `integer|nil` (optional) - Database index for SELECT command
- **Returns**:
  - `silly.store.redis` - Redis client object
- **Async**: No
- **Example**:

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

-- Basic connection
local db1 = redis.new {
    addr = "127.0.0.1:6379",
}

-- With password and database selection
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

Closes the Redis connection and releases resources.

- **Parameters**: None
- **Returns**: None
- **Async**: No
- **Example**:

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    db:set("temp", "value")
    db:close()  -- Close connection
end)
```

### db:call(cmd, ...)

Generic command invocation interface that can be used to call any Redis command.

- **Parameters**:
  - `cmd`: `string` - Redis command name
  - `...`: Command arguments (variable arguments or table)
- **Returns**:
  - Success: `true, result` - Command executed successfully, result is the command result
  - Failure: `false, error` - Command execution failed, error is the error message
- **Async**: Yes (suspends coroutine)
- **Example**:

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- Using call method
    local ok, res = db:call("set", "key1", "value1")
    assert(ok and res == "OK")

    local ok, res = db:call("get", "key1")
    assert(ok and res == "value1")

    -- Using table arguments
    local ok, res = db:call("mset", {"k1", "v1", "k2", "v2"})
    assert(ok)

    db:close()
end)
```

### db:pipeline(requests, results)

Executes Redis commands in batch, with all commands completed in a single network round trip.

- **Parameters**:
  - `requests`: `table` - Array of commands, each element is an array of command arguments
  - `results`: `table` (optional) - Results array, if provided it will be populated with all command return values
- **Returns**:
  - Without results: `boolean, result` - Returns result of the last command
  - With results: `true, count` - Returns true and the result count
- **Async**: Yes (suspends coroutine)
- **Example**:

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- Pipeline without getting results
    local ok, res = db:pipeline({
        {"SET", "p1", "v1"},
        {"SET", "p2", "v2"},
        {"SET", "p3", "v3"},
    })
    assert(ok)

    -- Get all results
    local results = {}
    local ok, count = db:pipeline({
        {"GET", "p1"},
        {"GET", "p2"},
        {"GET", "p3"},
    }, results)
    assert(ok and count == 6)  -- 3 commands, each with 2 return values (ok, value)
    assert(results[2] == "v1")
    assert(results[4] == "v2")
    assert(results[6] == "v3")

    db:close()
end)
```

### db:select(dbid)

Switches database. Note: This method is deprecated, you should specify the database when creating the client.

- **Parameters**:
  - `dbid`: `integer` - Database index
- **Returns**: Throws an error
- **Async**: No
- **Description**: This method throws an error, prompting to specify the `db` parameter in `redis.new()`

### Redis Command Methods

All standard Redis commands can be called as methods. Command names are automatically converted to uppercase. Below are common commands categorized:

#### String Operations

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

#### Hash Operations

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

#### List Operations

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

#### Set Operations

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

#### Sorted Set Operations

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

    -- ZREVRANGE (with scores)
    local ok, data = db:zrevrange("leaderboard", 0, -1, "WITHSCORES")
    assert(data[1] == "player2" and data[2] == "200")

    db:close()
end)
```

#### Key Operations

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

#### Server Commands

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

## Usage Examples

### Basic Key-Value Operations

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- Set and get
    db:set("username", "alice")
    local ok, name = db:get("username")
    assert(name == "alice")

    -- Check if key exists
    local ok, exists = db:exists("username")
    assert(exists == 1)

    -- Delete key
    local ok, count = db:del("username")
    assert(count == 1)

    db:close()
end)
```

### Using Hashes to Store Objects

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- Store user information
    local user_id = "user:1001"
    db:hmset(user_id,
        "name", "Alice",
        "email", "alice@example.com",
        "age", "25"
    )

    -- Get single field
    local ok, name = db:hget(user_id, "name")
    assert(name == "Alice")

    -- Get all fields
    local ok, fields = db:hgetall(user_id)
    -- fields = {"name", "Alice", "email", "alice@example.com", "age", "25"}
    assert(fields[1] == "name")

    -- Increment numeric field
    db:hincrby(user_id, "age", 1)
    local ok, age = db:hget(user_id, "age")
    assert(age == "26")

    db:close()
end)
```

### Batch Operations (Pipeline)

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- Batch set multiple keys (no return values needed)
    db:pipeline({
        {"SET", "batch:1", "value1"},
        {"SET", "batch:2", "value2"},
        {"SET", "batch:3", "value3"},
        {"SET", "batch:4", "value4"},
        {"SET", "batch:5", "value5"},
    })

    -- Batch get and process results
    local results = {}
    db:pipeline({
        {"GET", "batch:1"},
        {"GET", "batch:2"},
        {"GET", "batch:3"},
        {"GET", "batch:4"},
        {"GET", "batch:5"},
    }, results)

    -- results is {true, "value1", true, "value2", ...}
    for i = 2, #results, 2 do
        assert(results[i] == "value" .. (i // 2))
    end

    db:close()
end)
```

### Counter Implementation

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    local counter_key = "page:views"

    -- Initialize counter
    db:set(counter_key, 0)

    -- Increment counter
    local ok, count = db:incr(counter_key)
    assert(count == 1)

    -- Increment by specific value
    local ok, count = db:incrby(counter_key, 10)
    assert(count == 11)

    -- Get current value
    local ok, count = db:get(counter_key)
    assert(count == "11")

    db:close()
end)
```

### Leaderboard Implementation

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    local leaderboard = "game:leaderboard"

    -- Add player scores
    db:zadd(leaderboard, 1000, "player1")
    db:zadd(leaderboard, 1500, "player2")
    db:zadd(leaderboard, 1200, "player3")

    -- Get top 3 players (descending order)
    local ok, top3 = db:zrevrange(leaderboard, 0, 2, "WITHSCORES")
    -- top3 = {"player2", "1500", "player3", "1200", "player1", "1000"}
    assert(top3[1] == "player2")

    -- Get player rank (0-indexed)
    local ok, rank = db:zrevrank(leaderboard, "player1")
    assert(rank == 2)  -- Third place

    -- Increment player score
    db:zincrby(leaderboard, 500, "player1")
    local ok, score = db:zscore(leaderboard, "player1")
    assert(score == "1500")

    db:close()
end)
```

### Distributed Lock (Simple Implementation)

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
    local ttl = 30  -- Lock expiration time

    -- Try to acquire lock (NX = set if not exists, EX = expiration time)
    local ok, res = db:set(lock_key, lock_value, "NX", "EX", ttl)

    if res == "OK" then
        -- Successfully acquired lock, execute business logic
        -- ... do work ...

        -- Release lock (use Lua script to ensure atomicity)
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
        -- Failed to acquire lock
        print("Failed to acquire lock")
    end

    db:close()
end)
```

### Publish/Subscribe (Requires Multiple Connections)

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

-- Subscriber
local subscriber = redis.new {
    addr = "127.0.0.1:6379",
}

-- Publisher
local publisher = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- Note: subscribe blocks the connection, requires dedicated connection in practice
    -- This is just an example showing command invocation

    -- Publish message
    local ok, receivers = publisher:publish("news", "Hello World")
    -- receivers is the number of subscribers who received the message

    publisher:close()
    subscriber:close()
end)
```

### Lua Script Execution

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new {
    addr = "127.0.0.1:6379",
}

local task = require "silly.task"

task.fork(function()
    -- Execute Lua script using EVAL
    local script = [[
        local key = KEYS[1]
        local value = ARGV[1]
        redis.call('SET', key, value)
        return redis.call('GET', key)
    ]]

    local ok, result = db:eval(script, 1, "mykey", "myvalue")
    assert(result == "myvalue")

    -- Use EVALSHA (requires loading script first)
    local ok, sha = db:script("LOAD", script)
    local ok, result = db:evalsha(sha, 1, "mykey", "newvalue")
    assert(result == "newvalue")

    db:close()
end)
```

## Notes

### Error Handling

All Redis commands return two values `(ok, result)`:

- On success: `ok = true`, `result` is the command result
- On failure: `ok = false`, `result` is the error message string

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    -- Proper error handling
    local ok, result = db:get("somekey")
    if not ok then
        print("Error:", result)
    else
        print("Value:", result or "nil")
    end

    db:close()
end)
```

### Coroutine Safety

- All Redis commands must be called in coroutines created by `task.fork()`
- Multiple coroutines can safely share the same Redis client instance
- The connection pool automatically handles request queuing for concurrent requests

### nil Value Handling

When Redis returns nil (e.g., key doesn't exist), `result` is Lua's `nil`:

```lua validate
local silly = require "silly"
local redis = require "silly.store.redis"

local db = redis.new { addr = "127.0.0.1:6379" }

local task = require "silly.task"

task.fork(function()
    db:del("nonexist")
    local ok, val = db:get("nonexist")
    assert(ok == true)      -- Command executed successfully
    assert(val == nil)      -- But value is nil

    db:close()
end)
```

### Data Type Conversion

- All arguments are converted to strings using `tostring()`
- Integer return values are automatically converted to Lua numbers
- Bulk strings are returned as Lua strings
- Arrays are returned as Lua tables

### Connection Lifecycle

- Connection is not established immediately when creating the client
- First command invocation triggers automatic connection
- Automatic reconnection on connection loss
- Must explicitly call `close()` to release connection
- All requests are queued and executed on the same TCP connection

## Performance Recommendations

### Use Pipeline

When executing multiple independent commands, using pipeline can significantly improve performance:

```lua
-- Slow (multiple network round trips)
for i = 1, 100 do
    db:set("key" .. i, "value" .. i)
end

-- Fast (single network round trip)
local commands = {}
for i = 1, 100 do
    commands[i] = {"SET", "key" .. i, "value" .. i}
end
db:pipeline(commands)
```

### Batch Operation Commands

Prefer Redis batch commands:

- Use `MSET/MGET` instead of multiple `SET/GET`
- Use `HMSET/HMGET` instead of multiple `HSET/HGET`
- Use multi-argument form of `SADD`

### Avoid Large Keys

- Avoid storing too much data in a single key
- HASH, LIST, SET, ZSET should have controlled element counts
- Consider sharding for large datasets

### Connection Reuse

- Reuse Redis client instances in your application
- Avoid frequently creating and destroying connections
- Use singleton pattern to manage Redis connections
- Note: All requests execute serially on a single connection; for true concurrency, consider creating multiple client instances

## See Also

- [silly.store.mysql](/en/reference/store/mysql.md) - MySQL client
- [silly.store.etcd](/en/reference/store/etcd.md) - etcd client
