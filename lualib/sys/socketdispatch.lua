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
		tbl:close()
	end
}

--the function of process response insert into d.funcqueue
function dispatch:create(config)
	local d = {
		socket = false,
		status = CLOSE,
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
		local waitqueue = self.waitqueue
		local funcqueue = self.funcqueue
		local result_data = self.result_data
		while true do
			local co = tremove(waitqueue, 1)
			local func = tremove(funcqueue, 1)
			if func and co then
				local ok, status, data  = core.pcall(func, self)
				if ok then
					result_data[co] = data
					core.wakeup(co, status)
				else
					result_data[co] = status
					core.wakeup(co, false)
					doclose(self)
					return
				end
			else
				local co = core.running()
				self.dispatchco = co
				core.wait(co)
			end
		end
	end
end

local function waitfor_response(self, response)
	local co = core.running()
	local waitqueue = self.waitqueue
	local funcqueue = self.funcqueue
	waitqueue[#waitqueue + 1] = co
	funcqueue[#funcqueue + 1] = response
	if self.dispatchco then     --the first request
		local co = self.dispatchco
		self.dispatchco = nil
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
		return true;
	end
	if status == FINAL then
		return false, "already closed"
	end
	local res
	if status == CLOSE then
		local err
		self.status = CONNECTING;
		self.sock = socket.connect(self.addr)
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
			local auth = self.auth
			if auth then
				local ok, msg
				ok, res, msg = core.pcall(auth, self)
				if not ok then
					err = res
					res = err
					doclose(self)
				elseif not res then
					err = msg
					doclose(self)
				end
			end
			assert(#self.funcqueue == 0)
			assert(#self.waitqueue == 0)
		end
		wakeup_conn(self, res, err)
		return res, err
	elseif status == CONNECTING then
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

-- the respose function will be called in the socketfifo coroutine
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
	return function (self, ...)
		return func(self.sock, ...)
	end
end

dispatch.read = read_write_wrapper(socket.read)
dispatch.write = read_write_wrapper(socket.write)
dispatch.readline = read_write_wrapper(socket.readline)

return dispatch

