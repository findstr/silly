---
title: silly.metrics.prometheus
description: Prometheus 集成模块 - 提供便捷的 Prometheus 指标收集和导出接口
---

# silly.metrics.prometheus

`silly.metrics.prometheus` 是 Silly 框架的 Prometheus 集成模块，提供了便捷的指标创建、注册和收集接口。该模块是对底层 `counter`、`gauge` 和 `histogram` 模块的聚合封装，自动管理指标注册，并提供符合 Prometheus 文本格式的数据导出功能。

## 模块特点

- **自动注册**: 创建的指标自动注册到全局注册表
- **统一接口**: 统一的 API 风格，简化指标管理
- **内置收集器**: 自动注册框架级指标（Silly 运行时、进程资源、JeMalloc 内存等）
- **格式化输出**: 直接生成符合 Prometheus 文本格式的指标数据
- **零依赖**: 无需外部依赖，开箱即用

## 核心概念

### Prometheus 作为聚合模块

`prometheus` 模块是一个便捷封装层，它聚合了以下底层模块：

- **`silly.metrics.counter`**: Counter 指标的底层实现
- **`silly.metrics.gauge`**: Gauge 指标的底层实现
- **`silly.metrics.histogram`**: Histogram 指标的底层实现
- **`silly.metrics.registry`**: 指标注册表的管理

主要区别：

| 特性 | prometheus 模块 | 底层模块 |
|------|----------------|---------|
| 注册方式 | 自动注册到全局表 | 需手动注册 |
| 使用场景 | 标准使用场景 | 高级自定义场景 |
| 代码简洁性 | 更简洁 | 更灵活 |

**使用 prometheus 模块（推荐）**：
```lua
local prometheus = require "silly.metrics.prometheus"
local counter = prometheus.counter("requests_total", "Total requests")
counter:inc()
-- 自动注册，gather() 会包含此指标
```

**使用底层模块（高级场景）**：
```lua
local counter = require "silly.metrics.counter"
local registry = require "silly.metrics.registry"
local my_counter = counter("requests_total", "Total requests")
local my_registry = registry.new()
my_registry:register(my_counter)
-- 需要手动管理注册表
```

### Registry（注册表）

`prometheus` 模块维护一个全局的指标注册表，所有通过 `prometheus.counter()`、`prometheus.gauge()` 和 `prometheus.histogram()` 创建的指标都会自动注册到该表中。可以通过 `prometheus.registry()` 获取该注册表进行高级操作。

### Collector（收集器）

模块自动注册以下内置收集器：

#### 1. Silly Collector
框架运行时指标：
- `silly_worker_backlog`: Worker 队列待处理消息数
- `silly_timer_pending`: 待触发定时器数量
- `silly_timer_scheduled_total`: 已调度定时器总数
- `silly_timer_fired_total`: 已触发定时器总数
- `silly_timer_canceled_total`: 已取消定时器总数
- `silly_tasks_runnable`: 可运行任务数量
- `silly_tcp_connections`: 活跃 TCP 连接数
- `silly_socket_requests_total`: Socket 操作请求总数
- `silly_socket_processed_total`: 已处理 Socket 操作总数
- `silly_network_sent_bytes_total`: 网络发送字节总数
- `silly_network_received_bytes_total`: 网络接收字节总数

#### 2. Process Collector
进程资源指标：
- `process_cpu_seconds_user`: 用户态 CPU 时间（秒）
- `process_cpu_seconds_system`: 内核态 CPU 时间（秒）
- `process_resident_memory_bytes`: 常驻内存大小（字节）
- `process_heap_bytes`: 堆内存大小（字节）

#### 3. JeMalloc Collector（可选）
当使用 JeMalloc 时自动启用，提供内存分配器统计。

### Gather（指标收集）

`gather()` 函数会调用所有已注册收集器的 `collect()` 方法，收集指标数据并格式化为 Prometheus 文本格式（Text Format 0.0.4）。

## API 参考

### prometheus.counter()

创建并自动注册一个 Counter 指标。Counter 是只增不减的累加器，适合统计请求总数、错误次数等。

**函数签名**

```lua
function prometheus.counter(name, help, labels)
  -> counter
```

**参数**

