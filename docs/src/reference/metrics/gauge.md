---
title: gauge
icon: tachometer-alt
category:
  - API 参考
tag:
  - metrics
  - gauge
  - 监控
---

# silly.metrics.gauge

Gauge（仪表盘）指标模块，提供可增可减的瞬时值监控功能，适用于跟踪当前状态和动态变化的数值。

## 模块简介

`silly.metrics.gauge` 模块实现了 Prometheus Gauge 指标类型，用于表示可以任意上升或下降的数值。与 Counter（只增不减）不同，Gauge 适合记录瞬时状态，如：

- **系统资源**：当前内存使用量、CPU 使用率、磁盘空间
- **网络连接**：活跃连接数、WebSocket 连接数、数据库连接池状态
- **队列状态**：消息队列长度、任务队列深度
- **业务指标**：在线用户数、库存数量、温度传感器读数

Gauge 支持直接设置值（`set()`）、递增递减（`inc()`/`dec()`）、以及增减指定数值（`add()`/`sub()`），提供了灵活的状态管理能力。

## 模块导入

```lua validate
local gauge = require "silly.metrics.gauge"

-- 创建无标签的简单 Gauge
local temperature = gauge("room_temperature_celsius", "Room temperature")
temperature:set(25.5)
temperature:inc()  -- 26.5
temperature:dec()  -- 25.5

-- 创建带标签的 GaugeVec
local connections = gauge("active_connections", "Active connections", {"protocol", "state"})
connections:labels("http", "established"):set(42)
connections:labels("websocket", "established"):set(15)

print("Temperature:", temperature.value)
print("HTTP connections:", connections:labels("http", "established").value)
```

::: tip 独立使用
`gauge` 需要单独导入 `require "silly.metrics.gauge"`，不能通过 `prometheus.gauge()` 的方式直接访问模块本身。如果需要自动注册到 Prometheus Registry，请使用 `prometheus.gauge()`。
:::

## 核心概念

### Gauge vs Counter

理解 Gauge 和 Counter 的区别是正确使用监控指标的关键：

| 特性 | Gauge（仪表盘） | Counter（计数器） |
|------|----------------|------------------|
| **数值变化** | 可增可减 | 只增不减 |
| **表示含义** | 当前状态/瞬时值 | 累积总数 |
| **典型场景** | 内存使用量、连接数 | 请求总数、错误总数 |
| **支持操作** | set, inc, dec, add, sub | inc, add |
| **PromQL 查询** | 直接展示当前值 | 通常使用 rate() 计算速率 |

**选择原则**：
- 如果重启后数值归零有意义（如连接数），使用 **Gauge**
- 如果需要统计事件发生总次数，使用 **Counter**
- 如果需要计算变化率（如 QPS），使用 **Counter** + `rate()`

### 标签系统

标签（Labels）用于为同一指标创建多个维度的时间序列：

```lua validate
local gauge = require "silly.metrics.gauge"

-- 创建带两个标签的 Gauge
local memory_usage = gauge(
    "memory_usage_bytes",
    "Memory usage by type and pool",
    {"type", "pool"}
)

-- 不同标签组合代表不同的时间序列
memory_usage:labels("heap", "default"):set(1024 * 1024 * 100)
memory_usage:labels("heap", "large"):set(1024 * 1024 * 50)
memory_usage:labels("stack", "default"):set(1024 * 1024 * 10)

-- 每个标签组合都是独立的 Gauge 实例
print(memory_usage:labels("heap", "default").value)  -- 104857600
```

**重要约束**：
- 标签顺序必须与创建时一致
- 标签值应该是有限的、可预测的类别
- 避免使用高基数值（如用户 ID、时间戳）作为标签

### Gauge 的内部状态

每个 Gauge 实例维护一个简单的数值字段：

```lua
{
    name = "gauge_name",      -- 指标名称
    help = "description",     -- 描述文本
    kind = "gauge",           -- 类型标识
    value = 0,                -- 当前值（初始为 0）
}
```

