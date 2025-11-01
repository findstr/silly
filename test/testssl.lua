local silly = require "silly"
local hive = require "silly.hive"
local time = require "silly.time"
local dns = require "silly.net.dns"
local tls = require "silly.net.tls"
local channel = require "silly.sync.channel"
local testaux = require "test.testaux"

testaux.case("Test 1: Connect to www.baidu.com", function()
	local ip = dns.lookup("www.baidu.com", dns.A)
	local conn = tls.connect(ip..":443")
	conn:write("GET https://www.baidu.com/ HTTP/1.1\r\n" ..
		   "User-Agent: Fiddler\r\n" ..
		   "Host: www.baidu.com\r\n\r\n")
	local d
	while not d do
		d = conn:readline("\n")
		print(d)
	end
	conn:close()
end)

testaux.case("Test 2: Reload certs", function()
	local listener = tls.listen {
		addr = "127.0.0.1:10003",
		certs = {
			{
				cert = testaux.CERT_A,
				key = testaux.KEY_A,
			},
		},
		callback = function(conn, addr)
			local body = "testssl ok"
			local resp = "HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
			conn:write(resp)
			conn:close()
		end
	}
	local bee = hive.spawn [[
		return function()
			local handle = io.popen("curl -v -s https://localhost:10003 --insecure 2>&1")
			assert(handle)
			local result = handle:read("*a")
			handle:close()
			return result
		end
	]]
	local result = hive.invoke(bee)
	local cn = result:match("subject:%s*CN=([%w%.%-]+)")
	testaux.asserteq(cn, "localhost", "certA")
	tls.reload(listener, {
		certs = {
			{
				cert = testaux.CERT_B,
				key = testaux.KEY_B,
			},
		},
	})
	result = hive.invoke(bee)
	cn = result:match("subject:%s*CN=([%w%.%-]+)")
	testaux.asserteq(cn, "localhost2", "certB")
	listener:close()
end)

-- TLS EOF Handling Tests - shared server
local ip = "127.0.0.1"
local port = 10004
local listen_cb

local eof_server = tls.listen {
	addr = ip .. ":" .. port,
	certs = {
		{
			cert = testaux.CERT_A,
			key = testaux.KEY_A,
		},
	},
	callback = function(conn, addr)
		listen_cb(conn, addr)
	end,
}

local ch = channel.new()

testaux.case("Test 3.1: TLS read after peer closes", function()
	listen_cb = function(conn, addr)
		-- Read initial data
		local dat, err = conn:read(5)
		testaux.asserteq(dat, "hello", "Server read initial data")

		-- Subsequent read after client closes should return EOF
		local dat2, err2 = conn:read(1)
		testaux.asserteq(dat2, "", "TLS read after close returns empty string")
		testaux.asserteq(err2, "end of file", "TLS read after close returns 'end of file'")

		conn:close()
		ch:push("")
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Client connected to TLS server")
	local ok, err = cfd:write("hello")
	testaux.asserteq(ok, true, "Client wrote 'hello'")
	cfd:close() -- Close cleanly (with SSL_shutdown)
	ch:pop()
end)

testaux.case("Test 3.2: TLS readline interrupted by close", function()
	listen_cb = function(conn, addr)
		-- Try to readline but client will close before sending newline
		local data, err = conn:readline("\n")
		testaux.asserteq(data, "", "TLS readline returns empty string on interrupted read")
		testaux.asserteq(err, "end of file", "TLS readline returns 'end of file' error")
		conn:close()
		ch:push("done") -- Signal handler finished
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Client connected to TLS server")
	local ok, err = cfd:write("incomplete")
	testaux.asserteq(ok, true, "Client wrote incomplete line")
	time.sleep(50) -- Give server time to start readline
	cfd:close() -- Close before sending newline
	ch:pop() -- Wait for handler to finish
end)

testaux.case("Test 3.3: TLS abrupt close", function()
	listen_cb = function(conn, addr)
		-- Read initial data
		local dat, err = conn:read(5)
		testaux.asserteq(dat, "hello", "Server read initial data")

		-- Wait for client to close
		time.sleep(50)

		-- Try to read after abrupt close
		local dat2, err2 = conn:read(1)
		testaux.asserteq(dat2, "", "TLS read after abrupt close returns empty string")
		testaux.asserteq(err2, "end of file", "TLS read after abrupt close returns 'end of file'")

		conn:close()
		ch:push("done") -- Signal handler finished
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Client connected to TLS server")
	local ok, err = cfd:write("hello")
	testaux.asserteq(ok, true, "Client wrote 'hello'")

	-- Force close underlying TCP without SSL_shutdown
	cfd:close()
	ch:pop() -- Wait for handler to finish
end)

testaux.case("Test 3.4: Multiple reads after EOF", function()
	listen_cb = function(conn, addr)
		-- First read gets EOF
		local dat1, err1 = conn:read(1)
		testaux.asserteq(dat1, "", "First read returns empty string")
		testaux.asserteq(err1, "end of file", "First read returns 'end of file'")

		-- Second read should also get EOF
		local dat2, err2 = conn:read(1)
		testaux.asserteq(dat2, "", "Second read returns empty string")
		testaux.asserteq(err2, "end of file", "Second read returns 'end of file'")

		conn:close()
		ch:push("done") -- Signal handler finished
	end

	local cfd = tls.connect(ip .. ":" .. port)
	testaux.assertneq(cfd, nil, "Client connected to TLS server")
	cfd:close() -- Close immediately without sending data
	ch:pop() -- Wait for handler to finish
end)

-- Cleanup EOF server
eof_server:close()

silly.exit(0)
