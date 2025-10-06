---
title: Cipher（对称加密）
icon: lock
category:
  - API 参考
tag:
  - 加密
  - 对称加密
  - AES
  - DES
  - GCM
---

# silly.crypto.cipher

对称加密模块提供了基于 OpenSSL 的高性能加密和解密功能，支持多种加密算法（AES、DES、ChaCha20 等）和加密模式（CBC、GCM、CTR 等）。对称加密使用相同的密钥进行加密和解密，适合大量数据的快速加密场景。

## 概述

`silly.crypto.cipher` 模块是对 OpenSSL EVP Cipher 接口的 Lua 封装，提供了：

- **多种算法支持**：AES-128/192/256、DES、3DES、ChaCha20 等
- **多种加密模式**：CBC、GCM、CTR、ECB、CFB、OFB、CCM 等
- **流式处理**：支持分块加密大文件，避免内存占用过大
- **AEAD 支持**：支持 GCM/CCM 模式的认证加密，提供数据完整性保护
- **灵活配置**：可自定义填充模式、初始化向量（IV）、附加认证数据（AAD）

对称加密的核心特点：
- **速度快**：比非对称加密快 100-1000 倍
- **密钥管理**：加密和解密使用相同密钥，密钥需要安全传输
- **适用场景**：数据存储加密、会话密钥加密、大文件加密

## 模块导入

```lua validate
local cipher = require "silly.crypto.cipher"
```

## 核心概念

### 加密算法

对称加密算法通常由三部分组成：`算法名-密钥长度-模式`

**常用算法示例**：
- `aes-128-cbc`：AES 算法，128 位密钥，CBC 模式
- `aes-256-gcm`：AES 算法，256 位密钥，GCM 模式（认证加密）
- `chacha20-poly1305`：ChaCha20 流加密算法，带 Poly1305 认证

**AES 密钥长度**：
- AES-128：16 字节密钥（128 位）
- AES-192：24 字节密钥（192 位）
- AES-256：32 字节密钥（256 位）

### 加密模式

不同的加密模式决定了如何处理数据块和初始化向量：

| 模式 | 全称 | 特点 | IV 需求 | 填充 |
|------|------|------|---------|------|
| ECB | Electronic Codebook | 最简单，不安全（不推荐） | 不需要 | 需要 |
| CBC | Cipher Block Chaining | 块链接，常用模式 | 需要 | 需要 |
| CTR | Counter | 计数器模式，可并行 | 需要 | 不需要 |
| GCM | Galois/Counter Mode | 认证加密（AEAD），推荐 | 需要 | 不需要 |
| CCM | Counter with CBC-MAC | 认证加密（AEAD） | 需要 | 不需要 |
| CFB | Cipher Feedback | 流加密模式 | 需要 | 不需要 |
| OFB | Output Feedback | 流加密模式 | 需要 | 不需要 |

**推荐使用**：
- **数据加密**：AES-256-GCM（安全性高，带认证）
- **性能优先**：AES-128-CTR（速度快）
- **兼容性优先**：AES-128-CBC（广泛支持）

### 初始化向量（IV）

初始化向量（Initialization Vector）是加密过程中使用的随机数，用于增强安全性：

- **长度要求**：通常为加密算法的块大小（AES 为 16 字节）
- **随机性要求**：每次加密应使用不同的随机 IV
- **传输方式**：IV 可以公开传输（通常附加在密文前）
- **GCM 模式**：IV 长度通常为 12 字节（96 位），性能最优

**生成随机 IV**：
```lua
local random = require "silly.crypto.random"
local iv = random.random(16)  -- AES 的 IV 长度为 16 字节
```

### 填充（Padding）

块加密算法（如 AES-CBC）要求数据长度必须是块大小的整数倍，因此需要填充：

- **PKCS7 填充**（默认）：最常用，自动填充到块大小
  - 例如：数据长度为 13 字节，块大小 16 字节，填充 3 个字节 `\x03\x03\x03`
  - 如果数据恰好是块大小的整数倍，则填充一个完整的块
- **无填充**：适用于流加密模式（CTR、GCM）或手动填充的场景

### 认证加密（AEAD）

