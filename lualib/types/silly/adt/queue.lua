--- @meta silly.adt.queue

---@class silly.adt.queue<T>
local M = {}

---@generic T
---@return silly.adt.queue<T>
function M.new() end

---@generic T
---@param self silly.adt.queue<T>
---@param value T
---@return integer size
function M.push(self, value) end

---@generic T
---@param self silly.adt.queue<T>
---@return T? value
function M.pop(self) end

---Remove the first raw-equal value in FIFO order, preserving the remaining order. O(n).
---@generic T
---@param self silly.adt.queue<T>
---@param value T
---@return boolean removed
function M.remove(self, value) end

---@generic T
---@param self silly.adt.queue<T>
---@return integer size
function M.size(self) end

---@generic T
---@param self silly.adt.queue<T>
function M.clear(self) end

return M
