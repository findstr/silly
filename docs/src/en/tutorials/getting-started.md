---
title: Getting Started
icon: rocket
category:
  - Tutorials
order: 1
---

# Getting Started

Welcome to the Silly framework! This tutorial will guide you from scratch to install, configure, and run your first high-performance network application in 10 minutes.

## Introduction

### What is Silly?

Silly is a lightweight, high-performance server framework designed for building high-concurrency network applications. It combines:

- **C Performance**: Core components written in C for exceptional performance
- **Lua Flexibility**: Business logic implemented in Lua for efficient development
- **Coroutine-Driven**: Uses Lua coroutines to implement a clean asynchronous programming model

### What is it Good For?

Silly is particularly suitable for building the following types of applications:

- **Game Servers**: High-concurrency, low-latency game backends
- **API Services**: RESTful APIs, gRPC services
- **Real-time Communication**: WebSocket services, instant messaging
- **Network Proxies**: TCP/UDP proxies, load balancers

### Performance

Test results on Intel i7-10700 @ 2.90GHz:

- **Throughput**: 200,000+ requests/second
- **Latency**: P99 < 1ms
- **Concurrency**: Supports 65,535 concurrent connections

## System Requirements

### Operating Systems

Silly supports the following operating systems:

- **Linux**: Recommended for production environments (uses epoll)
- **macOS**: Suitable for development environments (uses kqueue)
- **Windows**: Supports MinGW compilation (uses IOCP)

### Dependencies

#### Required Dependencies

- **GCC** or **Clang**: C compiler
- **Make**: Build tool
- **Git**: For cloning code and submodules

#### Optional Dependencies

- **OpenSSL**: Enable TLS/SSL support (recommended)
- **jemalloc**: Better memory allocation performance (enabled by default)

### Installing Dependencies

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
# Install Xcode Command Line Tools
xcode-select --install

# Install OpenSSL (optional)
brew install openssl
```

:::

## Installation Steps

### 1. Clone the Repository

```bash
# Clone repository (including submodules)
git clone --recursive https://github.com/findstr/silly.git
cd silly
```

::: tip Note
If you forgot to use `--recursive`, you can initialize submodules with:
```bash
git submodule update --init --recursive
```
:::

### 2. Compile the Framework

```bash
# Standard compilation
make
```

::: details Advanced Compilation Options

```bash
# Enable OpenSSL support
make OPENSSL=ON

# Use glibc memory allocator (for debugging)
make MALLOC=glibc

# Compile test version (with address sanitizer)
make test

# Clean build artifacts
make clean
```

:::

### 3. Verify Installation

```bash
# Check executable
./silly --version
```

You should see output similar to:

```
Silly version: 1.0.x
Git SHA1: xxxxxxx
Lua version: 5.4.x
```

Congratulations! Silly has been successfully installed.

## Your First Program

Let's create a simple "Hello World" program to experience Silly.

### Create hello.lua

Create a file named `hello.lua` in the silly directory:

```lua
-- Import silly core module
local silly = require "silly"

print("Hello, Silly!")
print("Current process ID:", silly.pid)
print("Framework version:", silly.version)

