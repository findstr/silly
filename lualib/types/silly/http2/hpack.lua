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
---@return boolean
function M.unpack(self, dat, header_list) end

---@param self silly.http2.hpack
---@param limit integer
function M.hardlimit(self, limit) end

return M
