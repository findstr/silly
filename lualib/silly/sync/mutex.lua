local silly = require "silly"
local assert = assert
local setmetatable = setmetatable
local remove = table.remove
local running = silly.running
local wakeup = silly.wakeup
local weakmt = {__mode="v"}
local lockcache = setmetatable({}, weakmt)
local proxycache = setmetatable({}, weakmt)

---@class silly.sync.mutex
---@field lockobj table
local M = {}
local mt = {__index = M}

local function unlock(proxy)
	local l = proxy.lock
	if not l then
		return
	end
	proxy.lock = nil
	l.refn = l.refn - 1
	if l.refn == 0 then
		local lockobj = proxy.lockobj
		local waitq = l.waitq
		if waitq and #waitq > 0 then
			local co = remove(waitq, 1)
			l.refn = 1
			l.owner = co
			wakeup(co)
		else
			lockobj[l.key] = nil
			l.owner = nil
			l.key = nil
			lockcache[#lockcache+1] = l
		end
	end
	proxy.lockobj = nil
end

local proxymt = {
	__close = function(proxy)
		unlock(proxy)
		proxycache[#proxycache+1] = proxy
	end
}

---@return silly.sync.mutex
function M.new()
	return setmetatable({
		lockobj = {},
	}, mt)
end

---@param co thread
local function new_lock(key, co)
	local l = remove(lockcache)
	if l then
		l.key = key
		l.owner = co
		l.refn = 1
	else
		l = {
			key = key,
			owner = co,
			refn = 1,
		}
	end
	return l
end

function M:lock(key)
	local co = running()
	local lockobj = self.lockobj
	local l = lockobj[key]
	if l then
		if  l.owner == co then --reentrant mutex
			l.refn = l.refn + 1
		else
			local q = l.waitq
			if q then
				q[#q + 1] = co
			else
				l.waitq = {co}
			end
			silly.wait()
		end
	else
		l = new_lock(key, co)
		lockobj[key] = l
	end
	local proxy = remove(proxycache)
	if not proxy then
		proxy = setmetatable({
			lock = l,
			unlock = unlock,
		}, proxymt)
	else
		proxy.lock = l
	end
	proxy.lockobj = lockobj
	return proxy
end

return M

