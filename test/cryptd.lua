local crypt = require "crypt"

local str = "helloworld"
local res = crypt.hmac("test", str)
print(string.format("hmac key:test=%s:%d", res, #res))

