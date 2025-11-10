--- @meta silly.hive.c

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
---@return integer thread_id
function M.spawn(func, ...) end

---Push task to thread
---@param thread_id integer
---@param data any
function M.push(thread_id, data) end

---Get active threads count
---@return integer
function M.threads() end

return M
