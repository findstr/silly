---
title: silly.store.etcd
icon: database
category:
  - API Reference
tag:
  - Storage
  - etcd
  - Distributed Configuration
---

# silly.store.etcd

The `silly.store.etcd` module provides a client for interacting with the etcd v3 API. It is implemented based on gRPC and provides wrappers for etcd's core features (such as key-value storage, leases, and watches). etcd is a distributed, reliable key-value storage system commonly used for configuration management, service discovery, and distributed coordination.

## Module Import

```lua validate
local etcd = require "silly.store.etcd"
```

## Core Concepts

### etcd v3 API

The etcd v3 API is based on gRPC and provides the following core features:

- **Key-Value Store (KV)**: Supports CRUD operations, range queries, version control
- **Lease**: Sets time-to-live (TTL) for key-value pairs; keys are automatically deleted when lease expires
- **Watch**: Monitors key change events, supports historical version replay
- **Transaction**: Atomically executes multiple operations


### Lease Keep-Alive

The client automatically manages lease keep-alive:

- Automatically starts background keep-alive task after creating a lease
- Periodically sends keep-alive requests to extend lease TTL
- Automatically stops keep-alive when lease is revoked

### Retry Mechanism

The client has a built-in retry mechanism to improve reliability:

- Retries 5 times by default
- Configurable retry count and interval
- Automatically sleeps before retrying on failure

---

## API Reference

### etcd.newclient(conf)

Creates a new etcd client instance.

- **Parameters**:
  - `conf`: `table` - Client configuration table
    - `endpoints`: `string[]` (required) - List of etcd server addresses, e.g., `{"127.0.0.1:2379"}`
    - `retry`: `integer|nil` (optional) - Number of retries on request failure, defaults to 5
    - `retry_sleep`: `integer|nil` (optional) - Wait time between retries (milliseconds), defaults to 1000
    - `timeout`: `number|nil` (optional) - gRPC request timeout (seconds)
- **Returns**:
  - Success: `silly.store.etcd.client` - etcd client object
  - Failure: Throws an error
- **Async**: No
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
        timeout = 5,
        retry = 3,
        retry_sleep = 500,
    }

    print("etcd client created successfully")
end)
```

---

## Key-Value Storage API

### client:put(req)

Stores a key-value pair in etcd. If the key already exists, updates its value.

- **Parameters**:
  - `req`: `table` - Request parameters
    - `key`: `string` (required) - Key to store
    - `value`: `string` (required) - Value to store
    - `lease`: `integer|nil` (optional) - Associated lease ID; key is automatically deleted when lease expires
    - `prev_kv`: `boolean|nil` (optional) - If `true`, returns the key-value pair before the operation
    - `ignore_value`: `boolean|nil` (optional) - If `true`, etcd updates the key with the current value (only updates version number)
    - `ignore_lease`: `boolean|nil` (optional) - If `true`, etcd updates the key with the current lease
- **Returns**:
  - Success: `table` - Response object
    - `header`: `etcd.ResponseHeader` - Response header containing cluster information and version number
    - `prev_kv`: `mvccpb.KeyValue|nil` - If `prev_kv` was set, returns the key-value pair before the operation
  - Failure: `nil, string` - nil and error message
- **Async**: Yes (suspends coroutine until operation completes or times out)
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Store simple key-value pair
    local res, err = client:put {
        key = "config/app/name",
        value = "MyApp",
    }

    if not res then
        print("Put failed:", err)
        return
    end

    print("Put successful, revision:", res.header.revision)

    -- Store and get old value
    local res2, err = client:put {
        key = "config/app/name",
        value = "MyApp v2",
        prev_kv = true,
    }

    if res2 and res2.prev_kv then
        print("Old value:", res2.prev_kv.value)
        print("Old version:", res2.prev_kv.version)
    end
end)
```

### client:get(req)

Gets key-value pairs from etcd. Supports single key query, prefix query, range query, and other modes.