AEAD（Authenticated Encryption with Associated Data）模式提供加密和认证双重保护：

- **GCM/CCM 模式**：加密数据并生成认证标签（Tag）
- **认证标签**：用于验证密文完整性，防止篡改
- **附加认证数据（AAD）**：不加密但需要认证的数据（如协议头）

## API 参考

### cipher.encryptor(algorithm, key, iv)

创建加密器对象。

- **参数**:
  - `algorithm`: `string` - 加密算法名称，如 `"aes-128-cbc"`, `"aes-256-gcm"`
    - 支持的算法取决于 OpenSSL 版本，常见算法包括：
      - AES: `aes-128-ecb`, `aes-128-cbc`, `aes-128-ctr`, `aes-128-gcm`, `aes-256-cbc`, `aes-256-gcm` 等
      - DES: `des-ecb`, `des-cbc`, `des3-cbc` 等
      - ChaCha20: `chacha20`, `chacha20-poly1305`
  - `key`: `string` - 加密密钥，长度必须与算法要求一致
    - AES-128: 16 字节
    - AES-192: 24 字节
    - AES-256: 32 字节
  - `iv`: `string|nil` - 初始化向量（可选）
    - ECB 模式不需要 IV（传 `nil`）
    - CBC/CTR/GCM 等模式需要 IV，长度通常为块大小（AES 为 16 字节，GCM 推荐 12 字节）
- **返回值**:
  - `userdata` - 加密器对象
- **错误**:
  - 如果算法名称不支持，抛出错误：`"unkonwn algorithm: XXX"`
  - 如果密钥长度不正确，抛出错误：`"key length need:X got:Y"`
  - 如果 IV 长度不正确，抛出错误：`"iv length need:X got:Y"`
- **示例**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- 创建 AES-128-CBC 加密器
local key = "1234567890123456"  -- 16 字节密钥
local iv = "abcdefghijklmnop"   -- 16 字节 IV
local enc = cipher.encryptor("aes-128-cbc", key, iv)
```

### cipher.decryptor(algorithm, key, iv)

创建解密器对象。

- **参数**:
  - `algorithm`: `string` - 加密算法名称，必须与加密时使用的算法一致
  - `key`: `string` - 解密密钥，必须与加密时使用的密钥一致
  - `iv`: `string|nil` - 初始化向量（可选），必须与加密时使用的 IV 一致
- **返回值**:
  - `userdata` - 解密器对象
- **错误**:
  - 错误类型与 `encryptor()` 相同
- **示例**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- 创建 AES-128-CBC 解密器
local key = "1234567890123456"
local iv = "abcdefghijklmnop"
local dec = cipher.decryptor("aes-128-cbc", key, iv)
```

### ctx:update(data)

流式加密/解密数据块（不包含最终填充）。

- **参数**:
  - `data`: `string` - 要加密/解密的数据块
- **返回值**:
  - `string` - 加密/解密后的数据块
    - 注意：返回长度可能小于输入长度（数据被缓存到块边界）
    - 块加密算法会缓存不足一个块大小的数据，直到调用 `final()`
- **错误**:
  - 如果加密/解密失败，抛出错误：`"cipher update error: XXX"`
- **示例**:

```lua validate
local cipher = require "silly.crypto.cipher"

local enc = cipher.encryptor("aes-128-cbc", "1234567890123456", "abcdefghijklmnop")

-- 分块加密大数据
local encrypted = ""
encrypted = encrypted .. enc:update("first chunk of data")
encrypted = encrypted .. enc:update("second chunk of data")
encrypted = encrypted .. enc:final()  -- 必须调用 final() 获取最终数据
```

### ctx:final([data])

完成加密/解密，返回最终数据（包含填充）。

- **参数**:
  - `data`: `string|nil` - 可选的最后一块数据
    - 如果提供，等同于先调用 `update(data)`，再调用 `final()`
- **返回值**:
  - 成功: `string` - 最终的加密/解密数据（包含填充或填充验证后的数据）
  - 失败: `nil` - 解密时填充验证失败或数据损坏
