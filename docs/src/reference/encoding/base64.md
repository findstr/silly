---
title: silly.encoding.base64
icon: code
category:
  - API参考
tag:
  - 编码
  - Base64
  - 数据转换
---

# silly.encoding.base64

Base64 编码/解码模块，支持标准 Base64 和 URL-safe Base64 两种格式。

## 模块导入

```lua validate
local base64 = require "silly.encoding.base64"
```

## API函数

### base64.encode(data)
将二进制数据编码为 Base64 字符串（标准格式）。

- **参数**:
  - `data`: `string` - 要编码的原始数据（可以是二进制数据）
- **返回值**: `string` - Base64 编码后的字符串
- **编码特点**:
  - 使用标准 Base64 字典: `A-Z`, `a-z`, `0-9`, `+`, `/`
  - 使用 `=` 作为填充字符
  - 适用于一般数据传输和存储

**示例**:
```lua validate
local base64 = require "silly.encoding.base64"

local original = "Hello, World!"
local encoded = base64.encode(original)
print("Encoded:", encoded)  -- 输出: SGVsbG8sIFdvcmxkIQ==

-- 编码二进制数据
local binary = string.char(0x00, 0xFF, 0xAB, 0xCD)
local encoded_binary = base64.encode(binary)
print("Binary encoded:", encoded_binary)
```

### base64.decode(data)
将 Base64 字符串解码为原始数据。

- **参数**:
  - `data`: `string` - Base64 编码的字符串
- **返回值**: `string` - 解码后的原始数据
- **解码特点**:
  - 自动处理填充字符 `=`
  - 支持解码标准 Base64 和 URL-safe Base64
  - 忽略无效字符

**示例**:
```lua validate
local base64 = require "silly.encoding.base64"

local encoded = "SGVsbG8sIFdvcmxkIQ=="
local decoded = base64.decode(encoded)
print("Decoded:", decoded)  -- 输出: Hello, World!

-- 验证编码/解码的可逆性
local original = "Test data 测试数据"
local roundtrip = base64.decode(base64.encode(original))
assert(roundtrip == original)
```

### base64.urlsafe_encode(data)
将二进制数据编码为 URL-safe Base64 字符串。

- **参数**:
  - `data`: `string` - 要编码的原始数据
- **返回值**: `string` - URL-safe Base64 编码后的字符串
- **编码特点**:
  - 使用 URL-safe Base64 字典: `A-Z`, `a-z`, `0-9`, `-`, `_`
  - **不使用** `=` 填充字符
  - 安全用于 URL、文件名、Cookie 等

**示例**:
```lua validate
local base64 = require "silly.encoding.base64"

local data = "data >> url?"
local standard = base64.encode(data)
local urlsafe = base64.urlsafe_encode(data)

print("Standard:", standard)   -- ZGF0YSA+PiB1cmw/
print("URL-safe:", urlsafe)    -- ZGF0YSA+PiB1cmw_

-- URL-safe Base64 可以安全地用于 URL 参数
local token = base64.urlsafe_encode("user:12345:timestamp")
print("Token:", token)  -- 可以直接用于 URL: /api?token=xxx
```

### base64.urlsafe_decode(data)
将 URL-safe Base64 字符串解码为原始数据。

- **参数**:
  - `data`: `string` - URL-safe Base64 编码的字符串
- **返回值**: `string` - 解码后的原始数据
- **解码特点**:
  - 与 `base64.decode()` 共享相同的解码逻辑
  - 自动识别 `-` 和 `_` 字符
  - 不需要填充字符

**示例**:
```lua validate
local base64 = require "silly.encoding.base64"

local urlsafe_encoded = "SGVsbG8sIFdvcmxkIQ"  -- 无填充
local decoded = base64.urlsafe_decode(urlsafe_encoded)
print("Decoded:", decoded)  -- 输出: Hello, World!
```

## 使用示例

### 示例1：编码二进制数据

```lua validate
local base64 = require "silly.encoding.base64"

-- 编码图片或文件内容
local file = io.open("image.png", "rb")
local content = file:read("*a")
file:close()

local encoded = base64.encode(content)
print("Image size:", #content, "bytes")
print("Encoded size:", #encoded, "bytes")

-- 保存为文本文件
local out = io.open("image.txt", "w")
out:write(encoded)
out:close()
```