- `name` (string): 指标名称，必须符合 Prometheus 命名规范（`[a-zA-Z_:][a-zA-Z0-9_:]*`）
- `help` (string): 指标描述信息，用于 Prometheus UI 展示
- `labels` (table?): 标签名称数组，可选。如果提供，返回的是 CounterVec

**返回值**

- 返回 `silly.metrics.counter` 或 `silly.metrics.countervec` 对象，已自动注册到全局注册表

**示例**

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- 创建无标签的 Counter
local requests = prometheus.counter(
  "http_requests_total",
  "Total number of HTTP requests"
)
requests:inc()  -- 增加 1
requests:add(5) -- 增加 5

-- 创建带标签的 CounterVec
local errors = prometheus.counter(
  "http_errors_total",
  "Total number of HTTP errors",
  {"method", "status"}
)
errors:labels("GET", "404"):inc()
errors:labels("POST", "500"):add(2)
```

### prometheus.gauge()

创建并自动注册一个 Gauge 指标。Gauge 是可增可减的仪表盘，适合统计当前活跃连接数、温度、内存使用量等瞬时值。

**函数签名**

```lua
function prometheus.gauge(name, help, labels)
  -> gauge
```

**参数**

- `name` (string): 指标名称，必须符合 Prometheus 命名规范
- `help` (string): 指标描述信息
- `labels` (table?): 标签名称数组，可选。如果提供，返回的是 GaugeVec

**返回值**

- 返回 `silly.metrics.gauge` 或 `silly.metrics.gaugevec` 对象，已自动注册到全局注册表

**示例**

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- 创建无标签的 Gauge
local active = prometheus.gauge(
  "http_active_connections",
  "Current number of active HTTP connections"
)
active:set(100) -- 设置为 100
active:inc()    -- 增加 1
active:dec()    -- 减少 1
active:add(5)   -- 增加 5
active:sub(3)   -- 减少 3

-- 创建带标签的 GaugeVec
local temperature = prometheus.gauge(
  "server_temperature_celsius",
  "Server room temperature in Celsius",
  {"location"}
)
temperature:labels("datacenter1"):set(25.5)
temperature:labels("datacenter2"):set(27.3)
```

### prometheus.histogram()

创建并自动注册一个 Histogram 指标。Histogram 用于统计数据分布，适合统计请求延迟、响应大小等需要分位数分析的场景。

**函数签名**

```lua
function prometheus.histogram(name, help, labels, buckets)
  -> histogram
```

**参数**

- `name` (string): 指标名称，必须符合 Prometheus 命名规范
- `help` (string): 指标描述信息
- `labels` (table?): 标签名称数组，可选。如果提供，返回的是 HistogramVec
- `buckets` (table?): 桶边界数组，可选。默认为 `{0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0}`

**返回值**

- 返回 `silly.metrics.histogram` 或 `silly.metrics.histogramvec` 对象，已自动注册到全局注册表

**示例**

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- 使用默认桶的 Histogram
local latency = prometheus.histogram(
  "http_request_duration_seconds",
  "HTTP request latency in seconds"
)
latency:observe(0.023) -- 记录一次 23ms 的请求

-- 使用自定义桶的 HistogramVec
local response_size = prometheus.histogram(
  "http_response_size_bytes",
  "HTTP response size in bytes",
  {"method"},
  {100, 500, 1000, 5000, 10000}
)
response_size:labels("GET"):observe(1234)
response_size:labels("POST"):observe(5678)
```

### prometheus.registry()

获取全局注册表对象。用于高级场景，如手动注册自定义收集器或注销指标。

**函数签名**

```lua
function prometheus.registry()
  -> registry
```

**返回值**

- 返回全局 `silly.metrics.registry` 对象

**示例**

```lua validate
local prometheus = require "silly.metrics.prometheus"
local counter = require "silly.metrics.counter"

-- 获取全局注册表
local registry = prometheus.registry()

-- 手动创建并注册指标
local manual_counter = counter("manual_metric_total", "A manually registered metric")
registry:register(manual_counter)

-- 手动注销指标
registry:unregister(manual_counter)

-- 注册自定义收集器
local custom_collector = {
  collect = function(self, buf)
    buf[#buf + 1] = {
      name = "custom_metric",
      help = "A custom metric",
      kind = "gauge",
      value = 100
    }
  end
}
registry:register(custom_collector)
```

### prometheus.gather()

收集所有已注册指标的当前值，并格式化为 Prometheus 文本格式。该函数会调用所有注册的收集器（包括内置收集器和用户创建的指标）。

**函数签名**

```lua
function prometheus.gather()
  -> string
