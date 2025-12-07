---
title: silly.net.tls
icon: lock
category:
  - API Reference
tag:
  - Network
  - TLS
  - SSL
  - Encryption
---

# silly.net.tls

The `silly.net.tls` module provides encrypted network connections based on the TLS/SSL protocol. It provides secure data transmission on top of the TCP transport layer, supporting both server and client modes, as well as ALPN protocol negotiation (such as HTTP/2).

## Module Import

```lua validate
local tls = require "silly.net.tls"
```

## Core Concepts

### TLS/SSL Encryption

TLS (Transport Layer Security) is an encryption protocol used to provide security and data integrity in network communications. `silly.net.tls` is implemented based on OpenSSL and provides the following features:

- **Server Mode**: Listen for encrypted connections, requires certificate and private key configuration
- **Client Mode**: Connect to TLS servers, optional SNI (Server Name Indication)
- **ALPN Support**: Application-Layer Protocol Negotiation, supports protocols like HTTP/1.1, HTTP/2

### Certificate Configuration

The server must provide certificates and private keys in PEM format. Certificates can be:
- Self-signed certificates (for development and testing)
- CA-issued certificates (for production environments)

### Asynchronous Operations

Similar to `silly.net.tcp`, read operations in the TLS module are asynchronous, suspending coroutines when data is unavailable and automatically resuming when data arrives.

### API Change Notes

The TLS module now uses an object-oriented (OO) interface. `tls.listen` and `tls.connect` return connection objects or listener objects instead of file descriptors. All operations (such as `read`, `write`, `close`) are called as methods on the objects.

---

## Usage Examples

### Example 1: HTTPS Server

This example demonstrates how to create a simple HTTPS server that handles client connections and returns responses.

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tls = require "silly.net.tls"
local waitgroup = require "silly.sync.waitgroup"

task.fork(function()
    local wg = waitgroup.new()

    -- Server certificate and private key (PEM format)
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

    -- Start TLS server
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
                print("Client connected:", conn.remoteaddr)

                -- Read HTTP request
                local request, err = conn:read("\n")
                if not request then
                    print("Read error:", err)
                    conn:close()
                    return
                end

                print("Received request:", request)

                -- Send HTTP response
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
                print("Connection closed")
            end)
        end
    }

    if not listenfd then
        print("Failed to start server")
        return
    end

    print("HTTPS server listening on 127.0.0.1:8443")

    -- Wait for some time to process requests
    wg:wait()
    tls.close(listenfd)
end)
```

### Example 2: HTTPS Client

This example demonstrates how to create a TLS client to connect to an HTTPS server.

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tls = require "silly.net.tls"
local dns = require "silly.net.dns"

task.fork(function()
    -- Resolve domain name
    local ip = dns.lookup("www.example.com", dns.A)
    if not ip then
        print("DNS resolution failed")
        return
    end

    -- Connect to HTTPS server (port 443)
    local conn, err = tls.connect(
        ip .. ":443",       -- Server address
        {
            bind = nil,         -- No local address binding
            server = "www.example.com", -- SNI hostname
            alpn = {"http/1.1"} -- ALPN protocol
        }
    )

    if not conn then
        print("Connection failed:", err)
        return
    end

    print("Connected to server")

    -- Check negotiated ALPN protocol
    local alpn = conn:alpnproto()
    if alpn then
        print("ALPN protocol:", alpn)
    end

    -- Send HTTP request
    local request = "GET / HTTP/1.1\r\n" ..
                   "Host: www.example.com\r\n" ..
                   "User-Agent: silly-tls-client\r\n" ..
                   "Connection: close\r\n\r\n"

    local ok, write_err = conn:write(request)
    if not ok then
        print("Write failed:", write_err)
        conn:close()
        return
    end

    -- Read response headers
    local line, read_err = conn:read("\r\n")
    if not line then
        print("Read failed:", read_err)
        conn:close()
        return
    end

    print("Response:", line)

    -- Close connection
    conn:close()
    print("Connection closed")
end)
```

