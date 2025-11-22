---
title: JWT (JSON Web Token)
icon: key
category:
  - API Reference
tag:
  - Security
  - Authentication
  - JWT
  - Token
---

# silly.security.jwt

JWT (JSON Web Token) is an open standard (RFC 7519) for securely transmitting information between parties as a JSON object. JWT is widely used for authentication and information exchange, particularly suitable for Single Sign-On (SSO) and API authorization scenarios.

## Overview

The `silly.security.jwt` module provides complete JWT encoding and decoding functionality, supporting multiple signature algorithms:

- **HMAC algorithms** (HS256, HS384, HS512): Symmetric encryption using a shared secret
- **RSA algorithms** (RS256, RS384, RS512): Asymmetric encryption using RSA public/private key pairs
- **ECDSA algorithms** (ES256, ES384, ES512): Asymmetric encryption using elliptic curve public/private key pairs

JWT consists of three parts, separated by dots (`.`):

```
Header.Payload.Signature
```

1. **Header**: Contains token type and signature algorithm
2. **Payload**: Contains claims, i.e., the actual data being transmitted
3. **Signature**: Used to verify the integrity and authenticity of the token

## Module Import

```lua validate
local jwt = require "silly.security.jwt"
```

## Core Concepts

### JWT Structure

A typical JWT token example:

```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
```

Decoded contents:

- **Header**: `{"alg":"HS256","typ":"JWT"}`
- **Payload**: `{"sub":"1234567890","name":"John Doe","iat":1516239022}`
- **Signature**: Hash value signed with the key

### Standard Claims

The JWT specification defines some standard claim fields (optional):

- `iss` (Issuer): Token issuer
- `sub` (Subject): Token subject, usually the user ID
- `aud` (Audience): Token recipient
- `exp` (Expiration Time): Expiration time (Unix timestamp)
- `nbf` (Not Before): Activation time
- `iat` (Issued At): Issue time
- `jti` (JWT ID): Unique token identifier

### Algorithm Support

| Algorithm | Type | Hash Function | Key Type |
|------|------|----------|----------|
| HS256 | HMAC | SHA-256 | Shared secret (string) |
| HS384 | HMAC | SHA-384 | Shared secret (string) |
| HS512 | HMAC | SHA-512 | Shared secret (string) |
| RS256 | RSA | SHA-256 | RSA public/private key pair |
| RS384 | RSA | SHA-384 | RSA public/private key pair |
| RS512 | RSA | SHA-512 | RSA public/private key pair |
| ES256 | ECDSA | SHA-256 | EC public/private key pair |
| ES384 | ECDSA | SHA-384 | EC public/private key pair |
| ES512 | ECDSA | SHA-512 | EC public/private key pair |

## API Reference

### jwt.encode(payload, key, algname)

Encodes a payload into a JWT token.

- **Parameters**:
  - `payload`: `table` - JWT payload containing the data (claims) to transmit
  - `key`: `string|userdata` - Signing key
    - For HMAC algorithms (HS256/HS384/HS512): Use a string secret
    - For RSA/ECDSA algorithms: Use a private key object created by `silly.crypto.pkey`
  - `algname`: `string` - Signature algorithm name, optional, defaults to `"HS256"`
    - Supported: `"HS256"`, `"HS384"`, `"HS512"`, `"RS256"`, `"RS384"`, `"RS512"`, `"ES256"`, `"ES384"`, `"ES512"`
- **Returns**:
  - Success: `string` - JWT token string
  - Failure: `nil, string` - nil and error message
- **Example**:

```lua validate
local jwt = require "silly.security.jwt"

-- Using HMAC-SHA256 algorithm (default)
local payload = {
    sub = "user123",
    name = "John",
    admin = true,
    iat = os.time()
}

local secret = "my-secret-key-2024"
local token, err = jwt.encode(payload, secret, "HS256")
if not token then
    print("Encoding failed:", err)
else
    print("JWT token:", token)
end
```

### jwt.decode(token, key)

Decodes and verifies a JWT token.

- **Parameters**:
  - `token`: `string` - JWT token string
  - `key`: `string|userdata` - Verification key
    - For HMAC algorithms: Use the same string secret
    - For RSA/ECDSA algorithms: Use a public key object created by `silly.crypto.pkey`
