--- @meta silly.time.c

---@class silly.time.c
local M = {}

---Timer expire message type constant
M.EXPIRE = 0

---Set a timeout timer
---@param expire integer milliseconds
---@param userdata integer? user data to associate with timer
---@return integer session timer session ID
function M.timeout(expire, userdata) end

---Cancel a timer
---@param session integer timer session ID
---@return integer? userdata returns userdata if cancelled successfully, nil if timer not found
function M.timercancel(session) end

---Get current wall clock time in milliseconds
---@return integer
function M.now() end

---Get monotonic time in milliseconds (unaffected by system clock changes)
---@return integer
function M.monotonic() end

return M
