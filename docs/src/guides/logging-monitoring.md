---
title: 日志与监控指南
icon: chart-line
order: 4
category:
  - 操作指南
tag:
  - 日志
  - 监控
  - Prometheus
  - 可观测性
---

# 日志与监控指南

本指南介绍如何在 Silly 应用中实现全面的日志记录和性能监控，构建完整的可观测性方案。

## 简介

可观测性是现代应用运维的核心要素，包括三大支柱：

- **日志（Logging）**：记录离散的事件和错误信息
- **指标（Metrics）**：记录可聚合的数值数据，反映系统状态
- **追踪（Tracing）**：追踪请求在系统中的完整生命周期

Silly 框架为这三个方面提供了内置支持：

- `silly.logger`：分级日志系统，支持日志轮转
- `silly.metrics.prometheus`：Prometheus 指标收集和导出
- `silly.tracespawn/traceset`：分布式追踪 ID 生成和传播

## 日志系统

### 基本使用

`silly.logger` 提供了 DEBUG、INFO、WARN、ERROR 四个日志级别：

```lua
local logger = require "silly.logger"

-- 设置日志级别（只输出 INFO 及以上级别）
logger.setlevel(logger.INFO)

-- 基本日志输出
logger.debug("调试信息")           -- 不会输出
logger.info("服务器启动")           -- 会输出
logger.warn("连接超时，重试中")      -- 会输出
logger.error("数据库连接失败")       -- 会输出
```

### 日志格式

框架会自动为每条日志添加以下信息：

```
2025-10-21 09:37:27 0001e3d700010000 I cluster/node1.lua:30 [node1] Received HTTP GET /test
```

日志格式说明：
- `2025-10-21 09:37:27` - 时间戳
- `0001e3d700010000` - **Trace ID**（自动打印，无需业务代码显式添加）
- `I` - 日志级别（D=DEBUG, I=INFO, W=WARN, E=ERROR）
- `cluster/node1.lua:30` - 文件名和行号
- `[node1] Received HTTP GET /test` - 日志消息

::: tip Trace ID 自动打印
框架会自动在每条日志前打印当前协程的 Trace ID，业务代码**无需**在日志消息中显式包含 Trace ID。这使得同一请求的所有日志都可以通过 Trace ID 进行关联。
:::

```lua
-- ❌ 错误：不要显式打印 trace ID
local trace_id = trace.propagate()
logger.info("[" .. trace_id .. "] Processing request")

-- ✅ 正确：框架会自动打印 trace ID
logger.info("Processing request")
```

### 日志级别选择

根据不同场景选择合适的日志级别：

| 级别 | 使用场景 | 示例 |
|------|---------|------|
| **DEBUG** | 开发调试、问题排查 | 变量值、函数调用、详细请求信息 |
| **INFO** | 正常业务流程 | 服务启动/停止、用户登录、订单创建 |
| **WARN** | 潜在问题、降级操作 | 重试次数超限、缓存未命中、配置缺失 |
| **ERROR** | 错误和异常 | 数据库连接失败、请求处理失败 |

```lua
local logger = require "silly.logger"

-- 生产环境：使用 INFO 级别
logger.setlevel(logger.INFO)

-- 调试模式：使用 DEBUG 级别
logger.setlevel(logger.DEBUG)

-- 检查当前级别
if logger.getlevel() <= logger.DEBUG then
    -- 只在 DEBUG 模式下执行昂贵的序列化操作
    local json = require "json"
    logger.debug("请求详情:", json.encode(request))
end
```

### 格式化日志

使用格式化日志函数（`*f` 系列）提高日志可读性：

```lua
local logger = require "silly.logger"

-- 使用 string.format 格式
logger.infof("用户 [%s] 在 %d 秒内完成了 %d 次操作",
    username, duration, count)

logger.errorf("订单 #%d 处理失败: %s (错误码: %d)",
    order_id, error_msg, error_code)

-- 格式化参数
logger.debugf("%.2f%% 的请求在 %dms 内完成",
    percentage, latency_ms)
```

