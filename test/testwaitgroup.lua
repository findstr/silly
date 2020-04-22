local core = require "sys.core"
local testaux = require "testaux"
local waitgroup = require "sys.waitgroup"

return function()
	local wg = waitgroup:create()
	local count = 0
	for i = 1, 5 do
		wg:fork(function()
			core.sleep(500)
			count = count + 1
			assert(count ~= 5)
			print("finish", count)
		end)
	end
	wg:wait()
	testaux.asserteq(count, 5, "wait")
end

