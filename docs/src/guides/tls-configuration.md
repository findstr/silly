---
title: TLS/HTTPS 配置指南
icon: lock
order: 1
category:
  - 操作指南
tag:
  - TLS
  - HTTPS
  - 安全
  - 证书
---

# TLS/HTTPS 配置指南

本指南将帮助你在 Silly 框架中配置和管理 TLS/HTTPS 服务，包括证书准备、安全配置、证书管理和性能优化。

## 为什么需要 HTTPS？

HTTPS（HTTP over TLS）在 HTTP 之上添加了 TLS 加密层，提供：

- **数据加密**: 防止中间人窃听通信内容
- **身份验证**: 通过证书验证服务器身份，防止钓鱼攻击
- **数据完整性**: 防止传输过程中数据被篡改
- **SEO 优势**: 搜索引擎优先收录 HTTPS 网站
- **浏览器信任**: 现代浏览器会对 HTTP 网站显示"不安全"警告

::: tip HTTPS 是现代 Web 的标准
从 2018 年起，Google Chrome 开始将所有 HTTP 网站标记为"不安全"。HTTPS 已经从可选项变成了必需品。
:::

## 前置要求

### 1. 编译时启用 OpenSSL 支持

Silly 的 TLS 功能依赖 OpenSSL 库，编译时需要启用：

```bash
# 安装 OpenSSL 开发库
# Ubuntu/Debian
sudo apt-get install libssl-dev

# CentOS/RHEL
sudo yum install openssl-devel

# macOS
brew install openssl

# 编译 Silly（启用 OpenSSL）
make OPENSSL=ON
```

### 2. 验证 TLS 支持

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

print("TLS 模块加载成功！")
silly.exit(0)
```

如果 `require "silly.net.tls"` 报错，说明未正确编译 OpenSSL 支持。

## 证书准备

### 开发环境：自签名证书

自签名证书适合开发和测试环境，但不应在生产环境使用。

#### 生成自签名证书

```bash
# 生成私钥和自签名证书（有效期 10 年）
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server-key.pem \
    -out server-cert.pem \
    -days 3650 \
    -subj "/CN=localhost"
```

**参数说明**：
- `-x509`: 生成自签名证书
- `-newkey rsa:2048`: 创建 2048 位 RSA 私钥
- `-nodes`: 不加密私钥（便于测试）
- `-days 3650`: 有效期 10 年
- `-subj "/CN=localhost"`: 证书通用名称（Common Name）

#### 生成 SAN 证书（支持多域名）

```bash
# 创建配置文件 san.cnf
cat > san.cnf <<EOF
[req]
default_bits = 2048
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = localhost

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *.localhost
DNS.3 = 127.0.0.1
IP.1 = 127.0.0.1
EOF

# 生成证书
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server-key.pem \
    -out server-cert.pem \
    -days 3650 \
    -config san.cnf \
    -extensions v3_req
```

#### 在代码中使用自签名证书

```lua
local silly = require "silly"
local tls = require "silly.net.tls"
local io = io

-- 读取证书和私钥文件
local cert_file = io.open("server-cert.pem", "r")
local cert_pem = cert_file:read("*a")
cert_file:close()

local key_file = io.open("server-key.pem", "r")
local key_pem = key_file:read("*a")
key_file:close()

-- 启动 HTTPS 服务器
local listenfd = tls.listen {
    addr = "0.0.0.0:8443",
    certs = {
        {
            cert = cert_pem,
            key = key_pem,
        }
    },
    accept = function(conn)
        conn:write( "HTTP/1.1 200 OK\r\n\r\nHello HTTPS!\n")
        conn:close()
    end
}

print("HTTPS 服务器运行在 https://localhost:8443")
```

::: warning 浏览器警告
自签名证书会导致浏览器显示安全警告。测试时需要手动信任该证书，或在浏览器中添加例外。
:::

### 生产环境：Let's Encrypt 免费证书

[Let's Encrypt](https://letsencrypt.org/) 提供免费的、自动化的 CA 证书，被所有主流浏览器信任。

#### 使用 Certbot 获取证书

```bash
# 安装 Certbot
# Ubuntu/Debian
sudo apt-get install certbot