### 示例2：HTTP Basic Authentication

```lua validate
local base64 = require "silly.encoding.base64"

local username = "admin"
local password = "secret123"
local credentials = username .. ":" .. password
local auth_header = "Basic " .. base64.encode(credentials)

print("Authorization:", auth_header)
-- 输出: Authorization: Basic YWRtaW46c2VjcmV0MTIz
```

### 示例3：JWT Token（URL-safe Base64）

```lua validate
local base64 = require "silly.encoding.base64"
local json = require "silly.encoding.json"

-- JWT Header
local header = {
    alg = "HS256",
    typ = "JWT"
}

-- JWT Payload
local payload = {
    sub = "1234567890",
    name = "John Doe",
    iat = os.time()
}

-- 编码为 URL-safe Base64
local header_b64 = base64.urlsafe_encode(json.encode(header))
local payload_b64 = base64.urlsafe_encode(json.encode(payload))

print("Header:", header_b64)
print("Payload:", payload_b64)

-- JWT 格式: header.payload.signature
local jwt = header_b64 .. "." .. payload_b64 .. "." .. "signature"
print("JWT:", jwt)
```

### 示例4：数据加密后编码

```lua validate
local base64 = require "silly.encoding.base64"
local cipher = require "silly.crypto.cipher"

local key = "sixteen byte key"
local iv = "sixteen byte iv!"
local plaintext = "Secret message"

-- 加密
local encrypted = cipher.aes_128_cbc_encrypt(plaintext, key, iv)

-- 编码为 Base64 便于传输
local encoded = base64.encode(encrypted)
print("Encrypted (Base64):", encoded)

-- 解码并解密
local decoded = base64.decode(encoded)
local decrypted = cipher.aes_128_cbc_decrypt(decoded, key, iv)
print("Decrypted:", decrypted)
```

### 示例5：标准 vs URL-safe 对比

```lua validate
local base64 = require "silly.encoding.base64"

local test_cases = {
    "data?",
    "test>>data",
    "user/path",
}

for _, data in ipairs(test_cases) do
    local standard = base64.encode(data)
    local urlsafe = base64.urlsafe_encode(data)

    print(string.format("Original: %s", data))
    print(string.format("Standard: %s", standard))
    print(string.format("URL-safe: %s", urlsafe))
    print()
end

-- 输出:
-- Original: data?
-- Standard: ZGF0YT8=
-- URL-safe: ZGF0YT8
--
-- Original: test>>data
-- Standard: dGVzdD4+ZGF0YQ==
-- URL-safe: dGVzdD4-ZGF0YQ
```

## Base64 格式说明

### 标准 Base64

**字符集**: `A-Z`, `a-z`, `0-9`, `+`, `/`
**填充**: 使用 `=`
**输出长度**: 总是 4 的倍数

**编码规则**:
- 每 3 个字节（24位）编码为 4 个 Base64 字符（32位）
- 不足 3 字节时用 `=` 填充

**适用场景**:
- 邮件附件（MIME）
- XML/JSON 中的二进制数据
- 数据库存储

### URL-safe Base64

**字符集**: `A-Z`, `a-z`, `0-9`, `-`, `_`
**填充**: **不使用** `=`
**输出长度**: 可能不是 4 的倍数

**与标准 Base64 的区别**:
- `+` 替换为 `-`
- `/` 替换为 `_`
- 移除填充字符 `=`

**适用场景**:
- URL 参数
- 文件名
- Cookie
- JWT Token
- 任何需要在 URL 中使用的场景

## 编码大小计算

Base64 编码会使数据大小增加约 33%：

```
编码后大小 = ⌈原始大小 / 3⌉ × 4
```

**示例**:
- 原始: 12 字节 → Base64: 16 字节
- 原始: 100 字节 → Base64: 136 字节
- 原始: 1 KB → Base64: 1.37 KB

