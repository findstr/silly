local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"

task.fork(function()
	print("-------1")
	silly.exit(0)
	print("exit")
end)
task.fork(function()
	print("-------2")
	silly.exit(1)
end)
time.after(0, function()
	print("-------3")
	silly.exit(1)
end)