- **注意**:
  - 对于加密器：返回最后的数据块和填充
  - 对于解密器：验证填充并返回去除填充后的数据
  - GCM 模式：调用 `final()` 后才能调用 `tag()` 获取认证标签
  - 调用 `final()` 后，加密器/解密器对象不能继续使用，除非调用 `reset()`
- **示例**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- 方式 1：分别调用
local enc = cipher.encryptor("aes-128-cbc", "1234567890123456", "abcdefghijklmnop")
local encrypted = enc:update("hello") .. enc:final()

-- 方式 2：一次性加密（快捷方式）
local enc2 = cipher.encryptor("aes-128-cbc", "1234567890123456", "abcdefghijklmnop")
local encrypted2 = enc2:final("hello")  -- 直接传入数据

print(encrypted == encrypted2)  -- true
```

### ctx:reset(key, iv)

重置加密器/解密器，可复用同一对象进行多次加密/解密。

- **参数**:
  - `key`: `string` - 新的密钥（可以与之前相同）
  - `iv`: `string|nil` - 新的初始化向量（可以与之前相同）
- **返回值**: 无
- **错误**:
  - 如果密钥或 IV 长度不正确，抛出错误
- **用途**:
  - 复用加密器对象，避免重复创建，提升性能
  - 重置状态后，可以使用新的密钥和 IV 进行新的加密/解密操作
- **示例**:

```lua validate
local cipher = require "silly.crypto.cipher"

local enc = cipher.encryptor("aes-128-cbc", "1234567890123456", "abcdefghijklmnop")

-- 第一次加密
local encrypted1 = enc:final("first message")

-- 重置并加密第二条消息
enc:reset("1234567890123456", "1111111111111111")  -- 使用新的 IV
local encrypted2 = enc:final("second message")
```

### ctx:setpadding(enabled)

设置填充模式（仅适用于块加密算法）。

- **参数**:
  - `enabled`: `number` - 是否启用填充
    - `1` 或 `true`：启用 PKCS7 填充（默认）
    - `0` 或 `false`：禁用填充（数据长度必须是块大小的整数倍）
- **返回值**: 无
- **错误**:
  - 如果设置失败，抛出错误：`"cipher set padding error: XXX"`
- **注意**:
  - 禁用填充时，必须确保数据长度是块大小的整数倍
  - 流加密模式（CTR、GCM）不使用填充，调用此方法无效
  - 设置填充后，`reset()` 会保留填充设置
- **示例**:

```lua validate
local cipher = require "silly.crypto.cipher"

local enc = cipher.encryptor("aes-128-cbc", "1234567890123456", "abcdefghijklmnop")
enc:setpadding(0)  -- 禁用填充

-- 数据长度必须是 16 字节的整数倍
local plaintext = "1234567890123456"  -- 恰好 16 字节
local encrypted = enc:final(plaintext)
```

### ctx:setaad(aad)

设置附加认证数据（仅适用于 AEAD 模式，如 GCM、CCM）。

- **参数**:
  - `aad`: `string` - 附加认证数据（Additional Authenticated Data）
    - 不会被加密，但会被包含在认证标签的计算中
    - 常用于协议头、元数据等需要认证但不需要加密的数据
- **返回值**: 无
- **错误**:
  - 如果设置失败（非 AEAD 模式），抛出错误：`"cipher aad error: XXX"`
- **调用时机**:
  - 必须在调用 `update()` 或 `final()` 之前调用
  - 可以多次调用，数据会被累积
- **示例**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- GCM 模式加密，带 AAD
local enc = cipher.encryptor("aes-256-gcm", string.rep("k", 32), string.rep("i", 12))
enc:setaad("protocol-header-v1")  -- 设置附加认证数据
local encrypted = enc:final("secret message")
local tag = enc:tag()

-- GCM 模式解密，验证 AAD
local dec = cipher.decryptor("aes-256-gcm", string.rep("k", 32), string.rep("i", 12))
dec:setaad("protocol-header-v1")  -- 必须设置相同的 AAD
dec:settag(tag)                    -- 设置认证标签
local decrypted = dec:final(encrypted)
print(decrypted)  -- "secret message"
```

### ctx:settag(tag)

