---
title: Logging and Monitoring Guide
icon: chart-line
order: 4
category:
  - Guides
tag:
  - Logging
  - Monitoring
  - Prometheus
  - Observability
---

# Logging and Monitoring Guide

This guide introduces how to implement comprehensive logging and performance monitoring in Silly applications, building a complete observability solution.

## Introduction

Observability is a core element of modern application operations, consisting of three pillars:

- **Logging**: Recording discrete events and error messages
- **Metrics**: Recording aggregatable numerical data reflecting system state
- **Tracing**: Tracking the complete lifecycle of requests through the system

The Silly framework provides built-in support for all three aspects:

- `silly.logger`: Hierarchical logging system with log rotation support
- `silly.metrics.prometheus`: Prometheus metrics collection and export
- `silly.tracespawn/traceset`: Distributed trace ID generation and propagation

## Logging System

### Basic Usage

`silly.logger` provides four log levels: DEBUG, INFO, WARN, and ERROR:

```lua
local logger = require "silly.logger"

-- Set log level (only output INFO and above)
logger.setlevel(logger.INFO)

-- Basic log output
logger.debug("Debug information")        -- Won't be output
logger.info("Server started")            -- Will be output
logger.warn("Connection timeout, retrying") -- Will be output
logger.error("Database connection failed")  -- Will be output
```

### Log Format

The framework automatically adds the following information to each log entry:

```
2025-10-21 09:37:27 0001e3d700010000 I cluster/node1.lua:30 [node1] Received HTTP GET /test
```

Log format explanation:
- `2025-10-21 09:37:27` - Timestamp
- `0001e3d700010000` - **Trace ID** (automatically printed, no need to explicitly add in business code)
- `I` - Log level (D=DEBUG, I=INFO, W=WARN, E=ERROR)
- `cluster/node1.lua:30` - File name and line number
- `[node1] Received HTTP GET /test` - Log message

::: tip Automatic Trace ID Printing
The framework automatically prints the current coroutine's Trace ID before each log entry. Business code **does not need** to explicitly include the Trace ID in log messages. This allows all logs from the same request to be correlated via the Trace ID.
:::

```lua
-- ❌ Wrong: Don't explicitly print trace ID
local trace_id = task.tracepropagate()
logger.info("[" .. trace_id .. "] Processing request")

-- ✅ Correct: Framework automatically prints trace ID
logger.info("Processing request")
```

### Choosing Log Levels

Choose appropriate log levels based on different scenarios:

| Level | Use Case | Examples |
|------|---------|------|
| **DEBUG** | Development debugging, troubleshooting | Variable values, function calls, detailed request info |
| **INFO** | Normal business flow | Service start/stop, user login, order creation |
| **WARN** | Potential issues, degraded operations | Retry limit exceeded, cache miss, missing config |
| **ERROR** | Errors and exceptions | Database connection failure, request processing failure |

```lua
local logger = require "silly.logger"

-- Production environment: use INFO level
logger.setlevel(logger.INFO)

-- Debug mode: use DEBUG level
logger.setlevel(logger.DEBUG)

-- Check current level
if logger.getlevel() <= logger.DEBUG then
    -- Only perform expensive serialization in DEBUG mode
    local json = require "json"
    logger.debug("Request details:", json.encode(request))
end
```

### Formatted Logging

Use formatted log functions (`*f` series) to improve log readability:

```lua
local logger = require "silly.logger"

-- Use string.format style
logger.infof("User [%s] completed %d operations in %d seconds",
    username, duration, count)

logger.errorf("Order #%d processing failed: %s (error code: %d)",
    order_id, error_msg, error_code)

-- Format parameters
logger.debugf("%.2f%% of requests completed within %dms",
    percentage, latency_ms)
```

### Structured Logging

For easier log analysis, use structured log format:

```lua
local logger = require "silly.logger"
local json = require "silly.encoding.json"

-- Define log helper function
local function log_request(method, path, status, duration)
    local log_entry = {
        timestamp = os.time(),
        level = "INFO",
        event = "http_request",
        method = method,
        path = path,
        status = status,
        duration_ms = duration,
    }
    logger.info(json.encode(log_entry))
end

-- Usage
log_request("GET", "/api/users", 200, 15.3)
-- Output: {"timestamp":1703001234,"level":"INFO","event":"http_request",...}
```

