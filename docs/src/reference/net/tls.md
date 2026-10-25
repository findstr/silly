---
title: silly.net.tls
icon: lock
category:
  - API参考
tag:
  - 网络
  - TLS
  - SSL
  - 加密
---

# silly.net.tls

`silly.net.tls` 模块提供了基于 TLS/SSL 协议的加密网络连接功能。它在 TCP 传输层之上提供了安全的数据传输，支持服务器和客户端模式，并支持 ALPN 协议协商（如 HTTP/2）。

## 模块导入

```lua validate
local tls = require "silly.net.tls"
```

## 核心概念

### TLS/SSL 加密

TLS (Transport Layer Security) 是一种加密协议，用于在网络通信中提供安全性和数据完整性。`silly.net.tls` 基于 OpenSSL 实现，提供以下功能：

- **服务器模式**: 监听加密连接，需要配置证书和私钥
- **客户端模式**: 连接到 TLS 服务器，可选 SNI (Server Name Indication)
- **ALPN 支持**: 应用层协议协商，支持 HTTP/1.1、HTTP/2 等协议

### 证书配置

服务器端必须提供 PEM 格式的证书和私钥。证书可以是：
- 自签名证书（用于开发和测试）
- CA 签发的证书（用于生产环境）

### 异步操作

与 `silly.net.tcp` 类似，TLS 模块的读取操作是异步的，会在数据不可用时暂停协程，在数据到达后自动恢复。

### API 变更说明

TLS 模块现在使用面向对象（OO）的接口。`tls.listen` 和 `tls.connect` 返回连接对象或监听器对象，而不是文件描述符。所有操作（如 `read`, `write`, `close`）都作为对象的方法调用。

---

## 使用示例

### 示例1：HTTPS 服务器

此示例演示了如何创建一个简单的 HTTPS 服务器，处理客户端连接并返回响应。

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tls = require "silly.net.tls"
local waitgroup = require "silly.sync.waitgroup"