对于 GaugeVec（带标签的 Gauge），每个标签组合会创建一个独立的子实例（gaugesub），各自维护独立的 `value`。

## API 参考

### gauge(name, help, labelnames)

创建一个新的 Gauge 指标。

- **参数**:
  - `name`: `string` - 指标名称，必须符合 Prometheus 命名规范（`[a-zA-Z_:][a-zA-Z0-9_:]*`）
  - `help`: `string` - 指标描述文本
  - `labelnames`: `table | nil` - 标签名称列表（可选），例如 `{"method", "status"}`
- **返回值**:
  - `gauge` - 无标签时返回 Gauge 对象
  - `gaugevec` - 有标签时返回 GaugeVec 对象
- **示例**:

```lua validate
local gauge = require "silly.metrics.gauge"

-- 创建无标签的 Gauge
local temperature = gauge("room_temperature_celsius", "Current room temperature")
print(temperature.name)  -- "room_temperature_celsius"
print(temperature.kind)  -- "gauge"
print(temperature.value) -- 0

-- 创建带标签的 GaugeVec
local connections = gauge(
    "active_connections",
    "Number of active connections",
    {"protocol", "state"}
)
print(connections.name)  -- "active_connections"
print(#connections.labelnames)  -- 2
```

### gauge:set(value)

设置 Gauge 的当前值。这是 Gauge 最常用的操作，直接将值设置为指定数值。

- **参数**:
  - `value`: `number` - 要设置的新值
- **返回值**: 无
- **示例**:

```lua validate
local gauge = require "silly.metrics.gauge"

local temperature = gauge("temperature_celsius", "Temperature sensor reading")

-- 直接设置温度值
temperature:set(25.5)
print(temperature.value)  -- 25.5

temperature:set(26.0)
print(temperature.value)  -- 26.0

-- 可以设置任意数值，包括负数
temperature:set(-5.2)
print(temperature.value)  -- -5.2

-- 可以设置为 0
temperature:set(0)
print(temperature.value)  -- 0
```

### gauge:inc()

将 Gauge 的值增加 1。用于计数场景，如连接建立、任务入队等。

- **参数**: 无
- **返回值**: 无
- **示例**:

```lua validate
local gauge = require "silly.metrics.gauge"

local connections = gauge("active_connections", "Active connections")
connections:set(10)
print(connections.value)  -- 10

-- 新连接建立
connections:inc()
print(connections.value)  -- 11

connections:inc()
print(connections.value)  -- 12

-- 多次调用会累加
for i = 1, 5 do
    connections:inc()
end
print(connections.value)  -- 17
```

### gauge:dec()

将 Gauge 的值减少 1。用于计数场景，如连接关闭、任务出队等。

- **参数**: 无
- **返回值**: 无
- **示例**:

```lua validate
local gauge = require "silly.metrics.gauge"

local queue_size = gauge("queue_size", "Current queue size")
queue_size:set(10)
print(queue_size.value)  -- 10

-- 任务出队
queue_size:dec()
print(queue_size.value)  -- 9

queue_size:dec()
print(queue_size.value)  -- 8

-- 可以减到负数（虽然通常不应该）
for i = 1, 15 do
    queue_size:dec()
end
print(queue_size.value)  -- -7
```

### gauge:add(value)

将 Gauge 的值增加指定数值。支持正数和负数，负数相当于减少。

- **参数**:
  - `value`: `number` - 要增加的数值（可以为负数）
- **返回值**: 无
- **说明**:
  - 注意：源码中 `add()` 方法存在 bug，硬编码为加 1，实际使用时请验证
- **示例**:

```lua validate
local gauge = require "silly.metrics.gauge"

local balance = gauge("account_balance", "Account balance")
balance:set(100)
print(balance.value)  -- 100

-- 增加 50（由于 bug，实际只增加 1）
balance:add(50)
print(balance.value)  -- 101（期望 150，但 bug 导致只加了 1）

-- 再次增加（由于 bug，实际只增加 1）
balance:add(25)
print(balance.value)  -- 102（期望 175，但 bug 导致只加了 1）
```

