local rsa = require "silly.crypto.rsa"
local testaux = require "test.testaux"

-- Generated RSA keys (replace with actual generated keys)
local privkey = [[
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCtLWMWY5gVqqu0
lezUSXdhaT5vwldh5zbho4toYxCZuWjMBTPexwKMtXRXUnrEkZvflHc5TYlA4JPV
yEEAFhc3o39M1P+c2Fld1KKd6jJBiR/EN445/3Db5/DpPfYyz/of2wWS5de79Q7X
JG9tajM+Rl95uFpmjG963tbs5sH4Wbjvmv5qn+JzHZivVs+Dug/PdUG+yAaq6Cb7
SZ2m3RhRJHJB3R+KGZgKy/qV2bqZ+CgTSFU62GvnYqra8AxyX2QSTKGCHPD5bcz5
VeWAnBuUhMH0MQE/Ypq51RrqANiw6lq6hTy9pzI0AtItdM7t+1NzNEUg0/dr2Z1i
DlMeuSopAgMBAAECggEAYVue1TtwiN3GYmPXHRGgV9c/Dr2HOrcuF3RGL41iC8o8
rFZQbvIa8Ngia+Umt9PUecGRtVltzFd1RT6rrEy/CLyWGK+2dIr80s90DKtZTZa1
kS5aeyisXjTrL3VyL+bUi4wqegdVXYnLqhAFxNFrtZsCmf+WcwiIs98LnWutqNx7
QJR2HedjBXk+mXxkaonGyIjcXiowoXdIF/XhvR4CsH9G0OG3iD0g0ZkHGZ2zqGu7
qo9o2YwE1y1PTwd4otsuPITveCqj6egAm9rpHqaRQtRhAJqUPeKfKO2vlxdJrzLb
KyngzusRgz/gz3yQtL7ink19+/p9HSnbqCasJ8QwAQKBgQDaYPnJnw0TyUG0GpyG
MzC77vDqhbWGETPpgNS51UFRCpwrwY6URBMXw393YEb0DyLiP9w5U8camJC7DH1O
I/A+gWDT6x/LX3axC36ydhz00hiPXJMHHXUr4L3dQHCZQuW5HNm4VKBqGo2d8Yy1
KTpVyv8E0T0jtlDaz9cEas8igQKBgQDLAurBU8abUvoFFGMkfxoehsa7SLOudgTF
5BVhwVLZ71UdD5pjSzfTeKyIMZDLHQca0HuQ4Ee4LMJFp/3LGkvJYRhpI4XNxa8b
rg8x+VnFR7vMKzM4BiR7vzzQLk9Yl8JbUFCwu/0wqvi4K84V0BigSugYo+jO7mC0
cDyrWOPjqQKBgQCbln5BZV2m3DxAurkMcEpni50AKpWjWHxZAF4PrN3lhJ6yGiyg
fEPyKWqWvfSvjF05P3CDM6pmy45KhmJ8muRfVESNmDbF6lUhXOQ++CI3V70B314t
spI52dzMV04iE+SiV+jTCRBlqFd/0YqDxET4vTGm2AEsgYfn7i7uyb6cgQKBgQCS
hb9z24hb8M6dPfK0k7wBTls/LyDoiSu2vIEmNgcbXp76w5k1k0NusQktn0CXKJNJ
KjIVBZsd9cgdyDroDUmnxhl9QPNA6i4Rd1ZmRkchmT2VBZUJGX3ZhtRYmSQRmC7i
AxzKAlSifLPZEVzD55bukkHkDuFoASrw8JUJQrXwSQKBgGJNgiOksXQHGBMRQ4RN
58yxce1MjsPb6lUT4fU1I9XoIOrXi3LMGRbwCEQcTnAl/fmqX/mn/OU0uWKhtB00
mWF54QYcPrCDl4QWZjmnM9TeWab0Fdz5uGUe2PxhHs5dQ2hYRloTA/U+NsNLdiwW
BHo1sC5Ix5jbkO/TaUMKGmNb
-----END PRIVATE KEY-----
]]

local pubkey = [[
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArS1jFmOYFaqrtJXs1El3
YWk+b8JXYec24aOLaGMQmblozAUz3scCjLV0V1J6xJGb35R3OU2JQOCT1chBABYX
N6N/TNT/nNhZXdSineoyQYkfxDeOOf9w2+fw6T32Ms/6H9sFkuXXu/UO1yRvbWoz
PkZfebhaZoxvet7W7ObB+Fm475r+ap/icx2Yr1bPg7oPz3VBvsgGqugm+0mdpt0Y
USRyQd0fihmYCsv6ldm6mfgoE0hVOthr52Kq2vAMcl9kEkyhghzw+W3M+VXlgJwb
lITB9DEBP2KaudUa6gDYsOpauoU8vacyNALSLXTO7ftTczRFINP3a9mdYg5THrkq
KQIDAQAB
-----END PUBLIC KEY-----
]]

