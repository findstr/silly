--- @meta silly.logger.c

---@class silly.logger.c
local M = {}

---Open log file
---@param path string
function M.openfile(path) end

---Get current log level
---@return integer
function M.getlevel() end

---Set log level
---@param level integer?
function M.setlevel(level) end

---Log debug message
---@param ... any
function M.debug(...) end

---Log info message
---@param ... any
function M.info(...) end

---Log warn message
---@param ... any
function M.warn(...) end

---Log error message
---@param ... any
function M.error(...) end

---Log debug message with format string
---@param fmt string
---@param ... any
function M.debugf(fmt, ...) end

---Log info message with format string
---@param fmt string
---@param ... any
function M.infof(fmt, ...) end

---Log warn message with format string
---@param fmt string
---@param ... any
function M.warnf(fmt, ...) end

---Log error message with format string
---@param fmt string
---@param ... any
function M.errorf(fmt, ...) end

return M
