---
title: hmac
icon: shield-keyhole
category:
  - API参考
tag:
  - 密码学
  - HMAC
  - 消息认证
  - 防篡改
---

# hmac (`silly.crypto.hmac`)

`silly.crypto.hmac` 模块提供了基于哈希的消息认证码 (HMAC) 功能。HMAC 是一种使用密钥和哈希函数来生成消息认证码的算法,广泛用于验证消息的完整性和真实性。

要使用此模块,您必须首先 `require` 它:
```lua
local hmac = require "silly.crypto.hmac"
```

::: tip 编译要求
此模块需要在编译时启用 OpenSSL 支持。请使用 `make OPENSSL=ON` 编译 Silly 框架。
:::

---

## 核心概念

### 什么是 HMAC?

HMAC (Hash-based Message Authentication Code, 基于哈希的消息认证码) 是一种使用密钥和哈希函数来验证消息完整性和真实性的算法。它具有以下特性:

- **密钥保护**: 使用密钥生成认证码,只有持有相同密钥的通信双方才能验证
- **防篡改**: 任何对消息的修改都会导致 HMAC 值变化
- **单向性**: 无法从 HMAC 值推导出原始消息或密钥
- **确定性**: 相同的密钥和消息始终生成相同的 HMAC 值

### HMAC vs Hash

| 特性 | Hash (哈希) | HMAC (消息认证码) |
|-----|-----------|-----------------|
| **输入** | 只需要消息 | 需要密钥 + 消息 |
| **用途** | 数据指纹、去重 | 消息认证、防篡改 |
| **安全性** | 可被任何人计算 | 只有持有密钥者可验证 |
| **典型应用** | 文件校验、数据去重 | API 签名、JWT、Cookie 签名 |

### 工作原理

HMAC 的计算过程:
```
HMAC(K, m) = H((K' ⊕ opad) || H((K' ⊕ ipad) || m))
```

其中:
- `K`: 密钥
- `m`: 消息
- `H`: 哈希函数 (如 SHA-256)
- `K'`: 填充后的密钥
- `opad` 和 `ipad`: 固定的填充值
- `||`: 字符串连接
- `⊕`: 异或运算

---

## 完整示例

```lua validate
local hmac = require "silly.crypto.hmac"

-- 1. 基本 HMAC 计算
local key = "my-secret-key"
local message = "Hello, World!"
local mac = hmac.digest(key, message, "sha256")
print(string.format("HMAC-SHA256: %s", string.gsub(mac, ".", function(c)
    return string.format("%02x", string.byte(c))
end)))

-- 2. API 请求签名
local function sign_api_request(secret, method, path, body)
    local data = method .. path .. body
    return hmac.digest(secret, data, "sha256")
end

local api_secret = "api-secret-12345"
local signature = sign_api_request(api_secret, "POST", "/api/users", '{"name":"Alice"}')
print("API 签名生成成功")

-- 3. 消息验证
local function verify_message(key, message, expected_mac)
    local computed_mac = hmac.digest(key, message, "sha256")
    return computed_mac == expected_mac
end

local original_message = "Important data"
local mac_value = hmac.digest("verification-key", original_message, "sha256")
local is_valid = verify_message("verification-key", original_message, mac_value)
print("消息验证结果:", is_valid and "通过" or "失败")

-- 4. 不同哈希算法
local key = "test-key"
local data = "test data"
local sha1_mac = hmac.digest(key, data, "sha1")
local sha256_mac = hmac.digest(key, data, "sha256")
local sha512_mac = hmac.digest(key, data, "sha512")
print("SHA-1 HMAC 长度:", #sha1_mac, "字节")
print("SHA-256 HMAC 长度:", #sha256_mac, "字节")
print("SHA-512 HMAC 长度:", #sha512_mac, "字节")

-- 5. Cookie 签名
local function sign_cookie(secret, cookie_value)
    local timestamp = tostring(os.time())
    local data = cookie_value .. "|" .. timestamp
    local signature = hmac.digest(secret, data, "sha256")
    -- 转换为十六进制
    local hex_sig = string.gsub(signature, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)
    return data .. "|" .. hex_sig
end

local cookie_secret = "cookie-secret-xyz"
local signed_cookie = sign_cookie(cookie_secret, "user_id=12345")
print("签名 Cookie:", signed_cookie)

-- 6. 二进制数据处理
local binary_key = string.char(0x01, 0x02, 0x03, 0x04)
local binary_msg = string.char(0xFF, 0xFE, 0xFD, 0xFC)
local binary_mac = hmac.digest(binary_key, binary_msg, "sha256")
print("二进制 HMAC 长度:", #binary_mac, "字节")

-- 7. 空数据处理
local empty_msg_mac = hmac.digest("key", "", "sha256")
local empty_key_mac = hmac.digest("", "message", "sha256")
print("空消息 HMAC 计算成功")
print("空密钥 HMAC 计算成功")
```

