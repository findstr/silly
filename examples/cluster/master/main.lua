local core = require "sys.core"
local master = require "cluster.master"

core.start(function()
	local addr = assert(core.envget("master"), "master")
	local monitor = assert(core.envget("monitor"), "monitor")
	local capacity = {
		['auth'] = 1,
		['gate'] = 2,
		['role'] = 2,
	}
	local ok, err = master.start {
		monitor = monitor,
		listen = addr,
		capacity = capacity
	}
	core.log("[main] start success")
end)

