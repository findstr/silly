---
title: Cipher
icon: fa6-solid:lock
---
## API参考

### 导入模块
```lua validate
local cipher = require "core.crypto.cipher"
```

### 创建加密器
```lua
local encryptor = cipher.encryptor(algorithm, key [, iv])
```

创建一个用于加密的cipher对象。

参数:
- algorithm: 加密算法名称(如 "aes-128-cbc"、"aes-256-gcm"等)
- key: 加密密钥
- iv: 初始化向量(可选,取决于算法)

### 创建解密器

```lua
local decryptor = cipher.decryptor(algorithm, key [, iv])
```

创建一个用于解密的`cipher`对象。

参数同`encryptor`。

### Cipher对象方法

> cipher:update(data)

向cipher对象添加需要处理的数据。

参数:
- data: 要加密/解密的数据


> cipher:final([data])

完成加密/解密过程并返回结果。

参数:
- data: 最后一块要处理的数据(可选)

返回:
- result: 加密/解密后的数据

> cipher:reset(key, iv)

使用新的密钥和IV重置cipher对象。

参数:
- key: 新的密钥
- iv: 新的初始化向量

> cipher:setpadding(padding)

设置是否使用PKCS7填充。

参数:
- padding: 1启用填充,0禁用填充

### AEAD相关方法

> cipher:setaad(aad)

设置AEAD模式的额外认证数据。

参数:
- aad: 认证数据

> cipher:settag(tag)

设置AEAD模式解密时使用的认证标签。

参数:
- tag: 认证标签

> cipher:tag()

获取AEAD模式加密后生成的认证标签。

返回:
- tag: 认证标签

## 使用示例

### 基本加解密

```lua validate
local cipher = require "core.crypto.cipher"

-- 创建AES-128-CBC加密器
local key = "1234567890123456" -- 16字节密钥
local iv = "1234567890123456"  -- 16字节IV
local encryptor = cipher.encryptor("aes-128-cbc", key, iv)

-- 加密数据
encryptor:update("Hello")
encryptor:update(" ")
local ciphertext = encryptor:final("World")

-- 创建解密器
local decryptor = cipher.decryptor("aes-128-cbc", key, iv)
decryptor:update(ciphertext)
local plaintext = decryptor:final()
print(plaintext) -- 输出: Hello World
```

### AEAD模式(GCM)示例

```lua validate
local cipher = require "core.crypto.cipher"

-- 创建AES-256-GCM加密器
local key = string.rep("k", 32) -- 32字节密钥
local iv = string.rep("i", 12)  -- 12字节随机数
local aad = "header" -- 额外认证数据

local enc = cipher.encryptor("aes-256-gcm", key, iv)
enc:setaad(aad)
enc:update("secret message")
local ciphertext = enc:final()
local tag = enc:tag()

-- 解密
local dec = cipher.decryptor("aes-256-gcm", key, iv)
dec:setaad(aad)
dec:settag(tag)
dec:update(ciphertext)
local plaintext = dec:final()
print(plaintext) -- 输出: secret message
```
