local type = type
local pairs = pairs
local assert = assert
local dgetinfo = debug.getinfo
local dgetupval = debug.getupvalue
local dupvaljoin = debug.upvaluejoin

local function collectup(func,  tbl, unique)
	local info = dgetinfo(func, "u")
	for i = 1, info.nups do
		local up
		local name, val = dgetupval(func, i)
		local utype = type(val)
		if utype == "function" then
			local upval = unique[val]
			if not upval then
				upval = {}
				unique[val] = upval
				collectup(val, upval, unique)
			end
			up = {
				idx = i,
				utype = utype,
				val = val,
				up = upval
			}
		else
			up = {
				idx = i,
				utype = utype,
				val = val,
			}
		end
		tbl[name] = up
	end
end


local function join_val(joined, nfv, nup, rfv, rup)
	assert(type(nfv) == "function")
	assert(type(rfv) == "function")
	for name, nu in pairs(nup) do
		local ru = rup[name]
		if ru then
			local nidx = nu.idx
			local ridx = ru.idx
			assert(ru.utype == nu.utype or not nu.val or not ru.val)
			if nu.utype == "function" then
				local v = nu.val
				if not joined[v] then
					joined[v] = true
					join_val(joined, v, nu.up, ru.val, ru.up)
				end
			else
				dupvaljoin(nfv, nidx, rfv, ridx)
			end
		end
	end
end

local function join_fn(joined, rfv, rup, nfv, nup)
	assert(type(nfv) == "function")
	assert(type(rfv) == "function")
	for name, ru in pairs(rup) do
		local nu = nup[name]
		if nu then
			local nidx = nu.idx
			local ridx = ru.idx
			if nu.utype == "function" then
				assert(ru.utype == nu.utype)
				local v = nu.val
				if not joined[v] then
					joined[v] = true
					join_fn(joined, ru.val, ru.up, nu.val, nu.up)
				end
				dupvaljoin(rfv, ridx, nfv, nidx)
			end
		end
	end
end

return function(newenv, runm, newm)
	local unique = {}
	local val_joined = {}
	local fn_joined = {}
	--join the runm to newm
	for fn, nfv in pairs(newm) do
		local rfv = runm[fn]
		if rfv then
			local ru = {}
			local nu = {}
			collectup(rfv, ru, unique)
			collectup(nfv, nu, unique)
			join_val(val_joined, nfv, nu, rfv, ru)
			join_fn(fn_joined, rfv, ru, nfv, nu)
		end
	end
	--replace runm to newm
	for fn, nfv in pairs(newm) do
		runm[fn] = nfv
	end
	--fix _ENV
	for k, v in pairs(newenv) do
		if not _ENV[k] then
			_ENV[k] = v
		end
	end
	return
end

