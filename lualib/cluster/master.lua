local core = require "sys.core"
local json = require "sys.json"
local zproto = require "zproto"
local rpc = require "cluster.rpc"
local httpd = require "http.server"
local monitor_html = require "cluster.monitor"
local waitgroup = require "sys.waitgroup"
local type = type
local pairs = pairs
local ipairs = ipairs
local assert = assert
local tonumber = tonumber
local format = string.format
local M = {}
local epoch = 0
local proto, server
local master_epoch = nil
local modify_id = 0
local consistent_id = 0
local worker_total = 0
local fd_to_worker = {}
local listen_to_worker = {}
local type_to_workers= {}
local fd_to_join = {}
local listen_to_join = {}
local restoreing = {}
local router = {}

--[[
worker {
	epoch:integer,
	type:string,
	status:string,	`up,run,down`
	listen:string,
	slot:integer,
	fd:integer,
	heartbeat:long
}
]]

local function clone(a, b)
	b = b or {}
	for k, v in pairs(a) do
		b[k] = v
	end
	return b
end

local function formatworker(w)
	return format(
[[{type="%s",epoch=%s,status="%s",listen="%s",slot=%s,fd=%s,heartbeat=%s}]],
		w.type, w.epoch, w.status, w.listen,
		w.slot, w.fd, w.heartbeat
	)
end

local function create_rpc_for_worker(w)
	if w.rpc then
		if w.connect == w.listen then
			return
		end
		w.rpc:close()
	end
	core.log("[master] rpc connect to", w.listen)
	w.connect = w.listen
	w.rpc = rpc.connect {
		addr = w.listen,
		proto = proto,
		timeout = 5000,
		close = function(fd, errno)
			core.log("[master] worker close", w.listen)
		end,
	}
end

local function join_remove(fd)
	local j = fd_to_join[fd]
	if not j then
		return
	end
	assert(j.fd == fd)
	fd_to_join[fd] = nil
	listen_to_join[j.listen] = nil
end

