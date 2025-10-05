---
title: silly.console
icon: terminal
category:
  - API参考
tag:
  - 工具
  - 控制台
  - 运维
---

# silly.console

交互式控制台模块，提供TCP远程管理接口，支持服务器运行时信息查看、代码注入、调试等运维操作。

## 模块导入

```lua validate
local console = require "silly.console"
```

::: tip 模块特性
`silly.console` 模块导出的是一个函数，调用该函数会启动一个TCP监听服务器，接受控制台连接。
:::

## API

### console(config)
启动控制台服务器。

- **参数**:
  - `config`: `table` - 配置表
    - `addr`: `string` - 监听地址，格式为 `"host:port"`（如 `"127.0.0.1:8888"`）
    - `cmd`: `table` (可选) - 自定义命令表，键为命令名，值为处理函数
- **说明**:
  - 启动后会在指定地址监听TCP连接
  - 每个连接独立处理，支持多个并发控制台会话
  - 建议只在内网地址监听，避免安全风险

## 内置命令

控制台提供以下内置命令（不区分大小写）：

### HELP
显示所有命令的帮助信息。

- **语法**: `HELP`
- **返回**: 所有命令的描述列表

### PING
测试连接是否活跃。

- **语法**: `PING [text]`
- **返回**: 返回 `text` 或 `"PONG"`

### GC
执行一次完整的垃圾回收。

- **语法**: `GC`
- **返回**: Lua内存使用量（KiB）

### INFO
显示服务器的所有信息。

- **语法**: `INFO`
- **返回**: 包含以下信息：
  - 构建信息：版本号、Git SHA1、多路复用API、内存分配器、定时器分辨率
  - 进程信息：进程ID
  - 指标信息：所有Prometheus收集器的指标

### SOCKET
显示指定socket的详细信息。

- **语法**: `SOCKET <fd>`
- **参数**:
  - `fd`: `integer` - socket文件描述符
- **返回**: socket信息：
  - fd：文件描述符
  - os_fd：操作系统文件描述符
  - type：socket类型
  - protocol：协议类型
  - sendsize：发送缓冲区大小
  - localaddr/remoteaddr：本地和远程地址（如果已连接）

### TASK
显示所有协程任务的状态和堆栈跟踪。

- **语法**: `TASK`
- **返回**: 所有活跃协程的列表，包括：
  - 协程ID
  - 状态（running/suspended/...）
  - 完整的堆栈跟踪

### INJECT
注入并执行一个Lua文件。

- **语法**: `INJECT <filepath>`
- **参数**:
  - `filepath`: `string` - Lua文件的路径
- **返回**: 注入成功或失败的消息
- **说明**:
  - 文件在独立环境中执行，继承全局环境
  - 可用于运行时修复bug或添加功能
  - 谨慎使用，错误的代码可能导致服务器崩溃

### DEBUG
进入调试模式。

- **语法**: `DEBUG`
- **说明**:
  - 启动交互式调试器
  - 详见 [silly.debugger](./debugger.md)

### QUIT / EXIT
退出控制台连接。

- **语法**: `QUIT` 或 `EXIT`

## 使用示例

### 示例1：启动基本控制台

```lua validate
local console = require "silly.console"

console({
    addr = "127.0.0.1:8888"
})

print("Console started on 127.0.0.1:8888")
```

### 示例2：使用telnet连接控制台

```bash
$ telnet 127.0.0.1 8888
```

```
Welcome to console.

Type 'help' for help.

console> help
HELP: List command description. [HELP]
PING: Test connection alive. [PING <text>]
GC: Performs a full garbage-collection cycle. [GC]
INFO: Show all information of server. [INFO]
SOCKET: Show socket detail information. [SOCKET]
TASK: Show all task status and traceback. [TASK]
INJECT: INJECT code. [INJECT <path>]
DEBUG: Enter Debug mode. [DEBUG]
QUIT: Quit the console. [QUIT]

console> ping hello world
hello world

console> gc
Lua Mem Used:1234.56 KiB

console> quit
Bye, Bye
```

### 示例3：查看服务器信息

连接到控制台后执行：

