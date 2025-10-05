---
title: Hash（哈希函数）
icon: hashtag
category:
  - API 参考
tag:
  - 加密
  - 哈希
  - SHA256
  - MD5
  - 摘要
---

# silly.crypto.hash

哈希函数是一种单向密码学函数，能够将任意长度的输入数据转换为固定长度的输出（哈希值或摘要）。哈希函数广泛应用于数据完整性校验、密码存储、数字签名、区块链等场景。

## 概述

`silly.crypto.hash` 模块基于 OpenSSL EVP 接口实现，提供了完整的哈希计算功能，支持所有 OpenSSL 支持的哈希算法：

- **SHA-2 系列**（SHA-256、SHA-384、SHA-512）：现代密码学标准，推荐使用
- **SHA-1**：已被弱化，不推荐用于安全场景
- **MD5**：已被破解，仅用于非安全场景（如校验和）
- **SHA-3 系列**（SHA3-256、SHA3-384、SHA3-512）：最新标准（需 OpenSSL 1.1.1+）
- **BLAKE2**（BLAKE2s256、BLAKE2b512）：高性能哈希算法
- **其他算法**：RIPEMD-160、WHIRLPOOL 等

哈希函数具有以下特性：

1. **确定性**：相同输入总是产生相同输出
2. **不可逆**：无法从哈希值反推原始数据
3. **雪崩效应**：输入的微小变化导致输出完全不同
4. **抗碰撞性**：极难找到两个不同输入产生相同哈希值

## 模块导入

```lua validate
local hash = require "silly.crypto.hash"
```

## 核心概念

### 哈希值与摘要

哈希值（Hash）也称为消息摘要（Message Digest），是输入数据的"数字指纹"。不同算法产生不同长度的哈希值：

| 算法 | 输出长度（字节） | 输出长度（十六进制字符） | 安全性 | 应用场景 |
|------|------------------|--------------------------|--------|----------|
| MD5 | 16 | 32 | 已破解 | 文件校验、非安全场景 |
| SHA-1 | 20 | 40 | 弱化 | 遗留系统兼容 |
| SHA-256 | 32 | 64 | 高 | 密码存储、数字签名 |
| SHA-384 | 48 | 96 | 高 | 高安全需求 |
| SHA-512 | 64 | 128 | 高 | 高安全需求 |
| SHA3-256 | 32 | 64 | 极高 | 最新标准应用 |
| BLAKE2b512 | 64 | 128 | 极高 | 高性能场景 |

### 哈希碰撞

哈希碰撞是指两个不同的输入产生相同的哈希值。理想的哈希函数应具有极强的抗碰撞性：

- **MD5**：已被证明存在实用性碰撞攻击
- **SHA-1**：理论上已被攻破，存在碰撞风险
- **SHA-256/SHA-3**：目前无已知碰撞攻击

### 雪崩效应

哈希函数的雪崩效应指输入数据的微小变化会导致输出完全不同：

```
输入1: "hello world"  -> SHA-256: b94d27b9934d3e08...
输入2: "hello worlD"  -> SHA-256: 5891b5b522d5df08...
```

仅改变一个字符，输出的哈希值完全不同。

### 流式哈希计算

对于大文件或流式数据，可以分块计算哈希：

1. 创建哈希上下文（`hash.new()`）
2. 分块更新数据（`hash:update()`）
3. 获取最终结果（`hash:final()`）

这种方式避免了将整个文件加载到内存。

## API 参考

### hash.new(algorithm)

创建一个新的哈希计算上下文。

- **参数**:
  - `algorithm`: `string` - 哈希算法名称（不区分大小写）
    - 常用算法：`"sha256"`, `"sha512"`, `"sha1"`, `"md5"`, `"sha3-256"`, `"blake2b512"`
    - 完整列表取决于 OpenSSL 版本，可通过 `openssl list -digest-algorithms` 查看
- **返回值**:
  - 成功: `userdata` - 哈希上下文对象
  - 失败: 抛出错误（算法不支持或初始化失败）
- **示例**:

```lua validate
local hash = require "silly.crypto.hash"

-- 创建 SHA-256 哈希上下文
local h = hash.new("sha256")

-- 创建 MD5 哈希上下文
local h_md5 = hash.new("md5")

-- 尝试创建不存在的算法（会抛出错误）
local ok, err = pcall(function()
    return hash.new("invalid_algorithm")
end)
if not ok then
    print("算法不支持:", err)
end
```

### hash:update(data)

向哈希上下文添加数据进行计算。可以多次调用以分块处理数据。

- **参数**:
  - `data`: `string` - 要哈希的数据（支持二进制数据）
- **返回值**: 无返回值
- **注意**:
  - 可以多次调用 `update()`，效果等同于将所有数据拼接后一次性计算
  - 数据是二进制安全的，可以包含 `\0` 等特殊字符
- **示例**:

```lua validate
local hash = require "silly.crypto.hash"

local h = hash.new("sha256")

-- 单次更新
h:update("hello world")

-- 分块更新（效果相同）
local h2 = hash.new("sha256")
h2:update("hello")
h2:update(" ")
h2:update("world")

-- 两种方式产生相同的哈希值
local result1 = h:final()
local result2 = h2:final()
-- result1 == result2
```

### hash:final()

完成哈希计算并返回最终结果。

- **参数**: 无
- **返回值**: `string` - 原始二进制格式的哈希值（非十六进制字符串）
- **注意**:
  - 调用 `final()` 后，哈希上下文仍然可用
  - 如需重新计算，调用 `reset()` 或直接调用 `digest()`
  - 返回的是二进制数据，通常需要转换为十六进制显示
- **示例**:

```lua validate
local hash = require "silly.crypto.hash"

local h = hash.new("sha256")
h:update("hello world")
local digest = h:final()

-- 将二进制哈希值转换为十六进制字符串
local function to_hex(str)
    return (str:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

local hex_digest = to_hex(digest)
print("SHA-256 哈希值:", hex_digest)
-- 输出: b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
```

### hash:reset()

重置哈希上下文到初始状态，可以重新开始计算。

- **参数**: 无
- **返回值**: 无
- **用途**: 复用哈希上下文对象，避免重复创建
- **示例**:

```lua validate
local hash = require "silly.crypto.hash"

local h = hash.new("sha256")

-- 第一次计算
h:update("first data")
local result1 = h:final()

-- 重置并计算新数据
h:reset()
h:update("second data")
local result2 = h:final()

-- result1 和 result2 是不同数据的哈希值
```

### hash:digest(data)

便捷方法：自动重置上下文，计算给定数据的哈希值。

- **参数**:
  - `data`: `string` - 要哈希的数据
- **返回值**: `string` - 原始二进制格式的哈希值
- **等价操作**:
  ```lua
  h:reset()
  h:update(data)
  return h:final()
  ```
- **示例**:

```lua validate
local hash = require "silly.crypto.hash"

local h = hash.new("sha256")

-- 计算多个不同数据的哈希值
local hash1 = h:digest("data1")
local hash2 = h:digest("data2")
local hash3 = h:digest("data3")

-- 每次调用 digest() 都会自动重置上下文
```

### hash.hash(algorithm, data)

一次性计算哈希值的便捷函数。

- **参数**:
  - `algorithm`: `string` - 哈希算法名称
  - `data`: `string` - 要哈希的数据
- **返回值**: `string` - 原始二进制格式的哈希值
- **用途**: 适合一次性计算，无需创建上下文对象
- **示例**:

```lua validate
local hash = require "silly.crypto.hash"

-- 快速计算哈希值
local sha256_hash = hash.hash("sha256", "hello world")
local md5_hash = hash.hash("md5", "hello world")

-- 转换为十六进制
local function to_hex(str)
    return (str:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

print("SHA-256:", to_hex(sha256_hash))
print("MD5:", to_hex(md5_hash))
```

## 使用示例

### 基本用法：快速哈希计算

```lua validate
local hash = require "silly.crypto.hash"

-- 辅助函数：转换为十六进制
local function to_hex(str)
    return (str:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

-- 使用便捷函数计算 SHA-256
local data = "hello world"
local sha256 = hash.hash("sha256", data)
print("SHA-256:", to_hex(sha256))

-- 使用上下文对象
local h = hash.new("sha256")
h:update(data)
local result = h:final()
print("验证结果相同:", to_hex(result) == to_hex(sha256))
```

