local time = require "silly.time"
local silly = require "silly"
local logger = require "silly.logger"
local grpc = require "silly.net.grpc"
local proto = require "silly.store.etcd.v3.proto"
local pb = require "pb"
---@class silly.store.etcd.client
---@field retry integer
---@field retry_sleep integer
---@field kv silly.net.grpc.client
---@field lease silly.net.grpc.client
---@field watcher silly.net.grpc.client
---@field lease_list table<integer, boolean>
---@field lease_timer fun(self:silly.store.etcd.client)
local M = {}

local next = next
local pairs = pairs
local assert = assert
local sort = table.sort
local sub = string.sub
local char = string.char
local sleep = time.sleep
local timeout = time.after
local setmetatable = setmetatable

local no_prefix_end = "\0"

local sort_order_num <const> = {
	NONE = pb.enum(".etcdserverpb.RangeRequest.SortOrder", "NONE"),
	ASCEND = pb.enum(".etcdserverpb.RangeRequest.SortOrder", "ASCEND"),
	DESCEND = pb.enum(".etcdserverpb.RangeRequest.SortOrder", "DESCEND"),
}

local sort_target_num <const> = {
	KEY = pb.enum(".etcdserverpb.RangeRequest.SortTarget", "KEY"),
	VERSION = pb.enum(".etcdserverpb.RangeRequest.SortTarget", "VERSION"),
	CREATE = pb.enum(".etcdserverpb.RangeRequest.SortTarget", "CREATE"),
	MOD = pb.enum(".etcdserverpb.RangeRequest.SortTarget", "MOD"),
	VALUE = pb.enum(".etcdserverpb.RangeRequest.SortTarget", "VALUE"),
}

local watch_filter_type <const> = {
	NOPUT = pb.enum(".etcdserverpb.WatchCreateRequest.FilterType", "NOPUT"),
	NODELETE = pb.enum(".etcdserverpb.WatchCreateRequest.FilterType", "NODELETE"),
}

---@param key string
---@param options table
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

---@param key string
---@param options table
local function opt_fromkey(key, opt, options)
	if #key == 0 then
		options.key = no_prefix_end
		return
	end
	options.range_end = no_prefix_end
end

---@param sort_target string
---@param options table
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

---@param options table
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

local mt = { __index = M }
---@param conf {
---	endpoints:string[],	--etcd server address
---	retry:integer|nil,	--retry times
---	retry_sleep:integer|nil,--retry sleep time(ms)
---	timeout:number|nil,	--timeout
---}
---@return silly.store.etcd.client
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
					logger.error("[etcd] lease keepalive error:", err)
				end
			else
				logger.error("[etcd] lease keepalive lease:", lease_id, "error:", err)
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

---@class etcd.ResponseHeader
---@field cluster_id integer	--cluster_id is the ID of the cluster which sent the response.
---@field member_id integer	--member_id is the ID of the member which sent the response.
---revision is the key-value store revision when the request was applied, and it's
---unset (so 0) in case of calls not interacting with key-value store.
---For watch progress responses, the header.revision indicates progress. All future events
---received in this stream are guaranteed to have a higher revision number than the
---header.revision number.
---@field revision integer
---raft_term is the raft term when the request was applied.
---@field raft_term integer

---@class mvccpb.KeyValue
---key is the key in bytes. An empty key is not allowed.
---@field key string\
---create_revision is the revision of last creation on this key.
---@field create_revision integer
---mod_revision is the revision of last modification on this key.
---@field mod_revision integer
---version is the version of the key. A deletion resets
---the version to zero and any modification of the key
---increases its version
---@field version integer
---value is the value held by the key, in bytes.
---@field value string
---lease is the ID of the lease that attached to key.
---When the attached lease expires, the key will be deleted.
---If lease is 0, then no lease is attached to the key.
---@field lease integer

---@param req {
---    key:string,                --The key to store (required)
---    value:string,              --The value to store (required)
---    lease:integer|nil,         --Optional lease ID for the key-value pair
---    prev_kv:boolean|nil,       --If true, returns the previous key-value pair
---    ignore_value:boolean|nil,  --If true, etcd updates the key using its current value.
---    ignore_lease:boolean|nil,  --If true, etcd updates the key using its current lease.
---}
---@return {
---    header:etcd.ResponseHeader, -- The response header
---    prev_kv:mvccpb.KeyValue,    -- If `prev_kv` was set, returns the previous key-value pair
---}|nil
--- @return string|nil
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

---@param req {
---	key:string,	--The key to get (required)
---	prefix:boolean|nil,	--If true, returns all keys with the prefix
---	limit:number|nil,	--Limits the number of keys to return
---	revision:number|nil,	--The point-in-time of the key-value store to use for the range.
---	sort_order:'NONE'|'ASCEND'|'DESCEND'|nil, --The order for returned sorted results.
---	sort_target:'KEY'|'VERSION'|'CREATE'|'MOD'|'VALUE'|nil, --The key-value field to use for sorting.
---	serializable:boolean|nil, --Sets the range request to use serializable member-local reads.
---	keys_only:boolean|nil, --If true, returns only the keys and not the values.
---	count_only:boolean|nil, --If true, returns only the count of the keys.
---	min_mod_revision:number|nil, --The lower bound for returned key mod revisions.
---	max_mod_revision:number|nil, --The upper bound for returned key mod revisions.
---	min_create_revision:number|nil, --The lower bound for returned key create revisions
---	max_create_revision:number|nil, --The upper bound for returned key create revisions
---}
---@return {
---	header:etcd.ResponseHeader, -- The response header
---	kvs:mvccpb.KeyValue[],      -- The key-value pairs
---	more:boolean,                -- Indicates whether there are more keys to return
---	count:number,                -- The number of keys
--- }|nil
--- @return string|nil
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

