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

Input parsing accepts these forms:

- IPv4: `"127.0.0.1:8080"`
- IPv6: `"[::1]:8080"` (brackets required to disambiguate the port)
- Empty host: `":8080"` (listen on all addresses)
- Domain: `"example.com:80"`
- Host only, no port: `"example.com"`

For non-bracketed input, the **first** `:` is used as the host/port separator. Unbracketed IPv6 literals (e.g. `"::1:8080"`) are therefore parsed as host `""` and port `":1:8080"` — always wrap IPv6 hosts in `[]`.

For output, prefer `addr.join()` which wraps IPv6 hosts in `[]` automatically.

**Notes**:
- Empty host (e.g. `":8080"` or `"[]:8080"`) returns `host = nil`.
- Input without a port (e.g. `"example.com"`) returns `port = nil`.

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

Join `host` and `port` into a normalized address string. Hosts containing `:` (i.e. IPv6 literals) are wrapped in `[]` automatically.

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

### addr.iptype(host)

Classify `host` as an IP literal.

**Parameters**:
- `host` (string): host string

**Returns**:
- `integer`: `4` for a valid IPv4 literal, `6` for a valid IPv6 literal, `0` otherwise (e.g. domain names)

Uses `inet_pton` internally, so the classification matches what the OS considers a valid IP address.

### addr.isv4(host)

Returns `true` iff `addr.iptype(host) == 4` — i.e. `host` is a syntactically valid IPv4 literal.

### addr.isv6(host)

Returns `true` iff `addr.iptype(host) == 6` — i.e. `host` is a syntactically valid IPv6 literal. A string that merely contains `:` is **not** enough; `inet_pton` must accept it.

### addr.ishost(host)

Returns `true` iff `host` is non-empty and `addr.iptype(host) == 0` — i.e. it is neither a valid IPv4 nor a valid IPv6 literal. Typical callers use this to decide whether a DNS lookup is needed.