- **Returns**:
  - Success: `table` - Decoded payload data
  - Failure: `nil, string` - nil and error message
    - `"invalid token format"` - Token format error
    - `"invalid header"` - Invalid header
    - `"invalid payload"` - Invalid payload
    - `"invalid signature"` - Invalid signature
    - `"unsupported algorithm: XXX"` - Unsupported algorithm
    - `"signature verification failed"` - Signature verification failed
- **Example**:

```lua validate
local jwt = require "silly.security.jwt"

local token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMTIzIiwibmFtZSI6IuW8oOS4iSIsImFkbWluIjp0cnVlLCJpYXQiOjE3MTYyMzkwMjJ9.Xmb8K_example_signature"
local secret = "my-secret-key-2024"

local payload, err = jwt.decode(token, secret)
if not payload then
    print("Decoding failed:", err)
else
    print("User ID:", payload.sub)
    print("Username:", payload.name)
    print("Is admin:", payload.admin)
end
```

## Usage Examples

### Basic Usage: HMAC Signature

```lua validate
local jwt = require "silly.security.jwt"

-- Encode
local payload = {
    sub = "user001",
    name = "John",
    exp = os.time() + 3600  -- Expires in 1 hour
}
local secret = "super-secret-key"
local token = jwt.encode(payload, secret, "HS256")

-- Decode
local decoded, err = jwt.decode(token, secret)
if decoded then
    print("User:", decoded.name)
    print("Expiration:", decoded.exp)
end
```

### RSA Asymmetric Signature

```lua validate
local jwt = require "silly.security.jwt"
local pkey = require "silly.crypto.pkey"

-- Load RSA private key (for signing)
local private_key = pkey.new([[
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCtLWMWY5gVqqu0
lezUSXdhaT5vwldh5zbho4toYxCZuWjMBTPexwKMtXRXUnrEkZvflHc5TYlA4JPV
yEEAFhc3o39M1P+c2Fld1KKd6jJBiR/EN445/3Db5/DpPfYyz/of2wWS5de79Q7X
JG9tajM+Rl95uFpmjG963tbs5sH4Wbjvmv5qn+JzHZivVs+Dug/PdUG+yAaq6Cb7
SZ2m3RhRJHJB3R+KGZgKy/qV2bqZ+CgTSFU62GvnYqra8AxyX2QSTKGCHPD5bcz5
VeWAnBuUhMH0MQE/Ypq51RrqANiw6lq6hTy9pzI0AtItdM7t+1NzNEUg0/dr2Z1i
DlMeuSopAgMBAAECggEAYVue1TtwiN3GYmPXHRGgV9c/Dr2HOrcuF3RGL41iC8o8
rFZQbvIa8Ngia+Umt9PUecGRtVltzFd1RT6rrEy/CLyWGK+2dIr80s90DKtZTZa1
kS5aeyisXjTrL3VyL+bUi4wqegdVXYnLqhAFxNFrtZsCmf+WcwiIs98LnWutqNx7
QJR2HedjBXk+mXxkaonGyIjcXiowoXdIF/XhvR4CsH9G0OG3iD0g0ZkHGZ2zqGu7
qo9o2YwE1y1PTwd4otsuPITveCqj6egAm9rpHqaRQtRhAJqUPeKfKO2vlxdJrzLb
KyngzusRgz/gz3yQtL7ink19+/p9HSnbqCasJ8QwAQKBgQDaYPnJnw0TyUG0GpyG
MzC77vDqhbWGETPpgNS51UFRCpwrwY6URBMXw393YEb0DyLiP9w5U8camJC7DH1O
I/A+gWDT6x/LX3axC36ydhz00hiPXJMHHXUr4L3dQHCZQuW5HNm4VKBqGo2d8Yy1
KTpVyv8E0T0jtlDaz9cEas8igQKBgQDLAurBU8abUvoFFGMkfxoehsa7SLOudgTF
5BVhwVLZ71UdD5pjSzfTeKyIMZDLHQca0HuQ4Ee4LMJFp/3LGkvJYRhpI4XNxa8b
rg8x+VnFR7vMKzM4BiR7vzzQLk9Yl8JbUFCwu/0wqvi4K84V0BigSugYo+jO7mC0
cDyrWOPjqQKBgQCbln5BZV2m3DxAurkMcEpni50AKpWjWHxZAF4PrN3lhJ6yGiyg
fEPyKWqWvfSvjF05P3CDM6pmy45KhmJ8muRfVESNmDbF6lUhXOQ++CI3V70B314t
spI52dzMV04iE+SiV+jTCRBlqFd/0YqDxET4vTGm2AEsgYfn7i7uyb6cgQKBgQCS
hb9z24hb8M6dPfK0k7wBTls/LyDoiSu2vIEmNgcbXp76w5k1k0NusQktn0CXKJNJ
KjIVBZsd9cgdyDroDUmnxhl9QPNA6i4Rd1ZmRkchmT2VBZUJGX3ZhtRYmSQRmC7i
AxzKAlSifLPZEVzD55bukkHkDuFoASrw8JUJQrXwSQKBgGJNgiOksXQHGBMRQ4RN
58yxce1MjsPb6lUT4fU1I9XoIOrXi3LMGRbwCEQcTnAl/fmqX/mn/OU0uWKhtB00
mWF54QYcPrCDl4QWZjmnM9TeWab0Fdz5uGUe2PxhHs5dQ2hYRloTA/U+NsNLdiwW
BHo1sC5Ix5jbkO/TaUMKGmNb
-----END PRIVATE KEY-----
]])

-- Load RSA public key (for verification)
local public_key = pkey.new([[
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArS1jFmOYFaqrtJXs1El3
YWk+b8JXYec24aOLaGMQmblozAUz3scCjLV0V1J6xJGb35R3OU2JQOCT1chBABYX
N6N/TNT/nNhZXdSineoyQYkfxDeOOf9w2+fw6T32Ms/6H9sFkuXXu/UO1yRvbWoz
PkZfebhaZoxvet7W7ObB+Fm475r+ap/icx2Yr1bPg7oPz3VBvsgGqugm+0mdpt0Y
USRyQd0fihmYCsv6ldm6mfgoE0hVOthr52Kq2vAMcl9kEkyhghzw+W3M+VXlgJwb
lITB9DEBP2KaudUa6gDYsOpauoU8vacyNALSLXTO7ftTczRFINP3a9mdYg5THrkq
KQIDAQAB
-----END PUBLIC KEY-----
]])

-- Sign with private key
local payload = {sub = "admin", role = "superuser"}
local token = jwt.encode(payload, private_key, "RS256")

-- Verify with public key
local decoded, err = jwt.decode(token, public_key)
if decoded then
    print("Role:", decoded.role)
end
```

