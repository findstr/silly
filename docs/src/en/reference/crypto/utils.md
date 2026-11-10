---
title: Crypto Utilities
icon: wrench
---

# silly.crypto.utils

```lua validate
local utils = require "silly.crypto.utils"
assert(utils.xor("\xff", "\x00\xff") == "\xff\x00")
```

## utils.xor(key, data)

Return the bytewise XOR of `data` and the repeating, nonempty `key`. Both arguments and the result are binary strings.
