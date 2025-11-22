---
title: silly.metrics.prometheus
description: Prometheus integration module - provides convenient Prometheus metrics collection and export interface
---

# silly.metrics.prometheus

`silly.metrics.prometheus` is the Silly framework's Prometheus integration module, providing convenient interfaces for metric creation, registration, and collection. This module is an aggregated wrapper around the underlying `counter`, `gauge`, and `histogram` modules, automatically managing metric registration and providing data export functionality compliant with Prometheus text format.

## Module Features

- **Automatic registration**: Created metrics are automatically registered to the global registry
- **Unified interface**: Consistent API style, simplifying metric management
- **Built-in collectors**: Automatically registers framework-level metrics (Silly runtime, process resources, JeMalloc memory, etc.)
- **Formatted output**: Directly generates metric data in Prometheus text format
- **Zero dependencies**: No external dependencies, works out of the box

## Core Concepts

### Prometheus as an Aggregation Module

The `prometheus` module is a convenience wrapper that aggregates the following underlying modules:

- **`silly.metrics.counter`**: Underlying Counter metric implementation
- **`silly.metrics.gauge`**: Underlying Gauge metric implementation
- **`silly.metrics.histogram`**: Underlying Histogram metric implementation
- **`silly.metrics.registry`**: Metric registry management

Key differences:

| Feature | prometheus module | Underlying modules |
|---------|----------------|---------|
| Registration method | Auto-register to global table | Manual registration required |
| Use case | Standard usage scenarios | Advanced custom scenarios |
| Code simplicity | More concise | More flexible |

**Using prometheus module (recommended)**:
```lua
local prometheus = require "silly.metrics.prometheus"
local counter = prometheus.counter("requests_total", "Total requests")
counter:inc()
-- Auto-registered, gather() will include this metric
```

**Using underlying modules (advanced scenarios)**:
```lua
local counter = require "silly.metrics.counter"
local registry = require "silly.metrics.registry"
local my_counter = counter("requests_total", "Total requests")
local my_registry = registry.new()
my_registry:register(my_counter)
-- Manual registry management required
```

### Registry

The `prometheus` module maintains a global metric registry. All metrics created via `prometheus.counter()`, `prometheus.gauge()`, and `prometheus.histogram()` are automatically registered to this table. The registry can be accessed via `prometheus.registry()` for advanced operations.

### Collector

The module automatically registers the following built-in collectors:

#### 1. Silly Collector
Framework runtime metrics:
- `silly_worker_backlog`: Pending messages in worker queue
- `silly_timer_pending`: Number of pending timers
- `silly_timer_scheduled_total`: Total scheduled timers
- `silly_timer_fired_total`: Total fired timers
- `silly_timer_canceled_total`: Total canceled timers
- `silly_tasks_runnable`: Number of runnable tasks
- `silly_tcp_connections`: Active TCP connections
- `silly_socket_requests_total`: Total socket operation requests
- `silly_socket_processed_total`: Total processed socket operations
- `silly_network_sent_bytes_total`: Total network bytes sent
- `silly_network_received_bytes_total`: Total network bytes received

#### 2. Process Collector
Process resource metrics:
- `process_cpu_seconds_user`: User CPU time (seconds)
- `process_cpu_seconds_system`: System CPU time (seconds)
- `process_resident_memory_bytes`: Resident memory size (bytes)
- `process_heap_bytes`: Heap memory size (bytes)

#### 3. JeMalloc Collector (optional)
Automatically enabled when using JeMalloc, provides memory allocator statistics.

### Gather (Metric Collection)

The `gather()` function calls the `collect()` method of all registered collectors, collecting metric data and formatting it to Prometheus text format (Text Format 0.0.4).

## API Reference

### prometheus.counter()

Creates and automatically registers a Counter metric. Counter is a monotonically increasing accumulator, suitable for counting total requests, errors, etc.

**Function Signature**

```lua
function prometheus.counter(name, help, labels)
  -> counter
```

**Parameters**

- `name` (string): Metric name, must comply with Prometheus naming conventions (`[a-zA-Z_:][a-zA-Z0-9_:]*`)
- `help` (string): Metric description text, used for Prometheus UI display
- `labels` (table?): Label name array, optional. If provided, returns CounterVec

**Returns**

- Returns `silly.metrics.counter` or `silly.metrics.countervec` object, already registered to global registry

**Example**

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- Create label-less Counter
local requests = prometheus.counter(
  "http_requests_total",
  "Total number of HTTP requests"
)
requests:inc()  -- Increment by 1
requests:add(5) -- Increment by 5

