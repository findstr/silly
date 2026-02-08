---
title: TLS/HTTPS Configuration Guide
icon: lock
order: 1
category:
  - Guides
tag:
  - TLS
  - HTTPS
  - Security
  - Certificates
---

# TLS/HTTPS Configuration Guide

This guide will help you configure and manage TLS/HTTPS services in the Silly framework, including certificate preparation, security configuration, certificate management, and performance optimization.

## Why HTTPS?

HTTPS (HTTP over TLS) adds a TLS encryption layer on top of HTTP, providing:

- **Data Encryption**: Prevents man-in-the-middle eavesdropping on communication
- **Authentication**: Verifies server identity through certificates, preventing phishing attacks
- **Data Integrity**: Prevents data tampering during transmission
- **SEO Benefits**: Search engines prioritize indexing HTTPS websites
- **Browser Trust**: Modern browsers display "Not Secure" warnings for HTTP sites

::: tip HTTPS is the Standard for Modern Web
Since 2018, Google Chrome has been marking all HTTP websites as "Not Secure". HTTPS has evolved from optional to essential.
:::

## Prerequisites

### 1. Enable OpenSSL Support at Compile Time

Silly's TLS functionality depends on the OpenSSL library, which needs to be enabled during compilation:

```bash
# Install OpenSSL development library
# Ubuntu/Debian
sudo apt-get install libssl-dev

# CentOS/RHEL
sudo yum install openssl-devel

# macOS
brew install openssl

# Compile Silly (with OpenSSL enabled)
make OPENSSL=ON
```

### 2. Verify TLS Support

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

print("TLS module loaded successfully!")
silly.exit(0)
```

If `require "silly.net.tls"` throws an error, OpenSSL support was not compiled correctly.

## Certificate Preparation

### Development Environment: Self-Signed Certificates

Self-signed certificates are suitable for development and testing environments, but should not be used in production.

#### Generate a Self-Signed Certificate

```bash
# Generate private key and self-signed certificate (valid for 10 years)
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server-key.pem \
    -out server-cert.pem \
    -days 3650 \
    -subj "/CN=localhost"
```

**Parameter Explanation**:
- `-x509`: Generate a self-signed certificate
- `-newkey rsa:2048`: Create a 2048-bit RSA private key
- `-nodes`: Don't encrypt the private key (convenient for testing)
- `-days 3650`: Valid for 10 years
- `-subj "/CN=localhost"`: Certificate Common Name (CN)

#### Generate a SAN Certificate (Multi-Domain Support)

```bash
# Create configuration file san.cnf
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

# Generate certificate
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server-key.pem \
    -out server-cert.pem \
    -days 3650 \
    -config san.cnf \
    -extensions v3_req
```

#### Using Self-Signed Certificates in Code

```lua
local silly = require "silly"
local tls = require "silly.net.tls"
local io = io

-- Read certificate and private key files
local cert_file = io.open("server-cert.pem", "r")
local cert_pem = cert_file:read("*a")
cert_file:close()

local key_file = io.open("server-key.pem", "r")
local key_pem = key_file:read("*a")
key_file:close()

-- Start HTTPS server
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

print("HTTPS server running at https://localhost:8443")
```

::: warning Browser Warning
Self-signed certificates will cause browsers to display security warnings. During testing, you'll need to manually trust the certificate or add an exception in the browser.
:::

### Production Environment: Let's Encrypt Free Certificates

[Let's Encrypt](https://letsencrypt.org/) provides free, automated CA certificates trusted by all major browsers.

#### Obtain Certificates Using Certbot

```bash
# Install Certbot
# Ubuntu/Debian
sudo apt-get install certbot

# CentOS/RHEL
sudo yum install certbot

# macOS
brew install certbot

# Obtain certificate (requires domain name and port 80 access)
sudo certbot certonly --standalone -d yourdomain.com -d www.yourdomain.com

# Certificate file locations
# Certificate: /etc/letsencrypt/live/yourdomain.com/fullchain.pem
# Private key: /etc/letsencrypt/live/yourdomain.com/privkey.pem
```

#### Using Let's Encrypt Certificates in Silly

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

-- Read Let's Encrypt certificate
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
        -- Handle HTTPS request
    end
}

print("HTTPS server running at https://yourdomain.com")
```

