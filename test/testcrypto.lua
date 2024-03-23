local crypto = require "core.crypto"
local testaux = require "test.testaux"
local P = require "print"

---------------------test hamc
local hmac_key = "test"
local hmac_body = "helloworld"
local res = crypto.hmac(hmac_key, hmac_body)
print(string.format("hmac key:%s body:%s, res:", hmac_key, hmac_body))
P.hex(hmac_body)
P.hex(res)
---------------------test aes
local aes1_key = "lilei"
local aes1_body = "hello"
local aes2_key = "hanmeimei"
local aes2_body = "1234567891011121314151612345678910111213141516"
local aes1_encode = crypto.aesencode(aes1_key, aes1_body)
local aes2_encode = crypto.aesencode(aes2_key, aes2_body)
local aes1_decode = crypto.aesdecode(aes1_key, aes1_encode)
local aes2_decode = crypto.aesdecode(aes2_key, aes2_encode)
testaux.asserteq(aes1_decode, aes1_body, "aes test decode success")
testaux.asserteq(aes2_decode, aes2_body, "aes test decode success")
local incorrect = crypto.aesdecode(aes2_key, aes1_encode)
testaux.assertneq(incorrect, aes1_body, "aes test decode fail")
local incorrect = crypto.aesdecode("adsafdsafdsafds", aes1_encode)
testaux.assertneq(incorrect, aes1_body, "aes test decode fail")
local incorrect = crypto.aesdecode("fdsafdsafdsafdadfsa", aes2_encode)
testaux.assertneq(incorrect, aes2_body, "aes test decode fail")
--test dirty data defend
crypto.aesdecode("fdsafdsafdsafdsafda", aes2_body)
----------------------test base64
local plain = "aGVsbG8sIG15IGZyaWVuZCwgeW91IGtvbncgaSBkb24ndCBnb29kIGF0IGNy\xff\xef"
local e1 = crypto.base64encode(plain)
local e2 = crypto.base64encode(plain, "url")
testaux.assertneq(e1, e2, "base64 encode normal and url safe mode")
local d1 = crypto.base64decode(e1)
local d2 = crypto.base64decode(e2)
testaux.asserteq(d1, plain, "base64 normal test encode/decode success")
testaux.asserteq(d2, plain, "base64 url safe test encode/decode success")
local d3 = crypto.base64decode("====")
testaux.asserteq(d3, "", "base64 decode empty success")
---------------------test sha256
local x = crypto.sha256("aGVsbG8sIG15IGZyaWVuZCwgeW91IGtvbncgaSBkb24ndCBnb29kIGF0IGNy")
testaux.asserteq(x, "a3f0f2484b434eb7e3b7dbf89a3b2192c5577a3d51bb65d766a1abedb57aea8c","sha256 hash")
if crypto.digestsign then
	local rsa_pub =
'-----BEGIN PUBLIC KEY-----\n\z
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2LewXe+8fkojFjTQ+pRq\n\z
e29jKHJXcoqEc4D2GDNNdq32GjloPFidVvnlDhOForS5fH5jlqzvcG0mvzAGkmU3\n\z
Zz5fkrRkiKa+/EyHkiHk+h/VZgCPXendLCVL47Zeh4wPwyA7sV6Ns4O+KRn26xAZ\n\z
KBeLP8QuuBd68nRMLZMseMyUz+foVv22FvZ/SdqIeG8IZOSzoN2WJOPy+kYRxdS7\n\z
6Jc0QT6pK/zwpxwzhoLXu6HRzJaPZZ2epjilkKHtBj44svzywj1KAK4VDBkCHgGr\n\z
h/2sfHCcNJhxDw4G8tB1oiX+uZclwBMSuOJiu6dD1/IBt4FwzvLZghhgHW7ziJoA\n\z
dQIDAQAB\n\z
-----END PUBLIC KEY-----'
	local rsa_pri =
