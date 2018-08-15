local core = require "sys.core"
local testaux = require "testaux"

local total = 30
local WAIT

local function gen_closure(n)
	local now = core.now()
	return function ()
		local delta = core.now() - now
		delta = math.abs(delta - 100 - n)
		print("delta:", delta)
		--precise is 50ms
		testaux.assertle(delta, 100, "timer check delta")
		total = total - 1
		if total == 0 then
			core.wakeup(WAIT)
		end
	end
end

return function()
	for i = 1, total do
		local n = i * 50
		local f = gen_closure(n)
		core.timeout(100 + n, f)
	end
	WAIT = core.running()
	core.wait(WAIT)
end

