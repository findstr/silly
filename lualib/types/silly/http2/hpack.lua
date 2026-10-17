--- @meta silly.http2.hpack

---@class silly.http2.hpack
local M = {}


---@param hardlimit integer
---@return silly.http2.hpack
function M.new(hardlimit) end

---@param self silly.http2.hpack
---@param header table<string, string>
---@param ... any
---@return string
function M.pack(self, header, ...) end

---@param self silly.http2.hpack
---@param dat string|string[]
---@param header_list string[]
---@param limit integer? -- Decoded field-list size: sum of name/value octets plus 32 per field
---@return boolean success
---@return boolean? limited -- True on limit failure; the complete block still updates the dynamic table
function M.unpack(self, dat, header_list, limit) end

---@param self silly.http2.hpack
--- Sets the table limit. The encoder announces changes at the next block start.
---@param limit integer
function M.hardlimit(self, limit) end

return M
