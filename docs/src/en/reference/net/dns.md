---
title: silly.net.dns
icon: globe
category:
  - API Reference
tag:
  - Network
  - DNS
  - Domain Resolution
---

# dns (`silly.net.dns`)

The `silly.net.dns` module provides asynchronous DNS (Domain Name System) resolution functionality. Built on top of UDP, it supports common DNS record types (A, AAAA, SRV) and includes a built-in caching mechanism for improved performance. The module automatically parses system configuration files (`/etc/resolv.conf` and `/etc/hosts`).

## Module Import

```lua validate
local dns = require "silly.net.dns"
```

---

## Core Concepts

### DNS Record Types

The DNS system defines various record types, each serving different purposes:

- **A Record** (`dns.A`): Maps domain names to IPv4 addresses
- **AAAA Record** (`dns.AAAA`): Maps domain names to IPv6 addresses
- **CNAME Record**: Domain name alias, automatically followed during resolution
- **SRV Record** (`dns.SRV`): Service location record containing host, port, and priority information

### Caching Mechanism

The DNS module includes a built-in caching system:
- Results are automatically cached based on the TTL (Time To Live) value in DNS responses
- Cache automatically expires and re-queries after TTL expiration
- Entries from `/etc/hosts` are permanently cached
- CNAME records are recursively resolved and the final result is cached

### System Configuration

The module automatically reads system configuration:
- **`/etc/resolv.conf`**: DNS server configuration
- **`/etc/hosts`**: Static hostname mappings

Paths can be customized via environment variables:
- `sys.dns.resolv_conf`: Path to resolv.conf file
- `sys.dns.hosts`: Path to hosts file

---

## API Reference

### DNS Record Type Constants

#### `dns.A`

IPv4 address record type constant.

- **Type**: `integer`
- **Value**: `1`
- **Purpose**: Query IPv4 addresses for domain names

#### `dns.AAAA`

IPv6 address record type constant.

- **Type**: `integer`
- **Value**: `28`
- **Purpose**: Query IPv6 addresses for domain names

#### `dns.SRV`

Service record type constant.

- **Type**: `integer`
- **Value**: `33`
- **Purpose**: Query service host, port, priority, and weight information

---

### Domain Resolution

#### `dns.lookup(name, qtype [, timeout])`

Query DNS records of specified type and return the first result (asynchronous).

- **Parameters**:
  - `name`: `string` - Domain name or IP address to query
  - `qtype`: `integer` - DNS record type (`dns.A`, `dns.AAAA`, or `dns.SRV`)
  - `timeout`: `integer|nil` (optional) - Query timeout in milliseconds, defaults to 5000ms
- **Returns**:
  - Success: `string|table` - Resolution result
    - A/AAAA records: Returns IP address string
    - SRV records: Returns table containing `priority`, `weight`, `port`, `target`
  - Failure: `nil` - Query failed or timed out
- **Notes**:
  - If `name` is already an IP address, returns that address directly
  - Automatically follows CNAME records
  - Retries up to 3 times after timeout, with increasing timeout intervals
- **Example**:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- Query IPv4 address
    local ip = dns.lookup("www.example.com", dns.A)
    if ip then
        print("IPv4 address:", ip)
    else
        print("DNS lookup failed")
    end

    -- Query IPv6 address
    local ipv6 = dns.lookup("www.example.com", dns.AAAA)
    if ipv6 then
        print("IPv6 address:", ipv6)
    end

    -- Query SRV record
    local srv = dns.lookup("_http._tcp.example.com", dns.SRV)
    if srv then
        print("Target:", srv.target, "Port:", srv.port)
    end
end)
```

#### `dns.resolve(name, qtype [, timeout])`

Query DNS records of specified type and return all results (asynchronous).

- **Parameters**:
  - `name`: `string` - Domain name or IP address to query
  - `qtype`: `integer` - DNS record type
  - `timeout`: `integer|nil` (optional) - Query timeout in milliseconds, defaults to 5000ms
- **Returns**:
  - Success: `table` - Array containing all resolution results
    - A/AAAA records: Array of IP address strings
    - SRV records: Array of SRV record objects
  - Failure: `nil` - Query failed or timed out
- **Notes**:
  - If `name` is already an IP address, returns array containing that address
  - Returned array may be empty (if no records exist)
  - Automatically follows CNAME records
- **Example**:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- Query all IPv4 addresses
    local ips = dns.resolve("cdn.example.com", dns.A)
    if ips then
        print("Found", #ips, "IPv4 addresses:")
        for i, ip in ipairs(ips) do
            print(i, ip)
        end
    end

    -- Query all SRV records
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

### Configuration and Utilities

#### `dns.server(ip)`

Set custom DNS server address.

- **Parameters**:
  - `ip`: `string` - DNS server address in format `"IP:PORT"`
    - IPv4: `"8.8.8.8:53"` or `"223.5.5.5:53"`
    - IPv6: `"[2001:4860:4860::8888]:53"`
- **Returns**: None
- **Notes**:
  - Must be called before the first DNS query
  - Overrides configuration read from `/etc/resolv.conf`
- **Example**:

```lua validate
local dns = require "silly.net.dns"