local encrypted_privkey = [[
-----BEGIN ENCRYPTED PRIVATE KEY-----
MIIFLTBXBgkqhkiG9w0BBQ0wSjApBgkqhkiG9w0BBQwwHAQI2+GG3gsDJbwCAggA
MAwGCCqGSIb3DQIJBQAwHQYJYIZIAWUDBAEqBBBl5BCE5p8mrjUpj0cdbN5SBIIE
0FP54ygFb2qWXXLuRK241megT4wpy3ITDfkoyYtew23ScvZ/mNTBEUorA3H1ebas
8xUfsdVbZs91MbmJqTCpk0KWr86nz0H/5E8/EG8rr66ClnxkSMlaL910bpEn3LR/
w4jsCNzDHYtamwYQ4axpk+PjCFTFEzTNJohjl4ZRnXuLDFRMRqRcrvIIyVk0yLqE
e8aXPp6nYA5wwI+hlkTHPn9oe7QQnk3P9GrdJvY+6qmkmlOYV8b4uVso0HSnNYAy
1NHAHi0BZvlgmdPodgs9mOYYfV/TLHcdYOG7g0brBznHqk4K99TRmPnvU10NyFJ/
+/tEPWr6/kC+fz6AIi4sZ5oW84R/LOEbxifGUXmH2pDxL+NZFnboS7zbI6q3xZP9
vDYmZQ1hSZBu03kC+90KN/7T1tfr/FW1odnBQ6ZhiuTtHeutD5WAhpJEOmgYCp0A
HR/ETAX6Gq+0vPkp6OdRE0khA+9Q1uRI/Z1RzcvVQzOEhM02FjRv7FhLdQqwgVtC
5UcJkOC1SkU2rT2bYHnuaqUDYRKQ6lqOl6U5p26UyKLzFcza6zUKTGMCXePSbcJV
YkY4KfFXpQB2f7SS3/it6gsecwUGthFEXNqJL1q4Q2UlEHRVF6Iv8KuE/oV1HuHv
DCvao7kI0r1fbpLmG0v1Rx5WW/lbTet/dX2EkbXaD1BWtBzlQOo/mOHmpDrMoll+
F+S5Qm1L0Zfnl2QJb9ujh6ae82RdQbmGG0gt2bsPdBZTR8pkygNYxtT9ODdr35rr
IxXKdIln8qc3c1McHRUs+e8OwctTHFxXAqeUWDEZDvGHZ+L2guJJI186XUOLvkk+
V33AR1WEP8pfSPQFNVMzjnvy+9mWB3KDZALXezA+mOT/VJAUUq3B4vNjO8MUDigh
SpEG/1qwxc3XiolyxrYKeMdxQF5BzmPqk8oduPp+wRLgLcrwABDS0ppx9jbf9Fpv
lYt9H+xpADDWhmaIXCIDhbglxdja6lCNVmyybAf4ltBpx0LcfLYq2wTvsiiKGDAx
xWtT06qkRpZQ3gkMZzCE8uw0v1WW2Eu+NJKjjP8MpGHkdUHaZyZsdQ4d6q9eL+jr
LmvTs6VmUbefTAlMur7LieH/PMfOVsWkYpz7pTH42H6oAQ6wCUY0V95S9EmD3VlM
916hrRrxRl3hZDDjpWrcOTENcJC0B4b68qUWeyvA+HAJAjiJVXh8ja+PpJ3aDDOp
0Zgg/X5mwaOZGxjQsI5Xhou/TJBmOl2awqnolVVdG8AXVr2Lpuey43SAOejFicwh
Sj5oDcPW8b9GO9nkhHyJvKE2kwEy6Bf1wlBBMHVjdE6BjEdp2NWhilgX1pP2a6ZF
yPZ/Sf/LllQigY4YPd2fGqwFeWK6oFaMvAWsNlpA/yBGiJ7I7YYjaViywMtUoRU6
U7Wg9aBuo6zd/edibzz7VKDC0d1kpvTnWjnpZNWV34rR9R1lTS2g51t9B9UgVcIF
i8UpmLqSO2iTZ94YLXE+qjRuhqFGz+GzfVTPZXBptQ1QFeVwtcI2mdDoHV0rztzs
ARFqYQG3VWA7nbC0CsPuhGAwMdmhamDHyDJMyI0+LQCXdgGZGm3fp05YoIzVd57U
Kg7ZBEtGj2gFEoN7zNx9QfueKpjF5cfMzeQ4VOFfXDsO
-----END ENCRYPTED PRIVATE KEY-----
]]