# CentOS/RHEL
sudo yum install certbot

# macOS
brew install certbot

# 获取证书（需要域名和 80 端口访问权限）
sudo certbot certonly --standalone -d yourdomain.com -d www.yourdomain.com

# 证书文件位置
# 证书: /etc/letsencrypt/live/yourdomain.com/fullchain.pem
# 私钥: /etc/letsencrypt/live/yourdomain.com/privkey.pem
```

#### 在 Silly 中使用 Let's Encrypt 证书

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

-- 读取 Let's Encrypt 证书
local cert_file = io.open("/etc/letsencrypt/live/yourdomain.com/fullchain.pem", "r")
local cert_pem = cert_file:read("*a")
cert_file:close()

local key_file = io.open("/etc/letsencrypt/live/yourdomain.com/privkey.pem", "r")
local key_pem = key_file:read("*a")
key_file:close()

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {
        {
            cert = cert_pem,
            key = key_pem,
        }
    },
    accept = function(conn)
        -- 处理 HTTPS 请求
    end
}

print("HTTPS 服务器运行在 https://yourdomain.com")
```

::: tip 权限问题
Let's Encrypt 证书文件位于 `/etc/letsencrypt/` 目录，通常需要 root 权限读取。建议：
1. 复制证书到应用目录并修改权限
2. 或者使用 `sudo` 启动 Silly
3. 或者使用反向代理（如 Nginx）处理 TLS
:::

#### 自动续期证书

Let's Encrypt 证书有效期为 90 天，需要定期续期：

```bash
# 手动续期
sudo certbot renew

# 配置自动续期（添加到 crontab）
# 每天凌晨 2 点检查并续期
0 2 * * * certbot renew --quiet --post-hook "kill -USR1 $(cat /var/run/silly.pid)"
```

结合 Silly 的证书热重载功能（见下文），可以实现无缝证书更新。

### 证书格式转换

Silly 要求证书为 PEM 格式。如果你的证书是其他格式，需要转换：

#### DER 转 PEM

```bash
openssl x509 -inform der -in certificate.cer -out certificate.pem
openssl rsa -inform der -in private-key.der -out private-key.pem
```

#### PKCS#12 (.pfx/.p12) 转 PEM

```bash
# 提取证书
openssl pkcs12 -in certificate.pfx -clcerts -nokeys -out certificate.pem

# 提取私钥
openssl pkcs12 -in certificate.pfx -nocerts -nodes -out private-key.pem
```

#### PKCS#7 (.p7b) 转 PEM

```bash
openssl pkcs7 -print_certs -in certificate.p7b -out certificate.pem
```

## 基础配置

### HTTPS 服务器配置

```lua
local silly = require "silly"
local tls = require "silly.net.tls"
local http = require "silly.net.http"

-- 证书和私钥（PEM 格式）
local cert_pem = [[-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUPc2faaWEjGh1RklF9XPAgYS5WSMwDQYJKoZIhvcNAQEL
...
-----END CERTIFICATE-----
]]

local key_pem = [[-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCmZSX7snzN5Z04
...
-----END PRIVATE KEY-----
]]

-- 启动 HTTPS 服务器
local server = http.listen {
    addr = "0.0.0.0:8443",
    protocol = "https",
    tls = {
        certs = {
            {
                cert = cert_pem,
                key = key_pem,
            }
        }
    },
    handler = function(stream)
        local method, uri, header = stream:readheader()
        print(string.format("%s %s", method, uri))

        -- 发送响应
        stream:respond(200, {
            ["content-type"] = "text/plain",
        })
        stream:closewrite("Hello HTTPS!\n")
    end
}

print("HTTPS 服务器运行在 https://localhost:8443")
```

### 端口配置建议

**标准端口**：
- `443`: HTTPS 标准端口（推荐生产环境）
- `8443`: HTTPS 备用端口（常用于开发环境）

**HTTP 和 HTTPS 双栈**：