-- Use Aliyun DNS
dns.server("223.5.5.5:53")

-- Use Google DNS
dns.server("8.8.8.8:53")

-- Use Cloudflare DNS
dns.server("1.1.1.1:53")
```

#### `dns.isname(name)`

Check if a string is a domain name (not an IP address).

- **Parameters**:
  - `name`: `string` - String to check
- **Returns**: `boolean`
  - `true`: String is a domain name
  - `false`: String is an IPv4 or IPv6 address
- **Notes**: This is a synchronous function, does not need to be called in a coroutine
- **Example**:

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

## Usage Examples

### Example 1: Basic Domain Resolution

Query IPv4 and IPv6 addresses for a domain:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local domain = "www.example.com"

    -- Query IPv4 address
    local ipv4 = dns.lookup(domain, dns.A)
    if ipv4 then
        print("IPv4:", ipv4)
    else
        print("No IPv4 address found")
    end

    -- Query IPv6 address
    local ipv6 = dns.lookup(domain, dns.AAAA)
    if ipv6 then
        print("IPv6:", ipv6)
    else
        print("No IPv6 address found")
    end
end)
```

### Example 2: Multi-Address Resolution

Query all available IP addresses and select the optimal one:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local domain = "cdn.example.com"

    -- Get all IPv4 addresses
    local ips = dns.resolve(domain, dns.A)
    if not ips or #ips == 0 then
        print("No addresses found")
        return
    end

    print("Found", #ips, "addresses:")
    for i, ip in ipairs(ips) do
        print(i, ip)
    end

    -- Simple load balancing: randomly select an IP
    local selected = ips[math.random(#ips)]
    print("Selected:", selected)
end)
```

### Example 3: SRV Record Service Discovery

Discover service instances using SRV records:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- Query SRV records in _service._protocol.domain format
    local srvs = dns.resolve("_http._tcp.example.com", dns.SRV)
    if not srvs or #srvs == 0 then
        print("No service instances found")
        return
    end

    -- Sort by priority (lower priority is preferred)
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

    -- Use the highest priority server
    local primary = srvs[1]
    print(string.format(
        "Using primary server: %s:%d",
        primary.target,
        primary.port
    ))
end)
```

### Example 4: Custom DNS Server

Use a specific DNS server for queries:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- Use Aliyun public DNS
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

### Example 5: Query with Timeout

Set query timeout duration:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local domain = "slow.example.com"

    -- Set 2 second timeout
    local ip = dns.lookup(domain, dns.A, 2000)
    if ip then
        print("Resolved:", ip)
    else
        print("DNS lookup timeout or failed")
    end

    -- Use default timeout (5 seconds)
    local ip2 = dns.lookup(domain, dns.A)
    if ip2 then
        print("Resolved with default timeout:", ip2)
    end
end)
```

### Example 6: IP Address Validation and Resolution

Check if input is an IP address or domain name:

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

### Example 7: Concurrent DNS Queries

Query multiple domains concurrently for improved efficiency:

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

### Example 8: DNS Cache Warmup

Pre-resolve commonly used domains into cache:

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

    -- Subsequent queries will return directly from cache (until TTL expires)
    local ip = dns.lookup("api.example.com", dns.A)
    print("Fast lookup:", ip)
end)
```

---

## Important Notes

### 1. Coroutine Requirement

All DNS query functions (`lookup` and `resolve`) are asynchronous and must be called within a coroutine:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

-- Wrong: Cannot call in main thread
-- local ip = dns.lookup("example.com", dns.A)  -- Will fail

-- Correct: Call within coroutine
task.fork(function()
    local ip = dns.lookup("example.com", dns.A)
    print(ip)
end)
```

### 2. DNS Server Configuration Timing

Must configure server before the first DNS query:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- Correct: Configure before query
    dns.server("8.8.8.8:53")
    local ip = dns.lookup("example.com", dns.A)

    -- Wrong: Configuration after first query has no effect
    -- dns.server("1.1.1.1:53")  -- This call will be ignored
end)
```

### 3. Return Value Checking

Always check return values and handle query failures:

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

    -- Safely use results
    print("Found", #ips, "addresses")
end)
```

### 4. TTL and Caching

DNS responses are cached but will expire:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local time = require "silly.time"
local task = require "silly.task"

task.fork(function()
    -- First query, fetches from DNS server
    local ip1 = dns.lookup("example.com", dns.A)
    print("First lookup:", ip1)

    -- Query again immediately, returns from cache (very fast)
    local ip2 = dns.lookup("example.com", dns.A)
    print("Cached lookup:", ip2)

    -- Wait for TTL to expire (assuming TTL is 60 seconds)
    time.sleep(61000)

    -- Query after TTL expiry, fetches from DNS server again
    local ip3 = dns.lookup("example.com", dns.A)
    print("After TTL expiry:", ip3)
end)
```

### 5. Automatic CNAME Following

CNAME records are automatically resolved:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- If alias.example.com is a CNAME for real.example.com
    -- lookup automatically follows the CNAME and returns the A record of real.example.com
    local ip = dns.lookup("alias.example.com", dns.A)
    if ip then
        print("Final IP (after CNAME resolution):", ip)
    end
end)
```

### 6. IPv6 Address Format

IPv6 addresses use colon-separated hexadecimal format:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local ipv6 = dns.lookup("ipv6.example.com", dns.AAAA)
    if ipv6 then
        -- Format: xx:xx:xx:xx:xx:xx:xx:xx (not compressed format)
        print("IPv6:", ipv6)  -- Example: 00:00:00:00:00:00:00:01
    end
end)
```