- **Parameters**:
  - `req`: `table` - Request parameters
    - `key`: `string` (required) - Key to get
    - `prefix`: `boolean|nil` (optional) - If `true`, gets all keys with this prefix
    - `fromkey`: `boolean|nil` (optional) - If `true`, gets all keys starting from this key
    - `limit`: `number|nil` (optional) - Limits the number of keys returned
    - `revision`: `number|nil` (optional) - Specifies historical revision number to query keys at that revision
    - `sort_order`: `"NONE"|"ASCEND"|"DESCEND"|nil` (optional) - Sort order
    - `sort_target`: `"KEY"|"VERSION"|"CREATE"|"MOD"|"VALUE"|nil` (optional) - Sort target field
    - `serializable`: `boolean|nil` (optional) - If `true`, uses serializable read (better performance but may read stale data)
    - `keys_only`: `boolean|nil` (optional) - If `true`, returns only keys not values
    - `count_only`: `boolean|nil` (optional) - If `true`, returns only the count of keys
    - `min_mod_revision`: `number|nil` (optional) - Filter condition: minimum modification revision
    - `max_mod_revision`: `number|nil` (optional) - Filter condition: maximum modification revision
    - `min_create_revision`: `number|nil` (optional) - Filter condition: minimum creation revision
    - `max_create_revision`: `number|nil` (optional) - Filter condition: maximum creation revision
- **Returns**:
  - Success: `table` - Response object
    - `header`: `etcd.ResponseHeader` - Response header
    - `kvs`: `mvccpb.KeyValue[]` - Array of key-value pairs
    - `more`: `boolean` - Whether there are more keys (when using `limit`)
    - `count`: `number` - Total count of keys
  - Failure: `nil, string` - nil and error message
- **Async**: Yes
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Store some data first
    client:put {key = "config/db/host", value = "localhost"}
    client:put {key = "config/db/port", value = "3306"}
    client:put {key = "config/cache/host", value = "redis"}

    -- Get single key
    local res1, err = client:get {key = "config/db/host"}
    if res1 and res1.kvs[1] then
        print("DB Host:", res1.kvs[1].value)
    end

    -- Get all keys with prefix "config/db/"
    local res2, err = client:get {
        key = "config/db/",
        prefix = true,
    }

    if res2 then
        print("Found", res2.count, "keys with prefix config/db/")
        for i, kv in ipairs(res2.kvs) do
            print(kv.key, "=", kv.value)
        end
    end

    -- Get keys but return only key names
    local res3, err = client:get {
        key = "config/",
        prefix = true,
        keys_only = true,
    }

    if res3 then
        for i, kv in ipairs(res3.kvs) do
            print("Key:", kv.key)
        end
    end

    -- Sorted query
    local res4, err = client:get {
        key = "config/",
        prefix = true,
        sort_order = "DESCEND",
        sort_target = "KEY",
    }
end)
```

### client:delete(req)

Deletes key-value pairs from etcd. Supports single key deletion and prefix deletion.

- **Parameters**:
  - `req`: `table` - Request parameters
    - `key`: `string` (required) - Key to delete
    - `prefix`: `boolean|nil` (optional) - If `true`, deletes all keys with this prefix
    - `prev_kv`: `boolean|nil` (optional) - If `true`, returns the deleted key-value pairs
- **Returns**:
  - Success: `table` - Response object
    - `header`: `etcd.ResponseHeader` - Response header
    - `deleted`: `boolean` - Whether keys were deleted
    - `prev_kvs`: `mvccpb.KeyValue[]` - If `prev_kv` was set, returns array of deleted key-value pairs
  - Failure: `nil, string` - nil and error message
- **Async**: Yes
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Store data first
    client:put {key = "temp/key1", value = "value1"}
    client:put {key = "temp/key2", value = "value2"}

    -- Delete single key and get old value
    local res1, err = client:delete {
        key = "temp/key1",
        prev_kv = true,
    }

    if res1 and res1.prev_kvs[1] then
        print("Deleted key:", res1.prev_kvs[1].key)
        print("Old value:", res1.prev_kvs[1].value)
    end

    -- Delete all keys with prefix "temp/"
    local res2, err = client:delete {
        key = "temp/",
        prefix = true,
    }

    if res2 then
        print("Deleted", res2.deleted, "keys")
    end
end)
```

### client:compact(req)

