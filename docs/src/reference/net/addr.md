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

输入是宽容的，解析遵循以下约定：

- IPv4: `"127.0.0.1:8080"`
- IPv6（推荐）: `"[::1]:8080"`
- IPv6（兼容）: `"::1:8080"`（以最后一个 `:` 作为端口分隔）
- 空主机: `":8080"`（表示监听所有地址）
- 域名: `"example.com:80"`

输出建议使用 `addr.join()` 统一格式，尤其是 IPv6 会自动补 `[]`。

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

拼接 `host` 与 `port` 为地址字符串。若 `host` 是 IPv6，会自动添加 `[]`。

**参数**:
- `host` (string): 主机地址
- `port` (string): 端口

**返回值**:
- `addr` (string)

**示例**:
```lua
addr.join("127.0.0.1", "8080")  -- "127.0.0.1:8080"
addr.join("::1", "443")         -- "[::1]:443"
addr.join("", "8080")           -- ":8080"
```

### addr.isv4(host)

判断是否为 IPv4 形式（弱校验，仅检查字符）。

### addr.isv6(host)

判断是否包含 `:`（弱校验）。

### addr.ishost(host)

判断是否为域名样式（包含字母且不含 `:`）。