设置认证标签（仅用于 AEAD 解密）。

- **参数**:
  - `tag`: `string` - 认证标签（Authentication Tag）
    - 由加密器生成（通过 `tag()` 获取）
    - 用于验证密文的完整性和真实性
- **返回值**: 无
- **错误**:
  - 如果设置失败，抛出错误：`"cipher tag error: XXX"`
- **调用时机**:
  - 必须在调用 `final()` 之前调用
  - 如果标签验证失败，`final()` 会返回 `nil`
- **示例**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- 加密并获取标签
local enc = cipher.encryptor("aes-128-gcm", string.rep("x", 16), string.rep("y", 12))
local ciphertext = enc:final("confidential data")
local tag = enc:tag()

-- 解密并验证标签
local dec = cipher.decryptor("aes-128-gcm", string.rep("x", 16), string.rep("y", 12))
dec:settag(tag)  -- 设置标签用于验证
local plaintext = dec:final(ciphertext)

if plaintext then
    print("解密成功:", plaintext)
else
    print("认证失败：数据被篡改")
end
```

### ctx:tag()

获取认证标签（仅用于 AEAD 加密）。

- **参数**: 无
- **返回值**:
  - `string` - 认证标签（Tag），长度取决于算法（通常 16 字节）
- **错误**:
  - 如果获取失败（非 AEAD 模式或未调用 `final()`），抛出错误：`"cipher tag error: XXX"`
- **调用时机**:
  - 必须在调用 `final()` 之后调用
  - 标签需要与密文一起传输给接收方
- **示例**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- GCM 加密并获取标签
local enc = cipher.encryptor("aes-256-gcm", string.rep("k", 32), string.rep("n", 12))
local ciphertext = enc:final("top secret")
local tag = enc:tag()

print("密文长度:", #ciphertext)      -- 10 字节（与明文相同）
print("标签长度:", #tag)             -- 16 字节
print("传输数据:", ciphertext .. tag) -- 密文 + 标签
```

## 使用示例

### 基本用法：AES-CBC 加密

```lua validate
local cipher = require "silly.crypto.cipher"

-- 定义密钥和 IV
local key = "my-secret-key-16"  -- 16 字节（AES-128）
local iv = "my-random-iv1234"   -- 16 字节

-- 加密
local plaintext = "Hello, Silly Framework!"
local enc = cipher.encryptor("aes-128-cbc", key, iv)
local ciphertext = enc:final(plaintext)

print("明文:", plaintext)
print("密文长度:", #ciphertext)  -- 32 字节（16 字节数据 + 16 字节填充）

-- 解密
local dec = cipher.decryptor("aes-128-cbc", key, iv)
local decrypted = dec:final(ciphertext)

print("解密结果:", decrypted)    -- "Hello, Silly Framework!"
print("验证:", plaintext == decrypted)  -- true
```

### AES-GCM 认证加密

```lua validate
local cipher = require "silly.crypto.cipher"

-- GCM 模式：认证加密，提供数据完整性保护
local key = string.rep("k", 32)  -- AES-256: 32 字节密钥
local iv = string.rep("i", 12)   -- GCM 推荐 12 字节 IV

-- 加密
local plaintext = "Sensitive data"
local enc = cipher.encryptor("aes-256-gcm", key, iv)
local ciphertext = enc:final(plaintext)
local tag = enc:tag()  -- 获取认证标签

print("密文长度:", #ciphertext)  -- 14 字节（与明文相同，GCM 无填充）
print("标签长度:", #tag)         -- 16 字节

-- 解密并验证
local dec = cipher.decryptor("aes-256-gcm", key, iv)
dec:settag(tag)  -- 设置认证标签
local decrypted = dec:final(ciphertext)

if decrypted then
    print("解密成功:", decrypted)
else
    print("认证失败：数据可能被篡改")
end
```

### 流式加密大文件