local function join_start(msg, fd)
	local req = msg.self
	local listen = req.listen
	local j = listen_to_join[listen]
	if j and req.type ~= j.type then
		return false, format("join exist type:%s", j.type)
	end
	local w = listen_to_worker[listen]
	if w and req.type ~= w.type then
		return false, format("listen exist type:%s", w.type)
	end
	if req.slot then -- transition or restore
		if j and req.epoch < j.epoch then
			return false, format("join newer:%s", j.epoch)
		end
		if w and req.epoch < w.epoch then
			return false, format("join newer:%s", j.epoch)
		end
		local w = type_to_workers[req.type][req.slot]
		if w and req.epoch < w.epoch then
			return false, format("join newer:%s", w.epoch)
		end
		if not master_epoch then --restore
			assert(msg.workers, listen)
			restoreing[#restoreing + 1] = msg.workers
		end
	end
	if j then
		join_remove(j.fd)
	end
	req.fd = fd
	fd_to_join[fd] = req
	listen_to_join[listen] = req
	return true
end

local fd_waiting = {}

local function join_accept(w)
	fd_waiting[w.fd] = "success"
	core.log("[master] join accept", formatworker(w))
	return join_remove(w.fd)
end

local function join_fail(w, err)
	fd_waiting[w.fd] = err
	core.log("[master] join fail", formatworker(w), "err:", err)
	return join_remove(w.fd)
end

function router.join_r(msg, cmd, fd)
	local waiting = fd_waiting[fd]
	if not waiting then
		local j = msg.self
		local ok, err = join_start(msg, fd)
		core.log("[master] join_r start fd:", fd,
			"joiner:", formatworker(j),
			"res:", ok, "err:", err)
		if ok then
			modify_id = modify_id + 1
			fd_waiting[fd] = true
			return "join_a", {result = 1}
		else
			return "join_a", {result = -1, status = err}
		end
	else
		if modify_id ~= consistent_id then
			local w = fd_to_worker[fd]
			if w then
				w.heartbeat = core.monotonicsec()
			end
			return "join_a", {result = 1, status = "retry"}
		end
		assert(waiting ~= true)
		join_remove(fd)
		fd_waiting[fd] = nil
		local req = msg.self
		if waiting ~= "success" then
			core.log("[master] join_r fail:",
				waiting,  formatworker(req))
			return "join_a", {result = -1, status = waiting}
		end
		local listen, typ = req.listen, req.type
		local w = listen_to_worker[listen]
		assert(w, listen)
		clone(w, req)
		req.capacity = assert(type_to_workers[typ].count, typ)
		req.mepoch = master_epoch
		core.log("[master] join_r success", formatworker(w))
		return "join_a", req
	end
end

local function worker_join(w)
	local fd = w.fd
	local listen = w.listen
	assert(not listen_to_worker[listen], listen)
	assert(not fd_to_worker[fd], fd)
	local workers = type_to_workers[w.type]
	w.heartbeat = core.monotonicsec()
	workers[w.slot] = w
	listen_to_worker[listen] = w
	fd_to_worker[fd] = w
	join_accept(w)
end

local function worker_clear(w)
	if not w then
		return
	end
	local fd = w.fd
	if fd then
		w.fd = nil
		fd_to_worker[fd] = nil
	end
	w.status = "down"
	type_to_workers[w.type][w.slot] = nil
	listen_to_worker[w.listen] = nil
end

local function worker_down(w)
	local fd = w.fd
	w.fd = nil
	w.status = "down"
	fd_to_worker[fd] = nil
	fd_waiting[fd] = nil
	join_remove(fd)
	core.log("[master] worker down fd:", fd, "worker:", formatworker(w))
end

local function worker_close(fd, errno)
	fd_waiting[fd] = nil
	join_remove(fd)
	local w = fd_to_worker[fd]
	if w then
		assert(w.fd == fd)
		worker_down(w)
	end
	core.log("[master] worker_close", fd, errno)
end

function router.heartbeat_r(msg, cmd, fd)
	local w = fd_to_worker[fd]
	if not w then
		core.log("[master] heartbeat_r strange fd:", fd)
		return "heartbeat_a", {}
	end
	w.heartbeat = core.monotonicsec()
	return "heartbeat_a", {mepoch = master_epoch}
end

local function restore_cluster()
	local now = core.monotonicsec()
	for k, workers in ipairs(restoreing) do
		for _, w in ipairs(workers) do
			local t = w.type
			local workers = assert(type_to_workers[t], t)
			local ww = workers[w.slot]
			local epoch = ww and ww.epoch or 0
			local wid = w.epoch
			if wid > epoch then
				w.status = "down"
				w.heartbeat = now - 100
				workers[w.slot] = w
				listen_to_worker[w.listen] = w
				--restore assume all node is down,
				--so worker has no fd,
				--of course, don't need mark fd_to_worker
			end
			if wid > epoch then
				epoch = wid
			end
		end
		restoreing[k] = nil
	end
end

local function check_down()
	local now = core.monotonicsec() - 5
	for listen, w in pairs(listen_to_worker) do
		if w.status ~= "down" and w.heartbeat < now then
			worker_down(w)
		end
	end
end

local function count_joining()
	local rn, jn = 0, 0
	for _, req in pairs(listen_to_join) do
		if req.slot then
			rn = rn + 1
		else
			jn = jn + 1
		end
	end
	return rn, jn
end

local function merge_by_listen(r, a)
	for k, v in pairs(a) do
		if v.status ~= "down" then
			r[v.listen] = v
		end
	end
end

local function count_by_type(list)
	local type_count = {}
	for _, w in pairs(list) do
		assert(w.status ~= "down", w.listen)
		local t = w.type
		local n = type_count[t]
		n = (n or 0) + 1
		type_count[t] = n
	end
	return type_count

end

local function try_join(j) --process slot and not nil
	local workers = type_to_workers[j.type]
	if not workers then
		join_fail(j, "unkonw "..j.type)
		return
	end
	local slot = j.slot
	if slot then --status transition
		local w = workers[slot]
		assert(j.epoch >= w.epoch)
		local type = j.type
		assert(type == w.type)
		assert(listen_to_worker[w.listen])
		assert(workers[w.slot])
		worker_clear(w)
		w = clone(j, w)
		worker_join(w)
		assert(not (j.status == "up" and w.status == "run"))
		return
	end
	for i = 1, workers.count do
		local w = workers[i]
		if not w or w.status == "down" then
			worker_clear(w)
			w = clone(j, w)
			epoch = epoch + 1
			w.epoch = epoch
			w.slot = i
			worker_join(w)
			return
		end
	end
	join_fail(j, "worker full")
end

local function cluster_workers()
	if consistent_id == modify_id then
		check_down()
		return
	end
	--restore cluster info
	if not master_epoch then
		local rn, jn = count_joining()
		core.log("[master] start restore count:", rn,
			"joining count:", jn, "worker_total:", worker_total)
		if rn > 0 then --exist alive node ? try restore cluster
			if rn <= worker_total // 2 then
				return
			end
			restore_cluster() --restore
		elseif jn < worker_total then
			return
		end
		epoch = (epoch // 1000 + 1) * 1000 + 1
		master_epoch = epoch
		core.log("[master] start success mepoch", master_epoch,
			"modify", modify_id, "consistent", consistent_id)
	end
	check_down()
	--check all standby
	local alive = {}
	merge_by_listen(alive, listen_to_join)
	merge_by_listen(alive, listen_to_worker)
	local type_count = count_by_type(alive)
	for typ, workers in pairs(type_to_workers) do
		local total = workers.count
		local curr = type_count[typ]
		curr = curr or 0
		if curr < total then
			core.log("[master] cluster_r", typ,  "alive:",
				curr, "total:", total, "someone absent")
			return
		end
	end
	--worker join
	local cluster_id = modify_id
	for k, j in pairs(listen_to_join) do
		try_join(j)
	end
	--double check all worker standby
	local type_count = count_by_type(listen_to_worker)
	for typ, workers in pairs(type_to_workers) do
		local n = type_count[typ]
		local count = workers.count
		if n ~= count then
			error(format("standby:"..n .. " count:" .. count))
		end
	end
	--begin cluster_r
	local l = {}
	core.log("[master] cluster_r begin")
	local cluster_r = { workers = l }
	for _, w in pairs(listen_to_worker) do
		core.log("[master] cluster_r worker", formatworker(w))
		l[#l + 1] = w
	end
	local count = 0
	local wg = waitgroup:create()
	for _, w in ipairs(l) do
		wg:fork(function()
			create_rpc_for_worker(w)
			local ack, cmd = w.rpc:call("cluster_r", cluster_r)
			if not ack then
				core.log("[master] cluster_r ",
					w.listen, "err:", cmd)
			else
				count = count + 1
			end
		end)
	end
	wg:wait()
	local total = #l
	if count == total then
		assert(not next(fd_to_join))
		assert(not next(listen_to_join))
		consistent_id = cluster_id
		core.log("[master] cluster_r end total:",
			total, "success consistent",
			consistent_id, "modify", modify_id)
	else
		core.log("[master] cluster_r end total:",
			total, "success:", count)
	end
end

local function timer()
	local ok, err = core.pcall(cluster_workers)
	if not ok then
		core.log("[master] timer", err)
	end
	core.timeout(1000, timer)
end


--[[
listen = "127.0.0.1:8000",
monitor = "127.0.0.1:8080",
capacity = {
	type_x = count_x,
	type_y = count_y,
},
]]

local function collect_status(typ, w, i)
	if not w then
		return {
			name = format("%s[%s]", typ, i),
			status = "absent"
		}
	end
	local s = {
		name = format("%s[%s]", typ, i),
		epoch = w.epoch,
		status = w.status,
		listen = w.listen,
	}
	if not w.rpc then
		return s
	end
	local si = w.rpc:call("status_r")
	if si then
		for k, v in pairs(si) do
			s[k] = v
		end
		local day<const> = 24*3600
		s.memory_fragmentation_ratio =
			format("%.02f", s.memory_rss / s.memory_used)
		s.memory_rss = format("%.02fKiB", s.memory_rss / 1024)
		s.memory_used = format("%.02fKiB", s.memory_used/ 1024)
		s.uptime_in_days = format("%.02f", s.uptime_in_seconds / day)
	end
	return s
end

local function http_monitor(req)
	if req.uri == "/" then
		httpd.write(req.sock, 200,
		{"Content-Type: text/html"},
		monitor_html)
	elseif req.uri == "/status" then
		local status = {}
		for typ, workers in pairs(type_to_workers) do
			local count = workers.count
			for i = 1, count do
				local w = workers[i]
				status[#status + 1] = collect_status(typ, w, i)
			end
		end
		httpd.write(req.sock, 200,
		{"Content-Type: application/json"},
		json.encode(status))
	else
		httpd.write(req.sock, 404,
		{"Content-Type: text/plain"},
		"404 Page Not Found")
	end
end

function M.start(conf)
	local errno
	local str = require "cluster.proto"
	proto = zproto:parse(str)
	server, errno = rpc.listen {
		addr = conf.listen,
		proto = proto,
		accept = function(fd, addr)
			core.log("[master] accept", fd, addr)
		end,
		call = function(msg, cmd, fd)
			return router[cmd](msg, cmd, fd)
		end,
		close = worker_close,
	}
	assert(server, errno)
	for typ, n in pairs(conf.capacity) do
		type_to_workers[typ] = {
			count = tonumber(n),
		}
		worker_total = worker_total + n
	end
	local r = {}
	for k, v in pairs(router) do
		router[k] = nil
		r[proto:tag(k)] = v
	end
	router = r
	timer()
	if conf.monitor then
		httpd.listen {
			port = conf.monitor,
			handler = http_monitor,
		}
	end
end

return M



