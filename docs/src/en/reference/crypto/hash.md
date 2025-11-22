---
title: Hash (Hash Functions)
icon: hashtag
category:
  - API Reference
tag:
  - Encryption
  - Hash
  - SHA256
  - MD5
  - Digest
---

# silly.crypto.hash

Hash functions are one-way cryptographic functions that can convert input data of any length into fixed-length output (hash value or digest). Hash functions are widely used in data integrity checking, password storage, digital signatures, blockchain, and other scenarios.

## Overview

The `silly.crypto.hash` module is implemented based on the OpenSSL EVP interface, providing complete hash calculation capabilities and supporting all hash algorithms supported by OpenSSL:

- **SHA-2 Series** (SHA-256, SHA-384, SHA-512): Modern cryptographic standards, recommended for use
- **SHA-1**: Has been weakened, not recommended for security scenarios
- **MD5**: Has been cracked, only for non-security scenarios (such as checksums)
- **SHA-3 Series** (SHA3-256, SHA3-384, SHA3-512): Latest standard (requires OpenSSL 1.1.1+)
- **BLAKE2** (BLAKE2s256, BLAKE2b512): High-performance hash algorithm
- **Other Algorithms**: RIPEMD-160, WHIRLPOOL, etc.

Hash functions have the following characteristics:

1. **Deterministic**: Same input always produces same output
2. **Irreversible**: Cannot derive original data from hash value
3. **Avalanche Effect**: Small changes in input cause completely different output
4. **Collision Resistance**: Extremely difficult to find two different inputs that produce the same hash value

## Module Import

```lua validate
local hash = require "silly.crypto.hash"
```

## Core Concepts

### Hash Values and Digests

Hash values (Hash), also called message digests (Message Digest), are the "digital fingerprint" of input data. Different algorithms produce hash values of different lengths:

| Algorithm | Output Length (bytes) | Output Length (hex characters) | Security | Use Cases |
|-----------|----------------------|-------------------------------|----------|-----------|
| MD5 | 16 | 32 | Broken | File checking, non-security scenarios |
| SHA-1 | 20 | 40 | Weakened | Legacy system compatibility |
| SHA-256 | 32 | 64 | High | Password storage, digital signatures |
| SHA-384 | 48 | 96 | High | High security requirements |
| SHA-512 | 64 | 128 | High | High security requirements |
| SHA3-256 | 32 | 64 | Very High | Latest standard applications |
| BLAKE2b512 | 64 | 128 | Very High | High performance scenarios |

### Hash Collisions

Hash collision refers to two different inputs producing the same hash value. An ideal hash function should have extremely strong collision resistance:

- **MD5**: Proven to have practical collision attacks
- **SHA-1**: Theoretically broken, collision risks exist
- **SHA-256/SHA-3**: Currently no known collision attacks

### Avalanche Effect

The avalanche effect of hash functions means that small changes in input data cause completely different output:

```
Input1: "hello world"  -> SHA-256: b94d27b9934d3e08...
Input2: "hello worlD"  -> SHA-256: 5891b5b522d5df08...
```

Changing just one character results in completely different hash output.

### Stream Hash Calculation

For large files or streaming data, hash can be calculated in chunks:

1. Create hash context (`hash.new()`)
2. Update data in chunks (`hash:update()`)
3. Get final result (`hash:final()`)

This approach avoids loading the entire file into memory.

## API Reference

### hash.new(algorithm)

Creates a new hash computation context.

- **Parameters**:
  - `algorithm`: `string` - Hash algorithm name (case insensitive)
    - Common algorithms: `"sha256"`, `"sha512"`, `"sha1"`, `"md5"`, `"sha3-256"`, `"blake2b512"`
    - Complete list depends on OpenSSL version, can view via `openssl list -digest-algorithms`
- **Returns**:
  - Success: `userdata` - Hash context object
  - Failure: Throws error (algorithm not supported or initialization failed)
- **Example**:

```lua validate
local hash = require "silly.crypto.hash"

-- Create SHA-256 hash context
local h = hash.new("sha256")

-- Create MD5 hash context
local h_md5 = hash.new("md5")

-- Attempt to create non-existent algorithm (will throw error)
local ok, err = pcall(function()
    return hash.new("invalid_algorithm")
end)
if not ok then
    print("Algorithm not supported:", err)
end
```

### hash:update(data)

Adds data to hash context for computation. Can be called multiple times to process data in chunks.

