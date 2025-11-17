--- @meta silly.metrics.c

---@class silly.metrics.c
local M = {}

---Get socket polling API name (epoll/kqueue/iocp)
---@return string
function M.pollapi() end

---Get memory allocator name
---@return string
function M.memallocator() end

---Get timer resolution in milliseconds
---@return integer
function M.timerresolution() end

---Get CPU statistics
---@return number system_time
---@return number user_time
function M.cpustat() end

---Get maximum file descriptors limit
---@return integer soft_limit
---@return integer hard_limit
function M.maxfds() end

---Get number of open file descriptors
---@return integer
function M.openfds() end

---Get memory statistics
---@return integer rss_bytes Resident Set Size
---@return integer allocated_bytes Allocated memory
function M.memstat() end

---Get jemalloc statistics (if available)
---@return integer allocated
---@return integer active
---@return integer resident
---@return integer retained
function M.jestat() end

---Get worker thread backlog size
---@return integer
function M.workerstat() end

---Get timer statistics
---@return integer pending
---@return integer scheduled
---@return integer fired
---@return integer canceled
function M.timerstat() end

---Get network statistics
---@return integer tcp_connections
---@return integer sent_bytes
---@return integer received_bytes
---@return integer operate_request
---@return integer operate_processed
function M.netstat() end

---Get socket statistics
---@param sid integer socket ID
---@return table info {fd, os_fd, sent_bytes, type, protocol, localaddr, remoteaddr}
function M.socketstat(sid) end

return M
