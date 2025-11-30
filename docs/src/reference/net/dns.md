---
title: silly.net.dns
icon: globe
category:
  - API参考
tag:
  - 网络
  - DNS
  - 域名解析
---

# dns (`silly.net.dns`)

`silly.net.dns` 模块提供了异步 DNS (域名系统) 解析功能。它基于 UDP 实现,支持常见的 DNS 记录类型(A、AAAA、SRV),并内置缓存机制来提高性能。模块会自动解析系统配置文件(`/etc/resolv.conf` 和 `/etc/hosts`)。

## 模块导入

```lua validate
local dns = require "silly.net.dns"
```

---

## 核心概念

### DNS 记录类型

DNS 系统定义了多种记录类型,每种类型用于不同的目的:

- **A 记录** (`dns.A`): 将域名映射到 IPv4 地址
- **AAAA 记录** (`dns.AAAA`): 将域名映射到 IPv6 地址
- **CNAME 记录**: 域名别名,会自动跟随解析
- **SRV 记录** (`dns.SRV`): 服务定位记录,包含主机、端口和优先级信息

### 缓存机制

DNS 模块内置了缓存系统:
- 根据 DNS 响应中的 TTL (Time To Live) 值自动缓存结果
- 缓存过期后自动重新查询
- `/etc/hosts` 中的条目会被永久缓存
- CNAME 记录会被递归解析并缓存最终结果

### 系统配置

模块会自动读取系统配置:
- **`/etc/resolv.conf`**: DNS 服务器配置
- **`/etc/hosts`**: 静态主机名映射

可通过环境变量自定义路径:
- `sys.dns.resolv_conf`: resolv.conf 文件路径
- `sys.dns.hosts`: hosts 文件路径

---

## API 参考

### DNS 记录类型常量

#### `dns.A`

IPv4 地址记录类型常量。

- **类型**: `integer`
- **值**: `1`
- **用途**: 查询域名对应的 IPv4 地址

#### `dns.AAAA`

IPv6 地址记录类型常量。

- **类型**: `integer`
- **值**: `28`
- **用途**: 查询域名对应的 IPv6 地址

#### `dns.SRV`

服务记录类型常量。

- **类型**: `integer`
- **值**: `33`
- **用途**: 查询服务的主机、端口、优先级和权重信息

---

### 域名解析

#### `dns.lookup(name, qtype [, timeout])`

查询指定类型的 DNS 记录并返回第一个结果(异步)。

- **参数**:
  - `name`: `string` - 要查询的域名或 IP 地址
  - `qtype`: `integer` - DNS 记录类型(`dns.A`、`dns.AAAA` 或 `dns.SRV`)
  - `timeout`: `integer|nil` (可选) - 查询超时时间(毫秒),默认 5000ms
- **返回值**:
  - 成功: `string|table` - 解析结果
    - A/AAAA 记录: 返回 IP 地址字符串
    - SRV 记录: 返回包含 `priority`、`weight`、`port`、`target` 的表
  - 失败: `nil` - 查询失败或超时
- **注意**:
  - 如果 `name` 已经是 IP 地址,会直接返回该地址
  - 会自动跟随 CNAME 记录
  - 超时后会重试最多 3 次,每次增加超时时间
- **示例**:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- 查询 IPv4 地址
    local ip = dns.lookup("www.example.com", dns.A)
    if ip then
        print("IPv4 address:", ip)
    else
        print("DNS lookup failed")
    end

    -- 查询 IPv6 地址
    local ipv6 = dns.lookup("www.example.com", dns.AAAA)
    if ipv6 then
        print("IPv6 address:", ipv6)
    end

    -- 查询 SRV 记录
    local srv = dns.lookup("_http._tcp.example.com", dns.SRV)
    if srv then
        print("Target:", srv.target, "Port:", srv.port)
    end
end)
```

#### `dns.resolve(name, qtype [, timeout])`

查询指定类型的 DNS 记录并返回所有结果(异步)。

- **参数**:
  - `name`: `string` - 要查询的域名或 IP 地址
  - `qtype`: `integer` - DNS 记录类型
  - `timeout`: `integer|nil` (可选) - 查询超时时间(毫秒),默认 5000ms
- **返回值**:
  - 成功: `table` - 包含所有解析结果的数组
    - A/AAAA 记录: IP 地址字符串数组
    - SRV 记录: SRV 记录对象数组
  - 失败: `nil` - 查询失败或超时
- **注意**:
  - 如果 `name` 已经是 IP 地址,返回包含该地址的数组
  - 返回的数组可能为空(如果没有记录)
  - 会自动跟随 CNAME 记录
- **示例**:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- 查询所有 IPv4 地址
    local ips = dns.resolve("cdn.example.com", dns.A)
    if ips then
        print("Found", #ips, "IPv4 addresses:")
        for i, ip in ipairs(ips) do
            print(i, ip)
        end
    end

    -- 查询所有 SRV 记录
    local srvs = dns.resolve("_service._tcp.example.com", dns.SRV)
    if srvs then
        for i, srv in ipairs(srvs) do
            print(string.format(
                "Server %d: %s:%d (priority=%d, weight=%d)",
                i, srv.target, srv.port, srv.priority, srv.weight
            ))
        end
    end
end)
```