local encrypted_pubkey = [[
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA5ek2uXetoj+qwcI67800
h1cLPyPbt4/GDJBRFm0ki7q/ykcHgBniL2wW3UAzPteyyu4N+XlcOdeMIZJvbgwX
UqX7WIFxWNhzcU6sjRIIEa6dcYdAhVj/EMOXWKKbAsmRlR8Qhc7Tegas4USbfe74
+ApWRV5y95s4oQv7U9qPI2wdTJICwAhT3RH/AM6DWqUuAL1iTiVb0MGCGY+ei2sK
hJ4rt3ry8JzVyiJNCazDUbB3ZSrqTVW5I+2vWE0MyF+KQGkyeRBtWNDLUyg65eO6
y6er5SVhHz4/Ot5P16vpd4lr2uv2AIBZAJOXsoOc+oF7Zml8zAtk+RXX8VAmxF4d
/QIDAQAB
-----END PUBLIC KEY-----
]]

-- Test vectors
local test_vectors = {
	{
		alg = "sha256",
		message = "Hello RSA!",
	},
	{
		alg = "sha1",
		message = string.rep("A", 1024),  -- Long message test
	},
	{
		alg = "sha512",
		message = "",  -- Empty message test
	}
}

-- Test 1: Basic sign/verify workflow
do
	local priv = rsa.new(privkey)
	local pub = rsa.new(pubkey)

	for _, vec in ipairs(test_vectors) do
		local sig = priv:sign(vec.message, vec.alg)
		local verify = pub:verify(vec.message, sig, vec.alg)
		testaux.asserteq(verify, true, "Case1: "..vec.alg.." verification passed")
	end
end

-- Test 2: Signature tampering detection
do
	local priv = rsa.new(privkey)
	local pub = rsa.new(pubkey)
	local sig = priv:sign("original message", "sha256")

	-- Tamper with signature
	local bad_sig = sig:sub(1, -2) .. string.char(sig:byte(-1) ~ 0x01)
	testaux.asserteq(pub:verify("original message", bad_sig, "sha256"), false,
		"Case2: Detect signature tampering")

	-- Tamper with message
	testaux.asserteq(pub:verify("modified message", sig, "sha256"), false,
		"Case2: Detect message tampering")
end

-- Test 3: Encrypted private key handling
do
	-- Load encrypted key with correct password
	local priv = rsa.new(encrypted_privkey, "123456")
	local pub = rsa.new(encrypted_pubkey)

	-- Test signing with encrypted key
	local sig = priv:sign("test message", "sha256")
	testaux.asserteq(pub:verify("test message", sig, "sha256"), true,
		"Case3: Encrypted key with correct password")

	-- Test wrong password
	local status = pcall(rsa.new, encrypted_privkey, "wrongpass")
	testaux.asserteq(status, false, "Case3: Detect wrong password")
end

-- Test 4: Error handling
do
	-- Invalid key format
	local status = pcall(rsa.new, "invalid key")
	testaux.asserteq(status, false, "Case4: Detect invalid key format")

	-- Unsupported algorithm
	local priv = rsa.new(privkey)
	local status = pcall(priv.sign, priv, "invalid_alg", "data")
	testaux.asserteq(status, false, "Case4: Detect unsupported algorithm")

	-- Non-RSA key
	local status = pcall(rsa.new, [[-----BEGIN EC PRIVATE KEY-----...]])
	testaux.asserteq(status, false, "Case4: Detect non-RSA key")
end

-- Test 5: Object reuse
do
	local priv = rsa.new(privkey)
	local pub = rsa.new(pubkey)

	-- First use
	local sig1 = priv:sign("message1", "sha256")
	testaux.asserteq(pub:verify("message1", sig1, "sha256"), true,
		"Case5: First verification")

	-- Second use
	local sig2 = priv:sign("message2", "sha512")
	testaux.asserteq(pub:verify("message2", sig2, "sha512"), true,
		"Case5: Second verification")
end

-- Test 6: Boundary conditions
do
	local priv = rsa.new(privkey)
	local pub = rsa.new(pubkey)

	-- Maximum message length (for 2048-bit RSA)
	local max_len = 2048//8 - 11
	local long_msg = string.rep("A", max_len)
	local sig = priv:sign(long_msg, "sha256")
	testaux.asserteq(pub:verify(long_msg, sig, "sha256"), true,
		"Case6: Maximum length message")

	-- Test 1MB long message
	local long_msg = string.rep("A", 1024*1024)  -- 1MB 长消息
	local sig = priv:sign(long_msg, "sha256")
	testaux.asserteq(pub:verify(long_msg, sig, "sha256"), true,
		"Case6: 1MB long message")

	-- Test empty message
	local sig_empty = priv:sign("", "sha256")
	testaux.asserteq(pub:verify("", sig_empty, "sha256"), true,
		"Case6: empty message")
end