Compacts the etcd key-value storage to release space occupied by historical versions.

- **Parameters**:
  - `req`: `table` - Request parameters
    - `revision`: `integer` (required) - Revision number to compact to; historical data older than this revision will be deleted
    - `physical`: `boolean|nil` (optional) - If `true`, forces physical compaction (immediately releases space)
- **Returns**:
  - Success: `table` - Response object
    - `header`: `etcd.ResponseHeader` - Response header
  - Failure: `nil, string` - nil and error message
- **Async**: Yes
- **Note**: After compaction, historical data before the compacted revision cannot be queried
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Perform some write operations
    for i = 1, 10 do
        client:put {key = "counter", value = tostring(i)}
    end

    -- Get current revision number
    local res, err = client:get {key = "counter"}
    if res then
        local current_revision = res.header.revision
        print("Current revision:", current_revision)

        -- Compact to before current revision (keep recent history)
        local compact_res, err = client:compact {
            revision = current_revision - 5,
            physical = true,
        }

        if compact_res then
            print("Compaction successful")
        end
    end
end)
```

---

## Lease API

### client:grant(req)

Creates a lease. Leases can be associated with key-value pairs; when a lease expires, all associated keys are automatically deleted.

- **Parameters**:
  - `req`: `table` - Request parameters
    - `TTL`: `integer` (required) - Lease time-to-live (seconds)
    - `ID`: `integer|nil` (optional) - Specifies lease ID (if 0 or not specified, etcd automatically assigns one)
- **Returns**:
  - Success: `table` - Response object
    - `header`: `etcd.ResponseHeader` - Response header
    - `ID`: `integer` - Assigned lease ID
    - `TTL`: `integer` - Actual TTL (server may adjust)
    - `error`: `string|nil` - Error message (if any)
  - Failure: `nil, string` - nil and error message
- **Async**: Yes
- **Note**: After creating a lease, the client automatically starts a background keep-alive task
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Create a 60-second lease
    local lease_res, err = client:grant {
        TTL = 60,
    }

    if not lease_res then
        print("Grant lease failed:", err)
        return
    end

    local lease_id = lease_res.ID
    print("Lease granted, ID:", lease_id, "TTL:", lease_res.TTL)

    -- Associate key with lease
    local put_res, err = client:put {
        key = "temp/session",
        value = "active",
        lease = lease_id,
    }

    if put_res then
        print("Key associated with lease")
    end

    -- Lease automatically renews (client background keep-alive)
    -- After 60 seconds, if lease is not revoked, key will be automatically deleted
end)
```

### client:revoke(req)

Revokes a lease. When a lease is revoked, all associated keys are immediately deleted.

- **Parameters**:
  - `req`: `table` - Request parameters
    - `ID`: `integer` (required) - Lease ID to revoke
- **Returns**:
  - Success: `table` - Response object
    - `header`: `etcd.ResponseHeader` - Response header
  - Failure: `nil, string` - nil and error message
- **Async**: Yes
- **Note**: After revoking a lease, the client automatically stops the keep-alive task for that lease
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Create lease
    local lease_res = client:grant {TTL = 60}
    if not lease_res then
        return
    end

    local lease_id = lease_res.ID

    -- Associate key with lease
    client:put {
        key = "temp/data",
        value = "will be deleted",
        lease = lease_id,
    }

    -- Verify key exists
    local get_res = client:get {key = "temp/data"}
    print("Key exists:", get_res and get_res.kvs[1] ~= nil)

    -- Revoke lease
    local revoke_res, err = client:revoke {ID = lease_id}
    if revoke_res then
        print("Lease revoked")
    end

    -- Verify key has been deleted
    local get_res2 = client:get {key = "temp/data"}
    print("Key exists after revoke:", get_res2 and get_res2.kvs[1] ~= nil)
