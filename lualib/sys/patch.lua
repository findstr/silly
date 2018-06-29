local type = type
local pairs = pairs
local assert = assert
local dgetinfo = debug.getinfo
local dgetupval = debug.getupvalue
local dupvaljoin = debug.upvaluejoin

local function collectup(func,  tbl)
	local info = dgetinfo(func, "u")
	for i = 1, info.nups do
		local name, val = dgetupval(func, i)
		local up
		if type(val) == "function" then
			up = {
				idx = i,
				uname = name,
				utype = type(val),
				val = val,
				up = {}
			}
			collectup(val, up.up)
		else
			up = {
				idx = i,
				uname = name,
				uptype = type(val),
				val = val,
				up = val,
			}
		end
		tbl[name] = up
	end
end


local function patchup(cache, fix, fixup, run, runup)
	assert(type(run) == "function")
	assert(type(fix) == "function")
	local info = dgetinfo(run, "u")
	for i = 1, info.nups do
		local name, val = dgetupval(run, i)
		if fixup[name] then
			local rup = runup[name]
			local fup = fixup[name]
			assert(rup.idx == i)
			if (type(val) == "function") and (not cache[val]) then
				assert(rup.val == val)
				patchup(cache, fup.val, fup.up, rup.val, rup.up)
			else
				dupvaljoin(fix, fup.idx, run, rup.idx)
			end
		end
	end
	cache[fix] = true
end

local function patch(cache, fixfunc, runfunc, ...)
	if not fixfunc then
		assert(not runfunc)
		return
	end
	local runup = {}
	local fixup = {}
	collectup(runfunc, runup)
	collectup(fixfunc, fixup)
	patchup(cache, fixfunc, fixup, runfunc, runup)
	return patch(cache, ...)
end

return function(fixenv, ...)
	local cache = {}
	patch(cache, ...)
	for k, v in pairs(fixenv) do
		if not _ENV[k] then
			_ENV[k] = v
		end
	end
	return
end

