local P = require "test.print"
local jwt = require "core.jwt"
local json = require "core.encoding.json"
local rsa = require "core.crypto.rsa"
local ec = require "core.crypto.ec"
local testaux = require "test.testaux"
local base64 = require "core.encoding.base64"

-- Predefined test materials
local test_payload = {sub = "1234567890", name = "John Doe", iat = 1516239022}
local hmac_key = "secret"
local valid_token_hs256 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

-- Test 1: Basic JWT encode/decode with HS256
do
	local token, err = jwt.encode(test_payload, hmac_key, "HS256")
	testaux.assertneq(token, nil, "Case 1.1: Should generate token")
	testaux.asserteq(err, nil, "Case 1.1: No error expected")

	local decoded, err = jwt.decode(token, hmac_key)
	testaux.assertneq(decoded, nil, "Case 1.2: Should decode successfully")
	testaux.asserteq(decoded.name, test_payload.name, "Case 1.2: Payload should match")
end

-- Test 2: Invalid token formats
do
	local cases = {
		"invalid.token.format",
		"missing.third.part",
		"too.many.dots.in.token",
		"header.part.only",
		""
	}

	for i, token in ipairs(cases) do
		local decoded, err = jwt.decode(token, hmac_key)
		testaux.asserteq(decoded, nil, "Case 2."..i..": Should reject invalid format")
	end
end

-- Test 3: Signature verification failures
do
	-- Tampered signature
	local tampered_token = valid_token_hs256:gsub(".$", "x")
	local decoded, err = jwt.decode(tampered_token, hmac_key)
	testaux.asserteq(err, "signature verification failed", "Case 3.1: Tampered signature")

	-- Tampered payload
	local parts = {valid_token_hs256:match("([^.]+).([^.]+).([^.]+)")}
	parts[2] = base64.urlsafe_encode(json.encode({name = "Attacker"}))
	local modified_token = table.concat(parts, ".")
	decoded, err = jwt.decode(modified_token, hmac_key)
	testaux.asserteq(err, "signature verification failed", "Case 3.2: Modified payload")
end

-- Test 4: Invalid base64 encodings
do
	local invalid_base64 = {
		"InvalidHeader.pay.l0ad",  -- Contains uppercase letters
		"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ=,payload.sig",  -- Invalid padding
		"header.inval!d_chars.sig"
	}

	for i, token in ipairs(invalid_base64) do
		local decoded, err = jwt.decode(token, hmac_key)
		testaux.asserteq(decoded, nil, "Case 4."..i..": Should reject invalid base64")
	end
end

-- Test 5: JSON parsing failures
do
	local invalid_json = {
		-- Invalid header
		"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
		-- Invalid payload
		"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfS4SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
	}

	for i, token in ipairs(invalid_json) do
		local decoded, err = jwt.decode(token, hmac_key)
		testaux.asserteq(decoded, nil, "Case 5."..i..": Should reject invalid JSON")
	end
end

-- Test 6: Empty payload handling
do
	local token, err = jwt.encode({}, hmac_key, "HS256")
	testaux.assertneq(token, nil, "Case 6.1: Should handle empty payload")

	local decoded, err = jwt.decode(token, hmac_key)
	testaux.assertneq(decoded, nil, "Case 6.2: Should decode empty payload")
	testaux.asserteq(type(decoded), "table", "Case 6.2: Empty payload should be table")
end

-- Test 7: Binary data safety
do
	local binary_payload = {data = "\x00\xff\x80\x7f"}
	local token, err = jwt.encode(binary_payload, hmac_key, "HS256")
	testaux.assertneq(token, nil, "Case 7.1: Should handle binary data")

	local decoded, err = jwt.decode(token, hmac_key)
	testaux.asserteq(decoded.data, binary_payload.data, "Case 7.2: Binary data should match")
end

-- Test 8: Key validation
do
	-- Wrong key type
	local ok, err = pcall(jwt.encode, test_payload, {}, "HS256")
	testaux.asserteq(ok, false, "Case 8.1: Should reject invalid key type")

	-- Empty key
	local token, err = jwt.encode(test_payload, "", "HS256")
	testaux.assertneq(token, nil, "Case 8.2: Should handle empty HMAC key")
end

-- Test 9: Header caching verification
do
	local token1, _ = jwt.encode(test_payload, hmac_key, "HS256")
	local token2, _ = jwt.encode(test_payload, hmac_key, "HS256")
	testaux.asserteq(token1:match("^[^.]+"), token2:match("^[^.]+"), "Case 9: Header should be cached")
