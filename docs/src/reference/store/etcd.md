---
title: silly.store.etcd
icon: database
category:
  - API参考
tag:
  - 存储
  - etcd
  - 分布式配置
---

# silly.store.etcd

`silly.store.etcd` 模块提供了一个用于与 etcd v3 API 交互的客户端。它基于 gRPC 实现，并提供了对 etcd 核心功能（如键值存储、租约、监视）的封装。etcd 是一个分布式、可靠的键值存储系统，常用于配置管理、服务发现和分布式协调。

## 模块导入

```lua validate
local etcd = require "silly.store.etcd"
```

## 核心概念

### etcd v3 API

etcd v3 API 基于 gRPC，提供以下核心功能：

- **键值存储（KV）**: 支持 CRUD 操作、范围查询、版本控制
- **租约（Lease）**: 为键值对设置生存时间（TTL），租约到期后自动删除关联的键
- **监视（Watch）**: 监听键的变化事件，支持历史版本回放
- **事务（Transaction）**: 原子性执行多个操作


### 租约保活

客户端自动管理租约保活（keepalive）：

- 创建租约后自动启动后台保活任务
- 定期发送保活请求延长租约 TTL
- 撤销租约后自动停止保活

### 重试机制

客户端内置重试机制，提高可靠性：

- 默认重试 5 次
- 可配置重试次数和间隔时间
- 自动在失败时睡眠后重试

---

## API 参考

### etcd.newclient(conf)

创建一个新的 etcd 客户端实例。

- **参数**:
  - `conf`: `table` - 客户端配置表
    - `endpoints`: `string[]` (必需) - etcd 服务器地址列表，例如 `{"127.0.0.1:2379"}`
    - `retry`: `integer|nil` (可选) - 请求失败时的重试次数，默认为 5
    - `retry_sleep`: `integer|nil` (可选) - 每次重试之间的等待时间（毫秒），默认为 1000
    - `timeout`: `number|nil` (可选) - gRPC 请求的超时时间（秒）
- **返回值**:
  - 成功: `silly.store.etcd.client` - etcd 客户端对象
  - 失败: 抛出错误
- **异步**: 否
- **示例**:

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

## 键值存储 API

### client:put(req)

在 etcd 中存储一个键值对。如果键已存在，则更新其值。

- **参数**:
  - `req`: `table` - 请求参数
    - `key`: `string` (必需) - 要存储的键
    - `value`: `string` (必需) - 要存储的值
    - `lease`: `integer|nil` (可选) - 关联的租约 ID，租约到期后键自动删除
    - `prev_kv`: `boolean|nil` (可选) - 如果为 `true`，返回操作前的键值对
    - `ignore_value`: `boolean|nil` (可选) - 如果为 `true`，etcd 将使用当前值更新键（仅更新版本号）
    - `ignore_lease`: `boolean|nil` (可选) - 如果为 `true`，etcd 将使用当前租约更新键
- **返回值**:
  - 成功: `table` - 响应对象
    - `header`: `etcd.ResponseHeader` - 响应头，包含集群信息和版本号
    - `prev_kv`: `mvccpb.KeyValue|nil` - 如果设置了 `prev_kv`，返回操作前的键值对
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 是（会挂起协程直到操作完成或超时）
- **示例**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 存储简单键值对
    local res, err = client:put {
        key = "config/app/name",
        value = "MyApp",
    }

    if not res then
        print("Put failed:", err)
        return
    end

    print("Put successful, revision:", res.header.revision)

    -- 存储并获取旧值
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

从 etcd 中获取键值对。支持单键查询、前缀查询、范围查询等多种模式。

