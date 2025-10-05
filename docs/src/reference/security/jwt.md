---
title: JWT（JSON Web Token）
icon: key
category:
  - API 参考
tag:
  - 安全
  - 认证
  - JWT
  - Token
---

# silly.security.jwt

JWT（JSON Web Token）是一种开放标准（RFC 7519），用于在各方之间安全地传输信息作为 JSON 对象。JWT 广泛用于身份验证和信息交换，特别适合单点登录（SSO）和 API 授权场景。

## 概述

`silly.security.jwt` 模块提供了完整的 JWT 编码和解码功能，支持多种签名算法：

- **HMAC 算法**（HS256、HS384、HS512）：使用共享密钥的对称加密
- **RSA 算法**（RS256、RS384、RS512）：使用 RSA 公私钥对的非对称加密
- **ECDSA 算法**（ES256、ES384、ES512）：使用椭圆曲线公私钥对的非对称加密

JWT 由三部分组成，用点号（`.`）分隔：

```
Header.Payload.Signature
```

1. **Header（头部）**：包含令牌类型和签名算法
2. **Payload（载荷）**：包含声明（Claims），即实际传输的数据
3. **Signature（签名）**：用于验证令牌的完整性和真实性

## 模块导入

```lua validate
local jwt = require "silly.security.jwt"
```

## 核心概念

### JWT 结构

一个典型的 JWT 令牌示例：

```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c
```

解码后的内容：

- **Header**: `{"alg":"HS256","typ":"JWT"}`
- **Payload**: `{"sub":"1234567890","name":"John Doe","iat":1516239022}`
- **Signature**: 使用密钥签名的哈希值

### 标准声明（Claims）

JWT 规范定义了一些标准声明字段（可选）：

- `iss`（Issuer）：令牌签发者
- `sub`（Subject）：令牌主题，通常是用户 ID
- `aud`（Audience）：令牌接收者
- `exp`（Expiration Time）：过期时间（Unix 时间戳）
- `nbf`（Not Before）：生效时间
- `iat`（Issued At）：签发时间
- `jti`（JWT ID）：令牌唯一标识符

### 算法支持

| 算法 | 类型 | 哈希函数 | 密钥类型 |
|------|------|----------|----------|
| HS256 | HMAC | SHA-256 | 共享密钥（字符串） |
| HS384 | HMAC | SHA-384 | 共享密钥（字符串） |
| HS512 | HMAC | SHA-512 | 共享密钥（字符串） |
| RS256 | RSA | SHA-256 | RSA 公私钥对 |
| RS384 | RSA | SHA-384 | RSA 公私钥对 |
| RS512 | RSA | SHA-512 | RSA 公私钥对 |
| ES256 | ECDSA | SHA-256 | EC 公私钥对 |
| ES384 | ECDSA | SHA-384 | EC 公私钥对 |
| ES512 | ECDSA | SHA-512 | EC 公私钥对 |

## API 参考

### jwt.encode(payload, key, algname)

将 Payload 编码为 JWT 令牌。

- **参数**:
  - `payload`: `table` - JWT 载荷，包含要传输的数据（声明）
  - `key`: `string|userdata` - 签名密钥
    - 对于 HMAC 算法（HS256/HS384/HS512）：使用字符串密钥
    - 对于 RSA/ECDSA 算法：使用 `silly.crypto.pkey` 创建的私钥对象
  - `algname`: `string` - 签名算法名称，可选，默认为 `"HS256"`
    - 支持：`"HS256"`, `"HS384"`, `"HS512"`, `"RS256"`, `"RS384"`, `"RS512"`, `"ES256"`, `"ES384"`, `"ES512"`
- **返回值**:
  - 成功: `string` - JWT 令牌字符串
  - 失败: `nil, string` - nil 和错误信息
- **示例**:

```lua validate
local jwt = require "silly.security.jwt"

-- 使用 HMAC-SHA256 算法（默认）
local payload = {
    sub = "user123",
    name = "张三",
    admin = true,
    iat = os.time()
}

local secret = "my-secret-key-2024"
local token, err = jwt.encode(payload, secret, "HS256")
if not token then
    print("编码失败:", err)
else
    print("JWT 令牌:", token)
end
```

### jwt.decode(token, key)

解码并验证 JWT 令牌。

- **参数**:
  - `token`: `string` - JWT 令牌字符串
  - `key`: `string|userdata` - 验证密钥
    - 对于 HMAC 算法：使用相同的字符串密钥
    - 对于 RSA/ECDSA 算法：使用 `silly.crypto.pkey` 创建的公钥对象
- **返回值**:
  - 成功: `table` - 解码后的 Payload 数据
  - 失败: `nil, string` - nil 和错误信息
    - `"invalid token format"` - 令牌格式错误
    - `"invalid header"` - 头部无效
    - `"invalid payload"` - 载荷无效
    - `"invalid signature"` - 签名无效
    - `"unsupported algorithm: XXX"` - 不支持的算法
    - `"signature verification failed"` - 签名验证失败
- **示例**:

```lua validate
local jwt = require "silly.security.jwt"

local token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMTIzIiwibmFtZSI6IuW8oOS4iSIsImFkbWluIjp0cnVlLCJpYXQiOjE3MTYyMzkwMjJ9.Xmb8K_example_signature"
local secret = "my-secret-key-2024"

local payload, err = jwt.decode(token, secret)
if not payload then
    print("解码失败:", err)
else
    print("用户 ID:", payload.sub)
    print("用户名:", payload.name)
    print("是否管理员:", payload.admin)
end
```

## 使用示例

### 基本用法：HMAC 签名

```lua validate
local jwt = require "silly.security.jwt"

-- 编码
local payload = {
    sub = "user001",
    name = "李四",
    exp = os.time() + 3600  -- 1小时后过期
}
local secret = "super-secret-key"
local token = jwt.encode(payload, secret, "HS256")

-- 解码
local decoded, err = jwt.decode(token, secret)
if decoded then
    print("用户:", decoded.name)
    print("过期时间:", decoded.exp)
end
```

### RSA 非对称签名

```lua validate
local jwt = require "silly.security.jwt"
local pkey = require "silly.crypto.pkey"

-- 加载 RSA 私钥（用于签名）
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

-- 加载 RSA 公钥（用于验证）
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

-- 使用私钥签名
local payload = {sub = "admin", role = "superuser"}
local token = jwt.encode(payload, private_key, "RS256")

-- 使用公钥验证
local decoded, err = jwt.decode(token, public_key)
if decoded then
    print("角色:", decoded.role)
end
```

### ECDSA 椭圆曲线签名

```lua validate
local jwt = require "silly.security.jwt"
local pkey = require "silly.crypto.pkey"

-- 加载 EC 私钥
local ec_private = pkey.new([[
-----BEGIN EC PRIVATE KEY-----
MHQCAQEEICaCaDvEFIgrZXksCEe/FG1803c71gyUBI362hd8vuNyoAcGBSuBBAAK
oUQDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf/c+hOGwHalqi6V1wAiC1Hcx/
T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END EC PRIVATE KEY-----
]])

-- 加载 EC 公钥
local ec_public = pkey.new([[
-----BEGIN PUBLIC KEY-----
MFYwEAYHKoZIzj0CAQYFK4EEAAoDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf
/c+hOGwHalqi6V1wAiC1Hcx/T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END PUBLIC KEY-----
]])

local payload = {device_id = "mobile-001", os = "Android"}
local token = jwt.encode(payload, ec_private, "ES256")
local decoded = jwt.decode(token, ec_public)
print("设备系统:", decoded.os)
```

### 用户认证场景

