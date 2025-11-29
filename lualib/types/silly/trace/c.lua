--- @meta silly.trace.c

---@class silly.trace.c
local M = {}

---Set trace node ID for distributed tracing
---@param node integer
function M.setnode(node) end

---Spawn a new trace ID and return both new and old trace IDs
---@return integer new_traceid
---@return integer old_traceid
function M.spawn() end

---Attach trace ID for current coroutine and return old trace ID
---@param traceid integer?
---@return integer old_traceid
function M.attach(traceid) end

---Resume a coroutine with given trace ID
---@param co thread
---@param traceid integer?
---@param ... any
---@return boolean any...
function M.resume(co, traceid, ...) end
