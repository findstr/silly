local silly = require "silly"
local time = require "silly.time"
local grpc = require "silly.net.grpc"
local registrar = require "silly.net.grpc.registrar"
local v3proto = require "silly.store.etcd.v3.proto"

local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local setmetatable = setmetatable

-- In-memory storage for the fake etcd server
---@class FakeEtcdStorage
---@field storage table<string, silly.store.etcd.KeyValue>
---@field revision integer
---@field leases table<integer, {ID:integer, TTL:integer, deadline:integer, keys:table<string,boolean>}>
---@field lease_id_counter integer
---@field watchers table<integer, {key:string, range_end:string?, start_revision:integer, stream:any}>
---@field watcher_id_counter integer
---@field watch_requests table -- Hook to capture watch create requests
---@field keepalive_requests table -- Hook to capture lease keepalive requests
---@field active_streams table -- Track all active streams for forced close
local Storage = {}

function Storage:new()
	local s = {
		storage = {},
		revision = 0,
		leases = {},
		lease_id_counter = 1,
		watchers = {},
		watcher_id_counter = 1,
		watch_requests = {},  -- Array to store watch create requests for testing
		keepalive_requests = {},  -- Array to store keepalive requests for testing
		active_streams = {},  -- Array to track active streams
	}
	return setmetatable(s, {__index = Storage})
end

-- Helper function to get response header
function Storage:header()
	return {
		cluster_id = 1,
		member_id = 1,
		revision = self.revision,
		raft_term = 1,
	}
end

-- Helper function to check if a key is in range
local function in_range(key, start_key, range_end)
	if not range_end or range_end == "" then
		return key == start_key
	end
	if range_end == "\0" then
		return key >= start_key
	end
	return key >= start_key and key < range_end
end

-- KV service handlers
local KVHandlers = {}

function KVHandlers.Put(self, req)
	local storage = self.storage
	local key = req.key
	local value = req.value
	local lease = req.lease or 0

	-- Get previous kv if requested
	local prev_kv = nil
	if req.prev_kv then
		prev_kv = storage.storage[key]
	end

	-- Increment revision
	storage.revision = storage.revision + 1
	local now_revision = storage.revision

	-- Create or update key-value
	local existing = storage.storage[key]
	local kv = {
		key = key,
		value = value,
		create_revision = existing and existing.create_revision or now_revision,
		mod_revision = now_revision,
		version = existing and (existing.version + 1) or 1,
		lease = lease,
	}
	storage.storage[key] = kv

	-- Attach to lease if specified
	if lease ~= 0 then
		local lease_obj = storage.leases[lease]
		if lease_obj then
			lease_obj.keys[key] = true
		end
	end

	-- Notify watchers
	self:notify_watchers({
		type = "PUT",
		kv = kv,
	})

	return {
		header = storage:header(),
		prev_kv = prev_kv,
	}
end