task.fork(function()
    local wg = waitgroup.new()

    -- 服务器证书和私钥（PEM 格式）
    local cert_pem = [[-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUPc2faaWEjGh1RklF9XPAgYS5WSMwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI1MTAwOTA5NDc1M1oXDTM1MTAw
NzA5NDc1M1owFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEApmUl+7J8zeWdOH6aiNwRSOcFePTxuAyYsAEewVtBCAEv
LVGxQtrsVvd6UosEd0aO/Qz3hvV32wYzI0ZzjGGfy0lCCx9YB05SyYY+KpDwe/os
Mf4RtBS/jN1dVX7TiRQ3KsngMFSXp2aC6IpI5ngF0PS/o2qbwkU19FCELE6G5WnA
fniUaf7XEwrhAkMAczJovqOu4BAhBColr7cQK7CQK6VNEhQBzM/N/hGmIniPbC7k
TjqyohWoLGPT+xQAe8WB39zbIHl+xEDoGAYaaI8I7TlcQWwCOIxdm+w67CQmC/Fy
GTX5fPoK96drushzwvAKphQrpQwT5MxTDvoE9xgbhQIDAQABo1MwUTAdBgNVHQ4E
FgQUsjX1LC+0rS4Ls5lcE8yg5P85LqQwHwYDVR0jBBgwFoAUsjX1LC+0rS4Ls5lc
E8yg5P85LqQwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEADqDJ
HQxRjFPSxIk5EMrxkqxE30LoWKJeW9vqublQU/qHfMo7dVTwfsAvFpTJfL7Zhhqw
l20ijbQVxPtDwPB8alQ/ScP5VRqC2032KTi9CqUqTj+y58oDxgjnm06vr5d8Xkmm
nR2xhUecGkzFYlDoXo1w8XttMUefyHS6HWLXvu94V7Y/8YB4lBCEnwFnhgkYB9CG
RsleiOiZDsaHhnNQsnM+Xl1UJVxJlMStl+Av2rCTAj/LMHniXQ+9QKI/7pNDUeCL
qSdxZephYkeRF8C/i9R5G/gAL40kUFz0sgyXuv/kss3rrxsshKKTRbxnRm1k/J73
9ZiztVOeqpcxFxmf7Q==
-----END CERTIFICATE-----
]]

    local key_pem = [[-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCmZSX7snzN5Z04
fpqI3BFI5wV49PG4DJiwAR7BW0EIAS8tUbFC2uxW93pSiwR3Ro79DPeG9XfbBjMj
RnOMYZ/LSUILH1gHTlLJhj4qkPB7+iwx/hG0FL+M3V1VftOJFDcqyeAwVJenZoLo
ikjmeAXQ9L+japvCRTX0UIQsToblacB+eJRp/tcTCuECQwBzMmi+o67gECEEKiWv
txArsJArpU0SFAHMz83+EaYieI9sLuROOrKiFagsY9P7FAB7xYHf3NsgeX7EQOgY
BhpojwjtOVxBbAI4jF2b7DrsJCYL8XIZNfl8+gr3p2u6yHPC8AqmFCulDBPkzFMO
+gT3GBuFAgMBAAECggEAD5uyVetWuKuetVNu5IKcHnYJNeDoIacQ1YWtYF7SeVE/
HyWoFojZnYjGUSLYLuYP+J20RFUXQpTQzDDKGvN3XUbIaqmshLbsnhm5EB4baM29
Qo0+FOHTW//RxvjIF/Ys/JcGMBJnTV0Yz35VO0Ur6n9i0I3qAW2jk4DP/SX6kl9T
4iJj2Y+69y0bHjesfO71nCUUH6Ym2CHJRd6A4tCeYQr3U/CXOWggpUuPTXFWptt7
uSJjbTQgwUF5H83ih1CUdto1G5LPBUXVD5x2XZshgwZsL1au9kH2l/83BAHKK8io
LQ8FekLN6FLD83mvEwFPyrVhfipbeUz3bKrgEzvOmwKBgQDUbrAgRYCLxxpmguiN
0aPV85xc+VPL+dh865QHhJ0pH/f3fah/U7van/ayfG45aIA+DI7qohGzf03xFnO4
O51RHcRhnjDbXWY5l0ZpOIpvHLLCm8gqIAkX9bt7UyE+PxRSNvUt3kVFT3ZYnYCx
Wb1kiV1oRAzTf1l0X0qamFPqdwKBgQDIhV8OWTBrsuC0U3hmvNB+DPEHnyPWBHvI
+HMflas5gJiZ+3KvrS3vBOXFB3qfTD1LQwUPqeqY0Q41Svvsq2IQAkKedJDdMuPU
RoKaV/Qln85nmibscNcwVGQNUKTeSCJQ43ktrWT01UinamsSEOYTceMqwW10LDaF
Ff1MbKNs4wKBgQDMEPiIR7vQipdF2oNjmPt1z+tpNOnWjE/20KcHAdGna9pcmQ2A
IwPWZMwrcXTBGS34bT/tDXtLnwNUkWjglgPtpFa+H6R3ViWZNUSiV3pEeqEOaW/D
Z7rUlW5gbd8FWLtAryKfyWFpz4e0YLj7pWVWas6cFqLrmO5p6BBWqfYSyQKBgHyp
rjcVa+0JAHobircUm+pB0XeTkIv1rZ98FtaEDjdpo3XXxa1CVVRMDy03QRzYISMx
P2xFjvwCvHqVa5nv0r9xKEmq3oUmpk3KqFecZsUdXQ074QcOADqjvLAqetVWsz7m
rOeg7SrpjonGt1o7904Pd9OU/Z9D/YEv8pIY2GFRAoGASEf3+igRFSECUxLh9LZC
scAxCHh9sz15swDD/rdtEqLKGcxlu74YKkBnyQ/yWA4d/enPnvdP98ThXdXnX0X4
v1HSCliKZXW8cusnBRD2IOyxuIUV/qiMfARylMvlLBccgJR8+olH9f/yF2EFWhoy
125zQzr/ESlTL+5IWeNf2sM=
-----END PRIVATE KEY-----
]]

    -- 启动 TLS 服务器
    local listener, err = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {
            {
                cert = cert_pem,
                key = key_pem,
            }
        },
        accept = function(conn)
            wg:fork(function()
                print("客户端已连接:", conn.remoteaddr)

                -- 读取 HTTP 请求
                local request, err = conn:read("\n")
                if not request then
                    print("读取错误:", err)
                    conn:close()
                    return
                end

                print("收到请求:", request)

                -- 发送 HTTP 响应
                local body = "Hello from HTTPS server!"
                local response = string.format(
                    "HTTP/1.1 200 OK\r\n" ..
                    "Content-Type: text/plain\r\n" ..
                    "Content-Length: %d\r\n" ..
                    "\r\n%s",
                    #body, body
                )

                conn:write(response)
                conn:close()
                print("连接已关闭")
            end)
        end
    }

    if not listener then
        print("启动服务器失败")
        return
    end

    print("HTTPS 服务器正在监听 127.0.0.1:8443")

    -- 等待一段时间以处理请求
    wg:wait()
    listener:close()
