--- @meta silly.adt.queue

---@class silly.adt.queue
local M = {}

---@return silly.adt.queue
function M.new() end

---@param self silly.adt.queue
---@param ... any
---@return integer
function M.push(self, ...) end

---@param self silly.adt.queue
---@return any
function M.pop(self) end

---@param self silly.adt.queue
---@return integer
function M.size(self) end

---@param self silly.adt.queue
function M.clear(self) end

return M