---

### 配置和工具

#### `dns.server(ip)`

设置自定义 DNS 服务器地址。

- **参数**:
  - `ip`: `string` - DNS 服务器地址,格式为 `"IP:PORT"`
    - IPv4: `"8.8.8.8:53"` 或 `"223.5.5.5:53"`
    - IPv6: `"[2001:4860:4860::8888]:53"`
- **返回值**: 无
- **注意**:
  - 必须在第一次 DNS 查询前调用
  - 会覆盖从 `/etc/resolv.conf` 读取的配置
- **示例**:

```lua validate
local dns = require "silly.net.dns"

-- 使用阿里云 DNS
dns.server("223.5.5.5:53")

-- 使用 Google DNS
dns.server("8.8.8.8:53")

-- 使用 Cloudflare DNS
dns.server("1.1.1.1:53")
```

#### `dns.isname(name)`

判断字符串是否是域名(而不是 IP 地址)。

- **参数**:
  - `name`: `string` - 要判断的字符串
- **返回值**: `boolean`
  - `true`: 字符串是域名
  - `false`: 字符串是 IPv4 或 IPv6 地址
- **注意**: 这是一个同步函数,不需要在协程中调用
- **示例**:

```lua validate
local dns = require "silly.net.dns"

print(dns.isname("www.example.com"))   -- true
print(dns.isname("example.com"))       -- true
print(dns.isname("192.168.1.1"))       -- false
print(dns.isname("127.0.0.1"))         -- false
print(dns.isname("::1"))               -- false
print(dns.isname("2001:db8::1"))       -- false
```

---

## 使用示例

### 示例1：基础域名解析

查询域名的 IPv4 和 IPv6 地址:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local domain = "www.example.com"

    -- 查询 IPv4 地址
    local ipv4 = dns.lookup(domain, dns.A)
    if ipv4 then
        print("IPv4:", ipv4)
    else
        print("No IPv4 address found")
    end

    -- 查询 IPv6 地址
    local ipv6 = dns.lookup(domain, dns.AAAA)
    if ipv6 then
        print("IPv6:", ipv6)
    else
        print("No IPv6 address found")
    end
end)
```

### 示例2：多地址解析

查询所有可用的 IP 地址并选择最优的:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local domain = "cdn.example.com"

    -- 获取所有 IPv4 地址
    local ips = dns.resolve(domain, dns.A)
    if not ips or #ips == 0 then
        print("No addresses found")
        return
    end

    print("Found", #ips, "addresses:")
    for i, ip in ipairs(ips) do
        print(i, ip)
    end

    -- 简单的负载均衡：随机选择一个 IP
    local selected = ips[math.random(#ips)]
    print("Selected:", selected)
end)
```

### 示例3：SRV 记录服务发现

使用 SRV 记录发现服务实例:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- 查询 _service._protocol.domain 格式的 SRV 记录
    local srvs = dns.resolve("_http._tcp.example.com", dns.SRV)
    if not srvs or #srvs == 0 then
        print("No service instances found")
        return
    end

    -- 按优先级排序（优先级越小越优先）
    table.sort(srvs, function(a, b)
        return a.priority < b.priority
    end)

    print("Service instances:")
    for i, srv in ipairs(srvs) do
        print(string.format(
            "%d. %s:%d (priority=%d, weight=%d)",
            i, srv.target, srv.port, srv.priority, srv.weight
        ))
    end

    -- 使用优先级最高的服务器
    local primary = srvs[1]
    print(string.format(
        "Using primary server: %s:%d",
        primary.target,
        primary.port
    ))
end)
```

### 示例4：自定义 DNS 服务器

使用特定的 DNS 服务器进行查询:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- 使用阿里云公共 DNS
    dns.server("223.5.5.5:53")

    local domain = "www.example.com"
    local ip = dns.lookup(domain, dns.A)

    if ip then
        print("Resolved via Aliyun DNS:", ip)
    else
        print("DNS lookup failed")
    end
end)
```

### 示例5：带超时的查询

设置查询超时时间:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local domain = "slow.example.com"

    -- 设置 2 秒超时
    local ip = dns.lookup(domain, dns.A, 2000)
    if ip then
        print("Resolved:", ip)
    else
        print("DNS lookup timeout or failed")
    end

    -- 使用默认超时（5 秒）
    local ip2 = dns.lookup(domain, dns.A)
    if ip2 then
        print("Resolved with default timeout:", ip2)
    end