### 文件完整性校验

```lua validate
local hash = require "silly.crypto.hash"

-- 计算文件 SHA-256 校验和
local function file_checksum(filepath)
    local file = io.open(filepath, "rb")
    if not file then
        return nil, "无法打开文件"
    end

    local h = hash.new("sha256")
    local chunk_size = 4096

    while true do
        local chunk = file:read(chunk_size)
        if not chunk or #chunk == 0 then
            break
        end
        h:update(chunk)
    end

    file:close()

    local digest = h:final()
    return (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

-- 创建测试文件
local test_file = "/tmp/test_file.txt"
local f = io.open(test_file, "w")
f:write("This is a test file for checksum validation.")
f:close()

-- 计算校验和
local checksum = file_checksum(test_file)
print("文件 SHA-256 校验和:", checksum)

-- 清理测试文件
os.remove(test_file)
```

### 密码哈希（加盐）

```lua validate
local hash = require "silly.crypto.hash"

-- 简单的密码哈希函数（仅示例，生产环境建议使用 bcrypt/argon2）
local function hash_password(password, salt)
    -- 使用盐值防止彩虹表攻击
    salt = salt or string.format("%x", os.time() * math.random(1000000))

    -- 将盐值和密码拼接后哈希
    local salted = salt .. password
    local digest = hash.hash("sha256", salted)

    -- 将盐值和哈希值一起存储
    local hex_digest = (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    return salt .. ":" .. hex_digest
end

-- 验证密码
local function verify_password(password, stored_hash)
    local salt, expected_hash = stored_hash:match("^([^:]+):(.+)$")
    if not salt then
        return false
    end

    local salted = salt .. password
    local digest = hash.hash("sha256", salted)
    local hex_digest = (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    return hex_digest == expected_hash
end

-- 使用示例
local password = "MySecurePassword123!"
local stored = hash_password(password)
print("存储的哈希:", stored)

local is_valid = verify_password(password, stored)
print("密码验证:", is_valid and "成功" or "失败")

local is_invalid = verify_password("WrongPassword", stored)
print("错误密码验证:", is_invalid and "成功（异常）" or "失败（正常）")
```

### 数据去重（内容寻址）

```lua validate
local hash = require "silly.crypto.hash"

-- 内容寻址存储系统（类似 Git 的对象存储）
local content_store = {}

local function to_hex(str)
    return (str:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

-- 根据内容哈希存储数据
local function store_content(data)
    local digest = hash.hash("sha256", data)
    local content_id = to_hex(digest)

    -- 如果已存在相同内容，不重复存储
    if content_store[content_id] then
        return content_id, false  -- 已存在
    end

    content_store[content_id] = data
    return content_id, true  -- 新存储
end

-- 根据哈希值检索内容
local function retrieve_content(content_id)
    return content_store[content_id]
end

-- 使用示例
local data1 = "Hello, World!"
local data2 = "Hello, World!"  -- 相同内容
local data3 = "Different content"

local id1, new1 = store_content(data1)
print("存储 data1:", id1, new1 and "(新)" or "(已存在)")

local id2, new2 = store_content(data2)
print("存储 data2:", id2, new2 and "(新)" or "(已存在)")
print("内容去重成功:", id1 == id2)

local id3, new3 = store_content(data3)
print("存储 data3:", id3, new3 and "(新)" or "(已存在)")

-- 检索内容
local retrieved = retrieve_content(id1)
print("检索内容:", retrieved)
```

### 哈希链（区块链基础）

