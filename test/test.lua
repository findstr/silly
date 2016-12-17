local core = require "silly.core"

local modules = {
	"testchannel",
	"testcrypt",
	"testdns",
	"testredis",
	"testrpc",
	"testsocket",
	"testudp",
	"testwakeup",
	"testtimer",
	"testnetstream",
	"testhttp",
}

core.start(function()
	local entry = {}
	for k, v in pairs(modules) do
		entry[k] = require(v)
	end

	for k, v in ipairs(modules) do
		print(string.format("======%s start++++++\n", v))
		assert(entry[k])()
		print(string.format("\n======%s over------\n", v))
		print("\n")
	end
	core.exit()
end)




