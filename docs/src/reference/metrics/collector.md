---
title: silly.metrics.collector
description: Prometheus 指标收集器接口与实现
category: reference
---

# silly.metrics.collector

::: info 模块描述
`silly.metrics.collector` 定义了 Prometheus 指标收集器的接口协议。Collector 是一个抽象概念，用于在每次指标采集时动态生成指标数据。通过实现 Collector 接口，可以自定义复杂的指标采集逻辑，支持运行时统计、系统资源监控等场景。
:::

## 简介

Collector（收集器）是 Prometheus 监控系统中的核心抽象，用于按需生成指标数据。与 Counter、Gauge、Histogram 等静态指标不同，Collector 在每次 `/metrics` 端点被访问时动态执行采集逻辑。

### 为什么需要 Collector？

在以下场景中，Collector 比静态指标更合适：

1. **系统资源监控**：采集 CPU、内存、网络等系统级指标
2. **运行时统计**：查询进程内部状态（如任务队列长度、连接池状态）
3. **批量指标生成**：一次采集生成多个相关指标
4. **性能优化**：避免实时更新指标的性能开销，采集时计算即可
5. **外部数据源**：从数据库、配置中心等外部源读取指标

### Silly 内置 Collector

框架自动注册以下 Collector（无需手动创建）：

- **silly.metrics.collector.silly**：框架运行时统计（任务队列、定时器、网络连接）
- **silly.metrics.collector.process**：进程资源监控（CPU、内存）
- **silly.metrics.collector.jemalloc**：jemalloc 内存分配器统计（需编译时启用）

## 核心概念

### Collector 协议

Collector 是一个实现以下接口的 Lua 表：

```lua
---@class silly.metrics.collector
---@field name string                    -- 收集器名称（用于标识）
---@field new fun(): silly.metrics.collector    -- 构造函数
---@field collect fun(self: silly.metrics.collector, buf: silly.metrics.metric[])  -- 采集方法
```

**协议要求**：

1. **name 字段**：字符串类型，标识 Collector 的名称
2. **new() 方法**：返回一个新的 Collector 实例
3. **collect() 方法**：执行指标采集，将生成的指标对象追加到 `buf` 数组中

### 采集流程

当 Prometheus 请求 `/metrics` 端点时，流程如下：

```
1. prometheus.gather() 被调用
2. registry:collect() 遍历所有注册的 Collector
3. 每个 Collector 的 collect(buf) 被调用
4. Collector 将指标对象追加到 buf 数组
5. prometheus 将 buf 中的所有指标格式化为文本输出
```

### Collector vs 静态指标

| 特性           | 静态指标 (Counter/Gauge) | Collector                |
|----------------|--------------------------|--------------------------|
| 更新时机       | 事件发生时实时更新       | 采集时按需计算           |
| 内存占用       | 持续占用内存存储值       | 仅在采集时临时创建       |
| 性能开销       | 更新操作有轻微开销       | 采集时有计算开销         |
| 适用场景       | 高频事件、累积统计       | 系统状态、批量指标       |
| 数据持久性     | 保留历史累积值           | 每次重新计算             |

### 指标对象结构

`collect()` 方法需要将指标对象追加到 `buf` 数组。指标对象可以是：

- `silly.metrics.counter`：Counter 指标
- `silly.metrics.gauge`：Gauge 指标
- `silly.metrics.histogram`：Histogram 指标

这些对象必须包含以下字段：

```lua
{
    name = "指标名称",
    help = "指标描述",
    kind = "counter" | "gauge" | "histogram",
    value = 数值,         -- 简单指标的值
    metrics = {...}      -- Vector 类型的多个标签组合（可选）
}
```

## API 参考

### Collector 接口

#### name

收集器的名称，用于标识和调试。

```lua
collector.name: string
```

**示例：**

```lua validate
local M = {}

function M.new()
    local collector = {
        name = "MyCustomCollector",  -- 设置名称
        new = M.new,
        collect = function(self, buf)
            -- 采集逻辑
        end,
    }
    return collector
end
```

---

#### new()

创建一个新的 Collector 实例。

```lua
function collector.new(): silly.metrics.collector
```

**返回值：**

- `silly.metrics.collector`：新创建的 Collector 实例

**实现要求：**

- 必须返回包含 `name`、`new`、`collect` 字段的表
- 可以在实例中初始化内部状态（如缓存、计数器等）

**示例：**