### 结构化日志

为了便于日志分析，建议使用结构化的日志格式：

```lua
local logger = require "silly.logger"
local json = require "silly.encoding.json"

-- 定义日志辅助函数
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

-- 使用
log_request("GET", "/api/users", 200, 15.3)
-- 输出: {"timestamp":1703001234,"level":"INFO","event":"http_request",...}
```

### 日志轮转

Silly 支持通过信号进行日志轮转，避免日志文件无限增长：

```lua
-- 启动时指定日志文件
-- ./silly main.lua --logpath=/var/log/myapp.log
```

执行日志轮转的 shell 脚本：

```bash
#!/bin/bash
# rotate-logs.sh

LOG_FILE="/var/log/myapp.log"
APP_PID=$(cat /var/run/myapp.pid)

# 1. 重命名当前日志文件
mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d-%H%M%S)"

# 2. 发送 SIGUSR1 信号，让 Silly 重新打开日志文件
kill -USR1 "$APP_PID"

# 3. 压缩旧日志（可选）
gzip "$LOG_FILE".*

# 4. 清理 7 天前的日志（可选）
find /var/log -name "myapp.log.*" -mtime +7 -delete
```

配合 crontab 定期执行：

```bash
# 每天凌晨 2 点执行日志轮转
0 2 * * * /path/to/rotate-logs.sh
```

### 动态调整日志级别

在生产环境中，通过信号动态调整日志级别可以避免重启服务：

```lua
local logger = require "silly.logger"
local signal = require "silly.signal"

-- 初始化为 INFO 级别
logger.setlevel(logger.INFO)

-- 通过 SIGUSR2 信号切换 DEBUG 模式
signal("SIGUSR2", function()
    if logger.getlevel() == logger.DEBUG then
        logger.setlevel(logger.INFO)
        logger.info("日志级别切换为 INFO")
    else
        logger.setlevel(logger.DEBUG)
        logger.info("日志级别切换为 DEBUG")
    end
end)
```

切换日志级别：

```bash
# 切换到 DEBUG 模式
kill -USR2 <pid>

# 再次执行切换回 INFO 模式
kill -USR2 <pid>
```

## 性能监控

### Prometheus 集成

Silly 内置了完整的 Prometheus 指标系统，支持 Counter、Gauge、Histogram 三种指标类型。

#### 创建 /metrics 端点

最基本的监控集成是暴露 `/metrics` 端点供 Prometheus 抓取：

```lua
local http = require "silly.net.http"
local prometheus = require "silly.metrics.prometheus"

-- 启动 HTTP 服务器
local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        if stream.path == "/metrics" then
            -- 收集所有指标并以 Prometheus 格式返回
            local metrics = prometheus.gather()
            stream:respond(200, {
                ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
            })
            stream:closewrite(metrics)
        else
            -- 业务逻辑
            stream:respond(200, {["content-type"] = "text/plain"})
            stream:closewrite("Hello World")
        end
    end
}
```

#### 内置指标

`prometheus.gather()` 会自动收集以下内置指标：

**Silly 运行时指标**：
- `silly_worker_backlog`：Worker 队列待处理消息数
- `silly_timer_pending`：待触发定时器数量
- `silly_tasks_runnable`：可运行任务数量
- `silly_tcp_connections`：活跃 TCP 连接数
- `silly_network_sent_bytes_total`：网络发送字节总数
- `silly_network_received_bytes_total`：网络接收字节总数

**进程资源指标**：
- `process_cpu_seconds_user`：用户态 CPU 时间（秒）
- `process_cpu_seconds_system`：内核态 CPU 时间（秒）
- `process_resident_memory_bytes`：常驻内存大小（字节）
- `process_heap_bytes`：堆内存大小（字节）

**JeMalloc 指标**（如果使用 `MALLOC=jemalloc` 编译）：
- 详细的内存分配统计

### 自定义指标

根据业务需求创建自定义指标：

#### Counter：累加计数器

