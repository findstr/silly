local core = require "core"
local logger = require "core.logger"
local grpc = require "core.grpc"
local proto = require "core.etcd.v3.proto"
local pb = require "pb"
local M = {}

local next = next
local pairs = pairs
local assert = assert
local sort = table.sort
local sub = string.sub
local char = string.char
local sleep = core.sleep
local timeout = core.timeout
local setmetatable = setmetatable

local no_prefix_end = "\0"

local sort_order_num<const> = {
	NONE = pb.enum(".etcdserverpb.RangeRequest.SortOrder", "NONE"),
	ASCEND = pb.enum(".etcdserverpb.RangeRequest.SortOrder", "ASCEND"),
	DESCEND = pb.enum(".etcdserverpb.RangeRequest.SortOrder", "DESCEND"),
}

local sort_target_num<const> = {
	KEY = pb.enum(".etcdserverpb.RangeRequest.SortTarget", "KEY"),
	VERSION = pb.enum(".etcdserverpb.RangeRequest.SortTarget", "VERSION"),
	CREATE = pb.enum(".etcdserverpb.RangeRequest.SortTarget", "CREATE"),
	MOD = pb.enum(".etcdserverpb.RangeRequest.SortTarget", "MOD"),
	VALUE = pb.enum(".etcdserverpb.RangeRequest.SortTarget", "VALUE"),
}

local watch_filter_type<const> = {
	NOPUT = pb.enum(".etcdserverpb.WatchCreateRequest.FilterType", "NOPUT"),
	NODELETE = pb.enum(".etcdserverpb.WatchCreateRequest.FilterType", "NODELETE"),
}

local function opt_prefix(key, _, options)
	options.prefix = nil
	if not key or #key == 0 then
		options.key = no_prefix_end
		options.range_end = no_prefix_end
		return
	end
	for i = #key, 1, -1 do
		local n = key:byte(i)
		if n < 0xff then
			options.range_end = sub(key, 1, i - 1) .. char(n + 1)
			return
		end
	end
	-- next prefix does not exist (e.g., 0xffff);
	-- default to WithFromKey policy
	options.range_end = no_prefix_end
end

local function opt_fromkey(key, opt, options)
	if #key == 0 then
		options.key = no_prefix_end
		return
	end
	options.range_end = no_prefix_end
end

local function opt_options(_, sort_target, options)
	if not sort_target then
		return
	end
	local sort_order
	if sort_target == "KEY" then
		sort_order = options.sort_order
		if sort_order == "ASCEND" then
			sort_order = "NONE"
		end
	end
	options.sort_order = sort_order_num[sort_order]
	options.sort_target = sort_target_num[sort_target]
end

local option_fn = {
	prefix = opt_prefix,
	fromkey = opt_fromkey,
	sort_target = opt_options,
}

local function apply_options(options)
	if not options then
		return
	end
	local key = options.key
	for k, fn in pairs(option_fn) do
		local v = options[k]
		if v then
			fn(key, v, options)
		end
	end
end

local mt = {__index = M}
function M.newclient(conf)
	local c = setmetatable({
		retry = conf.retry or 5,
		retry_sleep = conf.retry_sleep or 1000,
		kv = assert(grpc.newclient {
			service = "KV",
			endpoints = conf.endpoints,
			proto = proto.loaded['rpc.proto'],
			timeout = conf.timeout,
		}),
		lease = assert(grpc.newclient {
			service = "Lease",
			endpoints = conf.endpoints,
			proto = proto.loaded['rpc.proto'],
			timeout = conf.timeout,
		}),
		watcher = assert(grpc.newclient {
			service = "Watch",
			endpoints = conf.endpoints,
			proto = proto.loaded['rpc.proto'],
			timeout = conf.timeout,
		}),
		lease_list = {},
		lease_timer = nil,
		keepalive_stream = nil
	}, mt)
	c.lease_timer = function(_)
		local n = 0
		local stream = c.keepalive_stream
		if not stream then
			stream = c.lease.LeaseKeepAlive()
			c.keepalive_stream = stream
		end
		for lease_id in pairs(c.lease_list) do
			local ok, err = stream:write {
				ID = lease_id,
			}
			if ok then
				local res, err = stream:read()
				if not res then
					logger.error("[core.etcd] lease keepalive error:", err)
				end
			else
				logger.error("[core.etcd] lease keepalive lease:", lease_id, "error:", err)
			end
			n = n + 1
		end
		if n > 0 then
			timeout(1000, c.lease_timer)
		else
			stream:close()
			c.keepalive_stream = nil
		end
	end
	return c