```lua validate
local base64 = require "silly.encoding.base64"

local function size_demo(size)
    local data = string.rep("x", size)
    local encoded = base64.encode(data)
    print(string.format("%d bytes → %d bytes (%.1f%% overhead)",
        size, #encoded, (#encoded / size - 1) * 100))
end

size_demo(10)    -- 10 bytes → 16 bytes (60.0% overhead)
size_demo(100)   -- 100 bytes → 136 bytes (36.0% overhead)
size_demo(1000)  -- 1000 bytes → 1336 bytes (33.6% overhead)
```

## 性能考虑

### 1. 批量编码

对大量小数据编码时，考虑先合并再编码：

```lua
-- ❌ 低效：多次编码
local parts = {}
for i = 1, 1000 do
    table.insert(parts, base64.encode("data" .. i))
end

-- ✅ 高效：合并后编码
local combined = table.concat(parts_raw)
local encoded = base64.encode(combined)
```

### 2. 流式处理

对于超大数据，考虑分块处理：

```lua validate
local base64 = require "silly.encoding.base64"

-- 模拟分块编码函数
local function encode_stream(read_func, write_func)
    while true do
        -- 每次读取 3 的倍数字节（避免填充问题）
        local chunk = read_func(3000)  -- 3000 bytes = 1000 * 3
        if not chunk or #chunk == 0 then
            break
        end

        local encoded = base64.encode(chunk)
        write_func(encoded)
    end
end
```

## 注意事项

::: warning 字符集安全
标准 Base64 包含 `+` 和 `/` 字符，在 URL 中使用时需要进行 URL 编码。建议直接使用 `urlsafe_encode()`。
:::

::: tip 自动兼容
`base64.decode()` 和 `base64.urlsafe_decode()` 使用相同的解码逻辑，可以自动识别标准和 URL-safe 格式。
:::

::: warning 填充字符
URL-safe Base64 不包含填充字符 `=`。如果你需要与其他系统互操作，确认对方是否支持无填充格式。
:::

## 常见错误

### 1. 混淆标准和 URL-safe 格式

```lua
-- ❌ 错误：在 URL 中使用标准 Base64
local token = base64.encode("user:123")
local url = "/api?token=" .. token  -- 可能包含 +/= 字符

-- ✅ 正确：使用 URL-safe Base64
local token = base64.urlsafe_encode("user:123")
local url = "/api?token=" .. token
```

### 2. 忘记编码后的数据是二进制安全的

```lua
-- ✅ Base64 编码后是纯文本，可以安全地存储和传输
local encrypted = cipher.encrypt(data)  -- 二进制数据
local safe = base64.encode(encrypted)   -- 转换为文本
```

## 实际应用场景

### 1. 邮件附件（MIME）

```lua
local base64 = require "silly.encoding.base64"

local attachment = io.open("document.pdf", "rb"):read("*a")
local encoded = base64.encode(attachment)

-- MIME 格式：每76个字符换行
local mime = {}
for i = 1, #encoded, 76 do
    table.insert(mime, encoded:sub(i, i + 75))
end
local mime_content = table.concat(mime, "\r\n")
```

### 2. Data URL

```lua
local base64 = require "silly.encoding.base64"

local image = io.open("logo.png", "rb"):read("*a")
local data_url = "data:image/png;base64," .. base64.encode(image)

-- 可以直接在 HTML 中使用
-- <img src="data:image/png;base64,iVBORw0...">
```

### 3. 配置文件中的二进制数据

```lua
local base64 = require "silly.encoding.base64"
local json = require "silly.encoding.json"

local config = {
    server = {
        host = "localhost",
        port = 8080,
        tls_cert = base64.encode(cert_data),  -- 证书编码为文本
        tls_key = base64.encode(key_data),
    }
}

-- 保存为 JSON
local config_json = json.encode(config)
```

## 参见

- [silly.encoding.json](./json.md) - JSON 编码/解码
- [silly.crypto.cipher](../crypto/cipher.md) - 加密算法（常与 Base64 配合使用）
- [silly.crypto.hash](../crypto/hash.md) - 哈希算法
- [silly.security.jwt](../security/jwt.md) - JWT Token（使用 URL-safe Base64）
