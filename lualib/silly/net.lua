local silly = require "silly"
local logger = require "silly.logger.c"
local c = require "silly.net.c"

local assert = assert
local smatch = string.match

local task_running = silly.running
local task_create = silly._task_create
local task_resume = silly._task_resume
local log_info = assert(logger.info)
local log_error = assert(logger.error)

local M = {}

---@class silly.net.event
---@field accept fun(fd:integer, listenid:integer, addr:string)?
---@field close fun(fd:integer, errno:integer)
---@field data fun(fd:integer, msg:lightuserdata, size:integer)|fun(fd:integer, msg:lightuserdata, addr:string?)

--socket
local socket_pending = {}
local accept_callback = {}
local data_callback = {}
local close_callback = {}

local ip_pattern = "%[-([0-9A-Fa-f:%.]*)%]-:([0-9a-zA-Z]+)$"

---@type fun(ip:string, port:string, backlog:integer):integer?, string? error
local tcp_listen = assert(c.tcp_listen)
---@type fun(ip:string, port:string, bind_ip:string, bind_port:string):integer?, string? error
local tcp_connect = assert(c.tcp_connect)
---@type fun(ip:string, port:string):integer?, string? error
local udp_bind = assert(c.udp_bind)
---@type fun(ip:string, port:string, bind_ip:string, bind_port:string):integer?, string? error
local udp_connect = assert(c.udp_connect)
---@type fun(fd:integer):boolean, string? error
local socket_close = assert(c.close)
---@type fun(fd:integer, data:string|lightuserdata|table, size:integer|nil):boolean, string? error
M.tcpsend = assert(c.tcp_send)
---@type fun(fd:integer, data:string|lightuserdata|table, size_or_addr:integer|string|nil, addr:string|nil):boolean, string? error
M.udpsend = assert(c.udp_send)
---@type fun(fd:integer, data:lightuserdata, size:integer?, addr:string?): boolean, string? error
M.tcpmulticast = assert(c.tcp_multicast)

M.multipack = assert(c.multipack)
---@type fun(fd:integer):integer
M.sendsize = assert(c.sendsize)
local function listen_wrap(listen)
	---@param addr string
	---@param event silly.net.event
	---@param backlog integer|nil
	---@return integer|nil, string|nil
	return function(addr, event, backlog)
		local ip, port = smatch(addr, ip_pattern)
		if ip == "" then
			ip = "0::0"
		end
		if not backlog then
			backlog = 256 --this constant come from linux kernel comment
		end
		local fd, err = listen(ip, port, backlog);
		if fd  then
			assert(socket_pending[fd] == nil)
			socket_pending[fd] = task_running()
			err = silly.wait()
			socket_pending[fd] = nil
			if err then
				return nil, err
			end
			accept_callback[fd] = event.accept
			close_callback[fd] = assert(event.close)
			data_callback[fd] = assert(event.data)
			return fd, nil
		end
		log_error("[net] listen", port, "error", err)
		return nil, err
	end
end

local function connect_wrap(connect)
	---@param addr string
	---@param event silly.net.event
	---@param bind string|nil
	---@return integer|nil, string|nil
	return function(addr, event, bind)
		local ip, port = smatch(addr, ip_pattern)
		if not ip or not port then
			return nil, "invalid address:" .. addr
		end
		local bindip, bindport
		if bind then
			bindip, bindport = smatch(bind, ip_pattern)
			if not bindip or not bindport then
				return nil, "invalid bind address:" .. bind
			end
		else
			bindip, bindport = "", "0"
		end
		local fd, err = connect(ip, port, bindip, bindport)
		if fd then
			assert(socket_pending[fd] == nil)
			socket_pending[fd] = task_running()
			err = silly.wait()
			socket_pending[fd] = nil
			if err then
				return nil, err
			end
			data_callback[fd] = assert(event.data)
			close_callback[fd] = assert(event.close)
			return fd, nil
		end
		return nil, err
	end
end

M.tcplisten = listen_wrap(tcp_listen)
M.udpbind = listen_wrap(udp_bind)

M.tcpconnect = connect_wrap(tcp_connect)
M.udpconnect = connect_wrap(udp_connect)

---@param fd integer
---@return boolean, string? error
function M.close(fd)
	local sc = close_callback[fd]
	if sc == nil then
		return false, "socket closed"
	end
	accept_callback[fd] = nil
	data_callback[fd] = nil
	close_callback[fd] = nil
	assert(socket_pending[fd] == nil)
	local ok, err = socket_close(fd)
	if not ok then
		return false, err
	end
	return true, nil
end

--the message handler can't be yield
silly.register(c.ACCEPT, function(fd, listenid, addr)
	assert(socket_pending[fd] == nil)
	local cb = accept_callback[listenid]
	assert(cb, listenid)
	-- inherit the callback from listenid
	data_callback[fd] = data_callback[listenid]
	close_callback[fd] = close_callback[listenid]
	local t = task_create(cb)
	task_resume(t, fd, listenid, addr)
end)

---@param fd integer
---@param errno integer
silly.register(c.CLOSE, function(fd, errno)
	local f = close_callback[fd]
	if f then
		local t = task_create(f)
		task_resume(t, fd, errno)
	end
end)

silly.register(c.LISTEN, function(fd, errno)
	local t = socket_pending[fd]
	if t == nil then --have already closed
		assert(accept_callback[fd] == nil)
		return
	end
	task_resume(t, errno)
end)

silly.register(c.CONNECT, function(fd, errno)
	local t = socket_pending[fd]
	if t == nil then	--have already closed
		assert(data_callback[fd] == nil)
		return
	end
	task_resume(t, errno)
end)

silly.register(c.TCPDATA, function(fd, ptr, size)
	local f = data_callback[fd]
	if f then
		local t = task_create(f)
		task_resume(t, fd, ptr, size)
	else
		c.free(ptr)
		log_info("[net] SILLY_SDATA fd:", fd, "closed")
	end
end)

silly.register(c.UDPDATA, function(fd, ptr, size, addr)
	local f = data_callback[fd]
	if f then
		local t = task_create(f)
		task_resume(t, fd, ptr, size, addr)
	else
		c.free(ptr)
		log_info("[net] SILLY_UDP fd:", fd, "closed")
	end
end)

return M