- **Parameters**:
  - `data`: `string` - Data to hash (supports binary data)
- **Returns**: No return value
- **Notes**:
  - Can call `update()` multiple times, effect is equivalent to concatenating all data and computing once
  - Data is binary-safe, can contain special characters like `\0`
- **Example**:

```lua validate
local hash = require "silly.crypto.hash"

local h = hash.new("sha256")

-- Single update
h:update("hello world")

-- Chunk updates (same effect)
local h2 = hash.new("sha256")
h2:update("hello")
h2:update(" ")
h2:update("world")

-- Both methods produce the same hash value
local result1 = h:final()
local result2 = h2:final()
-- result1 == result2
```

### hash:final()

Completes hash computation and returns final result.

- **Parameters**: None
- **Returns**: `string` - Hash value in raw binary format (not hex string)
- **Notes**:
  - After calling `final()`, hash context is still usable
  - To compute again, call `reset()` or directly call `digest()`
  - Returned data is binary, usually needs to be converted to hex for display
- **Example**:

```lua validate
local hash = require "silly.crypto.hash"

local h = hash.new("sha256")
h:update("hello world")
local digest = h:final()

-- Convert binary hash value to hex string
local function to_hex(str)
    return (str:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

local hex_digest = to_hex(digest)
print("SHA-256 hash value:", hex_digest)
-- Output: b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
```

### hash:reset()

Resets hash context to initial state, can start new computation.

- **Parameters**: None
- **Returns**: None
- **Purpose**: Reuse hash context object to avoid repeated creation
- **Example**:

```lua validate
local hash = require "silly.crypto.hash"

local h = hash.new("sha256")

-- First computation
h:update("first data")
local result1 = h:final()

-- Reset and compute new data
h:reset()
h:update("second data")
local result2 = h:final()

-- result1 and result2 are hash values of different data
```

### hash:digest(data)

Convenience method: automatically resets context, computes hash value for given data.

- **Parameters**:
  - `data`: `string` - Data to hash
- **Returns**: `string` - Hash value in raw binary format
- **Equivalent Operation**:
  ```lua
  h:reset()
  h:update(data)
  return h:final()
  ```
- **Example**:

```lua validate
local hash = require "silly.crypto.hash"

local h = hash.new("sha256")

-- Compute hash values for multiple different data
local hash1 = h:digest("data1")
local hash2 = h:digest("data2")
local hash3 = h:digest("data3")

-- Each call to digest() automatically resets context
```

### hash.hash(algorithm, data)

One-time hash value computation convenience function.

- **Parameters**:
  - `algorithm`: `string` - Hash algorithm name
  - `data`: `string` - Data to hash
- **Returns**: `string` - Hash value in raw binary format
- **Purpose**: Suitable for one-time computation, no need to create context object
- **Example**:

```lua validate
local hash = require "silly.crypto.hash"

-- Quick hash computation
local sha256_hash = hash.hash("sha256", "hello world")
local md5_hash = hash.hash("md5", "hello world")

-- Convert to hex
local function to_hex(str)
    return (str:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

print("SHA-256:", to_hex(sha256_hash))
print("MD5:", to_hex(md5_hash))
```

## Usage Examples

### Basic Usage: Quick Hash Computation

```lua validate
local hash = require "silly.crypto.hash"

-- Helper function: Convert to hex
local function to_hex(str)
    return (str:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

-- Use convenience function to compute SHA-256
local data = "hello world"
local sha256 = hash.hash("sha256", data)
print("SHA-256:", to_hex(sha256))

-- Use context object
local h = hash.new("sha256")
h:update(data)
local result = h:final()
print("Verify results match:", to_hex(result) == to_hex(sha256))
```

### File Integrity Checking

```lua validate
local hash = require "silly.crypto.hash"

-- Compute file SHA-256 checksum
local function file_checksum(filepath)
    local file = io.open(filepath, "rb")
    if not file then
        return nil, "Cannot open file"
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

-- Create test file
local test_file = "/tmp/test_file.txt"
local f = io.open(test_file, "w")
f:write("This is a test file for checksum validation.")
f:close()

-- Compute checksum
local checksum = file_checksum(test_file)
print("File SHA-256 checksum:", checksum)

-- Clean up test file
os.remove(test_file)
```

### Password Hashing (with Salt)

