local crypt = require "sys.crypt"
local testaux = require "testaux"
local P = require "print"

return function()
	---------------------test hamc
	local hmac_key = "test"
	local hmac_body = "helloworld"
	local res = crypt.hmac(hmac_key, hmac_body)
	print(string.format("hmac key:%s body:%s, res:", hmac_key, hmac_body))
	P.hex(hmac_body)
	P.hex(res)
	---------------------test aes
	local aes1_key = "lilei"
	local aes1_body = "hello"
	local aes2_key = "hanmeimei"
	local aes2_body = "1234567891011121314151612345678910111213141516"
	local aes1_encode = crypt.aesencode(aes1_key, aes1_body)
	local aes2_encode = crypt.aesencode(aes2_key, aes2_body)
	local aes1_decode = crypt.aesdecode(aes1_key, aes1_encode)
	local aes2_decode = crypt.aesdecode(aes2_key, aes2_encode)
	testaux.asserteq(aes1_decode, aes1_body, "aes test decode success")
	testaux.asserteq(aes2_decode, aes2_body, "aes test decode success")
	local incorrect = crypt.aesdecode(aes2_key, aes1_encode)
	testaux.assertneq(incorrect, aes1_body, "aes test decode fail")
	local incorrect = crypt.aesdecode("adsafdsafdsafds", aes1_encode)
	testaux.assertneq(incorrect, aes1_body, "aes test decode fail")
	local incorrect = crypt.aesdecode("fdsafdsafdsafdadfsa", aes2_encode)
	testaux.assertneq(incorrect, aes2_body, "aes test decode fail")
	--test dirty data defend
	crypt.aesdecode("fdsafdsafdsafdsafda", aes2_body)
	----------------------test base64
	local plain = "aGVsbG8sIG15IGZyaWVuZCwgeW91IGtvbncgaSBkb24ndCBnb29kIGF0IGNyeX"
	local e1 = crypt.base64encode(plain)
	local d1 = crypt.base64decode(e1)
	testaux.asserteq(d1, plain, "base64 test encode/decode success")
end

