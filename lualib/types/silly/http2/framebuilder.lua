--- @meta silly.http2.framebuilder

---@class silly.http2.framebuilder
local M = {}

---@param id integer
---@param maxsize integer
---@param header string
---@param endstream boolean
---@return string
function M.header(id, maxsize, header, endstream) end

---@param id integer
---@param maxsize integer
---@param data string
---@param endstream boolean
---@param offset integer?
---@param size integer?
---@return string
function M.body(id, maxsize, data, endstream, offset, size) end

---@param id integer
---@param errorcode integer
---@return string
function M.rst(id, errorcode) end

---@param flag integer
---@param ... any
---@return string
function M.setting(flag, ...) end

---@param id integer
---@param flag integer
---@param increment integer
---@return string
function M.winupdate(id, flag, increment) end

---@param id integer
---@param errorcode integer
---@return string
function M.goaway(id, errorcode) end

return M