-- Create Counter with labels (CounterVec)
local errors = prometheus.counter(
  "http_errors_total",
  "Total number of HTTP errors",
  {"method", "status"}
)
errors:labels("GET", "404"):inc()
errors:labels("POST", "500"):add(2)
```

### prometheus.gauge()

Creates and automatically registers a Gauge metric. Gauge is a metric that can increase or decrease, suitable for counting current active connections, temperature, memory usage, and other instantaneous values.

**Function Signature**

```lua
function prometheus.gauge(name, help, labels)
  -> gauge
```

**Parameters**

- `name` (string): Metric name, must comply with Prometheus naming conventions
- `help` (string): Metric description text
- `labels` (table?): Label name array, optional. If provided, returns GaugeVec

**Returns**

- Returns `silly.metrics.gauge` or `silly.metrics.gaugevec` object, already registered to global registry

**Example**

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- Create label-less Gauge
local active = prometheus.gauge(
  "http_active_connections",
  "Current number of active HTTP connections"
)
active:set(100) -- Set to 100
active:inc()    -- Increment by 1
active:dec()    -- Decrement by 1
active:add(5)   -- Increment by 5
active:sub(3)   -- Decrement by 3

-- Create Gauge with labels (GaugeVec)
local temperature = prometheus.gauge(
  "server_temperature_celsius",
  "Server room temperature in Celsius",
  {"location"}
)
temperature:labels("datacenter1"):set(25.5)
temperature:labels("datacenter2"):set(27.3)
```

### prometheus.histogram()

Creates and automatically registers a Histogram metric. Histogram is used for statistical data distribution, suitable for counting request latency, response size, and other scenarios requiring quantile analysis.

**Function Signature**

```lua
function prometheus.histogram(name, help, labels, buckets)
  -> histogram
```

**Parameters**

- `name` (string): Metric name, must comply with Prometheus naming conventions
- `help` (string): Metric description text
- `labels` (table?): Label name array, optional. If provided, returns HistogramVec
- `buckets` (table?): Bucket boundary array, optional. Defaults to `{0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0}`

**Returns**

- Returns `silly.metrics.histogram` or `silly.metrics.histogramvec` object, already registered to global registry

**Example**

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- Histogram with default buckets
local latency = prometheus.histogram(
  "http_request_duration_seconds",
  "HTTP request latency in seconds"
)
latency:observe(0.023) -- Record a 23ms request

-- HistogramVec with custom buckets
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

Gets the global registry object. Used for advanced scenarios like manually registering custom collectors or unregistering metrics.

**Function Signature**

```lua
function prometheus.registry()
  -> registry
```

**Returns**

- Returns global `silly.metrics.registry` object

**Example**

```lua validate
local prometheus = require "silly.metrics.prometheus"
local counter = require "silly.metrics.counter"

-- Get global registry
local registry = prometheus.registry()

-- Manually create and register metric
local manual_counter = counter("manual_metric_total", "A manually registered metric")
registry:register(manual_counter)

-- Manually unregister metric
registry:unregister(manual_counter)

-- Register custom collector
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

Collects current values of all registered metrics and formats them to Prometheus text format. This function calls all registered collectors (including built-in collectors and user-created metrics).

**Function Signature**

```lua
function prometheus.gather()
  -> string
```

**Returns**

- Returns string in Prometheus text format (Text Format 0.0.4)

**Output Format**

```text
# HELP metric_name metric description
# TYPE metric_name metric_type
metric_name{label1="value1"} value

# Histogram format:
metric_name_bucket{le="0.005"} count
metric_name_bucket{le="+Inf"} total_count
metric_name_sum total_sum
metric_name_count total_count
```

**Example**

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- Create some metrics
local requests = prometheus.counter("app_requests_total", "Total requests")
local active = prometheus.gauge("app_active_users", "Active users")

requests:inc()
active:set(42)

-- Collect and output
local metrics_text = prometheus.gather()
-- Output similar to:
-- # HELP app_requests_total Total requests
-- # TYPE app_requests_total counter
-- app_requests_total	1
-- # HELP app_active_users Active users
-- # TYPE app_active_users gauge
-- app_active_users	42
-- ... (plus built-in collector metrics)
```

## Usage Examples

### Example 1: HTTP Metrics Endpoint

Most common use case: create `/metrics` endpoint for Prometheus scraping.