```lua validate
local cipher = require "silly.crypto.cipher"

-- 模拟大文件分块加密
local function encrypt_large_data()
    local key = string.rep("x", 16)
    local iv = string.rep("y", 16)
    local enc = cipher.encryptor("aes-128-cbc", key, iv)

    -- 分块处理（模拟读取文件）
    local chunks = {
        "This is the first chunk of data. ",
        "This is the second chunk of data. ",
        "This is the final chunk of data."
    }

    local encrypted = ""
    for i, chunk in ipairs(chunks) do
        encrypted = encrypted .. enc:update(chunk)
    end
    encrypted = encrypted .. enc:final()  -- 获取最终块和填充

    print("总密文长度:", #encrypted)
    return encrypted, key, iv
end

-- 流式解密
local function decrypt_large_data(ciphertext, key, iv)
    local dec = cipher.decryptor("aes-128-cbc", key, iv)

    -- 分块解密
    local chunk_size = 32  -- 每次处理 32 字节
    local decrypted = ""

    for i = 1, #ciphertext - chunk_size, chunk_size do
        local chunk = ciphertext:sub(i, i + chunk_size - 1)
        decrypted = decrypted .. dec:update(chunk)
    end

    -- 处理剩余数据和填充验证
    local remaining = ciphertext:sub(#ciphertext - (#ciphertext % chunk_size) + 1)
    decrypted = decrypted .. dec:final(remaining)

    return decrypted
end

-- 执行加密和解密
local ciphertext, key, iv = encrypt_large_data()
local plaintext = decrypt_large_data(ciphertext, key, iv)
print("解密结果:", plaintext)
```

### AES-CTR 流加密模式

```lua validate
local cipher = require "silly.crypto.cipher"

-- CTR 模式：流加密，无需填充，可并行处理
local key = string.rep("s", 16)  -- 16 字节密钥
local iv = string.rep("n", 16)   -- 16 字节 nonce

-- 加密任意长度数据（无需填充）
local plaintext = "Short"  -- 5 字节
local enc = cipher.encryptor("aes-128-ctr", key, iv)
local ciphertext = enc:final(plaintext)

print("明文长度:", #plaintext)   -- 5 字节
print("密文长度:", #ciphertext)  -- 5 字节（与明文相同）

-- 解密
local dec = cipher.decryptor("aes-128-ctr", key, iv)
local decrypted = dec:final(ciphertext)
print("解密结果:", decrypted)  -- "Short"
```

### 禁用填充的手动填充

```lua validate
local cipher = require "silly.crypto.cipher"

-- 手动填充到块大小（16 字节）
local function manual_pkcs7_pad(data, block_size)
    local padding = block_size - (#data % block_size)
    return data .. string.rep(string.char(padding), padding)
end

local function manual_pkcs7_unpad(data)
    local padding = string.byte(data, -1)
    return data:sub(1, -padding - 1)
end

-- 加密（禁用自动填充）
local key = string.rep("k", 16)
local iv = string.rep("i", 16)
local plaintext = "Test"  -- 4 字节

-- 手动填充
local padded = manual_pkcs7_pad(plaintext, 16)
print("填充后:", #padded)  -- 16 字节

local enc = cipher.encryptor("aes-128-cbc", key, iv)
enc:setpadding(0)  -- 禁用自动填充
local ciphertext = enc:final(padded)

-- 解密（禁用自动填充）
local dec = cipher.decryptor("aes-128-cbc", key, iv)
dec:setpadding(0)
local decrypted_padded = dec:final(ciphertext)

-- 手动去除填充
local decrypted = manual_pkcs7_unpad(decrypted_padded)
print("解密结果:", decrypted)  -- "Test"
```

### GCM 模式带附加认证数据

