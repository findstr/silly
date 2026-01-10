--- @meta silly.perf

---@class silly.perf
local M = {}

---Get high-resolution monotonic time in nanoseconds
---@return integer ns
function M.hrtime() end

---Start profiling a named code section
---@param name string
function M.start(name) end

---Stop profiling a named code section
---@param name string
function M.stop(name) end

---Yield perf (save coroutine state before yield)
function M.yield() end

---Resume perf (restore coroutine state after resume)
---@param co thread
function M.resume(co) end

---Dump profiling data
---@param name? string Optional name to get specific stats
---@return table stats {[name] = {time = ns, call = count}, ...} or {time = ns, call = count}
function M.dump(name) end

return M
