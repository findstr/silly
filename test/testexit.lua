local silly = require "silly"
local time = require "silly.time"

silly.fork(function()
	print("-------1")
	silly.exit(0)
	print("exit")
end)
silly.fork(function()
	print("-------2")
	silly.exit(1)
end)
time.after(0, function()
	print("-------3")
	silly.exit(1)
end)