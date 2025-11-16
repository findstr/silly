--- @meta silly.net.cluster.c

---@class silly.net.cluster.c
local M = {}

---Create a new cluster instance
---@return userdata cluster
function M.create() end

---Pop a message from cluster
---@param cluster userdata
---@return integer fd
---@return string  dat
---@return integer session
---@return integer? cmd
---@return integer traceid
function M.pop(cluster) end

---Push a message to cluster
---@param cluster userdata
---@param fd integer file descriptor
---@param ptr lightuserdata pointer
---@param size integer
function M.push(cluster, fd, ptr, size) end

---Send a request to cluster
---@param cluster userdata
---@param target string
---@param data any
---@return integer session_id
function M.request(cluster, target, data) end

---Send a response to cluster
---@param session_id integer
---@param data string
function M.response(session_id, data) end

---Clear cluster
---@param cluster userdata
---@param fd integer file descriptor
function M.clear(cluster, fd) end

return M