---@param req {
---     key:string,           -- The key to delete (required)
--- 	prefix:boolean|nil,   -- If true, deletes all keys with the prefix
---	prev_kv:boolean|nil,  -- If true, returns the previous key-value pair
---}
---@return {
---	header:etcd.ResponseHeader, -- The response header
---     deleted:boolean,            -- Indicates whether the key was deleted
---     prev_kvs:mvccpb.KeyValue[], -- If `prev_kv` was set, the previous key-value pairs will be returned.
---}|nil
---@return string|nil
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

--- @param req {
---     revision:integer,      -- The revision to compact (required)
---     physical:boolean|nil,  -- If true, forces a physical compaction
--- }
--- @return {
---	header:etcd.ResponseHeader, -- The response header
--- }|nil
--- @return string|nil
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

--- @param req {
---     TTL:integer,    -- The TTL (time-to-live) for the lease (required)
--- 	ID:integer,     -- The lease ID to grant (optional)
--- }
--- @return {
--- 	header:etcd.ResponseHeader, -- The response header
---     ID:integer,     -- The lease ID granted
---     TTL:integer,    -- The TTL (time-to-live) for the lease
---     error:string,
--- }|nil
--- @return string|nil
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

--- @param req {
---     ID:integer,  -- The lease ID to revoke (required)
--- }
--- @return {
--- 	header:etcd.ResponseHeader, -- The response header
--- }|nil
--- @return string|nil
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

---@param req {
---	ID:integer,  -- The lease ID to query (required)
---	keys:boolean, -- If true, queries all keys attached to the lease
---}
---@return {
---	header:etcd.ResponseHeader, -- The response header
---	ID:integer,  -- The lease ID from the keep alive request
---	TTL:integer, -- The remaining TTL in seconds for the lease; the lease will expire in under TTL+1 seconds
---	grantedTTL:integer, -- The initial granted time in seconds upon lease creation/renewal
---	keys:string[], -- The list of keys attached to this lease
---}
---@return string|nil
function M.ttl(self, req)
	return self.lease.LeaseTimeToLive(req)
end

---@return {
---	leases:{
---		ID:integer,  -- The lease ID
---	}[],                  -- The list of leases
---}
function M.leases(self)
	return self.lease.LeaseLeases()
end

---@param req {
---	ID:integer,  -- The lease ID to keep alive (required)
---}
---@return {
---	header:etcd.ResponseHeader, -- The response header
---	ID:integer,  -- The lease ID from the keep alive request
---	TTL:integer, -- The new time-to-live for the lease
---}
---@return string|nil
function M.keepalive(self, req)
	return self.lease.LeaseKeepAlive(req)
end

--- @param req {
---     key:string,                        -- The key to watch (required)
---     revision:number|nil,               -- The revision version to start watching from (optional)
---     wait:boolean|nil,                  -- If true, blocks and waits for a key change (optional)
---     prefix:boolean|nil,                -- If true, watches a prefix of keys (optional)
---     range_end:string|nil,              -- The range end for prefix-based watch (optional)
---     filters:table|nil,                 -- The list of filters to apply on the watch (optional)
---     limit:number|nil,                  -- Limits the number of events returned (optional)
---     progress_notify:boolean|nil,       -- If true, sends a progress notification for the watch (optional)
--- }
--- @return silly.net.grpc.stream|nil, string|nil
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
	local ok, err = stream:write({ create_request = req })
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

--- @param prefix string
--- @param key string
--- @return boolean, string|nil
local function wait_for_lock(self, prefix, key)
	local list, err = self:get {
		key = prefix,
		prefix = true
	}
	if not list then
		return false, err
	end
	local kvs = list.kvs
	sort(kvs, function(a, b)
		return a.mod_revision < b.mod_revision
	end)
	if kvs[1].key == key then
		return true, nil
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
		return false, err
	end
	while true do
		local res, err = stream:read()
		if not res then
			logger.error("[etcd] watch key:", last_key, "err:", err)
			stream:close()
			return false, err
		end
		for _, event in ipairs(res.events) do
			if event.kv.key == last_key and event.type == "DELETE" then
				return true, nil
			end
		end
	end
end

---@param lease_id integer
---@param prefix string
---@param uuid string
---@return boolean|nil, string|nil
function M.lock(self, lease_id, prefix, uuid)
	local key = prefix .. "/" .. uuid
	local res, err = self:put {
		key = key,
		value = "1",
		lease = lease_id,
	}
	if not res then
		return false, err
	end
	return wait_for_lock(self, prefix, key)
end

---@param prefix string
---@param uuid string
function M.unlock(self, prefix, uuid)
	return self:delete {
		key = prefix .. "/" .. uuid
	}
end

return M
