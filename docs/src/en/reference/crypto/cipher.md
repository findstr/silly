---
title: Cipher (Symmetric Encryption)
icon: lock
category:
  - API Reference
tag:
  - Encryption
  - Symmetric Encryption
  - AES
  - DES
  - GCM
---

# silly.crypto.cipher

The symmetric encryption module provides high-performance encryption and decryption capabilities based on OpenSSL, supporting multiple encryption algorithms (AES, DES, ChaCha20, etc.) and encryption modes (CBC, GCM, CTR, etc.). Symmetric encryption uses the same key for both encryption and decryption, making it suitable for fast encryption of large amounts of data.

## Overview

The `silly.crypto.cipher` module is a Lua wrapper around the OpenSSL EVP Cipher interface, providing:

- **Multiple Algorithm Support**: AES-128/192/256, DES, 3DES, ChaCha20, etc.
- **Multiple Encryption Modes**: CBC, GCM, CTR, ECB, CFB, OFB, CCM, etc.
- **Stream Processing**: Supports chunk-based encryption of large files to avoid excessive memory usage
- **AEAD Support**: Supports authenticated encryption in GCM/CCM modes, providing data integrity protection
- **Flexible Configuration**: Customizable padding mode, initialization vector (IV), and additional authenticated data (AAD)

Core characteristics of symmetric encryption:
- **Fast**: 100-1000 times faster than asymmetric encryption
- **Key Management**: Same key used for encryption and decryption, key requires secure transmission
- **Use Cases**: Data storage encryption, session key encryption, large file encryption

## Module Import

```lua validate
local cipher = require "silly.crypto.cipher"
```

## Core Concepts

### Encryption Algorithms

Symmetric encryption algorithms typically consist of three parts: `algorithm-key_length-mode`

**Common Algorithm Examples**:
- `aes-128-cbc`: AES algorithm, 128-bit key, CBC mode
- `aes-256-gcm`: AES algorithm, 256-bit key, GCM mode (authenticated encryption)
- `chacha20-poly1305`: ChaCha20 stream cipher with Poly1305 authentication

**AES Key Lengths**:
- AES-128: 16-byte key (128 bits)
- AES-192: 24-byte key (192 bits)
- AES-256: 32-byte key (256 bits)

### Encryption Modes

Different encryption modes determine how data blocks and initialization vectors are processed:

| Mode | Full Name | Characteristics | IV Required | Padding |
|------|-----------|-----------------|-------------|---------|
| ECB | Electronic Codebook | Simplest, insecure (not recommended) | No | Yes |
| CBC | Cipher Block Chaining | Block chaining, commonly used | Yes | Yes |
| CTR | Counter | Counter mode, parallelizable | Yes | No |
| GCM | Galois/Counter Mode | Authenticated encryption (AEAD), recommended | Yes | No |
| CCM | Counter with CBC-MAC | Authenticated encryption (AEAD) | Yes | No |
| CFB | Cipher Feedback | Stream encryption mode | Yes | No |
| OFB | Output Feedback | Stream encryption mode | Yes | No |

**Recommendations**:
- **Data Encryption**: AES-256-GCM (high security, with authentication)
- **Performance Priority**: AES-128-CTR (fast)
- **Compatibility Priority**: AES-128-CBC (widely supported)

### Initialization Vector (IV)

The Initialization Vector is a random number used in the encryption process to enhance security:

- **Length Requirement**: Usually the block size of the encryption algorithm (16 bytes for AES)
- **Randomness Requirement**: Use a different random IV for each encryption
- **Transmission Method**: IV can be transmitted publicly (usually appended to the ciphertext)
- **GCM Mode**: IV length is typically 12 bytes (96 bits) for optimal performance

**Generate Random IV**:
```lua
local utils = require "silly.crypto.utils"
local iv = utils.randomkey(16)  -- IV length for AES is 16 bytes
```

### Padding