```lua
local silly = require "silly"
local http = require "silly.net.http"

-- HTTP 服务器（端口 80）
local http_server = http.listen {
    addr = "0.0.0.0:80",
    protocol = "http",
    handler = function(stream)
        -- 重定向到 HTTPS
        local host = stream.header["host"] or "localhost"
        local redirect_url = "https://" .. host .. stream.uri
        stream:respond(301, {
            ["location"] = redirect_url,
        })
        stream:closewrite("")
    end
}

-- HTTPS 服务器（端口 443）
local https_server = http.listen {
    addr = "0.0.0.0:443",
    protocol = "https",
    tls = {
        certs = {{cert = cert_pem, key = key_pem}}
    },
    handler = function(stream)
        -- 处理 HTTPS 请求
    end
}

print("HTTP (80) 自动重定向到 HTTPS (443)")
```

## 高级配置

### SNI（服务器名称指示）- 多域名支持

SNI 允许一个 IP 地址上托管多个 HTTPS 域名，每个域名使用不同的证书。

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

-- 为不同域名准备证书
local cert_example_com = io.open("example.com.pem", "r"):read("*a")
local key_example_com = io.open("example.com-key.pem", "r"):read("*a")

local cert_test_com = io.open("test.com.pem", "r"):read("*a")
local key_test_com = io.open("test.com-key.pem", "r"):read("*a")

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {
        -- 第一个证书（默认证书）
        {
            cert = cert_example_com,
            key = key_example_com,
        },
        -- 第二个证书
        {
            cert = cert_test_com,
            key = key_test_com,
        }
    },
    accept = function(conn)
        -- OpenSSL 会根据客户端的 SNI 请求自动选择正确的证书
        conn:write( "HTTP/1.1 200 OK\r\n\r\nHello!\n")
        conn:close()
    end
}

print("多域名 HTTPS 服务器运行")
```

::: tip SNI 工作原理
1. 客户端在 TLS 握手中发送目标域名（SNI 扩展）
2. 服务器根据域名选择对应的证书
3. 完成 TLS 握手并建立加密连接

OpenSSL 会自动处理 SNI 匹配，无需额外代码。
:::

### ALPN（应用层协议协商）- HTTP/2 支持

ALPN 允许客户端和服务器在 TLS 握手期间协商应用层协议（如 HTTP/1.1 或 HTTP/2）。

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {{cert = cert_pem, key = key_pem}},
    -- 声明支持的 ALPN 协议
    alpnprotos = {"h2", "http/1.1"},  -- 优先 HTTP/2，回退到 HTTP/1.1
    accept = function(conn)
        -- 检查协商结果
        local protocol = tls.alpnproto(fd)
        print("协商的协议:", protocol or "none")

        if protocol == "h2" then
            -- 处理 HTTP/2 请求
            print("使用 HTTP/2")
        elseif protocol == "http/1.1" then
            -- 处理 HTTP/1.1 请求
            print("使用 HTTP/1.1")
        else
            -- 未协商 ALPN（可能是旧客户端）
            print("使用默认协议")
        end

        conn:close()
    end
}

print("HTTPS 服务器支持 HTTP/2 和 HTTP/1.1")
```

::: tip HTTP/2 的优势
- **多路复用**: 一个连接处理多个请求，减少延迟
- **头部压缩**: HPACK 算法减少带宽消耗
- **服务器推送**: 主动推送资源到客户端
- **二进制协议**: 更高效的解析和传输
:::

### 密码套件选择（Cipher Suites）

密码套件定义了 TLS 连接使用的加密算法。配置安全的密码套件可以防止已知攻击。

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {{cert = cert_pem, key = key_pem}},
    -- 推荐的密码套件配置（TLS 1.2+）
    ciphers = table.concat({
        -- TLS 1.3 密码套件（最优先）
        "TLS_AES_128_GCM_SHA256",
        "TLS_AES_256_GCM_SHA384",
        "TLS_CHACHA20_POLY1305_SHA256",
        -- TLS 1.2 密码套件（向后兼容）
        "ECDHE-RSA-AES128-GCM-SHA256",
        "ECDHE-RSA-AES256-GCM-SHA384",
        "ECDHE-RSA-CHACHA20-POLY1305",
    }, ":"),
    accept = function(conn)
        conn:close()
    end
}

