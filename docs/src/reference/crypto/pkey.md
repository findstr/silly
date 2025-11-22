---
title: Pkey（公钥加密）
icon: lock
category:
  - API 参考
tag:
  - 加密
  - 非对称加密
  - RSA
  - ECDSA
  - 数字签名
---

# silly.crypto.pkey

`silly.crypto.pkey` 模块提供了公钥加密（Public Key Cryptography）功能，支持 RSA 和 ECDSA（椭圆曲线数字签名算法）两种非对称加密算法。该模块提供数字签名、签名验证以及 RSA 加密/解密功能，是构建安全系统的基础组件。

## 概述

非对称加密使用一对密钥：公钥（Public Key）和私钥（Private Key）。本模块支持以下操作：

**签名与验证**：
- 私钥用于签名，公钥用于验证签名
- 支持 RSA 和 ECDSA 两种算法

**加密与解密**（仅 RSA）：
- 公钥用于加密，私钥用于解密
- 支持多种填充模式（PKCS#1、OAEP）

这些功能广泛应用于：

- **数字签名**：证明数据的完整性和来源
- **身份认证**：验证通信双方的身份
- **JWT 令牌**：使用 RSA/ECDSA 签名的 JSON Web Token
- **TLS/SSL**：HTTPS 证书的签名验证、密钥交换
- **代码签名**：验证软件包的完整性
- **混合加密**：使用 RSA 加密对称密钥，用对称算法加密大量数据

本模块基于 OpenSSL EVP（Envelope）接口实现，支持 PEM 格式的密钥文件，并提供了简洁的 Lua API。

## 模块导入

```lua validate
local pkey = require "silly.crypto.pkey"
```

## 核心概念

### 公钥与私钥

- **私钥（Private Key）**：保密的密钥，用于生成数字签名。只有私钥持有者才能生成有效签名。
- **公钥（Public Key）**：公开的密钥，用于验证数字签名。任何人都可以使用公钥验证签名的真实性。

```
[发送方]
  数据 + 私钥 → 签名
  数据 + 签名 → 发送

[接收方]
  数据 + 签名 + 公钥 → 验证结果（true/false）
```

### 支持的算法

#### RSA（Rivest-Shamir-Adleman）

RSA 是最广泛使用的非对称加密算法，基于大整数分解的数学难题。

- **密钥长度**：通常为 2048 位或 4096 位
- **签名速度**：较慢，适合对性能要求不高的场景
- **兼容性**：几乎所有系统都支持

#### ECDSA（Elliptic Curve Digital Signature Algorithm）

ECDSA 是基于椭圆曲线的签名算法，使用更短的密钥达到与 RSA 相同的安全性。

- **密钥长度**：通常为 256 位（相当于 RSA 3072 位）
- **签名速度**：比 RSA 快得多
- **密钥尺寸**：更小，节省存储和传输带宽
- **常用曲线**：secp256k1（比特币）、prime256v1（P-256）

### 哈希算法

签名操作会先对数据进行哈希，然后对哈希值签名。支持的哈希算法：

- `sha1`：SHA-1（不推荐，存在碰撞风险）
- `sha256`：SHA-256（推荐）
- `sha384`：SHA-384
- `sha512`：SHA-512（高安全要求场景）
- `md5`：MD5（已弃用，不安全）

### RSA 填充模式

RSA 加密/解密需要指定填充模式（Padding），以确保安全性和兼容性：

#### PKCS#1 v1.5 填充（`pkey.RSA_PKCS1`）

- **值**：`1`（对应 OpenSSL 的 `RSA_PKCS1_PADDING`）
- **特点**：传统填充方式，确定性填充
- **安全性**：存在 Bleichenbacher 攻击风险，不推荐用于新系统
- **最大消息长度**：密钥长度 - 11 字节（2048 位密钥 = 245 字节）
- **用途**：兼容旧系统

#### OAEP 填充（`pkey.RSA_PKCS1_OAEP`）

- **值**：`4`（对应 OpenSSL 的 `RSA_PKCS1_OAEP_PADDING`）
- **全称**：Optimal Asymmetric Encryption Padding
- **特点**：现代化填充方式，包含随机性（每次加密结果不同）
- **安全性**：抗选择密文攻击，**推荐使用**
- **最大消息长度**：密钥长度 - 2×哈希长度 - 2（SHA256 时约 190 字节）
- **哈希算法**：支持 SHA1、SHA256、SHA512 等
- **用途**：新系统的默认选择，MySQL 8.0+ 密码加密

**OAEP 技术细节**：
- 使用两个哈希函数：OAEP digest（标签哈希）和 MGF1 digest（掩码生成）
- 默认情况下，OAEP digest 和 MGF1 digest 均为 SHA1（OpenSSL 默认）
- 当提供 `hash` 参数时，本模块会同时将 OAEP digest 和 MGF1 digest 设置为相同算法
- 标准兼容：符合 PKCS#1 v2.0+ 规范

#### 无填充（`pkey.RSA_NO`）

- **值**：`3`（对应 OpenSSL 的 `RSA_NO_PADDING`）
- **特点**：不添加填充，直接对数据加密
- **要求**：消息长度必须等于密钥长度
- **安全性**：**不安全**，仅用于特殊协议实现
- **用途**：低层协议、自定义填充

#### X9.31 填充（`pkey.RSA_X931`）

- **值**：`5`（对应 OpenSSL 的 `RSA_X931_PADDING`）
- **用途**：专门用于签名，不推荐用于加密