```lua validate
local cipher = require "silly.crypto.cipher"

-- 场景：加密 HTTP 响应体，认证 HTTP 头部
local function encrypt_http_response(headers, body, key, iv)
    local enc = cipher.encryptor("aes-256-gcm", key, iv)

    -- 设置 AAD（附加认证数据）：HTTP 头部
    local aad = "Content-Type: application/json\r\n" ..
                "X-Request-ID: 12345\r\n"
    enc:setaad(aad)

    -- 加密响应体
    local encrypted_body = enc:final(body)
    local tag = enc:tag()

    return {
        headers = aad,
        encrypted_body = encrypted_body,
        tag = tag
    }
end

local function decrypt_http_response(response, key, iv)
    local dec = cipher.decryptor("aes-256-gcm", key, iv)

    -- 设置相同的 AAD
    dec:setaad(response.headers)

    -- 设置认证标签
    dec:settag(response.tag)

    -- 解密响应体
    local body = dec:final(response.encrypted_body)
    if not body then
        return nil, "认证失败：头部或响应体被篡改"
    end

    return body
end

-- 使用示例
local key = string.rep("k", 32)
local iv = string.rep("i", 12)
local headers = "X-API-Version: 1.0"
local body = '{"status":"success","data":"hello"}'

local encrypted = encrypt_http_response(headers, body, key, iv)
print("密文长度:", #encrypted.encrypted_body)

local decrypted_body, err = decrypt_http_response(encrypted, key, iv)
if decrypted_body then
    print("解密成功:", decrypted_body)
else
    print("解密失败:", err)
end
```

### 多算法比较

```lua validate
local cipher = require "silly.crypto.cipher"

-- 比较不同加密算法的性能和密文长度
local function compare_algorithms()
    local plaintext = "Test data for comparison"
    local results = {}

    -- 测试不同算法
    local algorithms = {
        {name = "aes-128-cbc", key_len = 16, iv_len = 16},
        {name = "aes-256-cbc", key_len = 32, iv_len = 16},
        {name = "aes-128-gcm", key_len = 16, iv_len = 12},
        {name = "aes-256-gcm", key_len = 32, iv_len = 12},
        {name = "aes-128-ctr", key_len = 16, iv_len = 16},
    }

    for _, alg in ipairs(algorithms) do
        local key = string.rep("k", alg.key_len)
        local iv = string.rep("i", alg.iv_len)

        local enc = cipher.encryptor(alg.name, key, iv)
        local ciphertext = enc:final(plaintext)

        local tag_len = 0
        if alg.name:match("gcm") then
            tag_len = #enc:tag()
        end

        results[alg.name] = {
            plaintext_len = #plaintext,
            ciphertext_len = #ciphertext,
            tag_len = tag_len,
            total_len = #ciphertext + tag_len
        }
    end

    return results
end

-- 执行比较
local results = compare_algorithms()
for name, info in pairs(results) do
    print(string.format("%s: 明文=%d字节, 密文=%d字节, 标签=%d字节, 总计=%d字节",
        name, info.plaintext_len, info.ciphertext_len, info.tag_len, info.total_len))
end
```

### 重用加密器对象

```lua validate
local cipher = require "silly.crypto.cipher"

-- 场景：批量加密多条消息
local function batch_encrypt_messages(messages)
    local key = string.rep("k", 16)
    local enc = cipher.encryptor("aes-128-cbc", key, string.rep("i", 16))

    local encrypted_list = {}

    for i, msg in ipairs(messages) do
        -- 每条消息使用不同的 IV
        local iv = string.format("iv%013d", i)  -- 生成唯一 IV
        enc:reset(key, iv)

        encrypted_list[i] = {
            iv = iv,
            ciphertext = enc:final(msg)
        }
    end

    return encrypted_list
end

-- 批量解密
local function batch_decrypt_messages(encrypted_list, key)
    local dec = cipher.decryptor("aes-128-cbc", key, string.rep("i", 16))
    local messages = {}

    for i, item in ipairs(encrypted_list) do
        dec:reset(key, item.iv)
        messages[i] = dec:final(item.ciphertext)
    end

    return messages
end

-- 使用示例
local messages = {"Message 1", "Message 2", "Message 3"}
local key = string.rep("k", 16)

local encrypted = batch_encrypt_messages(messages)
print("加密完成，共", #encrypted, "条消息")

local decrypted = batch_decrypt_messages(encrypted, key)
for i, msg in ipairs(decrypted) do
    print(string.format("消息 %d: %s", i, msg))
end
```

## 注意事项

### 安全性考虑

1. **密钥管理**
   - 密钥应使用安全的随机数生成器生成（使用 `silly.crypto.random`）
   - 密钥应安全存储，避免硬编码在代码中
   - 建议使用密钥派生函数（KDF）从密码生成密钥
   - 定期轮换密钥以降低安全风险

