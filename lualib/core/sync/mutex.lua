local core = require "core"
local setmetatable = setmetatable
local remove = table.remove
local running = core.running
local wakeup = core.wakeup
local weakmt = {__mode="v"}
local lockcache = setmetatable({}, weakmt)
local proxycache = setmetatable({}, weakmt)

---@class core.sync.mutex
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
			wakeup(co)
		end
		lockobj[l.key] = nil
		l.owner = nil
		l.key = nil
		lockcache[#lockcache+1] = l
	end
	proxy.lockobj = nil
end

local proxymt = {
	__close = function(proxy)
		unlock(proxy)
		proxycache[#proxycache+1] = proxy
	end
}

---@return core.sync.mutex
function M.new()
	return setmetatable({
		lockobj = {},
	}, mt)
end

---@param co thread
local function lockkey(lockobj, key, co)
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
	lockobj[key] = l
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
			core.wait()
			l = lockkey(lockobj, key, co)
		end
	else
		l = lockkey(lockobj, key, co)
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

