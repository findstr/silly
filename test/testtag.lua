local testaux = require "testaux"
local core = require "sys.core"

local function disp()

end

local function test_core()
	local fd = core.connect("127.0.0.1@9009", disp, nil, "core")
	print("core connect:", fd, core.tag(fd))
	assert(fd >= 0)
	testaux.asserteq(core.tag(fd), "core", "testtag test fd tag")
	local ok, err = core.pcall(core.close, fd)
	testaux.assertneq(ok, true, "testtag test core.close incorrect tag")
	local ok, err = core.pcall(core.close, fd, "core")
	testaux.asserteq(ok, true, "testtag test core.close incorrect tag")
end

return function()
	local fd = core.listen("127.0.0.1@9009", disp)
	test_core()
	core.sleep(10)
	core.close(fd)
end
