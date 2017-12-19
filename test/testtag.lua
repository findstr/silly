local testaux = require "testaux"
local core = require "sys.core"

local function disp()

end

local function test_core()
	local fd = core.connect("127.0.0.1:9009", disp, nil, "core")
	testaux.assertneq(fd, nil)
	testaux.asserteq(core.tag(fd), "core", "sockettag test fd tag")
	local ok, err = core.pcall(core.close, fd)
	testaux.assertneq(ok, true, "sockettag core.close incorrect tag")
	local ok, err = core.pcall(core.close, fd, "core")
	testaux.asserteq(ok, true, "sockettag core.close correct tag")
end

return function()
	local fd = core.listen("127.0.0.1:9009", disp)
	test_core()
	core.sleep(10)
	core.close(fd)
end
