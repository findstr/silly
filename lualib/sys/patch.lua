local type = type
local pairs = pairs
local assert = assert
local concat = table.concat
local setmetatable = setmetatable
local getinfo = debug.getinfo
local getupval = debug.getupvalue
local setupvalue = debug.setupvalue
local upvalid = debug.upvalueid
local upvaljoin = debug.upvaluejoin

local M = {}
local mt = {__index = M}

local function collectfn(fn, upvals, unique)
	local info = getinfo(fn, "u")
	for i = 1, info.nups do
		local up
		local name, val = getupval(fn, i)
		local utype = type(val)
		if utype == "function" then
			local upval = unique[val]
			if not upval then
				upval = {}
				unique[val] = upval
				collectfn(val, upval, unique)
			end
			up = {
				idx = i,
				utype = utype,
				val = val,
				upid = upvalid(fn, i),
				upvals = upval
			}
		else
			up = {
				idx = i,
				utype = utype,
				val = val,
				upid = upvalid(fn, i),
			}
		end
		upvals[name] = up
	end
end

function M.create()
	return setmetatable({
		collected = {},
		valjoined = {},
	}, mt)
end

function M:collectupval(f_or_t)
	local upvals = {}
	local t = type(f_or_t)
	local unique = self.collected
	if t == "table" then
		for name, fn in pairs(f_or_t) do
			local x = {}
			collectfn(fn, x, unique)
			upvals[name] = {
				val = fn,
				upvals = x
			}
		end
	else
		collectfn(f_or_t, upvals, unique)
	end
	return upvals
end

local function joinval(f1, up1, f2, up2, joined, path, absent)
	local n = 0
	local depth = #path + 1
	for name, uv1 in pairs(up1) do
		path[depth] = name
		local uv2 = up2[name]
		if uv2 then
			local idx1 = uv1.idx
			local idx2 = uv2.idx
			assert(uv1.utype == uv2.utype or not uv1.val or not uv2.val)
			if uv1.utype == "function" then
				assert(uv2.utype == "function")
				local v = uv1.val
				if not joined[v] then
					joined[v] = true
					n = n + joinval(v, uv1.upvals,
						uv2.val, uv2.upvals,
						joined, path, absent)
				end
			else
				upvaljoin(f1, idx1, f2, idx2)
			end
		elseif name == "_ENV" then
			setupvalue(f1, uv1.idx, _ENV)
			absent[#absent + 1] = concat(path, ".")
		else
			absent[#absent + 1] = concat(path, ".")
		end
		path[depth] = nil
	end
	return n
end

function M:join(f1, up1, f2, up2)
	local n
	local path = {"$"}
	local absent = {}
	local joined = self.valjoined
	if type(f1) == "table" then
		local up1, up2 = f1, up1
		n = 0
		for name, uv1 in pairs(up1) do
			local uv2 = up2[name]
			if uv2 then
				path[2] = name
				n = n + joinval(uv1.val, uv1.upvals,
					uv2.val, uv2.upvals,
					joined, path, absent)
				path[2] = nil
			end
		end
	else
		assert(type(f1) == "function")
		assert(type(f2) == "function")
		path[2] = "#"
		n = joinval(f1, up1, f2, up2, joined, path, absent)
		path[2] = nil
	end
	return absent
end


return M

