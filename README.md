# Silly - 轻量级服务器框架
[![license](https://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat)](https://github.com/findstr/silly/blob/master/LICENSE)
[![CI](https://github.com/findstr/silly/actions/workflows/ci.yml/badge.svg)](https://github.com/findstr/silly/actions/workflows/ci.yml)
[![en](https://img.shields.io/badge/lang-en-red.svg)](./README.en.md)

Silly 是一个轻量、极简的服务器程序框架。

## 特性

- **底层采用 C 和 Lua 混合开发**，上层业务逻辑以 Lua 为主。
- **单进程单线程模型**，契合传统游戏开发，避免多线程并发问题。
- **避免回调地狱**，利用 Lua 协程处理异步调用。

## 性能测试

采用redis-benchmark程序来进行并发测试。

测试机型为`CPU：Intel(R) Core(TM) i5-4440 CPU @ 3.10GHz`.

[测试代码](https://github.com/findstr/silly/wiki/Benchmark)结果如下：

```
    ====== PING_INLINE ======
      100000 requests completed in 0.76 seconds
      1000 parallel clients
      3 bytes payload
      keep alive: 1

    0.00% <= 2 milliseconds
    0.03% <= 3 milliseconds
    70.15% <= 4 milliseconds
    99.35% <= 5 milliseconds
    99.70% <= 6 milliseconds
    99.98% <= 7 milliseconds
    100.00% <= 7 milliseconds
    131926.12 requests per second

    ====== PING_BULK ======
      100000 requests completed in 0.77 seconds
      1000 parallel clients
      3 bytes payload
      keep alive: 1

    0.00% <= 2 milliseconds
    0.08% <= 3 milliseconds
    87.33% <= 4 milliseconds
    99.45% <= 5 milliseconds
    99.76% <= 6 milliseconds
    100.00% <= 6 milliseconds
    130378.09 requests per second
```

## 编译

##### 安装依赖

###### Debian 系统

```bash
apt-get install libreadline-dev
```

###### CentOS 系统

```bash
yum install readline-devel
```

```bash
make
```

## 运行

```bash
./silly <main.lua> [options]
```

## 工作原理

Silly 虽然在实现上采用了三个线程，但是线程之间并不共享数据，业务逻辑只会在一个线程中执行，因此业务层的感知依然是单进程单线程模型。

下面是 Silly 的工作原理：

##### 线程划分

1. **Worker 线程**：
   - 工作在 Lua 虚拟机之上，负责处理所有通过 socket 和 timer 产生的事件。
   - 事件触发后，Worker 线程将其转换为 Lua 层进行处理。

2. **Socket 线程**：
   - 基于 `epoll/kevent/iocp` 提供高效的 socket 管理，封装了 socket 的数据传输、关闭和连接等事件。
   - 支持最大 65535 个 socket 连接，且可以通过 `silly_conf.h` 文件中的宏 `SOCKET_MAX_EXP` 来调整最大连接数。
   - 可以轻松替换成其他需要的 IO 模型，符合 `event.h` 接口定义即可。

3. **Timer 线程**：
   - 提供高分辨率低精度的定时器，分变率默认分辨率为 10ms，精度为50ms。 可以通过修改 `silly_conf.h` 中的宏 `TIMER_RESOLUTION` 和 `TIMER_ACCURACY`来调整定时器的分辨率和精度。

## 示例

Silly 提供了多个示例。

- [http](examples/http.lua)
- [patch](examples/patch.lua)
- [rpc](examples/rpc.lua)
- [socket](examples/socket.lua)
- [timer](examples/timer.lua)
- [websocket](examples/websocket.lua)

你可以运行如下脚本来启动不同的示例：

```lua
examples/start.sh http
examples/start.sh patch
examples/start.sh rpc
examples/start.sh socket
examples/start.sh timer
examples/start.sh websocket
```

如果你想一次性运行所有示例，可以执行：

```bash
examples/start.sh
```

## 测试

所有模块的测试代码位于 test 文件夹中。你可以通过以下命令运行测试：

```bash
make testall
```

## Wiki
欢迎查看 [Wiki 文档](https://github.com/findstr/silly/wiki)获取更多信息。