```lua validate
local gauge = require "silly.metrics.gauge"

local M = {}
M.__index = M

function M.new()
    -- 在构造函数中创建指标对象
    local active_tasks = gauge("active_tasks", "Number of active tasks")

    local collector = {
        name = "TaskCollector",
        new = M.new,
        collect = function(self, buf)
            -- 动态获取任务数量并更新指标
            local count = 42  -- 实际应从系统状态读取
            active_tasks:set(count)
            buf[#buf + 1] = active_tasks
        end,
    }
    return collector
end
```

---

#### collect()

执行指标采集，将生成的指标对象追加到 `buf` 数组中。

```lua
function collector:collect(buf: silly.metrics.metric[])
```

**参数：**

- `buf` (silly.metrics.metric[])：用于收集指标的数组，将生成的指标追加到此数组末尾

**返回值：** 无

**实现要求：**

1. 从系统、运行时或外部数据源读取最新状态
2. 更新或创建指标对象
3. 使用 `buf[#buf + 1] = metric` 追加指标到数组
4. 不要修改 `buf` 中已有的元素
5. 可以追加多个指标

**示例：**

```lua validate
local gauge = require "silly.metrics.gauge"

local M = {}

function M.new()
    -- 创建多个指标
    local cpu_usage = gauge("cpu_usage_percent", "CPU usage percentage")
    local memory_usage = gauge("memory_usage_bytes", "Memory usage in bytes")

    local collector = {
        name = "SystemCollector",
        new = M.new,
        collect = function(self, buf)
            -- 动态采集系统数据
            cpu_usage:set(45.6)        -- 实际应读取真实 CPU 数据
            memory_usage:set(1024000)  -- 实际应读取真实内存数据

            -- 追加多个指标
            local len = #buf
            buf[len + 1] = cpu_usage
            buf[len + 2] = memory_usage
        end,
    }
    return collector
end
```

---

### Registry API

#### registry:register()

将 Collector 注册到 registry。

```lua
local prometheus = require "silly.metrics.prometheus"
local registry = prometheus.registry()

registry:register(collector)
```

**参数：**

- `collector` (silly.metrics.collector)：要注册的 Collector 实例

**返回值：** 无

**注意：**

- 重复注册同一个实例不会生效（通过对象引用判断）
- 注册后，该 Collector 的 `collect()` 会在每次 `prometheus.gather()` 时被调用

**示例：**

```lua validate
local prometheus = require "silly.metrics.prometheus"
local gauge = require "silly.metrics.gauge"

-- 创建自定义 Collector
local M = {}
function M.new()
    local metric = gauge("my_metric", "My custom metric")
    return {
        name = "MyCollector",
        new = M.new,
        collect = function(self, buf)
            metric:set(100)
            buf[#buf + 1] = metric
        end,
    }
end

-- 注册到全局 registry
local registry = prometheus.registry()
local my_collector = M.new()
registry:register(my_collector)

-- 现在 my_metric 会出现在 prometheus.gather() 输出中
```

---

#### registry:unregister()

从 registry 中移除 Collector。

```lua
registry:unregister(collector)
```

**参数：**

- `collector` (silly.metrics.collector)：要移除的 Collector 实例

**返回值：** 无

**示例：**

```lua validate
local prometheus = require "silly.metrics.prometheus"
local gauge = require "silly.metrics.gauge"

local M = {}
function M.new()
    local metric = gauge("temp_metric", "Temporary metric")
    return {
        name = "TempCollector",
        new = M.new,
        collect = function(self, buf)
            metric:set(50)
            buf[#buf + 1] = metric
        end,
    }
end

local registry = prometheus.registry()
local temp_collector = M.new()

-- 注册
registry:register(temp_collector)

-- 后续不再需要时移除
registry:unregister(temp_collector)
```

---

#### registry:collect()

执行所有注册的 Collector 的采集逻辑，返回所有指标。

```lua
local metrics = registry:collect()
```

**返回值：**

- `silly.metrics.metric[]`：包含所有采集到的指标的数组

**注意：**

- 这是内部 API，通常由 `prometheus.gather()` 自动调用
- 普通用户代码不需要直接调用

**示例：**

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- 获取全局 registry
local registry = prometheus.registry()

-- 手动触发采集（通常不需要）
local metrics = registry:collect()

-- metrics 是一个包含所有指标对象的数组
for i = 1, #metrics do
    local m = metrics[i]
    print(m.name, m.kind, m.value or "vector")
