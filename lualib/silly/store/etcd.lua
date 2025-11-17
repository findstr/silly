local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local logger = require "silly.logger"
local grpc = require "silly.net.grpc"
local v3proto = require "silly.store.etcd.v3.proto"
local channel = require "silly.sync.channel"
local pb = require "pb"

local DEFAULT_TTL<const> = 5000
local RETRY_CONN_WAIT<const> = 500

---@class silly.store.etcd.keepalive
---@field deadline integer
---@field nextkeepalive integer

---@class silly.store.etcd.watcher
---@field watchid integer
---@field canceling boolean
---@field watchreqc silly.sync.channel<silly.store.etcd.watcher>
---@field createreq silly.store.etcd.WatchCreateRequest
---@field outch silly.sync.channel<silly.store.etcd.WatchResponse>
local watcher = {}
local watcher_mt = { __index = watcher }

---@class silly.store.etcd.client
---@field closed boolean
---@field dialtimeout integer
---@field conn silly.net.grpc.client.conn
---@field retry integer
---@field retry_sleep integer
---@field keepalives table<integer, silly.store.etcd.keepalive>
---@field keepalivetimeout integer
---@field keepaliveco thread?
---@field keepstream silly.net.grpc.client.bstream?
---@field watchidx integer
---@field watchers table<integer, silly.store.etcd.watcher>
---@field watchreqc silly.sync.channel<silly.store.etcd.WatchRequest>
---@field watchco thread?
---@field watchstream silly.net.grpc.client.bstream?
---@field kv silly.net.grpc.client.service
---@field lease silly.net.grpc.client.service
---@field watch_ silly.net.grpc.client.service
local M = {}

local pairs = pairs
local assert = assert
local sub = string.sub
local char = string.char
local sleep = time.sleep
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

---@enum silly.store.etcd.WatchFilterType
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

---@param c silly.store.etcd.client
---@param resp silly.store.etcd.LeaseKeepAliveResponse
local function lease_recv_keepalive(c, resp)
	local keepalives = c.keepalives
	local ka = keepalives[resp.ID]
	if not ka then
		return
	end
	if resp.TTL <= 0 then
		keepalives[resp.ID] = nil
		return
	end
	local ttl = resp.TTL
	local now = time.now()
	ka.deadline = now + ttl
	ka.nextkeepalive = now + ttl // 3
end