```lua validate
local jwt = require "silly.security.jwt"
local silly = require "silly"

-- 模拟用户登录
local function login(username, password)
    -- 验证用户名和密码（简化示例）
    if username == "admin" and password == "password123" then
        local payload = {
            sub = "user_" .. silly.genid(),  -- 用户唯一 ID
            username = username,
            role = "admin",
            iat = os.time(),              -- 签发时间
            exp = os.time() + 7200        -- 2小时后过期
        }
        local secret = "jwt-secret-2024"
        local token, err = jwt.encode(payload, secret, "HS256")
        return {success = true, token = token}
    else
        return {success = false, error = "Invalid credentials"}
    end
end

-- 模拟验证令牌
local function verify_token(token)
    local secret = "jwt-secret-2024"
    local payload, err = jwt.decode(token, secret)

    if not payload then
        return nil, "Invalid token: " .. err
    end

    -- 检查是否过期
    if payload.exp and payload.exp < os.time() then
        return nil, "Token expired"
    end

    return payload
end

-- 使用示例
local result = login("admin", "password123")
if result.success then
    print("登录成功，Token:", result.token)

    -- 验证令牌
    local user, err = verify_token(result.token)
    if user then
        print("用户:", user.username, "角色:", user.role)
    else
        print("验证失败:", err)
    end
end
```

### API 授权中间件

```lua validate
local jwt = require "silly.security.jwt"

-- JWT 认证中间件
local function jwt_middleware(request_headers)
    local auth_header = request_headers["Authorization"]
    if not auth_header then
        return nil, "Missing Authorization header"
    end

    -- 提取 Bearer Token
    local token = auth_header:match("^Bearer%s+(.+)$")
    if not token then
        return nil, "Invalid Authorization format"
    end

    local secret = "api-secret-key"
    local payload, err = jwt.decode(token, secret)

    if not payload then
        return nil, "Invalid token: " .. err
    end

    -- 检查过期时间
    if payload.exp and payload.exp < os.time() then
        return nil, "Token expired"
    end

    -- 检查权限
    if payload.scope and not payload.scope:match("api:read") then
        return nil, "Insufficient permissions"
    end

    return payload
end

-- 使用中间件保护 API
local function protected_api_handler()
    local request_headers = {
        ["Authorization"] = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
    }

    local user, err = jwt_middleware(request_headers)
    if not user then
        print("访问被拒绝:", err)
        return {status = 401, body = {error = err}}
    end

    -- 处理授权请求
    return {status = 200, body = {data = "Protected resource", user = user.sub}}
end

local response = protected_api_handler()
print("状态码:", response.status)
```

### 令牌刷新机制

```lua validate
local jwt = require "silly.security.jwt"

local secret = "refresh-secret"
local access_token_ttl = 900   -- 15分钟
local refresh_token_ttl = 604800  -- 7天

-- 生成访问令牌和刷新令牌
local function generate_tokens(user_id)
    local now = os.time()

    -- 访问令牌（短期）
    local access_payload = {
        sub = user_id,
        type = "access",
        iat = now,
        exp = now + access_token_ttl
    }
    local access_token = jwt.encode(access_payload, secret, "HS256")

    -- 刷新令牌（长期）
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

-- 刷新访问令牌
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

    -- 生成新的访问令牌
    return generate_tokens(payload.sub)
end

-- 使用示例
local tokens = generate_tokens("user_12345")
print("访问令牌:", tokens.access_token)
print("刷新令牌:", tokens.refresh_token)

-- 15分钟后刷新
local new_tokens = refresh_access_token(tokens.refresh_token)
if new_tokens then
    print("新访问令牌:", new_tokens.access_token)
end
```

### 自定义声明和角色权限

