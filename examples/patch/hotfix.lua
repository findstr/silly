local patch = require "sys.patch"
local run = require "patch.run"
local ENV = setmetatable({}, {__index = _ENV})
local fix = loadfile("examples/patch/fix.lua", "bt", ENV)()
local P = patch:create()
local up1 = P:collectupval(run)
local up2 = P:collectupval(fix)
local absent = P:join(up2, up1)
print(absent[1], absent[2])
debug.upvaluejoin(up2.foo.val, up2.foo.upvals.b.idx, up2.dump.val, up2.dump.upvals.b.idx)
print("hotfix ok")
for k, v in pairs(fix) do
	run[k] = v
end
for k, v in pairs(ENV) do
	if type(v) == "function" or not _ENV[k] then
		_ENV[k] = v
	end
end