'-----BEGIN RSA PRIVATE KEY-----\n\z
MIIEpQIBAAKCAQEA2LewXe+8fkojFjTQ+pRqe29jKHJXcoqEc4D2GDNNdq32Gjlo\n\z
PFidVvnlDhOForS5fH5jlqzvcG0mvzAGkmU3Zz5fkrRkiKa+/EyHkiHk+h/VZgCP\n\z
XendLCVL47Zeh4wPwyA7sV6Ns4O+KRn26xAZKBeLP8QuuBd68nRMLZMseMyUz+fo\n\z
Vv22FvZ/SdqIeG8IZOSzoN2WJOPy+kYRxdS76Jc0QT6pK/zwpxwzhoLXu6HRzJaP\n\z
ZZ2epjilkKHtBj44svzywj1KAK4VDBkCHgGrh/2sfHCcNJhxDw4G8tB1oiX+uZcl\n\z
wBMSuOJiu6dD1/IBt4FwzvLZghhgHW7ziJoAdQIDAQABAoIBAQDIkuGBXzM2Mwlc\n\z
MQ/FCv2uNj4wnfq/QOIrQI0Dgt/L2l9uj/kf+OfOKsRLDdhd6SPOy+8B8hY9GFiH\n\z
FDzQ2yq2vCyaS6jMLH+QZIgIwKP6tuG7YQNPaPXROMeO/idpDkE8V6XHl/pPzbt+\n\z
sNAtaB3QVFIFd13B9cFNikNC3vaG6SUD1hfY9N6bRi1OLGwQwxJHbTlQ/S+PD12t\n\z
ziFwZEiCEmr/vyV+9BcwGYTu613M4XJKkTy021NuXpUnBegpds4NSQt3vtJGsZej\n\z
W3RXeidUZCbHy/UzOUIUewk50xpK7qxDYaNMYEBs6qSSnSswO/2tdvlb/m6eby8+\n\z
Aa05IiT1AoGBAPPNllvLaPlQ8fctGivUCmalgbEmnVox2kiHQLkzJlZT0muO6oMs\n\z
GnjvQzlBYBk8YnEK3a6fZowY3vdXUI/wO4vVoIp/SxzrXd3A20IxPrDFKJR6X3lH\n\z
smMEe6Ib16gXDTWySwqOGXLSycMjA5zW2gE36M5Yy+iJ5Gp8OofJMdGDAoGBAOOP\n\z
NtAZjfGvu+A/3AS2uyH3ksicwaB0ClvtvmwQ0JaW0fkX6vDS6n2KsVRI9VPYi7pM\n\z
/bTO14VyRnDe7evlhkEWV7+wD0s7pTNPVKBn38xt6GgPbRyQbpb3gtvw8sAFOm1B\n\z
d0WGAkx7ea2XNJJJtD18/3DG4EPP159sXhXqEBynAoGAStVL1Zk1+3DRFGGPquxG\n\z
1QLwMAP+QHUU3zZEs5PzrIPGDqWrbd/XsE8gfy6F5LkYLkJ7kOH0hAQOTDVM0SGX\n\z
5XAI+vnfgFzuTuanZkXfTDr4HbsCGyPaqXHy0Oti4oFQ2K6FQhQj047Hx1G0Biwc\n\z
dktG9i9jR1kr91NyU8N5uykCgYEA22SLMy1AFeEZIMZQyNaoKsJ3aSUA5UKbbjAT\n\z
5Dp98IHuZNrzb0XaQDmEaD+DD1h6tp5eCIFXdthLI60687Exs/Tnmu8Sf7U8u/Bj\n\z
JdegBId+hz1ANEbn6HMvXf+6+vjPcOCqLoRaGQT+tidOzy9yL8oguMl1FMwBFjoz\n\z
p6sn54cCgYEAi0g89uogqIYsBnTHi9jWDaordsSJdcZyRzq7wlb8sTeBpJEHOdzo\n\z
whjjqZDjAW0a+58OPaKcDbTriqug9XvsIs25+7htJysO/yzTOIzTGb1pqJ1ZkeNs\n\z
w0W5t0qWE/d60ztwcVCUSINIb680yZexrobYH+tlpsVIdXxjcHPU2o4=\n\z
-----END RSA PRIVATE KEY-----'
	local ec_secp256k1_pri =
'-----BEGIN EC PRIVATE KEY-----\n\z
MHQCAQEEIHmXrEOL6We4OA9zJ8FOCe/Ed2efH+bi6bfn/0OYGzSqoAcGBSuBBAAK\n\z
oUQDQgAESYuWA8FXcHPPPuLj2uAuZRWQwRKEcayXWwXR47rGwMaQzNIhIHxkwbdZ\n\z
bd9rXq9Xrhow8xvLeInIGibcx27f1w==\n\z
-----END EC PRIVATE KEY-----'
	local ec_secp256k1_pub =
'-----BEGIN PUBLIC KEY-----\n\z
MFYwEAYHKoZIzj0CAQYFK4EEAAoDQgAESYuWA8FXcHPPPuLj2uAuZRWQwRKEcayX\n\z
WwXR47rGwMaQzNIhIHxkwbdZbd9rXq9Xrhow8xvLeInIGibcx27f1w==\n\z
-----END PUBLIC KEY-----'

	local sig = crypto.digestsign(rsa_pri, "hello", "SHA256")
	local ver = crypto.digestverify(rsa_pub, "hello", sig, "SHA256")
	testaux.asserteq(testaux.hextostr(sig),
	'7169cb0696fc074feb26296b9801833277cd7fce836\z
	6ccdb01f228fd0ee058e063374856d3316df9628774d\z
	fbb5aab1b378304423a5f872b8aa0efcd86f08dc05fe\z
	b74d4fb885242ef925f3ca79d3925dd19f143d8caf2d\z
	ee3eec28ed632491b5aae85b8cc2ebab4682a7f0adbe\z
	33383e1d12a8b9d4ab7d0a005d14c0bc5b3608558211\z
	91271a43e60347be0d791cfaef174e8692aacb0b695e\z
	e3c3ed7a2371661c432d7ff0ceb6c457b034829998d9\z
	369f85e72cbfe93705bd2de73b27f06bae5bd9998256\z
	bc838a4141149e731a78a96e0b82f413fdb5f41bf45d\z
	dcb157e254a6e959275fce64e7e7de25aa5017590e49\z
	e06588b8ca903bea4fa4862df0846', "SHA256withRSA sign success")
	local ok = crypto.digestverify(rsa_pub, "hello", sig, "sha256")
	testaux.asserteq(ok, true, "SHA256withRSA verify success")
	local ok = crypto.digestverify(rsa_pub, "hellox", sig, "sha256")
	testaux.asserteq(ok, false, "SHA256withRSA verify invalid")
	local sig = crypto.digestsign(ec_secp256k1_pri, "hello", "sha256")
	local ok = crypto.digestverify(ec_secp256k1_pub, "hello", sig, "sha256")
	testaux.asserteq(ok, true, "SHA256withECDSA verify success")
	local ok = crypto.digestverify(ec_secp256k1_pub, "hellox", sig, "sha256")
	testaux.asserteq(ok, false, "SHA256withECDSA verify invalid")
end


