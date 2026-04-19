---
title: silly.env
icon: gear
category:
  - API参考
tag:
  - 核心
  - 配置
  - 环境变量
---

# silly.env

环境变量和配置管理模块，支持从配置文件和命令行参数加载配置项。

## 模块导入

```lua validate
local env = require "silly.env"
```

## API函数

### env.get(key)
获取环境变量的值。

- **参数**:
  - `key`: `string` - 环境变量名。键是按 **字面字符串** 查找的：`env.get("server.port")` 返回的是恰好以 `"server.port"` 为键存储的那个值。点号分隔在运行时之所以"看起来像嵌套访问"，是因为 `env.load` 在加载配置文件时，把嵌套的 table 拍平成带点的扁平 key（详见下文 [配置文件格式](#配置文件格式)）。
- **返回值**: `any | nil` - 环境变量的值，不存在时返回 `nil`
- **示例**:
```lua validate
local env = require "silly.env"

local port = env.get("port")
local host = env.get("server.host")
local workers = env.get("server.workers")

print("Port:", port)
print("Host:", host)
print("Workers:", workers)
```

### env.set(key, value)
设置环境变量的值。

- **参数**:
  - `key`: `string` - 环境变量名。和 `env.get` 一样，key 按 **字面字符串** 处理 —— `env.set("server.port", 8080)` 存到的是 `"server.port"` 这个完整 key，而 **不会** 创建嵌套表。
  - `value`: `any` - 要设置的值（可以是任意类型）
- **示例**:
```lua validate
local env = require "silly.env"

-- 设置顶层键
env.set("debug", true)
env.set("timeout", 30)

-- 设置带点号的键（字面字符串 key —— 不会创建嵌套表）
env.set("server.port", 8080)
env.set("database.host", "127.0.0.1")

print("Debug mode:", env.get("debug"))
print("Server port:", env.get("server.port"))
```

### env.load(filename)
从配置文件加载环境变量。

- **参数**:
  - `filename`: `string` - 配置文件路径（Lua格式）
- **返回值**:
  - 成功时返回 `nil`
  - 失败时返回错误信息
- **说明**:
  - 配置文件是一个包含Lua变量赋值语句的文件
  - 支持嵌套表结构；嵌套表会被 **拍平** 成带点的 key（`server = { port = 8080 }` 变成 `env.get("server.port")`）
  - 在配置文件内部，`include(filename)` 会把另一个配置文件加载到同一个共享环境里；`ENV(name)` 是 `os.getenv(name)` 的简写
  - **First-writer-wins**：如果某个 key 已经存在（来自命令行参数、之前的 `env.set` / `env.load`），文件 **不会** 覆盖它 —— 这正是 `--key=value` 命令行覆盖能"自动生效"的原因
- **示例**:

配置文件 `config.lua`：
```lua
-- config.lua
server = {
    host = "0.0.0.0",
    port = 8080,
    workers = 4,
}
database = {
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "password",
}
debug = false
```

加载配置：
```lua validate
local env = require "silly.env"

local err = env.load("config.lua")
if err then
    print("Failed to load config:", err)
    return
end

local host = env.get("server.host")     -- "0.0.0.0"
local port = env.get("server.port")     -- 8080
local db_host = env.get("database.host") -- "127.0.0.1"
local debug = env.get("debug")          -- false

print(string.format("Server: %s:%s", host, tostring(port)))
print("Debug mode:", debug)
```

## 命令行参数

`silly.env` 自动解析命令行参数，支持 `--key=value` 格式。

### 参数格式

```bash
./silly main.lua --key1=value1 --key2=value2
```

- 参数必须以 `--` 开头
- 使用 `=` 分隔键和值
- **值会被解析为字符串**（即使看起来像数字）

### 示例

启动命令：
```bash
./silly server.lua --port=8080 --workers=4 --env=production
```

在代码中访问：
```lua validate
local env = require "silly.env"

local port = env.get("port")        -- "8080" (字符串)
local workers = env.get("workers")  -- "4" (字符串)
local environment = env.get("env")  -- "production"

-- 需要转换为数字
port = tonumber(port) or 8080
workers = tonumber(workers) or 1

print(string.format("Starting server on port %d with %d workers", port, workers))
print("Environment:", environment)
```

## 使用示例

### 示例1：基础配置管理

```lua validate
local env = require "silly.env"

-- 加载配置文件
env.load("config.lua")

-- 读取配置
local server_port = tonumber(env.get("server.port")) or 8080
local server_host = env.get("server.host") or "0.0.0.0"

print(string.format("Server will listen on %s:%d", server_host, server_port))
```

### 示例2：命令行参数覆盖配置文件

```lua validate
local env = require "silly.env"

-- 先加载配置文件
env.load("config.lua")

-- 命令行参数会自动覆盖配置文件中的值
-- ./silly main.lua --server.port=9090

local port = tonumber(env.get("server.port")) or 8080
print("Port (可被命令行覆盖):", port)
```

### 示例3：使用 include() 引入多个配置文件

`include(name)` 会把另一个配置文件在同一个共享环境里运行 —— 文件里的赋值会落到同一个 key 命名空间，所以拆分文件靠的是各自给顶层名赋值。

主配置文件 `main.config.lua`：
```lua
-- main.config.lua
include("server.config.lua")
include("database.config.lua")
debug = true
```

服务器配置 `server.config.lua`：
```lua
-- server.config.lua
server = {
    host = "0.0.0.0",
    port = 8080,
    workers = 4,
}
```

数据库配置 `database.config.lua`：
```lua
-- database.config.lua
database = {
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "password",
    database = "myapp",
}
```

加载主配置：
```lua validate
local env = require "silly.env"

env.load("main.config.lua")

-- 访问拍平后的 key
local server_port = env.get("server.port")     -- 8080
local db_host = env.get("database.host")       -- "127.0.0.1"
local db_name = env.get("database.database")   -- "myapp"

print("Server port:", server_port)
print("Database:", db_name)
```

### 示例4：多环境配置

创建不同环境的配置文件：

`config.development.lua`：
```lua
server = {
    host = "127.0.0.1",
    port = 8080,
}
database = {
    host = "127.0.0.1",
    port = 3306,
}
debug = true
```

`config.production.lua`：
```lua
server = {
    host = "0.0.0.0",
    port = 80,
}
database = {
    host = "db.example.com",
    port = 3306,
}
debug = false
```

根据环境加载：
```lua validate
local env = require "silly.env"

-- 从命令行获取环境：./silly main.lua --env=production
local environment = env.get("env") or "development"

-- 加载对应环境的配置
local config_file = string.format("config.%s.lua", environment)
env.load(config_file)

local debug = env.get("debug")
print("Environment:", environment)
print("Debug mode:", debug)
```

### 示例5：动态修改配置

```lua validate
local env = require "silly.env"
local signal = require "silly.signal"

-- 初始配置
env.load("config.lua")

-- 通过信号动态切换调试模式
-- 注意：SIGUSR2 在程序繁忙时可能被合并或丢失，请避免用于关键操作。
signal("SIGUSR1", function()
    local debug = env.get("debug")
    env.set("debug", not debug)
    print("Debug mode toggled:", env.get("debug"))
end)
```

## 配置文件格式

配置文件是一个包含Lua变量赋值语句的文件，支持以下特性：

### 1. 嵌套表结构

```lua
server = {
    host = "0.0.0.0",
    port = 8080,
    tls = {
        enabled = true,
        cert = "/path/to/cert.pem",
        key = "/path/to/key.pem",
    }
}
```

访问：
```lua
env.get("server.tls.enabled")  -- true
env.get("server.tls.cert")     -- "/path/to/cert.pem"
```

### 2. 使用 include() 与 ENV() 辅助函数

加载器会在配置文件里注入两个辅助函数：

- `include(name)` —— 把另一个配置文件加载到同一个共享环境里。被包含文件里的赋值会落到同一个扁平 key 命名空间；调用本身不返回任何东西，所以应该写 `include("server.config.lua")`（而 **不是** `server = include(...)`）。
- `ENV(name)` —— `os.getenv(name)` 的简写，用来从进程环境变量里读取秘钥/覆盖值。

```lua
include("server.config.lua")
include("database.config.lua")

-- 从进程环境读取
secret = ENV("APP_SECRET") or "dev-default"

cache = {
    enabled = true,
    ttl = 3600,
}
```

### 3. Lua 表达式

配置文件支持任意 Lua 表达式。从 OS 环境变量取值时用加载器注入的 `ENV(name)` 辅助函数：

```lua
workers = ENV("NUM_WORKERS") or 4
timeout = 30 * 1000  -- 30秒，单位毫秒
allowed_ips = {
    "127.0.0.1",
    "192.168.1.0/24",
}
features = {
    cache = true,
    metrics = true,
    debug = ENV("DEBUG") == "1",
}
```

## 注意事项

::: tip 点号分隔的 key
`env.get()` 和 `env.set()` 都把 key 当 **字面字符串** 用。点号 key 之所以"看起来像嵌套访问"，是因为 `env.load` 在加载配置时把嵌套 table 拍平成了带点的扁平 key：

```lua
-- config.lua 里：
server = { tls = { enabled = true, cert = "/path/to/cert.pem" } }

-- env.load("config.lua") 之后：
env.get("server.tls.enabled") -- ✅ true
env.get("server.tls.cert")    -- ✅ "/path/to/cert.pem"

-- env.set 也是按字面字符串 key 存的 —— 不会创建嵌套表：
env.set("server.tls.enabled", false)  -- 更新的是扁平 key "server.tls.enabled"
```
:::

::: warning First-Writer-Wins
`env.load` **不会覆盖** 已经存在的 key。命令行 `--key=value` 是在所有 `env.load` 调用之前就写入的，所以它永远赢。同样规则也适用于多次 `env.load` —— 第一个写入某个 key 的文件保留它的值。
:::

::: warning 命令行参数类型
命令行参数始终被解析为字符串：
```bash
./silly main.lua --port=8080 --workers=4
```

```lua
env.get("port")     -- "8080" (字符串，不是数字)
env.get("workers")  -- "4" (字符串，不是数字)

-- 需要手动转换
local port = tonumber(env.get("port")) or 8080
local workers = tonumber(env.get("workers")) or 1
```
:::

::: warning 配置文件安全
配置文件是可执行的Lua代码，确保：
1. 不要加载不受信任的配置文件
2. 配置文件权限应设置为只读（如 `chmod 600 config.lua`）
3. 不要在配置文件中存储敏感信息的明文（如密码）
:::

## 典型应用场景

### 1. 服务器启动配置

```lua validate
local env = require "silly.env"
local http = require "silly.net.http"

env.load("config.lua")

local port = tonumber(env.get("server.port")) or 8080
local workers = tonumber(env.get("server.workers")) or 1

http.listen {
    addr = "0.0.0.0:" .. port,
    handler = function(stream)
        stream:respond(200, {["content-type"] = "text/plain"})
        stream:closewrite("Hello!")
    end
}

print(string.format("HTTP server started on port %d with %d workers", port, workers))
```

### 2. 数据库连接配置

```lua validate
local env = require "silly.env"
local mysql = require "silly.store.mysql"

env.load("config.lua")

local db = mysql.open {
    addr = string.format("%s:%s",
        env.get("database.host"),
        env.get("database.port")
    ),
    user = env.get("database.user"),
    password = env.get("database.password"),
    database = env.get("database.database"),
    charset = env.get("database.charset") or "utf8mb4",
}

print("Database connected")
```

### 3. 特性开关（Feature Flags）

```lua validate
local env = require "silly.env"

env.load("config.lua")

local enable_cache = env.get("features.cache")
local enable_metrics = env.get("features.metrics")

if enable_cache then
    -- 启用缓存模块
    print("Cache enabled")
end

if enable_metrics then
    -- 启用监控指标
    print("Metrics enabled")
end
```

## 参见

- [silly](./silly.md) - 核心模块
- [silly.logger](./logger.md) - 日志系统（使用 `logpath` 环境变量）
- [快速开始](/tutorials/) - 使用配置文件的完整示例
