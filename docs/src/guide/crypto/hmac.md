---
title: HMAC
icon: fa6-solid:lock
---
## API参考

### 导入模块

```lua validate
local hmac = require "silly.crypto.hmac"
```

### 计算HMAC值

> hmac.digest(key, message, algorithm)

使用指定的算法和密钥计算消息的HMAC值。

参数:
- algorithm: 哈希算法名称(如 "sha256"、"sha512"等)
- key: HMAC密钥
- message: 要认证的消息

返回:
- mac: HMAC值(二进制字符串)

## 使用示例

### 基本使用

```lua validate
local hmac = require "silly.crypto.hmac"

local key = "secret key"
local message = "Hello World"
local mac = hmac.digest(key, message, "sha256")

-- 将结果转换为十六进制显示
local str = string.gsub(mac, ".", function(c)
	return string.format("%x", c:byte(1))
end)
print(str)
```

### 验证HMAC

```lua validate
local hmac = require "silly.crypto.hmac"

local function verify_hmac(key, message, received_mac)
    local computed_mac = hmac.digest(key, message, "sha256")
    return computed_mac == received_mac
end

local key = "secret key"
local message = "Hello World"

-- 计算HMAC
local mac = hmac.digest(key, message, "sha256")

-- 验证HMAC
local is_valid = verify_hmac(key, message, mac)
print(is_valid) -- 输出: true

-- 验证被篡改的消息
local is_valid = verify_hmac(key, message .. "!", mac)
print(is_valid) -- 输出: false
```

### 使用不同的哈希算法

```lua validate
local hmac = require "silly.crypto.hmac"

local key = "secret key"
local message = "Hello World"

-- 使用SHA-256
local mac1 = hmac.digest(key, message, "sha256")

-- 使用SHA-512
local mac2 = hmac.digest(key, message, "sha512")

-- 使用SHA3-256
local mac3 = hmac.digest(key, message, "sha3-256")
```
