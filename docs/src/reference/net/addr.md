---
title: silly.net.addr
icon: network-wired
---

# silly.net.addr

`silly.net.addr` 提供地址解析与拼接的工具函数，主要用于处理 `host:port` 形式的地址字符串。

## 模块导入

```lua
local addr = require "silly.net.addr"
```

## 解析规则

支持以下形式的输入：

- IPv4: `"127.0.0.1:8080"`
- IPv6: `"[::1]:8080"`（必须用 `[]` 包裹，以消除端口歧义）
- 空主机: `":8080"`（表示监听所有地址）
- 域名: `"example.com:80"`
- 仅主机、无端口: `"example.com"`

对于不带 `[]` 的输入，使用**第一个** `:` 作为 host/port 分隔符。因此未包裹的 IPv6 字面量（例如 `"::1:8080"`）会被解析成 `host = ""`、`port = ":1:8080"`——请始终用 `[]` 包裹 IPv6 主机。

输出建议使用 `addr.join()` 统一格式，遇到 IPv6 会自动补 `[]`。

**注意**:
- 空主机（如 `":8080"` 或 `"[]:8080"`）解析后 `host` 为 `nil`。
- 未带端口（如 `"example.com"`）解析后 `port` 为 `nil`。

## 函数

### addr.parse(addr)

解析 `host:port` 字符串。

**参数**:
- `addr` (string): 地址字符串

**返回值**:
- `host` (string|nil)
- `port` (string|nil)

**示例**:
```lua
local host, port = addr.parse("127.0.0.1:8080")
-- host = "127.0.0.1", port = "8080"

local host2, port2 = addr.parse("[::1]:443")
-- host2 = "::1", port2 = "443"

local host3, port3 = addr.parse("example.com")
-- host3 = "example.com", port3 = nil
```

### addr.join(host, port)

拼接 `host` 与 `port` 为地址字符串。若 `host` 含 `:`（IPv6 字面量），会自动补上 `[]`。

**参数**:
- `host` (string): 主机
- `port` (string): 端口

**返回值**:
- `addr` (string)

**示例**:
```lua
addr.join("127.0.0.1", "8080")  -- "127.0.0.1:8080"
addr.join("::1", "443")         -- "[::1]:443"
addr.join("", "8080")           -- ":8080"
```

### addr.iptype(host)

判断 `host` 是否为 IP 字面量。

**参数**:
- `host` (string): 主机字符串

**返回值**:
- `integer`: 合法 IPv4 字面量返回 `4`，合法 IPv6 字面量返回 `6`，其他情况（例如域名）返回 `0`。

内部调用 `inet_pton`，分类与 OS 对合法 IP 地址的判断一致。

### addr.isv4(host)

当 `addr.iptype(host) == 4` 时返回 `true`——即 `host` 是合法的 IPv4 字面量。

### addr.isv6(host)

当 `addr.iptype(host) == 6` 时返回 `true`——即 `host` 是合法的 IPv6 字面量。仅包含 `:` 的字符串**不**算数，`inet_pton` 必须接受。

### addr.ishost(host)

当 `host` 非空且 `addr.iptype(host) == 0` 时返回 `true`——即既不是 IPv4、也不是 IPv6 字面量。调用方通常据此判断是否需要做 DNS 解析。