```lua validate
local hash = require "silly.crypto.hash"

-- 简单的区块链结构
local Block = {}
Block.__index = Block

function Block.new(index, data, previous_hash)
    local self = setmetatable({}, Block)
    self.index = index
    self.timestamp = os.time()
    self.data = data
    self.previous_hash = previous_hash or "0"
    self.hash = self:calculate_hash()
    return self
end

function Block:calculate_hash()
    local content = string.format("%d|%d|%s|%s",
        self.index, self.timestamp, self.data, self.previous_hash)
    local digest = hash.hash("sha256", content)
    return (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

-- 创建区块链
local blockchain = {}

-- 创世区块
local genesis = Block.new(0, "Genesis Block")
table.insert(blockchain, genesis)

-- 添加新区块
local function add_block(data)
    local previous = blockchain[#blockchain]
    local new_block = Block.new(#blockchain, data, previous.hash)
    table.insert(blockchain, new_block)
end

-- 验证区块链完整性
local function validate_chain()
    for i = 2, #blockchain do
        local current = blockchain[i]
        local previous = blockchain[i - 1]

        -- 验证当前区块哈希
        if current.hash ~= current:calculate_hash() then
            return false, "区块 " .. i .. " 哈希无效"
        end

        -- 验证链接
        if current.previous_hash ~= previous.hash then
            return false, "区块 " .. i .. " 链接断裂"
        end
    end
    return true
end

-- 使用示例
add_block("Transaction 1: Alice -> Bob: 10 BTC")
add_block("Transaction 2: Bob -> Charlie: 5 BTC")
add_block("Transaction 3: Charlie -> Alice: 3 BTC")

print("区块链长度:", #blockchain)
for i, block in ipairs(blockchain) do
    print(string.format("区块 #%d: %s", block.index, block.hash:sub(1, 16) .. "..."))
end

local valid, err = validate_chain()
print("区块链验证:", valid and "通过" or ("失败: " .. err))
```

### 多算法比较

```lua validate
local hash = require "silly.crypto.hash"

-- 比较不同哈希算法的性能和输出
local function compare_algorithms(data)
    local algorithms = {"md5", "sha1", "sha256", "sha512"}
    local results = {}

    local function to_hex(str)
        return (str:gsub('.', function(c)
            return string.format('%02x', string.byte(c))
        end))
    end

    for _, alg in ipairs(algorithms) do
        local start = os.clock()
        local digest = hash.hash(alg, data)
        local elapsed = os.clock() - start

        results[alg] = {
            hex = to_hex(digest),
            length = #digest,
            time = elapsed
        }
    end

    return results
end

-- 测试数据
local test_data = string.rep("a", 1000000)  -- 1MB 数据

print("测试数据大小:", #test_data, "字节")
local results = compare_algorithms(test_data)

print("\n算法比较:")
for alg, info in pairs(results) do
    print(string.format("%-10s | 长度: %2d字节 | 哈希: %s...",
        alg:upper(), info.length, info.hex:sub(1, 32)))
end
```

### 分块流式哈希

```lua validate
local hash = require "silly.crypto.hash"

-- 模拟流式数据处理（如网络传输、日志追加）
local function stream_hash_example()
    local h = hash.new("sha256")
    local chunks = {
        "chunk1: hello ",
        "chunk2: world ",
        "chunk3: from ",
        "chunk4: silly ",
        "chunk5: framework"
    }

    print("流式处理数据:")
    for i, chunk in ipairs(chunks) do
        print("  处理分块", i, ":", chunk)
        h:update(chunk)
    end

    local digest = h:final()
    local hex_digest = (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    print("最终哈希值:", hex_digest)

    -- 验证：完整数据的哈希应该相同
    local full_data = table.concat(chunks)
    local full_hash = hash.hash("sha256", full_data)
    local full_hex = (full_hash:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    print("验证一致性:", hex_digest == full_hex)
    return hex_digest
end

stream_hash_example()
```

### 哈希上下文复用

```lua validate
local hash = require "silly.crypto.hash"

-- 复用哈希上下文处理多个数据
local function batch_hash(data_list)
    local h = hash.new("sha256")
    local results = {}

    local function to_hex(str)
        return (str:gsub('.', function(c)
            return string.format('%02x', string.byte(c))
        end))
    end

    for i, data in ipairs(data_list) do
        -- 使用 digest() 自动重置上下文
        local digest = h:digest(data)
        results[i] = to_hex(digest)
    end

    return results
end

-- 批量处理
local data_list = {
    "user_001@example.com",
    "user_002@example.com",
    "user_003@example.com",
    "user_004@example.com",
}

print("批量哈希处理:")
local hashes = batch_hash(data_list)
for i, email in ipairs(data_list) do
    print(string.format("  %s -> %s", email, hashes[i]:sub(1, 16) .. "..."))
end
```