Counter 只能增加，适合统计请求总数、错误次数等累积值：

```lua
local prometheus = require "silly.metrics.prometheus"

-- 创建 Counter
local http_requests_total = prometheus.counter(
    "http_requests_total",
    "HTTP 请求总数",
    {"method", "path", "status"}
)

-- 记录请求
http_requests_total:labels("GET", "/api/users", "200"):inc()
http_requests_total:labels("POST", "/api/users", "201"):inc()
http_requests_total:labels("GET", "/api/users", "500"):inc()
```

#### Gauge：仪表盘

Gauge 可增可减，适合统计当前连接数、队列深度等瞬时值：

```lua
local prometheus = require "silly.metrics.prometheus"

-- 创建 Gauge
local active_connections = prometheus.gauge(
    "active_connections",
    "当前活跃连接数"
)

local queue_depth = prometheus.gauge(
    "queue_depth",
    "队列深度",
    {"queue_name"}
)

-- 使用
active_connections:inc()        -- 增加 1
active_connections:dec()        -- 减少 1
active_connections:set(42)      -- 设置为 42
active_connections:add(10)      -- 增加 10
active_connections:sub(5)       -- 减少 5

queue_depth:labels("jobs"):set(128)
```

#### Histogram：直方图

Histogram 统计数据分布，适合统计延迟、响应大小等需要分位数分析的场景：

```lua
local prometheus = require "silly.metrics.prometheus"

-- 创建 Histogram（默认桶）
local request_duration = prometheus.histogram(
    "http_request_duration_seconds",
    "HTTP 请求延迟（秒）"
)

-- 自定义桶边界
local response_size = prometheus.histogram(
    "http_response_size_bytes",
    "HTTP 响应大小（字节）",
    {"method"},
    {100, 500, 1000, 5000, 10000, 50000, 100000}
)

-- 记录观测值
local start = os.clock()
-- ... 处理请求 ...
local duration = os.clock() - start
request_duration:observe(duration)

response_size:labels("GET"):observe(1234)
```

### 完整监控示例

一个带有完整监控的 HTTP 服务示例：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
local prometheus = require "silly.metrics.prometheus"

-- 定义指标
local http_requests_total = prometheus.counter(
    "myapp_http_requests_total",
    "HTTP 请求总数",
    {"method", "path", "status"}
)

local http_requests_in_flight = prometheus.gauge(
    "myapp_http_requests_in_flight",
    "正在处理的 HTTP 请求数"
)

local http_request_duration = prometheus.histogram(
    "myapp_http_request_duration_seconds",
    "HTTP 请求延迟（秒）",
    {"method", "path"},
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0}
)

-- HTTP 处理函数
local function handle_request(stream)
    local start = os.clock()
    http_requests_in_flight:inc()

    -- 处理不同路径
    local status_code = 200
    local response_body = ""

    if stream.path == "/metrics" then
        -- Prometheus 指标端点
        local metrics = prometheus.gather()
        stream:respond(200, {
            ["content-type"] = "text/plain; version=0.0.4",
        })
        stream:closewrite(metrics)
    elseif stream.path == "/api/users" then
        -- 业务 API
        logger.info("处理用户 API 请求:", stream.method)

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

    -- 记录指标
    local duration = os.clock() - start
    http_requests_in_flight:dec()
    http_request_duration:labels(stream.method, stream.path):observe(duration)
    http_requests_total:labels(stream.method, stream.path, tostring(status_code)):inc()

    -- 记录日志
    logger.infof("%s %s %d %.3fs",
        stream.method, stream.path, status_code, duration)
end

-- 启动服务
local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        local ok, err = silly.pcall(handle_request, stream)
        if not ok then
            logger.error("请求处理失败:", err)
            stream:respond(500, {["content-type"] = "text/plain"})
            stream:closewrite("Internal Server Error")
        end
    end
}