### ECDSA Elliptic Curve Signature

```lua validate
local jwt = require "silly.security.jwt"
local pkey = require "silly.crypto.pkey"

-- Load EC private key
local ec_private = pkey.new([[
-----BEGIN EC PRIVATE KEY-----
MHQCAQEEICaCaDvEFIgrZXksCEe/FG1803c71gyUBI362hd8vuNyoAcGBSuBBAAK
oUQDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf/c+hOGwHalqi6V1wAiC1Hcx/
T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END EC PRIVATE KEY-----
]])

-- Load EC public key
local ec_public = pkey.new([[
-----BEGIN PUBLIC KEY-----
MFYwEAYHKoZIzj0CAQYFK4EEAAoDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf
/c+hOGwHalqi6V1wAiC1Hcx/T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END PUBLIC KEY-----
]])

local payload = {device_id = "mobile-001", os = "Android"}
local token = jwt.encode(payload, ec_private, "ES256")
local decoded = jwt.decode(token, ec_public)
print("Device OS:", decoded.os)
```

### User Authentication Scenario

```lua validate
local jwt = require "silly.security.jwt"
local silly = require "silly"

-- Simulate user login
local function login(username, password)
    -- Verify username and password (simplified example)
    if username == "admin" and password == "password123" then
        local payload = {
            sub = "user_" .. silly.genid(),  -- Unique user ID
            username = username,
            role = "admin",
            iat = os.time(),              -- Issue time
            exp = os.time() + 7200        -- Expires in 2 hours
        }
        local secret = "jwt-secret-2024"
        local token, err = jwt.encode(payload, secret, "HS256")
        return {success = true, token = token}
    else
        return {success = false, error = "Invalid credentials"}
    end
end

-- Simulate token verification
local function verify_token(token)
    local secret = "jwt-secret-2024"
    local payload, err = jwt.decode(token, secret)

    if not payload then
        return nil, "Invalid token: " .. err
    end

    -- Check if expired
    if payload.exp and payload.exp < os.time() then
        return nil, "Token expired"
    end

    return payload
end

-- Usage example
local result = login("admin", "password123")
if result.success then
    print("Login successful, Token:", result.token)

    -- Verify token
    local user, err = verify_token(result.token)
    if user then
        print("User:", user.username, "Role:", user.role)
    else
        print("Verification failed:", err)
    end
end
```

