# Silly

<div align="center">

**轻量级、高性能的 Lua 服务器框架**

[![License](https://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat)](LICENSE)
[![CI](https://github.com/findstr/silly/actions/workflows/ci.yml/badge.svg)](https://github.com/findstr/silly/actions/workflows/ci.yml)
[![Documentation](https://img.shields.io/badge/docs-最新版-blue.svg)](https://findstr.github.io/silly/)

[English](README.md) | [简体中文](README_zh.md)

[特性](#-特性) • [快速开始](#-快速开始) • [案例](#-案例) • [示例](#-示例) • [文档](#-文档) • [贡献](#-贡献)

</div>

---

## ✨ 特性

- 🚀 **高性能** - 单线程架构处理每秒 20 万+ 请求
- 🧵 **协程驱动** - 清晰的 async/await 风格代码，无回调地狱
- 🌐 **丰富协议** - 内置 TCP、UDP、HTTP、WebSocket、gRPC、TLS 支持
- 💾 **数据库就绪** - 原生 MySQL、Redis、Etcd 集成
- 🔐 **安全加密** - 完整的加密套件，包括 JWT、AES、RSA、HMAC
- 📊 **可观测性** - 开箱即用的 Prometheus 指标和结构化日志
- 🔧 **开发友好** - 热更新、交互式调试器和丰富的 API

## 🚀 快速开始

### 安装

```bash
# 克隆仓库
git clone https://github.com/findstr/silly.git
cd silly

# 编译（支持 Linux、macOS、Windows）
# OpenSSL 支持默认启用（用于 TLS）
make

# 如不需要可禁用 OpenSSL
make OPENSSL=off
```

### Hello World

创建文件 `hello.lua`：

```lua
local tcp = require "silly.net.tcp"

local server = tcp.listen {
    addr = "127.0.0.1:8888",
    accept = function(conn)
        print("新连接来自", conn.remoteaddr)
        while true do
            local data, err = conn:read("\n")
            if err then
                print("客户端断开连接")
                break
            end

            conn:write("回显: " .. data)
        end
        conn:close()
    end
}

print("服务器监听在 127.0.0.1:8888")
```

运行服务器：

```bash
./silly hello.lua
```

使用 telnet 或 netcat 测试：

```bash
echo "你好 Silly\!" | nc localhost 8888
```

## 📊 性能

在 Intel Core i7-10700 @ 2.90GHz 上使用 redis-benchmark 测试：

| 测试 | 吞吐量 (请求/秒) | 平均延迟 | P99 延迟 |
|------|-------------------:|------------:|------------:|
| PING_INLINE | 235,849 | 0.230ms | 0.367ms |
| PING_MBULK  | 224,719 | 0.241ms | 0.479ms |

[查看完整基准测试结果 →](https://findstr.github.io/silly/benchmark.html)

## 🎮 案例

### 《天下英雄》手游服务器

[![天下英雄](docs/src/cases/case1.png)](https://www.taptap.cn/app/230552)

## 🎯 示例

### HTTP 服务器

```lua
local silly = require "silly"
local http = require "silly.net.http"

local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        local response_body = "你好，来自 Silly！"
        stream:respond(200, {
            ["content-type"] = "text/plain",
            ["content-length"] = #response_body,
        })
        stream:closewrite(response_body)
    end
}

print("HTTP 服务器监听在 http://0.0.0.0:8080")
```

### WebSocket 聊天

```lua
local silly = require "silly"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        if stream.header["upgrade"] ~= "websocket" then
            stream:respond(404, {})
            stream:close("Not Found")
            return
        end
        local sock, err = websocket.upgrade(stream)
        if not sock then
            print("升级失败:", err)
            return
        end
        print("新客户端已连接")
        while true do
            local data, typ = sock:read()
            if not data or typ == "close" then
                break
            end

            if typ == "text" then
                sock:write("回显: " .. data, "text")
            end
        end
        sock:close()
    end
}

print("WebSocket 服务器监听在 ws://0.0.0.0:8080")
```

### MySQL 查询

```lua
local mysql = require "silly.store.mysql"

local db = mysql.open {
    addr = "127.0.0.1:3306",
    user = "root",
    password = "password",
    database = "mydb",
    charset = "utf8mb4",
    max_open_conns = 10,
    max_idle_conns = 5,
}

local users, err = db:query("SELECT * FROM users WHERE age > ?", 18)
if users then
    for _, user in ipairs(users) do
        print(user.name, user.email)
    end
else
    print("查询失败:", err.message)
end

db:close()
```

更多示例请查看文档中的[教程部分](https://findstr.github.io/silly/tutorials/)。

## 📚 文档

完整文档请访问 **[https://findstr.github.io/silly/](https://findstr.github.io/silly/)**

- [入门指南](https://findstr.github.io/silly/tutorials/)
- [API 参考](https://findstr.github.io/silly/reference/)
- [最佳实践](https://findstr.github.io/silly/guides/)

## 🏗️ 架构

Silly 使用混合线程模型以获得最佳性能：

```
┌─────────────────────────────────────────────────────┐
│                   Silly 框架                         │
├──────────────┬──────────────┬──────────────┬────────┤
│ Worker 线程  │ Socket 线程  │ Timer 线程   │Monitor │
│  (Lua VM)    │ (epoll/kqueue│  (10ms 精度) │ 线程   │
│              │  /iocp)      │              │        │
│ • 协程调度   │ • I/O 事件   │ • 定时器     │• 健康  │
│ • 业务逻辑   │ • 6.5万连接  │ • 调度器     │  检查  │
└──────────────┴──────────────┴──────────────┴────────┘
```

核心设计原则：

- **单线程业务逻辑** - 无锁、无竞态条件
- **异步 I/O** - 事件驱动的 socket 操作
- **基于协程** - 清晰的异步代码，无回调

## 🔌 核心模块

| 模块 | 描述 | 文档 |
|--------|-------------|---------------|
| `silly.net` | TCP、UDP、HTTP、WebSocket、gRPC、TLS | [API](https://findstr.github.io/silly/reference/net/) |
| `silly.store` | MySQL、Redis、Etcd | [API](https://findstr.github.io/silly/reference/store/) |
| `silly.crypto` | AES、RSA、HMAC、Hash | [API](https://findstr.github.io/silly/reference/crypto/) |
| `silly.sync` | Channel、Mutex、WaitGroup | [API](https://findstr.github.io/silly/reference/sync/) |
| `silly.security` | JWT 认证 | [API](https://findstr.github.io/silly/reference/security/) |
| `silly.metrics` | Prometheus 指标 | [API](https://findstr.github.io/silly/reference/metrics/) |
| `silly.logger` | 结构化日志 | [API](https://findstr.github.io/silly/reference/logger.html) |

## 🛠️ 高级用法

### 命令行选项

```bash
./silly main.lua [选项]

核心选项:
  -h, --help                显示帮助信息
  -v, --version             显示版本
  -d, --daemon              以守护进程运行

日志选项:
  -p, --logpath PATH        日志文件路径
  -l, --loglevel LEVEL      日志级别 (debug/info/warn/error)
  -f, --pidfile FILE        PID 文件路径

自定义选项:
  --key=value               自定义键值对
```

使用自定义选项示例：

```bash
./silly server.lua --port=8080 --workers=4 --env=production
```

在 Lua 中访问：

```lua
local env = require "silly.env"
local port = env.get("port")        -- "8080"
local workers = env.get("workers")  -- "4"
local environment = env.get("env")  -- "production"
```

## 🧪 测试

运行完整测试套件：

```bash
# 运行所有测试
make testall

# 使用address sanitizer运行（Linux/macOS）
make test
```

## 📦 依赖

Silly 的依赖极少：

- **Lua 5.4**（内嵌）
- **jemalloc**（可选，用于更好的内存分配）
- **OpenSSL**（可选，用于 TLS 支持）
- **zlib**（内嵌，用于压缩）

所有依赖通过 Git 子模块自动构建。

## 🤝 贡献

我们欢迎贡献！详情请参阅 [CONTRIBUTING.md](CONTRIBUTING.md)。

### 开发设置

```bash
# 克隆并包含子模块
git clone --recursive https://github.com/findstr/silly.git

# 调试模式编译
make test

# 格式化代码
make fmt
```

## 📄 许可证

Silly 采用 [MIT 许可证](LICENSE)。

## 🙏 致谢

- [Lua](https://www.lua.org/) - 优雅的脚本语言
- [jemalloc](http://jemalloc.net/) - 可扩展的并发内存分配器
- [OpenSSL](https://www.openssl.org/) - 强大的加密工具包

## 📮 联系与社区

- **问题反馈**: [GitHub Issues](https://github.com/findstr/silly/issues)
- **讨论交流**: [GitHub Discussions](https://github.com/findstr/silly/discussions)
- **官方文档**: [文档站点](https://findstr.github.io/silly/)

---

<div align="center">

[⬆ 返回顶部](#silly)

</div>