```

**返回值**

- 返回符合 Prometheus 文本格式（Text Format 0.0.4）的字符串

**输出格式**

```text
# HELP metric_name metric description
# TYPE metric_name metric_type
metric_name{label1="value1"} value

# Histogram 格式：
metric_name_bucket{le="0.005"} count
metric_name_bucket{le="+Inf"} total_count
metric_name_sum total_sum
metric_name_count total_count
```

**示例**

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- 创建一些指标
local requests = prometheus.counter("app_requests_total", "Total requests")
local active = prometheus.gauge("app_active_users", "Active users")

requests:inc()
active:set(42)

-- 收集并输出
local metrics_text = prometheus.gather()
-- 输出类似：
-- # HELP app_requests_total Total requests
-- # TYPE app_requests_total counter
-- app_requests_total	1
-- # HELP app_active_users Active users
-- # TYPE app_active_users gauge
-- app_active_users	42
-- ... (以及内置收集器的指标)
```

## 使用示例

### 示例 1: HTTP Metrics Endpoint

最常见的使用场景：创建 `/metrics` 端点供 Prometheus 抓取。

```lua validate
local http = require "silly.net.http"
local prometheus = require "silly.metrics.prometheus"

-- 创建业务指标
local http_requests = prometheus.counter(
  "http_requests_total",
  "Total HTTP requests",
  {"method", "path", "status"}
)

local http_duration = prometheus.histogram(
  "http_request_duration_seconds",
  "HTTP request latency"
)

-- 启动 HTTP 服务器
local server = http.listen {
  addr = "0.0.0.0:8080",
  handler = function(stream)
    local start = os.clock()

    if stream.path == "/metrics" then
      -- Prometheus 抓取端点
      local metrics = prometheus.gather()
      stream:respond(200, {
        ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
        ["content-length"] = #metrics,
      })
      stream:closewrite(metrics)
    else
      -- 业务逻辑
      stream:respond(200, {["content-type"] = "text/plain"})
      stream:closewrite("Hello World")

      -- 记录指标
      local duration = os.clock() - start
      http_duration:observe(duration)
      http_requests:labels(stream.method, stream.path, "200"):inc()
    end
  end
}
```

### 示例 2: 完整的 Web 应用监控

结合多种指标类型监控 Web 应用的各个方面。

```lua validate
local http = require "silly.net.http"
local prometheus = require "silly.metrics.prometheus"

-- 定义指标
local requests_total = prometheus.counter(
  "myapp_http_requests_total",
  "Total HTTP requests received",
  {"method", "endpoint", "status"}
)

local requests_in_flight = prometheus.gauge(
  "myapp_http_requests_in_flight",
  "Current number of HTTP requests being processed"
)

local request_duration = prometheus.histogram(
  "myapp_http_request_duration_seconds",
  "HTTP request latency in seconds",
  {"method", "endpoint"},
  {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0}
)

local request_size = prometheus.histogram(
  "myapp_http_request_size_bytes",
  "HTTP request size in bytes",
  nil,
  {100, 1000, 10000, 100000, 1000000}
)

local response_size = prometheus.histogram(
  "myapp_http_response_size_bytes",
  "HTTP response size in bytes",
  nil,
  {100, 1000, 10000, 100000, 1000000}
)

-- HTTP 处理器
local server = http.listen {
  addr = "0.0.0.0:8080",
  handler = function(stream)
    local start = os.clock()
    requests_in_flight:inc()

    -- 处理 metrics 端点
    if stream.path == "/metrics" then
      local metrics = prometheus.gather()
      stream:respond(200, {
        ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
      })
      stream:closewrite(metrics)
      requests_in_flight:dec()
      return
    end

    -- 记录请求大小
    local req_size = stream.header["content-length"] or 0
    request_size:observe(tonumber(req_size))

    -- 业务逻辑
    local response_data = "Response data"
    stream:respond(200, {["content-type"] = "text/plain"})
    stream:closewrite(response_data)

    -- 记录响应指标
    local duration = os.clock() - start
    response_size:observe(#response_data)
    request_duration:labels(stream.method, stream.path):observe(duration)
    requests_total:labels(stream.method, stream.path, "200"):inc()
    requests_in_flight:dec()
  end
}
```

