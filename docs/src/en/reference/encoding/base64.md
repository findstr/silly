---
title: silly.encoding.base64
icon: code
category:
  - API Reference
tag:
  - Encoding
  - Base64
  - Data Conversion
---

# silly.encoding.base64

Base64 encoding/decoding module, supporting both standard Base64 and URL-safe Base64 formats.

## Module Import

```lua validate
local base64 = require "silly.encoding.base64"
```

## API Functions

### base64.encode(data)
Encodes binary data to a Base64 string (standard format).

- **Parameters**:
  - `data`: `string` - The raw data to encode (can be binary data)
- **Returns**: `string` - The Base64 encoded string
- **Encoding characteristics**:
  - Uses standard Base64 alphabet: `A-Z`, `a-z`, `0-9`, `+`, `/`
  - Uses `=` as padding character
  - Suitable for general data transmission and storage

**Example**:
```lua validate
local base64 = require "silly.encoding.base64"

local original = "Hello, World!"
local encoded = base64.encode(original)
print("Encoded:", encoded)  -- Output: SGVsbG8sIFdvcmxkIQ==

-- Encode binary data
local binary = string.char(0x00, 0xFF, 0xAB, 0xCD)
local encoded_binary = base64.encode(binary)
print("Binary encoded:", encoded_binary)
```

### base64.decode(data)
Decodes a Base64 string to raw data.

- **Parameters**:
  - `data`: `string` - The Base64 encoded string
- **Returns**: `string` - The decoded raw data
- **Decoding characteristics**:
  - Automatically handles padding character `=`
  - Supports decoding both standard Base64 and URL-safe Base64
  - Ignores invalid characters

**Example**:
```lua validate
local base64 = require "silly.encoding.base64"

local encoded = "SGVsbG8sIFdvcmxkIQ=="
local decoded = base64.decode(encoded)
print("Decoded:", decoded)  -- Output: Hello, World!

-- Verify encoding/decoding reversibility
local original = "Test data"
local roundtrip = base64.decode(base64.encode(original))
assert(roundtrip == original)
```

### base64.urlsafe_encode(data)
Encodes binary data to a URL-safe Base64 string.

- **Parameters**:
  - `data`: `string` - The raw data to encode
- **Returns**: `string` - The URL-safe Base64 encoded string
- **Encoding characteristics**:
  - Uses URL-safe Base64 alphabet: `A-Z`, `a-z`, `0-9`, `-`, `_`
  - **Does not use** `=` padding character
  - Safe for use in URLs, filenames, Cookies, etc.

**Example**:
```lua validate
local base64 = require "silly.encoding.base64"

local data = "data >> url?"
local standard = base64.encode(data)
local urlsafe = base64.urlsafe_encode(data)

print("Standard:", standard)   -- ZGF0YSA+PiB1cmw/
print("URL-safe:", urlsafe)    -- ZGF0YSA+PiB1cmw_

-- URL-safe Base64 can be safely used in URL parameters
local token = base64.urlsafe_encode("user:12345:timestamp")
print("Token:", token)  -- Can be used directly in URL: /api?token=xxx
```

### base64.urlsafe_decode(data)
Decodes a URL-safe Base64 string to raw data.

- **Parameters**:
  - `data`: `string` - The URL-safe Base64 encoded string
- **Returns**: `string` - The decoded raw data
- **Decoding characteristics**:
  - Shares the same decoding logic as `base64.decode()`
  - Automatically recognizes `-` and `_` characters
  - Does not require padding characters

**Example**:
```lua validate
local base64 = require "silly.encoding.base64"

local urlsafe_encoded = "SGVsbG8sIFdvcmxkIQ"  -- No padding
local decoded = base64.urlsafe_decode(urlsafe_encoded)
print("Decoded:", decoded)  -- Output: Hello, World!
```

## Usage Examples

### Example 1: Encoding Binary Data

```lua validate
local base64 = require "silly.encoding.base64"

-- Encode image or file content
local file = io.open("image.png", "rb")
local content = file:read("*a")
file:close()

local encoded = base64.encode(content)
print("Image size:", #content, "bytes")
print("Encoded size:", #encoded, "bytes")

-- Save as text file
local out = io.open("image.txt", "w")
out:write(encoded)
out:close()
```

### Example 2: HTTP Basic Authentication

```lua validate
local base64 = require "silly.encoding.base64"

local username = "admin"
local password = "secret123"
local credentials = username .. ":" .. password
local auth_header = "Basic " .. base64.encode(credentials)

print("Authorization:", auth_header)
-- Output: Authorization: Basic YWRtaW46c2VjcmV0MTIz
```

### Example 3: JWT Token (URL-safe Base64)

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

-- Encode as URL-safe Base64
local header_b64 = base64.urlsafe_encode(json.encode(header))
local payload_b64 = base64.urlsafe_encode(json.encode(payload))

print("Header:", header_b64)
print("Payload:", payload_b64)

-- JWT format: header.payload.signature
local jwt = header_b64 .. "." .. payload_b64 .. "." .. "signature"
print("JWT:", jwt)
```

### Example 4: Encoding After Data Encryption

```lua validate
local base64 = require "silly.encoding.base64"
local cipher = require "silly.crypto.cipher"

local key = "sixteen byte key"
local iv = "sixteen byte iv!"
local plaintext = "Secret message"

-- Encrypt
local encrypted = cipher.aes_128_cbc_encrypt(plaintext, key, iv)

-- Encode as Base64 for easy transmission
local encoded = base64.encode(encrypted)
print("Encrypted (Base64):", encoded)

