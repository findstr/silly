--- @meta silly.crypto.pkey

---@class silly.crypto.pkey.CTX
local CTX = {}

---Sign data with private key
---@param data string data to sign
---@param algorithm string hash algorithm (e.g., "sha256", "sha1")
---@return string? signature
---@return string? error
function CTX:sign(data, algorithm) end

---Verify signature with public key
---@param data string original data
---@param signature string signature to verify
---@param algorithm string hash algorithm (e.g., "sha256", "sha1")
---@return boolean? valid true if signature is valid, false otherwise
---@return string? error
function CTX:verify(data, signature, algorithm) end

---Encrypt data with public key
---@param data string plaintext
---@param padding integer? RSA padding mode (default: RSA_PKCS1_PADDING)
---@param oaep_md string? OAEP hash algorithm for OAEP padding (e.g., "sha256")
---@return string? ciphertext
---@return string? error
function CTX:encrypt(data, padding, oaep_md) end

---Decrypt data with private key
---@param data string ciphertext
---@param padding integer? RSA padding mode (default: RSA_PKCS1_PADDING)
---@param oaep_md string? OAEP hash algorithm for OAEP padding (e.g., "sha256")
---@return string? plaintext
---@return string? error
function CTX:decrypt(data, padding, oaep_md) end

---@class silly.crypto.pkey
local M = {}

---Create a new public/private key context
---@param key_pem string PEM-encoded key (public or private)
---@param password string? optional password for encrypted private keys
---@return silly.crypto.pkey.CTX? context
---@return string? error
function M.new(key_pem, password) end

return M
