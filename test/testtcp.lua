local core = require "core"
local metrics = require "core.metrics.c"
local json = require "core.json"
local tcp = require "core.net.tcp"
local tls = require "core.net.tls"
local crypto = require "core.crypto.utils"
local testaux = require "test.testaux"
local IO
local listen_cb
local listenfd = tcp.listen("127.0.0.1:10001", function(fd, addr)
	if listen_cb then
		listen_cb(fd)
		listen_cb = nil
	else
		tcp.close(fd)
	end
end)

local tlsfd = tls.listen {
	addr = "127.0.0.1:10002",
	certs = {
		{
			cert= "test/cert.pem",
			cert_key = "test/key.pem",
		},
	},
	disp = function(fd, addr)
		if listen_cb then
			listen_cb(fd)
			listen_cb = nil
		else
			tls.close(fd)
		end
	end
}

local function wait_done()
	while listen_cb do
		core.sleep(100)
	end
	core.sleep(1000)
end

local function netstat()
	local connecting, tcpclient, ctrlcount = metrics.netstat()
	return {
		connecting = connecting,
		tcpclient = tcpclient,
		ctrlcount = ctrlcount,
	}
end
local function test_limit(port)
	local dat1 = crypto.randomkey(511) .. "\n" .. crypto.randomkey(512)
	local dat2 = crypto.randomkey(1024)
	local listen_func = function(fd)
		print("write 1Kbyte data")
		tcp.write(fd, dat1)
		core.sleep(500)
		print("write 1Kbyte data")
		tcp.write(fd, dat2)
		tcp.close(fd)
	end
	print("==test dynamic limit")
	listen_cb = listen_func
	local fd = tcp.connect("127.0.0.1" .. port)
	print("limit tcp buffer to 1024", fd)
	tcp.limit(fd, 1024)
	print("wait for recv data")
	core.sleep(1000)
	testaux.asserteq(tcp.recvsize(fd), 1024, "tcp flow pause")
	tcp.limit(fd, 2048)
	core.sleep(1000)
	testaux.asserteq(tcp.recvsize(fd), 2048, "tcp flow limit change")
	tcp.close(fd)
	print("==test read part")
	listen_cb = listen_func
	local fd = tcp.connect("127.0.0.1" .. port)
	print("limit tcp buffer to 1024", fd)
	tcp.limit(fd, 1024)
	print("wait for recv data")
	core.sleep(1000)
	testaux.asserteq(tcp.recvsize(fd), 1024, "tcp flow pause")
	local datx = tcp.readline(fd)
	local daty = tcp.read(fd, 768)
	local datz = tcp.read(fd, 768)
	testaux.asserteq(datx..daty..datz, dat1..dat2, "tcp flow read 2048")
	tcp.close(fd)
	print("==test readall")
	listen_cb = listen_func
	local fd = tcp.connect("127.0.0.1" .. port)
	print("limit tcp buffer to 1024", fd)
	tcp.limit(fd, 1024)
	print("wait for recv data")
	core.sleep(1000)
	testaux.asserteq(tcp.recvsize(fd), 1024, "tcp flow pause")
	local datx = tcp.readall(fd)
	testaux.asserteq(datx, dat1, "tcp flow readall 1024")
	core.sleep(1000)
	local daty = tcp.readall(fd)
	testaux.asserteq(daty, dat2, "tcp flow readall 1024")
	tcp.close(fd)
	print("==test write function normal")
	local recvfd
	local size = 0
	local buf1 = {"h"}
	local dat3 = crypto.randomkey(1024 * 1024)
	listen_cb = function(fd)
		recvfd = fd
		tcp.limit(fd, 1)
		print("write 1Kbyte data")
		tcp.write(fd, dat1)
		core.sleep(500)
		print("write 1Kbyte data")
		tcp.write(fd, dat2)
	end
	local fd = tcp.connect("127.0.0.1" .. port)
	tcp.limit(fd, 1024)
	tcp.write(fd, buf1[1])
	core.sleep(1000)
	testaux.asserteq(tcp.recvsize(fd), 1024, "tcp flow pause")
	for i = 1, 1024 do
		size = size + #dat3
		buf1[#buf1 + 1] = dat3
		tcp.write(fd, dat3)
		core.sleep(100)
		if tcp.sendsize(fd) > 0 then
			break
		end
	end
	local datx = tcp.read(fd, 1024)
	local daty = tcp.read(fd, 1024)
	testaux.asserteq(datx .. daty, dat1 .. dat2, "tcp flow read 2048")
	tcp.limit(recvfd, 2*size)
	local datz = tcp.read(recvfd, size+1)
	local datw = table.concat(buf1)
	testaux.asserteq(datz, datw, "tcp flow write check")
	tcp.close(fd)
	tcp.close(recvfd)
	print("==test read large then limit")
	local recvfd
	listen_cb = function(fd)
		recvfd = fd
		print("write 1Kbyte data")
		tcp.write(fd, dat1)
		core.sleep(500)
		print("write 1Kbyte data")
		tcp.write(fd, dat2)
	end
	local fd = tcp.connect("127.0.0.1" .. port)
	tcp.limit(fd, 1024)
	core.sleep(100)
	local dat = tcp.read(fd, 2048)
	testaux.asserteq(dat, dat1 .. dat2, "tcp flow read 2048")
	print("write 1Kbyte data")
	tcp.write(recvfd, dat1)
	core.sleep(500)
	print("write 1Kbyte data")
	tcp.write(recvfd, dat2)
	core.sleep(500)
	testaux.asserteq(tcp.recvsize(fd), 1024, "tcp flow limit 1024")
	local dat = tcp.read(fd, 2048)
	testaux.asserteq(dat, dat1 .. dat2, "tcp flow read 2048")
	tcp.close(fd)
	tcp.close(recvfd)
end

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
					break
				end
			end
		end
		IO.close(fd)
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
	core.wait()
	testaux.asserteq(recv_nr, send_nr, "tcp send type count")
	testaux.asserteq(recv_sum, send_sum, "tcp send checksum")
	IO.close(fd)
end

local function test_close(port)
	--CASE1:client read before server close
	print("CASE1")
	listen_cb = function(fd, addr)
		local str = IO.readline(fd)
		testaux.asserteq(str, "ping\n", "server readline")
		local ok = IO.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = IO.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		print("close open")
		core.sleep(100)
		print("close close")
		local ok = IO.close(fd)
		testaux.asserteq(ok, true, "server close")
		local ok = IO.close(fd)
		testaux.asserteq(ok, false, "server close fail")
		local ok = IO.read(fd, 1)
		testaux.asserteq(ok, nil, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, nil, "server readall fail")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	local dat = IO.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = IO.read(fd, 4)
	testaux.asserteq(dat, nil, "client recv `nil`")
	local ok = IO.close(fd)
	testaux.asserteq(ok , true, "client close ok")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	wait_done()
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
		testaux.asserteq(ok, nil, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, nil, "server readall fail")
		IO.close(fd)
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
	wait_done()
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
		testaux.asserteq(ok, nil, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, nil, "server readall fail")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	local dat = IO.read(fd, 5)
	testaux.asserteq(dat, nil, "client recv more")
	local dat = IO.readall(fd)
	testaux.asserteq(dat, "pong", "client recv `pong` ")
	local dat = IO.readall(fd)
	testaux.asserteq(dat, nil, "client recv `nil` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , true, "client close ok")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	wait_done()
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
		testaux.asserteq(ok, nil, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, nil, "server readall fail")
		IO.close(fd)
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	core.sleep(100)
	local dat = IO.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = IO.read(fd, 1)
	testaux.asserteq(dat, nil, "client recv `nil` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , true, "client close ok")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	wait_done()
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
		testaux.asserteq(ok, nil, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, nil, "server readall fail")
		IO.close(fd)
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	core.sleep(100)
	local dat = IO.read(fd, 4)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = IO.readall(fd)
	testaux.asserteq(dat, nil, "client recv `nil` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , true, "client close ok")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	wait_done()
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
		testaux.asserteq(ok, nil, "server read fail")
		local ok = IO.readall(fd)
		testaux.asserteq(ok, nil, "server readall fail")
		IO.close(fd)
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local ok = IO.write(fd, "ping\n")
	testaux.asserteq(ok, true, "client send `ping`")
	core.sleep(100)
	local dat = IO.readall(fd)
	testaux.asserteq(dat, "pong", "client recv `pong`")
	local dat = IO.readall(fd)
	testaux.asserteq(dat, nil, "client recv `nil` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , true, "client close ok")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	wait_done()
	--CASE7:cilent read, server write, other coroutine IO.close
	print("CASE7")
	listen_cb = function(fd, addr)
		local ok = IO.write(fd, "po")
		testaux.asserteq(ok, true, "server write `po`")
		local ok = IO.write(fd, "ng")
		testaux.asserteq(ok, true, "server write `ng`")
		IO.close(fd)
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	core.fork(function()
		print("fork close")
		IO.close(fd)
	end)
	local dat = IO.read(fd, 5)
	testaux.asserteq(dat, nil, "client recv `nil` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	wait_done()
	--CASE8:cilent read, server write to an closed tcp
	print("CASE8")
	listen_cb = function(fd, addr)
		-- on macosx, need two write syscalls to trigger the error event
		local ok = IO.write(fd, "p")
		print("write p:", fd, ok)
		core.sleep(200)
		local ok = IO.write(fd, "o")
		print("write po:", fd, ok)
		core.sleep(200)
		local ok = IO.write(fd, "n")
		core.sleep(200)
		local ok = IO.write(fd, "g")
		testaux.asserteq(ok, false, "server write `g`")
		IO.close(fd)
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	core.fork(function()
		core.sleep(1)
		IO.close(fd)
		print("fork close")
	end)
	local dat = IO.read(fd, 5)
	testaux.asserteq(dat, nil, "client recv `nil` ")
	local ok = IO.close(fd)
	testaux.asserteq(ok , false, "client close dummy")
	core.sleep(2000)
	wait_done()
	print("CASE8 finish")
	--CASE9:cilent connect, server write then close immediately,
	--client should read all data
	print("CASE9")
	local dat = crypto.randomkey(64*1024*1024)

	listen_cb = function(fd, addr)
		local ok = IO.write(fd, dat)
		testaux.asserteq(ok, true, "server write `64MByte`")
		local ok = IO.close(fd)
		testaux.asserteq(ok, true, "server close")
	end
	local fd = IO.connect("127.0.0.1" .. port)
	testaux.assertneq(fd, nil, "client connect")
	local dat1 = IO.read(fd, 64*1024*1024)
	testaux.asserteq(dat, dat1, "client read connect")
	IO.close(fd)
	wait_done()
end

core.sleep(1000)
local info1 = netstat()
print(json.encode(info1))
testaux.module("tcp")
test_limit(":10001")
core.sleep(100)
local info2 = netstat()
print(json.encode(info2))
testaux.asserteq(info1, info2, "check limit clear")
IO = tcp
testaux.module("tcp")
test_read(":10001")
test_close(":10001")
core.sleep(500)
local info3 = netstat()
testaux.asserteq(info1, info3, "check tcp clear")
---@class test.tcp.io
IO = tls
testaux.module("tls")
IO.limit = function(fd, limit) end
test_read(":10002")
test_close(":10002")
core.sleep(100)
local info4 = netstat()
testaux.asserteq(info1, info4, "check tls clear")

