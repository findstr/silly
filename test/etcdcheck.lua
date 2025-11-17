local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local waitgroup = require "silly.sync.waitgroup"
local etcd = require "silly.store.etcd"
local testaux = require "test.testaux"

-- Etcd endpoint (can be configured via environment)
local ETCD_ENDPOINT = os.getenv("ETCD_ENDPOINT") or "127.0.0.1:2379"

print("=== Etcd Check Test Suite ===")
print("Connecting to etcd at: " .. ETCD_ENDPOINT)
print("Note: This test requires a running etcd server")
print("Start etcd with: etcd --listen-client-urls=http://127.0.0.1:2379 --advertise-client-urls=http://127.0.0.1:2379")
print("")

-- Test 1: Basic connection and CRUD operations
testaux.case("Test 1: Basic CRUD operations", function()
	print("-----Test 1: Basic CRUD operations-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
		retry = 3,
		retry_sleep = 100,
	}
	testaux.assertneq(c, nil, "Test 1.1: Connect to etcd")

	-- Test 1.2: Put a key
	local res, err = c:put {
		key = "/test/key1",
		value = "value1",
	}
	testaux.assertneq(res, nil, "Test 1.2: Put key1")
	testaux.assertneq(res.header, nil, "Test 1.3: Put response has header")

	-- Test 1.4: Get the key
	res, err = c:get {
		key = "/test/key1",
	}
	testaux.assertneq(res, nil, "Test 1.4: Get key1")
	testaux.assertneq(res.kvs, nil, "Test 1.5: Get response has kvs")
	testaux.asserteq(#res.kvs, 1, "Test 1.6: Get returns one key")
	testaux.asserteq(res.kvs[1].key, "/test/key1", "Test 1.7: Key matches")
	testaux.asserteq(res.kvs[1].value, "value1", "Test 1.8: Value matches")

	-- Test 1.9: Update with prev_kv
	res, err = c:put {
		key = "/test/key1",
		value = "value2",
		prev_kv = true,
	}
	testaux.assertneq(res, nil, "Test 1.9: Update key1")
	testaux.assertneq(res.prev_kv, nil, "Test 1.10: Update returns prev_kv")
	testaux.asserteq(res.prev_kv.value, "value1", "Test 1.11: Previous value matches")

	-- Test 1.12: Delete the key
	res, err = c:delete {
		key = "/test/key1",
		prev_kv = true,
	}
	testaux.assertneq(res, nil, "Test 1.12: Delete key1")
	testaux.asserteq(res.deleted, 1, "Test 1.13: One key deleted")
	testaux.assertneq(res.prev_kvs, nil, "Test 1.14: Delete returns prev_kvs")
	testaux.asserteq(res.prev_kvs[1].value, "value2", "Test 1.15: Deleted value matches")

	-- Test 1.16: Get non-existent key
	res, err = c:get {
		key = "/test/key1",
	}
	testaux.assertneq(res, nil, "Test 1.16: Get deleted key returns empty")
	testaux.asserteq(res.count, 0, "Test 1.17: Get returns zero count")

	c:close()
	testaux.success("Test 1: Basic CRUD operations passed")
end)

-- Test 2: Prefix operations
testaux.case("Test 2: Prefix operations", function()
	print("-----Test 2: Prefix operations-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 2.1: Connect to etcd")

	-- Test 2.2: Put multiple keys with same prefix
	c:put { key = "/test/prefix/a", value = "value_a" }
	c:put { key = "/test/prefix/b", value = "value_b" }
	c:put { key = "/test/prefix/c", value = "value_c" }
	c:put { key = "/test/other", value = "value_other" }

	-- Test 2.3: Get with prefix
	local res, err = c:get {
		key = "/test/prefix/",
		prefix = true,
	}
	testaux.assertneq(res, nil, "Test 2.3: Get with prefix")
	testaux.asserteq(res.count, 3, "Test 2.4: Returns 3 keys")

	-- Test 2.5: Get with prefix and limit
	res, err = c:get {
		key = "/test/prefix/",
		prefix = true,
		limit = 2,
	}
	testaux.assertneq(res, nil, "Test 2.5: Get with prefix and limit")
	testaux.asserteq(#res.kvs, 2, "Test 2.6: Returns 2 keys")
	testaux.asserteq(res.more, true, "Test 2.7: Indicates more keys available")

	-- Test 2.8: Delete with prefix
	res, err = c:delete {
		key = "/test/prefix/",
		prefix = true,
	}
	testaux.assertneq(res, nil, "Test 2.8: Delete with prefix")
	testaux.asserteq(res.deleted, 3, "Test 2.9: Deleted 3 keys")

	-- Cleanup
	c:delete { key = "/test/other" }
	c:close()
	testaux.success("Test 2: Prefix operations passed")
end)

-- Test 3: Lease operations
testaux.case("Test 3: Lease operations", function()
	print("-----Test 3: Lease operations-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 3.1: Connect to etcd")

	-- Test 3.2: Grant a lease
	local res, err = c:grant {
		TTL = 10,  -- 10 seconds
	}
	testaux.assertneq(res, nil, "Test 3.2: Grant lease")
	testaux.assertneq(res.ID, nil, "Test 3.3: Lease has ID")
	testaux.asserteq(res.TTL, 10, "Test 3.4: Lease TTL is 10")

	local lease_id = res.ID

	-- Test 3.5: Put with lease
	res, err = c:put {
		key = "/test/lease_key",
		value = "lease_value",
		lease = lease_id,
	}
	testaux.assertneq(res, nil, "Test 3.5: Put key with lease")

	-- Test 3.6: TTL query
	res, err = c:ttl {
		ID = lease_id,
		keys = true,
	}
	testaux.assertneq(res, nil, "Test 3.6: Query lease TTL")
	testaux.asserteq(res.ID, lease_id, "Test 3.7: TTL response ID matches")
	testaux.assertneq(res.keys, nil, "Test 3.8: TTL returns attached keys")
	testaux.asserteq(#res.keys, 1, "Test 3.9: One key attached")
	testaux.asserteq(res.keys[1], "/test/lease_key", "Test 3.10: Attached key matches")

	-- Test 3.11: Keepalive
	c:keepalive(lease_id)
	time.sleep(1000)  -- Wait 1 second for keepalive to work

	res, err = c:ttl {
		ID = lease_id,
	}
	testaux.assertneq(res, nil, "Test 3.11: TTL after keepalive")
	testaux.assertgt(res.TTL, 0, "Test 3.12: TTL is still positive after keepalive")

	-- Test 3.13: Revoke lease
	res, err = c:revoke {
		ID = lease_id,
	}
	testaux.assertneq(res, nil, "Test 3.13: Revoke lease")

	-- Test 3.14: Key should be deleted after revoke
	res, err = c:get {
		key = "/test/lease_key",
	}
	testaux.assertneq(res, nil, "Test 3.14: Get key after lease revoked")
	testaux.asserteq(res.count, 0, "Test 3.15: Key deleted with lease")

	c:close()
	testaux.success("Test 3: Lease operations passed")
end)

-- Test 4: Watch operations
testaux.case("Test 4: Watch operations", function()
	print("-----Test 4: Watch operations-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 4.1: Connect to etcd")

	-- Cleanup first
	c:delete { key = "/test/watch/", prefix = true }

	-- Test 4.2: Watch a key
	local watcher, err = c:watch {
		key = "/test/watch/key1",
	}
	testaux.assertneq(watcher, nil, "Test 4.2: Create watcher")

	-- Test 4.3: Put a key in another coroutine
	task.fork(function()
		time.sleep(100)  -- Small delay
		c:put {
			key = "/test/watch/key1",
			value = "watched_value",
		}
	end)

	-- Test 4.4: Receive watch event
	local watch_res, watch_err = watcher:read()
	testaux.assertneq(watch_res, nil, "Test 4.4: Receive watch event")
	testaux.assertneq(watch_res.events, nil, "Test 4.5: Watch response has events")
	testaux.asserteq(#watch_res.events, 1, "Test 4.6: One event received")
	testaux.asserteq(watch_res.events[1].kv.key, "/test/watch/key1", "Test 4.7: Event key matches")
	testaux.asserteq(watch_res.events[1].kv.value, "watched_value", "Test 4.8: Event value matches")

	watcher:cancel()

	-- Test 4.9: Watch with prefix
	local watcher2, err = c:watch {
		key = "/test/watch/",
		prefix = true,
	}
	testaux.assertneq(watcher2, nil, "Test 4.9: Create prefix watcher")

	-- Test 4.10: Put multiple keys
	task.fork(function()
		time.sleep(100)
		c:put { key = "/test/watch/a", value = "a" }
		time.sleep(50)
		c:put { key = "/test/watch/b", value = "b" }
	end)

	-- Test 4.11: Receive first event
	watch_res, watch_err = watcher2:read()
	testaux.assertneq(watch_res, nil, "Test 4.11: Receive first prefix event")
	testaux.asserteq(#watch_res.events, 1, "Test 4.12: One event in first response")

	-- Test 4.13: Receive second event
	watch_res, watch_err = watcher2:read()
	testaux.assertneq(watch_res, nil, "Test 4.13: Receive second prefix event")
	testaux.asserteq(#watch_res.events, 1, "Test 4.14: One event in second response")
	watcher2:cancel()

	-- Cleanup
	c:delete { key = "/test/watch/", prefix = true }
	print("watcher2:cancel3")
	c:close()
	print("watcher2:cancel4")
	testaux.success("Test 4: Watch operations passed")
end)

-- Test 5: Concurrent operations
testaux.case("Test 5: Concurrent operations", function()
	print("-----Test 5: Concurrent operations (100 concurrent puts)-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 5.1: Connect to etcd")

	-- Cleanup first
	c:delete { key = "/test/concurrent/", prefix = true }

	local wg = waitgroup.new()
	local success_count = 0
	local concurrent_count = 100

	-- Test 5.2: Concurrent puts
	for i = 1, concurrent_count do
		wg:fork(function()
			local key = string.format("/test/concurrent/key_%d", i)
			local value = string.format("value_%d", i)
			local res, err = c:put {
				key = key,
				value = value,
			}
			if res then
				success_count = success_count + 1
			end
		end)
	end

	wg:wait()
	testaux.asserteq(success_count, concurrent_count, "Test 5.2: All concurrent puts succeeded")

	-- Test 5.3: Verify all keys exist
	local res, err = c:get {
		key = "/test/concurrent/",
		prefix = true,
	}
	testaux.assertneq(res, nil, "Test 5.3: Get all concurrent keys")
	testaux.asserteq(res.count, concurrent_count, "Test 5.4: All keys retrieved")

	-- Cleanup
	c:delete { key = "/test/concurrent/", prefix = true }
	c:close()
	testaux.success("Test 5: Concurrent operations passed")
end)

-- Test 6: Multiple leases with keepalive
testaux.case("Test 6: Multiple leases with keepalive", function()
	print("-----Test 6: Multiple leases with keepalive-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 6.1: Connect to etcd")

	-- Test 6.2: Grant multiple leases
	local lease1 = c:grant { TTL = 10 }
	local lease2 = c:grant { TTL = 10 }
	local lease3 = c:grant { TTL = 10 }

	testaux.assertneq(lease1, nil, "Test 6.2: Grant lease1")
	testaux.assertneq(lease2, nil, "Test 6.3: Grant lease2")
	testaux.assertneq(lease3, nil, "Test 6.4: Grant lease3")

	-- Test 6.5: Start keepalive for all leases
	c:keepalive(lease1.ID)
	c:keepalive(lease2.ID)
	c:keepalive(lease3.ID)

	-- Test 6.6: Wait and check TTL
	time.sleep(2000)  -- Wait 2 seconds

	local ttl1 = c:ttl { ID = lease1.ID }
	local ttl2 = c:ttl { ID = lease2.ID }
	local ttl3 = c:ttl { ID = lease3.ID }

	testaux.assertneq(ttl1, nil, "Test 6.6: TTL1 query succeeded")
	testaux.assertneq(ttl2, nil, "Test 6.7: TTL2 query succeeded")
	testaux.assertneq(ttl3, nil, "Test 6.8: TTL3 query succeeded")
	testaux.assertgt(ttl1.TTL, 0, "Test 6.9: Lease1 still alive")
	testaux.assertgt(ttl2.TTL, 0, "Test 6.10: Lease2 still alive")
	testaux.assertgt(ttl3.TTL, 0, "Test 6.11: Lease3 still alive")

	-- Cleanup
	c:revoke { ID = lease1.ID }
	c:revoke { ID = lease2.ID }
	c:revoke { ID = lease3.ID }
	c:close()
	testaux.success("Test 6: Multiple leases with keepalive passed")
end)

-- Test 7: Watch with delete events
testaux.case("Test 7: Watch with delete events", function()
	print("-----Test 7: Watch with delete events-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 7.1: Connect to etcd")

	-- Put initial key
	c:put { key = "/test/watch_delete", value = "initial" }

	-- Test 7.2: Create watcher
	local watcher, err = c:watch {
		key = "/test/watch_delete",
	}
	testaux.assertneq(watcher, nil, "Test 7.2: Create watcher")

	-- Test 7.3: Update key
	task.fork(function()
		time.sleep(100)
		c:put { key = "/test/watch_delete", value = "updated" }
		time.sleep(100)
		c:delete { key = "/test/watch_delete" }
	end)

	-- Test 7.4: Receive put event
	local res1 = watcher:read()
	testaux.assertneq(res1, nil, "Test 7.4: Receive put event")
	testaux.asserteq(res1.events[1].type, "PUT", "Test 7.5: Event type is PUT")
	testaux.asserteq(res1.events[1].kv.value, "updated", "Test 7.6: Updated value matches")

	-- Test 7.7: Receive delete event
	local res2 = watcher:read()
	testaux.assertneq(res2, nil, "Test 7.7: Receive delete event")
	testaux.asserteq(res2.events[1].type, "DELETE", "Test 7.8: Event type is DELETE")

	watcher:cancel()
	c:close()
	testaux.success("Test 7: Watch with delete events passed")
end)

-- Test 8: Compact operation
testaux.case("Test 8: Compact operation", function()
	print("-----Test 8: Compact operation-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 8.1: Connect to etcd")

	-- Test 8.2: Put some keys to create history
	local res1 = c:put { key = "/test/compact", value = "v1" }
	local revision1 = res1.header.revision

	c:put { key = "/test/compact", value = "v2" }
	local res3 = c:put { key = "/test/compact", value = "v3" }
	local revision3 = res3.header.revision

	testaux.assertneq(revision1, nil, "Test 8.2: Got revision1")
	testaux.assertneq(revision3, nil, "Test 8.3: Got revision3")

	-- Test 8.4: Compact to revision1
	local compact_res, compact_err = c:compact {
		revision = revision1,
	}
	testaux.assertneq(compact_res, nil, "Test 8.4: Compact succeeded")

	-- Test 8.5: Current value should still be accessible
	local res = c:get { key = "/test/compact" }
	testaux.assertneq(res, nil, "Test 8.5: Get after compact")
	testaux.asserteq(res.kvs[1].value, "v3", "Test 8.6: Current value is v3")

	-- Cleanup
	c:delete { key = "/test/compact" }
	c:close()
	testaux.success("Test 8: Compact operation passed")
end)

-- Test 9: Sorting operations
testaux.case("Test 9: Sorting operations", function()
	print("-----Test 9: Sorting operations-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 9.1: Connect to etcd")

	-- Cleanup and create test data
	c:delete { key = "/test/sort/", prefix = true }

	c:put { key = "/test/sort/c", value = "3" }
	c:put { key = "/test/sort/a", value = "1" }
	c:put { key = "/test/sort/b", value = "2" }

	-- Test 9.2: Sort by key ascending (default)
	local res = c:get {
		key = "/test/sort/",
		prefix = true,
		sort_target = "KEY",
		sort_order = "ASCEND",
	}
	testaux.assertneq(res, nil, "Test 9.2: Get with sort")
	testaux.asserteq(res.kvs[1].key, "/test/sort/a", "Test 9.3: First key is 'a'")
	testaux.asserteq(res.kvs[2].key, "/test/sort/b", "Test 9.4: Second key is 'b'")
	testaux.asserteq(res.kvs[3].key, "/test/sort/c", "Test 9.5: Third key is 'c'")

	-- Test 9.6: Sort by key descending
	res = c:get {
		key = "/test/sort/",
		prefix = true,
		sort_target = "KEY",
		sort_order = "DESCEND",
	}
	testaux.assertneq(res, nil, "Test 9.6: Get with descending sort")
	testaux.asserteq(res.kvs[1].key, "/test/sort/c", "Test 9.7: First key is 'c'")
	testaux.asserteq(res.kvs[3].key, "/test/sort/a", "Test 9.8: Last key is 'a'")

	-- Cleanup
	c:delete { key = "/test/sort/", prefix = true }
	c:close()
	testaux.success("Test 9: Sorting operations passed")
end)

-- Test 10: Client close and cleanup
testaux.case("Test 10: Client close and cleanup", function()
	print("-----Test 10: Client close and cleanup-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 10.1: Connect to etcd")

	-- Create some watchers
	local w1 = c:watch { key = "/test/close/1" }
	local w2 = c:watch { key = "/test/close/2" }

	testaux.assertneq(w1, nil, "Test 10.2: Watcher1 created")
	testaux.assertneq(w2, nil, "Test 10.3: Watcher2 created")

	-- Create some leases
	local l1 = c:grant { TTL = 60 }
	testaux.assertneq(l1, nil, "Test 10.4: Lease created")
	c:keepalive(l1.ID)

	-- Test 10.5: Close client
	c:close()

	-- Test 10.6: Watcher read should fail after close
	local res, err = w1:read()
	testaux.asserteq(res, nil, "Test 10.6: Watcher read fails after close")
	testaux.assertneq(err, nil, "Test 10.7: Watcher returns error")

	testaux.success("Test 10: Client close and cleanup passed")
end)

-- Test 11: Keepalive edge cases
testaux.case("Test 11: Keepalive edge cases", function()
	print("-----Test 11: Keepalive edge cases-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 11.1: Connect to etcd")

	-- Test 11.2: Keepalive on valid lease
	local res = c:grant { TTL = 5 }
	local lease_id = res.ID
	c:keepalive(lease_id)
	time.sleep(500)

	res = c:ttl { ID = lease_id }
	testaux.assertneq(res, nil, "Test 11.2: Keepalive on valid lease")
	testaux.assertgt(res.TTL, 0, "Test 11.3: Lease is still alive after keepalive")

	-- Test 11.4: Keepalive on same lease twice (idempotent)
	c:keepalive(lease_id)
	c:keepalive(lease_id)
	res = c:ttl { ID = lease_id }
	testaux.assertgt(res.TTL, 0, "Test 11.4: Double keepalive is idempotent")

	-- Test 11.5: Keepalive on multiple leases
	local lease2 = c:grant { TTL = 5 }
	local lease3 = c:grant { TTL = 5 }
	c:keepalive(lease2.ID)
	c:keepalive(lease3.ID)
	time.sleep(500)

	res = c:ttl { ID = lease2.ID }
	testaux.assertgt(res.TTL, 0, "Test 11.5: Multiple keepalives work")

	-- Cleanup
	c:revoke { ID = lease_id }
	c:revoke { ID = lease2.ID }
	c:revoke { ID = lease3.ID }
	c:close()

	testaux.success("Test 11: Keepalive edge cases passed")
end)

-- Test 12: Watch cancel edge cases
testaux.case("Test 12: Watch cancel edge cases", function()
	print("-----Test 12: Watch cancel edge cases-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 12.1: Connect to etcd")

	-- Cleanup first
	c:delete { key = "/test/cancel/", prefix = true }

	-- Test 12.2: Cancel watcher, then verify read fails
	local w = c:watch { key = "/test/cancel/key1" }
	w:cancel()

	-- After cancel, read should eventually return error
	local res, err
	for i = 1, 10 do
		res, err = w:read()
		if err then
			break
		end
		time.sleep(10)
	end
	testaux.asserteq(res, nil, "Test 12.2: Read after cancel returns nil")
	testaux.assertneq(err, nil, "Test 12.3: Read after cancel returns error")

	-- Test 12.4: Double cancel (idempotent)
	local w2 = c:watch { key = "/test/cancel/key2" }
	w2:cancel()
	w2:cancel()  -- Should not error
	testaux.success("Test 12.4: Double cancel is safe")

	-- Test 12.5: Cancel during active watch
	local w3 = c:watch { key = "/test/cancel/key3" }
	task.fork(function()
		time.sleep(100)
		w3:cancel()
	end)

	res, err = w3:read()
	-- Should either get cancel response or error
	testaux.success("Test 12.5: Cancel during active watch")

	c:close()

	testaux.success("Test 12: Watch cancel edge cases passed")
end)

-- Test 13: Concurrent watchers
testaux.case("Test 13: Concurrent watchers", function()
	print("-----Test 13: Concurrent watchers-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 13.1: Connect to etcd")

	-- Cleanup
	c:delete { key = "/test/multiwatch/", prefix = true }

	local wg = waitgroup.new()

	-- Test 13.2: Create multiple watchers
	local watchers = {}
	for i = 1, 10 do
		local w = c:watch { key = "/test/multiwatch/key" }
		watchers[i] = w
	end

	-- Test 13.3: Trigger event, all watchers should receive it
	task.fork(function()
		time.sleep(100)
		c:put { key = "/test/multiwatch/key", value = "broadcast" }
	end)

	local received_count = 0
	for i = 1, 10 do
		wg:fork(function()
			local res = watchers[i]:read()
			if res and #res.events == 1 then
				received_count = received_count + 1
			end
		end)
	end
	wg:wait()

	testaux.asserteq(received_count, 10, "Test 13.3: All watchers received event")

	-- Test 13.4: Cancel all watchers
	for i = 1, 10 do
		watchers[i]:cancel()
	end

	-- Cleanup
	c:delete { key = "/test/multiwatch/", prefix = true }
	c:close()

	testaux.success("Test 13: Concurrent watchers passed")
end)

-- Test 14: Range operations edge cases
testaux.case("Test 14: Range operations", function()
	print("-----Test 14: Range operations-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 14.1: Connect to etcd")

	-- Cleanup and setup test data
	c:delete { key = "/test/range/", prefix = true }
	c:put { key = "/test/range/a", value = "1" }
	c:put { key = "/test/range/b", value = "2" }
	c:put { key = "/test/range/c", value = "3" }
	c:put { key = "/test/range/d", value = "4" }
	c:put { key = "/test/range/e", value = "5" }

	-- Test 14.2: Limit parameter
	local res = c:get { key = "/test/range/", prefix = true, limit = 2 }
	testaux.assertneq(res, nil, "Test 14.2: Get with limit")
	testaux.asserteq(#res.kvs, 2, "Test 14.3: Limit returns exactly 2 keys")
	testaux.asserteq(res.more, true, "Test 14.4: More flag is true")

	-- Test 14.5: Count only
	res = c:get { key = "/test/range/", prefix = true, count_only = true }
	testaux.asserteq(res.count, 5, "Test 14.5: Count only returns correct count")
	testaux.asserteq(#res.kvs, 0, "Test 14.6: Count only returns empty kvs")

	-- Test 14.7: Keys only
	res = c:get { key = "/test/range/", prefix = true, keys_only = true }
	testaux.asserteq(#res.kvs, 5, "Test 14.7: Keys only returns all keys")
	for i, kv in ipairs(res.kvs) do
		testaux.assertneq(kv.key, nil, "Test 14.8: Key exists in keys_only mode")
	end

	-- Test 14.9: Sorting by key ascending
	res = c:get {
		key = "/test/range/",
		prefix = true,
		sort_target = "KEY",
		sort_order = "ASCEND",
	}
	testaux.assertneq(res, nil, "Test 14.9: Get with sorting")
	testaux.asserteq(res.kvs[1].key, "/test/range/a", "Test 14.10: First key is 'a' in ascending order")

	-- Test 14.11: Sorting by key descending
	res = c:get {
		key = "/test/range/",
		prefix = true,
		sort_target = "KEY",
		sort_order = "DESCEND",
	}
	testaux.asserteq(res.kvs[1].key, "/test/range/e", "Test 14.11: First key is 'e' in descending order")

	-- Cleanup
	c:delete { key = "/test/range/", prefix = true }
	c:close()

	testaux.success("Test 14: Range operations passed")
end)

-- Test 15: Revision tracking
testaux.case("Test 15: Revision tracking", function()
	print("-----Test 15: Revision tracking-----")

	local c, err = etcd.newclient {
		endpoints = {ETCD_ENDPOINT},
	}
	testaux.assertneq(c, nil, "Test 15.1: Connect to etcd")

	-- Cleanup
	c:delete { key = "/test/revision/", prefix = true }

	-- Test 15.2: Initial revision
	local res = c:put { key = "/test/revision/key", value = "v1" }
	local rev1 = res.header.revision

	-- Test 15.3: Revision increases with each operation
	res = c:put { key = "/test/revision/key", value = "v2" }
	local rev2 = res.header.revision
	testaux.assertgt(rev2, rev1, "Test 15.3: Revision increases after put")

	-- Test 15.4: Delete also increases revision
	res = c:delete { key = "/test/revision/key" }
	local rev3 = res.header.revision
	testaux.assertgt(rev3, rev2, "Test 15.4: Revision increases after delete")

	-- Test 15.5: Get doesn't increase revision
	res = c:get { key = "/test/revision/other" }
	local rev4 = res.header.revision
	testaux.asserteq(rev4, rev3, "Test 15.5: Get doesn't increase revision")

	-- Test 15.6: Multiple puts increase revision
	for i = 1, 5 do
		c:put { key = "/test/revision/multi", value = tostring(i) }
	end
	res = c:get { key = "/test/revision/multi" }
	testaux.assertgt(res.header.revision, rev4, "Test 15.6: Multiple puts increase revision")

	-- Cleanup
	c:delete { key = "/test/revision/", prefix = true }
	c:close()

	testaux.success("Test 15: Revision tracking passed")
end)

print("")
print("=== All Etcd Check Tests Completed ===")
print("Note: These tests verify basic functionality with a real etcd server")
print("For comprehensive edge case testing, run test/testetcd.lua with fakeetcd")