Block encryption algorithms (such as AES-CBC) require data length to be a multiple of the block size, thus padding is needed:

- **PKCS7 Padding** (default): Most commonly used, automatically pads to block size
  - Example: Data length is 13 bytes, block size 16 bytes, pad with 3 bytes `\x03\x03\x03`
  - If data is exactly a multiple of block size, pad with a full block
- **No Padding**: Suitable for stream encryption modes (CTR, GCM) or manual padding scenarios

### Authenticated Encryption (AEAD)

AEAD (Authenticated Encryption with Associated Data) modes provide both encryption and authentication protection:

- **GCM/CCM Modes**: Encrypts data and generates an authentication tag
- **Authentication Tag**: Used to verify ciphertext integrity, preventing tampering
- **Additional Authenticated Data (AAD)**: Data that needs to be authenticated but not encrypted (such as protocol headers)

## API Reference

### cipher.encryptor(algorithm, key, iv)

Creates an encryptor object.

- **Parameters**:
  - `algorithm`: `string` - Encryption algorithm name, such as `"aes-128-cbc"`, `"aes-256-gcm"`
    - Supported algorithms depend on OpenSSL version, common algorithms include:
      - AES: `aes-128-ecb`, `aes-128-cbc`, `aes-128-ctr`, `aes-128-gcm`, `aes-256-cbc`, `aes-256-gcm`, etc.
      - DES: `des-ecb`, `des-cbc`, `des3-cbc`, etc.
      - ChaCha20: `chacha20`, `chacha20-poly1305`
  - `key`: `string` - Encryption key, length must match algorithm requirements
    - AES-128: 16 bytes
    - AES-192: 24 bytes
    - AES-256: 32 bytes
  - `iv`: `string|nil` - Initialization vector (optional)
    - ECB mode doesn't need IV (pass `nil`)
    - CBC/CTR/GCM modes need IV, length is usually block size (16 bytes for AES, 12 bytes recommended for GCM)
- **Returns**:
  - `userdata` - Encryptor object
- **Errors**:
  - If algorithm name is not supported, throws error: `"unkonwn algorithm: XXX"`
  - If key length is incorrect, throws error: `"key length need:X got:Y"`
  - If IV length is incorrect, throws error: `"iv length need:X got:Y"`
- **Example**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- Create AES-128-CBC encryptor
local key = "1234567890123456"  -- 16-byte key
local iv = "abcdefghijklmnop"   -- 16-byte IV
local enc = cipher.encryptor("aes-128-cbc", key, iv)
```

### cipher.decryptor(algorithm, key, iv)

Creates a decryptor object.

- **Parameters**:
  - `algorithm`: `string` - Encryption algorithm name, must match the algorithm used for encryption
  - `key`: `string` - Decryption key, must match the key used for encryption
  - `iv`: `string|nil` - Initialization vector (optional), must match the IV used for encryption
- **Returns**:
  - `userdata` - Decryptor object
- **Errors**:
  - Error types same as `encryptor()`
- **Example**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- Create AES-128-CBC decryptor
local key = "1234567890123456"
local iv = "abcdefghijklmnop"
local dec = cipher.decryptor("aes-128-cbc", key, iv)
```

### ctx:update(data)

Stream encrypt/decrypt data chunks (without final padding).

- **Parameters**:
  - `data`: `string` - Data chunk to encrypt/decrypt
- **Returns**:
  - `string` - Encrypted/decrypted data chunk
    - Note: Return length may be less than input length (data cached to block boundary)
    - Block encryption algorithms cache data less than one block size until `final()` is called
- **Errors**:
  - If encryption/decryption fails, throws error: `"cipher update error: XXX"`
- **Example**:

