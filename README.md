# Silly - 轻量级网络服务器框架

[![license](https://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat)](https://github.com/findstr/silly/blob/master/LICENSE)
[![CI](https://github.com/findstr/silly/actions/workflows/ci.yml/badge.svg)](https://github.com/findstr/silly/actions/workflows/ci.yml)

## Introduction | 简介

Silly is a lightweight and minimalist server framework designed for efficient server-side development. It combines the performance of C with the flexibility of Lua, making it particularly suitable for game server development and other high-performance network applications.

Silly 是一个轻量、极简的服务器程序框架。它将 C 语言的高性能与 Lua 的灵活性相结合，特别适合游戏服务器开发和其他高性能网络应用程序。

## Performance | 性能表现

### Benchmark Results | 基准测试结果
Test Environment | 测试环境：
- CPU：Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz
- Test Tool: redis-benchmark
- 测试工具：redis-benchmark

[**Test Results** | **测试结果**](https://github.com/findstr/silly/wiki/Benchmark):
```
====== PING_INLINE ======
  100000 requests completed in 0.42 seconds
  100 parallel clients
  3 bytes payload
Summary:
  throughput summary: 235849.06 requests per second
  latency summary (msec):
          avg       min       p50       p95       p99       max
        0.230     0.080     0.223     0.279     0.367     1.527
====== PING_MBULK ======
  100000 requests completed in 0.44 seconds
  100 parallel clients
  3 bytes payload
Summary:
  throughput summary: 224719.11 requests per second
  latency summary (msec):
          avg       min       p50       p95       p99       max
        0.241     0.136     0.231     0.335     0.479     0.887
```

## Example at a Glance | 代码一览

Here is a simple example that demonstrates how to easily write an echo server with Silly to handle 100,000+ concurrent requests per second:

这是一个简单的示例，展示了如何使用 Silly 轻松编写处理每秒 20w+ 并发请求的 echo server:

```lua
local tcp = require "silly.net.tcp"
local listenfd = tcp.listen("127.0.0.1:8888", function(fd, addr)
        print("accpet", addr, fd)
        while true do
                local l = tcp.readline(fd, "\n")
                if not l then
                        print("disconnected", fd)
                        break
                end
                tcp.write(fd, l)
        end
end)
```

To run this echo server:

运行这个echo server:

```bash
./silly echo_server.lua
```

Test with telnet or netcat:

使用 telnet 或 netcat 测试：

```bash
nc localhost 8888
```

## Case | 案例

[![](./docs/src/cases/case1.png)](https://www.taptap.cn/app/230552)

## Core Features | 核心特性

### Architecture | 架构设计
- 🔧 **Hybrid Development** | **混合开发**
  - Core components written in C for optimal performance
  - Business logic implemented in Lua for rapid development
  - 核心组件使用 C 语言开发，确保最佳性能
  - 业务逻辑使用 Lua 实现，支持快速开发

- 🧵 **Concurrency Model** | **并发模型**
  - Single-process, single-thread model for business logic
  - Eliminates complex multi-threading issues
  - 业务逻辑采用单进程单线程模型
  - 避免复杂的多线程问题

- 🔄 **Asynchronous Programming** | **异步编程**
  - Lua coroutines for clean asynchronous code
  - No callback hell
  - 使用 Lua 协程实现清晰的异步代码
  - 避免回调地狱

## System Architecture | 系统架构

### Thread Model | 线程模型

1. **Worker Thread** | **Worker 线程**
   - Manages Lua VM and event processing
   - Handles socket and timer events
   - 管理 Lua 虚拟机和事件处理
   - 处理 socket 和定时器事件

2. **Socket Thread** | **Socket 线程**
   - High-performance socket management (epoll/kevent/iocp)
   - Configurable connection limit (default: 65535)
   - 高性能 socket 管理（基于 epoll/kevent/iocp）
   - 可配置连接限制（默认：65535）

3. **Timer Thread** | **Timer 线程**
   - High-resolution timer system
   - Default: 10ms resolution, 50ms accuracy
   - 高分辨率定时器系统
   - 默认：10ms 分辨率，50ms 精度

## Getting Started | 快速开始

### Build | 编译

```bash
make
```

### Running | 运行

```bash
./silly <main.lua> [options]
```

##### Available options | 可用选项:
```
Core Options | 核心选项:
  -h, --help                Display this help message
                            显示帮助信息
  -v, --version             Show version information
                            显示版本信息
  -d, --daemon              Run as a daemon process
                            以守护进程模式运行
Logging Options | 日志选项:
  -p, --logpath PATH        Specify log file path
                            指定日志文件路径
  -l, --loglevel LEVEL      Set logging level (debug/info/warn/error)
                            设置日志级别 (debug/info/warn/error)
  -f, --pidfile FILE        Specify PID file path
                            指定 PID 文件路径
Library Path Options | 库路径选项:
  -L, --lualib_path PATH    Set Lua library path
                            设置 Lua 库路径
  -C, --lualib_cpath PATH   Set C Lua library path
                            设置 C Lua 库路径
CPU Affinity Options | CPU 亲和性选项:
  -S, --socket_cpu_affinity Set CPU affinity for socket thread
                            设置 socket 线程的 CPU 亲和性
  -W, --worker_cpu_affinity Set CPU affinity for worker threads
                            设置 worker 线程的 CPU 亲和性
  -T, --timer_cpu_affinity  Set CPU affinity for timer thread
                            设置 timer 线程的 CPU 亲和性
```

##### Custom Options | 自定义选项

In addition to the predefined options above, you can pass custom key-value pairs using the `--key=value` format. These values can be accessed in your Lua code using `require "silly.env".get(key)`.

除了上述预定义选项外，您可以使用 `--key=value` 格式传入自定义的键值对。这些值可以在 Lua 代码中通过 `require "silly.env".get(key)` 来获取。

Example | 示例:
```bash
# Start server with custom options | 使用自定义选项启动服务器
./silly main.lua --port=8888 --max_connections=1000 --server_name="my_server"
```

In your Lua code | 在 Lua 代码中:
```lua
local env = require "silly.env"

-- Get custom options | 获取自定义选项
local port = env.get("port")              -- Returns "8888"
local max_conn = env.get("max_connections") -- Returns "1000"
local name = env.get("server_name")        -- Returns "my_server"

print(string.format("Starting %s on port %s with max connections %s",
    name, port, max_conn))
```

## Examples | 示例

### Available Examples | 可用示例
- [HTTP Server](examples/http.lua) | HTTP 服务器
- [RPC System](examples/rpc.lua) | RPC 系统
- [WebSocket Server](examples/websocket.lua) | WebSocket 服务器
- [Timer Demo](examples/timer.lua) | 定时器演示
- [Socket Programming](examples/socket.lua) | Socket 编程
- [Patch System](examples/patch.lua) | 补丁系统

### Running Examples | 运行示例

单个示例 | Single example:
```bash
examples/start.sh [http|rpc|websocket|timer|socket|patch]
```

所有示例 | All examples:
```bash
examples/start.sh
```

## Development | 开发

### Testing | 测试
```bash
make testall
```

## Documentation | 文档

For detailed documentation, please visit our [Wiki](https://github.com/findstr/silly/wiki).

详细文档请访问我们的 [Wiki](https://github.com/findstr/silly/wiki)。

## License | 许可证

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。
