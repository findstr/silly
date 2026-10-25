local silly = require "silly"
local hive = require "silly.hive"
local testaux = require "test.testaux"
local channel = require "silly.sync.channel"
local errno = require "silly.errno"

local is_windows = silly.multiplexer == "iocp"
local binary = os.getenv("SILLY_BIN") or (is_windows and "./silly.exe" or "./silly")
if is_windows then
	binary = binary:gsub("/", "\\")
end
local cpath = os.getenv("SILLY_LUACLIB_PATH") or "luaclib"
local worker = hive.spawn [[
	return function(command)
		local process = assert(io.popen(command))
		local output = process:read("*a")
		local ok, reason, code = process:close()
		return {output = output, ok = ok, reason = reason, code = code}
	end
]]

for _, spec in ipairs({
	{id = 1, mode = "writelist", name = "Socket exit releases blocked write lists"},
	{id = 2, mode = "batch", name = "Socket exit discards operations after the exit command"},
	{id = 3, mode = "gc", name = "Socket shutdown rejects sends from VM finalizers"},
	{id = 4, mode = "tlsgc", name = "TLS finalizers safely attempt close_notify after socket shutdown"},
	{id = 7, mode = "producer", name = "Socket cleanup releases output queued after the socket thread joins"},
	{id = 8, mode = "flush", name = "Socket exit attempts TCP output queued before EXIT"},
}) do
	testaux.case("Test " .. spec.id .. ": " .. spec.name, function()
		local command = string.format(
			'"%s" test/fixtures/socketexit.lua --scenario=%s --lualib-cpath="./%s/?.so;./%s/?.dll" 2>&1',
			binary, spec.mode, cpath, cpath)
		if is_windows then
			command = '"' .. command .. '"'
		end
		local result = hive.invoke(worker, command)
		local output = result.output
		assert(result.ok, output)
		assert(output:find("SOCKET_EXIT_READY:" .. spec.mode, 1, true), output)
		assert(output:find("exit, leak memory size:0\n", 1, true), output)
		assert(not output:find("ERROR: ", 1, true), output)
		assert(not output:find("runtime error:", 1, true), output)
		assert(not output:find("error in __gc", 1, true), output)
		if spec.mode == "tlsgc" then
			local _, count = output:gsub("TLS_EXIT_CLOSED", "")
			assert(count == 2, output)
		end
		testaux.success("Test " .. spec.id .. ": Child exits without leaked socket buffers")
	end)
end

testaux.case("Test 59: Zombie sends preserve the fatal reason until the socket ID is released", function()
	local net = require "silly.net"
	local metrics = require "silly.metrics.c"
	local c = require "test.aux.c"
	local accepted = channel.new()
	local ended = channel.new()
	local event = {
		accept = function(fd)
			accepted:push(fd)
		end,
		data = function(_, ptr)
			net.free(ptr)
		end,
		close = function(_, err)
			ended:push({err = err})
		end,
	}
	local listener = assert(net.tcplisten("127.0.0.1:0", event))
	local fd = assert(net.tcpconnect(metrics.socketstat(listener).localaddr, event))
	local peer = testaux.await(accepted, "zombie fixture accepts TCP")
	c.setlinger(metrics.socketstat(peer).os_fd, 0)
	assert(net.close(peer))
	local observed = testaux.await(ended, "peer reset publishes a fatal close notification")
	-- LISTEN runs after the socket thread has published the zombie state.
	local barrier = assert(net.tcplisten("127.0.0.1:0", event))
	local ok, err = net.tcpsend(fd, "send after reset")
	local shared, size = net.multipack("multicast after reset", 1)
	local multi, multierr = net.tcpmulticast(fd, shared, size)
	net.close(fd)
	local stale, staleerr = net.tcpsend(fd, "send after owner close")
	net.close(barrier)
	net.close(listener)
	testaux.asserteq(observed.err == errno.CONNRESET or observed.err == errno.CONNABORTED, true,
		"Test 59.1: Reset produces a specific fatal transport cause")
	testaux.asserteq(ok, false, "Test 59.2: Raw send rejects the zombie socket")
	testaux.asserteq(err, observed.err, "Test 59.3: Raw send preserves the fatal cause")
	testaux.asserteq(multi, false, "Test 59.4: Multicast rejects the zombie socket")
	testaux.asserteq(multierr, observed.err, "Test 59.5: Multicast preserves the fatal cause")
	testaux.asserteq(stale, false, "Test 59.6: Released IDs reject sends")
	testaux.asserteq(staleerr, errno.CLOSED, "Test 59.7: Released IDs report CLOSED")
end)