---@param args {c:silly.store.etcd.client, stream:silly.net.grpc.client.bstream}
local function lease_send_task(args)
	local c = args.c
	local stream = args.stream
	local keepalives = c.keepalives
	while not c.closed do
		local tosend = {}
		local now = time.now()
		for id, ka in pairs(keepalives) do
			if ka.nextkeepalive <= now then
				tosend[#tosend + 1] = id
			end
		end
		for i = 1, #tosend do
			local id = tosend[i]
			local ok, err = stream:write {
				ID = id,
			}
			if not ok then
				logger.warn("[etcd] lease keepalive id:", id, "send error:", err)
				return
			end
		end
		time.sleep(RETRY_CONN_WAIT)
	end
end

---@param c silly.store.etcd.client
local function lease_recv_task(c)
	while not c.closed do
		local stream, err = c.lease:LeaseKeepAlive()
		if not stream then
			logger.warn("[etcd] lease keepalive stream error:", err)
		else
			c.keepstream = stream
			task.fork(lease_send_task, {c = c, stream = stream})
			while true do
				local res = stream:read()
				if not res then
					logger.warn("[etcd] lease keepalive read error:", stream.message)
					break
				end
				---@cast res silly.store.etcd.LeaseKeepAliveResponse
				lease_recv_keepalive(c, res)
			end
		end
		time.sleep(RETRY_CONN_WAIT)
	end
end

local EOS<const> = {}
---@param args {c:silly.store.etcd.client, stream:silly.net.grpc.client.bstream}
local function watch_recv_task(args)
	local c = args.c
	local stream = args.stream
	local watchers = c.watchers
	while true do
		local res = stream:read()
		if not res then
			logger.warn("[etcd] watch stream read error:", stream.message)
			break
		end
		local nstream = c.watchstream
		if stream ~= nstream then
			break
		end
		local watchid = res.watch_id
		local w = watchers[watchid]
		---@cast res silly.store.etcd.WatchResponse
		if res.canceled then
			watchers[watchid] = nil
			w.outch:close("watch canceled")
		elseif not res.created then
			local events = res.events
			local n = #events
			if n > 0 then
				w.createreq.start_revision = events[n].kv.mod_revision + 1
			end
			w.outch:push(res)
		end
	end
	c.watchreqc:push(EOS)
end

---@param c silly.store.etcd.client
local function watch_request_task(c)
	local stream, err
	local watchers = c.watchers
	local watchreqc = c.watchreqc
	while true do
		local reqw = watchreqc:pop()
		if not reqw then --watchreqc closed
			break
		end
		---@cast reqw silly.store.etcd.WatchRequest
		::reconnect::
		if c.closed then
			break
		end
		if not stream then
			stream, err = c.watch_:Watch()
			if not stream then
				logger.warn("[etcd] watch stream error:", err)
				time.sleep(RETRY_CONN_WAIT)
				goto reconnect
			end
			c.watchstream = stream
			task.fork(watch_recv_task, {c = c, stream = stream})
			watchreqc:clear()
			local tosend = {}
			for k, w in pairs(watchers) do
				if w.canceling then
					w.outch:close("watch canceled")
					watchers[k] = nil
				else
					tosend[#tosend + 1] = {
						create_request = w.createreq,
					}
				end
			end
			for i = 1, #tosend do
				local ok, err = stream:write(tosend[i])
				if not ok then
					logger.warn("[etcd] watch stream write error:", err)
					stream:close()
					stream = nil
					goto reconnect
				end
			end
		elseif reqw ~= EOS then
			local ok, err = stream:write(reqw)
			if not ok then
				logger.warn("[etcd] watch stream write error:", err)
				stream:close()
				stream = nil
				goto reconnect
			end
		else
			stream:close()
			stream = nil
			goto reconnect
		end
	end
end

---@param self silly.store.etcd.watcher
---@return silly.store.etcd.WatchResponse?, string? error
function watcher:read()
	return self.outch:pop()
end

---@param self silly.store.etcd.watcher
function watcher:cancel()
	if self.canceling then
		return
	end
	self.canceling = true
	self.watchreqc:push {
		cancel_request = {
			watch_id = self.watchid,
		},
	}
end

local mt = { __index = M }
---@param opts {
---	endpoints:string[],	--etcd server address
---	retry:integer|nil,	--retry times
---	retry_sleep:integer|nil,--retry sleep time(ms)
---	dialtimeout:number|nil, --timeout
---}
---@return silly.store.etcd.client?, string? error
function M.newclient(opts)
	local conn, err = grpc.newclient {
		targets = opts.endpoints
	}
	if not conn then
		return nil, err
	end
	local dialtimeout = opts.dialtimeout or 0
	local keepalivetimeout = dialtimeout == 0 and DEFAULT_TTL or (dialtimeout + 1000)
	local proto = v3proto.loaded["etcdv3.proto"]
	---@type silly.store.etcd.client
	local c = {
		closed = false,
		conn = conn,
		retry = opts.retry or 5,
		retry_sleep = opts.retry_sleep or 1000,
		dialtimeout = dialtimeout,
		keepalives = {},
		keepaliveco = nil,
		keepalivetimeout = keepalivetimeout,
		keepstream = nil,
		watchidx = 1,
		watchers = {},
		watchstream = nil,
		watchreqc = channel.new(),
		kv = assert(grpc.newservice(conn, proto, "KV")),
		lease = assert(grpc.newservice(conn, proto, "Lease")),
		watch_ = assert(grpc.newservice(conn, proto, "Watch")),
	}
	setmetatable(c, mt)
	return c
end

---@param req {
---    key:string,                --The key to store (required)
---    value:string,              --The value to store (required)
---    lease:integer|nil,         --Optional lease ID for the key-value pair
---    prev_kv:boolean|nil,       --If true, returns the previous key-value pair
---    ignore_value:boolean|nil,  --If true, etcd updates the key using its current value.
---    ignore_lease:boolean|nil,  --If true, etcd updates the key using its current lease.
---}
---@return {
---    header:silly.store.etcd.ResponseHeader, -- The response header
---    prev_kv:silly.store.etcd.KeyValue,    -- If `prev_kv` was set, returns the previous key-value pair
---}|nil
--- @return string|nil
function M.put(self, req)
	local res, err
	apply_options(req)
	for i = 1, self.retry do
		res, err = self.kv:Put(req)
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
---	header:silly.store.etcd.ResponseHeader, -- The response header
---	kvs:silly.store.etcd.KeyValue[],      -- The key-value pairs
---	more:boolean,                -- Indicates whether there are more keys to return
---	count:number,                -- The number of keys
--- }|nil
--- @return string|nil
function M.get(self, req)
	local res, err
	apply_options(req)
	for i = 1, self.retry do
		res, err = self.kv:Range(req)
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
---	header:silly.store.etcd.ResponseHeader, -- The response header
---     deleted:boolean,            -- Indicates whether the key was deleted
---     prev_kvs:silly.store.etcd.KeyValue[], -- If `prev_kv` was set, the previous key-value pairs will be returned.
---}|nil
---@return string|nil
function M.delete(self, req)
	local res, err
	apply_options(req)
	for i = 1, self.retry do
		res, err = self.kv:DeleteRange(req)
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
---	header:silly.store.etcd.ResponseHeader, -- The response header
--- }|nil
--- @return string|nil
function M.compact(self, req)
	local res, err
	apply_options(req)
	for i = 1, self.retry do
		res, err = self.kv:Compact(req)
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
--- 	header:silly.store.etcd.ResponseHeader, -- The response header
---     ID:integer,     -- The lease ID granted
---     TTL:integer,    -- The TTL (time-to-live) for the lease
---     error:string,
--- }|nil
--- @return string|nil
function M.grant(self, req)
	local res, err
	for i = 1, self.retry do
		res, err = self.lease:LeaseGrant(req)
		if res then
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
--- 	header:silly.store.etcd.ResponseHeader, -- The response header
--- }|nil
--- @return string|nil
function M.revoke(self, req)
	local res, err
	for i = 1, self.retry do
		res, err = self.lease:LeaseRevoke(req)
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
---	header:silly.store.etcd.ResponseHeader, -- The response header
---	ID:integer,  -- The lease ID from the keep alive request
---	TTL:integer, -- The remaining TTL in seconds for the lease; the lease will expire in under TTL+1 seconds
---	grantedTTL:integer, -- The initial granted time in seconds upon lease creation/renewal
---	keys:string[], -- The list of keys attached to this lease
---}
---@return string|nil
function M.ttl(self, req)
	return self.lease:LeaseTimeToLive(req)