### API Authorization Middleware

```lua validate
local jwt = require "silly.security.jwt"

-- JWT authentication middleware
local function jwt_middleware(request_headers)
    local auth_header = request_headers["Authorization"]
    if not auth_header then
        return nil, "Missing Authorization header"
    end

    -- Extract Bearer Token
    local token = auth_header:match("^Bearer%s+(.+)$")
    if not token then
        return nil, "Invalid Authorization format"
    end

    local secret = "api-secret-key"
    local payload, err = jwt.decode(token, secret)

    if not payload then
        return nil, "Invalid token: " .. err
    end

    -- Check expiration time
    if payload.exp and payload.exp < os.time() then
        return nil, "Token expired"
    end

    -- Check permissions
    if payload.scope and not payload.scope:match("api:read") then
        return nil, "Insufficient permissions"
    end

    return payload
end

-- Use middleware to protect API
local function protected_api_handler()
    local request_headers = {
        ["Authorization"] = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
    }

    local user, err = jwt_middleware(request_headers)
    if not user then
        print("Access denied:", err)
        return {status = 401, body = {error = err}}
    end

    -- Handle authorized request
    return {status = 200, body = {data = "Protected resource", user = user.sub}}
end

local response = protected_api_handler()
print("Status code:", response.status)
```

### Token Refresh Mechanism

```lua validate
local jwt = require "silly.security.jwt"

local secret = "refresh-secret"
local access_token_ttl = 900   -- 15 minutes
local refresh_token_ttl = 604800  -- 7 days

-- Generate access and refresh tokens
local function generate_tokens(user_id)
    local now = os.time()

    -- Access token (short-lived)
    local access_payload = {
        sub = user_id,
        type = "access",
        iat = now,
        exp = now + access_token_ttl
    }
    local access_token = jwt.encode(access_payload, secret, "HS256")

    -- Refresh token (long-lived)
    local refresh_payload = {
        sub = user_id,
        type = "refresh",
        iat = now,
        exp = now + refresh_token_ttl
    }
    local refresh_token = jwt.encode(refresh_payload, secret, "HS256")

    return {
        access_token = access_token,
        refresh_token = refresh_token,
        expires_in = access_token_ttl
    }
end

-- Refresh access token
local function refresh_access_token(refresh_token)
    local payload, err = jwt.decode(refresh_token, secret)

    if not payload then
        return nil, "Invalid refresh token"
    end

    if payload.type ~= "refresh" then
        return nil, "Not a refresh token"
    end

    if payload.exp < os.time() then
        return nil, "Refresh token expired"
    end

    -- Generate new access token
    return generate_tokens(payload.sub)
end

-- Usage example
local tokens = generate_tokens("user_12345")
print("Access token:", tokens.access_token)
print("Refresh token:", tokens.refresh_token)

-- Refresh after 15 minutes
local new_tokens = refresh_access_token(tokens.refresh_token)
if new_tokens then
    print("New access token:", new_tokens.access_token)
end
```

### Custom Claims and Role Permissions