print("HTTPS 服务器使用安全的密码套件")
```

**安全建议**：

::: danger 禁用不安全的密码套件
应该禁用以下不安全的密码套件：
- 所有使用 RC4、DES、3DES 的套件（已被破解）
- 所有使用 MD5 的套件（哈希碰撞）
- 所有不提供前向保密（Forward Secrecy）的套件
- 所有使用匿名认证（aNULL）的套件
:::

### TLS 版本控制

强制使用安全的 TLS 版本，禁用过时的协议。

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {{cert = cert_pem, key = key_pem}},
    -- 使用 OpenSSL ciphers 字符串来控制 TLS 版本
    -- "!SSLv3" 禁用 SSLv3
    -- "!TLSv1" 禁用 TLS 1.0
    -- "!TLSv1.1" 禁用 TLS 1.1
    ciphers = "DEFAULT:!SSLv3:!TLSv1:!TLSv1.1",
    accept = function(conn)
        conn:close()
    end
}

print("强制使用 TLS 1.2+ 协议")
```

::: warning TLS 版本安全性
- **SSLv3**: 已被 POODLE 攻击破解，必须禁用
- **TLS 1.0/1.1**: 存在已知漏洞，不推荐使用
- **TLS 1.2**: 当前广泛使用的安全版本
- **TLS 1.3**: 最新版本，性能和安全性最佳
:::

## 证书管理

### 证书热重载（零停机更新）

Silly 支持在不重启服务的情况下重新加载证书，实现无缝证书更新。

```lua
local silly = require "silly"
local tls = require "silly.net.tls"
local signal = require "silly.signal"

-- 证书文件路径
local cert_path = "/etc/certs/server-cert.pem"
local key_path = "/etc/certs/server-key.pem"

-- 加载证书的辅助函数
local function load_certs()
    local cert_file = io.open(cert_path, "r")
    local cert_pem = cert_file:read("*a")
    cert_file:close()

    local key_file = io.open(key_path, "r")
    local key_pem = key_file:read("*a")
    key_file:close()

    return cert_pem, key_pem
end

-- 初始加载证书
local cert_pem, key_pem = load_certs()

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {{cert = cert_pem, key = key_pem}},
    accept = function(conn)
        conn:write( "HTTP/1.1 200 OK\r\n\r\nHello!\n")
        conn:close()
    end
}

print("HTTPS 服务器启动，PID:", silly.pid)

-- 注册 SIGUSR1 信号处理器，用于触发证书重载
signal.register("SIGUSR1", function()
    print("[INFO] 收到证书重载信号...")

    -- 重新加载证书文件
    local ok, err = pcall(function()
        cert_pem, key_pem = load_certs()
    end)

    if not ok then
        print("[ERROR] 证书文件读取失败:", err)
        return
    end

    -- 热重载证书
    local success, reload_err = listenfd:reload({
        certs = {{cert = cert_pem, key = key_pem}}
    })

    if success then
        print("[SUCCESS] 证书重载成功")
    else
        print("[ERROR] 证书重载失败:", reload_err)
    end
end)

print("发送 'kill -USR1 " .. silly.pid .. "' 来重载证书")
```

**触发证书重载**：

```bash
# 更新证书文件后，发送信号触发重载
kill -USR1 $(cat /var/run/silly.pid)
```

::: tip 证书热重载的好处
- **零停机时间**: 服务持续运行，不影响现有连接
- **平滑更新**: 新连接使用新证书，旧连接继续使用旧证书直到关闭
- **简化运维**: 无需协调停机维护窗口
:::

### 证书过期监控

主动监控证书过期时间，避免证书过期导致服务中断。