end

	local rsa_privkey = rsa.new([[
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
]])

	local rsa_pubkey = rsa.new([[
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArS1jFmOYFaqrtJXs1El3
YWk+b8JXYec24aOLaGMQmblozAUz3scCjLV0V1J6xJGb35R3OU2JQOCT1chBABYX
N6N/TNT/nNhZXdSineoyQYkfxDeOOf9w2+fw6T32Ms/6H9sFkuXXu/UO1yRvbWoz
PkZfebhaZoxvet7W7ObB+Fm475r+ap/icx2Yr1bPg7oPz3VBvsgGqugm+0mdpt0Y
USRyQd0fihmYCsv6ldm6mfgoE0hVOthr52Kq2vAMcl9kEkyhghzw+W3M+VXlgJwb
lITB9DEBP2KaudUa6gDYsOpauoU8vacyNALSLXTO7ftTczRFINP3a9mdYg5THrkq
KQIDAQAB
-----END PUBLIC KEY-----
]])

	local ec_privkey = ec.new([[
-----BEGIN EC PRIVATE KEY-----
MHQCAQEEICaCaDvEFIgrZXksCEe/FG1803c71gyUBI362hd8vuNyoAcGBSuBBAAK
oUQDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf/c+hOGwHalqi6V1wAiC1Hcx/
T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END EC PRIVATE KEY-----
]])

	local ec_pubkey = ec.new([[
-----BEGIN PUBLIC KEY-----
MFYwEAYHKoZIzj0CAQYFK4EEAAoDQgAEe26lcpv6zAw3sO0gMwAGQ3QzXwE5IZCf
/c+hOGwHalqi6V1wAiC1Hcx/T7XZiStZF9amqLQOkXul6MZgsascsg==
-----END PUBLIC KEY-----
]])

-- Test 11: RSA algorithm family (RS256/RS384/RS512)
do
	-- Test valid RSA signatures
	local algorithms = {"RS256", "RS384", "RS512"}
	for i, alg in ipairs(algorithms) do
		local token, err = jwt.encode(test_payload, rsa_privkey, alg)
		testaux.assertneq(token, nil, "Case11."..i..": Should generate "..alg.." token")

		local decoded, err = jwt.decode(token, rsa_pubkey)
		testaux.assertneq(decoded, nil, "Case11."..i..": Should verify "..alg.." signature")
	end

	-- Test wrong public key
	local token = jwt.encode(test_payload, rsa_privkey, "RS256")
	local wrong_pub = ec_pubkey
	local decoded, err = jwt.decode(token, wrong_pub)
	print("Test11", decoded, err)
	testaux.asserteq(decoded, nil, "Case11.4: Detect wrong key type")
	testaux.asserteq(err, "signature verification failed", "Case11.4: Detect wrong key type")
end

-- Test 12: ECDSA algorithm family (ES256/ES384/ES512)
do
	-- Test valid ECDSA signatures
	local algorithms = {"ES256", "ES384", "ES512"}
	for i, alg in ipairs(algorithms) do
		local token, err = jwt.encode(test_payload, ec_privkey, alg)
		testaux.assertneq(token, nil, "Case12."..i..": Should generate "..alg.." token")

		local decoded, err = jwt.decode(token, ec_pubkey)
		testaux.assertneq(decoded, nil, "Case12."..i..": Should verify "..alg.." signature")
	end

	-- Test signature tampering
	local token = jwt.encode(test_payload, ec_privkey, "ES256")
	local tampered = token:gsub(".[^.]*$", "invalid_signature")
	local decoded, err = jwt.decode(tampered, ec_pubkey)
	testaux.asserteq(err, "signature verification failed", "Case12.4: Detect ECDSA tampering")
end

-- Test 13: Key type validation
do
	-- RSA key with EC algorithm
	local rsa_privkey = "-----BEGIN RSA PRIVATE KEY-----..."
	local status, err = pcall(jwt.encode, test_payload, rsa_privkey, "ES256")
	testaux.asserteq(status, false, "Case13.1: Reject RSA key with EC algorithm")

	-- EC key with RSA algorithm
	local ec_privkey = "-----BEGIN EC PRIVATE KEY-----..."
	local status, err = pcall(jwt.encode, test_payload, ec_privkey, "RS256")
	testaux.asserteq(status, false, "Case13.2: Reject EC key with RSA algorithm")
end

-- Test 14: Algorithm-specific header validation
do
	local function decode_header(token)
		local header_b64 = token:match("^([^.]+)%.")
		if not header_b64 then return nil end
		local header_json = base64.urlsafe_decode(header_b64)
		if not header_json then return nil end
		return json.decode(header_json)
	end

	local token_hs256 = jwt.encode(test_payload, hmac_key, "HS256")
	local token_rs256 = jwt.encode(test_payload, rsa_privkey, "RS256")
	local token_es256 = jwt.encode(test_payload, ec_privkey, "ES256")

	-- Verify algorithm in decoded header
	local header_hs256 = decode_header(token_hs256)
	testaux.asserteq(header_hs256.alg, "HS256", "Case14.1: HS256 in header")
	testaux.asserteq(header_hs256.typ, "JWT", "Case14.1: JWT type in header")

	local header_rs256 = decode_header(token_rs256)
	testaux.asserteq(header_rs256.alg, "RS256", "Case14.2: RS256 in header")

	-- Verify different algorithms have different headers
	testaux.assertneq(
		token_hs256:match("^[^.]+"),
		token_rs256:match("^[^.]+"),
		"Case14.3: Different headers for different algs"
	)

	-- Additional test: verify ECDSA header
	local header_es256 = decode_header(token_es256)
	testaux.asserteq(header_es256.alg, "ES256", "Case14.4: ES256 in header")
end

