local core = require "sys.core"
local json = require "sys.json"
local crypto = require "sys.crypto"
local msgserver = require "cluster.msg"
local role = require "agent.role"
local zproto = require "zproto"
local proto = zproto:parse(require "proto.client")
local R = require "router"
local M = {}
local gate_slot
local gate_server
local uid_to_fd = {}
local fd_to_uid = {}
local uid_token = {}
local online_count = 0
local lprint = core.log
local gate_listen = assert(core.envget("gate_listen"))

function R.gateinfo_c(req)
	return "gateinfo_a", {
		listenaddr = gate_listen,
		onlinecount = online_count
	}
end

local function kick(uid)
	local fd = uid_to_fd[uid]
	if fd then
		role.offline(uid, gate_slot)
		uid_to_fd[uid] = nil
		fd_to_uid[uid] = nil
		gate_server:close(fd)
	end
end

function R.gatekick_c(req)
	local uid = req.uid
	kick(uid)
	return "gatekick_a"
end

function R.gatetoken_c(req)
	local uid = req.uid
	kick(uid)
	local token = crypto.randomkey(8)
	uid_token[uid] = token
	return "gatetoken_a", {token = token}
end

function R.gateonline_c(req)
	local uids = {}
	local i = 0
	for uid, _ in pairs(uid_to_fd) do
		i = i + 1
		uids[i] = uid
	end
	return "gateonline_a", {uids = uids}
end

local MSG = {}
function R.handle_c(req)
	print("handle_c", json.encode(req))
	local agent = require("agent." .. req.type)
	for _, name in ipairs(req.list) do
		local id = assert(proto:tag(name), name)
		if not MSG[id] then
			MSG[id] = function(fd, uid, req, cmdx)
				print("forward", fd, uid, req, cmdx)
				local ack, cmd = agent.call(uid, name, req)
				if not ack then
					lprint("[gate] cmd:", name, "fail", cmd)
					return
				end
				print("-------ack", json.encode(ack), cmd)
				local errno = ack.errno
				if errno then
					ack.cmd = proto:tag(ack.cmd)
					gate_server:send(fd, "error_n", ack)
				else
					gate_server:send(fd, cmd, ack)
				end
			end
		end
	end
	return "handle_c"
end

function R.broadcast_c(req)
	local cmd, dat = req.cmd, req.dat
	dat = proto:unpack(dat)
	print("boradcast", cmd, next(uid_to_fd))
	cmd = proto:tag(cmd)
	local send = gate_server.sendbin
	for uid, fd in pairs(uid_to_fd) do
		print("boradcast to", uid, cmd, fd, #dat)
		send(gate_server, fd, cmd, dat)
	end
end

local function login_r(fd, req)
	local uid = req.uid
	local tk2 = req.token
	if uid_token[uid] ~= tk2 then
		kick(uid)
		return
	end
	fd_to_uid[fd] = uid
	uid_to_fd[uid] = fd
	online_count = online_count + 1
	role.online(uid, gate_slot)
	return gate_server:send(fd, "login_a", {})
end


function M.start(slot)
	gate_slot = slot
	gate_server = msgserver.listen {
		proto = proto,
		addr = gate_listen,
		accept = function(fd, addr)
			lprint("[gate] gate_server accept", fd, addr)
		end,
		close = function(fd, errno)
			local uid = fd_to_uid[fd]
			if uid then
				uid_to_fd[uid] = nil
				fd_to_uid[fd] = nil
				online_count = online_count - 1
			end
			lprint("[gate] gate_server close", fd,
				errno, "online", online_count)
		end,
		data = function(fd, cmd, req)
			local uid = fd_to_uid[fd]
			if not uid then
				assert(cmd == proto:tag("login_r"))
				login_r(fd, req)
			else
				MSG[cmd](fd, uid, req, cmd)
			end
		end,
	}
	lprint("[gate] start", slot)
end

return M