- **参数**:
  - `req`: `table` - 请求参数
    - `key`: `string` (必需) - 要获取的键
    - `prefix`: `boolean|nil` (可选) - 如果为 `true`，获取所有以此为前缀的键
    - `fromkey`: `boolean|nil` (可选) - 如果为 `true`，获取从此键开始的所有键
    - `limit`: `number|nil` (可选) - 限制返回的键数量
    - `revision`: `number|nil` (可选) - 指定历史版本号，查询该版本时的键值
    - `sort_order`: `"NONE"|"ASCEND"|"DESCEND"|nil` (可选) - 排序顺序
    - `sort_target`: `"KEY"|"VERSION"|"CREATE"|"MOD"|"VALUE"|nil` (可选) - 排序目标字段
    - `serializable`: `boolean|nil` (可选) - 如果为 `true`，使用可序列化读取（性能更好但可能读到旧数据）
    - `keys_only`: `boolean|nil` (可选) - 如果为 `true`，只返回键不返回值
    - `count_only`: `boolean|nil` (可选) - 如果为 `true`，只返回键的数量
    - `min_mod_revision`: `number|nil` (可选) - 过滤条件：修改版本号下限
    - `max_mod_revision`: `number|nil` (可选) - 过滤条件：修改版本号上限
    - `min_create_revision`: `number|nil` (可选) - 过滤条件：创建版本号下限
    - `max_create_revision`: `number|nil` (可选) - 过滤条件：创建版本号上限
- **返回值**:
  - 成功: `table` - 响应对象
    - `header`: `etcd.ResponseHeader` - 响应头
    - `kvs`: `mvccpb.KeyValue[]` - 键值对数组
    - `more`: `boolean` - 是否还有更多键（当使用 `limit` 时）
    - `count`: `number` - 键的总数量
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 是
- **示例**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 先存储一些数据
    client:put {key = "config/db/host", value = "localhost"}
    client:put {key = "config/db/port", value = "3306"}
    client:put {key = "config/cache/host", value = "redis"}

    -- 获取单个键
    local res1, err = client:get {key = "config/db/host"}
    if res1 and res1.kvs[1] then
        print("DB Host:", res1.kvs[1].value)
    end

    -- 获取所有前缀为 "config/db/" 的键
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

    -- 获取键但只返回键名
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

    -- 排序查询
    local res4, err = client:get {
        key = "config/",
        prefix = true,
        sort_order = "DESCEND",
        sort_target = "KEY",
    }
end)
```

### client:delete(req)

删除 etcd 中的键值对。支持单键删除和前缀删除。

- **参数**:
  - `req`: `table` - 请求参数
    - `key`: `string` (必需) - 要删除的键
    - `prefix`: `boolean|nil` (可选) - 如果为 `true`，删除所有以此为前缀的键
    - `prev_kv`: `boolean|nil` (可选) - 如果为 `true`，返回被删除的键值对
- **返回值**:
  - 成功: `table` - 响应对象
    - `header`: `etcd.ResponseHeader` - 响应头
    - `deleted`: `boolean` - 是否删除了键
    - `prev_kvs`: `mvccpb.KeyValue[]` - 如果设置了 `prev_kv`，返回被删除的键值对数组
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 是
- **示例**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 先存储数据
    client:put {key = "temp/key1", value = "value1"}
    client:put {key = "temp/key2", value = "value2"}

    -- 删除单个键并获取旧值
    local res1, err = client:delete {
        key = "temp/key1",
        prev_kv = true,
    }

    if res1 and res1.prev_kvs[1] then
        print("Deleted key:", res1.prev_kvs[1].key)
        print("Old value:", res1.prev_kvs[1].value)
    end

    -- 删除所有前缀为 "temp/" 的键
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

对 etcd 的键值存储进行压缩，释放历史版本占用的空间。

- **参数**:
  - `req`: `table` - 请求参数
    - `revision`: `integer` (必需) - 要压缩到的版本号，小于此版本的历史数据将被删除
    - `physical`: `boolean|nil` (可选) - 如果为 `true`，强制进行物理压缩（立即释放空间）
- **返回值**:
  - 成功: `table` - 响应对象
    - `header`: `etcd.ResponseHeader` - 响应头
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 是
- **注意**: 压缩后，无法再查询被压缩版本之前的历史数据
- **示例**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 执行一些写操作
    for i = 1, 10 do
        client:put {key = "counter", value = tostring(i)}
    end

    -- 获取当前版本号
    local res, err = client:get {key = "counter"}
    if res then
        local current_revision = res.header.revision
        print("Current revision:", current_revision)

        -- 压缩到当前版本之前的版本（保留最近的历史）
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

## 租约 API

### client:grant(req)

创建一个租约。租约可以关联到键值对，当租约过期时，所有关联的键将被自动删除。

- **参数**:
  - `req`: `table` - 请求参数
    - `TTL`: `integer` (必需) - 租约的生存时间（秒）
    - `ID`: `integer|nil` (可选) - 指定租约 ID（如果为 0 或不指定，由 etcd 自动分配）
- **返回值**:
  - 成功: `table` - 响应对象
    - `header`: `etcd.ResponseHeader` - 响应头
    - `ID`: `integer` - 分配的租约 ID
    - `TTL`: `integer` - 实际的 TTL（服务器可能调整）
    - `error`: `string|nil` - 错误信息（如果有）
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 是
- **注意**: 创建租约后，客户端会自动启动后台保活任务
- **示例**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 创建一个 60 秒的租约
    local lease_res, err = client:grant {
        TTL = 60,
    }

    if not lease_res then
        print("Grant lease failed:", err)
        return
    end

    local lease_id = lease_res.ID
    print("Lease granted, ID:", lease_id, "TTL:", lease_res.TTL)

    -- 关联键到租约
    local put_res, err = client:put {
        key = "temp/session",
        value = "active",
        lease = lease_id,
    }

    if put_res then
        print("Key associated with lease")
    end

    -- 租约会自动续期（客户端后台保活）
    -- 60 秒后如果不撤销租约，键会被自动删除
end)
```