function KVHandlers.Range(self, req)
	local storage = self.storage
	local key = req.key
	local range_end = req.range_end
	local limit = req.limit or 0
	local count_only = req.count_only
	local keys_only = req.keys_only
	local sort_target = req.sort_target
	local sort_order = req.sort_order

	-- Collect matching keys
	local kvs = {}
	local count = 0
	for k, v in pairs(storage.storage) do
		if in_range(k, key, range_end) then
			count = count + 1
			if not count_only then
				if keys_only then
					kvs[#kvs + 1] = {
						key = v.key,
						create_revision = v.create_revision,
						mod_revision = v.mod_revision,
						version = v.version,
						lease = v.lease,
					}
				else
					kvs[#kvs + 1] = v
				end
			end
		end
	end

	-- Sort if requested
	if #kvs > 0 and sort_target then
		local sort_field
		-- Handle both string enum names and numeric values
		if sort_target == "KEY" or sort_target == 0 then
			sort_field = "key"
		elseif sort_target == "VERSION" or sort_target == 1 then
			sort_field = "version"
		elseif sort_target == "CREATE" or sort_target == 2 then
			sort_field = "create_revision"
		elseif sort_target == "MOD" or sort_target == 3 then
			sort_field = "mod_revision"
		elseif sort_target == "VALUE" or sort_target == 4 then
			sort_field = "value"
		end

		if sort_field then
			table.sort(kvs, function(a, b)
				local va = a[sort_field]
				local vb = b[sort_field]
				-- Handle both string enum names and numeric values
				local is_descend = (sort_order == "DESCEND" or sort_order == 2)
				if is_descend then
					return va > vb
				else -- ASCEND, NONE, or any other value defaults to ascending
					return va < vb
				end
			end)
		end
	end

	-- Apply limit after sorting
	if limit > 0 and #kvs > limit then
		local limited = {}
		for i = 1, limit do
			limited[i] = kvs[i]
		end
		kvs = limited
	end

	-- Check if there are more keys
	local more = limit > 0 and count > limit

	return {
		header = storage:header(),
		kvs = count_only and {} or kvs,
		count = count,
		more = more,
	}
end

function KVHandlers.DeleteRange(self, req)
	local storage = self.storage
	local key = req.key
	local range_end = req.range_end
	local prev_kv = req.prev_kv

	-- Collect keys to delete
	local to_delete = {}
	for k, v in pairs(storage.storage) do
		if in_range(k, key, range_end) then
			to_delete[#to_delete + 1] = {key = k, kv = v}
		end
	end

	-- Delete keys and collect prev_kvs
	local prev_kvs = {}
	for _, item in ipairs(to_delete) do
		storage.storage[item.key] = nil
		if prev_kv then
			prev_kvs[#prev_kvs + 1] = item.kv
		end

		-- Notify watchers
		storage.revision = storage.revision + 1
		self:notify_watchers({
			type = "DELETE",
			kv = {
				key = item.key,
				mod_revision = storage.revision,
			},
		})
	end

	return {
		header = storage:header(),
		deleted = #to_delete,
		prev_kvs = prev_kvs,
	}
end

function KVHandlers.Compact(self, req)
	local storage = self.storage
	-- In a real implementation, this would remove old revisions
	-- For the fake server, we just acknowledge the request
	return {
		header = storage:header(),
	}
end

-- Lease service handlers
local LeaseHandlers = {}

function LeaseHandlers.LeaseGrant(self, req)
	local storage = self.storage
	local TTL = req.TTL
	local ID = req.ID

	-- Generate lease ID if not provided
	if ID == 0 then
		ID = storage.lease_id_counter
		storage.lease_id_counter = storage.lease_id_counter + 1
	end

	-- Create lease
	local now = time.now()
	storage.leases[ID] = {
		ID = ID,
		TTL = TTL,
		deadline = now + TTL * 1000,  -- Convert to milliseconds
		keys = {},
	}

	return {
		header = storage:header(),
		ID = ID,
		TTL = TTL,
	}
end

function LeaseHandlers.LeaseRevoke(self, req)
	local storage = self.storage
	local ID = req.ID

	-- Get lease
	local lease = storage.leases[ID]
	if lease then
		-- Delete all keys attached to the lease
		for key in pairs(lease.keys) do
			storage.storage[key] = nil
			storage.revision = storage.revision + 1
			self:notify_watchers({
				type = "DELETE",
				kv = {
					key = key,
					mod_revision = storage.revision,
				},
			})
		end

		-- Remove lease
		storage.leases[ID] = nil
	end

	return {
		header = storage:header(),
	}
end

function LeaseHandlers.LeaseKeepAlive(self, stream)
	local storage = self.storage

	-- Track this stream
	storage.active_streams[#storage.active_streams + 1] = stream

	-- Read keepalive requests and respond
	while true do
		local req = stream:read()
		if not req then
			break
		end

		local ID = req.ID

		-- Hook: Record keepalive request for testing
		storage.keepalive_requests[#storage.keepalive_requests + 1] = {
			ID = ID,
			timestamp = time.now(),
		}

		local lease = storage.leases[ID]

		if lease then
			-- Refresh lease deadline
			local now = time.now()
			lease.deadline = now + lease.TTL * 1000

			-- Send keepalive response
			stream:write({
				header = storage:header(),
				ID = ID,
				TTL = lease.TTL,
			})
		else
			-- Lease not found, return with TTL = -1
			stream:write({
				header = storage:header(),
				ID = ID,
				TTL = -1,
			})
		end
	end
end

function LeaseHandlers.LeaseTimeToLive(self, req)
	local storage = self.storage
	local ID = req.ID
	local keys = req.keys

	local lease = storage.leases[ID]
	if not lease then
		return {
			header = storage:header(),
			ID = ID,
			TTL = -1,
			grantedTTL = 0,
			keys = {},
		}
	end

	-- Calculate remaining TTL
	local now = time.now()
	local remaining_ms = lease.deadline - now
	local remaining_s = remaining_ms > 0 and (remaining_ms // 1000) or -1

	-- Collect keys if requested
	local key_list = {}
	if keys then
		for key in pairs(lease.keys) do
			key_list[#key_list + 1] = key
		end
	end

	return {
		header = storage:header(),
		ID = ID,
		TTL = remaining_s,
		grantedTTL = lease.TTL,
		keys = key_list,
	}
end

function LeaseHandlers.LeaseLeases(self, req)
	local storage = self.storage

	-- Collect all leases
	local leases = {}
	for _, lease in pairs(storage.leases) do
		leases[#leases + 1] = {
			ID = lease.ID,
		}
	end

	return {
		header = storage:header(),
		leases = leases,
	}
end

-- Watch service handlers
local WatchHandlers = {}

function WatchHandlers.Watch(self, stream)
	local storage = self.storage
	local watchers = {}

	-- Track this stream
	storage.active_streams[#storage.active_streams + 1] = stream

	-- Read watch requests from client
	while true do
		local req = stream:read()
		if not req then
			-- Stream closed, cleanup watchers
			for _, w in pairs(watchers) do
				storage.watchers[w.id] = nil
			end
			break
		end

		if req.create_request then
			-- Create new watcher
			local create = req.create_request
			local id = create.watch_id
			if id == 0 then
				id = storage.watcher_id_counter
				storage.watcher_id_counter = storage.watcher_id_counter + 1
			end

			-- Hook: Record watch create request for testing
			storage.watch_requests[#storage.watch_requests + 1] = {
				key = create.key,
				range_end = create.range_end,
				start_revision = create.start_revision,
				watch_id = id,
			}

			local watcher = {
				id = id,
				key = create.key,
				range_end = create.range_end,
				start_revision = create.start_revision or (storage.revision + 1),
				stream = stream,
			}

			watchers[id] = watcher
			storage.watchers[id] = watcher

			-- Send created response
			stream:write({
				header = storage:header(),
				watch_id = id,
				created = true,
			})

		elseif req.cancel_request then
			-- Cancel watcher
			local id = req.cancel_request.watch_id
			local watcher = watchers[id]

			if watcher then
				watchers[id] = nil
				storage.watchers[id] = nil

				-- Send canceled response
				stream:write({
					header = storage:header(),
					watch_id = id,
					canceled = true,
				})
			end
		end
	end
end

-- Main server class
---@class FakeEtcdServer
---@field port integer
---@field storage FakeEtcdStorage
---@field listener any
---@field kv_handler function|nil
---@field lease_handler function|nil
---@field watch_handler function|nil
local M = {}

---Create a new fake etcd server
---@param port integer
---@return FakeEtcdServer
function M.new(port)
	local server = {
		port = port or 12379,
		storage = Storage:new(),
		listener = nil,
		kv_handler = nil,
		lease_handler = nil,
		watch_handler = nil,
	}
	setmetatable(server, {__index = M})
	return server
end

---Notify all watchers of an event
function M:notify_watchers(event)
	for _, watcher in pairs(self.storage.watchers) do
		if in_range(event.kv.key, watcher.key, watcher.range_end) then
			local stream = watcher.stream
			if stream then
				stream:write({
					header = self.storage:header(),
					watch_id = watcher.id,
					events = {event},
				})
			end
		end
	end
end

---Set custom KV handler for testing edge cases
---@param handler function
function M:set_kv_handler(handler)
	self.kv_handler = handler
end

---Set custom Lease handler for testing edge cases
---@param handler function
function M:set_lease_handler(handler)
	self.lease_handler = handler
end

---Set custom Watch handler for testing edge cases
---@param handler function
function M:set_watch_handler(handler)
	self.watch_handler = handler
end

---Start the fake etcd server
function M:start()
	local proto = v3proto.loaded["etcdv3.proto"]
	local reg = registrar.new()

	-- Wrap handlers to allow custom override
	local function wrap_kv(method_name, default_handler)
		return function(req)
			if self.kv_handler then
				local result = self.kv_handler(method_name, req, self)
				if result then
					return result
				end
			end
			return default_handler(self, req)
		end
	end

	local function wrap_lease(method_name, default_handler)
		return function(req_or_stream)
			if self.lease_handler then
				local result = self.lease_handler(method_name, req_or_stream, self)
				if result then
					return result
				end
			end
			return default_handler(self, req_or_stream)
		end
	end

	local function wrap_watch(method_name, default_handler)
		return function(stream)
			if self.watch_handler then
				local result = self.watch_handler(method_name, stream, self)
				if result then
					return result
				end
			end
			return default_handler(self, stream)
		end
	end

	-- Register KV service
	reg:register(proto, "KV", {
		Range = wrap_kv("Range", KVHandlers.Range),
		Put = wrap_kv("Put", KVHandlers.Put),
		DeleteRange = wrap_kv("DeleteRange", KVHandlers.DeleteRange),
		Compact = wrap_kv("Compact", KVHandlers.Compact),
	})

	-- Register Lease service
	reg:register(proto, "Lease", {
		LeaseGrant = wrap_lease("LeaseGrant", LeaseHandlers.LeaseGrant),
		LeaseRevoke = wrap_lease("LeaseRevoke", LeaseHandlers.LeaseRevoke),
		LeaseKeepAlive = wrap_lease("LeaseKeepAlive", LeaseHandlers.LeaseKeepAlive),
		LeaseTimeToLive = wrap_lease("LeaseTimeToLive", LeaseHandlers.LeaseTimeToLive),
		LeaseLeases = wrap_lease("LeaseLeases", LeaseHandlers.LeaseLeases),
	})

	-- Register Watch service
	reg:register(proto, "Watch", {
		Watch = wrap_watch("Watch", WatchHandlers.Watch),
	})

	-- Start gRPC server
	local listener, err = grpc.listen({
		addr = "127.0.0.1:" .. self.port,
		registrar = reg,
	})

	if not listener then
		return nil, err
	end

	self.listener = listener
	return true
end

---Stop the fake etcd server
function M:stop()
	if self.listener then
		self.listener:close()
		self.listener = nil
	end
end

---Get current storage state (for testing/debugging)
function M:get_storage()
	return self.storage
end

---Get watch requests history (for testing)
function M:get_watch_requests()
	return self.storage.watch_requests
end

---Clear watch requests history
function M:clear_watch_requests()
	self.storage.watch_requests = {}
end

---Get keepalive requests history (for testing)
function M:get_keepalive_requests()
	return self.storage.keepalive_requests
end

---Clear keepalive requests history
function M:clear_keepalive_requests()
	self.storage.keepalive_requests = {}
end

---Close all active streams to simulate network interruption
function M:close_all_streams()
	local streams = self.storage.active_streams
	for i = 1, #streams do
		local stream = streams[i]
		if stream then
			stream:close()
		end
	end
	-- Clear the active streams list
	self.storage.active_streams = {}
end

---Reset storage to initial state (for testing between test cases)
function M:reset()
	-- Close all streams first
	self:close_all_streams()

	self.storage.storage = {}
	self.storage.revision = 0
	self.storage.leases = {}
	self.storage.lease_id_counter = 1
	self.storage.watchers = {}
	self.storage.watcher_id_counter = 1
	self.storage.watch_requests = {}
	self.storage.keepalive_requests = {}
	self.storage.active_streams = {}
end

return M