---

## API 参考

### `hmac.digest(key, data, algorithm)`

计算消息的 HMAC 值。

**参数**:
- `key` (字符串): 密钥。可以是任意长度的字符串,支持二进制数据。
- `data` (字符串): 要计算 HMAC 的消息数据。支持二进制数据。
- `algorithm` (字符串): 哈希算法名称。

**返回值**:
- 返回计算出的 HMAC 值,以二进制字符串形式返回。
- 如果计算失败,抛出 Lua 错误。

**支持的哈希算法**:
- `"md5"`: MD5 (不推荐用于安全场景,16 字节输出)
- `"sha1"`: SHA-1 (不推荐用于安全场景,20 字节输出)
- `"sha224"`: SHA-224 (28 字节输出)
- `"sha256"`: SHA-256 (推荐,32 字节输出)
- `"sha384"`: SHA-384 (48 字节输出)
- `"sha512"`: SHA-512 (64 字节输出)
- `"sha3-224"`, `"sha3-256"`, `"sha3-384"`, `"sha3-512"`: SHA-3 系列
- `"sm3"`: 国密 SM3 算法 (32 字节输出)

**示例**:
```lua validate
local hmac = require "silly.crypto.hmac"

-- 基本使用
local key = "my-secret-key"
local message = "Hello, World!"
local mac = hmac.digest(key, message, "sha256")
print("HMAC 长度:", #mac, "字节")

-- 转换为十六进制显示
local function to_hex(str)
    return (string.gsub(str, ".", function(c)
        return string.format("%02x", string.byte(c))
    end))
end
print("HMAC (hex):", to_hex(mac))

-- 不同算法对比
local algorithms = {"sha1", "sha256", "sha512"}
for _, alg in ipairs(algorithms) do
    local result = hmac.digest("key", "data", alg)
    print(string.format("%s: %d 字节", alg, #result))
end

-- 二进制安全
local binary_key = string.char(0, 255, 128, 127)
local binary_msg = string.char(1, 2, 3, 4)
local binary_mac = hmac.digest(binary_key, binary_msg, "sha256")
print("二进制数据 HMAC 计算成功")
```

---

## 使用示例

### API 签名验证

Web API 中最常用的 HMAC 应用场景:

```lua validate
local hmac = require "silly.crypto.hmac"

-- API 签名工具
local api_signer = {}

-- 生成签名
function api_signer.sign(secret, method, path, body, timestamp)
    -- 构建签名字符串
    local sign_string = string.format("%s\n%s\n%s\n%s",
        method, path, body or "", timestamp)

    -- 计算 HMAC
    local signature = hmac.digest(secret, sign_string, "sha256")

    -- 转换为 Base64 编码 (使用简单的十六进制代替)
    return string.gsub(signature, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)
end

-- 验证签名
function api_signer.verify(secret, method, path, body, timestamp, signature)
    local expected = api_signer.sign(secret, method, path, body, timestamp)
    return expected == signature
end

-- 使用示例
local api_secret = "my-api-secret-key-123"
local timestamp = "1634567890"

-- 客户端: 生成签名
local method = "POST"
local path = "/api/v1/users"
local body = '{"name":"Alice","age":30}'
local signature = api_signer.sign(api_secret, method, path, body, timestamp)
print("生成的签名:", signature:sub(1, 32) .. "...")

-- 服务端: 验证签名
local is_valid = api_signer.verify(api_secret, method, path, body, timestamp, signature)
print("签名验证:", is_valid and "通过" or "失败")

-- 篡改检测
local tampered_body = '{"name":"Bob","age":30}'
local is_tampered = api_signer.verify(api_secret, method, path, tampered_body, timestamp, signature)
print("篡改数据验证:", is_tampered and "通过" or "失败")
```