::: tip Permission Issues
Let's Encrypt certificate files are located in the `/etc/letsencrypt/` directory and typically require root permissions to read. Recommendations:
1. Copy certificates to the application directory and modify permissions
2. Or start Silly with `sudo`
3. Or use a reverse proxy (like Nginx) to handle TLS
:::

#### Automatic Certificate Renewal

Let's Encrypt certificates are valid for 90 days and need periodic renewal:

```bash
# Manual renewal
sudo certbot renew

# Configure automatic renewal (add to crontab)
# Check and renew daily at 2 AM
0 2 * * * certbot renew --quiet --post-hook "kill -USR1 $(cat /var/run/silly.pid)"
```

Combined with Silly's certificate hot reload feature (see below), seamless certificate updates can be achieved.

### Certificate Format Conversion

Silly requires certificates in PEM format. If your certificate is in another format, you need to convert it:

#### DER to PEM

```bash
openssl x509 -inform der -in certificate.cer -out certificate.pem
openssl rsa -inform der -in private-key.der -out private-key.pem
```

#### PKCS#12 (.pfx/.p12) to PEM

```bash
# Extract certificate
openssl pkcs12 -in certificate.pfx -clcerts -nokeys -out certificate.pem

# Extract private key
openssl pkcs12 -in certificate.pfx -nocerts -nodes -out private-key.pem
```

#### PKCS#7 (.p7b) to PEM

```bash
openssl pkcs7 -print_certs -in certificate.p7b -out certificate.pem
```

## Basic Configuration

### HTTPS Server Configuration

```lua
local silly = require "silly"
local tls = require "silly.net.tls"
local http = require "silly.net.http"

-- Certificate and private key (PEM format)
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

-- Start HTTPS server
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

        -- Send response
        stream:respond(200, {
            ["content-type"] = "text/plain",
        })
        stream:closewrite("Hello HTTPS!\n")
    end
}

print("HTTPS server running at https://localhost:8443")
```

### Port Configuration Recommendations

**Standard Ports**:
- `443`: HTTPS standard port (recommended for production)
- `8443`: HTTPS alternate port (commonly used in development)

**HTTP and HTTPS Dual Stack**:

```lua
local silly = require "silly"
local http = require "silly.net.http"

-- HTTP server (port 80)
local http_server = http.listen {
    addr = "0.0.0.0:80",
    protocol = "http",
    handler = function(stream)
        -- Redirect to HTTPS
        local host = stream.header["host"] or "localhost"
        local redirect_url = "https://" .. host .. stream.uri
        stream:respond(301, {
            ["location"] = redirect_url,
        })
        stream:closewrite("")
    end
}

-- HTTPS server (port 443)
local https_server = http.listen {
    addr = "0.0.0.0:443",
    protocol = "https",
    tls = {
        certs = {{cert = cert_pem, key = key_pem}}
    },
    handler = function(stream)
        -- Handle HTTPS request
    end
}

print("HTTP (80) automatically redirects to HTTPS (443)")
```

## Advanced Configuration

### SNI (Server Name Indication) - Multi-Domain Support

SNI allows hosting multiple HTTPS domains on a single IP address, each using a different certificate.

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

-- Prepare certificates for different domains
local cert_example_com = io.open("example.com.pem", "r"):read("*a")
local key_example_com = io.open("example.com-key.pem", "r"):read("*a")

local cert_test_com = io.open("test.com.pem", "r"):read("*a")
local key_test_com = io.open("test.com-key.pem", "r"):read("*a")

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {
        -- First certificate (default certificate)
        {
            cert = cert_example_com,
            key = key_example_com,
        },
        -- Second certificate
        {
            cert = cert_test_com,
            key = key_test_com,
        }
    },
    accept = function(conn)
        -- OpenSSL automatically selects the correct certificate based on the client's SNI request
        conn:write( "HTTP/1.1 200 OK\r\n\r\nHello!\n")
        conn:close()
    end
}