### 示例 3: 业务指标监控

监控业务层面的关键指标。

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- 用户相关指标
local user_logins = prometheus.counter(
  "business_user_logins_total",
  "Total number of user logins",
  {"source"}
)

local active_sessions = prometheus.gauge(
  "business_active_sessions",
  "Number of active user sessions"
)

local user_balance = prometheus.histogram(
  "business_user_balance",
  "User account balance distribution",
  nil,
  {0, 100, 500, 1000, 5000, 10000, 50000}
)

-- 订单相关指标
local orders_total = prometheus.counter(
  "business_orders_total",
  "Total number of orders",
  {"status", "payment_method"}
)

local order_amount = prometheus.histogram(
  "business_order_amount",
  "Order amount distribution",
  {"currency"},
  {10, 50, 100, 500, 1000, 5000}
)

-- 业务逻辑示例
local function handle_user_login(source)
  user_logins:labels(source):inc()
  active_sessions:inc()
end

local function handle_user_logout()
  active_sessions:dec()
end

local function handle_order(status, method, amount, currency)
  orders_total:labels(status, method):inc()
  order_amount:labels(currency):observe(amount)
end

-- 模拟业务操作
handle_user_login("web")
handle_user_login("mobile")
handle_order("completed", "credit_card", 199.99, "USD")
handle_order("pending", "paypal", 49.99, "EUR")
```

### 示例 4: 定时任务监控

监控定时任务的执行情况。

```lua validate
local time = require "silly.time"
local prometheus = require "silly.metrics.prometheus"

-- 定时任务指标
local job_runs = prometheus.counter(
  "cronjob_runs_total",
  "Total number of cron job executions",
  {"job_name", "status"}
)

local job_duration = prometheus.histogram(
  "cronjob_duration_seconds",
  "Cron job execution duration",
  {"job_name"},
  {0.1, 0.5, 1, 5, 10, 30, 60, 300}
)

local job_last_success = prometheus.gauge(
  "cronjob_last_success_timestamp",
  "Timestamp of last successful execution",
  {"job_name"}
)

-- 任务执行包装器
local function run_job(name, func)
  local start = os.clock()
  local success, err = pcall(func)
  local duration = os.clock() - start

  job_duration:labels(name):observe(duration)

  if success then
    job_runs:labels(name, "success"):inc()
    job_last_success:labels(name):set(os.time())
  else
    job_runs:labels(name, "failure"):inc()
  end
end

-- 定时任务示例
local function data_cleanup_job()
  -- 清理逻辑
  time.sleep(100)
end

local function backup_job()
  -- 备份逻辑
  time.sleep(200)
end

-- 每 5 秒执行一次
run_job("data_cleanup", data_cleanup_job)
run_job("backup", backup_job)
```

### 示例 5: 数据库连接池监控

监控数据库连接池的状态。

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- 连接池指标
local db_connections_total = prometheus.gauge(
  "db_pool_connections_total",
  "Total number of database connections",
  {"pool", "state"}
)

local db_queries_total = prometheus.counter(
  "db_queries_total",
  "Total number of database queries",
  {"pool", "operation", "status"}
)

local db_query_duration = prometheus.histogram(
  "db_query_duration_seconds",
  "Database query duration",
  {"pool", "operation"},
  {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0}
)

-- 模拟连接池管理
local ConnectionPool = {}
local ConnectionPool_mt = {__index = ConnectionPool}

function ConnectionPool.new(name, size)
  local pool = {
    name = name,
    idle = size,
    active = 0,
    total = size,
  }
  return setmetatable(pool, ConnectionPool_mt)
end

function ConnectionPool:acquire()
  if self.idle > 0 then
    self.idle = self.idle - 1
    self.active = self.active + 1

    db_connections_total:labels(self.name, "idle"):set(self.idle)
    db_connections_total:labels(self.name, "active"):set(self.active)
    return true
  end
  return false
end

function ConnectionPool:release()
  if self.active > 0 then
    self.active = self.active - 1
    self.idle = self.idle + 1

    db_connections_total:labels(self.name, "idle"):set(self.idle)
    db_connections_total:labels(self.name, "active"):set(self.active)
  end
end

function ConnectionPool:execute(operation, func)
  if not self:acquire() then
    db_queries_total:labels(self.name, operation, "no_connection"):inc()
    return nil, "no available connection"
  end

  local start = os.clock()
  local success, result = pcall(func)
  local duration = os.clock() - start

  db_query_duration:labels(self.name, operation):observe(duration)

  if success then
    db_queries_total:labels(self.name, operation, "success"):inc()
  else
    db_queries_total:labels(self.name, operation, "error"):inc()
  end

  self:release()
  return success and result or nil, result
end

-- 使用示例
local pool = ConnectionPool.new("postgres_main", 10)

pool:execute("select", function()
  -- 模拟查询
  return "result"
end)

pool:execute("insert", function()
  -- 模拟插入
  return true
end)
```