```lua validate
local cipher = require "silly.crypto.cipher"

local enc = cipher.encryptor("aes-128-cbc", "1234567890123456", "abcdefghijklmnop")

-- Encrypt large data in chunks
local encrypted = ""
encrypted = encrypted .. enc:update("first chunk of data")
encrypted = encrypted .. enc:update("second chunk of data")
encrypted = encrypted .. enc:final()  -- Must call final() to get final data
```

### ctx:final([data])

Completes encryption/decryption, returns final data (including padding).

- **Parameters**:
  - `data`: `string|nil` - Optional last chunk of data
    - If provided, equivalent to calling `update(data)` first, then `final()`
- **Returns**:
  - Success: `string` - Final encrypted/decrypted data (including padding or data after padding validation)
  - Failure: `nil` - Padding validation failed or data corrupted during decryption
- **Notes**:
  - For encryptor: Returns last data block and padding
  - For decryptor: Validates padding and returns data with padding removed
  - GCM mode: Can only call `tag()` after calling `final()`
  - After calling `final()`, encryptor/decryptor object cannot continue to be used unless `reset()` is called
- **Example**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- Method 1: Call separately
local enc = cipher.encryptor("aes-128-cbc", "1234567890123456", "abcdefghijklmnop")
local encrypted = enc:update("hello") .. enc:final()

-- Method 2: One-time encryption (shortcut)
local enc2 = cipher.encryptor("aes-128-cbc", "1234567890123456", "abcdefghijklmnop")
local encrypted2 = enc2:final("hello")  -- Pass data directly

print(encrypted == encrypted2)  -- true
```

### ctx:reset(key, iv)

Resets the encryptor/decryptor, allowing the same object to be reused for multiple encryptions/decryptions.

- **Parameters**:
  - `key`: `string` - New key (can be the same as before)
  - `iv`: `string|nil` - New initialization vector (can be the same as before)
- **Returns**: None
- **Errors**:
  - If key or IV length is incorrect, throws error
- **Purpose**:
  - Reuse encryptor object to avoid repeated creation, improving performance
  - After resetting state, can use new key and IV for new encryption/decryption operations
- **Example**:

```lua validate
local cipher = require "silly.crypto.cipher"

local enc = cipher.encryptor("aes-128-cbc", "1234567890123456", "abcdefghijklmnop")

-- First encryption
local encrypted1 = enc:final("first message")

-- Reset and encrypt second message
enc:reset("1234567890123456", "1111111111111111")  -- Use new IV
local encrypted2 = enc:final("second message")
```

### ctx:setpadding(enabled)

Sets padding mode (only applicable to block encryption algorithms).

- **Parameters**:
  - `enabled`: `number` - Whether to enable padding
    - `1` or `true`: Enable PKCS7 padding (default)
    - `0` or `false`: Disable padding (data length must be a multiple of block size)
- **Returns**: None
- **Errors**:
  - If setting fails, throws error: `"cipher set padding error: XXX"`
- **Notes**:
  - When padding is disabled, data length must be a multiple of block size
  - Stream encryption modes (CTR, GCM) don't use padding, calling this method has no effect
  - After setting padding, `reset()` retains the padding setting
- **Example**:

```lua validate
local cipher = require "silly.crypto.cipher"

local enc = cipher.encryptor("aes-128-cbc", "1234567890123456", "abcdefghijklmnop")
enc:setpadding(0)  -- Disable padding

