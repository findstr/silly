---
title: silly.net.http.url
icon: link
category:
  - API Reference
tag:
  - Network
  - HTTP
  - URL
---

# silly.net.http.url

The `silly.net.http.url` module provides URL parsing, resolution, and percent-encoding/decoding utilities for HTTP clients.

## Module Import

```lua validate
local url = require "silly.net.http.url"
```

## url.parse(url)

Parses a URL into a structured object.

- **Parameters**:
  - `url`: `string` - URL string (must include scheme, e.g. `"http://..."`)
- **Returns**:
  - Success: `table` with fields:
    - `scheme`: `string` - URL scheme (`"http"`, `"https"`, `"ws"`, `"wss"`)
    - `host`: `string` - Hostname (no brackets for IPv6, no port)
    - `port`: `string` - Port as string (defaults: 80 for http/ws, 443 for https/wss)
    - `authority`: `string` - `"host"` or `"host:port"` (omits port when it matches the scheme default)
    - `path`: `string` - Request target (path + query + fragment; defaults to `"/"`)
  - Failure: `nil, string`
- **Example**:

```lua validate
local url = require "silly.net.http.url"

local u, err = url.parse("http://example.com:8080/api?key=value")
-- u.scheme     == "http"
-- u.host       == "example.com"
-- u.port       == "8080"
-- u.authority  == "example.com:8080"
-- u.path       == "/api?key=value"
```

## url.resolve(base_url, ref)

Resolves a reference URL against a base URL (RFC 3986 Section 5).

- **Parameters**:
  - `base_url`: `string` - Base URL
  - `ref`: `string` - Reference URL (absolute, protocol-relative, root-relative, path-relative, query-only, or fragment-only)
- **Returns**: Same as `url.parse`
- **Example**:

```lua validate
local url = require "silly.net.http.url"

-- Absolute reference overrides base
local u = url.resolve("http://example.com/path", "http://other.com/new")

-- Path-relative: replaces last segment
u = url.resolve("http://example.com/a/b", "c")
-- u.path == "/a/c"

-- Root-relative
u = url.resolve("http://example.com/a/b", "/c/d")
-- u.path == "/c/d"
```

## url.build(u)

Reconstructs a full URL string from a parsed result.

- **Parameters**:
  - `u`: `table` - Parsed URL object (from `url.parse` or `url.resolve`)
- **Returns**: `string`
- **Example**:

```lua validate
local url = require "silly.net.http.url"

local u = url.parse("http://example.com/path")
local s = url.build(u)  -- "http://example.com/path"
```

## url.parsequery(query)

Parses a query string into a key-value table. Duplicate keys use last-value-wins semantics.

- **Parameters**:
  - `query`: `string` - Query string (without the leading `?`)
- **Returns**: `table<string, string>`
- **Example**:

```lua validate
local url = require "silly.net.http.url"

local q = url.parsequery("name=Alice&age=30")
-- q["name"] == "Alice"
-- q["age"]  == "30"
```

## url.queryescape(val)

Encodes a string or table for use in URL query strings (`application/x-www-form-urlencoded`). Spaces become `+`.

- **Parameters**:
  - `val`: `string|table<string, string>` - String to encode, or table of key-value pairs
- **Returns**: `string`
- **Example**:

```lua validate
local url = require "silly.net.http.url"

local s = url.queryescape("hello world")    -- "hello+world"
local t = url.queryescape({a = "b&c"})      -- "a=b%26c"
```

## url.queryunescape(s)

Decodes a query string value. Converts `+` to space and decodes `%XX` sequences.

- **Parameters**:
  - `s`: `string`
- **Returns**: `string`

## url.pathescape(val)

Percent-encodes a string for use in URL path segments (RFC 3986).

- **Parameters**:
  - `val`: `string`
- **Returns**: `string`

## url.pathunescape(s)

Decodes `%XX` sequences in a path string (RFC 3986). Does not convert `+` to space.

- **Parameters**:
  - `s`: `string`
- **Returns**: `string`

---

## See Also

- [silly.net.http](./http.md) - HTTP server and client
- [silly.net.addr](./addr.md) - Address parsing helpers