### 示例 6: 缓存性能监控

监控缓存的命中率和性能。

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- 缓存指标
local cache_operations = prometheus.counter(
  "cache_operations_total",
  "Total number of cache operations",
  {"cache", "operation", "result"}
)

local cache_size = prometheus.gauge(
  "cache_size_entries",
  "Current number of entries in cache",
  {"cache"}
)

local cache_memory = prometheus.gauge(
  "cache_memory_bytes",
  "Estimated cache memory usage",
  {"cache"}
)

local cache_operation_duration = prometheus.histogram(
  "cache_operation_duration_seconds",
  "Cache operation duration",
  {"cache", "operation"},
  {0.00001, 0.0001, 0.001, 0.01, 0.1}
)

-- 简单缓存实现
local Cache = {}
local Cache_mt = {__index = Cache}

function Cache.new(name)
  cache_size:labels(name):set(0)
  cache_memory:labels(name):set(0)

  local c = {
    name = name,
    data = {},
    size = 0,
  }
  return setmetatable(c, Cache_mt)
end

function Cache:get(key)
  local start = os.clock()
  local value = self.data[key]
  local duration = os.clock() - start

  cache_operation_duration:labels(self.name, "get"):observe(duration)

  if value then
    cache_operations:labels(self.name, "get", "hit"):inc()
    return value
  else
    cache_operations:labels(self.name, "get", "miss"):inc()
    return nil
  end
end

function Cache:set(key, value)
  local start = os.clock()
  local is_new = self.data[key] == nil
  self.data[key] = value
  local duration = os.clock() - start

  if is_new then
    self.size = self.size + 1
    cache_size:labels(self.name):set(self.size)
  end

  cache_operation_duration:labels(self.name, "set"):observe(duration)
  cache_operations:labels(self.name, "set", "success"):inc()
end

function Cache:delete(key)
  local start = os.clock()
  if self.data[key] then
    self.data[key] = nil
    self.size = self.size - 1
    cache_size:labels(self.name):set(self.size)
    cache_operations:labels(self.name, "delete", "success"):inc()
  else
    cache_operations:labels(self.name, "delete", "not_found"):inc()
  end
  local duration = os.clock() - start
  cache_operation_duration:labels(self.name, "delete"):observe(duration)
end

