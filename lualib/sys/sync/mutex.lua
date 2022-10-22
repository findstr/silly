local core = require "sys.core"
local assert = assert
local setmetatable = setmetatable
local remove = table.remove
local running = core.running
local wakeup = core.wakeup
local weakmt = {__mode="v"}
local lockcache = setmetatable({}, weakmt)
local proxycache = setmetatable({}, weakmt)
local lockobj = {}

local M = {}

local function unlock(proxy)
	local l = proxy.lock
	if not l then
		return
	end
	proxy.lock = nil
	l.refn = l.refn - 1
	if l.refn == 0 then
		local waitq = l.waitq
		if waitq and #waitq > 0 then
			co = remove(waitq, 1)
			wakeup(co)
		end
		lockobj[l.key] = nil
		l.owner = nil
		l.key = nil
		lockcache[#lockcache+1] = l
	end
end

local proxymt = {
	__close = function(proxy)
		unlock(proxy)
		proxycache[#proxycache+1] = proxy
	end
}

function M.lock(key)
	local co = running()
	local l = lockobj[key]
	if l then
		if l.owner ~= co then --reentrant mutex
			local q = l.waitq
			if q then
				q[#q + 1] = co
			else
				l.waitq = {co}
			end
			core.wait()
		end
		l.refn = l.refn + 1
	else
		l = remove(lockcache)
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
	end
	proxy = remove(proxycache)
	if not proxy then
		proxy = setmetatable({
			lock = l,
			unlock = unlock,
		}, proxymt)
	else
		proxy.lock = l
	end
	return proxy
end

return M