::: warning 源码 Bug
当前实现中 `add(v)` 方法硬编码为 `self.value = self.value + 1`，忽略了参数 `v`。如果需要增加指定数值，请使用以下替代方案：
- 使用 `gauge:set(gauge.value + v)` 手动增加
- 或直接修改源码：将 `self.value = self.value + 1` 改为 `self.value = self.value + v`
:::

### gauge:sub(value)

将 Gauge 的值减少指定数值。

- **参数**:
  - `value`: `number` - 要减少的数值
- **返回值**: 无
- **示例**:

```lua validate
local gauge = require "silly.metrics.gauge"

local memory = gauge("memory_free_bytes", "Free memory in bytes")
memory:set(1024 * 1024 * 100)  -- 100 MB
print(memory.value)  -- 104857600

-- 减少 10 MB
memory:sub(1024 * 1024 * 10)
print(memory.value)  -- 94371840

-- 减少 20 MB
memory:sub(1024 * 1024 * 20)
print(memory.value)  -- 73400320

-- 可以使用浮点数
memory:sub(1024.5)
print(memory.value)  -- 73399295.5
```

### gaugevec:labels(...)

获取或创建带指定标签值的 Gauge 实例。如果对应的标签组合不存在，会自动创建一个新的 Gauge 实例。

- **参数**:
  - `...`: `string|number` - 标签值，数量和顺序必须与创建时的 `labelnames` 一致
- **返回值**:
  - `gaugesub` - Gauge 子实例，支持 `set()`, `inc()`, `dec()`, `add()`, `sub()` 方法
- **示例**:

```lua validate
local gauge = require "silly.metrics.gauge"

local cpu_usage = gauge(
    "cpu_usage_percent",
    "CPU usage percentage by core",
    {"core"}
)

-- 设置不同 CPU 核心的使用率
cpu_usage:labels("0"):set(45.2)
cpu_usage:labels("1"):set(78.9)
cpu_usage:labels("2"):set(23.5)
cpu_usage:labels("3"):set(56.1)

-- 读取特定标签的值
print(cpu_usage:labels("0").value)  -- 45.2
print(cpu_usage:labels("1").value)  -- 78.9

-- 多个标签
local memory_usage = gauge(
    "memory_usage_bytes",
    "Memory usage by type and pool",
    {"type", "pool"}
)

memory_usage:labels("heap", "default"):set(1024 * 1024 * 100)
memory_usage:labels("heap", "large"):set(1024 * 1024 * 50)
memory_usage:labels("stack", "default"):set(1024 * 1024 * 10)

print(memory_usage:labels("heap", "default").value)  -- 104857600
```

### gaugevec.collect(self, buf)

收集指标数据到缓冲区。此方法主要供内部使用（如 Prometheus Registry），普通用户通常不需要直接调用。

- **参数**:
  - `self`: `gauge` - Gauge 对象
  - `buf`: `table` - 用于收集指标的缓冲区数组
- **返回值**: 无
- **说明**:
  - 将当前 Gauge 对象添加到 `buf` 数组末尾
  - 用于 Prometheus 的 `gather()` 流程
- **示例**:

```lua validate
local gauge = require "silly.metrics.gauge"

local temperature = gauge("temperature_celsius", "Temperature")
temperature:set(25.5)

-- 手动收集指标
local buf = {}
temperature:collect(buf)

print(#buf)  -- 1
print(buf[1].name)  -- "temperature_celsius"
print(buf[1].value)  -- 25.5
print(buf[1].kind)  -- "gauge"
```

## 使用示例

### 示例 1: 监控活跃连接数

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local gauge = require "silly.metrics.gauge"

-- 创建活跃连接计数器
local active_connections = gauge(
    "http_active_connections",
    "Current number of active HTTP connections"
)

