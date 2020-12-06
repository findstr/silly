local core = require "sys.core"
local worker = require "cluster.worker"
local proto = require "proto.cluster"
local gate = require "agent.gate"
local E = {}
local MSG = {}
local role_slot, role_cap

function MSG.online_c(req)
	local uid, slot = req.uid, req.slot
	assert(uid % role_cap + 1 == role_slot)
	print("role online", uid, slot)
	gate.online(uid, slot)
	return "online_a"
end

function MSG.offline_c(req)
	local uid, slot = req.uid, req.slot
	gate.offline(uid, slot)
	print("role offline", uid, slot)
	return "offline_a"
end

function E.foo_r(req)
	gate.broadcast("bar_n", {uid = req.uid_, txt = req.txt})
	return "foo_a"
end

core.start(function()
	local listen = assert(core.envget("role"), "role")
	local master = assert(core.envget("master"), "master")
	role_slot, role_cap = worker.up {
		type = "role",
		listen = listen,
		master = master,
		proto = proto,
		agents = {
			gate = gate,
		}
	}
	gate.handle("role", E)
	gate.restore()
	worker.run(MSG)
	worker.more(E)
	print("ROLE run ok", role_slot)
end)

