local core = require "sys.core"
return function()
	core.fork(function()
		print("-------1")
		core.exit(1)
		print("exit")
	end)
	core.fork(function()
		error("-------2")
	end)
	core.timeout(0, function()
		error("-------3")
	end)
end