silly.fork(function()
    local server = http.listen {
        addr = "0.0.0.0:8080",
        handler = function(stream)
            -- 连接建立，增加计数
            active_connections:inc()
            print("Active connections:", active_connections.value)

            -- 处理请求
            stream:respond(200, {["content-type"] = "text/plain"})
            stream:close("Hello World")

            -- 连接关闭，减少计数
            active_connections:dec()
            print("Active connections:", active_connections.value)
        end
    }

    print("HTTP server listening on :8080")
end)
```

### 示例 2: 监控系统资源使用

```lua validate
local silly = require "silly"
local gauge = require "silly.metrics.gauge"

-- 创建系统资源 Gauge
local memory_usage = gauge(
    "memory_usage_bytes",
    "Memory usage by type",
    {"type"}
)

local cpu_usage = gauge(
    "cpu_usage_percent",
    "CPU usage percentage"
)

local disk_free = gauge(
    "disk_free_bytes",
    "Free disk space by mount point",
    {"mount"}
)

silly.fork(function()
    -- 模拟定期收集系统指标
    while true do
        -- 更新内存使用量
        memory_usage:labels("heap"):set(collectgarbage("count") * 1024)
        memory_usage:labels("rss"):set(1024 * 1024 * 50)  -- 模拟 RSS

        -- 更新 CPU 使用率（模拟）
        cpu_usage:set(math.random(20, 80))

        -- 更新磁盘空间
        disk_free:labels("/"):set(1024 * 1024 * 1024 * 100)
        disk_free:labels("/data"):set(1024 * 1024 * 1024 * 500)

        print("Memory (heap):", memory_usage:labels("heap").value)
        print("CPU usage:", cpu_usage.value, "%")
        print("Disk free (/):", disk_free:labels("/").value)

        silly.time.sleep(5000)  -- 每 5 秒更新一次
    end
end)
```

### 示例 3: 监控队列深度

```lua validate
local gauge = require "silly.metrics.gauge"

-- 消息队列深度监控
local queue_depth = gauge(
    "message_queue_depth",
    "Number of messages in queue",
    {"queue", "priority"}
)

-- 初始化队列
queue_depth:labels("orders", "high"):set(0)
queue_depth:labels("orders", "low"):set(0)
queue_depth:labels("notifications", "high"):set(0)
queue_depth:labels("notifications", "low"):set(0)

-- 模拟消息入队
for i = 1, 10 do
    queue_depth:labels("orders", "high"):inc()
end

for i = 1, 25 do
    queue_depth:labels("orders", "low"):inc()
end

for i = 1, 5 do
    queue_depth:labels("notifications", "high"):inc()
end

print("Orders (high):", queue_depth:labels("orders", "high").value)  -- 10
print("Orders (low):", queue_depth:labels("orders", "low").value)    -- 25
print("Notifications (high):", queue_depth:labels("notifications", "high").value)  -- 5

-- 模拟消息出队
for i = 1, 3 do
    queue_depth:labels("orders", "high"):dec()
end

print("Orders (high) after dequeue:", queue_depth:labels("orders", "high").value)  -- 7
```

### 示例 4: 监控温度传感器

```lua validate
local silly = require "silly"
local gauge = require "silly.metrics.gauge"

-- 创建温度传感器 Gauge
local temperature = gauge(
    "room_temperature_celsius",
    "Room temperature in Celsius",
    {"location", "sensor"}
)

silly.fork(function()
    -- 模拟多个传感器读数
    local locations = {
        {location = "server_room", sensor = "front", base = 22},
        {location = "server_room", sensor = "back", base = 25},
        {location = "office", sensor = "desk1", base = 20},
        {location = "office", sensor = "desk2", base = 21},
    }

    while true do
        -- 更新所有传感器读数
        for _, sensor in ipairs(locations) do
            local temp = sensor.base + math.random(-2, 2) + math.random()
            temperature:labels(sensor.location, sensor.sensor):set(temp)

            print(string.format(
                "%s/%s: %.2f°C",
                sensor.location,
                sensor.sensor,
                temperature:labels(sensor.location, sensor.sensor).value
            ))
        end

        silly.time.sleep(2000)  -- 每 2 秒读取一次
    end
end)
```

### 示例 5: 监控数据库连接池

```lua validate
local gauge = require "silly.metrics.gauge"

