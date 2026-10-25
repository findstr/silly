local tls = require "silly.net.tls"
local errno = require "silly.errno"
local env = require "silly.env"
local channel = require "silly.sync.channel"
local conformance = require "test.conformance"
local testaux = require "test.testaux"

local control = conformance.connect("127.0.0.1", tonumber(env.get("conf_port")) or 19090)

for id, version in ipairs({0x0303, 0x0304}) do
	testaux.case("Test " .. id .. ": Go TLS close_notify preserves the response direction", function()
		local address = "127.0.0.1:" .. (18100 + id)
		local finished = channel.new()
		local listener = assert(tls.listen {
			addr = address,
			certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
			accept = function(conn)
				local request = conn:read(7, 1000)
				local data, err = conn:read(1, 1000)
				local native = require "silly.tls.tls"
				local native_err = native.readwait(conn.ssl)
				local saved_err = native.dbg_error(conn.ssl)
				local c = require "test.aux.c"
				local queued_err = native.push(conn.ssl, c.new("input after close_notify"))
				local ok, write_err = conn:write("response")
				local result = {request = request, data = data, err = err, native_err = native_err,
					saved_err = saved_err, queued_err = queued_err,
					read_err = conn.err, ok = ok, write_err = write_err}
				conn:close()
				result.after_close = native.dbg_error(conn.ssl)
				result.repeated = native.close(conn.ssl)
				finished:push(result)
			end,
		})
		local response, err = control:tlsclosewrite(address, version)
		local label = "Test " .. id .. "."
		testaux.asserteq(err, nil, label .. "2: TLS exchange succeeds")
		testaux.asserteq(response, "response", label .. "1: Go receives response after CloseWrite")
		local result = testaux.await(finished, "TLS close_notify handled")
		testaux.asserteq(result.request, "request", label .. "3: Request precedes close_notify")
		testaux.asserteq(result.data, nil, label .. "4: Read direction ends")
		testaux.asserteq(result.err, errno.EOF, label .. "5: close_notify reports EOF")
		testaux.asserteq(result.native_err, errno.EOF, label .. "5.1: Native readwait retains TLS EOF")
		testaux.asserteq(result.queued_err, errno.EOF, label .. "5.2: Push reports the ended SSL read direction")
		testaux.asserteq(result.read_err, errno.EOF, label .. "5.3: Lua retains EOF as the read-side error")
		testaux.asserteq(result.saved_err, errno.EOF, label .. "5.4: Error queries preserve TLS EOF")
		testaux.asserteq(result.ok, true, label .. "6: Write direction remains open")
		testaux.asserteq(result.write_err, nil, label .. "7: Response write succeeds")
		testaux.asserteq(result.after_close, errno.CLOSED, label .. "8: Owner close takes precedence over TLS EOF")
		testaux.asserteq(result.repeated, nil, label .. "9: Repeated close does not replay TLS EOF")
		listener:close()
	end)
end

testaux.case("Test 3: Fatal TLS input still allows the socket FIN to arrive", function()
	local net = require "silly.net"
	local task = require "silly.task"
	local silly = require "silly"
	local pcall = silly.pcall
	local failed = channel.new()
	local closed = channel.new()
	local completed = channel.new()
	local target
	local listen = net.tcplisten
	net.tcplisten = function(addr, event, backlog)
		return listen(addr, {
			accept = event.accept,
			data = event.data,
			close = function(fd, err)
				event.close(fd, err)
				if target and target.fd == fd then
					closed:push({err = err})
				end
			end,
		}, backlog)
	end
	local address = "127.0.0.1:18103"
	local ok, listener = pcall(tls.listen, {
		addr = address,
		certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
		accept = function(conn)
			target = conn
			conn:limit(1)
			local data, err = conn:read(6, 1000)
			-- A broken connection must keep draining even with unread plaintext at the limit.
			conn:limit(0)
			failed:push({conn = conn, data = data, err = err})
		end,
	})
	net.tcplisten = listen
	assert(ok, listener)
	assert(listener)
	task.fork(function()
		local data, err = control:tlscloseaftererror(address)
		completed:push({data = data, err = err})
	end)
	local result = testaux.await(failed, "fatal TLS input wakes the pending reader")
	local conn<close> = result.conn
	local observed, close_result = pcall(testaux.await, closed, "TCP FIN after fatal TLS input", 1000)
	local data, err = conn:read(5)
	local _, saved_err = conn:read(1)
	conn:close()
	local peer = testaux.await(completed, "Go peer observes owner close")
	listener:close()
	testaux.asserteq(result.data, nil, "Test 3.1: Fatal input interrupts an incomplete read")
	testaux.asserteq(result.err, errno.TLS, "Test 3.2: Reader receives the TLS error without timing out")
	testaux.asserteq(observed, true, "Test 3.3: Fatal TLS state does not suppress the TCP FIN")
	testaux.asserteq(close_result.err, errno.EOF, "Test 3.4: Go sends FIN rather than resetting the socket")
	testaux.asserteq(data, "hello", "Test 3.5: Discarding new ciphertext preserves valid buffered data")
	testaux.asserteq(err, nil, "Test 3.6: Buffered reads still succeed")
	testaux.asserteq(saved_err, errno.TLS, "Test 3.7: Socket EOF preserves the original TLS failure")
	testaux.asserteq(peer.data, "closed", "Test 3.8: Owner close releases the socket")
	testaux.asserteq(peer.err, nil, "Test 3.9: Go peer completes without an error")
end)

for id, version in ipairs({0x0303, 0x0304}) do
	testaux.case("Test " .. (id + 3) .. ": Normal TLS close sends close_notify to Go", function()
		local native = require "silly.tls.tls"
		local finished = channel.new()
		local address = "127.0.0.1:" .. (18103 + id)
		local listener = assert(tls.listen {
			addr = address,
			certs = {{cert = testaux.CERT_A, key = testaux.KEY_A}},
			accept = function(conn)
				local wrote, write_err = conn:write({"before", " close"})
				local closed, close_err = conn:close()
				finished:push({wrote = wrote, write_err = write_err, closed = closed, close_err = close_err,
					err = native.dbg_error(conn.ssl), repeated = native.close(conn.ssl)})
			end,
		})
		local data, err = control:tlsreadclose(address, version)
		local result = testaux.await(finished, "TLS close returns without waiting for the peer")
		listener:close()
		local label = "Test " .. (id + 3) .. "."
		testaux.asserteq(err, nil, label .. "1: Go receives close_notify rather than unexpected EOF")
		testaux.asserteq(data, "before close", label .. "2: All application data precedes close_notify")
		testaux.asserteq(result.wrote, true, label .. "3: The write is accepted")
		testaux.asserteq(result.write_err, nil, label .. "4: The write succeeds")
		testaux.asserteq(result.closed, true, label .. "5: Owner close succeeds")
		testaux.asserteq(result.close_err, nil, label .. "6: Normal close is not an I/O error")
		testaux.asserteq(result.err, errno.CLOSED, label .. "7: Native reads report owner close")
		testaux.asserteq(result.repeated, nil, label .. "9: Repeated native close is harmless")
	end)
end

control:close()
