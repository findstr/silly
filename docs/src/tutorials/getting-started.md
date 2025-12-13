---
title: 快速开始
icon: rocket
category:
  - 教程
order: 1
---

# 快速开始

欢迎使用 Silly 框架！本教程将引导你从零开始，在 10 分钟内完成 Silly 的安装、配置，并运行你的第一个高性能网络应用。

## 简介

### Silly 是什么？

Silly 是一个轻量级、高性能的服务器框架，专为构建高并发网络应用而设计。它结合了：

- **C 语言的性能**: 核心组件使用 C 编写，性能卓越
- **Lua 的灵活性**: 业务逻辑使用 Lua 实现，开发高效
- **协程驱动**: 使用 Lua 协程实现清晰的异步编程模型

### 适合做什么？

Silly 特别适合构建以下类型的应用：

- **游戏服务器**: 高并发、低延迟的游戏后端
- **API 服务**: RESTful API、gRPC 服务
- **实时通信**: WebSocket 服务、即时通讯
- **网络代理**: TCP/UDP 代理、负载均衡器

### 性能表现

在 Intel i7-10700 @ 2.90GHz 上的测试结果：

- **吞吐量**: 200,000+ 请求/秒
- **延迟**: P99 < 1ms
- **并发**: 支持 65,535 个并发连接

## 环境要求

### 操作系统

Silly 支持以下操作系统：

- **Linux**: 推荐使用，生产环境首选（使用 epoll）
- **macOS**: 适合开发环境（使用 kqueue）
- **Windows**: 支持 MinGW 编译（使用 IOCP）

### 依赖项

#### 必需依赖

- **GCC** 或 **Clang**: C 编译器
- **Make**: 构建工具
- **Git**: 用于克隆代码和子模块

#### 可选依赖

- **OpenSSL**: 启用 TLS/SSL 支持（推荐）
- **jemalloc**: 更好的内存分配性能（默认启用）

### 安装依赖

::: code-tabs#shell

@tab Ubuntu/Debian

```bash
sudo apt-get update
sudo apt-get install -y build-essential git libssl-dev
```

@tab CentOS/RHEL

```bash
sudo yum groupinstall "Development Tools"
sudo yum install -y git openssl-devel
```

@tab macOS

```bash
# 安装 Xcode Command Line Tools
xcode-select --install

# 安装 OpenSSL（可选）
brew install openssl
```

:::

## 安装步骤

### 1. 克隆代码

```bash
# 克隆仓库（包含子模块）
git clone --recursive https://github.com/findstr/silly.git
cd silly
```

::: tip 提示
如果忘记使用 `--recursive`，可以使用以下命令初始化子模块：
```bash
git submodule update --init --recursive
```
:::

### 2. 编译框架

```bash
# 标准编译
make
```

::: details 高级编译选项

```bash
# 禁用 OpenSSL 支持（默认启用）
make OPENSSL=off

# 使用 glibc 内存分配器（调试用）
make MALLOC=glibc

# 编译测试版本（带地址检测）
make test

# 清理构建产物
make clean
```

:::

### 3. 验证安装

```bash
# 检查可执行文件
./silly --version
```

你应该看到版本号输出：

```
0.6
```

恭喜！Silly 已经成功安装。

## 第一个程序

让我们创建一个简单的 "Hello World" 程序来体验 Silly。

### 创建 hello.lua

在 silly 目录下创建一个名为 `hello.lua` 的文件：

```lua
-- 导入 silly 核心模块
local silly = require "silly"

print("Hello, Silly!")
print("当前进程 ID:", silly.pid)
print("框架版本:", silly.version)

-- 退出程序
silly.exit(0)
```

### 运行程序

```bash
./silly hello.lua
```

### 理解输出

你将看到：

```
Hello, Silly!
当前进程 ID: 12345
框架版本: 0.6
```

::: tip 发生了什么？
1. `require "silly"` 获取 silly 框架接口
2. `print()` 输出信息到控制台
3. `silly.exit(0)` 优雅退出进程
:::

## 核心概念简介

在深入学习之前，了解 Silly 的几个核心概念非常重要。

### 1. 协程模型

Silly 使用 **Lua 协程**实现异步编程，让异步代码看起来像同步代码一样简洁。

**传统回调方式**（复杂、难维护）：

```lua
-- 回调地狱示例（Silly 不需要这样写）
socket.connect(addr, function(fd)
    socket.read(fd, function(data1)
        socket.write(fd, data1, function()
            socket.read(fd, function(data2)
                socket.write(fd, data2, function()
                    socket.close(fd)
                end)
            end)
        end)
    end)
end)
```

**Silly 协程方式**（清晰、易读）：

```lua
-- Silly 的协程方式
local tcp = require "silly.net.tcp"
local task = require "silly.task"

task.fork(function()
    local conn = tcp.connect("127.0.0.1:8080")
    local data1 = conn:read(1024)
    conn:write(data1)
    local data2 = conn:read(1024)
    conn:write(data2)
    conn:close()
end)
```

### 2. 事件循环

Silly 使用单线程事件循环处理所有业务逻辑：

```
┌─────────────────────────────┐
│   等待事件（socket/timer）    │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│   分发事件到协程处理          │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│   执行协程直到挂起            │
└──────────┬──────────────────┘
           │
           └────► 循环
```