end)
```

### client:ttl(req)

Queries the remaining time-to-live of a lease and the list of associated keys.

- **Parameters**:
  - `req`: `table` - Request parameters
    - `ID`: `integer` (required) - Lease ID to query
    - `keys`: `boolean|nil` (optional) - If `true`, returns all keys attached to this lease
- **Returns**:
  - Success: `table` - Response object
    - `header`: `etcd.ResponseHeader` - Response header
    - `ID`: `integer` - Lease ID
    - `TTL`: `integer` - Remaining TTL (seconds), lease will expire within TTL+1 seconds
    - `grantedTTL`: `integer` - Initial TTL when created or renewed
    - `keys`: `string[]` - If `keys` was requested, returns list of associated keys
  - Failure: `nil, string` - nil and error message
- **Async**: Yes
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Create lease and associate keys
    local lease_res = client:grant {TTL = 60}
    local lease_id = lease_res.ID

    client:put {key = "session/user1", value = "data1", lease = lease_id}
    client:put {key = "session/user2", value = "data2", lease = lease_id}

    -- Query lease information (including associated keys)
    local ttl_res, err = client:ttl {
        ID = lease_id,
        keys = true,
    }

    if ttl_res then
        print("Lease ID:", ttl_res.ID)
        print("Remaining TTL:", ttl_res.TTL, "seconds")
        print("Granted TTL:", ttl_res.grantedTTL, "seconds")
        print("Associated keys:")
        for i, key in ipairs(ttl_res.keys) do
            print("  -", key)
        end
    end
end)
```

### client:leases()

Lists all active leases.

- **Parameters**: None
- **Returns**:
  - Success: `table` - Response object
    - `leases`: `table[]` - List of leases, each element contains:
      - `ID`: `integer` - Lease ID
  - Failure: `nil, string` - nil and error message
- **Async**: Yes
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Create several leases
    local lease1 = client:grant {TTL = 60}
    local lease2 = client:grant {TTL = 120}

    -- List all leases
    local res, err = client:leases()
    if res then
        print("Total leases:", #res.leases)
        for i, lease in ipairs(res.leases) do
            print("Lease", i, "ID:", lease.ID)
        end
    end
end)
```

### client:keepalive(req)

Manually sends a single lease keep-alive request (usually not needed as the client automatically keeps leases alive).

- **Parameters**:
  - `req`: `table` - Request parameters
    - `ID`: `integer` (required) - Lease ID to keep alive
- **Returns**:
  - Success: `table` - Response object
    - `header`: `etcd.ResponseHeader` - Response header
    - `ID`: `integer` - Lease ID
    - `TTL`: `integer` - New TTL after renewal
  - Failure: `nil, string` - nil and error message
- **Async**: Yes
- **Note**: This method returns a gRPC stream object; you need to call `write()` and `read()` methods
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    local lease_res = client:grant {TTL = 60}
    local lease_id = lease_res.ID

    -- Get keep-alive stream
    local stream = client:keepalive {ID = lease_id}
    if stream then
        -- Send keep-alive request
        stream:write {ID = lease_id}

        -- Read response
        local ka_res = stream:read()
        if ka_res then
            print("Keepalive success, new TTL:", ka_res.TTL)
        end

        stream:close()
    end

    -- Note: Usually not needed to manually keep alive, client handles it automatically
end)
```

---

## Watch API

### client:watch(req)

Watches for change events on keys in etcd. Receives notifications when keys are created, modified, or deleted.

- **Parameters**:
  - `req`: `table` - Request parameters
    - `key`: `string` (required) - Key to watch
    - `prefix`: `boolean|nil` (optional) - If `true`, watches all keys with this prefix
    - `revision`: `number|nil` (optional) - Start watching from specified revision (can be used to replay historical events)
    - `progress_notify`: `boolean|nil` (optional) - If `true`, periodically sends progress notifications
    - `filters`: `table|nil` (optional) - List of event filters
    - `NOPUT`: `boolean|nil` (optional) - If `true`, filters PUT events
    - `NODELETE`: `boolean|nil` (optional) - If `true`, filters DELETE events
- **Returns**:
  - Success: `silly.net.grpc.stream` - gRPC stream object for reading events
  - Failure: `nil, string` - nil and error message
