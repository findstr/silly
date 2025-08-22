local ec = require 'core.crypto.ec'
local rsa = require 'core.crypto.rsa'
local hmac = require 'core.crypto.hmac'
local base64 = require 'core.encoding.base64'
local json = require 'core.encoding.json'
local jsonencode = json.encode
local jsondecode = json.decode
local b64encode = base64.urlsafe_encode
local b64decode = base64.urlsafe_decode

local jwt = {}

local hmac_digest = hmac.digest
local function hmac_verify(key, data, sig, alg)
	return hmac_digest(key, data, alg) == sig
end

local alg_map = {
	['ES256'] = {
		sign = ec.sign,
		verify = ec.verify,
		hash = "sha256"
	},
	['ES384'] = {
		sign = ec.sign,
		verify = ec.verify,
		hash = "sha384"
	},
	['ES512'] = {
		sign = ec.sign,
		verify = ec.verify,
		hash = "sha512"
	},
	['RS256'] = {
		sign = rsa.sign,
		verify = rsa.verify,
		hash = "sha256"
	},
	['RS384'] = {
		sign = rsa.sign,
		verify = rsa.verify,
		hash = "sha384"
	},
	['RS512'] = {
		sign = rsa.sign,
		verify = rsa.verify,
		hash = "sha512"
	},
	['HS256'] = {
		sign = hmac_digest,
		verify = hmac_verify,
		hash = "sha256"
	},
	['HS384'] = {
		sign = hmac_digest,
		verify = hmac_verify,
		hash = "sha384"
	},
	['HS512'] = {
		sign = hmac_digest,
		verify = hmac_verify,
		hash = "sha512"
	},
}

local header_cache = setmetatable({}, {
	__mode = "v",
	__index = function(t, k)
		local obj = {
			alg = k,
			typ = 'JWT',
		}
		local dat = b64encode(json.encode(obj))
		t[k] = dat
		return dat
	end,
})

--- @param payload table
--- @param key userdata|string
--- @param algname string
--- @return string|nil, string|nil
function jwt.encode(payload, key, algname)
	algname = algname or "HS256"
	local alg = alg_map[algname]
	if not alg then
		return nil, 'unsupported algorithm: ' .. algname
	end
	local header_b64 = header_cache[algname]
	-- marshal payload
	local payload_json = jsonencode(payload)
	local payload_b64 = b64encode(payload_json)
	-- build signing input
	local signing_input = header_b64 .. '.' .. payload_b64
	local sign = alg.sign(key, signing_input, alg.hash)
	local sig_b64 = b64encode(sign)
	return header_b64 .. '.' .. payload_b64 .. '.' .. sig_b64, nil
end

--- @param token string
--- @param key userdata|string
--- @return table|nil, string|nil
function jwt.decode(token, key)
	local header_b64, payload_b64, signature_b64 = token:match("([^.]+).([^.]+).([^.]+)")
	if not header_b64 or not payload_b64 or not signature_b64 then
		return nil, 'invalid token format'
	end
	-- parse header
	local header_json = b64decode(header_b64)
	if not header_json then
		return nil, 'invalid header'
	end
	local header, _ = jsondecode(header_json)
	if not header then
		return nil, 'invalid header'
	end
	local algname = header.alg
	local alg = alg_map[algname]
	if not alg then
		return nil, 'unsupported algorithm: ' .. algname
	end
	-- parse payload
	local payload_json = b64decode(payload_b64)
	if not payload_json then
		return nil, 'invalid payload'
	end
	local payload, _ = jsondecode(payload_json)
	if not payload then
		return nil, 'invalid payload'
	end
	-- parse signature
	local sig = b64decode(signature_b64)
	if not sig then
		return nil, 'invalid signature'
	end
	local signing_input = header_b64 .. '.' .. payload_b64
	if not alg.verify(key, signing_input, sig, alg.hash) then
		return nil, 'signature verification failed'
	end
	return payload, nil
end

return jwt