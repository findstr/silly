--- @meta silly.signal.c

---@class silly.signal.c
local M = {}

---Signal fire message type constant
M.FIRE = 0

---Get signal name to number mapping
---@return table<string, integer>
function M.signalmap() end

---Watch a signal
---@param signum integer
---@return string? error
function M.signal(signum) end

return M