```lua validate
local http = require "silly.net.http"
local prometheus = require "silly.metrics.prometheus"

-- Create business metrics
local http_requests = prometheus.counter(
  "http_requests_total",
  "Total HTTP requests",
  {"method", "path", "status"}
)

local http_duration = prometheus.histogram(
  "http_request_duration_seconds",
  "HTTP request latency"
)

-- Start HTTP server
local server = http.listen {
  addr = "0.0.0.0:8080",
  handler = function(stream)
    local start = os.clock()

    if stream.path == "/metrics" then
      -- Prometheus scrape endpoint
      local metrics = prometheus.gather()
      stream:respond(200, {
        ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
        ["content-length"] = #metrics,
      })
      stream:close(metrics)
    else
      -- Business logic
      stream:respond(200, {["content-type"] = "text/plain"})
      stream:close("Hello World")

      -- Record metrics
      local duration = os.clock() - start
      http_duration:observe(duration)
      http_requests:labels(stream.method, stream.path, "200"):inc()
    end
  end
}
```

### Example 2: Complete Web Application Monitoring

Monitoring various aspects of a web application with multiple metric types.

```lua validate
local http = require "silly.net.http"
local prometheus = require "silly.metrics.prometheus"

-- Define metrics
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

-- HTTP handler
local server = http.listen {
  addr = "0.0.0.0:8080",
  handler = function(stream)
    local start = os.clock()
    requests_in_flight:inc()

    -- Handle metrics endpoint
    if stream.path == "/metrics" then
      local metrics = prometheus.gather()
      stream:respond(200, {
        ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
      })
      stream:close(metrics)
      requests_in_flight:dec()
      return
    end

    -- Record request size
    local req_size = stream.headers["content-length"] or 0
    request_size:observe(tonumber(req_size))

    -- Business logic
    local response_data = "Response data"
    stream:respond(200, {["content-type"] = "text/plain"})
    stream:close(response_data)

    -- Record response metrics
    local duration = os.clock() - start
    response_size:observe(#response_data)
    request_duration:labels(stream.method, stream.path):observe(duration)
    requests_total:labels(stream.method, stream.path, "200"):inc()
    requests_in_flight:dec()
  end
}
```

### Example 3: Business Metrics Monitoring

Monitoring key business-level metrics.

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- User-related metrics
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

-- Order-related metrics
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

-- Business logic example
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

-- Simulate business operations
handle_user_login("web")
handle_user_login("mobile")
handle_order("completed", "credit_card", 199.99, "USD")
handle_order("pending", "paypal", 49.99, "EUR")
```

### Example 4: Scheduled Job Monitoring

Monitoring execution status of scheduled tasks.

```lua validate
local time = require "silly.time"
local prometheus = require "silly.metrics.prometheus"

-- Scheduled job metrics
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

-- Job execution wrapper
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

-- Scheduled job example
local function data_cleanup_job()
  -- Cleanup logic
  time.sleep(100)
end

local function backup_job()
  -- Backup logic
  time.sleep(200)
end

-- Execute every 5 seconds
run_job("data_cleanup", data_cleanup_job)
run_job("backup", backup_job)
```

### Example 5: Database Connection Pool Monitoring

Monitoring database connection pool status.

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- Connection pool metrics
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

-- Simulate connection pool management
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

-- Usage example
local pool = ConnectionPool.new("postgres_main", 10)

pool:execute("select", function()
  -- Simulate query
  return "result"
end)

pool:execute("insert", function()
  -- Simulate insert
  return true
end)
```

### Example 6: Cache Performance Monitoring

Monitoring cache hit rate and performance.

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- Cache metrics
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

-- Simple cache implementation
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

-- Usage example
local user_cache = Cache.new("users")
user_cache:set("user:1", {name = "Alice", age = 30})
user_cache:get("user:1")  -- hit
user_cache:get("user:2")  -- miss
user_cache:delete("user:1")
```

### Example 7: Queue Monitoring

Monitoring message queue throughput and latency.

```lua validate
local prometheus = require "silly.metrics.prometheus"

-- Queue metrics
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

-- Simple queue implementation
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

  -- Record wait time
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

-- Usage example
local job_queue = Queue.new("background_jobs")

-- Enqueue messages
job_queue:enqueue({type = "email", to = "user@example.com"})
job_queue:enqueue({type = "notification", message = "Hello"})

-- Process messages
job_queue:process_message(function(msg)
  -- Processing logic
end)
```

### Example 8: Multi-Service Aggregate Monitoring

In microservice architecture, providing unified monitoring for different services.

```lua validate
local http = require "silly.net.http"
local prometheus = require "silly.metrics.prometheus"

-- Service-level metrics (with service label)
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

-- Service abstraction
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

-- Usage example
local user_service = Service.new("user_service")
user_service:add_dependency("database", function()
  return true  -- Should actually check database connection
end)
user_service:add_dependency("cache", function()
  return true  -- Should actually check cache connection
end)

-- Handle request
user_service:handle_request("/users", function()
  return {users = {}}, "200"
end)

-- Periodic health check
user_service:check_dependencies()

