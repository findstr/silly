local core = require "sys.core"
local worker = require "saux.cluster.worker"
local proto = require "proto.cluster"
local gate = require "gate"
local router = require "router"
local role = require "agent.role"
local forward = gate.forward
core.start(function()
	local master = assert(core.envget("master"), "master")
	local listen = assert(core.envget("gate"), "gate")
	local slot = worker.up {
		type = "gate",
		listen = listen,
		master = master,
		proto = proto,
		agents = {
			["role"] = role,
		},
	}
	worker.run(router, function(tbl, k)
		tbl[k] = forward
		return forward
	end)
	gate.start(slot)
	core.log("[main] run ok")
end)

