---
title: 密码学辅助工具
icon: wrench
---

# silly.crypto.utils

```lua validate
local utils = require "silly.crypto.utils"
assert(utils.xor("\xff", "\x00\xff") == "\xff\x00")
```

## utils.xor(key, data)

将 `data` 与循环使用的非空 `key` 逐字节异或，返回二进制字符串。两个参数均为二进制字符串。
