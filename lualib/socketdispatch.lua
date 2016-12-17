local socket = require "socket"
local core = require "silly.core"

local tremove = table.remove

local CONNECTING   = 1
local CONNECTED    = 2
local CLOSE        = 5
local FINAL        = 6

local dispatch = {}

local mt = {
	__index = dispatch,
	__gc = function(tbl)
		tbl:close()
	end
}

--the function of process response insert into d.funcqueue
function dispatch:create(config)
	local d = {}
	d.socket = false
	d.status = CLOSE
	d.dispatchco = false
	d.config = config
	d.connectqueue = {}
	d.waitqueue = {}
	d.funcqueue = {}	--process response, return
	d.result_data = {}
	setmetatable(d, mt)
	return d
end

local function wakeup_all(self, ret, err)
	local co = tremove(self.waitqueue, 1)
	tremove(self.funcqueue, 1)
	while co do
		self.result_data[co] = err
		core.wakeup(co, ret)
		co = tremove(self.waitqueue, 1)
		tremove(self.funcqueue, 1)
	end
end

local function doclose(self)
	if (self.status == CLOSE) then
		return
	end
	assert(self.sock >= 0)
	socket.close(self.sock)
	self.sock = false
	self.dispatchco = false
	self.status = CLOSE;
	wakeup_all(self, false, "disconnected")
end


--this function will be run the indepedent coroutine
local function dispatch_response(self)
	return function ()
		while true do
			local co = tremove(self.waitqueue, 1)
			local func = tremove(self.funcqueue, 1)
			if func and co then
				local ok, do_ok, status, data  = core.pcall(func, self)
				if ok and do_ok then
					self.result_data[co] = data
					core.wakeup(co, status)
				else
					local err
					if not ok then
						err = do_ok
					else
						err = "disconnected"
					end
					self.result_data[co] = err
					core.wakeup(co, false)
					doclose(self)
					return
				end
			else
				self.dispatchco = core.running()
				core.wait()
			end
		end
	end
end

local function waitfor_response(self, response)
	local co = core.running()
	self.waitqueue[#self.waitqueue + 1] = co
	self.funcqueue[#self.funcqueue + 1] = response
	if self.dispatchco then     --the first request
		local co = self.dispatchco
		self.dispatchco = nil
		core.wakeup(co)
	end
	local status = core.wait()
	local data = self.result_data[co]
	self.result_data[co] = nil
	return status, data
end

local function waitfor_connect(self)
	local co = core.running()
	self.connectqueue[#self.connectqueue + 1] = co
	local status = core.wait()
	local data = self.result_data[co]
	self.result_data[co] = nil
	return status, data
end

local function wakeup_conn(self, success, err)
	for k, v in pairs(self.connectqueue) do
		self.result_data[v] = err
		core.wakeup(v, success)
		self.connectqueue[k] = nil
	end
end

local function tryconnect(self)
	if self.status == CONNECTED then
		return true;
	end
	if self.status == FINAL then
		return false, "already closed"
	end
	local res
	if self.status == CLOSE then
		local err
		self.status = CONNECTING;
		self.sock = socket.connect(self.config.addr)
		if not self.sock then
			res = false
			self.status = CLOSE
			err = "socketdispatch connect fail"
		else
			res = true
			self.status = CONNECTED;
		end
		if res then
			assert(self.dispatchco == false)
			core.fork(dispatch_response(self))
			if self.config.auth then
				res = waitfor_response(self, self.config.auth)
			end
			assert(#self.funcqueue == 0)
			assert(#self.waitqueue == 0)
			if not res then
				doclose(self)
				err = "socketdispatch auth fail"
			end
		end
		wakeup_conn(self, res, err)
		return res, err
	elseif self.status == CONNECTING then
		return waitfor_connect(self)
	else
		core.error("try_connect incorrect call at status:" .. self.status)
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

-- the respose function will be called in the socketfifo coroutine
function dispatch:request(cmd, response)
	local res
	assert(tryconnect(self))
	res = socket.write(self.sock, cmd)
	if not res then
		doclose(self)
		return nil
	end
	if not response then
		return
	end
	return waitfor_response(self, response)
end

local function read_write_wrapper(func)
	return function (self, ...)
		return func(self.sock, ...)
	end
end

dispatch.read = read_write_wrapper(socket.read)
dispatch.write = read_write_wrapper(socket.write)
dispatch.readline = read_write_wrapper(socket.readline)

return dispatch

