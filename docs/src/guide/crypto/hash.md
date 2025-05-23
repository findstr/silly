---
title: Hash
icon: fa6-solid:lock
---

# 哈希模块

哈希模块提供了基于OpenSSL的密码学哈希函数功能。哈希函数可以将任意长度的数据映射为固定长度的散列值。

## 常见的哈希算法包括:

- MD5 (不再推荐使用)
- SHA-1 (不再推荐使用)
- SHA-256/SHA-384/SHA-512 (SHA-2系列)
- SHA3-256/SHA3-384/SHA3-512 (SHA-3系列)

## API参考

### 导入模块

```lua validate
local hash = require "core.crypto.hash"
```

### 一次性计算哈希

> hash.hash(algorithm, data)

对数据进行一次性哈希计算。

参数:
- algorithm: openssl支持的所有哈希算法名称
- data: 要计算哈希的数据

返回:
- digest: 哈希值

### 创建哈希对象

> hash.new(algorithm)

创建一个新的哈希对象。

参数:
- algorithm: openssl支持的所有哈希算法名称

### Hash对象方法

> hasher:update(data)

向哈希对象添加要处理的数据。

参数:
- data: 要计算哈希的数据

> hasher:final()

完成哈希计算并返回最终的哈希值。

返回:
- digest: 哈希值

> hasher:reset()

重置哈希对象状态,可以重新使用。

> hasher:digest(data)

使用当前哈希对象对数据进行一次性哈希计算。

参数:
- data: 要计算哈希的数据

返回:
- digest: 哈希值

## 使用示例

### 一次性计算哈希

```lua validate
local hash = require "core.crypto.hash"

local data = "Hello World"
local digest = hash.hash("sha256", data)
local str = string.gsub(digest, ".", function(c)
	return string.format("%x", c:byte(1))
end)
print(str)
```

### 分块计算哈希

```lua validate
local hash = require "core.crypto.hash"

-- 创建SHA-256哈希对象
local hasher = hash.new("sha256")

-- 分块更新数据
hasher:update("Hello")
hasher:update(" ")
hasher:update("World")

-- 获取最终哈希值
local digest = hasher:final()
local str = string.gsub(digest, ".", function(c)
	return string.format("%x", c:byte(1))
end)
print(str)

-- 重置后可以重新使用
hasher:reset()
hasher:update("New Data")
local new_digest = hasher:final()
local str = string.gsub(new_digest, ".", function(c)
	return string.format("%x", c:byte(1))
end)
print(str)
```