### 二进制数据哈希

```lua validate
local hash = require "silly.crypto.hash"

-- 处理包含特殊字符的二进制数据
local function binary_data_hash()
    -- 二进制数据（包含 NULL 字节和控制字符）
    local binary_data = "\x00\x01\x02\x03\xFF\xFE\xFD\xFC"

    local digest = hash.hash("sha256", binary_data)

    -- 转换为十六进制
    local hex_digest = (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    -- 显示原始数据（十六进制格式）
    local hex_input = (binary_data:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    print("输入（十六进制）:", hex_input)
    print("SHA-256 哈希:", hex_digest)

    -- 验证二进制安全性
    local h = hash.new("sha256")
    h:update("\x00")
    h:update("\x01\x02\x03")
    h:update("\xFF\xFE\xFD\xFC")
    local digest2 = h:final()

    print("分块计算一致:", digest == digest2)
end

binary_data_hash()
```

## 注意事项

### 算法选择建议

1. **安全性优先**
   - **推荐**: SHA-256, SHA-512, SHA3-256, BLAKE2b
   - **避免**: MD5（已破解）, SHA-1（弱化）
   - 对于新项目，优先选择 SHA-256

2. **性能考虑**
   - SHA-256：安全性和性能的良好平衡
   - BLAKE2b：比 SHA-2 更快，同等安全性
   - SHA-512：在 64 位系统上性能优于 SHA-256
   - MD5：最快，但仅用于非安全场景

3. **应用场景**
   - **密码存储**: 使用 bcrypt、scrypt 或 argon2（非本模块）
   - **文件完整性**: SHA-256 或 BLAKE2b
   - **数字签名**: SHA-256 或 SHA-512
   - **数据去重**: SHA-256 或 BLAKE2b
   - **非安全校验**: MD5 或 CRC32

### 哈希值编码

模块返回的是原始二进制数据，通常需要编码为可读格式：

```lua
-- 十六进制编码（最常用）
local function to_hex(str)
    return (str:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

-- Base64 编码（需要 base64 模块）
-- local base64 = require "silly.encoding.base64"
-- local b64_hash = base64.encode(digest)
```

### 密码存储警告

**不要直接使用哈希函数存储密码！** 应该使用专门的密码哈希算法：

- **问题**: 简单哈希易受彩虹表攻击和暴力破解
- **解决方案**:
  - 使用 bcrypt、scrypt 或 argon2（需要额外模块）
  - 如果必须使用哈希函数，至少要加盐并进行多轮迭代

```lua
-- 错误示例（不安全）
local bad = hash.hash("sha256", password)

-- 改进示例（加盐，但仍不如 bcrypt）
local salt = generate_random_salt()
local better = hash.hash("sha256", salt .. password)
-- 存储时保存: salt:hash

-- 最佳实践（伪代码）
-- local bcrypt = require "bcrypt"
-- local secure = bcrypt.hash(password, bcrypt.gensalt(12))
```

### 性能优化

1. **复用哈希上下文**
   ```lua
   -- 好：复用上下文
   local h = hash.new("sha256")
   for _, data in ipairs(data_list) do
       local result = h:digest(data)
   end

   -- 差：每次创建新上下文
   for _, data in ipairs(data_list) do
       local h = hash.new("sha256")
       local result = h:digest(data)
   end
   ```

2. **流式处理大文件**
   ```lua
   -- 好：分块读取
   local h = hash.new("sha256")
   while true do
       local chunk = file:read(4096)
       if not chunk then break end
       h:update(chunk)
   end

   -- 差：一次性加载
   local data = file:read("*a")  -- 可能导致内存不足
   hash.hash("sha256", data)
   ```

3. **算法缓存**
   - 模块内部会缓存算法对象（`EVP_MD`）
   - 相同算法名称的多次调用会复用缓存

### OpenSSL 版本兼容性

不同 OpenSSL 版本支持的算法不同：

- **OpenSSL 1.0.x**: MD5, SHA-1, SHA-256, SHA-512, RIPEMD-160
- **OpenSSL 1.1.0+**: 增加 BLAKE2b, BLAKE2s
- **OpenSSL 1.1.1+**: 增加 SHA3 系列