### 7. SRV Record Structure

SRV records contain multiple fields:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    local srv = dns.lookup("_http._tcp.example.com", dns.SRV)
    if srv then
        -- SRV record contains:
        print("Priority:", srv.priority)  -- Priority (lower is preferred)
        print("Weight:", srv.weight)      -- Weight (for load balancing)
        print("Port:", srv.port)          -- Service port
        print("Target:", srv.target)      -- Target hostname
    end
end)
```

### 8. Timeout and Retry

DNS queries have built-in timeout and retry mechanisms:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- Default behavior:
    -- - Timeout: 5 seconds
    -- - Retry count: 3 times
    -- - Retry intervals: Increasing (5s, 10s, 15s)

    local ip = dns.lookup("example.com", dns.A)
    -- If first attempt times out, automatically retries
    -- Maximum wait time: 5s + 10s + 15s = 30s

    -- Custom timeout (but retry count remains 3)
    local ip2 = dns.lookup("example.com", dns.A, 2000)  -- 2 second timeout
end)
```

---

## Performance Recommendations

### 1. Cache Warmup

Pre-resolve commonly used domains to leverage caching:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"

local task = require "silly.task"

task.fork(function()
    -- Warm up cache at application startup
    local critical_domains = {
        "api.service.com",
        "db.service.com",
        "cache.service.com",
    }

    for _, domain in ipairs(critical_domains) do
        dns.resolve(domain, dns.A)  -- Pre-resolve to cache
    end

    -- Queries in business logic will be faster
    local ip = dns.lookup("api.service.com", dns.A)  -- Returns from cache
end)
```

### 2. Concurrent Queries

Use coroutines to query multiple domains concurrently:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local wg = waitgroup.new()
    local domains = {"site1.com", "site2.com", "site3.com"}

    -- Concurrent queries are much faster than serial queries
    for _, domain in ipairs(domains) do
        wg:fork(function()
            dns.lookup(domain, dns.A)
        end)
    end

    wg:wait()  -- Wait for all queries to complete
end)
```

### 3. Avoid Unnecessary Queries

Check if input is already an IP address before connecting:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local tcp = require "silly.net.tcp"
local task = require "silly.task"

task.fork(function()
    local function connect_to_host(host, port)
        local ip
        if dns.isname(host) then
            -- Only domain names need resolution
            ip = dns.lookup(host, dns.A)
            if not ip then
                return nil, "DNS resolution failed"
            end
        else
            -- Already an IP address, use directly
            ip = host
        end

        local addr = string.format("%s:%d", ip, port)
        return tcp.connect(addr)
    end

    -- Both calls handle correctly
    local fd1 = connect_to_host("example.com", 80)      -- Will resolve
    local fd2 = connect_to_host("192.168.1.1", 80)      -- Skips resolution
end)
```

### 4. Use Fast DNS Servers

Choose geographically close, fast-responding DNS servers:

```lua validate
local dns = require "silly.net.dns"

-- Recommended for mainland China: Aliyun or Tencent Cloud DNS
dns.server("223.5.5.5:53")        -- Aliyun DNS
-- dns.server("119.29.29.29:53")  -- Tencent Cloud DNS

-- Recommended for international: Google or Cloudflare DNS
-- dns.server("8.8.8.8:53")       -- Google DNS
-- dns.server("1.1.1.1:53")       -- Cloudflare DNS
```

### 5. Set Appropriate Timeout

Adjust timeout based on network environment:

```lua validate
local silly = require "silly"
local dns = require "silly.net.dns"
local task = require "silly.task"

task.fork(function()
    -- Local network: Use shorter timeout
    local ip1 = dns.lookup("local.service", dns.A, 1000)  -- 1 second

    -- Public network: Use default or longer timeout
    local ip2 = dns.lookup("remote.service.com", dns.A)  -- 5 seconds (default)

    -- Unreliable network: Use even longer timeout
    local ip3 = dns.lookup("unstable.service.com", dns.A, 10000)  -- 10 seconds
end)
```

### 6. Monitor DNS Performance

Record DNS query times to identify performance issues:

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

## See Also

- [silly.net.tcp](./tcp.md) - TCP network protocol
- [silly.net.udp](./udp.md) - UDP network protocol
- [silly.net.http](./http.md) - HTTP protocol (uses DNS internally)
- [silly.sync.waitgroup](../sync/waitgroup.md) - Coroutine wait group
