local core = require "sys.core"
local zproto = require "zproto"
local rpc = require "cluster.rpc"
local pairs = pairs
local assert = assert
local error = error
local format = string.format
local proto, server, master
local M = {}
local mepoch
local router = {}
local handler = {}
local type_to_workers = {}
local join_r = {
	self = nil,
	workers = nil
}

local function clone(src, dst)
	dst = dst or {}
	for k, v in pairs(src) do
		dst[k] = v
	end
end

local function formatworker(w)
	return format(
[[{type="%s",epoch=%s,status="%s",listen="%s",slot=%s,fd=%s}]],
		w.type, w.epoch, w.status, w.listen,
		w.slot, w.fd, w.heartbeat
	)
end

local function transition_until_success(status)
	local x = {}
	local req = {
		self = x,
		workers = join_r.workers
	}
	clone(join_r.self, x)
	x.status = status
	while true do
		core.log("[worker] join try type:", x.type,
			"listen:", x.listen, "status:",  status)
		local ack, err = master:call("join_r", req)
		if ack and not ack.result then
			assert(ack.epoch)
			assert(ack.slot)
			assert(ack.status == status, ack.status)
			local self = join_r.self
			self.epoch = ack.epoch
			self.slot = ack.slot
			self.status = status
			core.log("[worker] join successfully type:", x.type,
				"listen:", x.listen,
				"mepoch:", ack.mepoch,
				"self:", formatworker(self))
			return ack.mepoch, ack.capacity
		end
		if not ack then
			core.log("[worker] join timeout type:",
				x.type, "listen:", x.listen)
		else
			local res = ack.result
			if res == 1 then
				core.log("[worker] join retry type:",
					x.type, "listen:", x.listen)
			else
				core.log("[worker] join error type:", x.type,
					"listen:", x.listen,
					"status:", ack.status)
				core.exit(1)
			end
		end
		core.sleep(500)
	end
end

local function create_rpc_for_worker(w)
	if w.rpc then
		w.rpc:close()
	end
	core.log("[worker] rpc connect to", w.listen)
	w.rpc = rpc.connect {
		addr = w.listen,
		proto = proto,
		timeout = 5000,
		close = function(fd, errno)
			core.log("[worker] worker close", w.listen)
		end
	}
end

local function worker_join(w, conns_of_type)
	local typ = w.type
	local workers = type_to_workers[typ]
	if not workers then
		return
	end
	local conns = conns_of_type[typ]
	if not conns then
		conns = {}
		conns_of_type[typ] = conns
	end
	local slot = w.slot
	local ww = workers[slot]
	if not ww then
		workers[slot] = w
		if w.status == "run" then
			conns[w.slot] = w
		end
		core.log("[worker] worker_join add", formatworker(w))
		return
	end
	assert(w.epoch >= ww.epoch)
	if w.epoch > ww.epoch then
		if ww.rpc then
			ww.rpc:close()
		end
		clone(w, ww)
		if ww.status == "run" then
			conns[ww.slot] = ww
		end
	elseif w.status ~= ww.status then
		assert(w.status == "run")
		assert(ww.status == "up")
		assert(ww.epoch == w.epoch)
		assert(ww.slot == w.slot)
		assert(ww.listen == w.listen)
		ww.status = w.status
		conns[ww.slot] = ww
	else
		return
	end
	core.log("[worker] worker_join update", formatworker(w))
end

function handler.cluster_r(msg, cmd, fd)
	local conns_of_type = {}
	local workers = msg.workers
	join_r.workers = workers
	core.log("[worker] cluster_r join_r.workers", #workers)
	for _, w in pairs(workers) do
		worker_join(w, conns_of_type)
	end
	for typ, conns in pairs(conns_of_type) do
		for k, v in pairs(conns) do
			create_rpc_for_worker(v)
			conns[k] = v.rpc
		end
		local workers = type_to_workers[typ]
		workers.agent.join(conns, #workers, typ)
	end
	return "cluster_a", {}
end

local function heartbeat()
	local ack, err = master:call("heartbeat_r", {})
	if not ack then
		core.log("[worker] master heartbeat timeout")
		return
	end
	if not ack.mepoch or mepoch and mepoch ~= ack.mepoch then
		local status = join_r.self.status
		assert(status == "up" or status == "run")
		core.log("[worker] master down report to new master")
		mepoch = transition_until_success("run")
	end
end

local function timer()
	local ok, err = core.pcall(heartbeat)
	if not ok then
		core.log("[worker] timer", err)
	end
	core.timeout(1000, timer)
end

function M.more(funcs, __index)
	for k, v in pairs(funcs) do
		local cmd = assert(proto:tag(k), k)
		router[cmd] = v
	end
	if __index then
		setmetatable(router, {__index = __index})
	else
		setmetatable(router, nil)
	end
end

function M.run(funcs, __index)
	M.more(funcs, __index)
	mepoch = transition_until_success("run")
end

function M.up(conf)
	local errno
	local str = require "cluster.proto"
	proto = assert(zproto:parse(str .. conf.proto))
	for k, v in pairs(handler) do
		local cmd = assert(proto:tag(k), k)
		router[cmd] = v
	end
	server, errno = rpc.listen {
		proto = proto,
		addr = conf.listen,
		type = conf.type,
		accept = function(fd, addr)
			core.log("[worker] accept", fd, addr)
		end,
		call = function(msg, cmd, fd)
			local cb = router[cmd]
			if cb then
				return cb(msg, cmd, fd)
			end
			error(format("[worker] call %s %s none", fd, cmd))
		end,
		close = function(fd, errno)
			core.log("[worker] close", fd, errno)
		end
	}
	assert(server, errno)
	master = rpc.connect {
		addr = conf.master,
		proto = proto,
		timeout = 5000,
		close = function(fd, errno)
			core.log("[worker] master close", fd, errno)
		end
	}
	join_r.self = {
		epoch = nil,
		slot = nil,
		type = conf.type,
		status = "start",
		listen = conf.listen,
	}
	for typ, agent in pairs(conf.agents) do
		type_to_workers[typ] = {
			agent = agent
		}
	end
	local _, capacity = transition_until_success("up")
	timer()
	return join_r.self.slot, capacity
end

return M