- **Async**: Yes
- **Note**: Need to call `stream:read()` to read events, `stream:close()` to close watch
- **Example**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Start watch coroutine
    task.fork(function()
        local stream, err = client:watch {
            key = "config/",
            prefix = true,
        }

        if not stream then
            print("Watch failed:", err)
            return
        end

        print("Watching config/ prefix...")

        while true do
            local res, err = stream:read()
            if not res then
                print("Watch error:", err)
                break
            end

            -- Process events
            for _, event in ipairs(res.events) do
                if event.type == "PUT" then
                    print("PUT:", event.kv.key, "=", event.kv.value)
                elseif event.type == "DELETE" then
                    print("DELETE:", event.kv.key)
                end
            end
        end

        stream:close()
    end)

    -- Main coroutine makes some changes to trigger watch events
    silly.sleep(100)  -- Wait for watch to be ready

    client:put {key = "config/app", value = "v1"}
    silly.sleep(50)

    client:put {key = "config/app", value = "v2"}
    silly.sleep(50)

    client:delete {key = "config/app"}
end)
```

---

## Usage Examples

### Example 1: Configuration Management

Using etcd to store and read application configuration:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local json = require "silly.encoding.json"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Store configuration
    local config = {
        database = {
            host = "localhost",
            port = 3306,
            name = "mydb",
        },
        cache = {
            host = "localhost",
            port = 6379,
        },
    }

    client:put {
        key = "/config/app/database",
        value = json.encode(config.database),
    }

    client:put {
        key = "/config/app/cache",
        value = json.encode(config.cache),
    }

    print("Configuration stored")

    -- Read configuration
    local res = client:get {
        key = "/config/app/",
        prefix = true,
    }

    if res then
        print("Found", res.count, "configuration items:")
        for _, kv in ipairs(res.kvs) do
            local conf = json.decode(kv.value)
            print(kv.key, "=>", json.encode(conf))
        end
    end
end)
```

### Example 2: Service Discovery

Using leases to implement service registration and discovery:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local json = require "silly.encoding.json"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Service registration
    local service_info = {
        name = "api-server",
        host = "192.168.1.100",
        port = 8080,
        version = "1.0.0",
    }

    -- Create lease (service instance lifecycle)
    local lease = client:grant {TTL = 10}
    local lease_id = lease.ID

    -- Register service
    local service_key = string.format(
        "/services/%s/%s:%d",
        service_info.name,
        service_info.host,
        service_info.port
    )

    client:put {
        key = service_key,
        value = json.encode(service_info),
        lease = lease_id,
    }

    print("Service registered:", service_key)

    -- Service discovery
    local discover_res = client:get {
        key = "/services/api-server/",
        prefix = true,
    }

    if discover_res then
        print("Found", discover_res.count, "service instances:")
        for _, kv in ipairs(discover_res.kvs) do
            local info = json.decode(kv.value)
            print(string.format(
                "  - %s:%d (version %s)",
                info.host,
                info.port,
                info.version
            ))
        end
    end

    -- Service automatically deregisters when lease expires
    -- Or manually revoke lease to deregister service
    silly.sleep(5000)
    client:revoke {ID = lease_id}
    print("Service unregistered")
end)
```

### Example 3: Watching Configuration Changes

Real-time monitoring of configuration changes and updating application state:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local json = require "silly.encoding.json"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Current configuration
    local current_config = {}

    -- Start watch coroutine
    task.fork(function()
        local stream = client:watch {
            key = "/config/app/",
            prefix = true,
        }

        if not stream then
            return
        end

        print("Watching configuration changes...")

        while true do
            local res = stream:read()
            if not res then
                break
            end

            for _, event in ipairs(res.events) do
                local key = event.kv.key

                if event.type == "PUT" then
                    local value = json.decode(event.kv.value)
                    current_config[key] = value
                    print("Config updated:", key)
                    print("New value:", json.encode(value))

                    -- Trigger config reload logic
                    -- reload_config(key, value)

                elseif event.type == "DELETE" then
                    current_config[key] = nil
                    print("Config deleted:", key)

                    -- Trigger config cleanup logic
                    -- clear_config(key)
                end
            end
        end

        stream:close()
    end)

    -- Main thread: Initialize configuration
    silly.sleep(100)

    local init_res = client:get {
        key = "/config/app/",
        prefix = true,
    }

    if init_res then
        for _, kv in ipairs(init_res.kvs) do
            current_config[kv.key] = json.decode(kv.value)
        end
        print("Initial config loaded:", #init_res.kvs, "items")
    end

    -- Simulate configuration changes
    silly.sleep(1000)
    client:put {
        key = "/config/app/timeout",
        value = json.encode({value = 30, unit = "seconds"}),
    }

    silly.sleep(1000)
    client:put {
        key = "/config/app/timeout",
        value = json.encode({value = 60, unit = "seconds"}),
    }

    silly.sleep(1000)
    client:delete {key = "/config/app/timeout"}
end)
```