end
```

---

## 使用示例

### 示例 1：简单计数 Collector

创建一个采集固定值的简单 Collector。

```lua validate
local gauge = require "silly.metrics.gauge"
local prometheus = require "silly.metrics.prometheus"

local SimpleCollector = {}

function SimpleCollector.new()
    -- 在构造函数中创建指标
    local uptime_metric = gauge("app_uptime_seconds", "Application uptime in seconds")
    local start_time = os.time()

    local collector = {
        name = "SimpleCollector",
        new = SimpleCollector.new,
        collect = function(self, buf)
            -- 每次采集时计算运行时长
            local uptime = os.time() - start_time
            uptime_metric:set(uptime)
            buf[#buf + 1] = uptime_metric
        end,
    }
    return collector
end

-- 注册到 Prometheus
local registry = prometheus.registry()
local simple_collector = SimpleCollector.new()
registry:register(simple_collector)

-- 现在 app_uptime_seconds 会出现在 /metrics 输出中
-- 每次访问 /metrics 时，uptime 值都会更新
```

---

### 示例 2：多指标 Collector

一个 Collector 可以生成多个相关指标。

```lua validate
local gauge = require "silly.metrics.gauge"
local counter = require "silly.metrics.counter"
local prometheus = require "silly.metrics.prometheus"

local AppStatsCollector = {}

function AppStatsCollector.new()
    -- 创建多个指标
    local active_users = gauge("app_active_users", "Number of active users")
    local total_requests = counter("app_total_requests", "Total requests processed")
    local queue_size = gauge("app_queue_size", "Message queue size")

    -- 模拟内部状态
    local request_count = 0

    local collector = {
        name = "AppStatsCollector",
        new = AppStatsCollector.new,
        collect = function(self, buf)
            -- 模拟从系统状态读取数据
            active_users:set(math.random(50, 200))
            queue_size:set(math.random(0, 100))

            -- 累积请求计数
            request_count = request_count + math.random(10, 50)
            total_requests.value = request_count

            -- 追加多个指标
            local len = #buf
            buf[len + 1] = active_users
            buf[len + 2] = total_requests
            buf[len + 3] = queue_size
        end,
    }
    return collector
end

-- 注册
local registry = prometheus.registry()
local app_stats = AppStatsCollector.new()
registry:register(app_stats)
```

---

### 示例 3：带标签的 Vector Collector

采集多维度标签指标。

```lua validate
local gauge = require "silly.metrics.gauge"
local prometheus = require "silly.metrics.prometheus"

local PoolCollector = {}

function PoolCollector.new()
    -- 创建带标签的 Gauge Vector
    local pool_connections = gauge(
        "pool_connections",
        "Number of connections in pool",
        {"pool_name", "state"}
    )

    local collector = {
        name = "PoolCollector",
        new = PoolCollector.new,
        collect = function(self, buf)
            -- 模拟多个连接池的状态
            local pools = {
                {name = "mysql", active = 10, idle = 5},
                {name = "redis", active = 20, idle = 15},
                {name = "postgres", active = 8, idle = 12},
            }

            for _, pool in ipairs(pools) do
                pool_connections:labels(pool.name, "active"):set(pool.active)
                pool_connections:labels(pool.name, "idle"):set(pool.idle)
            end

            buf[#buf + 1] = pool_connections
        end,
    }
    return collector
end

-- 注册
local registry = prometheus.registry()
local pool_collector = PoolCollector.new()
registry:register(pool_collector)

-- 输出示例：
-- pool_connections{pool_name="mysql",state="active"} 10
-- pool_connections{pool_name="mysql",state="idle"} 5
-- pool_connections{pool_name="redis",state="active"} 20
-- pool_connections{pool_name="redis",state="idle"} 15
```

---

### 示例 4：缓存状态 Collector

采集缓存命中率等统计信息。

```lua validate
local gauge = require "silly.metrics.gauge"
local counter = require "silly.metrics.counter"
local prometheus = require "silly.metrics.prometheus"

local CacheCollector = {}

function CacheCollector.new()
    -- 创建指标
    local cache_size = gauge("cache_entries", "Number of cached entries")
    local cache_hits = counter("cache_hits_total", "Total cache hits")
    local cache_misses = counter("cache_misses_total", "Total cache misses")
    local cache_hit_ratio = gauge("cache_hit_ratio", "Cache hit ratio (0-1)")

    -- 模拟内部缓存状态
    local cache = {}
    local hits = 0
    local misses = 0

    local collector = {
        name = "CacheCollector",
        new = CacheCollector.new,
        collect = function(self, buf)
            -- 模拟缓存操作
            hits = hits + math.random(100, 200)
            misses = misses + math.random(10, 30)

            -- 计算缓存大小
            local size = math.random(500, 1000)
            cache_size:set(size)

            -- 更新计数器
            cache_hits.value = hits
            cache_misses.value = misses

            -- 计算命中率
            local total = hits + misses
            local ratio = total > 0 and (hits / total) or 0
            cache_hit_ratio:set(ratio)

            -- 追加指标
            local len = #buf
            buf[len + 1] = cache_size
            buf[len + 2] = cache_hits
            buf[len + 3] = cache_misses
            buf[len + 4] = cache_hit_ratio
        end,
    }
    return collector
end

-- 注册
local registry = prometheus.registry()
local cache_collector = CacheCollector.new()
registry:register(cache_collector)
```

---

### 示例 5：任务队列 Collector

监控异步任务队列状态。

```lua validate
local gauge = require "silly.metrics.gauge"
local prometheus = require "silly.metrics.prometheus"

local QueueCollector = {}

function QueueCollector.new()
    -- 创建队列相关指标
    local queue_size = gauge(
        "queue_size",
        "Number of tasks in queue",
        {"priority"}
    )
    local queue_oldest_age = gauge(
        "queue_oldest_task_seconds",
        "Age of oldest task in queue (seconds)",
        {"priority"}
    )

    local collector = {
        name = "QueueCollector",
        new = QueueCollector.new,
        collect = function(self, buf)
            -- 模拟不同优先级的队列状态
            local queues = {
                {priority = "high", size = 5, oldest = 2},
                {priority = "normal", size = 20, oldest = 10},
                {priority = "low", size = 50, oldest = 30},
            }

            for _, q in ipairs(queues) do
                queue_size:labels(q.priority):set(q.size)
                queue_oldest_age:labels(q.priority):set(q.oldest)
            end

            local len = #buf
            buf[len + 1] = queue_size
            buf[len + 2] = queue_oldest_age
        end,
    }
    return collector
end

-- 注册
local registry = prometheus.registry()
local queue_collector = QueueCollector.new()
registry:register(queue_collector)
```

---

### 示例 6：外部数据源 Collector

从配置文件或数据库读取指标数据。

```lua validate
local gauge = require "silly.metrics.gauge"
local prometheus = require "silly.metrics.prometheus"

local ConfigCollector = {}

function ConfigCollector.new()
    -- 创建配置相关指标
    local config_version = gauge("config_version", "Current configuration version")
    local config_reload_time = gauge("config_last_reload_timestamp", "Last config reload timestamp")

    local collector = {
        name = "ConfigCollector",
        new = ConfigCollector.new,
        collect = function(self, buf)
            -- 模拟从配置源读取数据
            -- 实际应用中可以从文件、etcd、consul 等读取
            local version = 123  -- 配置版本号
            local reload_time = os.time()  -- 最后重载时间

            config_version:set(version)
            config_reload_time:set(reload_time)

            local len = #buf
            buf[len + 1] = config_version
            buf[len + 2] = config_reload_time
        end,
    }
    return collector
end

-- 注册
local registry = prometheus.registry()
local config_collector = ConfigCollector.new()
registry:register(config_collector)
```

---

### 示例 7：Silly 框架内置 Collector 示例

查看框架如何实现内置 Collector（参考源码）。

```lua validate
local gauge = require "silly.metrics.gauge"
local counter = require "silly.metrics.counter"

-- 简化版 Silly 框架 Collector 实现
local SillyCollector = {}

function SillyCollector.new()
    -- 创建框架内部指标
    local worker_backlog = gauge(
        "silly_worker_backlog",
        "Number of pending messages in worker queue"
    )
    local tcp_connections = gauge(
        "silly_tcp_connections",
        "Number of active TCP connections"
    )
    local bytes_sent = counter(
        "silly_network_sent_bytes_total",
        "Total bytes sent via network"
    )

    local last_bytes_sent = 0

    local collector = {
        name = "SillyCollector",
        new = SillyCollector.new,
        collect = function(self, buf)
            -- 模拟从 C 模块读取统计数据
            -- 实际实现中调用 silly.metrics.c.workerstat() 等 C API
            local backlog = math.random(0, 50)
            local connections = math.random(10, 100)
            local current_bytes_sent = math.random(10000, 50000)

            -- 更新 Gauge 指标
            worker_backlog:set(backlog)
            tcp_connections:set(connections)

            -- 更新 Counter（计算增量）
            if current_bytes_sent > last_bytes_sent then
                bytes_sent:add(current_bytes_sent - last_bytes_sent)
            end
            last_bytes_sent = current_bytes_sent

            -- 追加指标
            local len = #buf
            buf[len + 1] = worker_backlog
            buf[len + 2] = tcp_connections
            buf[len + 3] = bytes_sent
        end,
    }
    return collector
end

-- 框架会自动注册内置 Collector，用户无需手动操作
```

---

### 示例 8：完整集成示例

创建自定义 Collector 并通过 HTTP 暴露指标。

```lua validate
local gauge = require "silly.metrics.gauge"
local prometheus = require "silly.metrics.prometheus"
local http = require "silly.net.http"

-- 创建业务 Collector
local BusinessCollector = {}

function BusinessCollector.new()
    local online_players = gauge("game_online_players", "Number of online players")
    local active_battles = gauge("game_active_battles", "Number of active battles")

    -- 模拟游戏状态
    local player_count = 0

    local collector = {
        name = "BusinessCollector",
        new = BusinessCollector.new,
        collect = function(self, buf)
            -- 动态更新玩家数量
            player_count = math.random(100, 500)
            online_players:set(player_count)

            -- 战斗数约为玩家数的 20%
            active_battles:set(math.floor(player_count * 0.2))

            local len = #buf
            buf[len + 1] = online_players
            buf[len + 2] = active_battles
        end,
    }
    return collector
end

-- 注册自定义 Collector
local registry = prometheus.registry()
local business_collector = BusinessCollector.new()
registry:register(business_collector)

-- 启动 HTTP 服务器暴露指标
local server = http.listen {
    addr = "127.0.0.1:9090",
    handler = function(stream)
        if stream.path == "/metrics" then
            -- 调用 gather() 会触发所有 Collector 的 collect()
            local metrics_data = prometheus.gather()

            stream:respond(200, {
                ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
                ["content-length"] = #metrics_data,
            })
            stream:close(metrics_data)
        else
            stream:respond(404)
            stream:close("Not Found")
        end
    end
}

-- 访问 http://127.0.0.1:9090/metrics 查看指标
-- 输出包含：
-- 1. 内置 Collector 的指标（silly、process、jemalloc）
-- 2. 自定义 BusinessCollector 的指标
```

---

## 注意事项

### 1. collect() 性能开销

`collect()` 在每次 `/metrics` 被访问时调用，应避免执行耗时操作。

```lua
-- 错误：在 collect() 中执行昂贵的操作
local collector = {
    collect = function(self, buf)
        -- ❌ 不好：大量文件 I/O
        local f = io.open("/large/file.log", "r")
        local content = f:read("*a")
        f:close()

        -- ❌ 不好：复杂计算
        for i = 1, 1000000 do
            -- 大量计算
        end

        -- ❌ 不好：网络请求
        -- http.get("http://external-service/stats")
    end
}

-- 正确：轻量级操作
local collector = {
    collect = function(self, buf)
        -- ✅ 好：读取内存中的状态
        local count = get_cached_count()
        metric:set(count)
        buf[#buf + 1] = metric
    end
}
```

**建议**：将昂贵操作移到后台任务，`collect()` 仅读取缓存结果。

---

### 2. 指标对象复用

在 `new()` 中创建指标对象，在 `collect()` 中复用它们。

```lua
-- ❌ 错误：每次 collect 创建新对象
local BadCollector = {}
function BadCollector.new()
    return {
        name = "BadCollector",
        new = BadCollector.new,
        collect = function(self, buf)
            -- 每次采集都创建新的 gauge 对象（浪费内存）
            local g = gauge("my_metric", "My metric")
            g:set(100)
            buf[#buf + 1] = g
        end,
    }
end

-- ✅ 正确：在构造函数中创建，在 collect 中复用
local GoodCollector = {}
function GoodCollector.new()
    -- 创建一次，复用多次
    local g = gauge("my_metric", "My metric")

    return {
        name = "GoodCollector",
        new = GoodCollector.new,
        collect = function(self, buf)
            g:set(100)  -- 仅更新值
            buf[#buf + 1] = g
        end,
    }
end
```

---

### 3. 避免修改 buf 中已有元素

只能追加新元素到 `buf`，不要修改或删除已有元素。

```lua
local collector = {
    collect = function(self, buf)
        -- ❌ 错误：修改已有元素
        buf[1] = nil

        -- ❌ 错误：插入到中间
        table.insert(buf, 1, metric)

        -- ✅ 正确：追加到末尾
        buf[#buf + 1] = metric
    end
}
```

---

### 4. Counter 增量计算

对于累积值（如字节数），需要保存上次值并计算增量。

```lua
local counter = require "silly.metrics.counter"

local MyCollector = {}
function MyCollector.new()
    local bytes_sent = counter("bytes_sent_total", "Total bytes sent")
    local last_value = 0  -- 保存上次的累积值

    return {
        name = "MyCollector",
        new = MyCollector.new,
        collect = function(self, buf)
            -- 假设系统返回累积总值
            local current_value = get_system_bytes_sent()

            -- 计算增量并更新 Counter
            if current_value > last_value then
                bytes_sent:add(current_value - last_value)
            end
            last_value = current_value

            buf[#buf + 1] = bytes_sent
        end,
    }
end
```

这是因为 Counter 的 `add()` 是累加操作，而系统统计通常返回累积总值。

---

### 5. 内置 Collector 自动注册

框架已自动注册以下 Collector，无需手动操作：

```lua
-- 这些 Collector 在 silly.metrics.prometheus 模块加载时自动注册
-- 用户无需也不应该手动注册

-- silly.metrics.collector.silly
-- silly.metrics.collector.process
-- silly.metrics.collector.jemalloc（仅当编译时启用 jemalloc）
```

如果想禁用内置 Collector，可以手动 `unregister`：

```lua validate
local prometheus = require "silly.metrics.prometheus"
local silly_collector = require "silly.metrics.collector.silly"

local registry = prometheus.registry()

-- 移除内置 Silly Collector（不推荐）
-- 注意：这需要访问到具体的 collector 实例，通常不建议这样做
```

---

### 6. 标签一致性

同一指标名称在不同采集周期必须保持标签名称一致。

```lua
-- ❌ 错误：标签不一致
local g = gauge("my_metric", "My metric", {"label1"})

-- 第一次采集
g:labels("value1"):set(100)
buf[#buf + 1] = g

-- 第二次采集（错误：改变了标签名称）
g = gauge("my_metric", "My metric", {"label2"})  -- label2 与 label1 不同
g:labels("value2"):set(200)
buf[#buf + 1] = g

-- ✅ 正确：标签名称保持一致
local g = gauge("my_metric", "My metric", {"label1"})

-- 始终使用相同的标签名称
g:labels("value1"):set(100)
g:labels("value2"):set(200)
```

---

### 7. 异常处理

`collect()` 中的错误会影响整个指标采集流程，应做好错误处理。

```lua
local collector = {
    collect = function(self, buf)
        -- ✅ 好：捕获异常避免采集失败
        local ok, err = pcall(function()
            local value = might_throw_error()
            metric:set(value)
            buf[#buf + 1] = metric
        end)

        if not ok then
            -- 记录错误日志
            print("Collector error:", err)
            -- 可以设置默认值或跳过该指标
        end
    end
}
```

---

### 8. 线程安全

Silly 使用单线程 Worker 模型，业务逻辑在同一线程执行。但 `collect()` 是同步调用，应避免阻塞操作。

```lua
local collector = {
    collect = function(self, buf)
        -- ❌ 不好：阻塞式网络请求
        -- local response = http.get("http://slow-service/stats")  -- 会阻塞

        -- ✅ 好：使用后台任务更新缓存，collect 只读取缓存
        local cached_stats = get_stats_from_cache()
        metric:set(cached_stats)
        buf[#buf + 1] = metric
    end
}
```

---

## 参见

- [silly.metrics.prometheus](./prometheus.md) - Prometheus 指标集成与格式化
- [silly.metrics.counter](./counter.md) - Counter 计数器指标
- [silly.metrics.gauge](./gauge.md) - Gauge 仪表盘指标
- [silly.metrics.histogram](./histogram.md) - Histogram 直方图指标
- [silly.net.http](../net/http.md) - HTTP 服务器（用于暴露 /metrics 端点）

## 参考资料

- [Prometheus Collector 接口](https://prometheus.io/docs/instrumenting/writing_exporters/)
- [Prometheus 客户端最佳实践](https://prometheus.io/docs/practices/instrumentation/)
- [Prometheus 数据模型](https://prometheus.io/docs/concepts/data_model/)