-- 使用示例
local user_cache = Cache.new("users")
user_cache:set("user:1", {name = "Alice", age = 30})
user_cache:get("user:1")  -- hit
user_cache:get("user:2")  -- miss
user_cache:delete("user:1")
```

### 示例 7: 队列监控

监控消息队列的吞吐量和延迟。

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- 队列指标
local queue_depth = prometheus.gauge(
  "queue_depth",
  "Current number of messages in queue",
  {"queue"}
)

local queue_enqueued = prometheus.counter(
  "queue_messages_enqueued_total",
  "Total number of messages enqueued",
  {"queue"}
)

local queue_dequeued = prometheus.counter(
  "queue_messages_dequeued_total",
  "Total number of messages dequeued",
  {"queue", "status"}
)

local queue_processing_duration = prometheus.histogram(
  "queue_message_processing_duration_seconds",
  "Message processing duration",
  {"queue"},
  {0.001, 0.01, 0.1, 1, 10}
)

local queue_wait_duration = prometheus.histogram(
  "queue_message_wait_duration_seconds",
  "Time message spent in queue",
  {"queue"},
  {0.1, 1, 10, 60, 300}
)

-- 简单队列实现
local Queue = {}
local Queue_mt = {__index = Queue}

function Queue.new(name)
  queue_depth:labels(name):set(0)

  local q = {
    name = name,
    messages = {},
    head = 1,
    tail = 0,
  }
  return setmetatable(q, Queue_mt)
end

function Queue:enqueue(message)
  self.tail = self.tail + 1
  self.messages[self.tail] = {
    data = message,
    enqueue_time = os.time(),
  }

  local depth = self.tail - self.head + 1
  queue_depth:labels(self.name):set(depth)
  queue_enqueued:labels(self.name):inc()
end

function Queue:dequeue()
  if self.head > self.tail then
    return nil
  end

  local item = self.messages[self.head]
  self.messages[self.head] = nil
  self.head = self.head + 1

  local depth = self.tail - self.head + 1
  queue_depth:labels(self.name):set(depth)

  -- 记录等待时间
  local wait_duration = os.time() - item.enqueue_time
  queue_wait_duration:labels(self.name):observe(wait_duration)

  return item.data
end

function Queue:process_message(handler)
  local message = self:dequeue()
  if not message then
    return false
  end

  local start = os.clock()
  local success, err = pcall(handler, message)
  local duration = os.clock() - start

  queue_processing_duration:labels(self.name):observe(duration)

  if success then
    queue_dequeued:labels(self.name, "success"):inc()
  else
    queue_dequeued:labels(self.name, "error"):inc()
  end

  return true
end

-- 使用示例
local job_queue = Queue.new("background_jobs")

-- 入队消息
job_queue:enqueue({type = "email", to = "user@example.com"})
job_queue:enqueue({type = "notification", message = "Hello"})

-- 处理消息
job_queue:process_message(function(msg)
  -- 处理逻辑
end)
```

### 示例 8: 多服务聚合监控

在微服务架构中，为不同服务提供统一的监控。

```lua validate
local http = require "silly.net.http"
local prometheus = require "silly.metrics.prometheus"

-- 服务级指标（带 service 标签）
local service_requests = prometheus.counter(
  "service_requests_total",
  "Total requests per service",
  {"service", "endpoint", "status"}
)

local service_errors = prometheus.counter(
  "service_errors_total",
  "Total errors per service",
  {"service", "error_type"}
)

local service_health = prometheus.gauge(
  "service_health_status",
  "Service health status (1=healthy, 0=unhealthy)",
  {"service"}
)

local service_dependencies = prometheus.gauge(
  "service_dependency_status",
  "Dependency health status",
  {"service", "dependency"}
)

-- 服务抽象
local Service = {}
local service_mt = { __index = Service }
function Service.new(name)
  service_health:labels(name):set(1)

  return setmetatable({
    name = name,
    dependencies = {},
  }, service_mt)
end

function Service:add_dependency(dep_name, check_func)
  self.dependencies[dep_name] = check_func
end

function Service:check_dependencies()
  for dep_name, check_func in pairs(self.dependencies) do
    local healthy = check_func()
    service_dependencies:labels(self.name, dep_name):set(healthy and 1 or 0)
  end
end

function Service:handle_request(endpoint, handler)
  local start = os.clock()
  local success, result, status = pcall(handler)

  if success then
    service_requests:labels(self.name, endpoint, status or "200"):inc()
    return result
  else
    service_requests:labels(self.name, endpoint, "500"):inc()
    service_errors:labels(self.name, "request_error"):inc()
    service_health:labels(self.name):set(0)
    return nil, result
  end
end

-- 使用示例
local user_service = Service.new("user_service")
user_service:add_dependency("database", function()
  return true  -- 实际应检查数据库连接
end)
user_service:add_dependency("cache", function()
  return true  -- 实际应检查缓存连接
end)

-- 处理请求
user_service:handle_request("/users", function()
  return {users = {}}, "200"
end)

-- 定期健康检查
user_service:check_dependencies()

-- 启动 metrics 服务器
local metrics_server = http.listen {
  addr = "0.0.0.0:9090",
  handler = function(stream)
    if stream.path == "/metrics" then
      local metrics = prometheus.gather()
      stream:respond(200, {
        ["content-type"] = "text/plain; version=0.0.4",
      })
      stream:closewrite(metrics)
    else
      stream:respond(404)
      stream:closewrite("Not Found")
    end
  end
}
```

## 注意事项

### 与底层模块的区别

**prometheus 模块的优势**：
- 自动注册到全局表，无需手动管理
- 代码更简洁，适合大多数使用场景
- 自动包含内置收集器（Silly、Process、JeMalloc）

