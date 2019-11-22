local core = require "sys.core"
local socket = require "sys.socket"
local tls = require "sys.tls"
local testaux = require "testaux"

local listen_cb
local listenfd = socket.listen(":100001", function(fd, addr)
	if listen_cb then
		listen_cb(fd)
		listen_cb = nil
	else
		socket.close(fd)
	end
end)

local function test_readline()
	local recv_sum = 0
	local send_sum = 0
	local recv_nr = 0
	local send_nr = 0

	local WAIT
	listen_cb = function(fd)
		socket.limit(fd, 1024*1024*1024)
		while true do
			local n = socket.readline(fd)
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
			socket.write(fd, n)
		end
	end
	local fd = socket.connect("127.0.0.1:100001")
	if not fd then
		print("connect fail:", fd)
		return
	end
	socket.limit(fd, 1024 * 1024 * 1024)
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
	socket.close(fd)
end

local function test_close()
	--CASE1:client read before server close
	print("CASE1")
	listen_cb = function(fd, addr)
		local str = socket.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = socket.write(fd, "po")
		testaux.asserteq(ok, true, "server write")
		local ok = socket.write(fd, "ng")
		core.sleep(100)
		local ok = socket.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = socket.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = socket.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = socket.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = socket.connect("127.0.0.1:100001")
	testaux.assertneq(fd, nil, "client connect")
	local ok = socket.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	local dat = socket.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = socket.read(fd, 4)
	testaux.asserteq(dat, false, "client recv `false`")
	local ok = socket.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE2:client readall before server close
	print("CASE2")
	listen_cb = function(fd, addr)
		local str = socket.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = socket.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = socket.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		core.sleep(100)
		local ok = socket.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = socket.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = socket.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = socket.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = socket.connect("127.0.0.1:100001")
	testaux.assertneq(fd, nil, "client connect")
	local ok = socket.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	local dat = socket.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `ping`")
	local dat = socket.readall(fd)
	testaux.asserteq(dat, "", "client recv '' ")
	core.sleep(200)
	local ok = socket.close(fd)
	testaux.asserteq(ok , true, "client close")
	--CASE3:client read more before server close
	print("CASE3")
	listen_cb = function(fd, addr)
		local str = socket.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = socket.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = socket.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		core.sleep(100)
		local ok = socket.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = socket.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = socket.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = socket.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = socket.connect("127.0.0.1:100001")
	testaux.assertneq(fd, nil, "client connect")
	local ok = socket.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	local dat = socket.read(fd, 5)
	testaux.asserteq(dat, false, "client recv more")
	local dat = socket.readall(fd)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = socket.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE4:server write and close then cilent read twice
	print("CASE4")
	listen_cb = function(fd, addr)
		local str = socket.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = socket.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = socket.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		local ok = socket.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = socket.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = socket.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = socket.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = socket.connect("127.0.0.1:100001")
	testaux.assertneq(fd, nil, "client connect")
	local ok = socket.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	core.sleep(100)
	local dat = socket.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = socket.read(fd, 1)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = socket.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE5:server write and close then cilent read and readall
	print("CASE5")
	listen_cb = function(fd, addr)
		local str = socket.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = socket.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = socket.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		local ok = socket.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = socket.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = socket.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = socket.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = socket.connect("127.0.0.1:100001")
	testaux.assertneq(fd, nil, "client connect")
	local ok = socket.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	core.sleep(100)
	local dat = socket.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = socket.readall(fd)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = socket.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE6:server write and close then cilent readall and readall
	print("CASE6")
	listen_cb = function(fd, addr)
		local str = socket.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = socket.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = socket.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		local ok = socket.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = socket.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = socket.read(fd, 1)
		testaux.asserteq(ok, false, "server read fail")
		local ok = socket.readall(fd)
		testaux.asserteq(ok, false, "server readall fail")
	end
	local fd = socket.connect("127.0.0.1:100001")
	testaux.assertneq(fd, nil, "client connect")
	local ok = socket.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	core.sleep(100)
	local dat = socket.readall(fd)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = socket.readall(fd)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = socket.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE7:cilent read, server write, other coroutine socket.close
	print("CASE7")
	listen_cb = function(fd, addr)
		local ok = socket.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = socket.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
	end
	local fd = socket.connect("127.0.0.1:100001")
	testaux.assertneq(fd, nil, "client connect")
	core.fork(function()
		socket.close(fd)
	end)
	local dat = socket.read(fd, 5)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = socket.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	--CASE8:cilent read, server write to an closed socket
	print("CASE8")
	listen_cb = function(fd, addr)
		local ok = socket.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		core.sleep(100)
		local ok = socket.write(fd, "ng")
		testaux.asserteq(ok, false, "server write `ng`")
	end
	local fd = socket.connect("127.0.0.1:100001")
	testaux.assertneq(fd, nil, "client connect")
	core.fork(function()
		core.sleep(50)
		socket.close(fd)
	end)
	local dat = socket.read(fd, 5)
	testaux.asserteq(dat, false, "client recv `false` ")
	local ok = socket.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	core.sleep(50)
end

return function()
	test_readline()
	test_close()
end