### Log Rotation

Silly supports log rotation via signals to prevent unlimited log file growth:

```lua
-- Specify log file at startup
-- ./silly main.lua --logpath=/var/log/myapp.log
```

Shell script to perform log rotation:

```bash
#!/bin/bash
# rotate-logs.sh

LOG_FILE="/var/log/myapp.log"
APP_PID=$(cat /var/run/myapp.pid)

# 1. Rename current log file
mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d-%H%M%S)"

# 2. Send SIGUSR1 signal to make Silly reopen the log file
kill -USR1 "$APP_PID"

# 3. Compress old logs (optional)
gzip "$LOG_FILE".*

# 4. Clean up logs older than 7 days (optional)
find /var/log -name "myapp.log.*" -mtime +7 -delete
```

Configure crontab for periodic execution:

```bash
# Execute log rotation at 2 AM daily
0 2 * * * /path/to/rotate-logs.sh
```

### Dynamic Log Level Adjustment

In production environments, dynamically adjust log levels via signals to avoid service restart:

```lua
local logger = require "silly.logger"
local signal = require "silly.signal"

-- Initialize to INFO level
logger.setlevel(logger.INFO)

-- Toggle DEBUG mode via SIGUSR2 signal
signal("SIGUSR2", function()
    if logger.getlevel() == logger.DEBUG then
        logger.setlevel(logger.INFO)
        logger.info("Log level switched to INFO")
    else
        logger.setlevel(logger.DEBUG)
        logger.info("Log level switched to DEBUG")
    end
end)
```

Switch log level:

```bash
# Switch to DEBUG mode
kill -USR2 <pid>

# Execute again to switch back to INFO mode
kill -USR2 <pid>
```

## Performance Monitoring

### Prometheus Integration

Silly has built-in complete Prometheus metrics system, supporting Counter, Gauge, and Histogram metric types.

#### Creating /metrics Endpoint

The most basic monitoring integration is exposing a `/metrics` endpoint for Prometheus to scrape:

```lua
local http = require "silly.net.http"
local prometheus = require "silly.metrics.prometheus"

-- Start HTTP server
local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        if stream.path == "/metrics" then
            -- Collect all metrics and return in Prometheus format
            local metrics = prometheus.gather()
            stream:respond(200, {
                ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
            })
            stream:closewrite(metrics)
        else
            -- Business logic
            stream:respond(200, {["content-type"] = "text/plain"})
            stream:closewrite("Hello World")
        end
    end
}
```

#### Built-in Metrics

`prometheus.gather()` automatically collects the following built-in metrics:

**Silly Runtime Metrics**:
- `silly_worker_backlog`: Number of pending messages in worker queue
- `silly_timer_pending`: Number of pending timers
- `silly_tasks_runnable`: Number of runnable tasks
- `silly_tcp_connections`: Number of active TCP connections
- `silly_network_sent_bytes_total`: Total bytes sent over network
- `silly_network_received_bytes_total`: Total bytes received from network

**Process Resource Metrics**:
- `process_cpu_seconds_user`: User-mode CPU time (seconds)
- `process_cpu_seconds_system`: Kernel-mode CPU time (seconds)
- `process_resident_memory_bytes`: Resident memory size (bytes)
- `process_heap_bytes`: Heap memory size (bytes)

**JeMalloc Metrics** (if compiled with `MALLOC=jemalloc`):
- Detailed memory allocation statistics

### Custom Metrics

Create custom metrics based on business needs:

#### Counter: Cumulative Counter

Counter can only increase, suitable for counting total requests, error counts, and other cumulative values:

```lua
local prometheus = require "silly.metrics.prometheus"

-- Create Counter
local http_requests_total = prometheus.counter(
    "http_requests_total",
    "Total HTTP requests",
    {"method", "path", "status"}
)

-- Record requests
http_requests_total:labels("GET", "/api/users", "200"):inc()
http_requests_total:labels("POST", "/api/users", "201"):inc()
http_requests_total:labels("GET", "/api/users", "500"):inc()
```

#### Gauge: Gauge

Gauge can increase or decrease, suitable for counting current connections, queue depth, and other instantaneous values:

```lua
local prometheus = require "silly.metrics.prometheus"

-- Create Gauge
local active_connections = prometheus.gauge(
    "active_connections",
    "Current active connections"
)

local queue_depth = prometheus.gauge(
    "queue_depth",
    "Queue depth",
    {"queue_name"}
)

-- Usage
active_connections:inc()        -- Increase by 1
active_connections:dec()        -- Decrease by 1
active_connections:set(42)      -- Set to 42
active_connections:add(10)      -- Add 10
active_connections:sub(5)       -- Subtract 5

queue_depth:labels("jobs"):set(128)
```

#### Histogram: Histogram

Histogram counts data distribution, suitable for counting latency, response size, and other scenarios requiring percentile analysis:

```lua
local prometheus = require "silly.metrics.prometheus"

-- Create Histogram (default buckets)
local request_duration = prometheus.histogram(
    "http_request_duration_seconds",
    "HTTP request duration (seconds)"
)

-- Custom bucket boundaries
local response_size = prometheus.histogram(
    "http_response_size_bytes",
    "HTTP response size (bytes)",
    {"method"},
    {100, 500, 1000, 5000, 10000, 50000, 100000}
)

-- Record observations
local start = os.clock()
-- ... process request ...
local duration = os.clock() - start
request_duration:observe(duration)

response_size:labels("GET"):observe(1234)
```

### Complete Monitoring Example

An HTTP service example with complete monitoring:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
local prometheus = require "silly.metrics.prometheus"

-- Define metrics
local http_requests_total = prometheus.counter(
    "myapp_http_requests_total",
    "Total HTTP requests",
    {"method", "path", "status"}
)

local http_requests_in_flight = prometheus.gauge(
    "myapp_http_requests_in_flight",
    "Number of HTTP requests in flight"
)

local http_request_duration = prometheus.histogram(
    "myapp_http_request_duration_seconds",
    "HTTP request duration (seconds)",
    {"method", "path"},
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0}
)

-- HTTP handler function
local function handle_request(stream)
    local start = os.clock()
    http_requests_in_flight:inc()

    -- Handle different paths
    local status_code = 200
    local response_body = ""

    if stream.path == "/metrics" then
        -- Prometheus metrics endpoint
        local metrics = prometheus.gather()
        stream:respond(200, {
            ["content-type"] = "text/plain; version=0.0.4",
        })
        stream:closewrite(metrics)
    elseif stream.path == "/api/users" then
        -- Business API
        logger.info("Handling user API request:", stream.method)

        response_body = '{"users": []}'
        stream:respond(200, {["content-type"] = "application/json"})
        stream:closewrite(response_body)
    else
        -- 404
        status_code = 404
        response_body = "Not Found"
        stream:respond(404, {["content-type"] = "text/plain"})
        stream:closewrite(response_body)
    end

    -- Record metrics
    local duration = os.clock() - start
    http_requests_in_flight:dec()
    http_request_duration:labels(stream.method, stream.path):observe(duration)
    http_requests_total:labels(stream.method, stream.path, tostring(status_code)):inc()

    -- Record log
    logger.infof("%s %s %d %.3fs",
        stream.method, stream.path, status_code, duration)
end

-- Start service
local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        local ok, err = silly.pcall(handle_request, stream)
        if not ok then
            logger.error("Request handling failed:", err)
            stream:respond(500, {["content-type"] = "text/plain"})
            stream:closewrite("Internal Server Error")
        end
    end
}

logger.info("Server started on 0.0.0.0:8080")
logger.info("Prometheus metrics: http://localhost:8080/metrics")
```

### Grafana Visualization

Configure Prometheus to scrape metrics from Silly application:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'silly-app'
    scrape_interval: 15s
    static_configs:
      - targets: ['localhost:8080']
        labels:
          app: 'my-silly-app'
          env: 'production'
```

Create dashboard in Grafana with common queries:

```promql
# QPS (queries per second)
rate(myapp_http_requests_total[1m])

# QPS grouped by status code
sum by (status) (rate(myapp_http_requests_total[1m]))

# P95 latency
histogram_quantile(0.95, rate(myapp_http_request_duration_seconds_bucket[5m]))

# Error rate
rate(myapp_http_requests_total{status=~"5.."}[1m])
  /
rate(myapp_http_requests_total[1m])

# Current active connections
myapp_http_requests_in_flight

# Memory usage
process_resident_memory_bytes

# CPU usage rate
rate(process_cpu_seconds_total[1m]) * 100
```

