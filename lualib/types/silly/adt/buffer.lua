---@meta silly.adt.buffer

---@class silly.adt.buffer
local M = {}

---@return silly.adt.buffer
function M.new() end

---@param self silly.adt.buffer
---@param ... any
---@return integer
function M.append(self, ...) end

---@param self silly.adt.buffer
---@param n integer|string
---@return string?, integer
function M.read(self, n) end

---@param self silly.adt.buffer
---@return string
function M.readall(self) end

---@param self silly.adt.buffer
function M.clear(self) end

---@param self silly.adt.buffer
---@return integer
function M.size(self) end

---@param self silly.adt.buffer
---@return table
function M.dump(self) end

return M