```lua
local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local logger = require "silly.logger"

-- 解析 PEM 证书的过期时间（需要调用 openssl 命令）
local function get_cert_expiry(cert_pem)
    -- 将证书写入临时文件
    local tmp_file = "/tmp/cert_check.pem"
    local f = io.open(tmp_file, "w")
    f:write(cert_pem)
    f:close()

    -- 使用 openssl 命令解析过期时间
    local handle = io.popen("openssl x509 -in " .. tmp_file .. " -noout -enddate")
    local result = handle:read("*a")
    handle:close()

    -- 清理临时文件
    os.remove(tmp_file)

    -- 解析输出：notAfter=Jan 7 09:47:53 2035 GMT
    local expiry_str = result:match("notAfter=(.+)")
    return expiry_str
end

-- 证书过期检查任务
local function monitor_cert_expiry(cert_pem, alert_days)
    alert_days = alert_days or 30  -- 默认提前 30 天告警

    task.fork(function()
        while true do
            local expiry_str = get_cert_expiry(cert_pem)
            logger.info("证书过期时间:", expiry_str)

            -- 这里可以添加更复杂的日期解析和告警逻辑
            -- 例如：计算剩余天数，小于 alert_days 时发送告警

            -- 每天检查一次
            time.sleep(86400000)  -- 24 小时
        end
    end)
end

local cert_pem = io.open("server-cert.pem", "r"):read("*a")
local key_pem = io.open("server-key.pem", "r"):read("*a")

-- 启动证书过期监控
monitor_cert_expiry(cert_pem, 30)

-- 启动 HTTPS 服务器
-- ...
```

::: tip 集成告警系统
在生产环境中，可以将证书过期告警集成到监控系统（如 Prometheus、Grafana）或发送通知（邮件、短信、Slack）。
:::

### 证书链配置

当使用中间 CA 颁发的证书时，需要配置完整的证书链。

**证书链结构**：
```
服务器证书 (your-domain.crt)
    ↓
中间 CA 证书 (intermediate.crt)
    ↓
根 CA 证书 (root.crt)  [客户端已信任]
```

**创建证书链文件**：

```bash
# 合并服务器证书和中间 CA 证书
cat your-domain.crt intermediate.crt > fullchain.pem

# 如果有多个中间 CA
cat your-domain.crt intermediate1.crt intermediate2.crt > fullchain.pem
```

**在 Silly 中使用证书链**：

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

-- fullchain.pem 包含服务器证书 + 中间 CA 证书
local fullchain_pem = io.open("fullchain.pem", "r"):read("*a")
local key_pem = io.open("private-key.pem", "r"):read("*a")

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {
        {
            cert = fullchain_pem,  -- 完整的证书链
            key = key_pem,
        }
    },
    accept = function(conn)
        conn:close()
    end
}

print("HTTPS 服务器使用完整证书链")
```

::: warning 证书链顺序
证书链文件中的证书必须按照以下顺序排列：
1. 服务器证书（叶子证书）
2. 中间 CA 证书（按层级从下到上）
3. 不需要包含根 CA 证书（客户端已内置）

顺序错误会导致客户端无法验证证书链。
:::

## 性能优化

### TLS Session 缓存

TLS 握手是一个昂贵的操作（需要多次往返和加密计算）。Session 缓存允许客户端重用之前的 TLS 会话，跳过完整握手。

**OpenSSL 自动启用 Session 缓存**：

OpenSSL 默认启用了 session 缓存，Silly 的 TLS 实现会自动受益：

- **Session ID**: 服务器分配一个 session ID，客户端在后续连接中提供该 ID
- **Session Ticket**: 服务器加密 session 状态并发送给客户端，无需服务器存储

**性能提升**：
- 首次连接：完整 TLS 握手（~2-3 RTT）
- 会话恢复：简化握手（~1 RTT），减少 CPU 开销

::: tip TLS 1.3 的优势
TLS 1.3 引入了 0-RTT 恢复机制，首次往返即可发送应用数据，进一步减少延迟。
:::

### OCSP Stapling（证书状态在线查询）

OCSP Stapling 允许服务器主动提供证书吊销状态，避免客户端单独查询 OCSP 服务器。

**优势**：
- 减少客户端的额外网络请求
- 提升 TLS 握手速度
- 提高隐私性（客户端不向 CA 泄露访问记录）

::: info OpenSSL 配置
Silly 的 TLS 模块基于 OpenSSL，OCSP Stapling 需要在 OpenSSL 上下文中启用。当前版本不直接支持 OCSP Stapling 配置，建议使用反向代理（如 Nginx）处理。
:::

### 连接复用

对于高频通信，复用 TLS 连接可以显著降低握手开销。

```lua
local silly = require "silly"
local tls = require "silly.net.tls"
local dns = require "silly.net.dns"

-- 连接池
local connection_pool = {}