2. **初始化向量（IV）**
   - **绝对不要**重复使用相同的 IV 和密钥组合
   - 每次加密应生成新的随机 IV
   - IV 可以公开传输（通常附加在密文前）
   - GCM 模式：IV 不能重复，否则严重破坏安全性

3. **加密模式选择**
   - **避免使用 ECB 模式**：相同的明文块会产生相同的密文块，不安全
   - **推荐 GCM 模式**：提供加密和认证双重保护，防止篡改
   - **CBC 模式**：需要使用 HMAC 等方式额外保护完整性
   - **CTR 模式**：需要确保 IV 不重复

4. **填充预言攻击**
   - CBC 模式存在填充预言攻击风险
   - 应统一错误处理，避免泄露填充信息
   - 建议使用 GCM/CCM 等 AEAD 模式

### 性能优化

1. **批量加密**
   - 使用 `reset()` 重用加密器对象，避免重复创建
   - 减少内存分配和 OpenSSL 上下文初始化开销

2. **流式处理**
   - 大文件加密时使用 `update()` 分块处理，避免内存溢出
   - 块大小建议为 16KB-64KB

3. **算法选择**
   - AES-GCM：硬件加速支持好，速度快
   - ChaCha20-Poly1305：软件实现快，适合移动设备

### 常见错误

| 错误信息 | 原因 | 解决方法 |
|---------|------|---------|
| `unknown algorithm: XXX` | 算法名称不支持或拼写错误 | 检查算法名称，确认 OpenSSL 版本支持 |
| `key length need:X got:Y` | 密钥长度不正确 | 使用正确长度的密钥（AES-128: 16字节，AES-256: 32字节） |
| `iv length need:X got:Y` | IV 长度不正确 | 使用正确长度的 IV（CBC/CTR: 16字节，GCM: 12字节） |
| `cipher update error` | 数据处理失败 | 检查数据是否损坏或算法参数是否正确 |
| `final()` 返回 `nil` | 解密时填充验证失败或 GCM 认证失败 | 密钥/IV 不正确，或数据被篡改 |

### 数据传输格式

加密数据传输时，通常使用以下格式：

```
[IV][密文][认证标签（如果是 AEAD）]
```

**示例**：
```lua
-- 加密并打包
local iv = random.random(12)
local enc = cipher.encryptor("aes-256-gcm", key, iv)
local ciphertext = enc:final(plaintext)
local tag = enc:tag()
local packet = iv .. ciphertext .. tag  -- 传输格式

-- 解包并解密
local iv = packet:sub(1, 12)
local ciphertext = packet:sub(13, -17)
local tag = packet:sub(-16)
local dec = cipher.decryptor("aes-256-gcm", key, iv)
dec:settag(tag)
local plaintext = dec:final(ciphertext)
```

### 与其他加密库的兼容性

- **OpenSSL 命令行**：
  ```bash
  # 加密（与 Lua 代码兼容）
  echo -n "Hello" | openssl enc -aes-128-cbc -K 31323334353637383930313233343536 -iv 61626364656667686969696a6b6c6d6e6f70 -nosalt
  ```

- **Python (cryptography)**：使用相同的算法、密钥、IV 可以互操作

- **Node.js (crypto)**：使用相同的算法、密钥、IV 可以互操作

## 最佳实践

### 1. 使用密钥派生函数（KDF）

```lua
local hash = require "silly.crypto.hash"
local cipher = require "silly.crypto.cipher"

-- 从密码派生密钥（简化示例，实际应使用 PBKDF2/Argon2）
local function derive_key(password, salt, key_len)
    local data = password .. salt
    for i = 1, 10000 do  -- 多次迭代增强安全性
        data = hash.sha256(data)
    end
    return data:sub(1, key_len)
end

local password = "user-password-123"
local salt = "random-salt-value"
local key = derive_key(password, salt, 32)  -- 派生 32 字节密钥

-- 使用派生的密钥
local enc = cipher.encryptor("aes-256-gcm", key, string.rep("i", 12))
```

### 2. 实现加密工具函数

