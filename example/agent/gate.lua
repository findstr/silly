local core = require "sys.core"
local json = require "sys.json"
local zproto = require "zproto"
local assert = assert
local pairs = pairs
local match = string.match
local tonumber = tonumber
local lprint = core.log
local proto = zproto:parse(require "proto.client")
local M = {}

local gate_count
local gate_rpc = {}
local uid_slot = {}
local worker_type
local worker_handler

local function gate_join(slotid, rpc)
	if not worker_type then
		return
	end
	local req = {
		type = worker_type,
		list = worker_handler
	}
	local ack, err = rpc:call("handle_c",req)
	if not ack then
		lprint("[agent.gate] gate", slotid, "join",
			worker_type, "handle fail", err)
	end
end

function M.join(conns, count)
	if not gate_count then
		gate_count = count
	else
		assert(gate_count == count)
	end
	for i = 1, count do
		local rpc = conns[i]
		if rpc then
			gate_rpc[i] = rpc
			gate_join(i, rpc)
		end
	end
end

function M.info(slotid)
	local rpc = gate_rpc[slotid]
	if not rpc then
		return
	end
	return rpc:call("gateinfo_c")
end

function M.handle(typ, router)
	worker_type = typ
	worker_handler = {}
	for name, _ in pairs(router) do
		worker_handler[#worker_handler+ 1] = name
	end
	if not gate_count then
		return
	end
	local req = {type = worker_type, list = worker_handler}
	for i = 1, gate_count do
		local rpc = gate_rpc[i]
		if rpc then
			local ack, err = rpc:call("handle_c", req)
			if not ack then
				lprint("[agent.gate] gate", i,
					typ, "handle fail", err)
			end
		end
	end
end

function M.token(slotid, uid)
	local rpc = gate_rpc[slotid]
	if not rpc then
		return
	end
	if uid_slot[uid] then
		local ack, err = rpc:call("gatekick_c", {uid = uid})
		if not ack then
			lprint("[agent.gate] gatekick_c uid:", uid, "err:", err)
			return
		end
	end
	uid_slot[uid] = slotid
	local ack, err = rpc:call("gatetoken_c", {uid = uid})
	if not ack then
		lprint("[agent.gate] gatetoken_c uid:", uid, "err:", err)
		return
	end
	return ack.token
end

function M.isready()
	if not gate_count then
		return false
	end
	for i = 1, gate_count do
		if not gate_rpc[i] then
			return false
		end
	end
	return true
end

function M.capacity()
	return gate_count or 0
end

local function restore_online(slotid, rpc)
	for uid, slot in pairs(uid_slot) do
		if slot == slotid then
			uid_slot[uid] = nil
		end
	end
	local ack, err = rpc:call("gateonline_c")
	if not ack then
		lprint("[agent.gate] gateonline_c err:", err)
	end
	return uid_slot
end

function M.restore()
	lprint("[agent.gate] restore gatecount", gate_count)
	for i = 1, gate_count do
		local rpc = gate_rpc[i]
		if rpc then
			restore_online(i, rpc)
		end
	end
	lprint("[agent.gate] restore finish")
	return uid_slot
end

function M.online(uid, slot)
	uid_slot[uid] = slot
end

function M.offline(uid, slot)
	if uid_slot[uid] == slot then
		uid_slot[uid] = nil
	end
end

function M.isonline(uid)
	return uid_slot[uid]
end

function M.forward(uid, cmd, obj)
	local slot = uid_slot[uid]
	if not slot then
		return
	end
	local rpc = gate_rpc[slot]
	if not rpc then
		lprint("[agent.gate] forward uid", uid, cmd, "rpc none")
		return
	end
	obj.uid_ = uid
	rpc:send(cmd, obj)
end

function M.broadcast(cmd, obj)
	local dat = proto:encode(cmd, obj)
	local req = {
		cmd = cmd,
		dat = proto:pack(dat)
	}
	for _, rpc in pairs(gate_rpc) do
		rpc:send("broadcast_c", req)
	end
end

return M