### Example 3: Certificate Hot Reload

This example demonstrates how to reload certificates at runtime, implementing zero-downtime certificate updates.

```lua validate
local silly = require "silly"
local task = require "silly.task"
local tls = require "silly.net.tls"
local signal = require "silly.signal"
local waitgroup = require "silly.sync.waitgroup"

task.fork(function()
    local wg = waitgroup.new()

    -- Initial certificate
    local cert_v1 = [[-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
]]

    local key_v1 = [[-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
]]

    -- New version certificate (CN=localhost2)
    local cert_v2 = [[-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
]]

    local key_v2 = [[-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
]]

    -- Start server
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

    print("Server started with certificate v1 (CN=localhost)")

    -- Register SIGUSR1 signal handler to trigger certificate reload
    signal.register("SIGUSR1", function()
        local ok, err = listener:reload {
            certs = {{cert = cert_v2, key = key_v2}}
        }
        if ok then
            print("Certificate reload successful (CN=localhost2)")
        else
            print("Certificate reload failed:", err)
        end
    end)

    print("Send SIGUSR1 signal to trigger certificate reload")
    print("Run: kill -USR1", silly.pid)

    wg:wait()
end)
```

---

## API Documentation

### tls.listen(conf)

Start a TLS server listening on the given address.

- **Parameters**:
  - `conf`: `table` - Server configuration table
    - `addr`: `string` (required) - Listen address, e.g. `"127.0.0.1:8443"` or `":8443"`
    - `certs`: `table[]` (required) - Certificate configuration list, each element contains:
      - `cert`: `string` - Certificate content in PEM format
      - `key`: `string` - Private key content in PEM format
    - `backlog`: `integer|nil` (optional) - Maximum length of the pending connection queue
    - `accept`: `fun(fd: integer, addr: string)` (required) - Connection handler, called for each new connection
    - `ciphers`: `string|nil` (optional) - Allowed cipher suites in OpenSSL format
    - `alpnprotos`: `string[]|nil` (optional) - List of supported ALPN protocols, e.g. `{"http/1.1", "h2"}`
- **Return value**:
  - Success: `integer` - Listener file descriptor
  - Failure: `nil, string` - nil and error message
- **Example**:

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
                print("Close failed:", err)
            end
        end
    }
end)
```

### tls.connect(addr [, opts])

Establishes a connection to a TLS secure server (asynchronous). This function performs both TCP connection and TLS handshake.

- **Parameters**:
  - `addr`: `string` - Server address, e.g. `"127.0.0.1:443"`
  - `opts`: `table|nil` (optional) - Configuration options
    - `bind`: `string|nil` - Local bind address
    - `hostname`: `string|nil` - Hostname for SNI (recommended)
    - `alpnprotos`: `string[]|nil` - List of ALPN protocols, e.g. `{"h2", "http/1.1"}`
    - `timeout`: `integer|nil` - Timeout for connection and handshake (milliseconds)
- **Return value**:
  - Success: `silly.net.tls.conn` - TLS connection object
  - Failure: `nil, string` - nil and error message
- **Example**:

```lua validate
local tls = require "silly.net.tls"

local conn, err = tls.connect("127.0.0.1:443", {
    hostname = "example.com",
    alpnprotos = {"http/1.1"},
    timeout = 5000  -- 5 seconds timeout
})

if not conn then
    print("Connect failed:", err)
    return
end
```

### listener:reload([conf])

Hot reload the TLS server's certificate configuration without restarting the service.

- **Parameters**:
  - `conf`: `table|nil` (optional) - New configuration
    - `certs`: `table[]` - New certificate configuration
    - `ciphers`: `string` - New cipher suites
    - `alpnprotos`: `string[]` - New ALPN protocol list
- **Return value**:
  - Success: `true`
  - Failure: `false, string` - false and error message
- **Example**:

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

    -- Reload certificate
    local ok, err = listener:reload({
        certs = {{
            cert = "-----BEGIN CERTIFICATE-----\n... new ...",
            key = "-----BEGIN PRIVATE KEY-----\n... new ...",
        }}
    })

    if ok then
        print("Certificate reload successful")
    else
        print("Certificate reload failed:", err)
    end
end)
```