-- Decode and decrypt
local decoded = base64.decode(encoded)
local decrypted = cipher.aes_128_cbc_decrypt(decoded, key, iv)
print("Decrypted:", decrypted)
```

### Example 5: Standard vs URL-safe Comparison

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

-- Output:
-- Original: data?
-- Standard: ZGF0YT8=
-- URL-safe: ZGF0YT8
--
-- Original: test>>data
-- Standard: dGVzdD4+ZGF0YQ==
-- URL-safe: dGVzdD4-ZGF0YQ
```

## Base64 Format Description

### Standard Base64

**Character set**: `A-Z`, `a-z`, `0-9`, `+`, `/`
**Padding**: Uses `=`
**Output length**: Always a multiple of 4

**Encoding rules**:
- Every 3 bytes (24 bits) are encoded to 4 Base64 characters (32 bits)
- Padded with `=` when less than 3 bytes

**Use cases**:
- Email attachments (MIME)
- Binary data in XML/JSON
- Database storage

### URL-safe Base64

**Character set**: `A-Z`, `a-z`, `0-9`, `-`, `_`
**Padding**: **Does not use** `=`
**Output length**: May not be a multiple of 4

**Differences from standard Base64**:
- `+` replaced with `-`
- `/` replaced with `_`
- Padding character `=` removed

**Use cases**:
- URL parameters
- Filenames
- Cookies
- JWT Tokens
- Any scenario requiring use in URLs

## Encoded Size Calculation

Base64 encoding increases data size by approximately 33%:

```
Encoded size = ceil(original size / 3) * 4
```

**Examples**:
- Original: 12 bytes -> Base64: 16 bytes
- Original: 100 bytes -> Base64: 136 bytes
- Original: 1 KB -> Base64: 1.37 KB

```lua validate
local base64 = require "silly.encoding.base64"

local function size_demo(size)
    local data = string.rep("x", size)
    local encoded = base64.encode(data)
    print(string.format("%d bytes -> %d bytes (%.1f%% overhead)",
        size, #encoded, (#encoded / size - 1) * 100))
end

size_demo(10)    -- 10 bytes -> 16 bytes (60.0% overhead)
size_demo(100)   -- 100 bytes -> 136 bytes (36.0% overhead)
size_demo(1000)  -- 1000 bytes -> 1336 bytes (33.6% overhead)
```

## Performance Considerations

### 1. Batch Encoding

When encoding many small pieces of data, consider merging before encoding:

```lua
-- Inefficient: Multiple encodings
local parts = {}
for i = 1, 1000 do
    table.insert(parts, base64.encode("data" .. i))
end

-- Efficient: Merge then encode
local combined = table.concat(parts_raw)
local encoded = base64.encode(combined)
```

### 2. Streaming Processing

For very large data, consider chunk processing:

```lua validate
local base64 = require "silly.encoding.base64"

-- Simulated chunk encoding function
local function encode_stream(read_func, write_func)
    while true do
        -- Read multiples of 3 bytes each time (to avoid padding issues)
        local chunk = read_func(3000)  -- 3000 bytes = 1000 * 3
        if not chunk or #chunk == 0 then
            break
        end

        local encoded = base64.encode(chunk)
        write_func(encoded)
    end
end
```

## Important Notes

::: warning Character Set Safety
Standard Base64 contains `+` and `/` characters, which need URL encoding when used in URLs. It's recommended to use `urlsafe_encode()` directly.
:::

::: tip Automatic Compatibility
`base64.decode()` and `base64.urlsafe_decode()` use the same decoding logic and can automatically recognize both standard and URL-safe formats.
:::

::: warning Padding Characters
URL-safe Base64 does not include padding character `=`. If you need to interoperate with other systems, confirm whether they support unpadded format.
:::

## Common Mistakes

### 1. Confusing Standard and URL-safe Formats

```lua
-- Wrong: Using standard Base64 in URL
local token = base64.encode("user:123")
local url = "/api?token=" .. token  -- May contain +/= characters

-- Correct: Using URL-safe Base64
local token = base64.urlsafe_encode("user:123")
local url = "/api?token=" .. token
```

### 2. Forgetting That Encoded Data is Binary-Safe

```lua
-- Base64 encoded data is plain text, safe to store and transmit
local encrypted = cipher.encrypt(data)  -- Binary data
local safe = base64.encode(encrypted)   -- Convert to text
```

## Practical Application Scenarios

### 1. Email Attachments (MIME)

```lua
local base64 = require "silly.encoding.base64"

local attachment = io.open("document.pdf", "rb"):read("*a")
local encoded = base64.encode(attachment)

-- MIME format: Line break every 76 characters
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

-- Can be used directly in HTML
-- <img src="data:image/png;base64,iVBORw0...">
```

### 3. Binary Data in Configuration Files

```lua
local base64 = require "silly.encoding.base64"
local json = require "silly.encoding.json"

local config = {
    server = {
        host = "localhost",
        port = 8080,
        tls_cert = base64.encode(cert_data),  -- Certificate encoded as text
        tls_key = base64.encode(key_data),
    }
}

-- Save as JSON
local config_json = json.encode(config)
```

## See Also

- [silly.encoding.json](./json.md) - JSON encoding/decoding
- [silly.crypto.cipher](../crypto/cipher.md) - Encryption algorithms (commonly used with Base64)
- [silly.crypto.hash](../crypto/hash.md) - Hash algorithms
- [silly.security.jwt](../security/jwt.md) - JWT Token (uses URL-safe Base64)