end

---@return {
---	leases:{
---		ID:integer,  -- The lease ID
---	}[],                 -- The list of leases
---}
function M.leases(self)
	return self.lease:LeaseLeases()
end

---@param id integer
function M.keepalive(self, id)
	local keepalives = self.keepalives
	local ka = keepalives[id]
	if ka then
		return
	end
	local now = time.now()
	ka = {
		nextkeepalive = now,
		deadline = now + self.keepalivetimeout,
	}
	keepalives[id] = ka
	if not self.keepaliveco then
		self.keepaliveco = task.fork(lease_recv_task, self)
	end
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
--- @return silly.store.etcd.watcher?, string? error
function M.watch(self, req)
	apply_options(req)
	local filters = {}
	for k, v in pairs(watch_filter_type) do
		if req[k] then
			req[k] = nil
			filters[#filters + 1] = v
		end
	end
	if #filters > 0 then
		req.filters = filters
	end
	local id = self.watchidx
	self.watchidx = self.watchidx + 1
	local watchreqc = self.watchreqc
	---@cast req silly.store.etcd.WatchCreateRequest
	req.watch_id = id
	local outch = channel.new()
	---@type silly.store.etcd.watcher
	local w = {
		watchid = id,
		outch = outch,
		createreq = req,
		watchreqc = watchreqc,
		canceling = false,
	}
	setmetatable(w, watcher_mt)
	watchreqc:push({ create_request = req })
	self.watchers[id] = w
	if not self.watchco then
		self.watchco = task.fork(watch_request_task, self)
	end
	return w, nil
end

---@param self silly.store.etcd.client
function M.close(self)
	if self.closed then
		return
	end
	self.closed = true
	local watchstream = self.watchstream
	if watchstream then
		watchstream:close()
	end
	local keepstream = self.keepstream
	if keepstream then
		keepstream:close()
	end
	self.conn:close()
	self.watchreqc:close("client closed")
	for _, w in pairs(self.watchers) do
		w.outch:close("client closed")
	end
end

return M