end)
```

### 示例2：HTTPS 客户端

此示例演示如何创建 TLS 客户端连接到 HTTPS 服务器。

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tls = require "silly.net.tls"
local dns = require "silly.net.dns"

task.fork(function()
    -- 解析域名
    local ip = dns.lookup("www.example.com", dns.A)
    if not ip then
        print("DNS 解析失败")
        return
    end

    -- 连接到 HTTPS 服务器 (端口 443)
    local conn, err = tls.connect(
        ip .. ":443",       -- 服务器地址
        {
            bind = nil,         -- 不绑定本地地址
            hostname = "www.example.com", -- SNI hostname
            alpnprotos = {"http/1.1"} -- ALPN 协议
        }
    )

    if not conn then
        print("连接失败:", err)
        return
    end

    print("已连接到服务器")

    -- 检查协商的 ALPN 协议
    local alpn = conn:alpnproto()
    if alpn then
        print("ALPN 协议:", alpn)
    end

    -- 发送 HTTP 请求
    local request = "GET / HTTP/1.1\r\n" ..
                   "Host: www.example.com\r\n" ..
                   "User-Agent: silly-tls-client\r\n" ..
                   "Connection: close\r\n\r\n"

    local ok, write_err = conn:write(request)
    if not ok then
        print("写入失败:", write_err)
        conn:close()
        return
    end

    -- 读取响应头
    local line, read_err = conn:read("\n")
    if not line then
        print("读取失败:", read_err)
        conn:close()
        return
    end

    print("响应:", line)

    -- 关闭连接
    conn:close()
    print("连接已关闭")
end)
```

### 示例3：证书热重载

此示例演示如何在运行时重载证书，实现零停机时间的证书更新。

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tls = require "silly.net.tls"
local signal = require "silly.signal"
local waitgroup = require "silly.sync.waitgroup"

task.fork(function()
    local wg = waitgroup.new()

    -- 初始证书
    local cert_v1 = [[-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
]]

    local key_v1 = [[-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
]]

    -- 新版本证书（CN=localhost2）
    local cert_v2 = [[-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
]]

    local key_v2 = [[-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
]]

    -- 启动服务器
    local listener, err = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{cert = cert_v1, key = key_v1}},
        accept = function(conn)
            wg:fork(function()
                conn:write("HTTP/1.1 200 OK\r\n\r\nHello!\n")
                conn:close()
            end)
        end
    }

    print("服务器启动，使用证书 v1 (CN=localhost)")

    -- 注册 SIGUSR1 信号处理器，用于触发证书重载
    signal.register("SIGUSR1", function()
        local ok, err = listener:reload {
            certs = {{cert = cert_v2, key = key_v2}}
        }
        if ok then
            print("证书重载成功 (CN=localhost2)")
        else
            print("证书重载失败:", err)
        end
    end)

    print("发送 SIGUSR1 信号以触发证书重载")
    print("运行: kill -USR1", silly.pid)

    wg:wait()