### client:revoke(req)

撤销一个租约。租约被撤销后，所有关联的键将立即被删除。

- **参数**:
  - `req`: `table` - 请求参数
    - `ID`: `integer` (必需) - 要撤销的租约 ID
- **返回值**:
  - 成功: `table` - 响应对象
    - `header`: `etcd.ResponseHeader` - 响应头
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 是
- **注意**: 撤销租约后，客户端会自动停止该租约的保活任务
- **示例**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 创建租约
    local lease_res = client:grant {TTL = 60}
    if not lease_res then
        return
    end

    local lease_id = lease_res.ID

    -- 关联键到租约
    client:put {
        key = "temp/data",
        value = "will be deleted",
        lease = lease_id,
    }

    -- 验证键存在
    local get_res = client:get {key = "temp/data"}
    print("Key exists:", get_res and get_res.kvs[1] ~= nil)

    -- 撤销租约
    local revoke_res, err = client:revoke {ID = lease_id}
    if revoke_res then
        print("Lease revoked")
    end

    -- 验证键已被删除
    local get_res2 = client:get {key = "temp/data"}
    print("Key exists after revoke:", get_res2 and get_res2.kvs[1] ~= nil)
end)
```

### client:ttl(req)

查询租约的剩余生存时间和关联的键列表。

- **参数**:
  - `req`: `table` - 请求参数
    - `ID`: `integer` (必需) - 要查询的租约 ID
    - `keys`: `boolean|nil` (可选) - 如果为 `true`，返回所有附加到此租约的键
- **返回值**:
  - 成功: `table` - 响应对象
    - `header`: `etcd.ResponseHeader` - 响应头
    - `ID`: `integer` - 租约 ID
    - `TTL`: `integer` - 剩余 TTL（秒），租约将在 TTL+1 秒内过期
    - `grantedTTL`: `integer` - 创建或续期时的初始 TTL
    - `keys`: `string[]` - 如果请求了 `keys`，返回关联的键列表
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 是
- **示例**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 创建租约并关联键
    local lease_res = client:grant {TTL = 60}
    local lease_id = lease_res.ID

    client:put {key = "session/user1", value = "data1", lease = lease_id}
    client:put {key = "session/user2", value = "data2", lease = lease_id}

    -- 查询租约信息（包含关联的键）
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

列出所有活跃的租约。

- **参数**: 无
- **返回值**:
  - 成功: `table` - 响应对象
    - `leases`: `table[]` - 租约列表，每个元素包含：
      - `ID`: `integer` - 租约 ID
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 是
- **示例**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 创建几个租约
    local lease1 = client:grant {TTL = 60}
    local lease2 = client:grant {TTL = 120}

    -- 列出所有租约
    local res, err = client:leases()
    if res then
        print("Total leases:", #res.leases)
        for i, lease in ipairs(res.leases) do
            print("Lease", i, "ID:", lease.ID)
        end
    end
end)
```

### client:keepalive(id)

手动发送一次租约保活请求（通常不需要手动调用，客户端会自动保活）。

- **参数**:
  - `id`: `integer` (必需) - 要保活的租约 ID
