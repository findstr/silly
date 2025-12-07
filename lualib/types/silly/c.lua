--- @meta silly.c

---@class silly.c
---@field public gitsha1 string Get git SHA1 of the build
---@field public version string Get silly version
---@field public pid integer Get process ID
---@field public multiplexer string Get socket multiplexer name
---@field public allocator string Get memory allocator name
---@field public timerresolution integer Get timer resolution in milliseconds
local M = {}

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

---Exit the program
---@param status integer?
function M.exit(status) end

return M
