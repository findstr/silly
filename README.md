# Silly

<div align="center">

**A Lightweight, High-Performance Server Framework for Lua**

[![License](https://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat)](LICENSE)
[![CI](https://github.com/findstr/silly/actions/workflows/ci.yml/badge.svg)](https://github.com/findstr/silly/actions/workflows/ci.yml)
[![codecov](https://codecov.io/github/findstr/silly/graph/badge.svg?token=VKS7HXU2QH)](https://codecov.io/github/findstr/silly)
[![Documentation](https://img.shields.io/badge/docs-latest-blue.svg)](https://findstr.github.io/silly/)

[English](README.md) | [简体中文](README_zh.md)

[Features](#-features) • [Quick Start](#-quick-start) • [Examples](#-examples) • [Documentation](#-documentation) • [Contributing](#-contributing)

</div>

---

## ✨ Features

- 🚀 **High Performance** - Handles 200,000+ requests/second with single-threaded architecture
- 🧵 **Coroutine-Based** - Clean async/await style code without callback hell
- 🌐 **Rich Protocols** - Built-in support for TCP, UDP, HTTP, WebSocket, gRPC, TLS
- 💾 **Database Ready** - Native MySQL, Redis, and Etcd integrations
- 🔐 **Security** - Comprehensive crypto suite including JWT, AES, RSA, HMAC
- 📊 **Observability** - Prometheus metrics and structured logging out of the box
- 🔧 **Developer Friendly** - Hot reload, interactive debugger, and extensive APIs

## 🚀 Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/findstr/silly.git
cd silly

# Build (supports Linux, macOS, Windows)
# OpenSSL support is enabled by default for TLS
make

# Disable OpenSSL if not needed
make OPENSSL=off
```

### Hello World

Create a file `hello.lua`:

```lua
local tcp = require "silly.net.tcp"

local server = tcp.listen {
    addr = "127.0.0.1:8888",
    accept = function(conn)
        print("New connection from", conn.remoteaddr)
        while true do
            local data, err = conn:read("\n")
            if err then
                print("Client disconnected")
                break
            end

            conn:write("Echo: " .. data)
        end
        conn:close()
    end
}

print("Server listening on 127.0.0.1:8888")
```

Run the server:

```bash
./silly hello.lua
```

Test with telnet or netcat:

```bash
echo "Hello Silly\!" | nc localhost 8888
```

## 📊 Performance

Benchmarked on Intel Core i7-10700 @ 2.90GHz using redis-benchmark:

| Test | Throughput (req/s) | Avg Latency | P99 Latency |
|------|-------------------:|------------:|------------:|
| PING_INLINE | 235,849 | 0.230ms | 0.367ms |
| PING_MBULK  | 224,719 | 0.241ms | 0.479ms |

[View Full Benchmark Results →](https://findstr.github.io/silly/benchmark.html)

## 🎯 Examples

### HTTP Server

```lua
local silly = require "silly"
local http = require "silly.net.http"

local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        local response_body = "Hello from Silly!"
        stream:respond(200, {
            ["content-type"] = "text/plain",
            ["content-length"] = #response_body,
        })
        stream:closewrite(response_body)
    end
}

print("HTTP server listening on http://0.0.0.0:8080")
```

### WebSocket Chat

```lua
local silly = require "silly"
local http = require "silly.net.http"
local websocket = require "silly.net.websocket"

http.listen {
    addr = "127.0.0.1:8080",
    handler = function(stream)
        if stream.header["upgrade"] ~= "websocket" then
            stream:respond(404, {})
            stream:closewrite("Not Found")
            return
        end
        local sock, err = websocket.upgrade(stream)
        if not sock then
            print("Upgrade failed:", err)
            return
        end
        print("New client connected")
        while true do
            local data, typ = sock:read()
            if not data or typ == "close" then
                break
            end

            if typ == "text" then
                sock:write("Echo: " .. data, "text")
            end
        end
        sock:close()
    end
}

print("WebSocket server listening on ws://0.0.0.0:8080")
```

### MySQL Query

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
    print("Query failed:", err.message)
end

db:close()
```

For more examples, check out the [tutorials](https://findstr.github.io/silly/tutorials/) in the documentation.

## 📚 Documentation

Comprehensive documentation is available at **[https://findstr.github.io/silly/](https://findstr.github.io/silly/)**

- [Getting Started Guide](https://findstr.github.io/silly/tutorials/)
- [API Reference](https://findstr.github.io/silly/reference/)
- [Best Practices](https://findstr.github.io/silly/guides/)

## 🏗️ Architecture

Silly uses a hybrid threading model for optimal performance:

```
┌─────────────────────────────────────────────────────┐
│                   Silly Framework                    │
├──────────────┬──────────────┬──────────────┬────────┤
│ Worker Thread│ Socket Thread│ Timer Thread │Monitor │
│  (Lua VM)    │ (epoll/kqueue│  (10ms res)  │ Thread │
│              │  /iocp)      │              │        │
│ • Coroutine  │ • I/O Events │ • Timers     │• Health│
│ • Business   │ • 65K conns  │ • Schedulers │  Check │
│   Logic      │              │              │        │
└──────────────┴──────────────┴──────────────┴────────┘
```

Key design principles:

- **Single-threaded business logic** - No locks, no race conditions
- **Asynchronous I/O** - Event-driven socket operations
- **Coroutine-based** - Clean async code without callbacks

## 🔌 Core Modules

| Module | Description | Documentation |
|--------|-------------|---------------|
| `silly.net` | TCP, UDP, HTTP, WebSocket, gRPC, TLS | [API](https://findstr.github.io/silly/reference/net/) |
| `silly.store` | MySQL, Redis, Etcd | [API](https://findstr.github.io/silly/reference/store/) |
| `silly.crypto` | AES, RSA, HMAC, Hash | [API](https://findstr.github.io/silly/reference/crypto/) |
| `silly.sync` | Channel, Mutex, WaitGroup | [API](https://findstr.github.io/silly/reference/sync/) |
| `silly.security` | JWT authentication | [API](https://findstr.github.io/silly/reference/security/) |
| `silly.metrics` | Prometheus metrics | [API](https://findstr.github.io/silly/reference/metrics/) |
| `silly.logger` | Structured logging | [API](https://findstr.github.io/silly/reference/logger.html) |

## 🛠️ Advanced Usage

### Command Line Options

```bash
./silly main.lua [options]

Core Options:
  -h, --help                Display help message
  -v, --version             Show version
  -d, --daemon              Run as daemon

Logging:
  -l, --log-level LEVEL     Log level (debug/info/warn/error)
      --log-path PATH       Log file path (effective with --daemon)
      --pid-file FILE       PID file path (effective with --daemon)

Lua Library Paths:
  -L, --lualib-path PATH    Lua library path (package.path)
  -C, --lualib-cpath PATH   Lua C library path (package.cpath)

Thread Affinity:
  -S, --socket-affinity CPU Bind socket thread to CPU core
  -W, --worker-affinity CPU Bind worker thread to CPU core
  -T, --timer-affinity CPU  Bind timer thread to CPU core

Custom Options:
  --key=value               Custom key-value pairs
```

Example with custom options:

```bash
./silly server.lua --port=8080 --workers=4 --env=production
```

Access in Lua:

```lua
local env = require "silly.env"
local port = env.get("port")        -- "8080"
local workers = env.get("workers")  -- "4"
local environment = env.get("env")  -- "production"
```

## 🧪 Testing

Run the complete test suite:

```bash
# Run all tests
make testall

# Run with address sanitizer (Linux/macOS)
make test
```

## 📦 Dependencies

Silly has minimal dependencies:

- **Lua 5.4** (embedded)
- **jemalloc** (optional, for better memory allocation)
- **OpenSSL** (optional, for TLS support)
- **zlib** (embedded, for compression)

All dependencies are automatically built via Git submodules.

## 🤝 Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

### Development Setup

```bash
# Clone with submodules
git clone --recursive https://github.com/findstr/silly.git

# Build in debug mode
make test

# Format code
make fmt
```

## 📄 License

Silly is licensed under the [MIT License](LICENSE).

## 🙏 Acknowledgments

- [Lua](https://www.lua.org/) - The elegant scripting language
- [jemalloc](http://jemalloc.net/) - Scalable concurrent memory allocator
- [OpenSSL](https://www.openssl.org/) - Robust cryptography toolkit

## 📮 Contact & Community

- **Issues**: [GitHub Issues](https://github.com/findstr/silly/issues)
- **Discussions**: [GitHub Discussions](https://github.com/findstr/silly/discussions)
- **Documentation**: [Official Docs](https://findstr.github.io/silly/)

---

<div align="center">

[⬆ Back to Top](#silly)

</div>
