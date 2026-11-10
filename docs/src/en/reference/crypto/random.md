---
title: Random Data
icon: dice
---

# silly.crypto.random

Use `bytes()` for cryptographically secure binary data and `text()` for ordinary random lowercase text.

```lua validate
local random = require "silly.crypto.random"
local key = random.bytes(32)
assert(#key == 32)
```

## random.bytes(length)

Return a binary string containing exactly `length` random bytes.

- `length`: integer from 0 to `2^31-1`; zero returns `""`.
- Returns: `string`, which may contain any byte, including NUL.
- Invalid lengths or random-source failures raise an error. Generation never falls back to an ordinary random source.

Encode the result with Base64 or hexadecimal when a printable string is required.

## random.text(length)

Return exactly `length` ordinary random lowercase ASCII letters (`a-z`).

- `length`: integer from 0 to `2^31-1`; zero returns `""`.
- Returns: `string`.
- Invalid lengths raise an error.

This function is unsuitable for keys, nonces, authentication tokens or protocol masking keys. Use `bytes()` for those purposes.

```lua validate
local random = require "silly.crypto.random"
local text = random.text(16)
assert(#text == 16 and not text:find("[^a-z]"))
```
