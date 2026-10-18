local task = require "silly.task"
local time = require "silly.time"
local tcp = require "silly.net.tcp"
local channel = require "silly.sync.channel"
local h1 = require "silly.net.http.h1"
local h2 = require "silly.net.http.h2"
local http = require "silly.net.http"
local testaux = require "test.testaux"
local errno = require "silly.errno"

local _, wait_readers = testaux.trackconnections(tcp)
local nextport = 18089
local function nextaddr()
	nextport = nextport + 1
	return "127.0.0.1:" .. nextport
end
local function withchannel(handler, body)
	local addr = nextaddr()
	local done = channel.new()
	local listener = assert(tcp.listen {
		addr = addr,
		accept = function(conn)
			h2.httpd(handler, conn, "http")
			done:push(true)
		end,
	})
	local conn = assert(tcp.connect(addr))
	local ch = assert(h2.newchannel("http", conn, "localhost"))
	body(ch)
	ch:close()
	testaux.await(done, "HTTP2 connection drained")
	listener:close()
end

testaux.case("Test 1: request starts before the first body write", function()
	local ready = channel.new()
	withchannel(function(s)
		ready:push(true)
		testaux.asserteq(s:readall(2000), "body", "Test 1.1: request body follows initial headers")
		assert(s:respond(200, {}, true))
		local ok = s:write("late")
		testaux.asserteq(ok, false, "Test 1.2: terminal response forbids body writes")
	end, function(ch)
		local s<close> = assert(ch:request("POST", "/", {}))
		testaux.await(ready, "request headers arrive without write or flush")
		assert(s:closewrite("body"))
		assert(s:waitresponse(2000))
		testaux.asserteq(s.headeronly, true, "Test 1.3: respond endstream terminates initial HEADERS")
		testaux.asserteq(s:readall(2000), "", "Test 1.4: response is empty")
	end)
end)

testaux.case("Test 2: admission timeout leaves the connection reusable", function()
	withchannel(function(s)
		testaux.asserteq(s:readall(2000), "", "Test 2.1: endstream request has no body")
		assert(s:respond(200, {}, true))
	end, function(ch)
		ch.streammax = 0
		ch.streamidx = 0x7ffffffd
		local after = time.after
		local cancel = time.cancel
		local timer
		local cancelled = false
		time.after = function(...)
			timer = after(...)
			return timer
		end
		time.cancel = function(id)
			if id == timer then
				cancelled = true
			end
			return cancel(id)
		end
		local ok, s, err = pcall(ch.request, ch, "POST", "/", {}, true, 20)
		time.after = after
		time.cancel = cancel
		assert(ok, s)
		testaux.asserteq(cancelled, false, "Test 2.7: expired admission timer is never cancelled")
		testaux.asserteq(s, nil, "Test 2.2: timeout returns no stream")
		testaux.assertneq(err, nil, "Test 2.3: timeout reports an error")
		testaux.asserteq(ch.openwaitq:size(), 0, "Test 2.4: timeout removes its waiter")
		testaux.asserteq(ch.streamidx, 0x7ffffffd, "Test 2.5: timeout consumes no ID")
		ch.streammax = 1
		local nextstream<close> = assert(ch:request("GET", "/", {}, true))
		testaux.asserteq(nextstream.id, 0x7fffffff, "Test 2.6: timeout releases the last available ID")
		assert(nextstream:waitresponse(2000))
	end)
end)

testaux.case("Test 3: graceful close drains requests already waiting for admission", function()
	withchannel(function(s)
		assert(s:readall(2000))
		assert(s:respond(200, {}, true))
	end, function(ch)
		ch.streammax = 1
		local first<close> = assert(ch:request("POST", "/", {}))
		local ready, done = channel.new(), channel.new()
		for _ = 1, 2 do
			task.fork(function()
				ready:push(true)
				local s<close> = assert(ch:request("GET", "/waiting", {}, true))
				testaux.asserteq(s:readall(2000), "", "Test 3.1: a queued request completes after local close")
				done:push(true)
			end)
			testaux.await(ready, "Test 3: request starts waiting for admission")
		end
		ch:close()
		ch:close()
		testaux.asserteq(ch.openwaitq:size(), 2, "Test 3.2: close retains both queued requests")
		testaux.asserteq(ch:request("GET", "/late", {}, true), nil, "Test 3.3: close rejects subsequent request calls")
		assert(first:closewrite())
		assert(first:waitresponse(2000))
		first:close()
		for _ = 1, 2 do testaux.await(done, "Test 3: queued request completed") end
		testaux.asserteq(ch.conn, nil, "Test 3.4: the connection closes after all queued work drains")
	end)
end)

testaux.case("Test 4: HTTP1 respond endstream finishes only this response", function()
	local addr = nextaddr()
	local handlerdone = channel.new()
	local accepted = 0
	local listener = assert(tcp.listen {
		addr = addr,
		accept = function(conn)
			accepted = accepted + 1
			h1.httpd(function(s)
				assert(s:respond(200, {}, true))
				testaux.asserteq(s:write("late"), false, "Test 4.1: response write end is closed")
				handlerdone:push(true)
			end, conn, "http")
		end,
	})
	local client = http.newclient()
	for _ = 1, 2 do
		local response = assert(client:get("http://" .. addr .. "/"))
		testaux.asserteq(response.body, "", "Test 4.2: complete empty HTTP1 response")
		testaux.await(handlerdone, "HTTP1 handler finished")
	end
	testaux.asserteq(accepted, 1, "Test 4.3: response end preserves connection reuse")
	client:close()
	listener:close()
end)

