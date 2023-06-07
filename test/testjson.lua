local json = require "sys.json"
local testaux = require "testaux"

local obj = {
	[1] = {
		a = 3.5,
		b = "hello",
		c = -5,
	},
	[2] = {
		a = "hello",
		b = "-5",
		c = "3.5"
	},
	[3] = {
		c = {-5}
	},
}

return function()
	local str = json.encode(obj)
	print('encode:', str)
	local res = json.decode(str)
	print('decode:', res)
	for i = 1, #obj do
		local s = obj[i]
		local d = res[i]
		for k, v in pairs(s) do
			testaux.asserteq(s[k], d[k],
				string.format("obj[%s].%s == obj[%s].%s",
				i, k, i, k))
		end
	end
end

