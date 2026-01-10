--- @meta silly.hive.c

---@class silly.hive.worker

---@class silly.hive.c
local M = {}

---Done status constant
M.DONE = 0

---Set thread limit
---@param limit integer
function M.limit(limit) end

---Prune idle threads
function M.prune() end

---Spawn a new thread
---@param func function
---@param ... any
---@return silly.hive.worker
function M.spawn(func, ...) end

---Push task to thread
---@param worker silly.hive.worker
---@param data any
---@return integer task_id
function M.push(worker, data) end

---Get active threads count
---@return integer
function M.threads() end

return M