end)
```

---

## API 文档

### tls.listen(conf)

启动一个 TLS 服务器在给定地址上进行监听。证书、私钥或加密套件无效等配置错误会在打开监听 socket 前抛出。

- **参数**:
  - `conf`: `table` - 服务器配置表
    - `addr`: `string` (必需) - 监听地址，例如 `"127.0.0.1:8443"` 或 `":8443"`
    - `certs`: `table[]` (必需) - 证书配置列表，每个元素包含：
      - `cert`: `string` - PEM 格式的证书内容
      - `key`: `string` - PEM 格式的私钥内容
    - `backlog`: `integer|nil` (可选) - 等待连接队列的最大长度
    - `accept`: `fun(conn: silly.net.tls.conn)` (必需) - 连接处理器，为每个新连接调用
    - `ciphers`: `string|nil` (可选) - 允许的加密套件，使用 OpenSSL 格式
    - `alpnprotos`: `string[]|nil` (可选) - 支持的 ALPN 协议列表，例如 `{"http/1.1", "h2"}`
- **返回值**:
  - 成功: `silly.net.tls.listener` - 监听器对象
  - 失败: `nil, silly.errno` - I/O 错误
- **示例**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tls = require "silly.net.tls"

task.fork(function()
    local listener = tls.listen {
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        accept = function(conn)
            conn:write("Goodbye!\n")
            local ok, err = conn:close()
            if not ok then
                print("关闭失败:", err)
            end
        end
    }
end)
```

### tls.connect(addr [, opts])

建立到 TLS 安全服务器的连接（异步）。此函数会进行 TCP 连接和 TLS 握手。配置无效时抛出错误；TLS 初始化失败会释放底层连接。

- **参数**:
  - `addr`: `string` - 服务器地址，例如 `"127.0.0.1:443"`
  - `opts`: `table|nil` (可选) - 配置选项
    - `bind`: `string|nil` - 本地绑定地址
    - `hostname`: `string|nil` - 用于 SNI 的主机名（推荐设置）
    - `alpnprotos`: `string[]|nil` - ALPN 协议列表，例如 `{"h2", "http/1.1"}`
    - `timeout`: `integer|nil` - 连接和握手的超时时间（毫秒）
- **返回值**:
  - 成功: `silly.net.tls.conn` - TLS 连接对象
  - 失败: `nil, silly.errno` - I/O 错误
- **示例**:

```lua validate
local tls = require "silly.net.tls"

local conn, err = tls.connect("127.0.0.1:443", {
    hostname = "example.com",
    alpnprotos = {"http/1.1"},
    timeout = 5000  -- 5秒超时
})

if not conn then
    print("Connect failed:", err)
    return
end
```

### listener:close()

关闭 TLS 监听器。

- **返回值**:
  - 成功: `true`
  - 失败: `false, silly.errno` - I/O 错误

### listener:reload([conf])

热重载 TLS 服务器的证书配置，无需重启服务。配置无效时抛出错误，并保留当前生效的配置。

- **参数**:
  - `conf`: `table|nil` (可选) - 新的配置
    - `certs`: `table[]` - 新的证书配置
    - `ciphers`: `string` - 新的加密套件
    - `alpnprotos`: `string[]` - 新的 ALPN 协议列表
- **返回值**:
  - 成功: `true`
  - 失败: `false, silly.errno` - I/O 错误
- **示例**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tls = require "silly.net.tls"

task.fork(function()
    local listener = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        accept = function(conn)
            conn:close()
        end
    }

    -- 重新加载证书
    local ok, err = listener:reload({
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n... new ...",
            key = "-----BEGIN PRIVATE KEY-----\n... new ...",
        }}
    })

    if ok then
        print("证书重载成功")
    else
        print("证书重载失败:", err)
    end
