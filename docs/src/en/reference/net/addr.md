---
title: silly.net.addr
icon: network-wired
---

# silly.net.addr

`silly.net.addr` provides address parsing and joining helpers for `host:port` strings.

## Module Import

```lua
local addr = require "silly.net.addr"
```

## Parsing Rules

Input parsing is tolerant and follows these rules:

- IPv4: `"127.0.0.1:8080"`
- IPv6 (recommended): `"[::1]:8080"`
- IPv6 (compatible): `"::1:8080"` (uses the last `:` as the port separator)
- Empty host: `":8080"` (listen on all addresses)
- Domain: `"example.com:80"`

For output, prefer `addr.join()` which normalizes IPv6 with brackets.

**Notes**:
- Empty hosts (e.g. `":8080"` or `"[]:8080"`) return `host = nil`.
- Inputs without a port (e.g. `"example.com"`) return `port = nil`.

## Functions

### addr.parse(addr)

Parse a `host:port` string.

**Parameters**:
- `addr` (string): address string

**Returns**:
- `host` (string|nil)
- `port` (string|nil)

**Example**:
```lua
local host, port = addr.parse("127.0.0.1:8080")
-- host = "127.0.0.1", port = "8080"

local host2, port2 = addr.parse("[::1]:443")
-- host2 = "::1", port2 = "443"

local host3, port3 = addr.parse("example.com")
-- host3 = "example.com", port3 = nil
```

### addr.join(host, port)

Join `host` and `port` into a normalized address string. IPv6 hosts are wrapped in `[]`.

**Parameters**:
- `host` (string): host
- `port` (string): port

**Returns**:
- `addr` (string)

**Example**:
```lua
addr.join("127.0.0.1", "8080")  -- "127.0.0.1:8080"
addr.join("::1", "443")         -- "[::1]:443"
addr.join("", "8080")           -- ":8080"
```

### addr.isv4(host)

Check if `host` looks like IPv4 (weak validation).

### addr.isv6(host)

Check if `host` contains `:`.

### addr.ishost(host)

Check if `host` looks like a domain name (contains letters and no `:`).