-- Start metrics server
local metrics_server = http.listen {
  addr = "0.0.0.0:9090",
  handler = function(stream)
    if stream.path == "/metrics" then
      local metrics = prometheus.gather()
      stream:respond(200, {
        ["content-type"] = "text/plain; version=0.0.4",
      })
      stream:close(metrics)
    else
      stream:respond(404)
      stream:close("Not Found")
    end
  end
}
```

## Important Notes

### Difference from Underlying Modules

**Advantages of prometheus module**:
- Auto-registers to global table, no manual management needed
- More concise code, suitable for most use cases
- Automatically includes built-in collectors (Silly, Process, JeMalloc)

**Advantages of underlying modules**:
- Can create multiple independent registries
- More fine-grained control, suitable for complex scenarios
- Can selectively not use built-in collectors

**Selection recommendations**:
- Standard applications: use `prometheus` module
- Need multiple isolated metric sets: use underlying modules
- Need custom registry management: use underlying modules

### Registry Management

**Global registry characteristics**:
```lua
local prometheus = require "silly.metrics.prometheus"

-- All metrics share the same registry
local counter1 = prometheus.counter("metric1", "Help 1")
local counter2 = prometheus.counter("metric2", "Help 2")

-- gather() will include all metrics
local metrics = prometheus.gather()
-- Contains metric1, metric2, and all built-in collector metrics
```

**Manual registry management**:
```lua
local registry = prometheus.registry()

-- Register custom collector
local my_collector = {
  collect = function(self, buf)
    -- Collection logic
  end
}
registry:register(my_collector)

-- Unregister metric
registry:unregister(my_collector)
```

### Metric Naming Conventions

Follow Prometheus naming best practices:

- Use snake_case: `http_requests_total`
- Use descriptive prefixes: `myapp_http_requests_total`
- Counter metrics end with `_total`: `requests_total`
- Units as suffix: `_seconds`, `_bytes`, `_ratio`
- Don't include label values in metric names

**Recommended naming**:
- `http_requests_total`
- `http_request_duration_seconds`
- `database_queries_total`
- `cache_hit_ratio`

**Avoid naming**:
- `httpRequestsCounter` (don't use camelCase)
- `requests` (missing units and type information)
- `request_time_ms` (use seconds instead of milliseconds)

### Label Usage Recommendations

1. **Avoid high cardinality labels**:
   - Don't use user ID, order ID, etc. as labels
   - Label combination count should be finite and predictable
   - High cardinality causes memory usage explosion and performance degradation

2. **Label value conventions**:
   - Use lowercase letters and underscores
   - Avoid dynamically generated label values
   - Use meaningful categories, like `status="success"` rather than `status="0"`

3. **Label order consistency**:
   - When calling `labels()`, parameter order must match creation order
   - Recommend defining constants to avoid order errors

### Performance Considerations

1. **Avoid creating new label combinations in hot paths**:
   ```lua
   -- Bad: create new label combinations each time
   for i = 1, 1000000 do
       counter:labels(tostring(i)):inc() -- Creates 1 million label combinations!
   end

   -- Good: use limited label values
   for i = 1, 1000000 do
       local status = success and "success" or "failure"
       counter:labels(status):inc() -- Only 2 label combinations
   end
   ```

2. **Histogram bucket selection**:
   - Choose bucket boundaries based on actual data distribution
   - Bucket count should not be too large (usually 10-20 is sufficient)
   - Bucket boundaries should cover most observation value ranges

3. **`gather()` call frequency**:
   - Don't call `gather()` too frequently (recommend interval > 1 second)
   - Prometheus default scrape interval is 15-60 seconds
   - `gather()` traverses all metrics and formats output, has certain overhead

### Built-in Collector Notes

**Silly Collector** provides framework runtime metrics, very useful for debugging and optimization:
- Worker queue depth reflects system load
- Timer statistics can detect timer leaks
- Network statistics can monitor traffic and connection count

**Process Collector** provides process-level resource usage:
- CPU time can calculate CPU utilization
- Memory metrics can monitor memory leaks

**JeMalloc Collector** provides detailed memory allocation statistics (requires `MALLOC=jemalloc` compilation).

### Thread Safety

- Silly uses single-threaded Worker model, all metric operations execute in the same thread
- All metric operations execute in Worker thread, no need to consider concurrency issues

## See Also

- [silly.metrics.counter](./counter.md) - Counter metric detailed documentation
- [silly.metrics.gauge](./gauge.md) - Gauge metric detailed documentation
- [silly.metrics.histogram](./histogram.md) - Histogram metric detailed documentation
- [silly.metrics.registry](./registry.md) - Registry detailed documentation
- [Prometheus text format specification](https://prometheus.io/docs/instrumenting/exposition_formats/)
- [Prometheus naming best practices](https://prometheus.io/docs/practices/naming/)