print("Multi-domain HTTPS server running")
```

::: tip How SNI Works
1. Client sends the target domain name (SNI extension) in the TLS handshake
2. Server selects the corresponding certificate based on the domain name
3. Completes TLS handshake and establishes encrypted connection

OpenSSL automatically handles SNI matching without additional code.
:::

### ALPN (Application-Layer Protocol Negotiation) - HTTP/2 Support

ALPN allows clients and servers to negotiate application-layer protocols (such as HTTP/1.1 or HTTP/2) during the TLS handshake.

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {{cert = cert_pem, key = key_pem}},
    -- Declare supported ALPN protocols
    alpnprotos = {"h2", "http/1.1"},  -- Prefer HTTP/2, fallback to HTTP/1.1
    accept = function(conn)
        -- Check negotiation result
        local protocol = tls.alpnproto(fd)
        print("Negotiated protocol:", protocol or "none")

        if protocol == "h2" then
            -- Handle HTTP/2 request
            print("Using HTTP/2")
        elseif protocol == "http/1.1" then
            -- Handle HTTP/1.1 request
            print("Using HTTP/1.1")
        else
            -- No ALPN negotiated (possibly old client)
            print("Using default protocol")
        end

        conn:close()
    end
}

print("HTTPS server supports HTTP/2 and HTTP/1.1")
```

::: tip Advantages of HTTP/2
- **Multiplexing**: Handle multiple requests over one connection, reducing latency
- **Header Compression**: HPACK algorithm reduces bandwidth consumption
- **Server Push**: Proactively push resources to clients
- **Binary Protocol**: More efficient parsing and transmission
:::

### Cipher Suite Selection

Cipher suites define the encryption algorithms used by TLS connections. Configuring secure cipher suites can prevent known attacks.

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {{cert = cert_pem, key = key_pem}},
    -- Recommended cipher suite configuration (TLS 1.2+)
    ciphers = table.concat({
        -- TLS 1.3 cipher suites (highest priority)
        "TLS_AES_128_GCM_SHA256",
        "TLS_AES_256_GCM_SHA384",
        "TLS_CHACHA20_POLY1305_SHA256",
        -- TLS 1.2 cipher suites (backward compatibility)
        "ECDHE-RSA-AES128-GCM-SHA256",
        "ECDHE-RSA-AES256-GCM-SHA384",
        "ECDHE-RSA-CHACHA20-POLY1305",
    }, ":"),
    accept = function(conn)
        conn:close()
    end
}

print("HTTPS server using secure cipher suites")
```

**Security Recommendations**:

::: danger Disable Insecure Cipher Suites
The following insecure cipher suites should be disabled:
- All suites using RC4, DES, 3DES (compromised)
- All suites using MD5 (hash collisions)
- All suites that don't provide Forward Secrecy
- All suites using anonymous authentication (aNULL)
:::

### TLS Version Control

Enforce secure TLS versions and disable obsolete protocols.

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {{cert = cert_pem, key = key_pem}},
    -- Use OpenSSL ciphers string to control TLS versions
    -- "!SSLv3" disables SSLv3
    -- "!TLSv1" disables TLS 1.0
    -- "!TLSv1.1" disables TLS 1.1
    ciphers = "DEFAULT:!SSLv3:!TLSv1:!TLSv1.1",
    accept = function(conn)
        conn:close()
    end
}

print("Enforcing TLS 1.2+ protocols")
```

::: warning TLS Version Security
- **SSLv3**: Compromised by POODLE attack, must be disabled
- **TLS 1.0/1.1**: Known vulnerabilities exist, not recommended
- **TLS 1.2**: Current widely-used secure version
- **TLS 1.3**: Latest version, best performance and security
:::

## Certificate Management

### Certificate Hot Reload (Zero-Downtime Updates)

Silly supports reloading certificates without restarting the service, enabling seamless certificate updates.

