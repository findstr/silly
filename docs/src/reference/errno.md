---
title: silly.errno
icon: triangle-exclamation
category:
  - API参考
tag:
  - 核心
  - 错误处理
  - 网络
---

# silly.errno

`silly.errno` 把传输层的错误码归一到一张表里。传输层调用不再返回裸 OS errno 数字（Linux/macOS/Windows 各不相同）或散乱的字符串，而是返回这张表里的值——你可以可靠地用 `==` 判等分支。

## 模块导入

```lua
local errno = require "silly.errno"
```

## 如何比较

错误值是普通的 Lua 值（当前实现为带数字后缀的字符串，例如 `"Operation timed out (110)"`）。

**只有当错误直接来自以下 4 个模块时，才允许 `err == errno.X` 的业务分支：**

- `silly.net`
- `silly.net.tcp`
- `silly.net.tls`
- `silly.net.udp`

其它模块——`silly.net.dns`、`silly.net.cluster`、`silly.net.http`、`silly.net.websocket`、`silly.net.grpc`、`silly.store.*`、用户自己的包装层……——哪怕底层有某层透传了一个 errno 值过来，对调用者而言它就是一个不透明的字符串。**只能用来打日志或原样返回，永远不要 `err == errno.X`**。

允许的 4 个模块里这样用：

```lua
local tcp = require "silly.net.tcp"
local errno = require "silly.errno"
local logger = require "silly.logger"

local conn, err = tcp.connect("127.0.0.1:8080", {timeout = 1000})
if not conn then
    if err == errno.TIMEDOUT then
        -- 超时
    elseif err == errno.CONNREFUSED then
        -- 对端无监听
    else
        logger.error("connect failed:", err)  -- 直接打印也可
    end
end
```

非传输层模块的正确写法：

```lua
-- 错误——cluster 不在允许列表里，即使内部确实是 errno.TIMEDOUT
local resp, err = cluster.call(peer, "hello", req)
if err == errno.TIMEDOUT then     -- ❌ 禁止
    retry_later()
end

-- 正确——记日志然后 drop through
if not resp then
    logger.error("cluster call failed:", err)
    return
end
```

## 适用范围

**产生 / 透传：** 任何层都可以把 `errno` 值当作错误返回。

**做业务分支（`err == errno.X`）：** 只允许当错误来自 **`silly.net`、`silly.net.tcp`、`silly.net.tls`、`silly.net.udp`** 这 4 个模块时——即你直接持有传输层 conn/listener 并在检查它们的 `read` / `write` / `recvfrom` / `sendto` / `connect` / `listen` / `close` / `bind` 返回的错误。

**其它模块一律禁止**，即使你确定里面就是一个 errno 值：`silly.net.dns`、`silly.net.cluster`、`silly.net.http`、`silly.net.websocket`、`silly.net.grpc`、`silly.store.*`、应用层 API……对调用者来说错误是不透明字符串。记日志、原样返回、或者和该 API 自己定义的 sentinel 比较都可以，**但绝对不能** `err == errno.X`。

通过传输层 `close` 回调或 `read` 返回值报告的「对端正常关闭」对应 `errno.EOF`——不是 `nil`。

## 全部常量

### 标准 errno（来自宿主 OS）

数字码因平台而异，但身份不变：Linux 和 Windows 下的 `errno.CONNREFUSED`，都和对应平台上传输调用返回的错误值相等。

| 名称 | 含义 |
|------|------|
| `INTR` | Interrupted system call |
| `ACCES` | Permission denied |
| `BADF` | Bad file descriptor |
| `FAULT` | Bad address |
| `INVAL` | Invalid argument |
| `MFILE` | Too many open files |
| `NFILE` | Too many open files in system |
| `NOMEM` | Cannot allocate memory |
| `NOBUFS` | No buffer space available |
| `NOTSOCK` | Socket operation on non-socket |
| `OPNOTSUPP` | Operation not supported |
| `AFNOSUPPORT` | Address family not supported by protocol |
| `PROTONOSUPPORT` | Protocol not supported |
| `ADDRINUSE` | Address already in use |
| `ADDRNOTAVAIL` | Cannot assign requested address |
| `NETDOWN` | Network is down |
| `NETUNREACH` | Network is unreachable |
| `NETRESET` | Network dropped connection on reset |
| `HOSTUNREACH` | No route to host |
| `CONNABORTED` | Software caused connection abort |
| `CONNRESET` | Connection reset by peer |
| `CONNREFUSED` | Connection refused |
| `TIMEDOUT` | Operation timed out |
| `ISCONN` | Transport endpoint is already connected |
| `NOTCONN` | Transport endpoint is not connected |
| `INPROGRESS` | Operation now in progress |
| `ALREADY` | Operation already in progress |
| `AGAIN` | Resource temporarily unavailable |
| `WOULDBLOCK` | Operation would block |
| `PIPE` | Broken pipe |
| `DESTADDRREQ` | Destination address required |
| `MSGSIZE` | Message too long |
| `PROTOTYPE` | Protocol wrong type for socket |
| `NOPROTOOPT` | Protocol not available |

### Silly 特有错误

由 silly 传输层产生，不对应 OS errno。

| 名称 | 含义 |
|------|------|
| `RESOLVE` | DNS 解析失败 |
| `NOSOCKET` | 无可用 socket |
| `CLOSING` | 套接字正在关闭 |
| `CLOSED` | 套接字已关闭 |
| `EOF` | 对端正常半关闭（有序关闭） |
| `TLS` | TLS 握手或记录层错误 |

## 常见模式

### 区分超时与其他错误

```lua
local data, err = conn:read(4, 1000)  -- 1 秒超时
if not data then
    if err == errno.TIMEDOUT then
        -- 可重试，或放弃本次请求
    elseif err == errno.EOF then
        -- 对端关闭，跳出读循环
    else
        logger.error("read failed:", err)
    end
end
```

### 在读循环里识别正常关闭

```lua
while true do
    local line, err = conn:read("\n")
    if err then
        if err ~= errno.EOF then
            logger.error("tcp read error:", err)
        end
        break
    end
    handle(line)
end
```

### 细分 connect 失败

```lua
local c, err = tcp.connect(addr, {timeout = 2000})
if not c then
    if err == errno.TIMEDOUT then       -- 对端慢/不可达
    elseif err == errno.CONNREFUSED then -- 无监听
    elseif err == errno.RESOLVE then     -- DNS 失败
    elseif err == errno.HOSTUNREACH then -- 路由不可达
    end
end
```

## 注意事项

- 错误的字符串表示里带有数字后缀（例如 `"Operation timed out (110)"`），具体数值还会因平台而异。务必按身份比较（`err == errno.X`），不要按字符串字面量比较。
- 访问未知常量（例如 `errno.NOTDEFINED`）**不会**抛错——errno 表带有 `__index` 兜底，会返回 `"Unknown error 'NAME'"` 并缓存供后续使用。这让运行时新增了文档未列出的错误码时，模式匹配代码也不会崩溃；但你写的那一分支永远不会与真实错误相等。
- 错误穿过上层 API（HTTP 流、gRPC 客户端、channel 关闭原因）后可能被字符串化或包装，请参阅该上层 API 的错误约定，不要回过头来和 `silly.errno` 比较。
- 常量可能随时间扩展；只处理已知子集的代码应该走日志/透传路径，而不是 `assert(false)`。