end)
```

### conn:read(n [, timeout])

精确读取 `n` 字节，或读取直到分隔符（异步）。底层自动处理 TLS 解密。

连接尚未被本地主动关闭时，`read(0)` 立即返回 `"", nil`，不消费缓冲区中的数据。同时只允许一个协程读取；即使缓冲区已有数据，第二个读取者也会触发错误，包括 `read(0)`。

- **参数**:
  - `n`: `integer|string` - 要读取的字节数，最大为 `2^31-1`，或单字节分隔符（返回值包含分隔符本身）
  - `timeout`: `integer|nil` (可选) - 本次读取的超时（毫秒）
- **返回值**:
  - 成功: `string` - 读到的数据
  - 失败: `nil, silly.errno` - 传输层错误（例如 `errno.EOF`、`errno.TIMEDOUT`、`errno.CLOSED`，握手/记录错误统一记为 `errno.TLS`）。详见 [silly.errno](../errno.md)。
- **异步**: 数据未就绪时挂起协程，直到有数据、超时触发或连接关闭。

### conn:write(data)

经由 TLS 加密层向对端写数据。由框架缓冲、异步发送；本调用本身不会 yield。大写入分批提交，同一次写入中的小片段会合并发送；写入失败时，前面的一部分数据可能已进入发送队列。

- **参数**:
  - `data`: `string|string[]` - 单个字符串，或字符串数组
- **返回值**:
  - 成功: `true`
  - 失败: `false, silly.errno` - 通常为 `errno.CLOSED` 或 `errno.TLS`

`conn:close()` 尽力发送后关闭，条件允许时发送 TLS 关闭通知，不等待对端回复，剩余数据可能丢弃。

读侧 EOF 不会阻止尚未关闭的连接写入响应。写入成功表示 SSL 已接受数据，不保证传输层已接收或对端已收到；传输层发送失败统一由 socket 关闭通知异步报告。
连接尚未由调用方关闭时，写操作返回自身的 SSL 结果，不会被已保存的读侧错误替换；调用方关闭后返回保存的错误。
读侧尚无错误时，致命 TLS 写错误会立即保存，即使没有等待读取者；它也会结束正在等待的读取。传输层写失败不会提前中断读取，仍可由在途数据满足读取，或由 socket 关闭通知结束。
已有的缓冲明文仍可先读出，数据不足时才返回保存的读侧错误。

### conn:isalive()

检查 TLS 连接是否仍然活动。

- **返回值**: `boolean` - 连接活动返回 `true`，否则返回 `false`
- **示例**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tls = require "silly.net.tls"

task.fork(function()
    local listener = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        accept = function(conn)
            if conn:isalive() then
                print("连接活动中")
                conn:write("Status: OK\n")
            else
                print("连接已断开")
            end
            conn:close()
        end
    }
end)
```

### conn:alpnproto()

获取通过 ALPN 协商的协议。

- **返回值**: `string` - 协商的协议（如 `"http/1.1"`、`"h2"`），未协商则返回 `""`
- **示例**:

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tls = require "silly.net.tls"

task.fork(function()
    local listener = tls.listen {
        addr = "127.0.0.1:8443",
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n...",
            key = "-----BEGIN PRIVATE KEY-----\n...",
        }},
        alpnprotos = {"http/1.1", "h2"},
        accept = function(conn)
            local proto = conn:alpnproto()
            if proto == "h2" then
                print("使用 HTTP/2")
            elseif proto == "http/1.1" then
                print("使用 HTTP/1.1")
            else
                print("未协商 ALPN")
            end
            conn:close()
        end
    }