```lua validate
local jwt = require "silly.security.jwt"

-- Generate token with permissions
local function create_permission_token(user_info)
    local payload = {
        sub = user_info.id,
        username = user_info.username,
        email = user_info.email,
        role = user_info.role,
        permissions = user_info.permissions,  -- Custom permission list
        org_id = user_info.org_id,           -- Custom organization ID
        iat = os.time(),
        exp = os.time() + 3600
    }

    local secret = "permission-secret"
    return jwt.encode(payload, secret, "HS512")  -- Use stronger algorithm
end

-- Permission check function
local function has_permission(token, required_permission)
    local secret = "permission-secret"
    local payload, err = jwt.decode(token, secret)

    if not payload then
        return false, err
    end

    if not payload.permissions then
        return false, "No permissions in token"
    end

    for _, perm in ipairs(payload.permissions) do
        if perm == required_permission then
            return true
        end
    end

    return false, "Permission denied"
end

-- Usage example
local user = {
    id = "user_001",
    username = "developer",
    email = "dev@example.com",
    role = "developer",
    permissions = {"read:code", "write:code", "deploy:staging"},
    org_id = "org_001"
}

local token = create_permission_token(user)
print("Permission token generated")

-- Check permission
local ok, err = has_permission(token, "deploy:staging")
if ok then
    print("User has permission to deploy to staging")
else
    print("Insufficient permissions:", err)
end
```

### Multi-Algorithm Support Example

```lua validate
local jwt = require "silly.security.jwt"

-- Demonstrate all HMAC algorithms
local function test_hmac_algorithms()
    local payload = {message = "Hello JWT", timestamp = os.time()}
    local secret = "test-secret-key"

    local algorithms = {"HS256", "HS384", "HS512"}
    local results = {}

    for _, alg in ipairs(algorithms) do
        local token = jwt.encode(payload, secret, alg)
        local decoded = jwt.decode(token, secret)

        results[alg] = {
            token_length = #token,
            success = (decoded ~= nil),
            algorithm = alg
        }
    end

    return results
end

-- Run test
local results = test_hmac_algorithms()
for alg, info in pairs(results) do
    print(string.format("%s: Token length=%d, Verification=%s",
        alg, info.token_length, info.success and "success" or "failed"))
end
```

### Error Handling Best Practices

```lua validate
local jwt = require "silly.security.jwt"

-- Complete error handling example
local function safe_jwt_operation(token, secret)
    -- Decode token
    local payload, err = jwt.decode(token, secret)
    if not payload then
        -- Return different HTTP status codes based on error type
        local error_map = {
            ["invalid token format"] = {code = 400, message = "Token format error"},
            ["invalid signature"] = {code = 400, message = "Invalid signature"},
            ["signature verification failed"] = {code = 401, message = "Signature verification failed"},
            ["unsupported algorithm"] = {code = 400, message = "Unsupported algorithm"},
        }

        local error_info = error_map[err] or {code = 500, message = "Unknown error"}
        return nil, error_info.code, error_info.message
    end

    -- Validate standard claims
    local now = os.time()

    -- Check expiration time
    if payload.exp and payload.exp < now then
        return nil, 401, "Token expired"
    end

    -- Check not before time
    if payload.nbf and payload.nbf > now then
        return nil, 401, "Token not yet valid"
    end

    -- Check required fields
    if not payload.sub then
        return nil, 400, "Token missing subject field"
    end

    return payload, 200, "Verification successful"
end

-- Usage example
local test_token = jwt.encode({sub = "user123", exp = os.time() + 3600}, "secret", "HS256")
local payload, code, message = safe_jwt_operation(test_token, "secret")

if payload then
    print("Verification successful, User ID:", payload.sub)
else
    print(string.format("Verification failed (HTTP %d): %s", code, message))
end
```

## Important Notes

### Security Considerations

1. **Key Management**
   - HMAC keys should be sufficiently long (at least 256 bits recommended) and random
   - Private key files should be properly secured to prevent leakage
   - Production environments should use Key Management Systems (KMS)
   - Rotate keys regularly

2. **Algorithm Selection**
   - HMAC algorithms are suitable for simple scenarios where the server signs and verifies itself
   - RSA/ECDSA algorithms are suitable for distributed systems where public keys can be distributed publicly
   - Recommend using HS256, RS256, or ES256 (faster and more secure)

3. **Token Transmission**
   - Always transmit JWT over HTTPS
   - Avoid passing tokens in URLs (use HTTP Headers)
   - Use the standard `Authorization: Bearer <token>` header

4. **Sensitive Information**
   - JWT Payload is Base64 encoded, not encrypted
   - Do not store passwords, keys, or other sensitive information in the Payload
   - For encryption, use JWE (JSON Web Encryption)