### 密钥格式

模块支持多种 PEM 格式：

```
-----BEGIN PRIVATE KEY-----        # PKCS#8 私钥（推荐）
-----BEGIN RSA PRIVATE KEY-----    # PKCS#1 RSA 私钥
-----BEGIN EC PRIVATE KEY-----     # SEC1 EC 私钥
-----BEGIN ENCRYPTED PRIVATE KEY----- # 加密的 PKCS#8 私钥
-----BEGIN PUBLIC KEY-----         # PKCS#8 公钥
```

## API 参考

### pkey.new(pem_string, [password])

加载 PEM 格式的公钥或私钥，创建密钥对象。

- **参数**:
  - `pem_string`: `string` - PEM 格式的密钥字符串（包括 `-----BEGIN/END-----` 标记）
  - `password`: `string` - 可选，加密私钥的密码（仅用于加密私钥）
- **返回值**:
  - 成功: `userdata, nil` - 密钥对象和 nil
  - 失败: `nil, error_message` - nil 和错误信息字符串
- **说明**:
  - 自动识别私钥或公钥格式
  - 支持 PKCS#8、PKCS#1、SEC1 等多种格式
  - 支持加密的私钥（需要提供密码）
  - 密钥对象会在垃圾回收时自动释放
- **示例**:

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加载 RSA 公钥
local rsa_public_key, err = pkey.new([[
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
if not rsa_public_key then
    print("RSA 公钥加载失败:", err)
    return
end
print("RSA 公钥加载成功")

-- 加载 EC 私钥
local ec_private_key, err = pkey.new([[
-----BEGIN EC PRIVATE KEY-----
MHQCAQEEICaCaDvEFIgrZXksCEe/FG1803c71gyUBI362hd8vuNyoAcGBSuBBAAK
oUQDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf/c+hOGwHalqi6V1wAiC1Hcx/
T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END EC PRIVATE KEY-----
]])
if not ec_private_key then
    print("EC 私钥加载失败:", err)
    return
end
print("EC 私钥加载成功")

-- 加载加密的私钥
local encrypted_key, err = pkey.new([[
-----BEGIN ENCRYPTED PRIVATE KEY-----
MIIFLTBXBgkqhkiG9w0BBQ0wSjApBgkqhkiG9w0BBQwwHAQI2+GG3gsDJbwCAggA
MAwGCCqGSIb3DQIJBQAwHQYJYIZIAWUDBAEqBBBl5BCE5p8mrjUpj0cdbN5SBIIE
0FP54ygFb2qWXXLuRK241megT4wpy3ITDfkoyYtew23ScvZ/mNTBEUorA3H1ebas
-----END ENCRYPTED PRIVATE KEY-----
]], "123456")  -- 提供密码
if not encrypted_key then
    print("加密私钥加载失败:", err)
    return
end
print("加密私钥加载成功")
```

### key:sign(message, algorithm)

使用私钥对消息进行数字签名。

- **参数**:
  - `message`: `string` - 要签名的消息（任意长度）
  - `algorithm`: `string` - 哈希算法名称
    - 支持：`"sha1"`, `"sha256"`, `"sha384"`, `"sha512"`, `"md5"`
    - 推荐：`"sha256"` 或 `"sha512"`
- **返回值**:
  - 成功: `string` - 二进制签名数据
  - 失败: 抛出错误
- **说明**:
  - 必须使用私钥对象调用
  - 签名是二进制数据，通常需要 Base64 编码后传输
  - 签名长度取决于密钥类型（RSA 2048 位 = 256 字节，ECDSA P-256 = ~70 字节）
  - 相同消息和密钥，RSA 签名是确定性的，ECDSA 签名包含随机数（不同次签名结果不同）
- **示例**:

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加载 RSA 私钥
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

-- 对消息进行签名
local message = "Hello, Silly Framework!"
local signature = private_key:sign(message, "sha256")

print("消息:", message)
print("签名长度:", #signature, "字节")
print("签名（十六进制）:", signature:gsub(".", function(c)
    return string.format("%02x", c:byte())
end))
```

### key:verify(message, signature, algorithm)

使用公钥验证消息的数字签名。

- **参数**:
  - `message`: `string` - 原始消息
  - `signature`: `string` - 签名数据（通常从 `sign()` 获得）
  - `algorithm`: `string` - 哈希算法名称（必须与签名时使用的算法一致）
- **返回值**:
  - 成功验证: `true` - 签名有效，消息未被篡改
  - 验证失败: `false` - 签名无效或消息被篡改
  - 错误: 抛出错误（如算法不支持）
- **说明**:
  - 必须使用公钥对象调用（私钥也可以，但不推荐）
  - 验证算法必须与签名时使用的算法一致
  - 返回 `false` 表示签名无效，可能是：
    - 消息被篡改
    - 签名被篡改
    - 使用了错误的公钥
    - 哈希算法不匹配
- **示例**:

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加载密钥对
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

-- 签名和验证
local message = "Important document content"
local signature = private_key:sign(message, "sha256")
local is_valid = public_key:verify(message, signature, "sha256")

if is_valid then
    print("签名验证成功：消息未被篡改")
else
    print("签名验证失败：消息可能被篡改")
end

-- 测试篡改检测
local tampered_message = "Modified document content"
local is_tampered = public_key:verify(tampered_message, signature, "sha256")
print("篡改消息验证结果:", is_tampered)  -- false
```

### key:encrypt(plaintext, [padding], [hash])

使用 RSA 公钥对数据进行加密（仅支持 RSA 密钥）。

- **参数**:
  - `plaintext`: `string` - 要加密的明文数据
  - `padding`: `number` - 可选，填充模式（默认为 PKCS#1 v1.5）
    - `pkey.RSA_PKCS1` (1): PKCS#1 v1.5 填充（OpenSSL 默认）
    - `pkey.RSA_PKCS1_OAEP` (4): OAEP 填充（推荐）
    - `pkey.RSA_NO` (3): 无填充（不安全）
    - `pkey.RSA_X931` (5): X9.31 填充
  - `hash`: `string` - 可选，仅用于 OAEP 填充时指定哈希算法（默认 SHA1）
    - 支持：`"sha1"`, `"sha256"`, `"sha384"`, `"sha512"`
    - 推荐：`"sha256"`
- **返回值**:
  - 成功: `ciphertext, nil` - 加密后的密文数据
  - 失败: `nil, error_message` - 错误信息字符串
- **说明**:
  - 必须使用 **公钥** 进行加密（私钥也可以但不推荐）
  - RSA 加密有最大长度限制：
    - PKCS#1: 密钥长度 - 11 字节（2048位密钥最大 245 字节）
    - OAEP: 密钥长度 - 2×哈希长度 - 2（SHA256 时约 190 字节）
  - OAEP 填充每次加密结果不同(包含随机数)
  - 当使用 OAEP 填充且提供 `hash` 参数时,本模块会同时将 OAEP digest 和 MGF1 digest 设置为相同算法
- **示例**:

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加载 RSA 公钥
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

-- 使用 OAEP + SHA256 加密（推荐）
local secret_message = "Confidential data"
local ciphertext, err = public_key:encrypt(secret_message, pkey.RSA_PKCS1_OAEP, "sha256")

if ciphertext then
    print("加密成功，密文长度:", #ciphertext, "字节")
else
    print("加密失败:", err)
end
```

### key:decrypt(ciphertext, [padding], [hash])

使用 RSA 私钥对密文进行解密（仅支持 RSA 密钥）。

- **参数**:
  - `ciphertext`: `string` - 要解密的密文数据
  - `padding`: `number` - 可选，填充模式（必须与加密时一致）
    - `pkey.RSA_PKCS1` (1): PKCS#1 v1.5 填充
    - `pkey.RSA_PKCS1_OAEP` (4): OAEP 填充（推荐）
    - `pkey.RSA_NO` (3): 无填充
    - `pkey.RSA_X931` (5): X9.31 填充
  - `hash`: `string` - 可选，仅用于 OAEP 填充时指定哈希算法（必须与加密时一致）
    - 支持：`"sha1"`, `"sha256"`, `"sha384"`, `"sha512"`
- **返回值**:
  - 成功: `plaintext, nil` - 解密后的明文数据
  - 失败: `nil, error_message` - 错误信息字符串
- **说明**:
  - 必须使用 **私钥** 进行解密
  - 填充模式和哈希算法必须与加密时完全一致
  - 解密失败可能原因：
    - 使用了错误的私钥
    - 密文被篡改
    - 填充模式或哈希算法不匹配
- **示例**:

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加载密钥对
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

-- 加密和解密流程
local message = "Secret message"
local ciphertext, _ = public_key:encrypt(message, pkey.RSA_PKCS1_OAEP, "sha256")

-- 解密
local decrypted, err = private_key:decrypt(ciphertext, pkey.RSA_PKCS1_OAEP, "sha256")

if decrypted then
    print("解密成功:", decrypted)  -- "Secret message"
else
    print("解密失败:", err)
end
```

## 使用示例

### RSA 加密解密完整流程（OAEP + SHA256）

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加载密钥对
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

-- 使用 OAEP + SHA256 加密（推荐方式）
local plaintext = "Sensitive password: MySecret123"
print("原始数据:", plaintext)

-- 使用公钥加密
local ciphertext, err = public_key:encrypt(plaintext, pkey.RSA_PKCS1_OAEP, "sha256")
if not ciphertext then
    print("加密失败:", err)
    return
end

print("加密成功，密文长度:", #ciphertext, "字节")

-- 使用私钥解密
local decrypted, err = private_key:decrypt(ciphertext, pkey.RSA_PKCS1_OAEP, "sha256")
if not decrypted then
    print("解密失败:", err)
    return
end

print("解密成功:", decrypted)
print("数据匹配:", decrypted == plaintext and "是" or "否")

-- 重要提示：OAEP 每次加密结果都不同（包含随机数）
local ciphertext2, _ = public_key:encrypt(plaintext, pkey.RSA_PKCS1_OAEP, "sha256")
print("\n两次加密结果相同吗?", ciphertext == ciphertext2 and "是" or "否（这是正常的）")
```

### RSA 多种填充模式对比

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加载密钥对
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

local test_message = "Hello, RSA!"

print("RSA 填充模式对比测试\n")

-- 1. PKCS#1 v1.5 填充（传统方式）
print("1. PKCS#1 v1.5 填充:")
local enc1, _ = public_key:encrypt(test_message, pkey.RSA_PKCS1)
local dec1, _ = private_key:decrypt(enc1, pkey.RSA_PKCS1)
print("  - 密文长度:", #enc1, "字节")
print("  - 解密结果:", dec1)
print("  - 特点: 确定性填充（同一消息每次加密结果相同）")

-- 2. OAEP 填充 + SHA1（MySQL 兼容模式）
print("\n2. OAEP + SHA1:")
local enc2, _ = public_key:encrypt(test_message, pkey.RSA_PKCS1_OAEP, "sha1")
local dec2, _ = private_key:decrypt(enc2, pkey.RSA_PKCS1_OAEP, "sha1")
print("  - 密文长度:", #enc2, "字节")
print("  - 解密结果:", dec2)
print("  - 特点: 随机性填充，MySQL 8.0+ 使用此模式")

-- 3. OAEP 填充 + SHA256（推荐）
print("\n3. OAEP + SHA256 (推荐):")
local enc3, _ = public_key:encrypt(test_message, pkey.RSA_PKCS1_OAEP, "sha256")
local dec3, _ = private_key:decrypt(enc3, pkey.RSA_PKCS1_OAEP, "sha256")
print("  - 密文长度:", #enc3, "字节")
print("  - 解密结果:", dec3)
print("  - 特点: 最安全的填充模式，抗选择密文攻击")

-- 4. OAEP 填充 + SHA512（高安全场景）
print("\n4. OAEP + SHA512:")
local enc4, _ = public_key:encrypt(test_message, pkey.RSA_PKCS1_OAEP, "sha512")
local dec4, _ = private_key:decrypt(enc4, pkey.RSA_PKCS1_OAEP, "sha512")
print("  - 密文长度:", #enc4, "字节")
print("  - 解密结果:", dec4)
print("  - 特点: 最高安全性，适合关键数据")

print("\n推荐：使用 OAEP + SHA256，安全性和兼容性最佳")
```

### 混合加密模式（RSA + AES）

```lua validate
local pkey = require "silly.crypto.pkey"
local cipher = require "silly.crypto.cipher"
local utils = require "silly.crypto.utils"

-- 加载 RSA 密钥对
local rsa_public = pkey.new([[
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

local rsa_private = pkey.new([[
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

-- 大文件数据（RSA 无法直接加密大数据）
local large_data = string.rep("This is a large document. ", 1000) -- 约 27KB

print("混合加密示例（RSA + AES）\n")
print("原始数据大小:", #large_data, "字节")

-- 步骤 1：生成随机 AES 密钥（32 字节 = 256 位）
local aes_key = utils.randomkey(32)
local aes_iv = utils.randomkey(16) -- AES-256-CBC 的 IV 长度为 16 字节

-- 步骤 2：使用 AES 加密大数据
local aes_enc = cipher.encryptor("aes-256-cbc", aes_key, aes_iv)
local aes_ciphertext = aes_enc:final(large_data)
print("\nAES 加密:")
print("  - AES 密钥长度:", #aes_key, "字节")
print("  - AES 密文长度:", #aes_ciphertext, "字节")

-- 步骤 3：使用 RSA 加密 AES 密钥（密钥很小，可以用 RSA 加密）
local encrypted_key, _ = rsa_public:encrypt(aes_key, pkey.RSA_PKCS1_OAEP, "sha256")
local encrypted_iv, _ = rsa_public:encrypt(aes_iv, pkey.RSA_PKCS1_OAEP, "sha256")
print("\nRSA 加密 AES 密钥:")
print("  - 加密后的密钥长度:", #encrypted_key, "字节")
print("  - 加密后的 IV 长度:", #encrypted_iv, "字节")

-- 步骤 4：传输数据（encrypted_key + encrypted_iv + aes_ciphertext）
local total_size = #encrypted_key + #encrypted_iv + #aes_ciphertext
print("\n传输数据总大小:", total_size, "字节")

-- ============ 解密过程 ============

-- 步骤 5：使用 RSA 解密 AES 密钥
local decrypted_key, _ = rsa_private:decrypt(encrypted_key, pkey.RSA_PKCS1_OAEP, "sha256")
local decrypted_iv, _ = rsa_private:decrypt(encrypted_iv, pkey.RSA_PKCS1_OAEP, "sha256")

-- 步骤 6：使用 AES 解密大数据
local aes_dec = cipher.decryptor("aes-256-cbc", decrypted_key, decrypted_iv)
local decrypted_data = aes_dec:final(aes_ciphertext)

print("\n解密结果:")
print("  - 解密数据大小:", #decrypted_data, "字节")
print("  - 数据完整性:", decrypted_data == large_data and "验证成功" or "验证失败")

print("\n混合加密优势:")
print("  - RSA 加密对称密钥，AES 加密大数据")
print("  - 结合了 RSA 的安全性和 AES 的高性能")
print("  - 适用于加密任意大小的数据")
```

### RSA 密钥签名验证完整流程

```lua validate
local pkey = require "silly.crypto.pkey"

-- 模拟场景：服务器 A 签名数据，服务器 B 验证签名

-- 服务器 A：加载私钥并签名
local server_a_privkey = pkey.new([[
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

local data_to_sign = "Transaction: Transfer $1000 from Alice to Bob"
local signature = server_a_privkey:sign(data_to_sign, "sha256")

print("[服务器 A] 数据已签名")
print("  数据:", data_to_sign)
print("  签名长度:", #signature, "字节")

-- 服务器 B：加载公钥并验证
local server_b_pubkey = pkey.new([[
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

local is_authentic = server_b_pubkey:verify(data_to_sign, signature, "sha256")

print("\n[服务器 B] 签名验证")
if is_authentic then
    print("  结果: 验证成功，数据真实可信")
else
    print("  结果: 验证失败，数据可能被篡改")
end
```

### ECDSA 椭圆曲线签名（高性能场景）

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加载 EC 密钥对（secp256k1 曲线）
local ec_privkey = pkey.new([[
-----BEGIN EC PRIVATE KEY-----
MHQCAQEEICaCaDvEFIgrZXksCEe/FG1803c71gyUBI362hd8vuNyoAcGBSuBBAAK
oUQDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf/c+hOGwHalqi6V1wAiC1Hcx/
T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END EC PRIVATE KEY-----
]])

local ec_pubkey = pkey.new([[
-----BEGIN PUBLIC KEY-----
MFYwEAYHKoZIzj0CAQYFK4EEAAoDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf
/c+hOGwHalqi6V1wAiC1Hcx/T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END PUBLIC KEY-----
]])

-- 签名多条消息
local messages = {
    "Payment request #1001",
    "Payment request #1002",
    "Payment request #1003"
}

print("ECDSA 签名示例（椭圆曲线）\n")

for i, msg in ipairs(messages) do
    local sig = ec_privkey:sign(msg, "sha256")
    local valid = ec_pubkey:verify(msg, sig, "sha256")

    print(string.format("消息 %d: %s", i, msg))
    print(string.format("  签名长度: %d 字节 (比 RSA 更短)", #sig))
    print(string.format("  验证结果: %s\n", valid and "成功" or "失败"))
end

print("说明：ECDSA 签名更短、更快，适合移动端和高并发场景")
```

### 使用加密私钥（密码保护）

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加密的私钥（使用密码 "123456" 加密）
local encrypted_privkey = [[
-----BEGIN ENCRYPTED PRIVATE KEY-----
MIIFLTBXBgkqhkiG9w0BBQ0wSjApBgkqhkiG9w0BBQwwHAQI2+GG3gsDJbwCAggA
MAwGCCqGSIb3DQIJBQAwHQYJYIZIAWUDBAEqBBBl5BCE5p8mrjUpj0cdbN5SBIIE
0FP54ygFb2qWXXLuRK241megT4wpy3ITDfkoyYtew23ScvZ/mNTBEUorA3H1ebas
8xUfsdVbZs91MbmJqTCpk0KWr86nz0H/5E8/EG8rr66ClnxkSMlaL910bpEn3LR/
w4jsCNzDHYtamwYQ4axpk+PjCFTFEzTNJohjl4ZRnXuLDFRMRqRcrvIIyVk0yLqE
e8aXPp6nYA5wwI+hlkTHPn9oe7QQnk3P9GrdJvY+6qmkmlOYV8b4uVso0HSnNYAy
1NHAHi0BZvlgmdPodgs9mOYYfV/TLHcdYOG7g0brBznHqk4K99TRmPnvU10NyFJ/
+/tEPWr6/kC+fz6AIi4sZ5oW84R/LOEbxifGUXmH2pDxL+NZFnboS7zbI6q3xZP9
vDYmZQ1hSZBu03kC+90KN/7T1tfr/FW1odnBQ6ZhiuTtHeutD5WAhpJEOmgYCp0A
HR/ETAX6Gq+0vPkp6OdRE0khA+9Q1uRI/Z1RzcvVQzOEhM02FjRv7FhLdQqwgVtC
5UcJkOC1SkU2rT2bYHnuaqUDYRKQ6lqOl6U5p26UyKLzFcza6zUKTGMCXePSbcJV
YkY4KfFXpQB2f7SS3/it6gsecwUGthFEXNqJL1q4Q2UlEHRVF6Iv8KuE/oV1HuHv
DCvao7kI0r1fbpLmG0v1Rx5WW/lbTet/dX2EkbXaD1BWtBzlQOo/mOHmpDrMoll+
F+S5Qm1L0Zfnl2QJb9ujh6ae82RdQbmGG0gt2bsPdBZTR8pkygNYxtT9ODdr35rr
IxXKdIln8qc3c1McHRUs+e8OwctTHFxXAqeUWDEZDvGHZ+L2guJJI186XUOLvkk+
V33AR1WEP8pfSPQFNVMzjnvy+9mWB3KDZALXezA+mOT/VJAUUq3B4vNjO8MUDigh
SpEG/1qwxc3XiolyxrYKeMdxQF5BzmPqk8oduPp+wRLgLcrwABDS0ppx9jbf9Fpv
lYt9H+xpADDWhmaIXCIDhbglxdja6lCNVmyybAf4ltBpx0LcfLYq2wTvsiiKGDAx
xWtT06qkRpZQ3gkMZzCE8uw0v1WW2Eu+NJKjjP8MpGHkdUHaZyZsdQ4d6q9eL+jr
LmvTs6VmUbefTAlMur7LieH/PMfOVsWkYpz7pTH42H6oAQ6wCUY0V95S9EmD3VlM
916hrRrxRl3hZDDjpWrcOTENcJC0B4b68qUWeyvA+HAJAjiJVXh8ja+PpJ3aDDOp
0Zgg/X5mwaOZGxjQsI5Xhou/TJBmOl2awqnolVVdG8AXVr2Lpuey43SAOejFicwh
Sj5oDcPW8b9GO9nkhHyJvKE2kwEy6Bf1wlBBMHVjdE6BjEdp2NWhilgX1pP2a6ZF
yPZ/Sf/LllQigY4YPd2fGqwFeWK6oFaMvAWsNlpA/yBGiJ7I7YYjaViywMtUoRU6
U7Wg9aBuo6zd/edibzz7VKDC0d1kpvTnWjnpZNWV34rR9R1lTS2g51t9B9UgVcIF
i8UpmLqSO2iTZ94YLXE+qjRuhqFGz+GzfVTPZXBptQ1QFeVwtcI2mdDoHV0rztzs
ARFqYQG3VWA7nbC0CsPuhGAwMdmhamDHyDJMyI0+LQCXdgGZGm3fp05YoIzVd57U
Kg7ZBEtGj2gFEoN7zNx9QfueKpjF5cfMzeQ4VOFfXDsO
-----END ENCRYPTED PRIVATE KEY-----
]]

local encrypted_pubkey = [[
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA5ek2uXetoj+qwcI67800
h1cLPyPbt4/GDJBRFm0ki7q/ykcHgBniL2wW3UAzPteyyu4N+XlcOdeMIZJvbgwX
UqX7WIFxWNhzcU6sjRIIEa6dcYdAhVj/EMOXWKKbAsmRlR8Qhc7Tegas4USbfe74
+ApWRV5y95s4oQv7U9qPI2wdTJICwAhT3RH/AM6DWqUuAL1iTiVb0MGCGY+ei2sK
hJ4rt3ry8JzVyiJNCazDUbB3ZSrqTVW5I+2vWE0MyF+KQGkyeRBtWNDLUyg65eO6
y6er5SVhHz4/Ot5P16vpd4lr2uv2AIBZAJOXsoOc+oF7Zml8zAtk+RXX8VAmxF4d
/QIDAQAB
-----END PUBLIC KEY-----
]]

-- 使用正确的密码加载密钥
local correct_password = "123456"
local private_key = pkey.new(encrypted_privkey, correct_password)
local public_key = pkey.new(encrypted_pubkey)

print("加密私钥示例\n")
print("私钥已使用密码保护，成功加载")

-- 正常签名和验证
local message = "Confidential document"
local signature = private_key:sign(message, "sha256")
local verified = public_key:verify(message, signature, "sha256")

print("签名和验证:", verified and "成功" or "失败")

-- 测试错误密码
local wrong_password = "wrong-password"
local key, err = pkey.new(encrypted_privkey, wrong_password)

if not key then
    print("\n错误密码测试:")
    print("  无法加载私钥:", err)
end
```

### 多算法签名比较

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加载 RSA 私钥
local rsa_key = pkey.new([[
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

-- 测试消息
local message = "Performance testing message"

-- 测试多种哈希算法
local algorithms = {"sha1", "sha256", "sha384", "sha512"}
local results = {}

print("不同哈希算法签名对比\n")
print(string.format("%-10s %-15s %-10s", "算法", "签名长度", "推荐度"))
print(string.rep("-", 40))

for _, alg in ipairs(algorithms) do
    local sig = rsa_key:sign(message, alg)
    local recommendation = alg == "sha256" and "推荐" or
                          alg == "sha512" and "高安全" or
                          alg == "sha1" and "不推荐" or "可选"

    print(string.format("%-10s %-15d %-10s",
        alg:upper(), #sig, recommendation))

    results[alg] = sig
end

print("\n说明：")
print("- SHA256: 安全性和性能平衡，最常用")
print("- SHA512: 更高安全性，适合敏感数据")
print("- SHA1: 已有碰撞攻击，不推荐生产使用")
```

### 文件签名验证

```lua validate
local pkey = require "silly.crypto.pkey"

-- 模拟文件签名和验证场景
local function sign_file(file_content, private_key, algorithm)
    algorithm = algorithm or "sha256"
    local signature = private_key:sign(file_content, algorithm)
    return {
        content = file_content,
        signature = signature,
        algorithm = algorithm,
        signed_at = os.time()
    }
end

local function verify_file(signed_data, public_key)
    local is_valid = public_key:verify(
        signed_data.content,
        signed_data.signature,
        signed_data.algorithm
    )

    return {
        valid = is_valid,
        algorithm = signed_data.algorithm,
        signed_at = signed_data.signed_at,
        verified_at = os.time()
    }
end

-- 加载密钥
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

-- 模拟文件内容
local file_content = "This is a critical configuration file.\nDo not modify without authorization."

-- 签名文件
print("文件签名验证示例\n")
print("原始文件内容:")
print(file_content)
print()

local signed = sign_file(file_content, private_key, "sha512")
print("文件已签名")
print("  算法:", signed.algorithm)
print("  签名时间:", os.date("%Y-%m-%d %H:%M:%S", signed.signed_at))
print("  签名长度:", #signed.signature, "字节")
print()

-- 验证文件（未篡改）
local result = verify_file(signed, public_key)
print("验证结果（原始文件）:")
print("  有效性:", result.valid and "有效" or "无效")
print()

-- 模拟文件被篡改
signed.content = "This file has been modified by attacker!"
local tampered_result = verify_file(signed, public_key)
print("验证结果（篡改后的文件）:")
print("  有效性:", tampered_result.valid and "有效" or "无效")
print("  结论: 检测到文件被篡改")
```

### 密钥对象复用（性能优化）

```lua validate
local pkey = require "silly.crypto.pkey"

-- 加载密钥（应在程序启动时执行一次）
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

print("密钥对象复用示例\n")
print("最佳实践：在程序启动时加载密钥一次，然后重复使用\n")

-- 模拟多次签名操作（复用同一个密钥对象）
local operations = {
    "User login: alice@example.com",
    "API request: GET /api/users",
    "Database query: SELECT * FROM orders",
    "WebSocket message: {type: 'chat', text: 'Hello'}",
    "File upload: document.pdf"
}

print("执行多次签名操作:")
for i, operation in ipairs(operations) do
    -- 每次签名都复用 private_key 对象，无需重复加载
    local sig = private_key:sign(operation, "sha256")
    local verified = public_key:verify(operation, sig, "sha256")

    print(string.format("  [%d] %s - %s", i, operation, verified and "验证成功" or "验证失败"))
end

print("\n性能提示:")
print("- 加载密钥是耗时操作，应避免频繁加载")
print("- 将密钥对象保存在全局变量或模块中")
print("- 密钥对象会在垃圾回收时自动释放")
```

### 错误处理示例

```lua validate
local pkey = require "silly.crypto.pkey"

print("错误处理示例\n")

-- 1. 无效的密钥格式
print("测试 1: 无效的密钥格式")
local key, err = pkey.new("this is not a valid PEM key")
if not key then
    print("  检测到错误:", err)
end
print()

-- 2. 错误的密码
print("测试 2: 加密密钥的错误密码")
local encrypted_key = [[
-----BEGIN ENCRYPTED PRIVATE KEY-----
MIIFLTBXBgkqhkiG9w0BBQ0wSjApBgkqhkiG9w0BBQwwHAQI2+GG3gsDJbwCAggA
MAwGCCqGSIb3DQIJBQAwHQYJYIZIAWUDBAEqBBBl5BCE5p8mrjUpj0cdbN5SBIIE
0FP54ygFb2qWXXLuRK241megT4wpy3ITDfkoyYtew23ScvZ/mNTBEUorA3H1ebas
-----END ENCRYPTED PRIVATE KEY-----
]]

local key, err = pkey.new(encrypted_key, "wrong-password")
if not key then
    print("  检测到错误:", err)
end
print()

-- 3. 加载有效密钥
print("测试 3: 加载有效密钥")
local valid_key, err = pkey.new([[
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

if not valid_key then
    print("  加载失败:", err)
    return
end
print("  密钥加载成功")
print()

-- 4. 不支持的算法（使用 pcall 因为 sign/verify 仍然会抛出错误）
print("测试 4: 不支持的哈希算法")
local ok, err = pcall(valid_key.sign, valid_key, "test", "unknown_algorithm")
if not ok then
    print("  捕获错误: 算法不支持")
end
print()

-- 5. 签名验证失败
print("测试 5: 签名验证失败（消息被篡改）")
local message = "Original message"
local signature = valid_key:sign(message, "sha256")

local public_key, err = pkey.new([[
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

if not public_key then
    print("  公钥加载失败:", err)
    return
end

local tampered = "Tampered message"
local is_valid = public_key:verify(tampered, signature, "sha256")

if not is_valid then
    print("  正确检测到：签名验证失败（消息被修改）")
end
print()

print("错误处理建议:")
print("- pkey.new() 返回 nil + 错误信息，直接检查返回值")
print("- sign() 和 verify() 在错误时会抛出异常，使用 pcall 捕获")
print("- 验证失败 (verify 返回 false) 与错误 (抛出异常) 是不同的")
print("- 验证失败应记录日志并拒绝请求")
print("- 不要在错误信息中泄露密钥细节")
```

## 注意事项

### 密钥安全

1. **私钥保护**
   - 私钥文件权限应设为 600（仅所有者可读写）
   - 生产环境建议使用加密的私钥
   - 不要将私钥提交到版本控制系统（添加到 .gitignore）
   - 使用环境变量或密钥管理系统（如 HashiCorp Vault）存储密钥

2. **密钥长度**
   - RSA：至少 2048 位，推荐 4096 位（高安全场景）
   - ECDSA：推荐 256 位（相当于 RSA 3072 位安全性）

3. **密钥轮换**
   - 定期更换密钥对（建议每年或更频繁）
   - 保留旧公钥以验证历史签名
   - 使用密钥版本号管理多个密钥

### 算法选择

| 场景 | 推荐算法 | 原因 |
|------|---------|------|
| 通用场景 | RSA + SHA256 | 兼容性最好，广泛支持 |
| 高性能场景 | ECDSA + SHA256 | 签名/验证速度快，密钥小 |
| 高安全场景 | RSA 4096 + SHA512 或 ECDSA P-384 | 更高的安全强度 |
| 移动端/IoT | ECDSA + SHA256 | 资源占用少，速度快 |
| JWT 令牌 | RS256 或 ES256 | 行业标准 |

### 性能考虑

1. **密钥加载**
   - 密钥加载是耗时操作（解析 PEM 格式和 OpenSSL 初始化）
   - 在程序启动时加载一次，保存在全局变量中复用
   - 避免在请求处理中重复加载密钥

2. **签名性能**
   - RSA 2048 签名：约 1-2ms（单核）
   - ECDSA P-256 签名：约 0.5ms（快 2-4 倍）
   - 验证操作通常比签名快 3-5 倍

3. **消息大小**
   - 签名前会对消息进行哈希，任意大小的消息都能签名
   - 大文件建议分块哈希或使用流式处理
   - 签名长度仅取决于密钥类型，与消息大小无关

### 常见错误

| 错误信息 | 原因 | 解决方法 |
|---------|------|---------|
| `load key error: ...` | PEM 格式错误或密码错误 | 检查密钥格式和密码 |
| `EVP_MD_CTX_new error` | OpenSSL 内存分配失败 | 检查系统资源 |
| `sign error: ...` | 签名失败（通常是密钥类型错误） | 确保使用私钥签名 |
| `verify error: ...` | 验证初始化失败 | 检查算法是否支持 |
| `unknown digest method: 'xxx'` | 不支持的哈希算法 | 使用支持的算法（sha256、sha512 等） |

### 兼容性说明

- **依赖**：需要编译时启用 OpenSSL 支持（`OPENSSL=ON`）
- **OpenSSL 版本**：支持 OpenSSL 1.0.x 和 1.1.x+
- **密钥格式**：自动识别 PKCS#1、PKCS#8、SEC1 格式
- **DER 格式**：同时支持 DER 二进制格式（不常用）

## 最佳实践

### 1. 密钥管理

```lua
-- 推荐：从环境变量或配置文件加载密钥
local key_path = os.getenv("PRIVATE_KEY_PATH") or "/etc/app/keys/private.pem"
local key_password = os.getenv("KEY_PASSWORD")

local function load_private_key()
    local f = io.open(key_path, "r")
    if not f then
        error("Cannot open private key file: " .. key_path)
    end
    local pem = f:read("*all")
    f:close()

    return pkey.new(pem, key_password)
end

-- 全局密钥对象（启动时加载）
local PRIVATE_KEY = load_private_key()
```

### 2. 签名数据结构化

```lua
-- 推荐：对结构化数据签名，包含时间戳和版本
local function sign_data(data)
    local payload = {
        version = 1,
        timestamp = os.time(),
        data = data
    }

    -- 序列化为 JSON 字符串
    local json = require "silly.encoding.json"
    local message = json.encode(payload)

    local signature = PRIVATE_KEY:sign(message, "sha256")

    return {
        payload = payload,
        signature = signature,
        algorithm = "sha256"
    }
end
```

### 3. 验证签名时检查过期

```lua
-- 验证签名并检查时间戳
local function verify_signed_data(signed_data, max_age)
    max_age = max_age or 3600  -- 默认 1 小时

    local json = require "silly.encoding.json"
    local message = json.encode(signed_data.payload)

    -- 验证签名
    if not PUBLIC_KEY:verify(message, signed_data.signature, signed_data.algorithm) then
        return nil, "invalid signature"
    end

    -- 检查时间戳
    local age = os.time() - signed_data.payload.timestamp
    if age > max_age then
        return nil, "signature expired"
    end

    return signed_data.payload.data
end
```

### 4. 签名版本控制

```lua
-- 支持多版本密钥
local KEY_VERSIONS = {
    v1 = pkey.new(V1_PRIVATE_KEY),
    v2 = pkey.new(V2_PRIVATE_KEY),  -- 新密钥
}

local CURRENT_VERSION = "v2"

local function sign_with_version(message)
    local key = KEY_VERSIONS[CURRENT_VERSION]
    local signature = key:sign(message, "sha256")

    return {
        version = CURRENT_VERSION,
        signature = signature
    }
end

local function verify_with_version(message, signed)
    local key = KEY_VERSIONS[signed.version]
    if not key then
        return false, "unknown key version"
    end

    return key:verify(message, signed.signature, "sha256")
end
```

### 5. 错误日志记录

```lua
local logger = require "silly.logger"
local json = require "json"

local function safe_sign(message, algorithm)
    local ok, result = pcall(function()
        return PRIVATE_KEY:sign(message, algorithm)
    end)

    if not ok then
        logger.error("Sign failed:", json.encode({
            algorithm = algorithm,
            message_len = #message,
            error = result
        }))
        return nil, "sign failed"
    end

    return result
end
```

## 生成密钥对

本模块不提供密钥生成功能，请使用 OpenSSL 命令行工具：

### 生成 RSA 密钥对

```bash
# 生成 2048 位私钥
openssl genrsa -out private.pem 2048

# 从私钥提取公钥
openssl rsa -in private.pem -pubout -out public.pem

# 生成加密的私钥（使用密码保护）
openssl genrsa -aes256 -out encrypted_private.pem 2048
```

### 生成 ECDSA 密钥对

```bash
# 生成 P-256 曲线私钥
openssl ecparam -genkey -name prime256v1 -out ec_private.pem

# 从私钥提取公钥
openssl ec -in ec_private.pem -pubout -out ec_public.pem

# 其他常用曲线：
# - secp256k1（比特币使用）
# - prime256v1（P-256，NIST 标准）
# - secp384r1（P-384，更高安全性）
```

### 转换密钥格式

```bash
# PKCS#1 转 PKCS#8
openssl pkcs8 -topk8 -inform PEM -outform PEM -in private.pem -out private_pkcs8.pem -nocrypt

# 查看密钥信息
openssl rsa -in private.pem -text -noout
openssl ec -in ec_private.pem -text -noout
```

## 参见

- [silly.security.jwt](../security/jwt.md) - JWT 令牌（使用 pkey 进行 RS256/ES256 签名）
- [silly.crypto.hmac](./hmac.md) - HMAC 消息认证码（对称签名）
- [silly.crypto.hash](./hash.md) - 哈希函数（SHA256、SHA512 等）
- [silly.encoding.base64](../encoding/base64.md) - Base64 编码（用于签名的传输编码）

## 标准参考

- [PKCS #1: RSA Cryptography Specifications](https://tools.ietf.org/html/rfc8017)
- [SEC 1: Elliptic Curve Cryptography](https://www.secg.org/sec1-v2.pdf)
- [FIPS 186-4: Digital Signature Standard (DSS)](https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.186-4.pdf)
- [OpenSSL EVP Documentation](https://www.openssl.org/docs/man1.1.1/man3/EVP_DigestSign.html)