### Example 4: Key-Value Version Control

Using etcd's MVCC features to implement version control:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    local key = "document/readme"

    -- Update the same key multiple times
    print("Creating document versions...")

    for i = 1, 5 do
        local content = string.format("Version %d content", i)
        local res = client:put {
            key = key,
            value = content,
        }

        if res then
            print(string.format(
                "Version %d saved, revision: %d",
                i,
                res.header.revision
            ))
        end

        silly.sleep(100)
    end

    -- Get current version
    local current = client:get {key = key}
    if current and current.kvs[1] then
        local kv = current.kvs[1]
        print("\nCurrent version:")
        print("  Value:", kv.value)
        print("  Version:", kv.version)
        print("  Mod Revision:", kv.mod_revision)
        print("  Create Revision:", kv.create_revision)
    end

    -- Get historical version (need to know specific revision)
    -- Note: Need to query historical versions before compaction
    local history = client:get {
        key = key,
        revision = current.header.revision - 2,
    }

    if history and history.kvs[1] then
        print("\nHistorical version (2 revisions ago):")
        print("  Value:", history.kvs[1].value)
    end
end)
```

### Example 5: Transactional Operations

Using etcd for atomic multi-key operations (note: requires underlying gRPC client):

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Set initial values first
    client:put {key = "counter/a", value = "10"}
    client:put {key = "counter/b", value = "20"}

    print("Initial values set")

    -- Read current values
    local res_a = client:get {key = "counter/a"}
    local res_b = client:get {key = "counter/b"}

    if res_a and res_b and res_a.kvs[1] and res_b.kvs[1] then
        local val_a = tonumber(res_a.kvs[1].value)
        local val_b = tonumber(res_b.kvs[1].value)

        print("Counter A:", val_a)
        print("Counter B:", val_b)
        print("Sum:", val_a + val_b)

        -- Update counters
        client:put {key = "counter/a", value = tostring(val_a + 1)}
        client:put {key = "counter/b", value = tostring(val_b + 1)}

        print("\nCounters incremented")

        -- Read new values
        res_a = client:get {key = "counter/a"}
        res_b = client:get {key = "counter/b"}

        if res_a and res_b and res_a.kvs[1] and res_b.kvs[1] then
            print("Counter A:", res_a.kvs[1].value)
            print("Counter B:", res_b.kvs[1].value)
        end
    end
end)
```

### Example 6: Health Check and Heartbeat

Using leases to implement service health checks:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Create lease (heartbeat interval)
    local lease = client:grant {TTL = 5}
    local lease_id = lease.ID

    -- Register heartbeat key
    local heartbeat_key = "/health/service-1"
    client:put {
        key = heartbeat_key,
        value = tostring(os.time()),
        lease = lease_id,
    }

    print("Heartbeat registered with", lease_id)

    -- Monitoring coroutine
    task.fork(function()
        local stream = client:watch {
            key = heartbeat_key,
        }

        if not stream then
            return
        end

        print("Monitoring heartbeat...")

        while true do
            local res = stream:read()
            if not res then
                break
            end

            for _, event in ipairs(res.events) do
                if event.type == "PUT" then
                    print("Heartbeat updated:", event.kv.value)
                elseif event.type == "DELETE" then
                    print("WARNING: Service heartbeat lost!")
                    -- Trigger alert
                end
            end
        end

        stream:close()
    end)

    -- Keep service running (lease automatically renews)
    silly.sleep(15000)

    -- Revoke lease (simulate service stop)
    print("Stopping service...")
    client:revoke {ID = lease_id}

    silly.sleep(1000)
    print("Service stopped")
