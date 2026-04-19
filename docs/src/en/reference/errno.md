---
title: silly.errno
icon: triangle-exclamation
category:
  - API Reference
tag:
  - Core
  - Error Handling
  - Network
---

# silly.errno

`silly.errno` normalizes transport-layer error codes into a single table. Instead of raw OS errno integers (which differ between Linux, macOS, and Windows) or free-form strings, every transport call returns a value drawn from this table — so you can branch on it reliably.

## Module Import

```lua
local errno = require "silly.errno"
```

## How to Compare

Errors are plain Lua values (currently strings like `"Operation timed out (110)"` with a numeric suffix).

**The only place you are allowed to branch on `err == errno.X` is when the error comes directly from one of these four modules:**

- `silly.net`
- `silly.net.tcp`
- `silly.net.tls`
- `silly.net.udp`

Everywhere else — `silly.net.dns`, `silly.net.cluster`, `silly.net.http`, `silly.net.websocket`, `silly.net.grpc`, `silly.store.*`, user wrappers, …  — the error is a plain string from the caller's perspective, even if some layer deeper happened to pass an errno value through. **Use the value only for logging or returning; never `err == errno.X`**.

Within the allowed modules:

```lua
local tcp = require "silly.net.tcp"
local errno = require "silly.errno"
local logger = require "silly.logger"

local conn, err = tcp.connect("127.0.0.1:8080", {timeout = 1000})
if not conn then
    if err == errno.TIMEDOUT then
        -- timed out
    elseif err == errno.CONNREFUSED then
        -- server not listening
    else
        logger.error("connect failed:", err)  -- safe: still a string when logged
    end
end
```

And how it looks in a non-transport module:

```lua
-- WRONG — cluster is not in the allowed list, even if the error happens
-- to be errno.TIMEDOUT internally.
local resp, err = cluster.call(peer, "hello", req)
if err == errno.TIMEDOUT then     -- ❌ forbidden
    retry_later()
end

-- CORRECT — log the error and drop through.
if not resp then
    logger.error("cluster call failed:", err)
    return
end
```

## Where It Applies

**Produce / propagate:** any layer may return an `errno` value as an error.

**Branch on (`err == errno.X`):** only when the error was returned by **`silly.net`, `silly.net.tcp`, `silly.net.tls`, or `silly.net.udp`** — i.e. you're holding a transport conn/listener and inspecting the error from its `read` / `write` / `recvfrom` / `sendto` / `connect` / `listen` / `close` / `bind`.

**Do NOT branch on** the error from any other module, even if you suspect (or know) it is an errno value internally. `silly.net.dns`, `silly.net.cluster`, `silly.net.http`, `silly.net.websocket`, `silly.net.grpc`, `silly.store.*`, application-level APIs — for all of them the error is an opaque string. Log it, surface it to callers, or compare against sentinels defined by that API. **Never** `err == errno.X`.

A normal peer close reported through a transport `close` callback or `read` return is `errno.EOF` — not `nil`.

## Values

### Standard errno (mapped from the host OS)

The numeric code varies by platform but the identity is preserved: `errno.CONNREFUSED` on Linux and on Windows compare equal to the value returned by the corresponding transport call on that platform.

| Name | Meaning |
|------|---------|
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

### Silly-specific errors

Returned by the silly transport layer, not by the OS.

| Name | Meaning |
|------|---------|
| `RESOLVE` | DNS resolution failed |
| `NOSOCKET` | No free socket available |
| `CLOSING` | Socket is closing |
| `CLOSED` | Socket is closed |
| `EOF` | End of file — peer half-closed the stream cleanly |
| `TLS` | TLS handshake or record-layer error |

## Common Patterns

### Timeout vs. other errors

```lua
local data, err = conn:read(4, 1000)  -- 1 second timeout
if not data then
    if err == errno.TIMEDOUT then
        -- retry, or give up on this request
    elseif err == errno.EOF then
        -- peer closed, stop the read loop
    else
        logger.error("read failed:", err)
    end
end
```

### Detecting a clean close in a read loop

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

### Distinguishing connect failures

```lua
local c, err = tcp.connect(addr, {timeout = 2000})
if not c then
    if err == errno.TIMEDOUT then       -- server slow/unreachable
    elseif err == errno.CONNREFUSED then -- nothing listening
    elseif err == errno.RESOLVE then     -- DNS lookup failed
    elseif err == errno.HOSTUNREACH then -- routing problem
    end
end
```

## Caveats

- The raw string representation includes a numeric suffix (e.g. `"Operation timed out (110)"`), and the specific number differs between platforms. Always compare by identity (`err == errno.X`); never by string literal equality.
- Accessing an unknown constant (e.g. `errno.NOTDEFINED`) does **not** raise — the table has an `__index` fallback that returns `"Unknown error 'NAME'"` and caches it for future lookups. This keeps pattern-match code crash-free when a newer runtime adds codes the doc does not list yet; but your branch for that name will never equal any real error.
- When an error flows through an application-level API (HTTP stream, gRPC client, channel close reason), it may be stringified or wrapped. Check that API's documentation for its error contract rather than reaching back for `silly.errno` constants.
- New entries may be added over time; code that only handles a known subset should fall through to a log/propagate path, not `assert(false)`.