testaux.case("Test 5: the last admission timeout finishes a local graceful close", function()
	withchannel(function(s)
		assert(s:respond(200, {}, true))
	end, function(ch)
		ch.streammax = 0
		local ready, done = channel.new(), channel.new()
		task.fork(function()
			ready:push(true)
			local s, err = ch:request("GET", "/", {}, true, 100)
			testaux.asserteq(s, nil, "Test 5.1: admission timeout returns no stream")
			testaux.asserteq(err, errno.TIMEDOUT, "Test 5.2: local close preserves the admission timer")
			done:push(true)
		end)
		testaux.await(ready, "Test 5: request is queued")
		testaux.asserteq(ch:isidle(), false, "Test 5.3: pool retains a channel with pending admission")
		ch:close()
		testaux.assertneq(ch.conn, nil, "Test 5.4: a queued request keeps the connection open")
		testaux.await(done, "Test 5: pending request timed out")
		testaux.asserteq(ch.conn, nil, "Test 5.5: removing the last waiter releases the transport")
	end)
end)

testaux.case("Test 6: HTTP1 rejects conflicting endstream before committing headers", function()
	local addr = nextaddr()
	local listener = assert(tcp.listen {
		addr = addr,
		accept = function(conn)
			h1.httpd(function(s)
				local ok = s:respond(200, {["content-length"] = 1}, true)
				testaux.asserteq(ok, false, "Test 6.1: terminal headers reject a nonempty body length")
				assert(s:respond(500, {}, true))
			end, conn, "http")
		end,
	})
	local client = http.newclient()
	local response, err = client:get("http://" .. addr .. "/")
	testaux.assertneq(response, nil, err or "Test 6.2: replacement response remains well framed")
	testaux.asserteq(response.status, 500, "Test 6.3: rejected response emitted no status line")
	client:close()
	listener:close()
end)

testaux.case("Test 7: closed streams retain their channel without further network writes", function()
	withchannel(function(s)
		assert(s:respond(200, {}, true))
	end, function(ch)
		local s = assert(ch:request("GET", "/", {}, true))
		assert(s:waitresponse(2000))
		s:close()
		s:close()
		testaux.asserteq(s.channel, ch, "Test 7.1: channel ownership remains available after close")
		testaux.asserteq(ch.streamcount, 0, "Test 7.2: repeated close releases admission only once")
		local queued = #ch.sendbuf
		testaux.asserteq(s:flush(), true, "Test 7.3: flush remains a no-op after close")
		testaux.asserteq(s:readall(2000), "", "Test 7.4: completed receive data remains readable")
		testaux.asserteq(#ch.sendbuf, queued, "Test 7.5: post-close reads and flush send no frames")
	end)
end)

testaux.case("Test 8: HTTP1 request endstream sends an empty request and closes writes", function()
	local addr = nextaddr()
	local done = channel.new()
	local listener = assert(tcp.listen {
		addr = addr,
		accept = function(conn)
			h1.httpd(function(s)
				testaux.asserteq(s:readall(), "", "Test 8.1: terminal request has no body")
				assert(s:respond(200, {}, true))
			end, conn, "http")
			done:push(true)
		end,
	})
	for _, header in ipairs({
		{}, {["content-length"] = "0"}, {["transfer-encoding"] = "chunked"},
		{["expect"] = "100-continue"}, {["transfer-encoding"] = "chunked", ["expect"] = "100-continue"},
	}) do
		local conn = assert(tcp.connect(addr))
		local s<close> = h1.newstream("http", conn, "localhost")
		assert(s:request("POST", "/", header, true, 2000))
		testaux.asserteq(s:write("late"), false, "Test 8.2: request endstream forbids further writes")
		testaux.asserteq(s:readall(2000), "", "Test 8.3: empty request is submitted without closewrite")
		s:close()
		testaux.await(done, "Test 8: HTTP1 request connection closed")
	end
	listener:close()
end)

testaux.case("Test 9: HTTP1 request rejects conflicting endstream before submitting headers", function()
	local addr = nextaddr()
	local done = channel.new()
	local listener = assert(tcp.listen {
		addr = addr,
		accept = function(conn)
			h1.httpd(function(s)
				testaux.asserteq(s.path, "/valid", "Test 9.1: rejected request emits no request line")
				assert(s:respond(200, {}, true))
			end, conn, "http")
			done:push(true)
		end,
	})
	local conn = assert(tcp.connect(addr))
	local s<close> = h1.newstream("http", conn, "localhost")
	local ok = s:request("POST", "/invalid", {["content-length"] = "1"}, true)
	testaux.asserteq(ok, false, "Test 9.2: nonempty Content-Length conflicts with endstream")
	assert(s:request("POST", "/valid", {}, true))
	testaux.asserteq(s:readall(2000), "", "Test 9.3: valid request survives parameter rejection")
	s:close()
	testaux.await(done, "Test 9: HTTP1 request connection closed")
	listener:close()
end)

testaux.case("Test 10: HTTP1 request keeps Expect timeout after endstream", function()
	local addr = nextaddr()
	local done = channel.new()
	local listener = assert(tcp.listen {
		addr = addr,
		accept = function(conn)
			while assert(conn:read("\n")) ~= "\r\n" do end
			time.sleep(100)
			conn:close()
			done:push(true)
		end,
	})
	local conn = assert(tcp.connect(addr))
	local s<close> = h1.newstream("http", conn, "localhost")
	local ok, err = s:request("POST", "/", {["expect"] = "100-continue", ["content-length"] = "3"}, false, 10)
	testaux.asserteq(ok, false, "Test 10.1: request times out waiting for 100 Continue")
	testaux.asserteq(err, errno.TIMEDOUT, "Test 10.2: fifth argument remains the Expect timeout")
	s:close()
	testaux.await(done, "Test 10: delayed Expect peer closed")
	listener:close()
end)

wait_readers()
