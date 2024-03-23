local core = require "core"

core.fork(function()
	print("-------1")
	core.exit(0)
	print("exit")
end)
core.fork(function()
	print("-------2")
	core.exit(1)
end)
core.timeout(0, function()
	print("-------3")
	core.exit(1)
end)

