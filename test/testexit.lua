local core = require "core"
local time = require "core.time"

core.fork(function()
	print("-------1")
	core.exit(0)
	print("exit")
end)
core.fork(function()
	print("-------2")
	core.exit(1)
end)
time.after(0, function()
	print("-------3")
	core.exit(1)
end)