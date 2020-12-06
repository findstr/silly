local core = require "sys.core"
local json = require "sys.json"
local zproto = require "zproto"
local assert = assert
local pairs = pairs
local match = string.match
local tonumber = tonumber
local lprint = core.log
local M = {}

local role_count
local role_rpc = {}

function M.join(conns, count)
	if not role_count then
		role_count = count
	else
		assert(role_count == count)
	end
	for i = 1, count do
		local rpc = conns[i]
		if rpc then
			role_rpc[i] = rpc
		end
	end
end

function M.call(uid, cmd, req)
	local rpc = role_rpc[uid % role_count + 1]
	if not rpc then
		return nil, "not ready"
	end
	return rpc:call(cmd, req)
end

function M.online(uid, slot)
	local r = role_rpc[uid % role_count + 1]
	local ack, err = r:call("online_c", {
		uid = uid, slot = slot
	})
	if not ack then
		lprint("[agent.role] online uid", uid, "err", err)
		return nil
	end
	return ack
end

function M.offline(uid, slot)
	local r = role_rpc[uid % role_count + 1]
	local ack, err = r:call("offline_c", {
		uid = uid, slot = slot
	})
	if not ack then
		lprint("[agent.role] online_c uid", uid, "err", err)
		return false
	end
	return true
end



function M.isready()
	if not role_count then
		return false
	end
	for i = 1, role_count do
		if not role_rpc[i] then
			return false
		end
	end
	return true
end

function M.capacity()
	return role_count or 0
end

return M

