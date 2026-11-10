local silly = require "silly"
local net = require "silly.net"
local native = require "silly.net.c"
local tcp = require "silly.net.tcp"
local metrics = require "silly.metrics.c"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"
local errno = require "silly.errno"
local pcall = silly.pcall

local callbacks
for _, value in pairs(debug.getregistry()) do
	if type(value) == "table" and type(value[native.ACCEPT]) == "function" and
		type(value[native.TCPDATA]) == "function" then
		callbacks = value
		break
	end
end
assert(callbacks)

testaux.case("Test 1: Listener close releases an ACCEPT already queued by the socket thread", function()
	local queued = channel.new()
	local event = {
		accept = function()
			error("closed listener must not accept a connection")
		end,
		data = function(_, ptr)
			net.free(ptr)
		end,
		close = function() end,
	}
	local listener = assert(net.tcplisten("127.0.0.1:0", event))
	local accept = callbacks[native.ACCEPT]
	-- Hold a real ACCEPT at the worker boundary until its listener is closed.
	callbacks[native.ACCEPT] = function(fd, listenid, addr)
		if listenid == listener then
			queued:push({fd = fd, listenid = listenid, addr = addr})
		else
			accept(fd, listenid, addr)
		end
	end
	local peer = assert(tcp.connect(metrics.socketstat(listener).localaddr))
	local message = testaux.await(queued, "socket thread publishes ACCEPT")
	assert(net.close(listener))
	callbacks[native.ACCEPT] = accept
	local ok, err = pcall(accept, message.fd, message.listenid, message.addr)
	if not ok then
		native.close(message.fd)
	end
	local data, peererr = peer:read(1, 1000)
	peer:close()
	testaux.asserteq(ok, true, "Test 1.1: A queued ACCEPT does not assert after listener close")
	testaux.asserteq(data, nil, "Test 1.2: The abandoned connection is closed")
	testaux.asserteq(peererr, errno.EOF, "Test 1.3: The peer observes closure instead of timing out")
end)

testaux.case("Test 2: TCP releases input if GC closes its owner after callback selection", function()
	local accepted = channel.new()
	local delivered = channel.new()
	local listener = assert(tcp.listen {
		addr = "127.0.0.1:0",
		accept = function(conn)
			accepted:push(conn)
		end,
	})
	local connect = net.tcpconnect
	net.tcpconnect = function(addr, event, ...)
		return connect(addr, {
			close = event.close,
			data = function(fd, ptr, size)
				-- GC may run after the dispatcher caches this callback.
				collectgarbage("collect")
				collectgarbage("collect")
				event.data(fd, ptr, size)
				delivered:push(true)
			end,
		}, ...)
	end
	local conn = assert(tcp.connect(metrics.socketstat(listener.fd).localaddr))
	net.tcpconnect = connect
	local peer = testaux.await(accepted, "GC input fixture accepts")
	local weak = setmetatable({conn}, {__mode = "v"})
	local gc_running = collectgarbage("isrunning")
	collectgarbage("stop")
	conn = nil
	assert(peer:write("input for a collected TCP owner"))
	testaux.await(delivered, "selected input callback runs after owner GC")
	if gc_running then
		collectgarbage("restart")
	end
	local data, err = peer:read(1, 1000)
	peer:close()
	listener:close()
	testaux.asserteq(weak[1], nil, "Test 2.1: GC releases the socket before handing over its input")
	testaux.asserteq(data, nil, "Test 2.2: Finalization closes the TCP connection")
	testaux.asserteq(err, errno.EOF, "Test 2.3: Finalization reaches the peer")
	-- The suite's allocator/ASan leak check verifies ownership of the received buffer.
end)