end)
```

### conn:limit(size)

设置读取缓冲区限制。缓冲数据达到限制时暂停接收，但读取、握手或 TLS 写入仍需更多输入时不受此限制。
等待读取的豁免持续到读取成功、超时或取消，期间修改限额不会撤销豁免。
传入 `nil` 取消限制；传入零时，无豁免的连接会暂停接收应用数据。

- **参数**:
  - `size`: `integer?` - 限制大小，范围为 0 至 `2^31-1` 字节

### conn:unreadbytes()

获取当前读取缓冲区中未读取的字节数。

- **返回值**: `integer` - 字节数

### conn:unsentbytes()

获取当前发送缓冲区中未发送的字节数。

- **返回值**: `integer` - 字节数

### conn.remoteaddr

获取远程地址（只读属性）。

> **注意**: `remoteaddr` 是连接对象的属性，直接访问即可，不需要加括号调用。

- **类型**: `string` - 远程地址（格式：`IP:Port`）
- **示例**:

```lua validate
local tls = require "silly.net.tls"

local conn = tls.connect("example.com:443")
if not conn then return end

print("Remote address:", conn.remoteaddr)
```

---

## 注意事项

### 证书管理

1. **证书格式**: 必须使用 PEM 格式的证书和私钥
2. **证书验证**: 客户端不验证服务器证书或主机名；`hostname` 仅用于设置 SNI。
3. **SNI 支持**: 客户端连接时建议提供 hostname 参数以支持 SNI
4. **证书链**: 如果使用中间 CA，需要将完整证书链放入 cert 字段

### 性能考虑

1. **加密开销**: TLS 加密会增加 CPU 使用，性能约为普通 TCP 的 60-80%
2. **握手延迟**: TLS 握手需要额外的往返时间（RTT）
3. **连接复用**: 对于高频通信，应尽可能复用 TLS 连接
4. **协议选择**: HTTP/2 (h2) 使用多路复用，可以减少连接数

### 安全建议

1. **密钥保护**: 私钥文件应设置严格的访问权限（如 `chmod 600`）
2. **加密套件**: 生产环境建议配置 `ciphers` 参数，禁用不安全的加密算法
3. **证书更新**: 使用 `listener:reload()` 定期更新证书，避免证书过期
4. **ALPN 协商**: 使用 `alpnprotos` 明确支持的协议，避免协议降级攻击

### 常见错误

`conn:read`/`conn:write`、`tls.connect`/`tls.listen` 返回的错误都是 [`silly.errno`](../errno.md) 值。除了标准传输错误（`errno.EOF`、`errno.CLOSED`、`errno.TIMEDOUT` 等）之外，TLS 特有失败（握手协议错误、加密套件协商失败等）统一记为 `errno.TLS`。需要具体 OpenSSL 原因时，查看服务器日志中以 `[tls] openssl fd:...` 开头的行。

最先保存的读侧错误不会被后续 TLS 或 socket 事件覆盖。读侧结束后会丢弃后续网络输入，但缓冲区中已有的明文仍可先满足读取。连接尚未由调用方关闭时，写操作返回自身的原生 SSL 结果；传输层错误通过 socket 关闭通知报告。

发生致命 TLS 错误后，`conn:isalive()` 返回假值，调用方须调用 `conn:close()` 释放连接。
收到对端的 TLS 关闭通知后，读取返回 `errno.EOF`，仍可发送响应。

- **原因**: 证书配置错误、对端不信任证书、加密套件不匹配
- **解决**: 检查 PEM 格式、使用受信任 CA、配置兼容的加密套件

### 编译要求

TLS 模块依赖 OpenSSL。OpenSSL 支持**默认启用**，不需要额外选项：

```bash
make           # 默认启用 OpenSSL
make OPENSSL=off   # 禁用 TLS 支持
```

如果构建时使用了 `OPENSSL=off`，`require "silly.net.tls"` 会失败。

## 参见

- [silly](../silly.md) - 核心模块
- [silly.net.tcp](./tcp.md) - TCP 协议支持
- [silly.net.udp](./udp.md) - UDP 协议支持
- [silly.net.dns](./dns.md) - DNS 解析器
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
