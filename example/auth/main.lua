local core = require "sys.core"
local zproto = require "zproto"
local gate = require "agent.gate"
local msgserver = require "cluster.msg"
local worker = require "cluster.worker"
local gate_info = {}
local auth_server
local uid_start = 0x123456

local function safe_balance()
	local gateaddr
	local gateslot
	local min = 0xffffffff
	local count = gate.capacity()
	for i = 1, count do
		local ack = gate.info(i)
		if ack then
			if ack.onlinecount < count then
				count = ack.onlinecount
				gateaddr = ack.listenaddr
				gateslot = i
			end
		end
	end
	if gateaddr then
		if gate_info.slot ~= gateslot then
			core.log("[auth] balance gate slot", gateslot, gateaddr)
		end
		gate_info.addr = gateaddr
		gate_info.slot = gateslot
	end
end

local function timer_balance()
	local ok, err = core.pcall(safe_balance)
	if not ok then
		core.log("[auth] timer_balance", err)
	end
	core.timeout(100, timer_balance)
end

local function auth_r(fd, cmd, req)
	if req.passwd ~= "helloworld" then
		auth_server:close(fd)
		return
	end
	if not gate_info.addr then
		core.log("[auth] there is no gate node for", req.account)
		auth_server:close(fd)
		return
	end
	local slot = gate_info.slot
	local addr = gate_info.addr
	local uid = uid_start
	uid_start = uid_start + 1
	local token = gate.token(slot, uid)
	if not token then
		core.log("[auth] there is no gate node for", req.account)
		--may should report a exception
		auth_server:close(fd)
	end
	return auth_server:send(fd, "auth_a", {
		uid = uid,
		gate = addr,
		token = token,
	})
end

local function auth_start()
	timer_balance()
	auth_server = msgserver.listen {
		proto = zproto:parse(require "proto.client"),
		addr = assert(core.envget("auth_listen")),
		accept = function(fd, addr)
			core.log("[auth] auth_server accept", fd, addr)
		end,
		close = function(fd, errno)
			core.log("[auth] auth_server close", fd, errno)
		end,
		data = auth_r
	}
	core.log("[auth] start ok")
end

core.start(function()
	local master = assert(core.envget("master"), "master")
	local listen = assert(core.envget("auth"), "auth")
	worker.up {
		type = "auth",
		listen = listen,
		master = master,
		proto = require "proto.cluster",
		agents = {
			["gate"] = gate,
		}
	}
	while not gate.isready() do
		core.sleep(100)
	end
	gate.restore()
	worker.run({})
	core.log("[main] run ok")
	auth_start()
end)

return start