-- 数据库连接池监控
local db_connections = gauge(
    "db_connections",
    "Database connections by state",
    {"pool", "state"}
)

local db_wait_time = gauge(
    "db_connection_wait_time_seconds",
    "Time waiting for available connection",
    {"pool"}
)

-- 初始化连接池状态
local pools = {
    {name = "primary", total = 10, active = 2},
    {name = "replica", total = 20, active = 8},
}

for _, pool in ipairs(pools) do
    db_connections:labels(pool.name, "idle"):set(pool.total - pool.active)
    db_connections:labels(pool.name, "active"):set(pool.active)
    db_connections:labels(pool.name, "total"):set(pool.total)
    db_wait_time:labels(pool.name):set(0)
end

-- 模拟获取连接
local function acquire_connection(pool_name)
    local idle = db_connections:labels(pool_name, "idle")
    local active = db_connections:labels(pool_name, "active")

    if idle.value > 0 then
        idle:dec()
        active:inc()
        print(pool_name, "- Acquired connection (idle:", idle.value, "active:", active.value, ")")
    else
        print(pool_name, "- No idle connections, waiting...")
        -- 注意：由于 add() 有 bug，使用 set() 手动增加
        local wait = db_wait_time:labels(pool_name)
        wait:set(wait.value + 0.1)
    end
end

-- 模拟释放连接
local function release_connection(pool_name)
    local idle = db_connections:labels(pool_name, "idle")
    local active = db_connections:labels(pool_name, "active")

    if active.value > 0 then
        active:dec()
        idle:inc()
        print(pool_name, "- Released connection (idle:", idle.value, "active:", active.value, ")")
    end
end

-- 测试连接池操作
acquire_connection("primary")
acquire_connection("primary")
acquire_connection("replica")
release_connection("primary")
```

### 示例 6: 监控缓存状态

```lua validate
local gauge = require "silly.metrics.gauge"

-- 缓存监控
local cache_size_bytes = gauge(
    "cache_size_bytes",
    "Cache size in bytes",
    {"cache"}
)

local cache_items = gauge(
    "cache_items_total",
    "Number of items in cache",
    {"cache"}
)

local cache_hit_ratio = gauge(
    "cache_hit_ratio",
    "Cache hit ratio",
    {"cache"}
)

-- 初始化缓存状态
cache_size_bytes:labels("user_session"):set(1024 * 1024 * 50)
cache_items:labels("user_session"):set(1234)
cache_hit_ratio:labels("user_session"):set(0.95)

cache_size_bytes:labels("api_response"):set(1024 * 1024 * 100)
cache_items:labels("api_response"):set(5678)
cache_hit_ratio:labels("api_response"):set(0.88)

-- 模拟缓存操作
local function cache_put(cache_name, item_size)
    -- 注意：由于 add() 有 bug，使用 set() 手动增加
    local size = cache_size_bytes:labels(cache_name)
    size:set(size.value + item_size)
    cache_items:labels(cache_name):inc()
end

local function cache_delete(cache_name, item_size)
    cache_size_bytes:labels(cache_name):sub(item_size)
    cache_items:labels(cache_name):dec()
end

-- 添加缓存项
cache_put("user_session", 1024)
print("Session cache items:", cache_items:labels("user_session").value)  -- 1235

-- 删除缓存项
cache_delete("user_session", 1024)
print("Session cache items:", cache_items:labels("user_session").value)  -- 1234
```

### 示例 7: 监控业务指标

```lua validate
local gauge = require "silly.metrics.gauge"

-- 业务指标监控
local active_users = gauge(
    "active_users",
    "Currently active users",
    {"platform"}
)

local inventory_quantity = gauge(
    "inventory_quantity",
    "Product inventory quantity",
    {"product", "warehouse"}
)

local wallet_balance = gauge(
    "wallet_balance_cents",
    "User wallet balance in cents",
    {"currency"}
)

