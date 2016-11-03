local core = require "silly.core"

local function gen_closure(n)
	local now = core.now()
	return function ()
		local delta = core.now() - now
		print("do #", n, " delta:", delta)
		delta = math.abs(delta - 100 - n * 10)
		--precise is 10ms
		assert(delta <= 10, delta)
	end
end

for i = 1, 30 do
	local f = gen_closure(i)
	core.timeout(100 + i * 10, f)
end

return function()
	core.sleep(1000)
	print("testtimer ok")
end