end)
```

### 示例6：IP 地址验证和解析

检查输入是否是 IP 地址或域名:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local inputs = {
        "www.example.com",
        "192.168.1.1",
        "2001:db8::1",
        "localhost.example.com",
    }

    for _, input in ipairs(inputs) do
        if dns.isname(input) then
            print(input, "is a domain name, resolving...")
            local ip = dns.lookup(input, dns.A)
            if ip then
                print("  ->", ip)
            else
                print("  -> resolution failed")
            end
        else
            print(input, "is already an IP address")
        end
    end
end)
```

### 示例7：并发 DNS 查询

同时查询多个域名以提高效率:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local domains = {
        "www.google.com",
        "www.github.com",
        "www.cloudflare.com",
        "www.amazon.com",
    }

    local wg = waitgroup.new()
    local results = {}

    for i, domain in ipairs(domains) do
        wg:fork(function()
            local ip = dns.lookup(domain, dns.A)
            results[domain] = ip
        end)
    end

    wg:wait()

    print("DNS resolution results:")
    for domain, ip in pairs(results) do
        if ip then
            print(domain, "->", ip)
        else
            print(domain, "-> FAILED")
        end
    end
end)
```

### 示例8：DNS 缓存预热

预先解析常用域名到缓存:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local common_domains = {
        "api.example.com",
        "cdn.example.com",
        "db.example.com",
    }

    print("Warming up DNS cache...")
    for _, domain in ipairs(common_domains) do
        local ips = dns.resolve(domain, dns.A)
        if ips then
            print("Cached", domain, "->", #ips, "addresses")
        end
    end

    print("Cache warmed up, subsequent queries will be faster")

    -- 后续查询会直接从缓存返回（直到 TTL 过期）
    local ip = dns.lookup("api.example.com", dns.A)
    print("Fast lookup:", ip)
end)
```

---

## 注意事项

### 1. 协程要求

所有 DNS 查询函数（`lookup` 和 `resolve`）都是异步的, 必须在协程中调用:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

-- 错误：不能在主线程调用
-- local ip = dns.lookup("example.com", dns.A)  -- 会失败

-- 正确：在协程中调用
task.fork(function()
    local ip = dns.lookup("example.com", dns.A)
    print(ip)
end)
```

### 2. DNS 服务器配置时机

必须在第一次 DNS 查询前配置服务器:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- 正确：在查询前配置
    dns.server("8.8.8.8:53")
    local ip = dns.lookup("example.com", dns.A)

    -- 错误：第一次查询后配置无效
    -- dns.server("1.1.1.1:53")  -- 这个调用会被忽略
end)
```

### 3. 返回值检查

始终检查返回值,处理查询失败的情况:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local ip = dns.lookup("nonexistent.example.com", dns.A)
    if not ip then
        print("DNS lookup failed - domain may not exist")
        return
    end

    local ips = dns.resolve("example.com", dns.A)
    if not ips or #ips == 0 then
        print("No addresses found")
        return
    end

    -- 安全地使用结果
    print("Found", #ips, "addresses")
end)
```

### 4. TTL 和缓存

DNS 响应会被缓存,但会过期:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local time = require "silly.time"
local task = require "silly.task"

task.fork(function()
    -- 第一次查询，从 DNS 服务器获取
    local ip1 = dns.lookup("example.com", dns.A)
    print("First lookup:", ip1)

    -- 立即再次查询，从缓存返回（非常快）
    local ip2 = dns.lookup("example.com", dns.A)
    print("Cached lookup:", ip2)

    -- 等待 TTL 过期（假设 TTL 是 60 秒）
    time.sleep(61000)

    -- TTL 过期后再次查询，会重新从 DNS 服务器获取
    local ip3 = dns.lookup("example.com", dns.A)
    print("After TTL expiry:", ip3)
end)
```

### 5. CNAME 自动跟随

CNAME 记录会被自动解析:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- 如果 alias.example.com 是 real.example.com 的 CNAME
    -- lookup 会自动跟随 CNAME 并返回 real.example.com 的 A 记录
    local ip = dns.lookup("alias.example.com", dns.A)
    if ip then
        print("Final IP (after CNAME resolution):", ip)
    end
end)
```

### 6. IPv6 地址格式

IPv6 地址使用冒号分隔的十六进制格式:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local ipv6 = dns.lookup("ipv6.example.com", dns.AAAA)
    if ipv6 then
        -- 格式：xx:xx:xx:xx:xx:xx:xx:xx（不是压缩格式）
        print("IPv6:", ipv6)  -- 例如：00:00:00:00:00:00:00:01
    end
end)
```

