local socket = require "sys.socket"
local core = require "sys.core"

local pairs = pairs
local assert = assert
local tremove = table.remove

local CONNECTING   = 1
local CONNECTED    = 2
local CLOSE        = 5
local FINAL        = 6

local dispatch = {}

local mt = {
	__index = dispatch,
	__gc = function(tbl)
		if tbl.sock then
			socket.close(tbl.sock)
		end
	end
}

--the function of process response insert into d.funcqueue
function dispatch:create(config)
	local d = {
		sock = nil,
		status = CLOSE,
		authco = nil,
		responseco = false,
		dispatchco = false,
		connectqueue = {},
		waitqueue = {},
		funcqueue = {},	--process response, return
		result_data = {},
		--come from config
		addr = config.addr,
		auth = config.auth,
	}
	setmetatable(d, mt)
	return d
end

local function wakeup_all(self, ret, err)
	local waitqueue = self.waitqueue
	local funcqueue = self.funcqueue
	local result_data = self.result_data
	local co = tremove(waitqueue, 1)
	tremove(funcqueue, 1)
	while co do
		result_data[co] = err
		core.wakeup(co, ret)
		co = tremove(waitqueue, 1)
		tremove(funcqueue, 1)
	end
end

local function doclose(self)
	if self.status == CLOSE then
		return
	end
	assert(self.sock)
	socket.close(self.sock)
	self.sock = nil
	self.status = CLOSE;
	local co = self.responseco
	if co then
		self.responseco = nil
		core.wakeup(co)
	end
end


--this function will be run the indepedent coroutine
local function dispatch_response(self)
	return function ()
		local pcall = core.pcall
		local waitqueue = self.waitqueue
		local funcqueue = self.funcqueue
		local result_data = self.result_data
		while self.sock do
			local co = tremove(waitqueue, 1)
			local func = tremove(funcqueue, 1)
			if func and co then
				local ok, status, data  = pcall(func, self)
				if ok then
					result_data[co] = data
					core.wakeup(co, status)
				else
					result_data[co] = status
					core.wakeup(co, false)
					doclose(self)
					break
				end
			else
				local co = core.running()
				self.responseco = co
				core.wait(co)
			end
		end
		self.dispatchco = false
		wakeup_all(self, false, "disconnected")
	end
end

local function waitfor_response(self, response)
	local co = core.running()
	local waitqueue = self.waitqueue
	local funcqueue = self.funcqueue
	waitqueue[#waitqueue + 1] = co
	funcqueue[#funcqueue + 1] = response
	if self.responseco then     --the first request
		local co = self.responseco
		self.responseco = nil
		core.wakeup(co)
	end
	local status = core.wait(co)
	local result_data = self.result_data
	local data = result_data[co]
	result_data[co] = nil
	return status, data
end

local function waitfor_connect(self)
	local co = core.running()
	local connectqueue = self.connectqueue
	connectqueue[#connectqueue + 1] = co
	local status = core.wait(co)
	local result_data = self.result_data
	local data = result_data[co]
	result_data[co] = nil
	return status, data
end

local function wakeup_conn(self, success, err)
	local result_data = self.result_data
	local connectqueue = self.connectqueue
	for k, v in pairs(connectqueue) do
		result_data[v] = err
		core.wakeup(v, success)
		connectqueue[k] = nil
	end
end

local function tryconnect(self)
	local status = self.status
	if status == CONNECTED then
		return true
	end
	if status == FINAL then
		return false, "already closed"
	end
	if status == CLOSE then
		local err, sock, res
		self.status = CONNECTING;
		sock = socket.connect(self.addr)
		if sock then
			self.sock = sock
			--wait for responseco exit
			while self.dispatchco do
				core.sleep(0)
			end
			local auth = self.auth
			self.dispatchco = core.fork(dispatch_response(self))
			if auth then
				local ok, msg
				self.authco = core.running()
				ok, res, msg = core.pcall(auth, self)
				self.authco = nil
				if not ok then
					res = false
					err = res
					doclose(self)
				elseif not res then
					res = false
					err = msg
					doclose(self)
				end
			else
				res = true
			end
			if res then
				self.status = CONNECTED;
				assert(#self.funcqueue == 0)
				assert(#self.waitqueue == 0)
			end
		else
			res = false
			self.status = CLOSE
			err = "socketdispatch connect fail"
		end
		wakeup_conn(self, res, err)
		return res, err
	elseif status == CONNECTING then
		if self.authco == core.running() then
			return true
		end
		return waitfor_connect(self)
	else
		core.error("[socketdispatch] incorrect call at status:" .. self.status)
	end
end

function dispatch:connect()
	return tryconnect(self)
end

function dispatch:close()
	if self.status == FINAL then
		return
	end
	doclose(self)
	self.status = FINAL
	return
end

-- the respose function will be called in the `dispatchco` coroutine
function dispatch:request(cmd, response)
	local ok, err = tryconnect(self)
	if not ok then
		return ok, err
	end
	local ok = socket.write(self.sock, cmd)
	if not ok then
		doclose(self)
		return nil
	end
	if not response then
		return
	end
	return waitfor_response(self, response)
end

local function read_write_wrapper(func)
	return function (self, p)
		return func(self.sock, p)
	end
end

dispatch.read = read_write_wrapper(socket.read)
dispatch.write = read_write_wrapper(socket.write)
dispatch.readline = read_write_wrapper(socket.readline)

return dispatch

