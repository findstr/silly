--- @meta silly.time.c

---@class silly.time.c
local M = {}

---Timer expire message type constant
M.EXPIRE = 0

---Set a timeout timer
---@param expire integer milliseconds
---@return integer session timer session ID
function M.after(expire) end

---Cancel a timer
---@param session integer timer session ID
---@return boolean ok return userdata if cancelled successfully
function M.cancel(session) end

---Get current wall clock time in milliseconds
---@return integer
function M.now() end

---Get monotonic time in milliseconds (unaffected by system clock changes)
---@return integer
function M.monotonic() end

return M