testaux.case("Test 60: Read EOF does not replace a later zombie write error", function()
	local net = require "silly.net"
	local metrics = require "silly.metrics.c"
	local c = require "test.aux.c"
	local accepted = channel.new()
	local ended = channel.new()
	local barrier_accepted = channel.new()
	local close_count = 0
	local event = {
		accept = function(fd)
			accepted:push(fd)
		end,
		data = function(_, ptr)
			net.free(ptr)
		end,
		close = function(_, err)
			close_count = close_count + 1
			ended:push({err = err})
		end,
	}
	local listener = assert(net.tcplisten("127.0.0.1:0", event))
	local address = metrics.socketstat(listener).localaddr
	local host, port = address:match("^([^:]+):(%d+)$")
	local peer = c.connect(host, tonumber(port))
	local fd = testaux.await(accepted, "half-close fixture accepts TCP")
	c.shutdown(peer, 1)
	local read_end = testaux.await(ended, "peer FIN ends only the read direction")
	local wrote, writeerr = net.tcpsend(fd, "world")
	local response = c.recv(peer, 5)
	local barrier_event = {
		accept = function(id)
			barrier_accepted:push(id)
		end,
		data = event.data,
		close = function()
		end,
	}
	local barrier_listener = assert(net.tcplisten("127.0.0.1:0", barrier_event))
	-- The socket remains owned by the engine; only its write half is shut down here.
	c.shutdown(metrics.socketstat(fd).os_fd, 1)
	local queued = net.tcpsend(fd, "write after local shutdown")
	local barrier_client = assert(net.tcpconnect(metrics.socketstat(barrier_listener).localaddr,
		barrier_event))
	-- Accept runs after the operation batch has attempted the failed write.
	local barrier_peer = testaux.await(barrier_accepted, "the socket thread completes the failed write")
	local ok, err = net.tcpsend(fd, "send after becoming zombie")
	local again, againerr = net.tcpsend(fd, "repeat zombie send")
	local shared, size = net.multipack("zombie multicast", 1)
	local multi, multierr = net.tcpmulticast(fd, shared, size)
	net.close(fd)
	c.close(peer)
	net.close(barrier_client)
	net.close(barrier_peer)
	net.close(barrier_listener)
	net.close(listener)
	testaux.asserteq(read_end.err, errno.EOF, "Test 60.1: The read direction reports EOF")
	testaux.asserteq(wrote, true, "Test 60.2: Read EOF still permits writing")
	testaux.asserteq(writeerr, nil, "Test 60.3: Half-close does not invent a write error")
	testaux.asserteq(response, "world", "Test 60.4: The peer receives data after its FIN")
	testaux.asserteq(queued, true, "Test 60.5: The operation is queued before the write failure")
	testaux.asserteq(ok, false, "Test 60.6: The failed write makes the socket a zombie")
	testaux.assertneq(err, nil, "Test 60.7: Zombie sends return a write failure")
	testaux.assertneq(err, errno.EOF, "Test 60.8: Zombie cause does not reuse the earlier read EOF")
	testaux.assertneq(err, errno.CLOSED, "Test 60.9: Zombie cause retains the actual write failure")
	testaux.asserteq(again, false, "Test 60.10: Repeated zombie sends fail")
	testaux.asserteq(againerr, err, "Test 60.11: Repeated sends preserve the zombie cause")
	testaux.asserteq(multi, false, "Test 60.12: Zombie multicast fails")
	testaux.asserteq(multierr, err, "Test 60.13: Multicast preserves the write failure")
	testaux.asserteq(close_count, 1, "Test 60.14: The earlier read EOF remains the only close notification")
end)


testaux.case("Test 61: Invalid socket IDs cannot refer to unused pool slots", function()
	local net = require "silly.net"
	local ok, err = net.tcpsend(-1, "invalid TCP socket ID")
	local udp_ok, udp_err = net.udpsend(-1, "invalid UDP socket ID")
	local shared, size = net.multipack("invalid multicast socket ID", 1)
	local multi_ok, multi_err = net.tcpmulticast(-1, shared, size)
	testaux.asserteq(ok, false, "Test 61.1: Invalid TCP IDs reject sends")
	testaux.asserteq(err, errno.CLOSED, "Test 61.2: Invalid TCP IDs report CLOSED")
	testaux.asserteq(udp_ok, false, "Test 61.3: Invalid UDP IDs reject sends")
	testaux.asserteq(udp_err, errno.CLOSED, "Test 61.4: Invalid UDP IDs report CLOSED")
	testaux.asserteq(multi_ok, false, "Test 61.5: Invalid multicast IDs reject sends")
	testaux.asserteq(multi_err, errno.CLOSED, "Test 61.6: Invalid multicast IDs report CLOSED")
end)