logger.info("服务器启动在 0.0.0.0:8080")
logger.info("Prometheus 指标: http://localhost:8080/metrics")
```

### Grafana 可视化

配置 Prometheus 抓取 Silly 应用的指标：

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

在 Grafana 中创建仪表盘，常用查询：

```promql
# QPS（每秒请求数）
rate(myapp_http_requests_total[1m])

# 按状态码分组的 QPS
sum by (status) (rate(myapp_http_requests_total[1m]))

# P95 延迟
histogram_quantile(0.95, rate(myapp_http_request_duration_seconds_bucket[5m]))

# 错误率
rate(myapp_http_requests_total{status=~"5.."}[1m])
  /
rate(myapp_http_requests_total[1m])

# 当前活跃连接数
myapp_http_requests_in_flight

# 内存使用
process_resident_memory_bytes

# CPU 使用率
rate(process_cpu_seconds_total[1m]) * 100
```

## 请求追踪

### Trace ID 生成

Silly 提供了分布式追踪 ID 系统，每个协程都有独立的 trace ID：

```lua
local silly = require "silly"
local task = require "silly.task"
local logger = require "silly.logger"

task.fork(function()
    -- 创建新的 trace ID（如果当前协程没有）
    local old_trace_id = trace.spawn()
    logger.infof("开始处理请求")
    logger.infof("请求处理完成")
    trace.attach(old_trace_id)
end)
```

### 跨服务追踪

在微服务架构中，需要将 trace ID 传播到下游服务：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
-- 服务 A：发起 HTTP 请求
local function call_service_b()
    -- 生成传播用的 trace ID
    local trace_id = trace.propagate()
    logger.info("调用服务 B")

    -- 通过 HTTP Header 传递 trace ID
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

-- 服务 B：接收请求并使用传入的 trace ID
local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        -- 提取并设置 trace ID
        local trace_id = tonumber(stream.headers["x-trace-id"])
        if trace_id then
            trace.attach(trace_id)
        else
            trace_id = trace.spawn()
        end
        logger.info("服务 B 收到请求")
        -- 处理业务逻辑
        stream:respond(200, {["content-type"] = "application/json"})
        stream:closewrite('{"status": "ok"}')
    end
}
```

### RPC 自动追踪

使用 `silly.net.cluster` 进行 RPC 调用时，trace ID 会自动传播：

```lua
local cluster = require "silly.net.cluster"
local logger = require "silly.logger"

-- 创建 cluster 服务
cluster.serve {
    marshal = ...,
    unmarshal = ...,
    call = function(peer, cmd, body)
        -- trace ID 已由 cluster 自动设置，logger 会自动使用
        logger.info("RPC 调用:", cmd)

        -- 处理 RPC 请求
        return handle_rpc(body, cmd)
    end,
    close = function(peer, errno)
        logger.info("RPC 连接关闭, errno:", errno)
    end,
}

-- 发起 RPC 调用（trace ID 自动传播）
local peer = cluster.connect("127.0.0.1:8080")
local result = cluster.call(peer, "get_user", {user_id = 123})
```

### 日志关联

将 trace ID 融入日志，实现请求的完整追踪：

```lua
local silly = require "silly"
local logger = require "silly.logger"
local json = require "silly.encoding.json"

-- 结构化日志辅助函数
local function log_with_trace(level, event, data)
    local log_entry = {
        timestamp = os.time(),
        level = level,
        event = event,
    }

    -- 合并数据
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

-- 使用
log_with_trace("INFO", "user_login", {
    user_id = 12345,
    ip = "192.168.1.100",
})

log_with_trace("ERROR", "database_error", {
    query = "SELECT * FROM users",
    error = "connection timeout",
})
```

在日志收集系统（如 ELK）中，可以通过 trace_id 查询一个请求的完整日志链路。

## 告警配置

### Prometheus 告警规则

在 Prometheus 中配置告警规则：