```lua validate
local jwt = require "silly.security.jwt"

-- 生成带权限的令牌
local function create_permission_token(user_info)
    local payload = {
        sub = user_info.id,
        username = user_info.username,
        email = user_info.email,
        role = user_info.role,
        permissions = user_info.permissions,  -- 自定义权限列表
        org_id = user_info.org_id,           -- 自定义组织 ID
        iat = os.time(),
        exp = os.time() + 3600
    }

    local secret = "permission-secret"
    return jwt.encode(payload, secret, "HS512")  -- 使用更强的算法
end

-- 权限检查函数
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

-- 使用示例
local user = {
    id = "user_001",
    username = "developer",
    email = "dev@example.com",
    role = "developer",
    permissions = {"read:code", "write:code", "deploy:staging"},
    org_id = "org_001"
}

local token = create_permission_token(user)
print("权限令牌已生成")

-- 检查权限
local ok, err = has_permission(token, "deploy:staging")
if ok then
    print("用户有部署到 staging 的权限")
else
    print("权限不足:", err)
end
```

### 多算法支持示例

```lua validate
local jwt = require "silly.security.jwt"

-- 演示所有 HMAC 算法
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

-- 运行测试
local results = test_hmac_algorithms()
for alg, info in pairs(results) do
    print(string.format("%s: 令牌长度=%d, 验证=%s",
        alg, info.token_length, info.success and "成功" or "失败"))
end
```

### 错误处理最佳实践

```lua validate
local jwt = require "silly.security.jwt"

-- 完整的错误处理示例
local function safe_jwt_operation(token, secret)
    -- 解码令牌
    local payload, err = jwt.decode(token, secret)
    if not payload then
        -- 根据错误类型返回不同的 HTTP 状态码
        local error_map = {
            ["invalid token format"] = {code = 400, message = "令牌格式错误"},
            ["invalid signature"] = {code = 400, message = "签名无效"},
            ["signature verification failed"] = {code = 401, message = "签名验证失败"},
            ["unsupported algorithm"] = {code = 400, message = "不支持的算法"},
        }

        local error_info = error_map[err] or {code = 500, message = "未知错误"}
        return nil, error_info.code, error_info.message
    end

    -- 验证标准声明
    local now = os.time()

    -- 检查过期时间
    if payload.exp and payload.exp < now then
        return nil, 401, "令牌已过期"
    end

    -- 检查生效时间
    if payload.nbf and payload.nbf > now then
        return nil, 401, "令牌尚未生效"
    end

    -- 检查必需字段
    if not payload.sub then
        return nil, 400, "令牌缺少 subject 字段"
    end

    return payload, 200, "验证成功"
end

-- 使用示例
local test_token = jwt.encode({sub = "user123", exp = os.time() + 3600}, "secret", "HS256")
local payload, code, message = safe_jwt_operation(test_token, "secret")

if payload then
    print("验证成功，用户 ID:", payload.sub)
else
    print(string.format("验证失败 (HTTP %d): %s", code, message))
end
```

## 注意事项

### 安全性考虑

1. **密钥管理**
   - HMAC 密钥应足够长（建议至少 256 位）且随机
   - 私钥文件应妥善保管，避免泄露
   - 生产环境建议使用密钥管理系统（KMS）
   - 定期轮换密钥

2. **算法选择**
   - HMAC 算法适合简单场景，服务端自签自验
   - RSA/ECDSA 算法适合分布式系统，公钥可公开分发
   - 建议使用 HS256、RS256 或 ES256（更快更安全）

3. **令牌传输**
   - 始终通过 HTTPS 传输 JWT
   - 避免在 URL 中传递令牌（使用 HTTP Header）
   - 使用 `Authorization: Bearer <token>` 标准头部

4. **敏感信息**
   - JWT Payload 是 Base64 编码，不是加密
   - 不要在 Payload 中存储密码、密钥等敏感信息
   - 如需加密，使用 JWE（JSON Web Encryption）

### 过期时间处理