::: info 为什么是单线程？
单线程模型避免了锁、竞态条件等多线程复杂问题，同时通过异步 I/O 和协程实现高并发。这是 Node.js、Nginx 等高性能系统采用的成熟模式。
:::

### 3. task.fork() - 创建并发任务

`task.fork()` 用于创建新的协程任务，实现并发处理：

```lua
local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"

print("主任务开始")

-- 创建两个并发任务
task.fork(function()
    time.sleep(1000)  -- 睡眠 1 秒
    print("任务 1 完成")
end)

task.fork(function()
    time.sleep(500)   -- 睡眠 0.5 秒
    print("任务 2 完成")
end)

print("主任务继续执行")
```

**输出顺序**：
```
主任务开始
主任务继续执行
任务 2 完成        # 0.5 秒后
任务 1 完成        # 1 秒后
```

### 4. 一个完整示例

让我们创建一个简单的定时器程序，巩固所学概念：

创建 `timer_demo.lua`：

```lua
local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"

print("定时器演示开始")

-- 任务 1: 每秒打印一次
task.fork(function()
    for i = 1, 5 do
        print(string.format("[任务1] 第 %d 秒", i))
        time.sleep(1000)
    end
end)

-- 任务 2: 每 0.5 秒打印一次
task.fork(function()
    for i = 1, 10 do
        print(string.format("  [任务2] 第 %d 次 (%.1f秒)", i, i * 0.5))
        time.sleep(500)
    end
end)

-- 主任务: 等待 6 秒后退出
task.fork(function()
    time.sleep(6000)
    print("演示结束")
    silly.exit(0)
end)
```

运行：

```bash
./silly timer_demo.lua
```

你将看到两个任务交替执行，直到程序退出。

## 下一步

恭喜你完成了快速开始教程！现在你已经：

✅ 成功安装并运行 Silly
✅ 理解了协程和事件循环的基本概念
✅ 学会了使用 `task.fork()` 创建并发任务
✅ 创建了第一个定时器程序

### 推荐学习路径

1. **[Echo 服务器教程](./echo-server.md)** - 学习如何构建一个高性能的 TCP 服务器（10 行代码实现）
2. **[核心概念](/concepts/)** - 深入理解协程、消息队列、调度器等核心机制
3. **[操作指南](/guides/)** - 学习如何解决实际开发中的具体问题
4. **[API 参考](/reference/)** - 查阅完整的 API 文档

### 更多示例

继续学习以下教程来掌握更多功能：

- **[HTTP 服务器](./http-server.md)** - 构建 RESTful API 服务
- **[WebSocket 聊天](./websocket-chat.md)** - 实现实时通信应用
- **[数据库应用](./database-app.md)** - 使用 MySQL 存储数据

## 故障排除

### 常见问题

#### 1. 编译失败：找不到 lua.h

**问题**：
```
fatal error: lua.h: No such file or directory
```

**解决方法**：
```bash
# 确保子模块已初始化
git submodule update --init --recursive
```

#### 2. 运行时找不到 Lua 库

**问题**：
```
module 'silly' not found
```

**解决方法**：
```bash
# 使用正确的路径运行
./silly your_script.lua

# 或指定 Lua 库路径
./silly your_script.lua --lualib_path="lualib/?.lua"
```

#### 3. 端口已被占用

**问题**：
```
bind failed: Address already in use
```

**解决方法**：
```bash
# 查找占用端口的进程
lsof -i :8080

# 或者更换端口
# 在代码中使用不同的端口号，例如 8081
```

#### 4. 权限不足

**问题**：
```
Permission denied
```

**解决方法**：
```bash
# 给可执行文件添加执行权限
chmod +x silly

# 或者以管理员身份运行（不推荐）
sudo ./silly your_script.lua
```

### 获取帮助

如果遇到其他问题，可以：

- 查看 [GitHub Issues](https://github.com/findstr/silly/issues)
- 阅读 [Wiki 文档](https://github.com/findstr/silly/wiki)
- 参考文档中的教程和操作指南

### 调试技巧

#### 启用调试日志

```bash
./silly your_script.lua --loglevel=debug
```

#### 查看命令行帮助

```bash
./silly --help
```

输出包含所有可用选项：
```
Usage: silly main.lua [options]
Options:
  -h, --help                help
  -v, --version             version
  -d, --daemon              run as a daemon
  -p, --logpath PATH        path for the log file
  -l, --loglevel LEVEL      logging level (e.g. debug, info, warn, error)
  -f, --pidfile FILE        path for the PID file
  -L, --lualib_path PATH    path for Lua libraries
  -C, --lualib_cpath PATH   path for C Lua libraries
  -S, --socket_cpu_affinity affinity for socket thread
  -W, --worker_cpu_affinity affinity for worker threads
  -T, --timer_cpu_affinity  affinity for timer thread
```

## 总结

本教程涵盖了：

- **安装**: 克隆代码、编译、验证
- **第一个程序**: Hello World 示例
- **核心概念**: 协程、事件循环、并发任务
- **实践示例**: 定时器程序
- **故障排除**: 常见问题解决方案

现在你已经掌握了 Silly 的基础知识，可以开始构建真正的网络应用了！继续阅读 [Echo 服务器教程](./echo-server.md)，学习如何用 10 行代码实现一个每秒处理 20 万请求的高性能服务器。