```yaml
# alerts.yml
groups:
  - name: silly_app_alerts
    interval: 30s
    rules:
      # 错误率过高
      - alert: HighErrorRate
        expr: |
          rate(myapp_http_requests_total{status=~"5.."}[5m])
          /
          rate(myapp_http_requests_total[5m]) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "高错误率: {{ $value | humanizePercentage }}"
          description: "应用 {{ $labels.app }} 的错误率超过 5%"

      # P95 延迟过高
      - alert: HighLatency
        expr: |
          histogram_quantile(0.95,
            rate(myapp_http_request_duration_seconds_bucket[5m])
          ) > 1.0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "P95 延迟过高: {{ $value }}s"
          description: "应用 {{ $labels.app }} 的 P95 延迟超过 1 秒"

      # 内存使用过高
      - alert: HighMemoryUsage
        expr: process_resident_memory_bytes > 1073741824  # 1GB
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "内存使用过高: {{ $value | humanize1024 }}"
          description: "应用 {{ $labels.app }} 内存使用超过 1GB"

      # Worker 队列积压
      - alert: WorkerBacklog
        expr: silly_worker_backlog > 1000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Worker 队列积压: {{ $value }} 条消息"
          description: "应用 {{ $labels.app }} 的 Worker 队列积压严重"

      # 服务不可用
      - alert: ServiceDown
        expr: up{job="silly-app"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "服务不可用"
          description: "应用 {{ $labels.app }} 无法访问"
```

### 告警渠道

配置 Alertmanager 发送告警：

```yaml
# alertmanager.yml
route:
  group_by: ['alertname', 'app']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'default'

  routes:
    # 严重告警立即通知
    - match:
        severity: critical
      receiver: 'pager'
      continue: true

    # 警告级别告警发送到邮件
    - match:
        severity: warning
      receiver: 'email'

receivers:
  # 默认接收器
  - name: 'default'
    webhook_configs:
      - url: 'http://webhook-service:8080/alerts'

  # 邮件通知
  - name: 'email'
    email_configs:
      - to: 'ops@example.com'
        from: 'alertmanager@example.com'
        smarthost: 'smtp.example.com:587'
        auth_username: 'alertmanager@example.com'
        auth_password: 'password'

  # 紧急呼叫
  - name: 'pager'
    webhook_configs:
      - url: 'http://pagerduty-integration:8080/alert'
```

### 应用内告警

也可以在应用内实现简单的告警逻辑：

```lua
local silly = require "silly"
local time = require "silly.time"
local logger = require "silly.logger"
local prometheus = require "silly.metrics.prometheus"

-- 定义告警阈值
local ALERT_CONFIG = {
    error_rate_threshold = 0.05,      -- 5% 错误率
    latency_p95_threshold = 1.0,      -- 1 秒
    memory_threshold = 1073741824,    -- 1GB
}

-- 告警状态
local alert_state = {
    error_rate_fired = false,
    latency_fired = false,
    memory_fired = false,
}

-- 发送告警
local function send_alert(alert_name, message)
    logger.errorf("[ALERT] %s: %s", alert_name, message)

    -- 这里可以集成告警渠道，如 HTTP 回调、邮件等
    -- http.post("http://alert-service/webhook",
    --     {},
    --     body = json.encode({
    --         alert = alert_name,
    --         message = message,
    --         timestamp = os.time(),
    --     })
    -- }
end

-- 定期检查指标
local function check_alerts()
    -- 这里是简化示例，实际应该从 Prometheus 指标计算
    local error_rate = 0.06  -- 示例值
    local latency_p95 = 1.2  -- 示例值
    local memory_usage = 1200000000  -- 示例值

    -- 检查错误率
    if error_rate > ALERT_CONFIG.error_rate_threshold then
        if not alert_state.error_rate_fired then
            send_alert("HighErrorRate",
                string.format("错误率 %.2f%% 超过阈值 %.2f%%",
                    error_rate * 100,
                    ALERT_CONFIG.error_rate_threshold * 100))
            alert_state.error_rate_fired = true
        end
    else
        alert_state.error_rate_fired = false
    end

    -- 检查延迟
    if latency_p95 > ALERT_CONFIG.latency_p95_threshold then
        if not alert_state.latency_fired then
            send_alert("HighLatency",
                string.format("P95 延迟 %.2fs 超过阈值 %.2fs",
                    latency_p95,
                    ALERT_CONFIG.latency_p95_threshold))
            alert_state.latency_fired = true
        end
    else
        alert_state.latency_fired = false
    end

    -- 检查内存
    if memory_usage > ALERT_CONFIG.memory_threshold then
        if not alert_state.memory_fired then
            send_alert("HighMemoryUsage",
                string.format("内存使用 %d MB 超过阈值 %d MB",
                    memory_usage / 1024 / 1024,
                    ALERT_CONFIG.memory_threshold / 1024 / 1024))
            alert_state.memory_fired = true
        end
    else
        alert_state.memory_fired = false
    end
end

-- 每 60 秒检查一次
task.fork(function()
    while true do
        time.sleep(60000)
        check_alerts()
    end
end)
```