```lua validate
local hash = require "silly.crypto.hash"

-- Simple password hash function (example only, recommend using bcrypt/argon2 in production)
local function hash_password(password, salt)
    -- Use salt to prevent rainbow table attacks
    salt = salt or string.format("%x", os.time() * math.random(1000000))

    -- Hash concatenated salt and password
    local salted = salt .. password
    local digest = hash.hash("sha256", salted)

    -- Store salt and hash together
    local hex_digest = (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    return salt .. ":" .. hex_digest
end

-- Verify password
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

-- Usage example
local password = "MySecurePassword123!"
local stored = hash_password(password)
print("Stored hash:", stored)

local is_valid = verify_password(password, stored)
print("Password verification:", is_valid and "Success" or "Failed")

local is_invalid = verify_password("WrongPassword", stored)
print("Wrong password verification:", is_invalid and "Success (abnormal)" or "Failed (normal)")
```

### Data Deduplication (Content-Addressed Storage)

```lua validate
local hash = require "silly.crypto.hash"

-- Content-addressed storage system (similar to Git object storage)
local content_store = {}

local function to_hex(str)
    return (str:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

-- Store data based on content hash
local function store_content(data)
    local digest = hash.hash("sha256", data)
    local content_id = to_hex(digest)

    -- Don't store duplicate content if exists
    if content_store[content_id] then
        return content_id, false  -- Already exists
    end

    content_store[content_id] = data
    return content_id, true  -- Newly stored
end

-- Retrieve content by hash value
local function retrieve_content(content_id)
    return content_store[content_id]
end

-- Usage example
local data1 = "Hello, World!"
local data2 = "Hello, World!"  -- Same content
local data3 = "Different content"

local id1, new1 = store_content(data1)
print("Store data1:", id1, new1 and "(new)" or "(already exists)")

local id2, new2 = store_content(data2)
print("Store data2:", id2, new2 and "(new)" or "(already exists)")
print("Deduplication successful:", id1 == id2)

local id3, new3 = store_content(data3)
print("Store data3:", id3, new3 and "(new)" or "(already exists)")

-- Retrieve content
local retrieved = retrieve_content(id1)
print("Retrieved content:", retrieved)
```

### Hash Chain (Blockchain Basics)

```lua validate
local hash = require "silly.crypto.hash"

-- Simple blockchain structure
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

-- Create blockchain
local blockchain = {}

-- Genesis block
local genesis = Block.new(0, "Genesis Block")
table.insert(blockchain, genesis)

-- Add new block
local function add_block(data)
    local previous = blockchain[#blockchain]
    local new_block = Block.new(#blockchain, data, previous.hash)
    table.insert(blockchain, new_block)
end

-- Validate blockchain integrity
local function validate_chain()
    for i = 2, #blockchain do
        local current = blockchain[i]
        local previous = blockchain[i - 1]

        -- Validate current block hash
        if current.hash ~= current:calculate_hash() then
            return false, "Block " .. i .. " hash invalid"
        end

        -- Validate link
        if current.previous_hash ~= previous.hash then
            return false, "Block " .. i .. " link broken"
        end
    end
    return true
end

-- Usage example
add_block("Transaction 1: Alice -> Bob: 10 BTC")
add_block("Transaction 2: Bob -> Charlie: 5 BTC")
add_block("Transaction 3: Charlie -> Alice: 3 BTC")

print("Blockchain length:", #blockchain)
for i, block in ipairs(blockchain) do
    print(string.format("Block #%d: %s", block.index, block.hash:sub(1, 16) .. "..."))
end

local valid, err = validate_chain()
print("Blockchain validation:", valid and "Passed" or ("Failed: " .. err))
```

### Multiple Algorithm Comparison

```lua validate
local hash = require "silly.crypto.hash"

-- Compare performance and output of different hash algorithms
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

-- Test data
local test_data = string.rep("a", 1000000)  -- 1MB data

print("Test data size:", #test_data, "bytes")
local results = compare_algorithms(test_data)

print("\nAlgorithm comparison:")
for alg, info in pairs(results) do
    print(string.format("%-10s | Length: %2d bytes | Hash: %s...",
        alg:upper(), info.length, info.hex:sub(1, 32)))
end
```

### Chunk Stream Hashing