```
console> info

#Build
version:1.0.0
git_sha1:abc1234
multiplexing_api:epoll
memory_allocator:jemalloc
timer_resolution:10 ms

#Process
process_id:12345

#Memory
lua_memory_used:1234.56 KiB
...
```

### 示例4：查看所有协程任务

```
console> task
#Task (3)
Task thread: 0x12345678 - suspended :
  [C]: in function 'tcp.read'
  /app/handler.lua:45: in function 'handle_request'
  ...

Task thread: 0x23456789 - suspended :
  [C]: in function 'time.sleep'
  /app/timer.lua:10: in function 'timer_task'
  ...
```

### 示例5：注入修复代码

假设有一个bug需要运行时修复，创建文件 `/tmp/fix.lua`：

```lua
-- /tmp/fix.lua
local mymodule = require "mymodule"
mymodule.buggy_function = function()
    print("Fixed version")
end
```

在控制台中：

```
console> inject /tmp/fix.lua
Inject file:/tmp/fix.lua Success
```

### 示例6：添加自定义命令

```lua validate
local console = require "silly.console"

console({
    addr = "127.0.0.1:8888",
    cmd = {
        -- 自定义STATUS命令
        status = function(fd)
            return "Server is running normally"
        end,

        -- 自定义USERS命令，显示在线用户数
        users = function(fd)
            -- local count = get_online_users_count()
            local count = 100  -- 模拟
            return string.format("Online users: %d", count)
        end,
    }
})

print("Console with custom commands started")
```

连接后可以使用自定义命令：

```
console> status
Server is running normally

console> users
Online users: 100
```

## 安全注意事项

::: danger 安全风险
控制台提供了对服务器的完全访问权限，包括代码注入和调试能力。务必注意以下安全措施：
:::

1. **只在内网监听**: 使用 `127.0.0.1` 或内网地址，绝不要暴露到公网
2. **使用防火墙**: 即使是内网，也应该限制可访问的IP
3. **考虑认证**: 在生产环境中，可以在自定义命令中实现认证机制
4. **谨慎使用INJECT**: 代码注入功能强大但危险，只在紧急情况下使用
5. **日志记录**: 所有控制台操作都会记录到日志，便于审计

## 命令处理器接口

自定义命令处理函数签名：

```lua
function(fd, ...) -> string | table | nil
```

- **参数**:
  - `fd`: `integer` - 客户端socket文件描述符
  - `...`: 命令行参数（空格分隔）
- **返回值**:
  - `string`: 直接返回给客户端
  - `table`: 以换行符连接后返回
  - `nil`: 关闭连接

示例：

```lua validate
local tcp = require "silly.net.tcp"
local console = require "silly.console"

console({
    addr = "127.0.0.1:8888",
    cmd = {
        -- 返回字符串
        echo = function(fd, ...)
            local args = {...}
            return table.concat(args, " ")
        end,

        -- 返回表（多行）
        list = function(fd)
            return {
                "Item 1",
                "Item 2",
                "Item 3",
            }
        end,

        -- 关闭连接
        kick = function(fd)
            return nil  -- 返回nil会关闭连接
        end,
    }
})
```

## 与其他模块的集成

### 与metrics集成

控制台的 `INFO` 命令会自动显示所有注册的Prometheus指标：

```lua
local console = require "silly.console"
local prometheus = require "silly.metrics.prometheus"

-- 注册自定义指标
local counter = prometheus.counter("my_requests", "Total requests")

console({
    addr = "127.0.0.1:8888"
})
```

### 与logger集成

控制台会自动记录所有连接和断开事件：

```lua validate
local console = require "silly.console"
local logger = require "silly.logger"

logger.setlevel(logger.INFO)

console({
    addr = "127.0.0.1:8888"
})
```

日志输出示例：
```
[INFO] console come in: 127.0.0.1:54321
[INFO] 127.0.0.1:54321 leave
```

## 参见

- [silly.debugger](./debugger.md) - 交互式调试器
- [silly.metrics](./metrics/) - 指标收集
- [silly.logger](./logger.md) - 日志系统
- [silly.net.tcp](./net/tcp.md) - TCP网络