end)
```

### Example 7: Graceful Shutdown and Resource Cleanup

Properly handling etcd client lifecycle:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Create lease and resources
    local lease = client:grant {TTL = 60}
    local lease_id = lease.ID

    local resources = {
        "/temp/resource1",
        "/temp/resource2",
        "/temp/resource3",
    }

    -- Register resources
    for _, key in ipairs(resources) do
        client:put {
            key = key,
            value = "active",
            lease = lease_id,
        }
        print("Registered:", key)
    end

    -- Simulate work
    print("Working...")
    silly.sleep(3000)

    -- Graceful shutdown: Clean up resources
    print("Shutting down...")

    -- Method 1: Revoke lease (automatically deletes all associated keys)
    local revoke_res = client:revoke {ID = lease_id}
    if revoke_res then
        print("Lease revoked, all resources cleaned up")
    end

    -- Method 2: Manually delete resources (if not using lease)
    -- for _, key in ipairs(resources) do
    --     client:delete {key = key}
    -- end

    -- Verify cleanup result
    silly.sleep(100)

    local check_res = client:get {
        key = "/temp/",
        prefix = true,
    }

    if check_res then
        print("Remaining resources:", check_res.count)
    end

    print("Shutdown complete")
end)
```

---

## Notes

### 1. Coroutine Requirement

All etcd client methods must be called in coroutines because they are asynchronous operations:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"

-- Wrong: Cannot call directly in main thread
-- local client = etcd.newclient({endpoints = {"127.0.0.1:2379"}})
-- local res = client:get({key = "foo"})  -- Will block or fail

-- Correct: Call in coroutine
task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    local res = client:get {key = "foo"}
    -- Process result...
end)
```

### 2. Automatic Lease Keep-Alive

After creating a lease, the client automatically starts a background keep-alive task; no need to manually call `keepalive`:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Create lease
    local lease = client:grant {TTL = 10}
    local lease_id = lease.ID

    -- No need to manually call keepalive
    -- Client automatically renews in background

    -- Associate key with lease
    client:put {
        key = "temp/data",
        value = "will live for 10+ seconds",
        lease = lease_id,
    }

    -- Lease automatically renews until you revoke it
    silly.sleep(30000)  -- Even after 10 seconds, lease is still valid

    -- Revoke lease to stop automatic keep-alive
    client:revoke {ID = lease_id}
end)
```

### 3. Error Handling

Always check return values and handle errors:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
        retry = 3,
        retry_sleep = 1000,
    }

    -- Correct: Check for errors
    local res, err = client:put {
        key = "test/key",
        value = "test value",
    }

    if not res then
        print("Put failed:", err)
        -- Handle error (retry, alert, etc.)
        return
    end

    print("Put successful")

    -- Check lease operations
    local lease, err = client:grant {TTL = 60}
    if not lease then
        print("Grant lease failed:", err)
        return
    end

    print("Lease granted:", lease.ID)
end)
```

### 4. Watch Stream Lifecycle

Watch stream objects need to be properly managed:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    local stream = client:watch {
        key = "config/",
        prefix = true,
    }

    if not stream then
        return
    end

    -- Read events in separate coroutine
    task.fork(function()
        while true do
            local res, err = stream:read()

            if not res then
                print("Watch ended:", err)
                break
            end

            -- Process events...
        end

        -- Important: Close stream to release resources
        stream:close()
    end)

    -- Main coroutine can continue executing other tasks
    silly.sleep(10000)

    -- If need to stop watching, close stream
    stream:close()
end)
```

### 5. Key Name Conventions

Recommend using hierarchical key name conventions for convenient prefix queries and management:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Recommended: Use /-separated hierarchical structure
    client:put {key = "/config/app/database/host", value = "localhost"}
    client:put {key = "/config/app/database/port", value = "3306"}
    client:put {key = "/config/app/cache/host", value = "redis"}

    -- Avoid: Flat key names
    -- client:put {key = "config-app-database-host", value = "localhost"}

    -- Benefits of hierarchical structure: Convenient prefix queries
    local res = client:get {
        key = "/config/app/database/",
        prefix = true,
    }

    if res then
        print("Found database config:", res.count, "items")
    end