-- 设置活跃用户数
active_users:labels("web"):set(3245)
active_users:labels("mobile"):set(8976)
active_users:labels("desktop"):set(456)

print("Total active users:",
    active_users:labels("web").value +
    active_users:labels("mobile").value +
    active_users:labels("desktop").value
)

-- 设置库存数量
inventory_quantity:labels("phone_x", "beijing"):set(1250)
inventory_quantity:labels("phone_x", "shanghai"):set(890)
inventory_quantity:labels("laptop_y", "beijing"):set(340)

print("Phone X total inventory:",
    inventory_quantity:labels("phone_x", "beijing").value +
    inventory_quantity:labels("phone_x", "shanghai").value
)

-- 钱包余额
wallet_balance:labels("USD"):set(1000000)
wallet_balance:labels("EUR"):set(850000)

print("USD balance:", wallet_balance:labels("USD").value, "cents")
```

### 示例 8: 监控任务调度器

```lua validate
local silly = require "silly"
local gauge = require "silly.metrics.gauge"

-- 任务调度器监控
local tasks_pending = gauge(
    "tasks_pending",
    "Number of pending tasks",
    {"type", "priority"}
)

local tasks_running = gauge(
    "tasks_running",
    "Number of running tasks",
    {"type"}
)

local scheduler_queue_depth = gauge(
    "scheduler_queue_depth",
    "Scheduler queue depth"
)