可以通过以下命令查看系统支持的算法：

```bash
openssl list -digest-algorithms
```

### 常见错误

| 错误信息 | 原因 | 解决方法 |
|---------|------|---------|
| `unknown digest method: 'xxx'` | 算法名称错误或不支持 | 检查算法名称拼写，确认 OpenSSL 版本 |
| `hash update error` | 上下文已损坏 | 重新创建哈希上下文 |
| `hash final error` | 上下文状态异常 | 检查是否已调用 `final()` 后未重置 |

## 最佳实践

### 1. 使用常量定义算法名称

```lua
local hash = require "silly.crypto.hash"

-- 定义常量避免拼写错误
local ALGORITHM = {
    SHA256 = "sha256",
    SHA512 = "sha512",
    MD5 = "md5",
}

local h = hash.new(ALGORITHM.SHA256)
```

### 2. 封装辅助函数

```lua
local hash = require "silly.crypto.hash"

-- 创建工具模块
local HashUtil = {}

function HashUtil.hex(data, algorithm)
    algorithm = algorithm or "sha256"
    local digest = hash.hash(algorithm, data)
    return (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

function HashUtil.file(filepath, algorithm)
    algorithm = algorithm or "sha256"
    local file = io.open(filepath, "rb")
    if not file then
        return nil, "file not found"
    end

    local h = hash.new(algorithm)
    while true do
        local chunk = file:read(4096)
        if not chunk then break end
        h:update(chunk)
    end
    file:close()

    local digest = h:final()
    return (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

-- 使用封装后的函数
local hex_hash = HashUtil.hex("hello world")
print("SHA-256:", hex_hash)
```

### 3. 实现哈希缓存

```lua
local hash = require "silly.crypto.hash"

-- 避免重复计算相同数据的哈希
local hash_cache = {}

local function cached_hash(data, algorithm)
    algorithm = algorithm or "sha256"
    local cache_key = algorithm .. ":" .. data

    if hash_cache[cache_key] then
        return hash_cache[cache_key]
    end

    local digest = hash.hash(algorithm, data)
    hash_cache[cache_key] = digest
    return digest
end
```

### 4. 错误处理模式

```lua
local hash = require "silly.crypto.hash"

-- 安全的哈希计算函数
local function safe_hash(algorithm, data)
    local ok, result = pcall(function()
        return hash.hash(algorithm, data)
    end)

    if not ok then
        return nil, "hash calculation failed: " .. tostring(result)
    end

    return result
end

-- 使用示例
local digest, err = safe_hash("sha256", "test data")
if not digest then
    print("错误:", err)
else
    print("成功")
end
```

### 5. 文档化使用场景

```lua
--[[
用户数据指纹生成器

使用 SHA-256 为用户数据生成唯一标识符，用于：
1. 去重检测
2. 隐私保护（不直接存储原始数据）
3. 快速查找

注意：不适用于密码存储，密码请使用 bcrypt
]]
local function generate_user_fingerprint(user_data)
    local normalized = string.lower(user_data.email)
    return hash.hash("sha256", normalized)
end
```

## 参见

- [silly.crypto.hmac](./hmac.md) - HMAC 消息认证码（带密钥的哈希）
- [silly.crypto.pkey](./pkey.md) - 公私钥加密（包含签名功能）
- [silly.security.jwt](../security/jwt.md) - JWT 令牌（使用哈希和 HMAC）
- [silly.encoding.base64](../encoding/base64.md) - Base64 编码（用于哈希值编码）

## 标准参考

- [FIPS 180-4](https://csrc.nist.gov/publications/detail/fips/180/4/final) - SHA-2 标准
- [FIPS 202](https://csrc.nist.gov/publications/detail/fips/202/final) - SHA-3 标准
- [RFC 1321](https://tools.ietf.org/html/rfc1321) - MD5 算法
- [RFC 3174](https://tools.ietf.org/html/rfc3174) - SHA-1 算法
- [BLAKE2](https://www.blake2.net/) - BLAKE2 官方文档
- [OpenSSL EVP](https://www.openssl.org/docs/man3.0/man7/evp.html) - OpenSSL EVP 接口文档