### JWT Token 签名

实现简单的 JWT HMAC 签名:

```lua validate
local hmac = require "silly.crypto.hmac"

local jwt = {}

-- Base64URL 编码 (简化版)
local function base64url_encode(str)
    local b64 = ""
    -- 简化实现:转换为十六进制
    for i = 1, #str do
        b64 = b64 .. string.format("%02x", string.byte(str, i))
    end
    return b64
end

-- 创建 JWT
function jwt.sign(payload, secret)
    -- Header (简化)
    local header = '{"alg":"HS256","typ":"JWT"}'
    local header_b64 = base64url_encode(header)

    -- Payload
    local payload_json = string.format('{"sub":"%s","exp":%d}',
        payload.sub or "", payload.exp or 0)
    local payload_b64 = base64url_encode(payload_json)

    -- 签名部分
    local sign_input = header_b64 .. "." .. payload_b64
    local signature = hmac.digest(secret, sign_input, "sha256")
    local signature_b64 = base64url_encode(signature)

    -- 组合 JWT
    return sign_input .. "." .. signature_b64
end

-- 验证 JWT
function jwt.verify(token, secret)
    local parts = {}
    for part in string.gmatch(token, "[^.]+") do
        table.insert(parts, part)
    end

    if #parts ~= 3 then
        return false, "invalid token format"
    end

    -- 验证签名
    local sign_input = parts[1] .. "." .. parts[2]
    local expected_sig = hmac.digest(secret, sign_input, "sha256")
    local expected_sig_b64 = base64url_encode(expected_sig)

    return parts[3] == expected_sig_b64, "signature verified"
end

-- 使用示例
local jwt_secret = "jwt-secret-key-xyz"
local payload = {
    sub = "user123",
    exp = os.time() + 3600
}

-- 签发 Token
local token = jwt.sign(payload, jwt_secret)
print("JWT Token 长度:", #token)

-- 验证 Token
local valid, msg = jwt.verify(token, jwt_secret)
print("Token 验证:", valid and "成功" or "失败")

-- 使用错误密钥验证
local invalid, err = jwt.verify(token, "wrong-secret")
print("错误密钥验证:", invalid and "成功" or "失败")
```

### Webhook 签名

验证 Webhook 回调的真实性:

```lua validate
local hmac = require "silly.crypto.hmac"

local webhook = {}

-- 计算 Webhook 签名
function webhook.sign(secret, payload, timestamp)
    local signed_payload = timestamp .. "." .. payload
    local signature = hmac.digest(secret, signed_payload, "sha256")

    -- 转换为十六进制
    return string.gsub(signature, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)
end

-- 验证 Webhook 签名
function webhook.verify(secret, payload, timestamp, received_signature)
    local expected = webhook.sign(secret, payload, timestamp)

    -- 防止时序攻击:使用恒定时间比较
    if #expected ~= #received_signature then
        return false
    end

    local result = 0
    for i = 1, #expected do
        local a = string.byte(expected, i)
        local b = string.byte(received_signature, i)
        result = result | (a ~ b)
    end

    return result == 0
end

-- 使用示例
local webhook_secret = "whsec_abcdef123456"

-- 模拟收到 Webhook
local timestamp = tostring(os.time())
local payload = '{"event":"payment.success","amount":100}'

-- 发送方:生成签名
local signature = webhook.sign(webhook_secret, payload, timestamp)
print("Webhook 签名:", signature:sub(1, 32) .. "...")

-- 接收方:验证签名
local is_valid = webhook.verify(webhook_secret, payload, timestamp, signature)
print("Webhook 验证:", is_valid and "通过" or "失败")

-- 防重放攻击:检查时间戳
local current_time = os.time()
local webhook_time = tonumber(timestamp)
local time_diff = math.abs(current_time - webhook_time)
if time_diff > 300 then -- 5分钟有效期
    print("警告: Webhook 时间戳过期")
else
    print("时间戳验证: 通过")
end
```