```lua
local cipher = require "silly.crypto.cipher"
local random = require "silly.crypto.random"

local crypto_util = {}

-- 一键加密（自动生成 IV）
function crypto_util.encrypt(plaintext, key, algorithm)
    algorithm = algorithm or "aes-256-gcm"
    local iv_len = algorithm:match("gcm") and 12 or 16
    local iv = random.random(iv_len)

    local enc = cipher.encryptor(algorithm, key, iv)
    local ciphertext = enc:final(plaintext)

    if algorithm:match("gcm") then
        local tag = enc:tag()
        return iv .. ciphertext .. tag  -- IV + 密文 + 标签
    else
        return iv .. ciphertext  -- IV + 密文
    end
end

-- 一键解密
function crypto_util.decrypt(encrypted, key, algorithm)
    algorithm = algorithm or "aes-256-gcm"
    local iv_len = algorithm:match("gcm") and 12 or 16

    local iv = encrypted:sub(1, iv_len)

    if algorithm:match("gcm") then
        local tag = encrypted:sub(-16)
        local ciphertext = encrypted:sub(iv_len + 1, -17)

        local dec = cipher.decryptor(algorithm, key, iv)
        dec:settag(tag)
        return dec:final(ciphertext)
    else
        local ciphertext = encrypted:sub(iv_len + 1)
        local dec = cipher.decryptor(algorithm, key, iv)
        return dec:final(ciphertext)
    end
end

return crypto_util
```

### 3. 数据库字段加密

```lua
-- 场景：加密用户敏感信息（如邮箱、电话）
local cipher = require "silly.crypto.cipher"
local base64 = require "silly.encoding.base64"

local db_crypto = {}
local master_key = string.rep("k", 32)  -- 从配置文件读取

function db_crypto.encrypt_field(plaintext)
    local random = require "silly.crypto.random"
    local iv = random.random(12)

    local enc = cipher.encryptor("aes-256-gcm", master_key, iv)
    local ciphertext = enc:final(plaintext)
    local tag = enc:tag()

    -- Base64 编码以存储到数据库
    return base64.encode(iv .. ciphertext .. tag)
end

function db_crypto.decrypt_field(encrypted_b64)
    local encrypted = base64.decode(encrypted_b64)
    local iv = encrypted:sub(1, 12)
    local tag = encrypted:sub(-16)
    local ciphertext = encrypted:sub(13, -17)

    local dec = cipher.decryptor("aes-256-gcm", master_key, iv)
    dec:settag(tag)
    return dec:final(ciphertext)
end

return db_crypto
```

### 4. 会话密钥加密

```lua
local cipher = require "silly.crypto.cipher"

-- 使用临时会话密钥加密数据
local function create_session(user_id)
    local random = require "silly.crypto.random"
    local session_key = random.random(32)  -- 随机会话密钥
    local session_id = random.random(16)

    return {
        id = session_id,
        key = session_key,
        user_id = user_id,
        created_at = os.time()
    }
end

local function encrypt_session_data(session, data)
    local random = require "silly.crypto.random"
    local iv = random.random(12)

    local enc = cipher.encryptor("aes-256-gcm", session.key, iv)
    local ciphertext = enc:final(data)
    local tag = enc:tag()

    return iv .. ciphertext .. tag
end
```

## 参见

- [silly.crypto.hash](./hash.md) - 哈希函数（密钥派生、数据完整性）
- [silly.crypto.hmac](./hmac.md) - 消息认证码（CBC 模式的完整性保护）
- [silly.crypto.pkey](./pkey.md) - 非对称加密（密钥交换、数字签名）
- [silly.encoding.base64](../encoding/base64.md) - Base64 编码（存储二进制密文）

## 标准参考

- [OpenSSL EVP Cipher](https://www.openssl.org/docs/manmaster/man3/EVP_EncryptInit.html)
- [NIST SP 800-38A](https://csrc.nist.gov/publications/detail/sp/800-38a/final) - AES 加密模式
- [NIST SP 800-38D](https://csrc.nist.gov/publications/detail/sp/800-38d/final) - GCM 模式规范
- [RFC 5116](https://tools.ietf.org/html/rfc5116) - 认证加密（AEAD）接口