## 完整示例：生产级 HTTP 服务

一个具备完整日志、监控和追踪的生产级 HTTP 服务示例：

```lua
local silly = require "silly"
local http = require "silly.net.http"
local logger = require "silly.logger"
local signal = require "silly.signal"
local time = require "silly.time"
local prometheus = require "silly.metrics.prometheus"
local json = require "silly.encoding.json"

-- ========== 日志配置 ==========
logger.setlevel(logger.INFO)

-- 动态调整日志级别
signal("SIGUSR2", function()
    if logger.getlevel() == logger.DEBUG then
        logger.setlevel(logger.INFO)
        logger.info("日志级别切换为 INFO")
    else
        logger.setlevel(logger.DEBUG)
        logger.info("日志级别切换为 DEBUG")
    end
end)

-- ========== 监控指标 ==========
-- 请求指标
local http_requests_total = prometheus.counter(
    "api_http_requests_total",
    "HTTP 请求总数",
    {"method", "path", "status"}
)

local http_requests_in_flight = prometheus.gauge(
    "api_http_requests_in_flight",
    "正在处理的 HTTP 请求数"
)

local http_request_duration = prometheus.histogram(
    "api_http_request_duration_seconds",
    "HTTP 请求延迟（秒）",
    {"method", "path"},
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0}
)

local http_request_size = prometheus.histogram(
    "api_http_request_size_bytes",
    "HTTP 请求大小（字节）",
    nil,
    {100, 1000, 10000, 100000, 1000000}
)

local http_response_size = prometheus.histogram(
    "api_http_response_size_bytes",
    "HTTP 响应大小（字节）",
    nil,
    {100, 1000, 10000, 100000, 1000000}
)

-- 业务指标
local user_operations = prometheus.counter(
    "api_user_operations_total",
    "用户操作总数",
    {"operation", "status"}
)

-- ========== 结构化日志 ==========
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

-- ========== 业务处理 ==========
local function handle_user_get(stream)
    logger.debug("获取用户列表")

    -- 模拟数据库查询
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
    logger.debug("创建用户")

    -- 模拟数据库插入
    time.sleep(20)

    local response = json.encode({
        id = 3,
        name = "Charlie",
        status = "created",
    })

    user_operations:labels("create_user", "success"):inc()
    return 201, response
end

-- ========== HTTP 处理 ==========
local function handle_request(stream)
    local start = os.clock()
    http_requests_in_flight:inc()

    -- 获取或创建 trace ID
    local trace_id = tonumber(stream.headers["x-trace-id"])
    if trace_id then
        silly.traceset(trace_id)
    else
        silly.tracespawn()
        trace_id = silly.tracepropagate()  -- 获取当前 trace ID 用于响应头
    end

    -- 记录请求大小
    local req_size = tonumber(stream.headers["content-length"]) or 0
    http_request_size:observe(req_size)

    -- 路由处理
    local status_code = 200
    local response_body = ""

    if stream.path == "/metrics" then
        -- Prometheus 指标端点
        local metrics = prometheus.gather()
        stream:respond(200, {
            ["content-type"] = "text/plain; version=0.0.4",
        })
        stream:closewrite(metrics)
        status_code = 200
        response_body = metrics
    elseif stream.path == "/api/users" then
        -- 用户 API
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
        -- 健康检查
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

    -- 记录指标
    local duration = os.clock() - start
    http_requests_in_flight:dec()
    http_response_size:observe(#response_body)
    http_request_duration:labels(stream.method, stream.path):observe(duration)
    http_requests_total:labels(stream.method, stream.path, tostring(status_code)):inc()

    -- 记录日志
    log_request(trace_id, stream.method, stream.path, status_code,
        duration, req_size, #response_body)
end

-- ========== 启动服务 ==========
local server = http.listen {
    addr = "0.0.0.0:8080",
    handler = function(stream)
        local ok, err = silly.pcall(handle_request, stream)
        if not ok then
            silly.tracespawn()  -- 创建新的 trace ID
            logger.error("请求处理失败:", err)

            stream:respond(500, {["content-type"] = "application/json"})
            stream:closewrite(json.encode({error = "Internal Server Error"}))

            http_requests_total:labels(stream.method, stream.path, "500"):inc()
        end
    end
}

logger.info("========================================")
logger.info("应用启动成功")
logger.infof("API 服务: http://localhost:8080/api/users")
logger.infof("健康检查: http://localhost:8080/health")
logger.infof("监控指标: http://localhost:8080/metrics")
logger.info("========================================")
logger.info("信号控制:")
logger.info("  kill -USR1 <pid>  # 重新打开日志文件")
logger.info("  kill -USR2 <pid>  # 切换日志级别 (INFO <-> DEBUG)")
logger.info("========================================")
```