### 密码存储 HMAC

使用 HMAC 增强密码存储安全性:

```lua validate
local hmac = require "silly.crypto.hmac"

local password_manager = {}

-- 生成随机盐 (简化版)
local function generate_salt()
    local salt = ""
    for i = 1, 16 do
        salt = salt .. string.char(math.random(0, 255))
    end
    return salt
end

-- 转换为十六进制
local function to_hex(str)
    return string.gsub(str, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)
end

-- 从十六进制转换
local function from_hex(hex)
    return string.gsub(hex, "..", function(cc)
        return string.char(tonumber(cc, 16))
    end)
end

-- 哈希密码
function password_manager.hash_password(password, server_secret)
    local salt = generate_salt()
    local hash = hmac.digest(server_secret, password .. to_hex(salt), "sha256")

    -- 返回盐和哈希值
    return {
        salt = to_hex(salt),
        hash = to_hex(hash)
    }
end

-- 验证密码
function password_manager.verify_password(password, server_secret, stored_salt, stored_hash)
    local hash = hmac.digest(server_secret, password .. stored_salt, "sha256")
    local computed_hash = to_hex(hash)

    -- 恒定时间比较
    if #computed_hash ~= #stored_hash then
        return false
    end

    local result = 0
    for i = 1, #computed_hash do
        local a = string.byte(computed_hash, i)
        local b = string.byte(stored_hash, i)
        result = result | (a ~ b)
    end

    return result == 0
end

-- 使用示例
local server_secret = "server-master-secret-key"
local user_password = "MySecurePassword123!"

-- 注册:存储密码
local stored = password_manager.hash_password(user_password, server_secret)
print("密码已哈希")
print("盐:", stored.salt:sub(1, 16) .. "...")
print("哈希:", stored.hash:sub(1, 16) .. "...")

-- 登录:验证密码
local login_success = password_manager.verify_password(
    user_password,
    server_secret,
    stored.salt,
    stored.hash
)
print("密码验证:", login_success and "成功" or "失败")

-- 错误密码
local wrong_attempt = password_manager.verify_password(
    "WrongPassword",
    server_secret,
    stored.salt,
    stored.hash
)
print("错误密码验证:", wrong_attempt and "成功" or "失败")
```

### 会话 Cookie 签名

防止 Cookie 篡改:

```lua validate
local hmac = require "silly.crypto.hmac"

local session = {}

-- 签名 Cookie 值
function session.sign_cookie(secret, name, value, timestamp)
    local cookie_data = name .. "=" .. value .. "&t=" .. timestamp
    local signature = hmac.digest(secret, cookie_data, "sha256")

    -- 转换为十六进制
    local sig_hex = string.gsub(signature, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)

    return cookie_data .. "&sig=" .. sig_hex
end

-- 验证并解析 Cookie
function session.verify_cookie(secret, cookie_string)
    -- 提取签名
    local sig_start = string.find(cookie_string, "&sig=")
    if not sig_start then
        return nil, "no signature"
    end

    local data = string.sub(cookie_string, 1, sig_start - 1)
    local received_sig = string.sub(cookie_string, sig_start + 5)

    -- 验证签名
    local expected_sig = hmac.digest(secret, data, "sha256")
    local expected_hex = string.gsub(expected_sig, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)

    if expected_hex ~= received_sig then
        return nil, "invalid signature"
    end

    -- 解析 Cookie 数据
    local name, value, timestamp
    for kv in string.gmatch(data, "[^&]+") do
        local k, v = string.match(kv, "([^=]+)=([^=]+)")
        if k == "t" then
            timestamp = tonumber(v)
        else
            name, value = k, v
        end
    end

    -- 检查过期时间
    if timestamp and os.time() - timestamp > 3600 then
        return nil, "cookie expired"
    end

    return {name = name, value = value, timestamp = timestamp}
end

-- 使用示例
local cookie_secret = "cookie-signing-secret"
local timestamp = tostring(os.time())

-- 设置 Cookie
local cookie = session.sign_cookie(cookie_secret, "session_id", "abc123def456", timestamp)
print("签名 Cookie:", cookie:sub(1, 50) .. "...")

-- 验证 Cookie
local parsed, err = session.verify_cookie(cookie_secret, cookie)
if parsed then
    print("Cookie 验证成功")
    print("名称:", parsed.name)
    print("值:", parsed.value)
else
    print("Cookie 验证失败:", err)
end

-- 篡改 Cookie 测试
local tampered = string.gsub(cookie, "abc123", "xyz789")
local invalid, err2 = session.verify_cookie(cookie_secret, tampered)
if not invalid then
    print("篡改检测:", err2)
end
```

### 文件完整性验证

验证文件是否被篡改:

```lua validate
local hmac = require "silly.crypto.hmac"

local file_integrity = {}

-- 计算文件 HMAC (模拟)
function file_integrity.compute_hmac(secret, file_content)
    return hmac.digest(secret, file_content, "sha256")
end

-- 创建完整性清单
function file_integrity.create_manifest(secret, files)
    local manifest = {}

    for filename, content in pairs(files) do
        local file_hmac = file_integrity.compute_hmac(secret, content)

        -- 转换为十六进制
        manifest[filename] = string.gsub(file_hmac, ".", function(c)
            return string.format("%02x", string.byte(c))
        end)
    end

    return manifest
end

-- 验证文件完整性
function file_integrity.verify_file(secret, filename, content, expected_hmac)
    local computed = file_integrity.compute_hmac(secret, content)
    local computed_hex = string.gsub(computed, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)

    return computed_hex == expected_hmac
end

-- 使用示例
local integrity_secret = "file-integrity-key"

-- 模拟文件系统
local files = {
    ["config.lua"] = 'return {port = 8080, host = "0.0.0.0"}',
    ["app.lua"] = 'print("Hello, World!")',
    ["data.txt"] = "Important data content"
}

-- 生成完整性清单
local manifest = file_integrity.create_manifest(integrity_secret, files)
print("文件完整性清单:")
for filename, hmac_value in pairs(manifest) do
    print(string.format("  %s: %s...", filename, hmac_value:sub(1, 32)))
end

-- 验证文件
for filename, content in pairs(files) do
    local is_valid = file_integrity.verify_file(
        integrity_secret,
        filename,
        content,
        manifest[filename]
    )
    print(string.format("%s: %s", filename, is_valid and "完整" or "已篡改"))
end

-- 模拟文件篡改
local tampered_content = "Tampered data content"
local is_tampered = file_integrity.verify_file(
    integrity_secret,
    "data.txt",
    tampered_content,
    manifest["data.txt"]
)
print(string.format("篡改文件检测: %s", is_tampered and "未检测到" or "检测到篡改"))
```

### 消息队列签名

确保消息队列中消息的真实性:

```lua validate
local hmac = require "silly.crypto.hmac"

local mq_signer = {}

-- 签名消息
function mq_signer.sign_message(secret, topic, payload, producer_id)
    local timestamp = tostring(os.time())
    local nonce = tostring(math.random(100000, 999999))

    -- 构建签名数据
    local sign_data = string.format("%s|%s|%s|%s|%s",
        topic, producer_id, timestamp, nonce, payload)

    local signature = hmac.digest(secret, sign_data, "sha256")
    local sig_hex = string.gsub(signature, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)

    return {
        topic = topic,
        payload = payload,
        producer_id = producer_id,
        timestamp = timestamp,
        nonce = nonce,
        signature = sig_hex
    }
end

-- 验证消息
function mq_signer.verify_message(secret, message)
    -- 重构签名数据
    local sign_data = string.format("%s|%s|%s|%s|%s",
        message.topic,
        message.producer_id,
        message.timestamp,
        message.nonce,
        message.payload)

    local expected = hmac.digest(secret, sign_data, "sha256")
    local expected_hex = string.gsub(expected, ".", function(c)
        return string.format("%02x", string.byte(c))
    end)

    -- 验证签名
    if expected_hex ~= message.signature then
        return false, "invalid signature"
    end

    -- 验证时间戳 (防重放)
    local msg_time = tonumber(message.timestamp)
    local current_time = os.time()
    if math.abs(current_time - msg_time) > 60 then
        return false, "message expired"
    end

    return true, "verified"
end

-- 使用示例
local mq_secret = "message-queue-secret"

-- 生产者:发送消息
local message = mq_signer.sign_message(
    mq_secret,
    "user.events",
    '{"event":"user.login","user_id":12345}',
    "producer-001"
)
print("消息已签名")
print("主题:", message.topic)
print("签名:", message.signature:sub(1, 32) .. "...")

-- 消费者:验证消息
local valid, msg = mq_signer.verify_message(mq_secret, message)
if valid then
    print("消息验证: 通过")
    print("消费消息:", message.payload)
else
    print("消息验证: 失败 -", msg)
end

-- 篡改检测
local tampered_message = {
    topic = message.topic,
    payload = '{"event":"user.logout","user_id":12345}',  -- 篡改内容
    producer_id = message.producer_id,
    timestamp = message.timestamp,
    nonce = message.nonce,
    signature = message.signature
}
local invalid, err = mq_signer.verify_message(mq_secret, tampered_message)
print("篡改消息验证:", invalid and "通过" or "失败 - " .. err)
```

---

## 注意事项

### 1. 密钥安全

密钥是 HMAC 安全性的核心:

- **密钥长度**: 推荐使用至少 32 字节 (256 位) 的随机密钥
- **密钥存储**: 不要在代码中硬编码密钥,使用环境变量或密钥管理服务
- **密钥轮换**: 定期更换密钥,特别是怀疑泄露时
- **密钥分离**: 不同用途使用不同的密钥 (API、Cookie、文件等)

```lua
-- ❌ 不好的做法
local key = "123456"  -- 太弱

-- ✅ 好的做法
local key = os.getenv("HMAC_SECRET_KEY")  -- 从环境变量读取
if not key or #key < 32 then
    error("HMAC secret key must be at least 32 bytes")
end
```

### 2. 算法选择

不同场景选择合适的哈希算法:

| 算法 | 安全性 | 性能 | 推荐场景 |
|-----|-------|------|---------|
| MD5 | ❌ 弱 | 快 | 不推荐 |
| SHA-1 | ⚠️ 已弃用 | 较快 | 不推荐用于新项目 |
| SHA-256 | ✅ 强 | 中等 | **推荐** (通用场景) |
| SHA-512 | ✅ 很强 | 较慢 | 高安全要求场景 |
| SM3 | ✅ 强 | 中等 | 国密合规场景 |

### 3. 时序攻击防护

验证 HMAC 时使用恒定时间比较:

```lua
-- ❌ 不安全:早期退出会泄露信息
local function unsafe_compare(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if string.byte(a, i) ~= string.byte(b, i) then
            return false  -- 早期退出!
        end
    end
    return true
end

-- ✅ 安全:恒定时间比较
local function safe_compare(a, b)
    if #a ~= #b then return false end
    local result = 0
    for i = 1, #a do
        result = result | (string.byte(a, i) ~ string.byte(b, i))
    end
    return result == 0
end
```

### 4. 与 Hash 的区别