- **返回值**: 无
- **异步**: 否 (只是启动后台保活任务或发送一次请求)
- **注意**: 此方法在实现中通常用于触发后台保活逻辑
- **示例**:

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

    -- 手动触发保活（通常不需要）
    client:keepalive(lease_id)
end)
```

---

## 监视 API

### client:watch(req)

监视 etcd 中键的变化事件。当键被创建、修改或删除时，会收到通知。

- **参数**:
  - `req`: `table` - 请求参数
    - `key`: `string` (必需) - 要监视的键
    - `prefix`: `boolean|nil` (可选) - 如果为 `true`，监视所有以此为前缀的键
    - `revision`: `number|nil` (可选) - 从指定版本号开始监视（可用于回放历史事件）
    - `progress_notify`: `boolean|nil` (可选) - 如果为 `true`，定期发送进度通知
    - `filters`: `table|nil` (可选) - 事件过滤器列表
    - `NOPUT`: `boolean|nil` (可选) - 如果为 `true`，过滤 PUT 事件
    - `NODELETE`: `boolean|nil` (可选) - 如果为 `true`，过滤 DELETE 事件
- **返回值**:
  - 成功: `silly.net.grpc.stream` - gRPC 流对象，用于读取事件
  - 失败: `nil, string` - nil 和错误信息
- **异步**: 是
- **注意**: 需要调用 `stream:read()` 读取事件，`stream:close()` 关闭监视
- **示例**:

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 启动监视协程
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

            -- 处理事件
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

    -- 主协程进行一些修改，触发监视事件
    silly.sleep(100)  -- 等待监视就绪

    client:put {key = "config/app", value = "v1"}
    silly.sleep(50)

    client:put {key = "config/app", value = "v2"}
    silly.sleep(50)

    client:delete {key = "config/app"}
end)
```

---

## 使用示例

### 示例1：配置管理

使用 etcd 存储和读取应用配置：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local json = require "silly.encoding.json"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 存储配置
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

    -- 读取配置
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

### 示例2：服务发现

使用租约实现服务注册与发现：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local json = require "silly.encoding.json"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 服务注册
    local service_info = {
        name = "api-server",
        host = "192.168.1.100",
        port = 8080,
        version = "1.0.0",
    }

    -- 创建租约（服务实例生命周期）
    local lease = client:grant {TTL = 10}
    local lease_id = lease.ID

    -- 注册服务
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

    -- 服务发现
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

    -- 服务会在租约到期后自动注销
    -- 或者手动撤销租约注销服务
    silly.sleep(5000)
    client:revoke {ID = lease_id}
    print("Service unregistered")
end)
```

### 示例3：监听配置变化

实时监听配置变化并更新应用状态：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local json = require "silly.encoding.json"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 当前配置
    local current_config = {}

    -- 启动监听协程
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

                    -- 触发配置重载逻辑
                    -- reload_config(key, value)

                elseif event.type == "DELETE" then
                    current_config[key] = nil
                    print("Config deleted:", key)

                    -- 触发配置清理逻辑
                    -- clear_config(key)
                end
            end
        end

        stream:close()
    end)

    -- 主线程：初始化配置
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

    -- 模拟配置变化
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

### 示例4：键值版本控制

利用 etcd 的 MVCC 特性实现版本控制：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    local key = "document/readme"

    -- 多次更新同一个键
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

    -- 获取当前版本
    local current = client:get {key = key}
    if current and current.kvs[1] then
        local kv = current.kvs[1]
        print("\nCurrent version:")
        print("  Value:", kv.value)
        print("  Version:", kv.version)
        print("  Mod Revision:", kv.mod_revision)
        print("  Create Revision:", kv.create_revision)
    end

    -- 获取历史版本（需要知道具体的 revision）
    -- 注意：需要在压缩之前查询历史版本
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

### 示例5：事务性操作

使用 etcd 进行原子性的多键操作（注意：需要通过底层 gRPC 客户端）：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 先设置初始值
    client:put {key = "counter/a", value = "10"}
    client:put {key = "counter/b", value = "20"}

    print("Initial values set")

    -- 读取当前值
    local res_a = client:get {key = "counter/a"}
    local res_b = client:get {key = "counter/b"}

    if res_a and res_b and res_a.kvs[1] and res_b.kvs[1] then
        local val_a = tonumber(res_a.kvs[1].value)
        local val_b = tonumber(res_b.kvs[1].value)

        print("Counter A:", val_a)
        print("Counter B:", val_b)
        print("Sum:", val_a + val_b)

        -- 更新计数器
        client:put {key = "counter/a", value = tostring(val_a + 1)}
        client:put {key = "counter/b", value = tostring(val_b + 1)}

        print("\nCounters incremented")

        -- 读取新值
        res_a = client:get {key = "counter/a"}
        res_b = client:get {key = "counter/b"}

        if res_a and res_b and res_a.kvs[1] and res_b.kvs[1] then
            print("Counter A:", res_a.kvs[1].value)
            print("Counter B:", res_b.kvs[1].value)
        end
    end
end)
```