## Request Tracing

### Trace ID Generation

Silly provides a distributed trace ID system where each coroutine has an independent trace ID:

```lua
local silly = require "silly"
local task = require "silly.task"
local logger = require "silly.logger"

task.fork(function()
    -- Create new trace ID (if current coroutine doesn't have one)
    local old_trace_id = task.tracespawn()
    logger.infof("Start processing request")
    logger.infof("Request processing completed")
    task.traceset(old_trace_id)
end)
```

### Cross-Service Tracing

In microservice architecture, trace IDs need to be propagated to downstream services:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"

-- Service A: Initiate HTTP request
local function call_service_b()
    -- Generate trace ID for propagation
    local trace_id = task.tracepropagate()
    logger.info("Calling service B")

    -- Pass trace ID via HTTP Header
    local response = http.request {
        method = "POST",
        url = "http://service-b:8080/api/process",
        headers = {
            ["X-Trace-Id"] = tostring(trace_id),
        },
        body = '{"data": "value"}',
    }

    return response
end

-- Service B: Receive request and use incoming trace ID
local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        -- Extract and set trace ID
        local trace_id = tonumber(stream.headers["x-trace-id"])
        if trace_id then
            task.traceset(trace_id)
        else
            trace_id = task.tracespawn()
        end
        logger.info("Service B received request")
        -- Process business logic
        stream:respond(200, {["content-type"] = "application/json"})
        stream:closewrite('{"status": "ok"}')
    end
}
```

### Automatic RPC Tracing

When making RPC calls using `silly.net.cluster`, trace IDs are automatically propagated:

```lua
local cluster = require "silly.net.cluster"
local logger = require "silly.logger"

-- Create cluster service
cluster.serve {
    marshal = ...,
    unmarshal = ...,
    call = function(peer, cmd, body)
        -- trace ID is automatically set by cluster, logger will use it automatically
        logger.info("RPC call:", cmd)

        -- Handle RPC request
        return handle_rpc(body, cmd)
    end,
    close = function(peer, errno)
        logger.info("RPC connection closed, errno:", errno)
    end,
}

-- Initiate RPC call (trace ID automatically propagated)
local peer = cluster.connect("127.0.0.1:8080")
local result = cluster.call(peer, "get_user", {user_id = 123})
```

### Log Correlation

Integrate trace ID into logs to achieve complete request tracking:

```lua
local silly = require "silly"
local logger = require "silly.logger"
local json = require "silly.encoding.json"

-- Structured log helper function
local function log_with_trace(level, event, data)
    local log_entry = {
        timestamp = os.time(),
        level = level,
        event = event,
    }

    -- Merge data
    for k, v in pairs(data or {}) do
        log_entry[k] = v
    end

    local log_str = json.encode(log_entry)

    if level == "ERROR" then
        logger.error(log_str)
    elseif level == "WARN" then
        logger.warn(log_str)
    elseif level == "DEBUG" then
        logger.debug(log_str)
    else
        logger.info(log_str)
    end
end

-- Usage
log_with_trace("INFO", "user_login", {
    user_id = 12345,
    ip = "192.168.1.100",
})