### Expiration Time Handling

```lua
-- Recommended expiration time settings
local token_ttl = {
    access = 15 * 60,        -- Access token: 15 minutes
    refresh = 7 * 24 * 3600, -- Refresh token: 7 days
    remember = 30 * 24 * 3600 -- Remember me: 30 days
}

-- Always verify expiration time
local function is_token_expired(payload)
    if not payload.exp then
        return false  -- No expiration time means never expires
    end
    return payload.exp < os.time()
end
```

### Performance Optimization

1. **Header Caching**
   - The module internally caches Headers for different algorithms, avoiding repeated encoding
   - Multiple encodings with the same algorithm share the same Header string

2. **Key Reuse**
   - For RSA/ECDSA, reuse `pkey` objects to avoid repeated loading
   - Public key objects can be cached in global variables

3. **Batch Verification**
   - For high-concurrency scenarios, consider using connection pools and caching mechanisms
   - Can cache verified token results (note expiration times)

### Common Errors

| Error Message | Cause | Solution |
|---------|------|---------|
| `invalid token format` | Token is not in three-part format | Check if token is complete |
| `invalid header/payload/signature` | Base64 decoding failed or JSON parsing failed | Check if token is truncated or tampered |
| `unsupported algorithm: XXX` | Using an unsupported algorithm | Use one of the 9 supported algorithms |
| `signature verification failed` | Signature verification failed | Check if key is correct, if token is tampered |

## Best Practices

### 1. Use Environment Variables to Manage Keys

```lua
-- Don't hardcode keys
-- Wrong example:
-- local secret = "my-secret-key"

-- Correct example: Read from environment variable
local secret = os.getenv("JWT_SECRET") or error("JWT_SECRET not set")
```

### 2. Implement Token Blacklist

```lua
-- Maintain a blacklist for logged out or revoked tokens
local blacklist = {}  -- In real applications, use Redis, etc.

local function revoke_token(token)
    local payload = jwt.decode(token, secret)
    if payload and payload.jti then
        blacklist[payload.jti] = payload.exp
    end
end

local function is_token_revoked(token)
    local payload = jwt.decode(token, secret)
    return payload and payload.jti and blacklist[payload.jti] ~= nil
end
```

### 3. Use JTI to Prevent Replay Attacks

```lua
local silly = require "silly"
local jwt = require "silly.security.jwt"

local payload = {
    sub = "user123",
    jti = silly.genid(),  -- Unique token ID
    iat = os.time(),
    exp = os.time() + 3600
}
```

### 4. Implement Token Version Control

```lua
-- Invalidate tokens after user changes password
local payload = {
    sub = user_id,
    token_version = user.token_version,  -- Stored in database
    exp = os.time() + 3600
}

-- Check version during verification
local function validate_token_version(payload, user)
    return payload.token_version == user.token_version
end
```

### 5. Multi-Environment Configuration

```lua
local config = {
    development = {
        secret = "dev-secret",
        algorithm = "HS256",
        ttl = 86400  -- 24 hours
    },
    production = {
        secret = os.getenv("JWT_SECRET"),
        algorithm = "RS256",  -- Use asymmetric encryption in production
        ttl = 3600  -- 1 hour
    }
}

local env = os.getenv("ENV") or "development"
local jwt_config = config[env]
```

## See Also

- [silly.crypto.pkey](../crypto/pkey.md) - Public/private key encryption (RSA/ECDSA algorithm support)
- [silly.crypto.hmac](../crypto/hmac.md) - HMAC message authentication code (HS256/HS384/HS512 algorithm support)
- [silly.encoding.base64](../encoding/base64.md) - Base64 encoding (JWT uses URL-Safe Base64)
- [silly.encoding.json](../encoding/json.md) - JSON encoding/decoding (Header and Payload encoding)
- [silly.net.http](../net/http.md) - HTTP server (implement API authentication with JWT)

## Standards Reference

- [RFC 7519 - JSON Web Token (JWT)](https://tools.ietf.org/html/rfc7519)
- [RFC 7515 - JSON Web Signature (JWS)](https://tools.ietf.org/html/rfc7515)
- [RFC 7518 - JSON Web Algorithms (JWA)](https://tools.ietf.org/html/rfc7518)