HMAC 和 Hash 不可混用:

```lua
local hmac = require "silly.crypto.hmac"
local hash = require "silly.crypto.hash"

local key = "secret"
local data = "message"

-- 这两个结果完全不同!
local hmac_result = hmac.digest(key, data, "sha256")
local hash_result = hash.digest(data, "sha256")

-- ❌ 错误:用 Hash 代替 HMAC
-- 任何人都可以计算 Hash,无法验证消息来源

-- ✅ 正确:使用 HMAC 进行身份验证
-- 只有持有密钥的人可以生成有效的 HMAC
```

### 5. 二进制安全

HMAC 结果是二进制数据:

```lua
local hmac = require "silly.crypto.hmac"

local mac = hmac.digest("key", "data", "sha256")

-- ❌ 不要直接打印或存储二进制数据
-- print(mac)  -- 可能产生不可见字符

-- ✅ 转换为十六进制或 Base64
local hex = string.gsub(mac, ".", function(c)
    return string.format("%02x", string.byte(c))
end)
print("HMAC (hex):", hex)
```

### 6. 性能考虑

HMAC 计算有性能开销:

- **缓存结果**: 对于静态数据,缓存 HMAC 值
- **批量计算**: 避免在循环中重复计算相同数据的 HMAC
- **算法选择**: SHA-256 通常是性能和安全的最佳平衡点

### 7. 防重放攻击

仅验证 HMAC 不足以防止重放攻击:

```lua
-- ✅ 包含时间戳或 nonce
local function sign_with_timestamp(key, data)
    local timestamp = tostring(os.time())
    local sign_data = data .. "|" .. timestamp
    local mac = hmac.digest(key, sign_data, "sha256")
    return mac, timestamp
end

-- 验证时检查时间戳
local function verify_with_timestamp(key, data, timestamp, mac)
    local sign_data = data .. "|" .. timestamp
    local expected = hmac.digest(key, sign_data, "sha256")

    if expected ~= mac then
        return false, "invalid signature"
    end

    local current_time = os.time()
    local msg_time = tonumber(timestamp)
    if math.abs(current_time - msg_time) > 300 then  -- 5分钟有效期
        return false, "expired"
    end

    return true
end
```

### 8. 空密钥和空数据

虽然支持空密钥和空数据,但不推荐:

```lua
-- ⚠️ 虽然可以工作,但不推荐
local empty_key_mac = hmac.digest("", "message", "sha256")
local empty_data_mac = hmac.digest("key", "", "sha256")

-- ✅ 始终使用强密钥和非空数据
local strong_mac = hmac.digest("strong-secret-key", "message", "sha256")
```

---

## 参见

- **[silly.crypto.hash](./hash.md)**: 哈希函数 (用于数据指纹,不用于认证)
- **[silly.crypto.cipher](./cipher.md)**: 对称加密算法 (用于保密性,而非完整性)
- **[silly.security.jwt](../security/jwt.md)**: JWT Token 实现 (内部使用 HMAC 签名)
- **[silly.net.http](../net/http.md)**: HTTP 服务器 (常用于 API 签名验证)

---

## 标准参考

- **RFC 2104**: HMAC: Keyed-Hashing for Message Authentication
- **RFC 4231**: Identifiers and Test Vectors for HMAC-SHA-224, HMAC-SHA-256, HMAC-SHA-384, and HMAC-SHA-512
- **FIPS 198-1**: The Keyed-Hash Message Authentication Code (HMAC)

---

## 安全建议

1. **使用 SHA-256 或更强**: 避免使用 MD5 和 SHA-1
2. **密钥长度**: 至少 32 字节随机密钥
3. **恒定时间比较**: 防止时序攻击
4. **包含时间戳**: 防止重放攻击
5. **密钥隔离**: 不同用途使用不同密钥
6. **定期轮换**: 定期更换密钥
7. **安全存储**: 不要硬编码密钥
8. **HTTPS 传输**: 签名值应通过加密通道传输