end

function M.put(self, req)
	local res, err
	apply_options(req)
	for i = 1, self.retry do
		res, err = self.kv.Put(req)
		if res then
			break
		end
		sleep(self.retry_sleep)
	end
	return res, err
end

function M.get(self, req)
	local res, err
	apply_options(req)
	for i = 1, self.retry do
		res, err = self.kv.Range(req)
		if res then
			break
		end
		sleep(self.retry_sleep)
	end
	return res, err
end

function M.delete(self, req)
	local res, err
	apply_options(req)
	for i = 1, self.retry do
		res, err = self.kv.DeleteRange(req)
		if res then
			return res, err
		end
		sleep(self.retry_sleep)
	end
	return res, err
end

function M.compact(self, req)
	local res, err
	apply_options(req)
	for i = 1, self.retry do
		res, err = self.kv.Compact(req)
		if res then
			break
		end
		sleep(self.retry_sleep)
	end
	return res, err
end

--Lease
function M.grant(self, req)
	local res, err
	for i = 1, self.retry do
		res, err = self.lease.LeaseGrant(req)
		if res then
			local lease_list = self.lease_list
			if not next(lease_list) then
				timeout(1000, self.lease_timer)
			end
			lease_list[res.ID] = true
			break
		end
		sleep(self.retry_sleep)
	end
	return res, err
end

function M.revoke(self, req)
	local res, err
	self.lease_list[req.ID] = nil
	for i = 1, self.retry do
		res, err = self.lease.LeaseRevoke(req)
		if res then
			break
		end
		sleep(self.retry_sleep)
	end
	return res, err
end

function M.ttl(self, req)
	return self.lease.LeaseTimeToLive(req)
end

function M.leases(self)
	return self.lease.LeaseLeases()
end

function M.keepalive(self, req)
	return self.lease.LeaseKeepAlive(req)
end

--watcher
function M.watch(self, req)
	apply_options(req)
	local filters = {}
	for k, v in pairs(watch_filter_type) do
		if req[k] then
			filters[#filters + 1] = v
		end
	end
	if #filters > 0 then
		req.filters = filters
	end
	local stream, err = self.watcher.Watch()
	if not stream then
		return nil, err
	end
	local ok, err = stream:write({create_request = req})
	if not ok then
		stream:close()
		return nil, err
	end
	local ack, err = stream:read()
	if not ack then
		return nil, err
	end
	return stream, nil
end

local function wait_for_lock(self, prefix, key)
	local list, err = self:get {
		key = prefix,
		prefix = true
	}
	if not list then
		return nil, err
	end
	local kvs = list.kvs
	sort(kvs, function(a, b)
		return a.mod_revision < b.mod_revision
	end)
	if kvs[1].key == key then
		return true
	end
	local last_key = nil
	for _, kv in pairs(kvs) do
		if kv.key == key then
			break
		end
		last_key = kv.key
	end
	local stream, err = self:watch {
		key = last_key,
		NOPUT = true,
	}
	if not stream then
		return nil, err
	end
	while true do
		local res, err = stream:read()
		if not res then
			logger.error("[core.etcd] watch key:", last_key, "err:", err)
			stream:close()
			return nil, err
		end
		for _, event in ipairs(res.events) do
			if event.kv.key == last_key and event.type == "DELETE" then
				return true
			end
		end
	end
end

function M.lock(self, lease_id, prefix, uuid)
	local key = prefix .. "/" .. uuid
	local res, err = self:put {
		key = key,
		value = "1",
		lease = lease_id,
	}
	if not res then
		return res, err
	end
	res, err = wait_for_lock(self, prefix, key)
	return res, err
end

function M.unlock(self, prefix, uuid)
	return self:delete {
		key = prefix .. "/" .. uuid
	}
end

return M