```lua validate
local hash = require "silly.crypto.hash"

-- Simulate stream data processing (such as network transmission, log append)
local function stream_hash_example()
    local h = hash.new("sha256")
    local chunks = {
        "chunk1: hello ",
        "chunk2: world ",
        "chunk3: from ",
        "chunk4: silly ",
        "chunk5: framework"
    }

    print("Stream processing data:")
    for i, chunk in ipairs(chunks) do
        print("  Processing chunk", i, ":", chunk)
        h:update(chunk)
    end

    local digest = h:final()
    local hex_digest = (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    print("Final hash value:", hex_digest)

    -- Verification: Hash of complete data should be the same
    local full_data = table.concat(chunks)
    local full_hash = hash.hash("sha256", full_data)
    local full_hex = (full_hash:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    print("Verify consistency:", hex_digest == full_hex)
    return hex_digest
end

stream_hash_example()
```

### Hash Context Reuse

```lua validate
local hash = require "silly.crypto.hash"

-- Reuse hash context to process multiple data
local function batch_hash(data_list)
    local h = hash.new("sha256")
    local results = {}

    local function to_hex(str)
        return (str:gsub('.', function(c)
            return string.format('%02x', string.byte(c))
        end))
    end

    for i, data in ipairs(data_list) do
        -- Use digest() to automatically reset context
        local digest = h:digest(data)
        results[i] = to_hex(digest)
    end

    return results
end

-- Batch processing
local data_list = {
    "user_001@example.com",
    "user_002@example.com",
    "user_003@example.com",
    "user_004@example.com",
}

print("Batch hash processing:")
local hashes = batch_hash(data_list)
for i, email in ipairs(data_list) do
    print(string.format("  %s -> %s", email, hashes[i]:sub(1, 16) .. "..."))
end
```

### Binary Data Hashing

```lua validate
local hash = require "silly.crypto.hash"

-- Process binary data containing special characters
local function binary_data_hash()
    -- Binary data (includes NULL bytes and control characters)
    local binary_data = "\x00\x01\x02\x03\xFF\xFE\xFD\xFC"

    local digest = hash.hash("sha256", binary_data)

    -- Convert to hex
    local hex_digest = (digest:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    -- Display original data (hex format)
    local hex_input = (binary_data:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))

    print("Input (hex):", hex_input)
    print("SHA-256 hash:", hex_digest)

    -- Verify binary safety
    local h = hash.new("sha256")
    h:update("\x00")
    h:update("\x01\x02\x03")
    h:update("\xFF\xFE\xFD\xFC")
    local digest2 = h:final()

    print("Chunk computation consistent:", digest == digest2)
end

binary_data_hash()
```

## Notes

### Algorithm Selection Recommendations

1. **Security Priority**
   - **Recommended**: SHA-256, SHA-512, SHA3-256, BLAKE2b
   - **Avoid**: MD5 (broken), SHA-1 (weakened)
   - For new projects, prioritize SHA-256

2. **Performance Considerations**
   - SHA-256: Good balance of security and performance
   - BLAKE2b: Faster than SHA-2, equivalent security
   - SHA-512: Better performance than SHA-256 on 64-bit systems
   - MD5: Fastest, but only for non-security scenarios

3. **Application Scenarios**
   - **Password Storage**: Use bcrypt, scrypt or argon2 (not this module)
   - **File Integrity**: SHA-256 or BLAKE2b
   - **Digital Signatures**: SHA-256 or SHA-512
   - **Data Deduplication**: SHA-256 or BLAKE2b
   - **Non-Security Checksums**: MD5 or CRC32

### Hash Value Encoding

The module returns raw binary data, usually needs to be encoded to readable format:

```lua
-- Hex encoding (most common)
local function to_hex(str)
    return (str:gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
end

-- Base64 encoding (requires base64 module)
-- local base64 = require "silly.encoding.base64"
-- local b64_hash = base64.encode(digest)
```

### Password Storage Warning

**Do not use hash functions directly to store passwords!** Should use specialized password hashing algorithms:

- **Problem**: Simple hashing susceptible to rainbow table attacks and brute force
- **Solutions**:
  - Use bcrypt, scrypt or argon2 (requires additional modules)
  - If must use hash functions, at least add salt and perform multiple iterations

```lua
-- Wrong example (insecure)
local bad = hash.hash("sha256", password)

-- Improved example (add salt, but still not as good as bcrypt)
local salt = generate_random_salt()
local better = hash.hash("sha256", salt .. password)
-- Store: salt:hash

-- Best practice (pseudocode)
-- local bcrypt = require "bcrypt"
-- local secure = bcrypt.hash(password, bcrypt.gensalt(12))
```

### Performance Optimization

