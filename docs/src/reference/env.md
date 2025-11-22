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
  - `key`: `string` - 环境变量名，支持点号分隔的嵌套访问（如 `"server.port"`）
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
  - `key`: `string` - 环境变量名，支持点号分隔的嵌套键（如 `"server.port"`）
  - `value`: `any` - 要设置的值（可以是任意类型）
- **示例**:
```lua validate
local env = require "silly.env"

-- 设置顶层键
env.set("debug", true)
env.set("timeout", 30)

-- 设置嵌套键
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
  - 支持嵌套表结构
  - 支持 `include(filename)` 函数引入其他配置文件
  - 加载的配置会合并到现有环境变量中
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

主配置文件 `main.config.lua`：
```lua
-- main.config.lua
server = include("server.config.lua")
database = include("database.config.lua")
debug = true
```

服务器配置 `server.config.lua`：
```lua
-- server.config.lua
return {
    host = "0.0.0.0",
    port = 8080,
    workers = 4,
}
```

数据库配置 `database.config.lua`：
```lua
-- database.config.lua
return {
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

-- 访问嵌套配置
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
signal("SIGUSR2", function()
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

### 2. 使用 include() 函数

```lua
server = include("server.config.lua")
database = include("database.config.lua")
-- 也可以直接嵌套
cache = {
    enabled = true,
    ttl = 3600,
}
```

### 3. Lua 表达式

配置文件支持任意Lua表达式：

```lua
workers = os.getenv("NUM_WORKERS") or 4
timeout = 30 * 1000  -- 30秒，单位毫秒
allowed_ips = {
    "127.0.0.1",
    "192.168.1.0/24",
}
features = {
    cache = true,
    metrics = true,
    debug = os.getenv("DEBUG") == "1",
}
```

## 注意事项

::: tip 嵌套访问
`env.get()` 和 `env.set()` 都支持点号分隔的嵌套键访问：
```lua
env.get("server.port")        -- ✅ 支持
env.get("server.tls.enabled") -- ✅ 支持
env.set("server.port", 8080)  -- ✅ 支持
env.set("server.tls.enabled", true) -- ✅ 支持
```
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
