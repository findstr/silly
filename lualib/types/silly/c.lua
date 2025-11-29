--- @meta silly.c

---@class silly.c
local M = {}

---Get git SHA1 of the build
---@return string
function M.gitsha1() end

---Get silly version
---@return string
function M.version() end

---Register a callback in the callback table
---@param key any
---@param value any
function M.register(key, value) end

---Get signal name to number mapping
---@return table<string, integer>
function M.signalmap() end

---Watch a signal
---@param signum integer
---@return string? error
function M.signal(signum) end

---Generate a unique ID
---@return integer
function M.genid() end

---Convert lightuserdata buffer to string
---@param ptr lightuserdata
---@param size integer
---@return string
function M.tostring(ptr, size) end

---Get process ID
---@return integer
function M.getpid() end

---Get error string from error code
---@param errno integer
---@return string
function M.strerror(errno) end

---Exit the program
---@param status integer?
function M.exit(status) end

return M
