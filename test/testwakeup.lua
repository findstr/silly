local core = require "silly.core"

local closure = {}

local last = nil

local more = core.fork(function()
	core.wait()
	print("extra")
end)

local function wrap(str, last)
	return function()
		core.wait()
		if last then
			print("#", last)
			core.wakeup(last)
			if str == "test3" then
				core.wakeup(more)
			end
		end
		print(str, "exit")
	end
end

local function create(str)
	if last then
		table.insert(closure, last)
	end
	local tmp =  core.fork(wrap(str, last))
	print(tmp)
	last = tmp
end

return function()
	for i = 1, 5 do
		create("test" .. i)
	end
	core.sleep(100)
	print("--------------")
	core.fork(function ()
		print("-", last)
		core.wakeup(last)
	end)
	core.sleep(100)
	print("testwakeup ok")
end