-- Data length must be a multiple of 16 bytes
local plaintext = "1234567890123456"  -- Exactly 16 bytes
local encrypted = enc:final(plaintext)
```

### ctx:setaad(aad)

Sets additional authenticated data (only applicable to AEAD modes, such as GCM, CCM).

- **Parameters**:
  - `aad`: `string` - Additional Authenticated Data
    - Not encrypted but included in authentication tag calculation
    - Commonly used for protocol headers, metadata that needs authentication but not encryption
- **Returns**: None
- **Errors**:
  - If setting fails (non-AEAD mode), throws error: `"cipher aad error: XXX"`
- **Timing**:
  - Must be called before calling `update()` or `final()`
  - Can be called multiple times, data will be accumulated
- **Example**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- GCM mode encryption with AAD
local enc = cipher.encryptor("aes-256-gcm", string.rep("k", 32), string.rep("i", 12))
enc:setaad("protocol-header-v1")  -- Set additional authenticated data
local encrypted = enc:final("secret message")
local tag = enc:tag()

-- GCM mode decryption, verify AAD
local dec = cipher.decryptor("aes-256-gcm", string.rep("k", 32), string.rep("i", 12))
dec:setaad("protocol-header-v1")  -- Must set same AAD
dec:settag(tag)                    -- Set authentication tag
local decrypted = dec:final(encrypted)
print(decrypted)  -- "secret message"
```

### ctx:settag(tag)

Sets authentication tag (only for AEAD decryption).

- **Parameters**:
  - `tag`: `string` - Authentication Tag
    - Generated by encryptor (obtained via `tag()`)
    - Used to verify ciphertext integrity and authenticity
- **Returns**: None
- **Errors**:
  - If setting fails, throws error: `"cipher tag error: XXX"`
- **Timing**:
  - Must be called before calling `final()`
  - If tag validation fails, `final()` will return `nil`
- **Example**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- Encrypt and get tag
local enc = cipher.encryptor("aes-128-gcm", string.rep("x", 16), string.rep("y", 12))
local ciphertext = enc:final("confidential data")
local tag = enc:tag()

-- Decrypt and verify tag
local dec = cipher.decryptor("aes-128-gcm", string.rep("x", 16), string.rep("y", 12))
dec:settag(tag)  -- Set tag for verification
local plaintext = dec:final(ciphertext)

if plaintext then
    print("Decryption successful:", plaintext)
else
    print("Authentication failed: Data tampered")
end
```

### ctx:tag()

Gets authentication tag (only for AEAD encryption).

- **Parameters**: None
- **Returns**:
  - `string` - Authentication tag, length depends on algorithm (usually 16 bytes)
- **Errors**:
  - If retrieval fails (non-AEAD mode or `final()` not called), throws error: `"cipher tag error: XXX"`
- **Timing**:
  - Must be called after calling `final()`
  - Tag needs to be transmitted with ciphertext to receiver
- **Example**:

```lua validate
local cipher = require "silly.crypto.cipher"

-- GCM encryption and get tag
local enc = cipher.encryptor("aes-256-gcm", string.rep("k", 32), string.rep("n", 12))
local ciphertext = enc:final("top secret")
local tag = enc:tag()