### 示例6：健康检查与心跳

使用租约实现服务健康检查：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 创建租约（心跳间隔）
    local lease = client:grant {TTL = 5}
    local lease_id = lease.ID

    -- 注册心跳键
    local heartbeat_key = "/health/service-1"
    client:put {
        key = heartbeat_key,
        value = tostring(os.time()),
        lease = lease_id,
    }

    print("Heartbeat registered with", lease_id)

    -- 监控协程
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
                    -- 触发告警
                end
            end
        end

        stream:close()
    end)

    -- 保持服务运行（租约会自动续期）
    silly.sleep(15000)

    -- 撤销租约（模拟服务停止）
    print("Stopping service...")
    client:revoke {ID = lease_id}

    silly.sleep(1000)
    print("Service stopped")
end)
```

### 示例7：优雅关闭与资源清理

正确处理 etcd 客户端的生命周期：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 创建租约和资源
    local lease = client:grant {TTL = 60}
    local lease_id = lease.ID

    local resources = {
        "/temp/resource1",
        "/temp/resource2",
        "/temp/resource3",
    }

    -- 注册资源
    for _, key in ipairs(resources) do
        client:put {
            key = key,
            value = "active",
            lease = lease_id,
        }
        print("Registered:", key)
    end

    -- 模拟工作
    print("Working...")
    silly.sleep(3000)

    -- 优雅关闭：清理资源
    print("Shutting down...")

    -- 方式1：撤销租约（自动删除所有关联的键）
    local revoke_res = client:revoke {ID = lease_id}
    if revoke_res then
        print("Lease revoked, all resources cleaned up")
    end

    -- 方式2：手动删除资源（如果不使用租约）
    -- for _, key in ipairs(resources) do
    --     client:delete {key = key}
    -- end

    -- 验证清理结果
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

## 注意事项

### 1. 协程要求

所有 etcd 客户端方法必须在协程中调用，因为它们是异步操作：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"

-- 错误：不能在主线程直接调用
-- local client = etcd.newclient({endpoints = {"127.0.0.1:2379"}})
-- local res = client:get({key = "foo"})  -- 会阻塞或失败

-- 正确：在协程中调用
task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    local res = client:get {key = "foo"}
    -- 处理结果...
end)
```

### 2. 租约自动保活

创建租约后，客户端会自动启动后台保活任务，无需手动调用 `keepalive`：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 创建租约
    local lease = client:grant {TTL = 10}
    local lease_id = lease.ID

    -- 不需要手动调用 keepalive
    -- 客户端会在后台自动续期

    -- 关联键到租约
    client:put {
        key = "temp/data",
        value = "will live for 10+ seconds",
        lease = lease_id,
    }

    -- 租约会自动续期，直到你撤销它
    silly.sleep(30000)  -- 即使超过10秒，租约仍然有效

    -- 撤销租约停止自动保活
    client:revoke {ID = lease_id}
end)
```

### 3. 错误处理

始终检查返回值并处理错误：

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

    -- 正确：检查错误
    local res, err = client:put {
        key = "test/key",
        value = "test value",
    }

    if not res then
        print("Put failed:", err)
        -- 处理错误（重试、告警等）
        return
    end

    print("Put successful")

    -- 检查租约操作
    local lease, err = client:grant {TTL = 60}
    if not lease then
        print("Grant lease failed:", err)
        return
    end

    print("Lease granted:", lease.ID)
end)
```

### 4. 监视流的生命周期