```lua
-- 推荐的过期时间设置
local token_ttl = {
    access = 15 * 60,        -- 访问令牌：15分钟
    refresh = 7 * 24 * 3600, -- 刷新令牌：7天
    remember = 30 * 24 * 3600 -- 记住我：30天
}

-- 总是验证过期时间
local function is_token_expired(payload)
    if not payload.exp then
        return false  -- 没有过期时间则认为不过期
    end
    return payload.exp < os.time()
end
```

### 性能优化

1. **Header 缓存**
   - 模块内部缓存了不同算法的 Header，避免重复编码
   - 相同算法的多次编码共享同一个 Header 字符串

2. **密钥复用**
   - 对于 RSA/ECDSA，复用 `pkey` 对象，避免重复加载
   - 可将公钥对象缓存在全局变量中

3. **批量验证**
   - 对于高并发场景，考虑使用连接池和缓存机制
   - 可缓存已验证令牌的结果（注意过期时间）

### 常见错误

| 错误信息 | 原因 | 解决方法 |
|---------|------|---------|
| `invalid token format` | 令牌格式不是三段式 | 检查令牌是否完整 |
| `invalid header/payload/signature` | Base64 解码失败或 JSON 解析失败 | 检查令牌是否被截断或篡改 |
| `unsupported algorithm: XXX` | 使用了不支持的算法 | 使用支持的 9 种算法之一 |
| `signature verification failed` | 签名验证失败 | 检查密钥是否正确，令牌是否被篡改 |

## 最佳实践

### 1. 使用环境变量管理密钥

```lua
-- 不要硬编码密钥
-- 错误示例：
-- local secret = "my-secret-key"

-- 正确示例：从环境变量读取
local secret = os.getenv("JWT_SECRET") or error("JWT_SECRET not set")
```

### 2. 实现令牌黑名单

```lua
-- 对于已登出或被撤销的令牌，维护黑名单
local blacklist = {}  -- 实际应用中使用 Redis 等

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

### 3. 使用 JTI 防止重放攻击

```lua
local silly = require "silly"
local jwt = require "silly.security.jwt"

local payload = {
    sub = "user123",
    jti = silly.genid(),  -- 唯一令牌 ID
    iat = os.time(),
    exp = os.time() + 3600
}
```

### 4. 实现令牌版本控制

```lua
-- 用户更改密码后使令牌失效
local payload = {
    sub = user_id,
    token_version = user.token_version,  -- 存储在数据库中
    exp = os.time() + 3600
}

-- 验证时检查版本
local function validate_token_version(payload, user)
    return payload.token_version == user.token_version
end
```

### 5. 多环境配置

```lua
local config = {
    development = {
        secret = "dev-secret",
        algorithm = "HS256",
        ttl = 86400  -- 24小时
    },
    production = {
        secret = os.getenv("JWT_SECRET"),
        algorithm = "RS256",  -- 生产环境使用非对称加密
        ttl = 3600  -- 1小时
    }
}

local env = os.getenv("ENV") or "development"
local jwt_config = config[env]
```

## 参见

- [silly.crypto.pkey](../crypto/pkey.md) - 公私钥加密（RSA/ECDSA 算法支持）
- [silly.crypto.hmac](../crypto/hmac.md) - HMAC 消息认证码（HS256/HS384/HS512 算法支持）
- [silly.encoding.base64](../encoding/base64.md) - Base64 编码（JWT 使用 URL-Safe Base64）
- [silly.encoding.json](../encoding/json.md) - JSON 编解码（Header 和 Payload 编码）
- [silly.net.http](../net/http.md) - HTTP 服务器（与 JWT 配合实现 API 认证）

## 标准参考

- [RFC 7519 - JSON Web Token (JWT)](https://tools.ietf.org/html/rfc7519)
- [RFC 7515 - JSON Web Signature (JWS)](https://tools.ietf.org/html/rfc7515)
- [RFC 7518 - JSON Web Algorithms (JWA)](https://tools.ietf.org/html/rfc7518)