**底层模块的优势**：
- 可创建多个独立的注册表
- 更精细的控制，适合复杂场景
- 可选择性地不使用内置收集器

**选择建议**：
- 标准应用：使用 `prometheus` 模块
- 需要多个隔离的指标集：使用底层模块
- 需要自定义注册表管理：使用底层模块

### Registry 管理

**全局注册表特性**：
```lua
local prometheus = require "silly.metrics.prometheus"

-- 所有指标共享同一注册表
local counter1 = prometheus.counter("metric1", "Help 1")
local counter2 = prometheus.counter("metric2", "Help 2")

-- gather() 会包含所有指标
local metrics = prometheus.gather()
-- 包含 metric1, metric2, 以及所有内置收集器的指标
```

**手动管理注册表**：
```lua
local registry = prometheus.registry()

-- 注册自定义收集器
local my_collector = {
  collect = function(self, buf)
    -- 收集逻辑
  end
}
registry:register(my_collector)

-- 注销指标
registry:unregister(my_collector)
```

### 指标命名规范

遵循 Prometheus 命名最佳实践：

- 使用蛇形命名（snake_case）：`http_requests_total`
- 使用描述性前缀：`myapp_http_requests_total`
- Counter 指标以 `_total` 结尾：`requests_total`
- 单位作为后缀：`_seconds`、`_bytes`、`_ratio`
- 不要在指标名中包含标签值

**推荐命名**：
- `http_requests_total`
- `http_request_duration_seconds`
- `database_queries_total`
- `cache_hit_ratio`

**避免的命名**：
- `httpRequestsCounter` （不要用 camelCase）
- `requests` （缺少单位和类型信息）
- `request_time_ms` （使用秒而不是毫秒）

### 标签使用建议

1. **避免高基数标签**：
   - 不要使用用户 ID、订单 ID 等作为标签
   - 标签组合数应该是有限且可预测的
   - 高基数会导致内存占用激增和性能下降

2. **标签值规范**：
   - 使用小写字母和下划线
   - 避免动态生成的标签值
   - 使用有意义的分类，如 `status="success"` 而不是 `status="0"`

3. **标签顺序一致性**：
   - 调用 `labels()` 时，参数顺序必须与创建时一致
   - 建议定义常量来避免顺序错误

### 性能考虑

1. **避免在热路径上创建新的标签组合**：
   ```lua
   -- 不好：每次都创建新的标签组合
   for i = 1, 1000000 do
       counter:labels(tostring(i)):inc() -- 创建 100 万个标签组合！
   end

   -- 好：使用有限的标签值
   for i = 1, 1000000 do
       local status = success and "success" or "failure"
       counter:labels(status):inc() -- 只有 2 个标签组合
   end
   ```

2. **Histogram 桶的选择**：
   - 根据实际数据分布选择桶边界
   - 桶数量不宜过多（通常 10-20 个足够）
   - 桶边界应该覆盖大部分观察值的范围

3. **`gather()` 调用频率**：
   - 不要过于频繁调用 `gather()`（建议间隔 > 1 秒）
   - Prometheus 默认抓取间隔为 15-60 秒
   - `gather()` 会遍历所有指标并格式化输出，有一定开销

### 内置收集器说明

**Silly Collector** 提供框架运行时指标，对调试和优化非常有用：
- Worker 队列深度可以反映系统负载
- 定时器统计可以发现定时器泄漏
- 网络统计可以监控流量和连接数

**Process Collector** 提供进程级资源使用情况：
- CPU 时间可以计算 CPU 使用率
- 内存指标可以监控内存泄漏

**JeMalloc Collector** 提供详细的内存分配统计（需要 `MALLOC=jemalloc` 编译）。

### 线程安全

- Silly 使用单线程事件循环，无需考虑并发问题
- 所有指标操作都在 Worker 线程中执行

## 参见

- [silly.metrics.counter](./counter.md) - Counter 指标详细文档
- [silly.metrics.gauge](./gauge.md) - Gauge 指标详细文档
- [silly.metrics.histogram](./histogram.md) - Histogram 指标详细文档
- [silly.metrics.registry](./registry.md) - Registry 注册表详细文档
- [Prometheus 文本格式规范](https://prometheus.io/docs/instrumenting/exposition_formats/)
- [Prometheus 命名最佳实践](https://prometheus.io/docs/practices/naming/)