监视返回的 stream 对象需要正确管理生命周期：

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

    -- 在独立协程中读取事件
    task.fork(function()
        while true do
            local res, err = stream:read()

            if not res then
                print("Watch ended:", err)
                break
            end

            -- 处理事件...
        end

        -- 重要：关闭流释放资源
        stream:close()
    end)

    -- 主协程可以继续执行其他任务
    silly.sleep(10000)

    -- 如果需要停止监视，关闭流
    stream:close()
end)
```

### 5. 键名约定

建议使用层级化的键名约定，便于前缀查询和管理：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 推荐：使用 / 分隔的层级结构
    client:put {key = "/config/app/database/host", value = "localhost"}
    client:put {key = "/config/app/database/port", value = "3306"}
    client:put {key = "/config/app/cache/host", value = "redis"}

    -- 避免：扁平化的键名
    -- client:put {key = "config-app-database-host", value = "localhost"}

    -- 层级结构的好处：方便前缀查询
    local res = client:get {
        key = "/config/app/database/",
        prefix = true,
    }

    if res then
        print("Found database config:", res.count, "items")
    end
end)
```

### 6. 版本号和压缩

etcd 使用 MVCC，每次修改都会增加版本号。定期压缩避免空间占用过大：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 执行大量更新
    for i = 1, 100 do
        client:put {key = "counter", value = tostring(i)}
    end

    -- 获取当前版本号
    local res = client:get {key = "counter"}
    if res then
        local current_rev = res.header.revision
        print("Current revision:", current_rev)

        -- 压缩旧版本（保留最近50个版本）
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

## 性能建议

### 1. 批量操作

对于多个独立的键值操作，考虑并发执行以提高性能：

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

    -- 并发写入多个键
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

### 2. 使用前缀查询

避免多次单键查询，使用前缀查询一次获取多个相关键：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 不推荐：多次单键查询
    -- local host = client:get {key = "/config/db/host"}
    -- local port = client:get {key = "/config/db/port"}
    -- local user = client:get {key = "/config/db/user"}

    -- 推荐：使用前缀查询一次获取所有配置
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

### 3. 监视过滤

使用过滤器减少不必要的事件通知：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 只监听删除事件
    local stream = client:watch {
        key = "/temp/",
        prefix = true,
        NOPUT = true,  -- 过滤 PUT 事件
    }

    if stream then
        while true do
            local res = stream:read()
            if not res then
                break
            end

            -- 只会收到删除事件
            for _, event in ipairs(res.events) do
                print("Deleted:", event.kv.key)
            end
        end

        stream:close()
    end
end)
```

### 4. 租约复用

对于多个临时键，复用同一个租约可以减少开销：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    local client = etcd.newclient {
        endpoints = {"127.0.0.1:2379"},
    }

    -- 创建一个租约
    local lease = client:grant {TTL = 60}
    local lease_id = lease.ID

    -- 多个键共享同一个租约
    local temp_keys = {
        "session/user1",
        "session/user2",
        "session/user3",
    }

    for _, key in ipairs(temp_keys) do
        client:put {
            key = "/temp/" .. key,
            value = "active",
            lease = lease_id,  -- 共享租约
        }
    end

    print("All keys registered with lease:", lease_id)

    -- 一次撤销租约，删除所有关联的键
    silly.sleep(10000)
    client:revoke {ID = lease_id}
    print("All keys deleted")
end)
```

### 5. 合理设置重试参数

根据网络环境调整重试参数：

```lua validate
local silly = require "silly"
local etcd = require "silly.store.etcd"
local task = require "silly.task"

task.fork(function()
    -- 局域网环境：快速失败
    local client_lan = etcd.newclient {
        endpoints = {"192.168.1.100:2379"},
        retry = 2,
        retry_sleep = 100,
        timeout = 2,
    }

    -- 跨区域环境：更多重试和更长超时
    local client_wan = etcd.newclient {
        endpoints = {"remote.example.com:2379"},
        retry = 5,
        retry_sleep = 2000,
        timeout = 10,
    }
end)
```

---

## 参见

- [silly.store.mysql](./mysql.md) - MySQL 数据库客户端
- [silly.store.redis](./redis.md) - Redis 客户端
- [silly.net.grpc](../net/grpc.md) - gRPC 客户端/服务器
- [silly.sync.mutex](../sync/mutex.md) - 本地互斥锁
- [silly.encoding.json](../encoding/json.md) - JSON 编解码