-- 获取或创建连接
local function get_connection(host, port)
    local key = host .. ":" .. port
    local conn = connection_pool[key]

    -- 检查连接是否仍然有效
    if conn and conn:isalive() then
        return conn
    end

    -- 创建新连接
    local ip = dns.lookup(host, dns.A)
    conn = tls.connect(ip .. ":" .. port, {hostname = host, alpnprotos = {"http/1.1"}})

    if conn then
        connection_pool[key] = conn
    end

    return conn
end

-- 发送请求（复用连接）
local function send_request(host, port, request)
    local conn = get_connection(host, port)
    if not conn then
        return nil, "connection failed"
    end

    conn:write(request)
    local response = conn:read("\r\n")
    return response
end

local silly = require "silly"
local task = require "silly.task"

task.fork(function()
    -- 发送多个请求，复用同一个连接
    for i = 1, 10 do
        local response = send_request("example.com", 443, "GET / HTTP/1.1\r\n\r\n")
        print(response)
    end
end)
```

::: tip HTTP/2 的连接复用
HTTP/2 原生支持多路复用，一个连接可以并发处理多个请求。使用 HTTP/2 时无需手动管理连接池。
:::

### 性能监控指标

监控以下指标来优化 TLS 性能：

```lua
local silly = require "silly"
local metrics = require "silly.metrics.prometheus"

-- 定义 TLS 相关指标
local tls_handshake_duration = metrics.histogram(
    "tls_handshake_duration_seconds",
    "TLS 握手耗时",
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0}
)

local tls_connections_total = metrics.counter(
    "tls_connections_total",
    "TLS 连接总数"
)

local tls_handshake_errors_total = metrics.counter(
    "tls_handshake_errors_total",
    "TLS 握手失败次数"
)

-- 在连接处理中收集指标
local function handle_connection(fd, addr)
    local start_time = silly.time.now()

    -- TLS 握手在 tls.listen 的 accept 回调时已经完成
    local handshake_duration = (silly.time.now() - start_time) / 1000.0
    tls_handshake_duration:observe(handshake_duration)
    tls_connections_total:inc()

    -- 处理业务逻辑
    -- ...
end
```

## 故障排除

### 常见错误

#### 1. 握手失败：证书验证错误

**错误信息**：
```
certificate verify failed
SSL_ERROR_SSL: error:14090086:SSL routines:ssl3_get_server_certificate:certificate verify failed
```

**原因**：
- 证书过期
- 证书链不完整（缺少中间 CA）
- 域名不匹配（CN 或 SAN）
- 客户端不信任根 CA

**解决方法**：

```bash
# 检查证书有效期
openssl x509 -in server-cert.pem -noout -dates

# 检查证书链
openssl s_client -connect localhost:8443 -showcerts

# 检查域名匹配
openssl x509 -in server-cert.pem -noout -text | grep -A1 "Subject:"
```

#### 2. 握手失败：密码套件不匹配

**错误信息**：
```
no shared cipher
SSL_ERROR_SSL: error:141640B5:SSL routines:tls_construct_client_hello:no ciphers available
```

**原因**：
- 客户端和服务器没有共同支持的密码套件
- 服务器配置过于严格，禁用了所有客户端支持的套件

**解决方法**：

```lua
-- 放宽密码套件限制（开发环境）
ciphers = "HIGH:!aNULL:!MD5"

-- 生产环境使用推荐配置
ciphers = "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384"
```

#### 3. 私钥和证书不匹配

**错误信息**：
```
key values mismatch
SSL_CTX_use_PrivateKey_file() failed
```

**原因**：
- 私钥文件和证书文件不匹配
- 私钥文件损坏或格式错误

**解决方法**：

```bash
# 验证私钥和证书是否匹配
# 两个命令的输出应该完全相同
openssl x509 -noout -modulus -in server-cert.pem | openssl md5
openssl rsa -noout -modulus -in server-key.pem | openssl md5
```

#### 4. 端口已被占用

**错误信息**：
```
bind failed: Address already in use
```

**解决方法**：

```bash
# 查找占用 443 端口的进程
sudo lsof -i :443
# 或
sudo netstat -tulpn | grep :443

