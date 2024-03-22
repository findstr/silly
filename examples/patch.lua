local console = require "core.console"
local run = require "examples.patch.run"

console {
	addr = "127.0.0.1:2345",
	cmd = {
		foo = function()
			run.foo()
			local a, b = run.dump()
			return string.format("a:%s,b:%s,step:%s", a, b, tostring(STEP))
		end,
		bar = function()
			run.bar()
			local a, b = run.dump()
			return string.format("a:%s,b:%s,step:%s", a, b, tostring(STEP))
		end
	}
}