1. **Reuse Hash Context**
   ```lua
   -- Good: Reuse context
   local h = hash.new("sha256")
   for _, data in ipairs(data_list) do
       local result = h:digest(data)
   end

   -- Poor: Create new context each time
   for _, data in ipairs(data_list) do
       local h = hash.new("sha256")
       local result = h:digest(data)
   end
   ```

2. **Stream Process Large Files**
   ```lua
   -- Good: Read in chunks
   local h = hash.new("sha256")
   while true do
       local chunk = file:read(4096)
       if not chunk then break end
       h:update(chunk)
   end

   -- Poor: Load all at once
   local data = file:read("*a")  -- May cause out of memory
   hash.hash("sha256", data)
   ```

3. **Algorithm Caching**
   - Module internally caches algorithm objects (`EVP_MD`)
   - Multiple calls with same algorithm name reuse cache

### OpenSSL Version Compatibility

Different OpenSSL versions support different algorithms:

- **OpenSSL 1.0.x**: MD5, SHA-1, SHA-256, SHA-512, RIPEMD-160
- **OpenSSL 1.1.0+**: Adds BLAKE2b, BLAKE2s
- **OpenSSL 1.1.1+**: Adds SHA3 series

Can view supported algorithms via command:

```bash
openssl list -digest-algorithms
```

### Common Errors

| Error Message | Cause | Solution |
|--------------|-------|----------|
| `unknown digest method: 'xxx'` | Wrong algorithm name or not supported | Check algorithm name spelling, confirm OpenSSL version |
| `hash update error` | Context corrupted | Recreate hash context |
| `hash final error` | Context state abnormal | Check if already called `final()` without reset |

## Best Practices

### 1. Use Constants to Define Algorithm Names

```lua
local hash = require "silly.crypto.hash"

-- Define constants to avoid typos
local ALGORITHM = {
    SHA256 = "sha256",
    SHA512 = "sha512",
    MD5 = "md5",
}

local h = hash.new(ALGORITHM.SHA256)
```

### 2. Encapsulate Helper Functions

```lua
local hash = require "silly.crypto.hash"

-- Create utility module
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

-- Use encapsulated functions
local hex_hash = HashUtil.hex("hello world")
print("SHA-256:", hex_hash)
```

### 3. Implement Hash Caching

```lua
local hash = require "silly.crypto.hash"

-- Avoid repeatedly computing hash of same data
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

### 4. Error Handling Pattern

```lua
local hash = require "silly.crypto.hash"

-- Safe hash computation function
local function safe_hash(algorithm, data)
    local ok, result = pcall(function()
        return hash.hash(algorithm, data)
    end)

    if not ok then
        return nil, "hash calculation failed: " .. tostring(result)
    end

    return result
end

-- Usage example
local digest, err = safe_hash("sha256", "test data")
if not digest then
    print("Error:", err)
else
    print("Success")
end
```

### 5. Document Use Cases

```lua
--[[
User Data Fingerprint Generator

Uses SHA-256 to generate unique identifier for user data, for:
1. Deduplication detection
2. Privacy protection (not storing original data directly)
3. Fast lookup

Note: Not suitable for password storage, use bcrypt for passwords
]]
local function generate_user_fingerprint(user_data)
    local normalized = string.lower(user_data.email)
    return hash.hash("sha256", normalized)
end
```

## See Also

- [silly.crypto.hmac](./hmac.md) - HMAC Message Authentication Code (keyed hash)
- [silly.crypto.pkey](./pkey.md) - Public Key Encryption (includes signature functionality)
- [silly.security.jwt](../security/jwt.md) - JWT Tokens (uses hash and HMAC)
- [silly.encoding.base64](../encoding/base64.md) - Base64 Encoding (for hash value encoding)

## Standards Reference

- [FIPS 180-4](https://csrc.nist.gov/publications/detail/fips/180/4/final) - SHA-2 Standard
- [FIPS 202](https://csrc.nist.gov/publications/detail/fips/202/final) - SHA-3 Standard
- [RFC 1321](https://tools.ietf.org/html/rfc1321) - MD5 Algorithm
- [RFC 3174](https://tools.ietf.org/html/rfc3174) - SHA-1 Algorithm
- [BLAKE2](https://www.blake2.net/) - BLAKE2 Official Documentation
- [OpenSSL EVP](https://www.openssl.org/docs/man3.0/man7/evp.html) - OpenSSL EVP Interface Documentation