### conn:isalive()

Check if the TLS connection is still active.

- **Return value**: `boolean` - Returns `true` if connection is active, otherwise `false`
- **Example**:

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
                print("Connection active")
                conn:write("Status: OK\n")
            else
                print("Connection disconnected")
            end
            conn:close()
        end
    }
end)
```

### conn:alpnproto()

Get the protocol negotiated through ALPN.

- **Return value**: `string|nil` - Negotiated protocol (e.g. `"http/1.1"`, `"h2"`), returns `nil` if not negotiated
- **Example**:

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
                print("Using HTTP/2")
            elseif proto == "http/1.1" then
                print("Using HTTP/1.1")
            else
                print("No ALPN negotiation")
            end
            conn:close()
        end
    }
end)
```

### conn:limit(size)

Set read buffer limit. Suspend reading when buffer size exceeds the limit.

- **Parameters**:
  - `size`: `integer` - Limit size (bytes)

### conn:unreadbytes()

Get the number of unread bytes in the current read buffer.

- **Return value**: `integer` - Number of bytes

### conn:unsentbytes()

Get the number of unsent bytes in the current send buffer.

- **Return value**: `integer` - Number of bytes

### conn.remoteaddr

Get the remote address (read-only property).

> **Note**: `remoteaddr` is a property of the connection object. Access it directly without parentheses.

- **Type**: `string` - Remote address (format: `IP:Port`)
- **Example**:

```lua validate
local tls = require "silly.net.tls"

local conn = tls.connect("example.com:443")
if not conn then return end

print("Remote address:", conn.remoteaddr)
```

---

## Notes

### Certificate Management

1. **Certificate Format**: Must use PEM format for certificates and private keys
2. **Certificate Verification**: Clients verify server certificates by default, self-signed certificates will cause verification failures
3. **SNI Support**: It's recommended to provide the hostname parameter when clients connect to support SNI
4. **Certificate Chain**: If using intermediate CAs, the complete certificate chain must be placed in the cert field

### Performance Considerations

1. **Encryption Overhead**: TLS encryption increases CPU usage, performance is about 60-80% of plain TCP
2. **Handshake Latency**: TLS handshake requires additional round-trip time (RTT)
3. **Connection Reuse**: For high-frequency communication, TLS connections should be reused as much as possible
4. **Protocol Selection**: HTTP/2 (h2) uses multiplexing, which can reduce the number of connections

### Security Recommendations

1. **Key Protection**: Private key files should have strict access permissions (e.g. `chmod 600`)
2. **Cipher Suites**: In production environments, it's recommended to configure the `ciphers` parameter to disable insecure encryption algorithms
3. **Certificate Updates**: Use `tls.reload()` to regularly update certificates to avoid certificate expiration
4. **ALPN Negotiation**: Use `alpnprotos` to explicitly specify supported protocols, avoiding protocol downgrade attacks

### Common Errors

**Error**: "socket closed" or "handshake failed"
- **Cause**: Certificate configuration error, client doesn't trust certificate, cipher suite mismatch
- **Solution**: Check certificate format, use correct CA certificates, configure compatible cipher suites

**Error**: "certificate verify failed"
- **Cause**: Client cannot verify server certificate
- **Solution**: Use trusted CA certificates, or use `--insecure` option in test environments

### Build Requirements

The TLS module requires OpenSSL support. OpenSSL must be enabled during compilation:

```bash
make OPENSSL=ON
```

If OpenSSL is not enabled, `require "silly.net.tls"` will fail.

## See Also

- [silly](../silly.md) - Core module
- [silly.net.tcp](./tcp.md) - TCP protocol support
- [silly.net.udp](./udp.md) - UDP protocol support
- [silly.net.dns](./dns.md) - DNS resolver
- [silly.sync.waitgroup](../sync/waitgroup.md) - Coroutine wait group
