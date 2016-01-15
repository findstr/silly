local crypt = require "crypt"

local str = "helloworld"
local res = crypt.hmac("test", str)
print(string.format("hmac key:test=%s:%d", res, #res))

aes1 = crypt.aesencode("key", "hello")
aes2 = crypt.aesencode("key", "12345678910111213141516");

print(aes1, #aes1)
print(aes2, #aes2)

local daes1 = crypt.aesdecode("key", aes1)
local daes2 = crypt.aesdecode("key", aes2)

print(daes1, #daes1)
print(daes2, #daes2)

print(string.format("aes decode:%s-%s", "key1", crypt.aesdecode("adsafdsafdsafds", aes1)))
print(string.format("aes decode:%s-%s", "key1", crypt.aesdecode("fdsafdsafdsafdadfsa", aes2)))

