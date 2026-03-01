local silly = require "silly"
local task = require "silly.task"
local error = error
local setmetatable = setmetatable
local pcall = silly.pcall
local running = task.running
local wakeup = task.wakeup
local tremove = table.remove
local wait = task.wait
local pack = table.pack
local unpack = table.unpack

---@class silly.sync.singleflight.inflight
---@field err string?
---@field [integer]thread

---@class silly.sync.singleflight
---@field fn function
---@field inflight table
local M = {}
local mt = {__index = M}
local cache = setmetatable({}, {__mode = "v"})

---@param fn function
---@return silly.sync.singleflight
function M.new(fn)
	return setmetatable({
		fn = fn,
		inflight = {},
	}, mt)
end

function M:call(key)
	local result
	local inflight = self.inflight
	local flight = inflight[key]
	if not flight then
		flight = tremove(cache) or {}
		inflight[key] = flight
		result = pack(pcall(self.fn, key))
		inflight[key] = nil
		-- Wake all waiters
		for i = 1, #flight do
			local t = flight[i]
			flight[i] = nil
			wakeup(t, result)
		end
		cache[#cache + 1] = flight
	else
		-- Someone else is executing for this key, wait for result
		flight[#flight + 1] = running()
		result = wait()
	end
	if not result[1] then
		error(result[2])
	end
	return unpack(result, 2, result.n)
end

return M