```lua
local silly = require "silly"
local tls = require "silly.net.tls"
local signal = require "silly.signal"

-- Certificate file paths
local cert_path = "/etc/certs/server-cert.pem"
local key_path = "/etc/certs/server-key.pem"

-- Helper function to load certificates
local function load_certs()
    local cert_file = io.open(cert_path, "r")
    local cert_pem = cert_file:read("*a")
    cert_file:close()

    local key_file = io.open(key_path, "r")
    local key_pem = key_file:read("*a")
    key_file:close()

    return cert_pem, key_pem
end

-- Initial certificate load
local cert_pem, key_pem = load_certs()

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {{cert = cert_pem, key = key_pem}},
    accept = function(conn)
        conn:write( "HTTP/1.1 200 OK\r\n\r\nHello!\n")
        conn:close()
    end
}

print("HTTPS server started, PID:", silly.pid)

-- Register SIGUSR1 signal handler to trigger certificate reload
signal.register("SIGUSR1", function()
    print("[INFO] Received certificate reload signal...")

    -- Reload certificate files
    local ok, err = pcall(function()
        cert_pem, key_pem = load_certs()
    end)

    if not ok then
        print("[ERROR] Certificate file read failed:", err)
        return
    end

    -- Hot reload certificates
    local success, reload_err = listenfd:reload({
        certs = {{cert = cert_pem, key = key_pem}}
    })

    if success then
        print("[SUCCESS] Certificate reload successful")
    else
        print("[ERROR] Certificate reload failed:", reload_err)
    end
end)

print("Send 'kill -USR1 " .. silly.pid .. "' to reload certificates")
```

**Trigger Certificate Reload**:

```bash
# After updating certificate files, send signal to trigger reload
kill -USR1 $(cat /var/run/silly.pid)
```

::: tip Benefits of Certificate Hot Reload
- **Zero Downtime**: Service continues running without affecting existing connections
- **Smooth Updates**: New connections use new certificates, old connections continue using old certificates until closed
- **Simplified Operations**: No need to coordinate maintenance windows
:::

### Certificate Expiration Monitoring

Proactively monitor certificate expiration time to avoid service disruption due to expired certificates.

```lua
local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local logger = require "silly.logger"

-- Parse PEM certificate expiration time (requires calling openssl command)
local function get_cert_expiry(cert_pem)
    -- Write certificate to temporary file
    local tmp_file = "/tmp/cert_check.pem"
    local f = io.open(tmp_file, "w")
    f:write(cert_pem)
    f:close()

    -- Use openssl command to parse expiration time
    local handle = io.popen("openssl x509 -in " .. tmp_file .. " -noout -enddate")
    local result = handle:read("*a")
    handle:close()

    -- Clean up temporary file
    os.remove(tmp_file)

    -- Parse output: notAfter=Jan 7 09:47:53 2035 GMT
    local expiry_str = result:match("notAfter=(.+)")
    return expiry_str
end

-- Certificate expiration check task
local function monitor_cert_expiry(cert_pem, alert_days)
    alert_days = alert_days or 30  -- Default 30 days advance warning

    task.fork(function()
        while true do
            local expiry_str = get_cert_expiry(cert_pem)
            logger.info("Certificate expiration time:", expiry_str)

            -- More complex date parsing and alerting logic can be added here
            -- For example: calculate remaining days, send alert when less than alert_days

            -- Check once per day
            time.sleep(86400000)  -- 24 hours
        end
    end)
end

local cert_pem = io.open("server-cert.pem", "r"):read("*a")
local key_pem = io.open("server-key.pem", "r"):read("*a")

-- Start certificate expiration monitoring
monitor_cert_expiry(cert_pem, 30)

-- Start HTTPS server
-- ...
```

::: tip Integrate Alert Systems
In production, certificate expiration alerts can be integrated into monitoring systems (like Prometheus, Grafana) or send notifications (email, SMS, Slack).
:::

### Certificate Chain Configuration

When using certificates issued by intermediate CAs, you need to configure the complete certificate chain.

**Certificate Chain Structure**:
```
Server Certificate (your-domain.crt)
    ↓
Intermediate CA Certificate (intermediate.crt)
    ↓
Root CA Certificate (root.crt)  [Trusted by client]
```

**Create Certificate Chain File**:

```bash
# Merge server certificate and intermediate CA certificate
cat your-domain.crt intermediate.crt > fullchain.pem

# If there are multiple intermediate CAs
cat your-domain.crt intermediate1.crt intermediate2.crt > fullchain.pem
```

**Using Certificate Chain in Silly**:

```lua
local silly = require "silly"
local tls = require "silly.net.tls"

-- fullchain.pem contains server certificate + intermediate CA certificate
local fullchain_pem = io.open("fullchain.pem", "r"):read("*a")
local key_pem = io.open("private-key.pem", "r"):read("*a")

local listenfd = tls.listen {
    addr = "0.0.0.0:443",
    certs = {
        {
            cert = fullchain_pem,  -- Complete certificate chain
            key = key_pem,
        }
    },
    accept = function(conn)
        conn:close()
    end
}

print("HTTPS server using complete certificate chain")
```

::: warning Certificate Chain Order
Certificates in the chain file must be arranged in the following order:
1. Server certificate (leaf certificate)
2. Intermediate CA certificate(s) (from bottom to top by hierarchy)
3. Root CA certificate not needed (built into clients)

Incorrect order will prevent clients from verifying the certificate chain.
:::

## Performance Optimization

### TLS Session Cache

TLS handshake is an expensive operation (requires multiple round trips and cryptographic computations). Session caching allows clients to reuse previous TLS sessions, skipping the full handshake.

**OpenSSL Automatically Enables Session Cache**:

OpenSSL enables session caching by default, and Silly's TLS implementation benefits automatically:

- **Session ID**: Server assigns a session ID, client provides it in subsequent connections
- **Session Ticket**: Server encrypts session state and sends it to client, no server storage needed

**Performance Improvement**:
- First connection: Full TLS handshake (~2-3 RTT)
- Session resumption: Abbreviated handshake (~1 RTT), reduced CPU overhead

::: tip Advantages of TLS 1.3
TLS 1.3 introduces 0-RTT resumption, allowing application data to be sent in the first round trip, further reducing latency.
:::

### OCSP Stapling (Online Certificate Status Protocol)

OCSP Stapling allows the server to proactively provide certificate revocation status, avoiding separate OCSP server queries by clients.