log_with_trace("ERROR", "database_error", {
    query = "SELECT * FROM users",
    error = "connection timeout",
})
```

In log collection systems (like ELK), you can query the complete log chain of a request via trace_id.

## Alert Configuration

### Prometheus Alert Rules

Configure alert rules in Prometheus:

```yaml
# alerts.yml
groups:
  - name: silly_app_alerts
    interval: 30s
    rules:
      # High error rate
      - alert: HighErrorRate
        expr: |
          rate(myapp_http_requests_total{status=~"5.."}[5m])
          /
          rate(myapp_http_requests_total[5m]) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High error rate: {{ $value | humanizePercentage }}"
          description: "Application {{ $labels.app }} error rate exceeds 5%"

      # High P95 latency
      - alert: HighLatency
        expr: |
          histogram_quantile(0.95,
            rate(myapp_http_request_duration_seconds_bucket[5m])
          ) > 1.0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High P95 latency: {{ $value }}s"
          description: "Application {{ $labels.app }} P95 latency exceeds 1 second"

      # High memory usage
      - alert: HighMemoryUsage
        expr: process_resident_memory_bytes > 1073741824  # 1GB
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "High memory usage: {{ $value | humanize1024 }}"
          description: "Application {{ $labels.app }} memory usage exceeds 1GB"

      # Worker queue backlog
      - alert: WorkerBacklog
        expr: silly_worker_backlog > 1000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Worker queue backlog: {{ $value }} messages"
          description: "Application {{ $labels.app }} has severe worker queue backlog"

      # Service down
      - alert: ServiceDown
        expr: up{job="silly-app"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Service unavailable"
          description: "Application {{ $labels.app }} is unreachable"
```

### Alert Channels

Configure Alertmanager to send alerts:

```yaml
# alertmanager.yml
route:
  group_by: ['alertname', 'app']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'default'

  routes:
    # Critical alerts notify immediately
    - match:
        severity: critical
      receiver: 'pager'
      continue: true

    # Warning-level alerts send to email
    - match:
        severity: warning
      receiver: 'email'

receivers:
  # Default receiver
  - name: 'default'
    webhook_configs:
      - url: 'http://webhook-service:8080/alerts'

  # Email notification
  - name: 'email'
    email_configs:
      - to: 'ops@example.com'
        from: 'alertmanager@example.com'
        smarthost: 'smtp.example.com:587'
        auth_username: 'alertmanager@example.com'
        auth_password: 'password'

  # Emergency pager
  - name: 'pager'
    webhook_configs:
      - url: 'http://pagerduty-integration:8080/alert'
```

### In-Application Alerts

You can also implement simple alert logic within the application:

```lua
local silly = require "silly"
local time = require "silly.time"
local logger = require "silly.logger"
local prometheus = require "silly.metrics.prometheus"

-- Define alert thresholds
local ALERT_CONFIG = {
    error_rate_threshold = 0.05,      -- 5% error rate
    latency_p95_threshold = 1.0,      -- 1 second
    memory_threshold = 1073741824,    -- 1GB
}

-- Alert state
local alert_state = {
    error_rate_fired = false,
    latency_fired = false,
    memory_fired = false,
}

-- Send alert
local function send_alert(alert_name, message)
    logger.errorf("[ALERT] %s: %s", alert_name, message)

    -- You can integrate alert channels here, such as HTTP callbacks, email, etc.
    -- http.request {
    --     method = "POST",
    --     url = "http://alert-service/webhook",
    --     body = json.encode({
    --         alert = alert_name,
    --         message = message,
    --         timestamp = os.time(),
    --     })
    -- }
end

-- Periodically check metrics
local function check_alerts()
    -- This is a simplified example, should actually calculate from Prometheus metrics
    local error_rate = 0.06  -- Example value
    local latency_p95 = 1.2  -- Example value
    local memory_usage = 1200000000  -- Example value

    -- Check error rate
    if error_rate > ALERT_CONFIG.error_rate_threshold then
        if not alert_state.error_rate_fired then
            send_alert("HighErrorRate",
                string.format("Error rate %.2f%% exceeds threshold %.2f%%",
                    error_rate * 100,
                    ALERT_CONFIG.error_rate_threshold * 100))
            alert_state.error_rate_fired = true
        end
    else
        alert_state.error_rate_fired = false
    end

    -- Check latency
    if latency_p95 > ALERT_CONFIG.latency_p95_threshold then
        if not alert_state.latency_fired then
            send_alert("HighLatency",
                string.format("P95 latency %.2fs exceeds threshold %.2fs",
                    latency_p95,
                    ALERT_CONFIG.latency_p95_threshold))
            alert_state.latency_fired = true
        end
    else
        alert_state.latency_fired = false
    end

    -- Check memory
    if memory_usage > ALERT_CONFIG.memory_threshold then
        if not alert_state.memory_fired then
            send_alert("HighMemoryUsage",
                string.format("Memory usage %d MB exceeds threshold %d MB",
                    memory_usage / 1024 / 1024,
                    ALERT_CONFIG.memory_threshold / 1024 / 1024))
            alert_state.memory_fired = true
        end
    else
        alert_state.memory_fired = false
    end
end

-- Check every 60 seconds
task.fork(function()
    while true do
        time.sleep(60000)
        check_alerts()
    end
end)
```

## Complete Example: Production-Grade HTTP Service

A production-grade HTTP service example with complete logging, monitoring, and tracing:

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
local signal = require "silly.signal"
local time = require "silly.time"
local prometheus = require "silly.metrics.prometheus"
local json = require "silly.encoding.json"

-- ========== Logging Configuration ==========
logger.setlevel(logger.INFO)

-- Dynamically adjust log level
signal("SIGUSR2", function()
    if logger.getlevel() == logger.DEBUG then
        logger.setlevel(logger.INFO)
        logger.info("Log level switched to INFO")
    else
        logger.setlevel(logger.DEBUG)
        logger.info("Log level switched to DEBUG")
    end
end)

-- ========== Monitoring Metrics ==========
-- Request metrics
local http_requests_total = prometheus.counter(
    "api_http_requests_total",
    "Total HTTP requests",
    {"method", "path", "status"}
)

local http_requests_in_flight = prometheus.gauge(
    "api_http_requests_in_flight",
    "Number of HTTP requests in flight"
)

local http_request_duration = prometheus.histogram(
    "api_http_request_duration_seconds",
    "HTTP request duration (seconds)",
    {"method", "path"},
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0}
)

local http_request_size = prometheus.histogram(
    "api_http_request_size_bytes",
    "HTTP request size (bytes)",
    nil,
    {100, 1000, 10000, 100000, 1000000}
)

local http_response_size = prometheus.histogram(
    "api_http_response_size_bytes",
    "HTTP response size (bytes)",
    nil,
    {100, 1000, 10000, 100000, 1000000}
)

-- Business metrics
local user_operations = prometheus.counter(
    "api_user_operations_total",
    "Total user operations",
    {"operation", "status"}
)

-- ========== Structured Logging ==========
local function log_request(trace_id, method, path, status, duration, req_size, resp_size)
    local log_entry = {
        timestamp = os.time(),
        trace_id = trace_id,
        level = "INFO",
        event = "http_request",
        method = method,
        path = path,
        status = status,
        duration_ms = duration * 1000,
        request_size_bytes = req_size,
        response_size_bytes = resp_size,
    }
    logger.info(json.encode(log_entry))
end

-- ========== Business Handlers ==========
local function handle_user_get(stream)
    logger.debug("Getting user list")

    -- Simulate database query
    time.sleep(10)

    local response = json.encode({
        users = {
            {id = 1, name = "Alice"},
            {id = 2, name = "Bob"},
        }
    })

    user_operations:labels("get_users", "success"):inc()
    return 200, response
end

local function handle_user_post(stream)
    logger.debug("Creating user")

    -- Simulate database insert
    time.sleep(20)

    local response = json.encode({
        id = 3,
        name = "Charlie",
        status = "created",
    })

    user_operations:labels("create_user", "success"):inc()
    return 201, response
end

-- ========== HTTP Handler ==========
local function handle_request(stream)
    local start = os.clock()
    http_requests_in_flight:inc()

    -- Get or create trace ID
    local trace_id = tonumber(stream.headers["x-trace-id"])
    if trace_id then
        silly.traceset(trace_id)
    else
        silly.tracespawn()
        trace_id = silly.tracepropagate()  -- Get current trace ID for response header
    end

    -- Record request size
    local req_size = tonumber(stream.headers["content-length"]) or 0
    http_request_size:observe(req_size)

    -- Route handling
    local status_code = 200
    local response_body = ""

    if stream.path == "/metrics" then
        -- Prometheus metrics endpoint
        local metrics = prometheus.gather()
        stream:respond(200, {
            ["content-type"] = "text/plain; version=0.0.4",
        })
        stream:closewrite(metrics)
        status_code = 200
        response_body = metrics
    elseif stream.path == "/api/users" then
        -- User API
        if stream.method == "GET" then
            status_code, response_body = handle_user_get(stream)
        elseif stream.method == "POST" then
            status_code, response_body = handle_user_post(stream)
        else
            status_code = 405
            response_body = "Method Not Allowed"
        end

        stream:respond(status_code, {
            ["content-type"] = "application/json",
            ["x-trace-id"] = tostring(trace_id),
        })
        stream:closewrite(response_body)
    elseif stream.path == "/health" then
        -- Health check
        status_code = 200
        response_body = json.encode({status = "healthy"})
        stream:respond(status_code, {["content-type"] = "application/json"})
        stream:closewrite(response_body)
    else
        -- 404
        status_code = 404
        response_body = json.encode({error = "Not Found"})
        stream:respond(status_code, {["content-type"] = "application/json"})
        stream:closewrite(response_body)
    end

    -- Record metrics
    local duration = os.clock() - start
    http_requests_in_flight:dec()
    http_response_size:observe(#response_body)
    http_request_duration:labels(stream.method, stream.path):observe(duration)
    http_requests_total:labels(stream.method, stream.path, tostring(status_code)):inc()

    -- Record log
    log_request(trace_id, stream.method, stream.path, status_code,
        duration, req_size, #response_body)
end

-- ========== Start Service ==========
local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        local ok, err = silly.pcall(handle_request, stream)
        if not ok then
            silly.tracespawn()  -- Create new trace ID
            logger.error("Request handling failed:", err)

            stream:respond(500, {["content-type"] = "application/json"})
            stream:closewrite(json.encode({error = "Internal Server Error"}))

            http_requests_total:labels(stream.method, stream.path, "500"):inc()
        end
    end
}

logger.info("========================================")
logger.info("Application started successfully")
logger.infof("API Service: http://localhost:8080/api/users")
logger.infof("Health Check: http://localhost:8080/health")
logger.infof("Monitoring Metrics: http://localhost:8080/metrics")
logger.info("========================================")
logger.info("Signal Controls:")
logger.info("  kill -USR1 <pid>  # Reopen log file")
logger.info("  kill -USR2 <pid>  # Toggle log level (INFO <-> DEBUG)")
logger.info("========================================")
```

## Monitoring Dashboard Configuration

### Grafana Dashboard JSON

Create a Grafana dashboard to visualize monitoring data from Silly applications:

```json
{
  "dashboard": {
    "title": "Silly Application Monitoring",
    "panels": [
      {
        "title": "QPS",
        "targets": [
          {
            "expr": "sum(rate(api_http_requests_total[1m]))"
          }
        ]
      },
      {
        "title": "Error Rate",
        "targets": [
          {
            "expr": "sum(rate(api_http_requests_total{status=~\"5..\"}[1m])) / sum(rate(api_http_requests_total[1m]))"
          }
        ]
      },
      {
        "title": "P95 Latency",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, rate(api_http_request_duration_seconds_bucket[5m]))"
          }
        ]
      },
      {
        "title": "Active Connections",
        "targets": [
          {
            "expr": "silly_tcp_connections"
          }
        ]
      },
      {
        "title": "Memory Usage",
        "targets": [
          {
            "expr": "process_resident_memory_bytes"
          }
        ]
      },
      {
        "title": "Worker Queue Depth",
        "targets": [
          {
            "expr": "silly_worker_backlog"
          }
        ]
      }
    ]
  }
}
```

## Best Practices

### Logging Best Practices

1. **Use log levels appropriately**: Avoid using DEBUG level in production, which generates excessive logs
2. **Structured logging**: Use JSON format for easier log collection and analysis
3. **Avoid sensitive information**: Don't log passwords, tokens, or other sensitive data
4. **Control log volume**: For high-frequency operations, consider sampling logs
5. **Regular rotation**: Avoid unlimited log file growth

### Monitoring Best Practices

1. **Metric naming**: Follow Prometheus naming conventions (snake_case, with unit suffixes)
2. **Avoid high cardinality**: Don't use user IDs as labels
3. **Choose metric types appropriately**:
   - Counter: Cumulative values (total requests)
   - Gauge: Instantaneous values (current connections)
   - Histogram: Distribution (latency)
4. **Set reasonable bucket boundaries**: Choose Histogram buckets based on actual data distribution
5. **Monitor key business metrics**: Monitor not only system metrics but also business metrics

### Tracing Best Practices

1. **Always propagate trace ID**: Pass trace ID in cross-service calls
3. **Log correlation**: Integrate trace ID into logs for easier troubleshooting
4. **Retain sufficient information**: Include trace ID in logs, metrics, and error reports

## See Also

- [silly.logger](../reference/logger.md) - Logger API Reference
- [silly.metrics.prometheus](../reference/metrics/prometheus.md) - Prometheus Metrics API Reference
- [silly](../reference/silly.md) - Core Module
- [silly.signal](../reference/signal.md) - Signal Handling
