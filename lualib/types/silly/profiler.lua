--- @meta silly.profiler

---@class silly.profiler
local M = {}

---Start profiling
function M.start() end

---Stop profiling and return results
---@return table
function M.stop() end

---Yield profiler (save coroutine state)
function M.yield() end

---Resume profiler (restore coroutine state)
function M.resume() end

---Dump current profiling data
---@return table
function M.dump() end

return M
