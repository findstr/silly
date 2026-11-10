---
title: 随机数据
icon: dice
---

# silly.crypto.random

使用 `bytes()` 生成密码学安全的随机字节，使用 `text()` 生成普通随机小写文本。

```lua validate
local random = require "silly.crypto.random"
local key = random.bytes(32)
assert(#key == 32)
```

## random.bytes(length)

返回恰好包含 `length` 个随机字节的二进制字符串。

- `length`：0 至 `2^31-1` 的整数；零返回 `""`。
- 返回：`string`，可以包含任意字节，包括 NUL。
- 长度无效或随机源失败时抛出错误，不会回退到普通随机源。

需要可打印字符串时，使用 Base64 或十六进制编码结果。

## random.text(length)

返回恰好 `length` 个普通随机小写 ASCII 字母（`a-z`）。

- `length`：0 至 `2^31-1` 的整数；零返回 `""`。
- 返回：`string`。
- 长度无效时抛出错误。

该函数不适用于密钥、nonce、认证令牌或协议掩码；这些场景应使用 `bytes()`。

```lua validate
local random = require "silly.crypto.random"
local text = random.text(16)
assert(#text == 16 and not text:find("[^a-z]"))
```