### 7. SRV 记录结构

SRV 记录包含多个字段:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local srv = dns.lookup("_http._tcp.example.com", dns.SRV)
    if srv then
        -- SRV 记录包含:
        print("Priority:", srv.priority)  -- 优先级（越小越优先）
        print("Weight:", srv.weight)      -- 权重（用于负载均衡）
        print("Port:", srv.port)          -- 服务端口
        print("Target:", srv.target)      -- 目标主机名
    end
end)
```

### 8. 超时和重试

DNS 查询有内置的超时和重试机制:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- 默认行为：
    -- - 超时时间：5 秒
    -- - 重试次数：3 次
    -- - 重试间隔：递增（5s, 10s, 15s）

    local ip = dns.lookup("example.com", dns.A)
    -- 如果第一次超时，会自动重试
    -- 最多等待 5s + 10s + 15s = 30s

    -- 自定义超时（但重试次数仍为 3）
    local ip2 = dns.lookup("example.com", dns.A, 2000)  -- 2 秒超时
end)
```

---

## 性能建议

### 1. 缓存预热

对于常用域名，提前解析以利用缓存:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"

local task = require "silly.task"

task.fork(function()
    -- 应用启动时预热缓存
    local critical_domains = {
        "api.service.com",
        "db.service.com",
        "cache.service.com",
    }

    for _, domain in ipairs(critical_domains) do
        dns.resolve(domain, dns.A)  -- 预先解析到缓存
    end

    -- 业务逻辑中的查询会更快
    local ip = dns.lookup("api.service.com", dns.A)  -- 从缓存返回
end)
```

### 2. 并发查询

使用协程并发查询多个域名:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local domains = {"site1.com", "site2.com", "site3.com"}

    -- 并发查询比串行查询快得多
    for _, domain in ipairs(domains) do
        wg:fork(function()
            dns.lookup(domain, dns.A)
        end)
    end

    wg:wait()  -- 等待所有查询完成
end)
```

### 3. 避免不必要的查询

在连接前检查是否已经是 IP 地址:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local tcp = require "silly.net.tcp"
local task = require "silly.task"

task.fork(function()
    local function connect_to_host(host, port)
        local ip
        if dns.isname(host) then
            -- 只有域名才需要解析
            ip = dns.lookup(host, dns.A)
            if not ip then
                return nil, "DNS resolution failed"
            end
        else
            -- 已经是 IP 地址，直接使用
            ip = host
        end

        local addr = string.format("%s:%d", ip, port)
        return tcp.connect(addr)
    end

    -- 这两个调用都能正确处理
    local fd1 = connect_to_host("example.com", 80)      -- 会解析
    local fd2 = connect_to_host("192.168.1.1", 80)      -- 跳过解析
end)
```

### 4. 使用快速的 DNS 服务器

选择地理位置近、响应快的 DNS 服务器:

```lua validate
local dns = require "silly.net.dns"

-- 中国大陆推荐使用阿里云或腾讯云 DNS
dns.server("223.5.5.5:53")        -- 阿里云 DNS
-- dns.server("119.29.29.29:53")  -- 腾讯云 DNS

-- 国际环境推荐使用 Google 或 Cloudflare DNS
-- dns.server("8.8.8.8:53")       -- Google DNS
-- dns.server("1.1.1.1:53")       -- Cloudflare DNS
```

### 5. 合理设置超时时间

根据网络环境调整超时时间:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- 局域网环境：使用较短的超时
    local ip1 = dns.lookup("local.service", dns.A, 1000)  -- 1 秒

    -- 公网环境：使用默认或较长的超时
    local ip2 = dns.lookup("remote.service.com", dns.A)  -- 5 秒（默认）

    -- 不可靠网络：使用更长的超时
    local ip3 = dns.lookup("unstable.service.com", dns.A, 10000)  -- 10 秒
end)
```

### 6. 监控 DNS 性能

记录 DNS 查询时间以识别性能问题:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local time = require "silly.time"
local task = require "silly.task"

task.fork(function()
    local function timed_lookup(domain, qtype)
        local start = time.monotonic()
        local result = dns.lookup(domain, qtype)
        local elapsed = time.monotonic() - start

        print(string.format(
            "DNS lookup for %s took %d ms",
            domain,
            elapsed
        ))

        return result
    end

    timed_lookup("example.com", dns.A)
end)
```

---

## 参见

- [silly.net.tcp](./tcp.md) - TCP 网络协议
- [silly.net.udp](./udp.md) - UDP 网络协议
- [silly.net.http](./http.md) - HTTP 协议（内部使用 DNS）
- [silly.sync.waitgroup](../sync/waitgroup.md) - 协程等待组