-- Exit program
silly.exit(0)
```

### Run the Program

```bash
./silly hello.lua
```

### Understanding the Output

You will see:

```
Hello, Silly!
Current process ID: 12345
Framework version: 1.0.x
```

::: tip What Happened?
1. `require "silly"` loads the core module and automatically starts the event loop
2. `print()` outputs information to the console
3. `silly.exit(0)` gracefully exits the process
:::

## Core Concepts

Before diving deeper, it's important to understand several core concepts of Silly.

### 1. Coroutine Model

Silly uses **Lua coroutines** to implement asynchronous programming, making async code look as clean as synchronous code.

**Traditional Callback Style** (complex, hard to maintain):

```lua
-- Callback hell example (Silly doesn't require this style)
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

**Silly Coroutine Style** (clear, readable):

```lua
-- Silly's coroutine approach
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

### 2. Event Loop

Silly uses a single-threaded event loop to handle all business logic:

```
┌─────────────────────────────┐
│   Wait for events           │
│   (socket/timer)            │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│   Dispatch events to        │
│   coroutine handlers        │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│   Execute coroutine until   │
│   suspended                 │
└──────────┬──────────────────┘
           │
           └────► Loop
```

::: info Why Single-Threaded?
The single-threaded model avoids complex multi-threading issues like locks and race conditions, while achieving high concurrency through asynchronous I/O and coroutines. This is the proven pattern used by high-performance systems like Node.js and Redis.
:::

### 3. task.fork() - Creating Concurrent Tasks

`task.fork()` is used to create new coroutine tasks for concurrent processing:

```lua
local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"

print("Main task started")

-- Create two concurrent tasks
task.fork(function()
    time.sleep(1000)  -- Sleep for 1 second
    print("Task 1 completed")
end)

task.fork(function()
    time.sleep(500)   -- Sleep for 0.5 seconds
    print("Task 2 completed")
end)

print("Main task continues")
```

**Output Order**:
```
Main task started
Main task continues
Task 2 completed        # After 0.5 seconds
Task 1 completed        # After 1 second
```

### 4. A Complete Example

Let's create a simple timer program to consolidate what we've learned:

Create `timer_demo.lua`:

```lua
local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"

print("Timer demo started")

-- Task 1: Print every second
task.fork(function()
    for i = 1, 5 do
        print(string.format("[Task1] Second %d", i))
        time.sleep(1000)
    end
end)

-- Task 2: Print every 0.5 seconds
task.fork(function()
    for i = 1, 10 do
        print(string.format("  [Task2] Iteration %d (%.1fs)", i, i * 0.5))
        time.sleep(500)
    end
end)

-- Main task: Exit after 6 seconds
task.fork(function()
    time.sleep(6000)
    print("Demo ended")
    silly.exit(0)
end)
```

Run:

```bash
./silly timer_demo.lua
```

You will see two tasks executing alternately until the program exits.

## Next Steps

Congratulations on completing the Getting Started tutorial! Now you have:

- Successfully installed and run Silly
- Understood the basic concepts of coroutines and event loops
- Learned to use `task.fork()` to create concurrent tasks
- Created your first timer program

### Recommended Learning Path

1. **[Echo Server Tutorial](./echo-server.md)** - Learn how to build a high-performance TCP server (implemented in 10 lines of code)
2. **[Core Concepts](/en/concepts/)** - Deeply understand coroutines, message queues, schedulers, and other core mechanisms
3. **[Guides](/en/guides/)** - Learn how to solve specific problems in actual development
4. **[API Reference](/en/reference/)** - Consult complete API documentation

### More Examples

Continue learning with these tutorials to master more features:

- **[HTTP Server](./http-server.md)** - Build RESTful API services
- **[WebSocket Chat](./websocket-chat.md)** - Implement real-time communication applications
- **[Database Application](./database-app.md)** - Use MySQL to store data

## Troubleshooting

### Common Issues

#### 1. Compilation Failed: lua.h Not Found

**Problem**:
```
fatal error: lua.h: No such file or directory
```

**Solution**:
```bash
# Ensure submodules are initialized
git submodule update --init --recursive
```

#### 2. Runtime: Lua Library Not Found

**Problem**:
```
module 'silly' not found
```

**Solution**:
```bash
# Run with correct path
./silly your_script.lua

# Or specify Lua library path
./silly your_script.lua --lualib_path="lualib/?.lua"
```

#### 3. Port Already in Use

**Problem**:
```
bind failed: Address already in use
```

**Solution**:
```bash
# Find process using the port
lsof -i :8080

# Or use a different port
# Use a different port number in code, e.g., 8081
```

#### 4. Permission Denied

**Problem**:
```
Permission denied
```

**Solution**:
```bash
# Add execute permission to the executable
chmod +x silly

# Or run as administrator (not recommended)
sudo ./silly your_script.lua
```

### Getting Help

If you encounter other problems:

- Check [GitHub Issues](https://github.com/findstr/silly/issues)
- Read [Wiki Documentation](https://github.com/findstr/silly/wiki)
- Refer to tutorials and guides in the documentation

### Debugging Tips

#### Enable Debug Logging

```bash
./silly your_script.lua --loglevel=debug
```

#### View Command Line Help

```bash
./silly --help
```

Output includes all available options:
```
Options:
  -h, --help                Display this help message
  -v, --version             Show version information
  -d, --daemon              Run as a daemon process
  -l, --loglevel LEVEL      Set logging level (debug/info/warn/error)
  ...
```

## Summary

This tutorial covered:

- **Installation**: Cloning code, compiling, verification
- **First Program**: Hello World example
- **Core Concepts**: Coroutines, event loop, concurrent tasks
- **Practical Example**: Timer program
- **Troubleshooting**: Common problem solutions

Now you have mastered the basics of Silly and can start building real network applications! Continue reading the [Echo Server Tutorial](./echo-server.md) to learn how to implement a high-performance server that handles 200,000 requests per second with just 10 lines of code.