# 停止占用端口的进程
sudo kill <PID>

# 或者更换端口
addr = "0.0.0.0:8443"
```

#### 5. 客户端不信任自签名证书

**浏览器错误**：
```
NET::ERR_CERT_AUTHORITY_INVALID
Your connection is not private
```

**解决方法**：

**方法 1: 临时信任（仅测试）**
- Chrome: 点击 "Advanced" → "Proceed to localhost (unsafe)"
- Firefox: "Advanced" → "Accept the Risk and Continue"

**方法 2: 添加到系统信任（本地开发）**

```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain server-cert.pem

# Linux (Ubuntu/Debian)
sudo cp server-cert.pem /usr/local/share/ca-certificates/server-cert.crt
sudo update-ca-certificates

# Windows
certutil -addstore -f "ROOT" server-cert.pem
```

**方法 3: 使用受信任的证书**
- 生产环境使用 Let's Encrypt 或商业 CA 证书

### 调试工具

#### OpenSSL s_client（测试 TLS 连接）

```bash
# 连接到 HTTPS 服务器并显示详细信息
openssl s_client -connect localhost:8443 -showcerts

# 测试特定 TLS 版本
openssl s_client -connect localhost:8443 -tls1_2
openssl s_client -connect localhost:8443 -tls1_3

# 测试 SNI
openssl s_client -connect localhost:8443 -servername example.com

# 测试 ALPN
openssl s_client -connect localhost:8443 -alpn h2,http/1.1
```

#### curl（测试 HTTPS 请求）

```bash
# 发送 HTTPS 请求（忽略证书验证）
curl -k https://localhost:8443

# 显示详细信息
curl -v https://localhost:8443

# 显示 TLS 握手信息
curl -v --trace-ascii - https://localhost:8443

# 指定客户端证书（双向 TLS）
curl --cert client-cert.pem --key client-key.pem https://localhost:8443
```

#### 在线工具

- **SSL Labs Server Test**: https://www.ssllabs.com/ssltest/
  - 全面检测 HTTPS 配置安全性
  - 提供评分和改进建议
  - 仅支持公网可访问的服务器

- **SSL Checker**: https://www.sslshopper.com/ssl-checker.html
  - 快速检查证书安装情况
  - 验证证书链完整性

## 安全最佳实践

### 1. 使用强密码套件

```lua
-- 推荐配置（TLS 1.2+ with Forward Secrecy）
ciphers = "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305"
```

### 2. 强制使用 TLS 1.2+

```lua
-- 禁用 SSLv3, TLS 1.0, TLS 1.1
ciphers = "DEFAULT:!SSLv3:!TLSv1:!TLSv1.1"
```

### 3. 保护私钥文件

```bash
# 设置严格的文件权限
chmod 600 server-key.pem
chown app-user:app-user server-key.pem

# 不要将私钥提交到版本控制
echo "*.pem" >> .gitignore
echo "*.key" >> .gitignore
```

### 4. 启用 HSTS（HTTP 严格传输安全）

```lua
-- 在 HTTP 响应中添加 HSTS 头
stream:respond(200, {
    ["strict-transport-security"] = "max-age=31536000; includeSubDomains; preload",
})
stream:closewrite(body)
```

HSTS 强制浏览器只通过 HTTPS 访问网站，防止中间人攻击。

### 5. 定期更新证书

- Let's Encrypt 证书每 90 天过期，配置自动续期
- 监控证书过期时间，提前 30 天更新
- 使用证书热重载实现无缝更新

### 6. 使用证书固定（Certificate Pinning）

对于移动应用或关键服务，可以实现证书固定，防止中间人攻击：

```lua
-- 客户端示例：验证服务器证书指纹
local expected_fingerprint = "AA:BB:CC:DD:..."

-- 在实际应用中，需要获取并验证证书指纹
-- 这通常在客户端 SDK 中实现
```

## 完整示例：生产级 HTTPS 服务器

```lua
local silly = require "silly"
local http = require "silly.net.http"
local signal = require "silly.signal"
local logger = require "silly.logger"

-- 配置
local config = {
    http_port = 80,
    https_port = 443,
    cert_path = "/etc/certs/fullchain.pem",
    key_path = "/etc/certs/privkey.pem",
}

