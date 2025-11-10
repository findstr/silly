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

---Set trace node ID for distributed tracing
---@param node integer
function M.tracenode(node) end

---Spawn a new trace ID and return both new and old trace IDs
---@return integer new_traceid
---@return integer old_traceid
function M.tracespawn() end

---Set trace ID for current coroutine
---@param traceid integer?
---@param co thread?
---@return integer old_traceid
function M.traceset(traceid, co) end

---Get current trace ID
---@return integer traceid
function M.traceget() end

return M