silly.fork(function()
    -- 初始化任务状态
    local task_types = {"backup", "cleanup", "report", "sync"}
    local priorities = {"high", "normal", "low"}

    for _, task_type in ipairs(task_types) do
        for _, priority in ipairs(priorities) do
            tasks_pending:labels(task_type, priority):set(0)
        end
        tasks_running:labels(task_type):set(0)
    end

    scheduler_queue_depth:set(0)

    -- 模拟任务调度
    for i = 1, 20 do
        local task_type = task_types[math.random(#task_types)]
        local priority = priorities[math.random(#priorities)]

        -- 任务加入队列
        tasks_pending:labels(task_type, priority):inc()
        scheduler_queue_depth:inc()

        print(string.format(
            "Task queued: %s/%s (pending: %d, queue depth: %d)",
            task_type,
            priority,
            tasks_pending:labels(task_type, priority).value,
            scheduler_queue_depth.value
        ))

        silly.time.sleep(100)

        -- 任务开始执行
        if math.random() > 0.3 then
            tasks_pending:labels(task_type, priority):dec()
            tasks_running:labels(task_type):inc()
            scheduler_queue_depth:dec()

            print(string.format(
                "Task started: %s (running: %d)",
                task_type,
                tasks_running:labels(task_type).value
            ))

            -- 任务完成
            silly.time.sleep(math.random(200, 1000))
            tasks_running:labels(task_type):dec()

            print(string.format(
                "Task completed: %s (running: %d)",
                task_type,
                tasks_running:labels(task_type).value
            ))
        end
    end
end)
```

## 注意事项

### Gauge 的正确使用

1. **选择合适的指标类型**：
   - 如果值可以上下波动（如内存使用量、连接数），使用 **Gauge**
   - 如果值只能递增（如请求总数），使用 **Counter**
   - 如果需要统计分布（如延迟），使用 **Histogram**

2. **避免滥用 Gauge**：
   ```lua
   -- 错误：用 Gauge 统计请求总数
   local requests = gauge("requests", "Total requests")
   requests:inc()  -- 应该使用 Counter

   -- 正确：用 Gauge 表示当前状态
   local active_requests = gauge("active_requests", "Active requests")
   active_requests:inc()  -- 请求开始
   active_requests:dec()  -- 请求结束
   ```

3. **确保 inc/dec 配对**：
   ```lua
   local connections = gauge("connections", "Active connections")

   -- 连接建立
   connections:inc()

   -- 处理逻辑...

   -- 连接关闭（必须对应 dec）
   connections:dec()

   -- 如果忘记 dec，计数会越来越大且不准确
   ```

### 标签使用建议

1. **避免高基数标签**：
   ```lua
   -- 错误：用户 ID 会导致数百万个时间序列
   local user_status = gauge("user_status", "User status", {"user_id"})
   user_status:labels("12345"):set(1)  -- 不要这样做！

   -- 正确：使用有限的分类
   local users_by_status = gauge("users_by_status", "Users by status", {"status"})
   users_by_status:labels("online"):inc()
   users_by_status:labels("offline"):dec()
   ```

2. **标签顺序一致性**：
   ```lua
   local memory = gauge("memory_usage", "Memory usage", {"type", "pool"})

   -- 正确
   memory:labels("heap", "default"):set(100)

   -- 错误：顺序颠倒
   -- memory:labels("default", "heap"):set(100)  -- 会创建不同的时间序列！
   ```

3. **标签值规范化**：
   ```lua
   -- 使用小写和下划线
   connections:labels("http_1_1", "established")  -- 好

   -- 避免动态生成的值
   -- connections:labels("HTTP/1.1", "Established")  -- 不好
   ```

### 性能考虑

1. **避免频繁创建新标签组合**：
   ```lua
   -- 不好：每次循环创建新的标签组合
   for i = 1, 1000000 do
       gauge:labels(tostring(i)):set(100)  -- 创建 100 万个时间序列！
   end

   -- 好：使用固定的标签值
   for i = 1, 1000000 do
       local pool = (i % 10) + 1
       gauge:labels("pool_" .. pool):inc()  -- 只有 10 个时间序列
   end
   ```

2. **初始化标签组合**：
   ```lua
   -- 推荐：提前初始化所有可能的标签组合
   local states = {"idle", "active", "waiting"}
   for _, state in ipairs(states) do
       connections:labels(state):set(0)
   end

   -- 后续使用时不会触发新对象创建
   connections:labels("idle"):inc()
   connections:labels("active"):inc()
   ```

3. **避免在热路径上操作 Gauge**：
   ```lua
   -- 如果操作非常频繁（每秒数万次），考虑批量更新
   local count = 0
   for i = 1, 10000 do
       count = count + 1  -- 先累积
   end
   gauge:add(count)  -- 批量更新
   ```

### 源码 Bug 注意

当前实现中 `add(v)` 方法存在 bug：

```lua
-- 源码第 31-33 行
function M:add(v)
    self.value = self.value + 1  -- 硬编码为 +1，忽略了参数 v
end
```

**解决方案**：
- 直接使用 `gauge:set(gauge.value + v)`
- 或使用 `inc()` 和 `dec()` 代替
- 等待框架修复后使用 `add(v)`

### 线程安全

- Silly 框架使用单线程事件循环，Gauge 操作无需考虑并发问题
- 所有 Gauge 操作都在 Worker 线程中执行
- 如果使用多进程架构，每个进程维护独立的 Gauge 实例

### 与 Prometheus 集成

使用 `silly.metrics.prometheus` 自动注册和导出：

```lua
local prometheus = require "silly.metrics.prometheus"

-- 通过 prometheus 创建会自动注册
local gauge = prometheus.gauge("my_gauge", "My gauge", {"label"})
gauge:labels("value1"):set(100)

-- 导出指标
local metrics = prometheus.gather()
-- 输出：
-- # HELP my_gauge My gauge
-- # TYPE my_gauge gauge
-- my_gauge{label="value1"}	100
```

**PromQL 查询示例**：

```promql
# 查看当前值
my_gauge{label="value1"}

# 计算平均值
avg(my_gauge)

# 查找最大值
max(my_gauge)

# 按标签分组求和
sum by (label) (my_gauge)
```

## 参见

- [silly.metrics.prometheus](./prometheus.md) - Prometheus 指标导出模块
- [silly.metrics.counter](./counter.md) - Counter 计数器指标
- [silly.metrics.histogram](./histogram.md) - Histogram 直方图指标
- [Prometheus Gauge 文档](https://prometheus.io/docs/concepts/metric_types/#gauge)