## 监控面板配置

### Grafana 仪表盘 JSON

创建一个 Grafana 仪表盘来可视化 Silly 应用的监控数据：

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
        "title": "错误率",
        "targets": [
          {
            "expr": "sum(rate(api_http_requests_total{status=~\"5..\"}[1m])) / sum(rate(api_http_requests_total[1m]))"
          }
        ]
      },
      {
        "title": "P95 延迟",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, rate(api_http_request_duration_seconds_bucket[5m]))"
          }
        ]
      },
      {
        "title": "活跃连接数",
        "targets": [
          {
            "expr": "silly_tcp_connections"
          }
        ]
      },
      {
        "title": "内存使用",
        "targets": [
          {
            "expr": "process_resident_memory_bytes"
          }
        ]
      },
      {
        "title": "Worker 队列深度",
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

## 最佳实践

### 日志最佳实践

1. **合理使用日志级别**：避免在生产环境使用 DEBUG 级别，会产生大量日志
2. **结构化日志**：使用 JSON 格式便于日志收集和分析
3. **避免敏感信息**：不要记录密码、token 等敏感数据
4. **控制日志量**：对于高频操作，考虑采样记录
5. **定期轮转**：避免日志文件无限增长

### 监控最佳实践

1. **指标命名**：遵循 Prometheus 命名规范（snake_case，带单位后缀）
2. **避免高基数**：不要使用用户 ID 等作为标签
3. **合理选择指标类型**：
   - Counter：累积值（请求总数）
   - Gauge：瞬时值（当前连接数）
   - Histogram：分布（延迟）
4. **设置合理的桶边界**：根据实际数据分布选择 Histogram 的桶
5. **监控关键业务指标**：不仅要监控系统指标，还要监控业务指标

### 追踪最佳实践

1. **始终传播 trace ID**：在跨服务调用时传递 trace ID
3. **日志关联**：将 trace ID 融入日志，便于问题排查
4. **保留足够信息**：trace ID 要在日志、指标、错误报告中都包含

## 参见

- [silly.logger](../reference/logger.md) - 日志系统 API 参考
- [silly.metrics.prometheus](../reference/metrics/prometheus.md) - Prometheus 指标 API 参考
- [silly](../reference/silly.md) - 核心模块
- [silly.signal](../reference/signal.md) - 信号处理