end)
```

### 6. Revision Numbers and Compaction

etcd uses MVCC, and each modification increases the revision number. Regularly compact to avoid excessive space usage:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Perform many updates
    for i = 1, 100 do
        client:put {key = "counter", value = tostring(i)}
    end

    -- Get current revision number
    local res = client:get {key = "counter"}
    if res then
        local current_rev = res.header.revision
        print("Current revision:", current_rev)

        -- Compact old versions (keep recent 50 versions)
        local compact_rev = current_rev - 50
        if compact_rev > 0 then
            local compact_res = client:compact {
                revision = compact_rev,
                physical = true,
            }

            if compact_res then
                print("Compacted to revision:", compact_rev)
            end
        end
    end
end)
```

---

## Performance Recommendations

### 1. Batch Operations

For multiple independent key-value operations, consider concurrent execution to improve performance:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local waitgroup = require "silly.sync.waitgroup"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    local wg = waitgroup.new()
    local keys = {"key1", "key2", "key3", "key4", "key5"}

    -- Concurrent write to multiple keys
    for _, key in ipairs(keys) do
        wg:fork(function()
            client:put {
                key = "batch/" .. key,
                value = "value-" .. key,
            }
        end)
    end

    wg:wait()
    print("All keys written")
end)
```

### 2. Use Prefix Queries

Avoid multiple single-key queries; use prefix queries to get multiple related keys at once:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Not recommended: Multiple single-key queries
    -- local host = client:get {key = "/config/db/host"}
    -- local port = client:get {key = "/config/db/port"}
    -- local user = client:get {key = "/config/db/user"}

    -- Recommended: Use prefix query to get all config at once
    local res = client:get {
        key = "/config/db/",
        prefix = true,
    }

    if res then
        local config = {}
        for _, kv in ipairs(res.kvs) do
            local field = kv.key:match("/config/db/(.+)")
            config[field] = kv.value
        end

        print("DB config:", config.host, config.port, config.user)
    end
end)
```

### 3. Watch Filtering

Use filters to reduce unnecessary event notifications:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Only watch delete events
    local stream = client:watch {
        key = "/temp/",
        prefix = true,
        NOPUT = true,  -- Filter PUT events
    }

    if stream then
        while true do
            local res = stream:read()
            if not res then
                break
            end

            -- Will only receive delete events
            for _, event in ipairs(res.events) do
                print("Deleted:", event.kv.key)
            end
        end

        stream:close()
    end
end)
```

### 4. Lease Reuse

For multiple temporary keys, reusing the same lease can reduce overhead:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- Create one lease
    local lease = client:grant {TTL = 60}
    local lease_id = lease.ID

    -- Multiple keys share the same lease
    local temp_keys = {
        "session/user1",
        "session/user2",
        "session/user3",
    }

    for _, key in ipairs(temp_keys) do
        client:put {
            key = "/temp/" .. key,
            value = "active",
            lease = lease_id,  -- Share lease
        }
    end

    print("All keys registered with lease:", lease_id)

    -- Revoke lease once to delete all associated keys
    silly.sleep(10000)
    client:revoke {ID = lease_id}
    print("All keys deleted")
end)
```

### 5. Reasonable Retry Parameters

Adjust retry parameters based on network environment:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    -- LAN environment: Fast fail
    local client_lan = etcd.newclient {
        endpoints = {"192.168.1.100:2379"},
        retry = 2,
        retry_sleep = 100,
        timeout = 2,
    }

    -- Cross-region environment: More retries and longer timeout
    local client_wan = etcd.newclient {
        endpoints = {"remote.example.com:2379"},
        retry = 5,
        retry_sleep = 2000,
        timeout = 10,
    }
end)
```

---

## See Also

- [silly.store.mysql](./mysql.md) - MySQL database client
- [silly.store.redis](./redis.md) - Redis client
- [silly.net.grpc](../net/grpc.md) - gRPC client/server
- [silly.sync.mutex](../sync/mutex.md) - Local mutex
- [silly.encoding.json](../encoding/json.md) - JSON encoding/decoding
