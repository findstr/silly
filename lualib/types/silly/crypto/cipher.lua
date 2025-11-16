--- @meta silly.crypto.cipher

---@class silly.crypto.cipher.CTX
local CTX = {}

---Reset cipher context with new key and iv
---@param key string new encryption/decryption key
---@param iv string new initialization vector
function CTX:reset(key, iv) end

---Update cipher with data
---@param data string
---@return string
function CTX:update(data) end

---Finalize cipher operation (optionally with final data block)
---@param data string? optional final data to process
---@return string
function CTX:final(data) end

---Set padding (for block ciphers)
---@param padding integer 1 to enable padding, 0 to disable
function CTX:setpadding(padding) end

---Set Additional Authenticated Data (for AEAD ciphers like GCM)
---@param aad string
function CTX:setaad(aad) end

---Set authentication tag (for AEAD decryption)
---@param tag string
function CTX:settag(tag) end

---Get authentication tag (for AEAD encryption)
---@return string
function CTX:tag() end

---@class silly.crypto.cipher
local M = {}

---Create a new encryptor
---@param algorithm string cipher algorithm (e.g., "aes-256-cbc", "aes-128-gcm")
---@param key string encryption key
---@param iv string? initialization vector
---@return silly.crypto.cipher.CTX
function M.encryptor(algorithm, key, iv) end

---Create a new decryptor
---@param algorithm string cipher algorithm
---@param key string decryption key
---@param iv string? initialization vector
---@return silly.crypto.cipher.CTX
function M.decryptor(algorithm, key, iv) end

return M