print("Ciphertext length:", #ciphertext)      -- 10 bytes (same as plaintext)
print("Tag length:", #tag)                     -- 16 bytes
print("Transmission data:", ciphertext .. tag) -- ciphertext + tag
```

## Usage Examples

### Basic Usage: AES-CBC Encryption

```lua validate
local cipher = require "silly.crypto.cipher"

-- Define key and IV
local key = "my-secret-key-16"  -- 16 bytes (AES-128)
local iv = "my-random-iv1234"   -- 16 bytes

-- Encrypt
local plaintext = "Hello, Silly Framework!"
local enc = cipher.encryptor("aes-128-cbc", key, iv)
local ciphertext = enc:final(plaintext)

print("Plaintext:", plaintext)
print("Ciphertext length:", #ciphertext)  -- 32 bytes (16 bytes data + 16 bytes padding)

-- Decrypt
local dec = cipher.decryptor("aes-128-cbc", key, iv)
local decrypted = dec:final(ciphertext)

print("Decryption result:", decrypted)    -- "Hello, Silly Framework!"
print("Verification:", plaintext == decrypted)  -- true
```

### AES-GCM Authenticated Encryption

```lua validate
local cipher = require "silly.crypto.cipher"

-- GCM mode: Authenticated encryption, provides data integrity protection
local key = string.rep("k", 32)  -- AES-256: 32-byte key
local iv = string.rep("i", 12)   -- GCM recommends 12-byte IV

-- Encrypt
local plaintext = "Sensitive data"
local enc = cipher.encryptor("aes-256-gcm", key, iv)
local ciphertext = enc:final(plaintext)
local tag = enc:tag()  -- Get authentication tag

print("Ciphertext length:", #ciphertext)  -- 14 bytes (same as plaintext, GCM no padding)
print("Tag length:", #tag)                 -- 16 bytes

-- Decrypt and verify
local dec = cipher.decryptor("aes-256-gcm", key, iv)
dec:settag(tag)  -- Set authentication tag
local decrypted = dec:final(ciphertext)

if decrypted then
    print("Decryption successful:", decrypted)
else
    print("Authentication failed: Data may be tampered")
end
```

### Stream Encryption of Large Files

```lua validate
local cipher = require "silly.crypto.cipher"

-- Simulate large file chunk encryption
local function encrypt_large_data()
    local key = string.rep("x", 16)
    local iv = string.rep("y", 16)
    local enc = cipher.encryptor("aes-128-cbc", key, iv)

    -- Process in chunks (simulate reading file)
    local chunks = {
        "This is the first chunk of data. ",
        "This is the second chunk of data. ",
        "This is the final chunk of data."
    }

    local encrypted = ""
    for i, chunk in ipairs(chunks) do
        encrypted = encrypted .. enc:update(chunk)
    end
    encrypted = encrypted .. enc:final()  -- Get final block and padding

    print("Total ciphertext length:", #encrypted)
    return encrypted, key, iv
end

-- Stream decryption
local function decrypt_large_data(ciphertext, key, iv)
    local dec = cipher.decryptor("aes-128-cbc", key, iv)

    -- Decrypt in chunks
    local chunk_size = 32  -- Process 32 bytes at a time
    local decrypted = ""

    for i = 1, #ciphertext - chunk_size, chunk_size do
        local chunk = ciphertext:sub(i, i + chunk_size - 1)
        decrypted = decrypted .. dec:update(chunk)
    end

    -- Process remaining data and padding validation
    local remaining = ciphertext:sub(#ciphertext - (#ciphertext % chunk_size) + 1)
    decrypted = decrypted .. dec:final(remaining)

    return decrypted
end

-- Execute encryption and decryption
local ciphertext, key, iv = encrypt_large_data()
local plaintext = decrypt_large_data(ciphertext, key, iv)
print("Decryption result:", plaintext)
```

### AES-CTR Stream Encryption Mode

```lua validate
local cipher = require "silly.crypto.cipher"

-- CTR mode: Stream encryption, no padding needed, can be parallelized
local key = string.rep("s", 16)  -- 16-byte key
local iv = string.rep("n", 16)   -- 16-byte nonce

-- Encrypt arbitrary length data (no padding needed)
local plaintext = "Short"  -- 5 bytes
local enc = cipher.encryptor("aes-128-ctr", key, iv)
local ciphertext = enc:final(plaintext)

print("Plaintext length:", #plaintext)   -- 5 bytes
print("Ciphertext length:", #ciphertext)  -- 5 bytes (same as plaintext)

-- Decrypt
local dec = cipher.decryptor("aes-128-ctr", key, iv)
local decrypted = dec:final(ciphertext)
print("Decryption result:", decrypted)  -- "Short"
```

### Disable Padding for Manual Padding

```lua validate
local cipher = require "silly.crypto.cipher"

-- Manually pad to block size (16 bytes)
local function manual_pkcs7_pad(data, block_size)
    local padding = block_size - (#data % block_size)
    return data .. string.rep(string.char(padding), padding)
end

local function manual_pkcs7_unpad(data)
    local padding = string.byte(data, -1)
    return data:sub(1, -padding - 1)
end

-- Encrypt (disable automatic padding)
local key = string.rep("k", 16)
local iv = string.rep("i", 16)
local plaintext = "Test"  -- 4 bytes

-- Manual padding
local padded = manual_pkcs7_pad(plaintext, 16)
print("After padding:", #padded)  -- 16 bytes

local enc = cipher.encryptor("aes-128-cbc", key, iv)
enc:setpadding(0)  -- Disable automatic padding
local ciphertext = enc:final(padded)

-- Decrypt (disable automatic padding)
local dec = cipher.decryptor("aes-128-cbc", key, iv)
dec:setpadding(0)
local decrypted_padded = dec:final(ciphertext)

-- Manually remove padding
local decrypted = manual_pkcs7_unpad(decrypted_padded)
print("Decryption result:", decrypted)  -- "Test"
```

### GCM Mode with Additional Authenticated Data

```lua validate
local cipher = require "silly.crypto.cipher"

-- Scenario: Encrypt HTTP response body, authenticate HTTP headers
local function encrypt_http_response(headers, body, key, iv)
    local enc = cipher.encryptor("aes-256-gcm", key, iv)

    -- Set AAD (Additional Authenticated Data): HTTP headers
    local aad = "Content-Type: application/json\r\n" ..
                "X-Request-ID: 12345\r\n"
    enc:setaad(aad)

    -- Encrypt response body
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

    -- Set same AAD
    dec:setaad(response.headers)

    -- Set authentication tag
    dec:settag(response.tag)

    -- Decrypt response body
    local body = dec:final(response.encrypted_body)
    if not body then
        return nil, "Authentication failed: Headers or body tampered"
    end

    return body
end

-- Usage example
local key = string.rep("k", 32)
local iv = string.rep("i", 12)
local headers = "X-API-Version: 1.0"
local body = '{"status":"success","data":"hello"}'

local encrypted = encrypt_http_response(headers, body, key, iv)
print("Ciphertext length:", #encrypted.encrypted_body)

local decrypted_body, err = decrypt_http_response(encrypted, key, iv)
if decrypted_body then
    print("Decryption successful:", decrypted_body)
else
    print("Decryption failed:", err)
end
```

### Multiple Algorithm Comparison

```lua validate
local cipher = require "silly.crypto.cipher"

-- Compare performance and ciphertext length of different encryption algorithms
local function compare_algorithms()
    local plaintext = "Test data for comparison"
    local results = {}

    -- Test different algorithms
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

-- Execute comparison
local results = compare_algorithms()
for name, info in pairs(results) do
    print(string.format("%s: plaintext=%d bytes, ciphertext=%d bytes, tag=%d bytes, total=%d bytes",
        name, info.plaintext_len, info.ciphertext_len, info.tag_len, info.total_len))
end
```

### Reuse Encryptor Object

```lua validate
local cipher = require "silly.crypto.cipher"

-- Scenario: Batch encrypt multiple messages
local function batch_encrypt_messages(messages)
    local key = string.rep("k", 16)
    local enc = cipher.encryptor("aes-128-cbc", key, string.rep("i", 16))

    local encrypted_list = {}

    for i, msg in ipairs(messages) do
        -- Use different IV for each message
        local iv = string.format("iv%014d", i)  -- Generate unique IV (2+14=16 bytes)
        enc:reset(key, iv)

        encrypted_list[i] = {
            iv = iv,
            ciphertext = enc:final(msg)
        }
    end

    return encrypted_list
end

-- Batch decryption
local function batch_decrypt_messages(encrypted_list, key)
    local dec = cipher.decryptor("aes-128-cbc", key, string.rep("i", 16))
    local messages = {}

    for i, item in ipairs(encrypted_list) do
        dec:reset(key, item.iv)
        messages[i] = dec:final(item.ciphertext)
    end

    return messages
end

-- Usage example
local messages = {"Message 1", "Message 2", "Message 3"}
local key = string.rep("k", 16)

local encrypted = batch_encrypt_messages(messages)
print("Encryption completed,", #encrypted, "messages")

local decrypted = batch_decrypt_messages(encrypted, key)
for i, msg in ipairs(decrypted) do
    print(string.format("Message %d: %s", i, msg))
end
```

## Notes

### Security Considerations

1. **Key Management**
   - Keys should be generated using a secure random number generator (use `silly.crypto.utils.randomkey()`)
   - Keys should be stored securely, avoid hardcoding in code
   - Recommend using Key Derivation Function (KDF) to generate keys from passwords
   - Regularly rotate keys to reduce security risks

2. **Initialization Vector (IV)**
   - **Never** reuse the same IV and key combination
   - Generate a new random IV for each encryption
   - IV can be transmitted publicly (usually appended to ciphertext)
   - GCM mode: IV cannot be reused, otherwise seriously compromises security

3. **Encryption Mode Selection**
   - **Avoid ECB mode**: Same plaintext blocks produce same ciphertext blocks, insecure
   - **Recommend GCM mode**: Provides both encryption and authentication protection, prevents tampering
   - **CBC mode**: Needs to use HMAC or similar for additional integrity protection
   - **CTR mode**: Need to ensure IV is not reused

4. **Padding Oracle Attack**
   - CBC mode has padding oracle attack risk
   - Should unify error handling to avoid leaking padding information
   - Recommend using GCM/CCM AEAD modes

### Performance Optimization

1. **Batch Encryption**
   - Use `reset()` to reuse encryptor object, avoid repeated creation
   - Reduces memory allocation and OpenSSL context initialization overhead

2. **Stream Processing**
   - For large file encryption, use `update()` to process in chunks, avoid memory overflow
   - Recommended chunk size is 16KB-64KB

3. **Algorithm Selection**
   - AES-GCM: Good hardware acceleration support, fast
   - ChaCha20-Poly1305: Fast software implementation, suitable for mobile devices

### Common Errors

| Error Message | Cause | Solution |
|--------------|-------|----------|
| `unknown algorithm: XXX` | Algorithm name not supported or misspelled | Check algorithm name, confirm OpenSSL version support |
| `key length need:X got:Y` | Incorrect key length | Use correct length key (AES-128: 16 bytes, AES-256: 32 bytes) |
| `iv length need:X got:Y` | Incorrect IV length | Use correct length IV (CBC/CTR: 16 bytes, GCM: 12 bytes) |
| `cipher update error` | Data processing failed | Check if data is corrupted or algorithm parameters are correct |
| `final()` returns `nil` | Padding validation failed or GCM authentication failed during decryption | Incorrect key/IV, or data tampered |

### Data Transmission Format

When transmitting encrypted data, typically use the following format:

```
[IV][Ciphertext][Authentication Tag (if AEAD)]
```

**Example**:
```lua
-- Encrypt and pack
local iv = random.random(12)
local enc = cipher.encryptor("aes-256-gcm", key, iv)
local ciphertext = enc:final(plaintext)
local tag = enc:tag()
local packet = iv .. ciphertext .. tag  -- Transmission format

-- Unpack and decrypt
local iv = packet:sub(1, 12)
local ciphertext = packet:sub(13, -17)
local tag = packet:sub(-16)
local dec = cipher.decryptor("aes-256-gcm", key, iv)
dec:settag(tag)
local plaintext = dec:final(ciphertext)
```

### Compatibility with Other Encryption Libraries

- **OpenSSL Command Line**:
  ```bash
  # Encrypt (compatible with Lua code)
  echo -n "Hello" | openssl enc -aes-128-cbc -K 31323334353637383930313233343536 -iv 61626364656667686969696a6b6c6d6e6f70 -nosalt
  ```

- **Python (cryptography)**: Can interoperate using same algorithm, key, IV

- **Node.js (crypto)**: Can interoperate using same algorithm, key, IV

## Best Practices

### 1. Use Key Derivation Function (KDF)

```lua
local hash = require "silly.crypto.hash"
local cipher = require "silly.crypto.cipher"

-- Derive key from password (simplified example, should use PBKDF2/Argon2 in practice)
local function derive_key(password, salt, key_len)
    local data = password .. salt
    for i = 1, 10000 do  -- Multiple iterations enhance security
        data = hash.sha256(data)
    end
    return data:sub(1, key_len)
end

local password = "user-password-123"
local salt = "random-salt-value"
local key = derive_key(password, salt, 32)  -- Derive 32-byte key

-- Use derived key
local enc = cipher.encryptor("aes-256-gcm", key, string.rep("i", 12))
```

### 2. Implement Encryption Utility Functions

```lua
local cipher = require "silly.crypto.cipher"
local utils = require "silly.crypto.utils"

local crypto_util = {}

-- One-click encryption (automatically generate IV)
function crypto_util.encrypt(plaintext, key, algorithm)
    algorithm = algorithm or "aes-256-gcm"
    local iv_len = algorithm:match("gcm") and 12 or 16
    local iv = utils.randomkey(iv_len)

    local enc = cipher.encryptor(algorithm, key, iv)
    local ciphertext = enc:final(plaintext)

    if algorithm:match("gcm") then
        local tag = enc:tag()
        return iv .. ciphertext .. tag  -- IV + ciphertext + tag
    else
        return iv .. ciphertext  -- IV + ciphertext
    end
end

-- One-click decryption
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

### 3. Database Field Encryption

```lua
-- Scenario: Encrypt user sensitive information (such as email, phone)
local cipher = require "silly.crypto.cipher"
local base64 = require "silly.encoding.base64"

local db_crypto = {}
local master_key = string.rep("k", 32)  -- Read from config file

function db_crypto.encrypt_field(plaintext)
    local utils = require "silly.crypto.utils"
    local iv = utils.randomkey(12)

    local enc = cipher.encryptor("aes-256-gcm", master_key, iv)
    local ciphertext = enc:final(plaintext)
    local tag = enc:tag()

    -- Base64 encode for database storage
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

### 4. Session Key Encryption

```lua
local cipher = require "silly.crypto.cipher"

-- Use temporary session key to encrypt data
local function create_session(user_id)
    local utils = require "silly.crypto.utils"
    local session_key = utils.randomkey(32)  -- Random session key
    local session_id = utils.randomkey(16)

    return {
        id = session_id,
        key = session_key,
        user_id = user_id,
        created_at = os.time()
    }
end

local function encrypt_session_data(session, data)
    local utils = require "silly.crypto.utils"
    local iv = utils.randomkey(12)

    local enc = cipher.encryptor("aes-256-gcm", session.key, iv)
    local ciphertext = enc:final(data)
    local tag = enc:tag()

    return iv .. ciphertext .. tag
end
```

## See Also

- [silly.crypto.hash](./hash.md) - Hash functions (key derivation, data integrity)
- [silly.crypto.hmac](./hmac.md) - Message Authentication Code (integrity protection for CBC mode)
- [silly.crypto.pkey](./pkey.md) - Asymmetric encryption (key exchange, digital signatures)
- [silly.encoding.base64](../encoding/base64.md) - Base64 encoding (store binary ciphertext)

## Standards Reference

- [OpenSSL EVP Cipher](https://www.openssl.org/docs/manmaster/man3/EVP_EncryptInit.html)
- [NIST SP 800-38A](https://csrc.nist.gov/publications/detail/sp/800-38a/final) - AES Encryption Modes
- [NIST SP 800-38D](https://csrc.nist.gov/publications/detail/sp/800-38d/final) - GCM Mode Specification
- [RFC 5116](https://tools.ietf.org/html/rfc5116) - Authenticated Encryption (AEAD) Interface
