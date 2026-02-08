--- @meta silly.net.cluster.c

---@class silly.net.cluster.context

---@class silly.net.cluster.c
local M = {}

---Create a new cluster instance
---@param hardlimit? integer max body size before error (default 128MB)
---@param softlimit? integer max body size before warning (default 65535)
---@return silly.net.cluster.context cluster
function M.create(hardlimit, softlimit) end

---Pop a message from cluster
---@param cluster silly.net.cluster.context
---@return integer fd
---@return string  dat
---@return integer session
---@return integer? cmd
---@return integer traceid
function M.pop(cluster) end

---Push a message to cluster
---@param cluster silly.net.cluster.context
---@param fd integer file descriptor
---@param ptr lightuserdata pointer
---@param size integer
---@return boolean ok
---@return string? err
function M.push(cluster, fd, ptr, size) end

---Send a request to cluster
---@param cluster silly.net.cluster.context
---@param cmd integer
---@param traceid integer
---@param data string|lightuserdata
---@param size? integer
---@return integer|false session_id, string body_or_error
function M.request(cluster, cmd, traceid, data, size) end

---Send a response to cluster
---@param cluster silly.net.cluster.context
---@param session_id integer
---@param data string|lightuserdata
---@param size? integer
---@return string|false body, string? error
function M.response(cluster, session_id, data, size) end

---Clear cluster
---@param cluster silly.net.cluster.context
---@param fd integer file descriptor
function M.clear(cluster, fd) end

return M