**Advantages**:
- Reduces additional network requests from clients
- Improves TLS handshake speed
- Enhances privacy (client doesn't leak access records to CA)

::: info OpenSSL Configuration
Silly's TLS module is based on OpenSSL, OCSP Stapling needs to be enabled in the OpenSSL context. The current version doesn't directly support OCSP Stapling configuration; using a reverse proxy (like Nginx) is recommended.
:::

### Connection Reuse

For high-frequency communication, reusing TLS connections can significantly reduce handshake overhead.

```lua
local silly = require "silly"
local tls = require "silly.net.tls"
local dns = require "silly.net.dns"

-- Connection pool
local connection_pool = {}

-- Get or create connection
local function get_connection(host, port)
    local key = host .. ":" .. port
    local conn = connection_pool[key]

    -- Check if connection is still valid
    if conn and conn:isalive() then
        return conn
    end

    -- Create new connection
    local ip = dns.lookup(host, dns.A)
    conn = tls.connect(ip .. ":" .. port, {hostname = host, alpnprotos = {"http/1.1"}})

    if conn then
        connection_pool[key] = conn
    end

    return conn
end

-- Send request (reuse connection)
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
    -- Send multiple requests, reuse the same connection
    for i = 1, 10 do
        local response = send_request("example.com", 443, "GET / HTTP/1.1\r\n\r\n")
        print(response)
    end
end)
```

::: tip HTTP/2 Connection Reuse
HTTP/2 natively supports multiplexing, allowing one connection to handle multiple concurrent requests. When using HTTP/2, manual connection pool management is unnecessary.
:::

### Performance Monitoring Metrics

Monitor the following metrics to optimize TLS performance:

```lua
local silly = require "silly"
local metrics = require "silly.metrics.prometheus"

-- Define TLS-related metrics
local tls_handshake_duration = metrics.histogram(
    "tls_handshake_duration_seconds",
    "TLS handshake duration",
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0}
)

local tls_connections_total = metrics.counter(
    "tls_connections_total",
    "Total TLS connections"
)

local tls_handshake_errors_total = metrics.counter(
    "tls_handshake_errors_total",
    "TLS handshake failure count"
)

-- Collect metrics during connection handling
local function handle_connection(fd, addr)
    local start_time = silly.time.now()

    -- TLS handshake is already completed in tls.listen's accept callback
    local handshake_duration = (silly.time.now() - start_time) / 1000.0
    tls_handshake_duration:observe(handshake_duration)
    tls_connections_total:inc()

    -- Handle business logic
    -- ...
end
```

## Troubleshooting

### Common Errors

#### 1. Handshake Failed: Certificate Verification Error

**Error Message**:
```
certificate verify failed
SSL_ERROR_SSL: error:14090086:SSL routines:ssl3_get_server_certificate:certificate verify failed
```

**Causes**:
- Certificate expired
- Incomplete certificate chain (missing intermediate CA)
- Domain name mismatch (CN or SAN)
- Client doesn't trust root CA

**Solutions**:

```bash
# Check certificate validity period
openssl x509 -in server-cert.pem -noout -dates

# Check certificate chain
openssl s_client -connect localhost:8443 -showcerts

# Check domain name match
openssl x509 -in server-cert.pem -noout -text | grep -A1 "Subject:"
```

#### 2. Handshake Failed: Cipher Suite Mismatch

**Error Message**:
```
no shared cipher
SSL_ERROR_SSL: error:141640B5:SSL routines:tls_construct_client_hello:no ciphers available
```

**Causes**:
- Client and server have no mutually supported cipher suites
- Server configuration too strict, disabling all client-supported suites

**Solutions**:

```lua
-- Relax cipher suite restrictions (development environment)
ciphers = "HIGH:!aNULL:!MD5"

-- Production environment using recommended configuration
ciphers = "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384"
```

#### 3. Private Key and Certificate Mismatch

**Error Message**:
```
key values mismatch
SSL_CTX_use_PrivateKey_file() failed
```

**Causes**:
- Private key file and certificate file don't match
- Private key file corrupted or wrong format

**Solutions**:

```bash
# Verify if private key and certificate match
# Output of both commands should be identical
openssl x509 -noout -modulus -in server-cert.pem | openssl md5
openssl rsa -noout -modulus -in server-key.pem | openssl md5
```

#### 4. Port Already in Use

**Error Message**:
```
bind failed: Address already in use
```

**Solutions**:

```bash
# Find process occupying port 443
sudo lsof -i :443
# or
sudo netstat -tulpn | grep :443

# Stop process occupying the port
sudo kill <PID>

# Or change port
addr = "0.0.0.0:8443"
```

#### 5. Client Doesn't Trust Self-Signed Certificate

**Browser Error**:
```
NET::ERR_CERT_AUTHORITY_INVALID
Your connection is not private
```

**Solutions**:

**Method 1: Temporary Trust (Testing Only)**
- Chrome: Click "Advanced" → "Proceed to localhost (unsafe)"
- Firefox: "Advanced" → "Accept the Risk and Continue"

**Method 2: Add to System Trust (Local Development)**

```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain server-cert.pem

# Linux (Ubuntu/Debian)
sudo cp server-cert.pem /usr/local/share/ca-certificates/server-cert.crt
sudo update-ca-certificates

# Windows
certutil -addstore -f "ROOT" server-cert.pem
```

**Method 3: Use Trusted Certificates**
- Use Let's Encrypt or commercial CA certificates in production

### Debugging Tools

#### OpenSSL s_client (Test TLS Connection)

```bash
# Connect to HTTPS server and display detailed information
openssl s_client -connect localhost:8443 -showcerts

# Test specific TLS version
openssl s_client -connect localhost:8443 -tls1_2
openssl s_client -connect localhost:8443 -tls1_3

# Test SNI
openssl s_client -connect localhost:8443 -servername example.com

# Test ALPN
openssl s_client -connect localhost:8443 -alpn h2,http/1.1
```

#### curl (Test HTTPS Requests)

```bash
# Send HTTPS request (ignore certificate verification)
curl -k https://localhost:8443

# Display detailed information
curl -v https://localhost:8443

# Display TLS handshake information
curl -v --trace-ascii - https://localhost:8443

# Specify client certificate (mutual TLS)
curl --cert client-cert.pem --key client-key.pem https://localhost:8443
```

#### Online Tools

- **SSL Labs Server Test**: https://www.ssllabs.com/ssltest/
  - Comprehensive HTTPS configuration security check
  - Provides ratings and improvement suggestions
  - Only supports publicly accessible servers

- **SSL Checker**: https://www.sslshopper.com/ssl-checker.html
  - Quick certificate installation check
  - Verify certificate chain integrity

## Security Best Practices

### 1. Use Strong Cipher Suites

```lua
-- Recommended configuration (TLS 1.2+ with Forward Secrecy)
ciphers = "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305"
```

### 2. Enforce TLS 1.2+

```lua
-- Disable SSLv3, TLS 1.0, TLS 1.1
ciphers = "DEFAULT:!SSLv3:!TLSv1:!TLSv1.1"
```

### 3. Protect Private Key Files

```bash
# Set strict file permissions
chmod 600 server-key.pem
chown app-user:app-user server-key.pem

# Don't commit private keys to version control
echo "*.pem" >> .gitignore
echo "*.key" >> .gitignore
```

### 4. Enable HSTS (HTTP Strict Transport Security)

```lua
-- Add HSTS header in HTTP response
stream:respond(200, {
    ["strict-transport-security"] = "max-age=31536000; includeSubDomains; preload",
})
stream:closewrite(body)
```

HSTS forces browsers to only access websites via HTTPS, preventing man-in-the-middle attacks.

### 5. Regularly Update Certificates

- Let's Encrypt certificates expire every 90 days, configure automatic renewal
- Monitor certificate expiration time, update 30 days in advance
- Use certificate hot reload for seamless updates

### 6. Use Certificate Pinning

For mobile apps or critical services, implement certificate pinning to prevent man-in-the-middle attacks:

```lua
-- Client example: verify server certificate fingerprint
local expected_fingerprint = "AA:BB:CC:DD:..."

-- In actual applications, need to obtain and verify certificate fingerprint
-- This is typically implemented in client SDKs
```

## Complete Example: Production-Grade HTTPS Server

```lua
local silly = require "silly"
local http = require "silly.net.http"
local signal = require "silly.signal"
local logger = require "silly.logger"

-- Configuration
local config = {
    http_port = 80,
    https_port = 443,
    cert_path = "/etc/certs/fullchain.pem",
    key_path = "/etc/certs/privkey.pem",
}

-- Load certificates
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

-- HTTP server (redirect to HTTPS)
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

-- HTTPS server
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

        -- Handle request
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
    <h1>Welcome to Silly HTTPS Server</h1>
    <p>Current protocol: ]] .. protocol .. [[</p>
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

logger.info("HTTP server running on port " .. config.http_port)
logger.info("HTTPS server running on port " .. config.https_port)

-- Certificate hot reload
signal.register("SIGUSR1", function()
    logger.info("Received certificate reload signal...")

    local ok, err = pcall(function()
        cert_pem, key_pem = load_certs()
    end)

    if not ok then
        logger.error("Certificate file read failed:", err)
        return
    end

    -- Reload HTTPS server certificates
    local success, reload_err = https_server:reload({
        certs = {{cert = cert_pem, key = key_pem}}
    })

    if success then
        logger.info("Certificate reload successful")
    else
        logger.error("Certificate reload failed:", reload_err)
    end
end)

logger.info("Send 'kill -USR1 " .. silly.pid .. "' to reload certificates")
```

Running the server:

```bash
# Compile (with OpenSSL enabled)
make OPENSSL=ON

# Run server (requires root permissions to bind ports 80/443)
sudo ./silly https_server.lua
```

## Summary

This guide covers all aspects of TLS/HTTPS configuration in the Silly framework:

- **Certificate Preparation**: Self-signed certificates, Let's Encrypt, certificate format conversion
- **Basic Configuration**: HTTPS server, port configuration, HTTP to HTTPS redirection
- **Advanced Configuration**: SNI multi-domain, ALPN HTTP/2, cipher suites, TLS version control
- **Certificate Management**: Hot reload, expiration monitoring, certificate chains
- **Performance Optimization**: Session cache, connection reuse, performance metrics
- **Troubleshooting**: Common errors, debugging tools
- **Security Practices**: Strong cipher suites, HSTS, private key protection

::: tip Recommended Reading
- [silly.net.tls API Reference](/en/reference/net/tls.md) - Complete TLS module API documentation
- [silly.net.http API Reference](/en/reference/net/http.md) - HTTP/HTTPS server API
- [HTTPS Tutorial](/en/tutorials/http-server.md) - Build a complete HTTPS application
:::