-- 加载证书
local function load_certs()
    local cert_file = io.open(config.cert_path, "r")
    local cert_pem = cert_file:read("*a")
    cert_file:close()

    local key_file = io.open(config.key_path, "r")
    local key_pem = key_file:read("*a")
    key_file:close()

    return cert_pem, key_pem
end

local cert_pem, key_pem = load_certs()

-- HTTP 服务器（重定向到 HTTPS）
local http_server = http.listen {
    addr = "0.0.0.0:" .. config.http_port,
    protocol = "http",
    handler = function(stream)
        local method, uri, header = stream:readheader()
        local host = header["host"] or "localhost"
        local redirect_url = "https://" .. host .. uri

        logger.info(string.format("[HTTP] %s %s -> %s", method, uri, redirect_url))

        stream:respond(301, {
            ["location"] = redirect_url,
            ["content-type"] = "text/plain",
        })
        stream:closewrite("Redirecting to HTTPS...\n")
    end
}

-- HTTPS 服务器
local https_server = http.listen {
    addr = "0.0.0.0:" .. config.https_port,
    protocol = "https",
    tls = {
        certs = {{cert = cert_pem, key = key_pem}},
        alpnprotos = {"h2", "http/1.1"},
        ciphers = "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305",
    },
    handler = function(stream)
        local method, uri, header = stream:readheader()
        local protocol = stream.version

        logger.info(string.format("[HTTPS/%s] %s %s", protocol, method, uri))

        -- 处理请求
        if uri == "/" then
            stream:respond(200, {
                ["content-type"] = "text/html; charset=utf-8",
                ["strict-transport-security"] = "max-age=31536000; includeSubDomains",
            })
            stream:closewrite([[
<!DOCTYPE html>
<html>
<head><title>Silly HTTPS Server</title></head>
<body>
    <h1>欢迎使用 Silly HTTPS 服务器</h1>
    <p>当前协议: ]] .. protocol .. [[</p>
</body>
</html>
]])
        else
            stream:respond(404, {
                ["content-type"] = "text/plain",
            })
            stream:closewrite("404 Not Found\n")
        end
    end
}

logger.info("HTTP 服务器运行在端口 " .. config.http_port)
logger.info("HTTPS 服务器运行在端口 " .. config.https_port)

-- 证书热重载
signal.register("SIGUSR1", function()
    logger.info("收到证书重载信号...")

    local ok, err = pcall(function()
        cert_pem, key_pem = load_certs()
    end)

    if not ok then
        logger.error("证书文件读取失败:", err)
        return
    end

    -- 重载 HTTPS 服务器的证书
    local success, reload_err = https_server:reload({
        certs = {{cert = cert_pem, key = key_pem}}
    })

    if success then
        logger.info("证书重载成功")
    else
        logger.error("证书重载失败:", reload_err)
    end
end)

logger.info("发送 'kill -USR1 " .. silly.pid .. "' 来重载证书")
```

运行服务器：

```bash
# 编译（启用 OpenSSL）
make OPENSSL=ON

# 运行服务器（需要 root 权限绑定 80/443 端口）
sudo ./silly https_server.lua
```

## 总结

本指南涵盖了 Silly 框架中 TLS/HTTPS 配置的各个方面：

- **证书准备**: 自签名证书、Let's Encrypt、证书格式转换
- **基础配置**: HTTPS 服务器、端口配置、HTTP 到 HTTPS 重定向
- **高级配置**: SNI 多域名、ALPN HTTP/2、密码套件、TLS 版本控制
- **证书管理**: 热重载、过期监控、证书链
- **性能优化**: Session 缓存、连接复用、性能指标
- **故障排除**: 常见错误、调试工具
- **安全实践**: 强密码套件、HSTS、私钥保护

::: tip 推荐阅读
- [silly.net.tls API 参考](/reference/net/tls.md) - TLS 模块完整 API 文档
- [silly.net.http API 参考](/reference/net/http.md) - HTTP/HTTPS 服务器 API
- [HTTPS 教程](/tutorials/http-server.md) - 构建一个完整的 HTTPS 应用
:::
