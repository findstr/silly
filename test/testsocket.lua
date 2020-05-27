local core = require "sys.core"
local socket = require "sys.socket"
local tls = require "sys.tls"
local testaux = require "testaux"
local IO
local listen_cb
local listenfd = socket.listen(":10001", function(fd, addr)
	if listen_cb then
		listen_cb(fd)
		listen_cb = nil
	else
		socket.close(fd)
	end
end)

local tlsfd = tls.listen {
	port = ":10002",
	cert = "test/cert.pem",
	key = "test/key.pem",
	disp = function(fd, addr)
		if listen_cb then
			listen_cb(fd)
			listen_cb = nil
		else
			tls.close(fd)
		end
	end
}

local function test_read(port)
	local recv_sum = 0
	local send_sum = 0
	local recv_nr = 0
	local send_nr = 0

	local WAIT
	listen_cb = function(fd)
		IO.limit(fd, 8*1024*1024)
		while true do
			local n = IO.readline(fd)
			assert(n,n)
			recv_nr = recv_nr + #n
			recv_sum = testaux.checksum(recv_sum, n)
			if recv_nr == send_nr then
				if WAIT then
					core.wakeup(WAIT)
					return
				end
			end
		end
	end
	local testsend = function (fd, one, nr)
		print(string.format("-----test packet of %d count %d-----", one, nr))
		for i = 1, nr do
			local n = testaux.randomdata(one - 1) .. "\n"
			send_sum = testaux.checksum(send_sum, n)
			send_nr = send_nr + #n
			IO.write(fd, n)
		end
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	IO.limit(fd, 8 * 1024 * 1024)
	assert(fd >= 0)
	local start = 8
	local total = 32 * 1024 * 1024
	for i = 1, 4 do
		local nr = total // start
		if nr > 1024 then
			nr = 1024
		end
		testsend(fd, start, nr)
		start = start * start
		if i ~= 4 then
			core.sleep(0)
		end
	end
	WAIT = core.running()
	core.wait(WAIT)
	testaux.asserteq(recv_nr, send_nr, "socket send type count")
	testaux.asserteq(recv_sum, send_sum, "socket send checksum")
	IO.close(fd)
end

local function test_close(port)
	--CASE1:client read before server close
	print("CASE1")
	listen_cb = function(fd, addr)
		local str = IO.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = IO.write(fd, "po")
		testaux.asserteq(ok, true, "server write")
		local ok = IO.write(fd, "ng")
		print("close open")
		core.sleep(100)
		print("close close")
		local ok = IO.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = IO.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = IO.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	print("connect", fd)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	print("read 'pong'")
	local dat = IO.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = IO.read(fd, 4)
	testaux.asserteq(dat, false, "client recv `false`")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE2:client readall before server close
	print("CASE2")
	listen_cb = function(fd, addr)
		local str = IO.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = IO.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = IO.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		core.sleep(100)
		local ok = IO.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = IO.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = IO.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	local dat = IO.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `ping`")
	local dat = IO.readall(fd)
	testaux.asserteq(dat, "", "client recv '' ")
	core.sleep(200)
	local ok = IO.close(fd)
	testaux.asserteq(ok , true, "client close")
	--CASE3:client read more before server close
	print("CASE3")
	listen_cb = function(fd, addr)
		local str = IO.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = IO.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = IO.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		core.sleep(100)
		local ok = IO.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = IO.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = IO.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	local dat = IO.read(fd, 5)
	testaux.asserteq(dat, false, "client recv more")
	local dat = IO.readall(fd)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE4:server write and close then cilent read twice
	print("CASE4")
	listen_cb = function(fd, addr)
		local str = IO.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = IO.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = IO.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		local ok = IO.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = IO.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = IO.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	core.sleep(100)
	local dat = IO.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = IO.read(fd, 1)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE5:server write and close then cilent read and readall
	print("CASE5")
	listen_cb = function(fd, addr)
		local str = IO.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = IO.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = IO.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		local ok = IO.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = IO.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = IO.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	core.sleep(100)
	local dat = IO.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = IO.readall(fd)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE6:server write and close then cilent readall and readall
	print("CASE6")
	listen_cb = function(fd, addr)
		local str = IO.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = IO.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = IO.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		local ok = IO.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = IO.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = IO.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	core.sleep(100)
	local dat = IO.readall(fd)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = IO.readall(fd)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE7:cilent read, server write, other coroutine IO.close
	print("CASE7")
	listen_cb = function(fd, addr)
		local ok = IO.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = IO.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	core.fork(function()
		print("fork close")
		IO.close(fd)
	end)
	local dat = IO.read(fd, 5)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE8:cilent read, server write to an closed socket
	print("CASE8")
	listen_cb = function(fd, addr)
		local ok = IO.write(fd, "po")
		core.sleep(200)
		local ok = IO.write(fd, "ng")
		testaux.asserteq(ok, false, "server write `ng`")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	core.fork(function()
		core.sleep(1)
		IO.close(fd)
	end)
	local dat = IO.read(fd, 5)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	core.sleep(200)
end

return function()
	IO = socket
	testaux.module("socet")
	test_read(":10001")
	test_close(":10001")
	IO = tls
	testaux.module("tls")
	IO.limit = function() end
	test_read(":10002")
	test_close(":10002")
end

