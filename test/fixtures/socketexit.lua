local silly = require "silly"
local net = require "silly.net"
local env = require "silly.env"
local metrics = require "silly.metrics.c"
local errno = require "silly.errno"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"
local c = require "test.aux.c"

local mode = assert(env.get("scenario"))
local accepted = channel.new()
local event = {
	accept = function(fd)
		accepted:push(fd)
	end,
	close = function()
	end,
	data = function(_, ptr)
		net.free(ptr)
	end,
}

-- These raw sockets deliberately remain open for socket_exit to reclaim.
local listener = assert(net.tcplisten("127.0.0.1:0", event))
local address = metrics.socketstat(listener).localaddr
local client = assert(net.tcpconnect(address, event))
testaux.await(accepted, "shutdown fixture accepts TCP")
local udp_listener = assert(net.udpbind("127.0.0.1:0", event))
local datagram = assert(net.udpconnect(metrics.socketstat(udp_listener).localaddr, event))

if mode == "writelist" then
	c.debugctrl("socket.conf", {eagain_every = 1})
	-- Exceed the write-node cache so heap-allocated nodes also need cleanup.
	for _ = 1, 130 do
		assert(net.tcpsend(client, string.rep("w", 257)))
	end
	local shared, size = net.multipack("blocked multicast output", 1)
	assert(net.tcpmulticast(client, shared, size))
	assert(net.udpsend(datagram, "already processed UDP output"))
	-- The connection operation follows every send; accepting it is the barrier.
	assert(net.tcpconnect(address, event))
	testaux.await(accepted, "blocked writes enter the socket write list")
	assert(net.sendsize(client) == 130 * 257 + size)
elseif mode == "batch" then
	c.debugctrl("socket.conf", {defer_trigger = true})
	assert(net.tcpsend(client, "TCP before exit"))
	assert(net.udpsend(datagram, "UDP before exit"))
	local shared, size = net.multipack("shared across exit", 2)
	assert(net.tcpmulticast(client, shared, size))
	c.debugctrl("socket.stop")
	assert(net.tcpsend(client, "TCP after exit"))
	assert(net.udpsend(datagram, "UDP after exit"))
	assert(net.tcpmulticast(client, shared, size))
	c.debugctrl("socket.kick")
elseif mode == "flush" then
	-- Keep SEND and EXIT in one batch, then join before inspecting the send queue.
	c.debugctrl("socket.conf", {defer_trigger = true})
	assert(net.tcpsend(client, "TCP output before EXIT"))
	c.debugctrl("socket.stop")
	c.debugctrl("socket.kick")
	require("silly.c").exit(0)
	assert(net.sendsize(client) == 0, "EXIT skipped the final send attempt")
elseif mode == "producer" then
	-- Joining the socket thread leaves all subsequent output in the producer slot.
	require("silly.c").exit(0)
	assert(net.tcpsend(client, "TCP after the socket thread joins"))
	assert(net.udpsend(datagram, "UDP after the socket thread joins"))
	local shared, size = net.multipack("producer slot multicast", 2)
	for _ = 1, 2 do
		assert(net.tcpmulticast(client, shared, size))
	end
elseif mode == "gc" then
	-- Keep the finalizer reachable until lua_close, after the socket thread joins.
	_G.socket_exit_guard = setmetatable({}, {
		__gc = function()
			local ok, err = net.tcpsend(client, "TCP from VM finalizer")
			assert(ok == false and err == errno.CLOSED)
			ok, err = net.udpsend(datagram, "UDP from VM finalizer")
			assert(ok == false and err == errno.CLOSED)
			local shared, size = net.multipack("multicast from VM finalizer", 2)
			for _ = 1, 2 do
				ok, err = net.tcpmulticast(client, shared, size)
				assert(ok == false and err == errno.CLOSED)
			end
			-- No GC callback may resurrect a socket that can enqueue more output.
			local native = require "silly.net.c"
			local fd, createerr = native.tcp_connect("127.0.0.1", "1", "", "0")
			if fd then
				ok, err = native.tcp_send(fd, "output from a newly allocated GC socket")
				assert(ok == false and err == errno.CLOSED)
			else
				assert(createerr == errno.NOSOCKET)
			end
		end,
	})

else
	error("unknown socket exit scenario: " .. mode)
end

print("SOCKET_EXIT_READY:" .. mode)
if mode ~= "producer" and mode ~= "flush" then
	silly.exit(0)
end
