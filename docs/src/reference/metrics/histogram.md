---
title: histogram
icon: chart-histogram
category:
  - API 参考
tag:
  - metrics
  - histogram
  - 直方图
  - 监控
---

# silly.metrics.histogram

Histogram（直方图）指标模块，用于统计观察值的分布情况，自动计算分位数和统计特征。

## 模块简介

`silly.metrics.histogram` 模块实现了 Prometheus Histogram 指标类型，用于对观察值进行采样并统计其分布特征。Histogram 将观察值分配到预定义的桶（bucket）中，并自动维护三个关键统计量：

- **桶计数（bucket counts）**：每个桶的累积观察值数量
- **总和（sum）**：所有观察值的总和
- **总数（count）**：观察值的总数量

通过这些统计量，可以计算平均值、分位数（如 P50、P95、P99）等重要性能指标。

## 模块导入

```lua validate
local histogram = require "silly.metrics.histogram"

-- 创建一个基本的直方图
local latency = histogram("request_latency_seconds", "Request latency in seconds")

-- 记录观察值
latency:observe(0.123)
latency:observe(0.456)
latency:observe(0.789)

-- 查看内部状态
print("Sum:", latency.sum)
print("Count:", latency.count)
```

::: warning 独立使用
`histogram` 模块需要单独 require，不能通过 `prometheus.histogram` 访问到此模块的构造函数。如果需要自动注册到 Prometheus Registry，请使用 `silly.metrics.prometheus.histogram()`。
:::

## 核心概念

### 桶（Buckets）

桶是 Histogram 的核心概念，定义了观察值的分组边界。每个桶有一个上界值（le = less than or equal），所有小于等于该值的观察都会计入该桶。

**默认桶边界**：
```lua
{0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0}
```

这些默认值适合测量以秒为单位的延迟（从 5ms 到 10s）。

**桶的累积特性**：
- 桶计数是累积的：如果观察值为 0.3，则会同时增加 `le="0.5"`、`le="0.75"`、`le="1.0"` 等所有大于等于 0.3 的桶的计数
- 最后总会有一个 `le="+Inf"` 的桶，包含所有观察值

**示例**：

```lua validate
local histogram = require "silly.metrics.histogram"

-- 使用自定义桶边界（适合字节大小统计）
local response_size = histogram(
    "response_size_bytes",
    "HTTP response size distribution",
    nil,  -- 无标签
    {100, 500, 1000, 5000, 10000, 50000, 100000}
)

-- 记录一些观察值
response_size:observe(250)   -- 会计入 le="500", le="1000", ..., le="+Inf"
response_size:observe(1500)  -- 会计入 le="5000", le="10000", ..., le="+Inf"
response_size:observe(75000) -- 会计入 le="100000", le="+Inf"

print("桶设置:", table.concat(response_size.buckets, ", "))
```

### 分位数（Quantiles）

分位数表示数据分布的特定百分位点。例如：

- **P50（中位数）**：50% 的观察值小于等于此值
- **P95**：95% 的观察值小于等于此值
- **P99**：99% 的观察值小于等于此值

虽然 Histogram 本身不直接计算分位数，但通过桶计数，Prometheus 可以使用 `histogram_quantile()` 函数估算分位数。

**PromQL 示例**：
```promql
# 计算 P95 延迟
histogram_quantile(0.95, rate(request_latency_seconds_bucket[5m]))

# 计算 P99 延迟
histogram_quantile(0.99, rate(request_latency_seconds_bucket[5m]))
```

**桶边界选择建议**：
- 根据实际数据分布选择桶边界
- 确保关键分位数（如 P95、P99）附近有足够的桶以提高精度
- 桶数量通常在 10-20 个之间

### 统计量

每个 Histogram 自动维护三个统计量：

1. **sum**：所有观察值的总和
   - 用于计算平均值：`sum / count`

2. **count**：观察值的总数量
   - 表示总共记录了多少次观察

3. **bucketcounts**：每个桶的累积计数
   - 用于计算分位数和分布特征

```lua validate
local histogram = require "silly.metrics.histogram"

local h = histogram("test_histogram", "Test histogram")

h:observe(1.0)
h:observe(2.0)
h:observe(3.0)

-- 访问统计量
print("总和:", h.sum)           -- 6.0
print("计数:", h.count)         -- 3
print("平均值:", h.sum / h.count) -- 2.0
```

### Histogram vs Summary

Prometheus 有两种类似的指标类型：

| 特性 | Histogram | Summary |
|------|-----------|---------|
| 分位数计算 | 服务端（Prometheus）计算 | 客户端计算 |
| 可聚合性 | 可聚合（可合并多个实例） | 不可聚合 |
| 精度 | 估算（取决于桶划分） | 精确 |
| 资源开销 | 较低 | 较高 |
| 配置灵活性 | 查询时可调整分位数 | 固定分位数 |

Silly 框架只实现了 Histogram，因为它更适合分布式系统。

## API 参考

### histogram(name, help, labelnames, buckets)

创建一个新的 Histogram 指标或 HistogramVec（带标签的 Histogram）。

- **参数**:
  - `name`: `string` - 指标名称，必须符合 Prometheus 命名规范
  - `help`: `string` - 指标描述文本
  - `labelnames`: `table?` - 标签名称列表（可选），例如 `{"method", "endpoint"}`
  - `buckets`: `table?` - 桶边界数组（可选），默认为 `{0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0}`

- **返回值**:
  - `histogram` - Histogram 对象（无标签时）
  - `histogramvec` - HistogramVec 对象（带标签时）

- **说明**:
  - 桶边界会自动排序
  - 桶边界必须是正数
  - 不包含标签名称时，返回简单的 Histogram 对象
  - 包含标签名称时，返回 HistogramVec 对象，需要通过 `labels()` 获取具体实例

- **示例**:

```lua validate
local histogram = require "silly.metrics.histogram"

-- 基本用法：无标签，使用默认桶边界
local request_latency = histogram(
    "request_latency_seconds",
    "Request latency in seconds"
)
request_latency:observe(0.123)

-- 自定义桶边界
local db_query_duration = histogram(
    "db_query_duration_seconds",
    "Database query duration",
    nil,  -- 无标签
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0}
)
db_query_duration:observe(0.023)

-- 带标签的 Histogram
local http_response_size = histogram(
    "http_response_size_bytes",
    "HTTP response size by endpoint",
    {"endpoint"},
    {100, 1000, 10000, 100000, 1000000}
)
http_response_size:labels("/api/users"):observe(5432)
http_response_size:labels("/api/products"):observe(12345)
```

## Histogram 对象方法

### histogram:observe(value)

记录一次观察值。

- **参数**:
  - `value`: `number` - 观察到的数值

- **返回值**: 无

- **说明**:
  - 自动更新 `sum`（累加观察值）
  - 自动更新 `count`（计数加 1）
  - 自动将观察值归入对应的桶（所有 `<= value` 的桶边界的计数都会增加，这是 Prometheus Histogram 的累积特性）
  - 观察值会计入所有大于等于该值的桶边界

- **示例**:

```lua validate
local histogram = require "silly.metrics.histogram"

local latency = histogram("request_latency", "Request latency in seconds")

-- 记录多次观察
latency:observe(0.005)  -- 快速请求
latency:observe(0.123)  -- 正常请求
latency:observe(2.456)  -- 慢请求
latency:observe(15.0)   -- 超时请求（超过默认最大桶 10.0）

-- 查看统计结果
print("总计数:", latency.count)  -- 4
print("总和:", latency.sum)      -- 17.584
print("平均值:", latency.sum / latency.count)  -- 4.396
```

### histogram:collect(buf)

收集指标数据到缓冲区（内部方法）。

- **参数**:
  - `buf`: `table` - 指标数据缓冲区

- **返回值**: 无

- **说明**:
  - 此方法由 Registry 在调用 `gather()` 时自动调用
  - 一般不需要手动调用
  - 将当前 Histogram 对象添加到缓冲区

- **示例**:

```lua validate
local histogram = require "silly.metrics.histogram"

local h = histogram("test_metric", "Test metric")
h:observe(1.0)

-- 内部收集方法
local buf = {}
h:collect(buf)

print("收集到的指标数量:", #buf)  -- 1
print("指标名称:", buf[1].name)   -- "test_metric"
print("指标类型:", buf[1].kind)   -- "histogram"
```

## HistogramVec 对象方法

### histogramvec:labels(...)

获取或创建带指定标签值的 Histogram 实例。

- **参数**:
  - `...`: `string|number` - 标签值，数量和顺序必须与创建时的 `labelnames` 参数一致

- **返回值**:
  - `histogram` - Histogram 实例

- **说明**:
  - 首次调用时会创建新的 Histogram 实例
  - 相同标签值的后续调用会返回同一个实例
  - 标签值的顺序必须与 `labelnames` 的顺序一致
  - 标签值会被缓存，避免重复创建

- **示例**:

```lua validate
local histogram = require "silly.metrics.histogram"

-- 创建带标签的 HistogramVec
local request_duration = histogram(
    "http_request_duration_seconds",
    "HTTP request duration by method and endpoint",
    {"method", "endpoint"}
)

-- 获取不同标签组合的实例
local get_users = request_duration:labels("GET", "/api/users")
local post_orders = request_duration:labels("POST", "/api/orders")
local get_products = request_duration:labels("GET", "/api/products")

-- 记录观察值
get_users:observe(0.023)
get_users:observe(0.045)

post_orders:observe(0.156)
post_orders:observe(0.234)

get_products:observe(0.012)

-- 再次获取相同标签组合，返回同一个实例
local get_users_again = request_duration:labels("GET", "/api/users")
get_users_again:observe(0.034)  -- 会累加到之前的统计中

print("GET /api/users 计数:", get_users.count)  -- 3
```

### histogramvec:collect(buf)

收集所有标签组合的指标数据到缓冲区（内部方法）。

- **参数**:
  - `buf`: `table` - 指标数据缓冲区

- **返回值**: 无

- **说明**:
  - 此方法由 Registry 在调用 `gather()` 时自动调用
  - 会收集所有已创建的标签组合
  - 一般不需要手动调用

## 使用示例

### 示例 1: HTTP 请求延迟监控

```lua validate
local histogram = require "silly.metrics.histogram"

-- 创建 HTTP 请求延迟直方图
local http_request_duration = histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    {"method", "path"},
    {0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0}
)

-- 模拟请求处理
local function handle_request(method, path, duration)
    http_request_duration:labels(method, path):observe(duration)
end

-- 记录各种请求
handle_request("GET", "/api/users", 0.023)
handle_request("GET", "/api/users", 0.018)
handle_request("GET", "/api/users", 0.156)
handle_request("POST", "/api/orders", 0.234)
handle_request("POST", "/api/orders", 0.089)
handle_request("GET", "/api/products", 0.012)

-- 查看统计
local get_users = http_request_duration:labels("GET", "/api/users")
print("GET /api/users - 计数:", get_users.count)
print("GET /api/users - 平均延迟:", get_users.sum / get_users.count, "秒")
```

### 示例 2: 数据库查询性能监控

```lua validate
local histogram = require "silly.metrics.histogram"

-- 数据库查询耗时直方图（毫秒级别）
local db_query_duration = histogram(
    "db_query_duration_seconds",
    "Database query duration",
    {"operation", "table"},
    {0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0}
)

-- 模拟数据库操作
local function execute_query(operation, table_name, duration_ms)
    local duration_sec = duration_ms / 1000
    db_query_duration:labels(operation, table_name):observe(duration_sec)
end

-- 记录查询
execute_query("SELECT", "users", 2.3)    -- 2.3ms
execute_query("SELECT", "users", 1.8)
execute_query("SELECT", "users", 15.6)
execute_query("INSERT", "orders", 23.4)
execute_query("INSERT", "orders", 18.9)
execute_query("UPDATE", "products", 45.2)
execute_query("DELETE", "cache", 1.2)

-- 统计 SELECT users 的性能
local select_users = db_query_duration:labels("SELECT", "users")
print("SELECT users - 总次数:", select_users.count)
print("SELECT users - 总耗时:", select_users.sum * 1000, "ms")
print("SELECT users - 平均耗时:", (select_users.sum / select_users.count) * 1000, "ms")
```

### 示例 3: 消息处理时间分布

```lua validate
local histogram = require "silly.metrics.histogram"

-- 消息处理时间直方图
local message_processing_time = histogram(
    "message_processing_seconds",
    "Message processing time by type",
    {"message_type"},
    {0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0, 30.0, 60.0}
)

-- 模拟消息处理
local function process_message(msg_type, processing_time)
    message_processing_time:labels(msg_type):observe(processing_time)
end

-- 记录各类消息的处理时间
process_message("email", 0.123)
process_message("email", 0.234)
process_message("email", 0.156)

process_message("sms", 0.045)
process_message("sms", 0.038)

process_message("push", 0.012)
process_message("push", 0.018)
process_message("push", 0.015)

process_message("webhook", 1.234)
process_message("webhook", 2.567)

-- 查看各类消息的统计
local email_stats = message_processing_time:labels("email")
local sms_stats = message_processing_time:labels("sms")
local push_stats = message_processing_time:labels("push")

print("Email - 平均耗时:", email_stats.sum / email_stats.count, "秒")
print("SMS - 平均耗时:", sms_stats.sum / sms_stats.count, "秒")
print("Push - 平均耗时:", push_stats.sum / push_stats.count, "秒")
```

### 示例 4: API 响应大小统计

```lua validate
local histogram = require "silly.metrics.histogram"

-- API 响应大小直方图（字节）
local api_response_size = histogram(
    "api_response_size_bytes",
    "API response size distribution",
    {"endpoint"},
    {100, 500, 1000, 5000, 10000, 50000, 100000, 500000, 1000000}
)

-- 模拟 API 响应
local function send_response(endpoint, size_bytes)
    api_response_size:labels(endpoint):observe(size_bytes)
end

-- 记录各个端点的响应大小
send_response("/api/users", 1234)
send_response("/api/users", 2345)
send_response("/api/users", 987)

send_response("/api/products", 45678)
send_response("/api/products", 56789)
send_response("/api/products", 34567)

send_response("/api/orders", 123456)
send_response("/api/orders", 234567)

send_response("/api/stats", 5432100)  -- 大数据导出

-- 统计分析
local users_stats = api_response_size:labels("/api/users")
local products_stats = api_response_size:labels("/api/products")

print("/api/users - 平均大小:", users_stats.sum / users_stats.count, "bytes")
print("/api/products - 平均大小:", products_stats.sum / products_stats.count, "bytes")
```

### 示例 5: 批处理任务大小分布

```lua validate
local histogram = require "silly.metrics.histogram"

-- 批处理任务大小直方图
local batch_size = histogram(
    "batch_processing_size",
    "Number of items processed per batch",
    {"job_type"},
    {10, 50, 100, 500, 1000, 5000, 10000}
)

-- 批处理任务执行时间
local batch_duration = histogram(
    "batch_processing_duration_seconds",
    "Batch processing duration",
    {"job_type"},
    {1, 5, 10, 30, 60, 300, 600}
)

-- 模拟批处理
local function process_batch(job_type, item_count, duration)
    batch_size:labels(job_type):observe(item_count)
    batch_duration:labels(job_type):observe(duration)
end

-- 记录批处理任务
process_batch("email_dispatch", 523, 12.3)
process_batch("email_dispatch", 1234, 23.4)
process_batch("email_dispatch", 876, 15.6)

process_batch("data_sync", 5432, 123.4)
process_batch("data_sync", 7890, 234.5)

process_batch("report_generation", 150, 45.6)
process_batch("report_generation", 200, 56.7)

-- 分析批处理效率
local email_size = batch_size:labels("email_dispatch")
local email_time = batch_duration:labels("email_dispatch")

local avg_size = email_size.sum / email_size.count
local avg_time = email_time.sum / email_time.count

print("邮件批处理 - 平均批次大小:", avg_size, "封")
print("邮件批处理 - 平均处理时间:", avg_time, "秒")
print("邮件批处理 - 吞吐量:", avg_size / avg_time, "封/秒")
```

### 示例 6: 缓存操作延迟监控

```lua validate
local histogram = require "silly.metrics.histogram"

-- 缓存操作延迟（微秒级别）
local cache_operation_duration = histogram(
    "cache_operation_duration_seconds",
    "Cache operation latency",
    {"operation", "cache_type"},
    {0.00001, 0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05}
)

-- 模拟缓存操作
local function cache_op(operation, cache_type, latency_us)
    local latency_sec = latency_us / 1000000
    cache_operation_duration:labels(operation, cache_type):observe(latency_sec)
end

-- 记录 Redis 操作
cache_op("GET", "redis", 50)    -- 50微秒
cache_op("GET", "redis", 45)
cache_op("GET", "redis", 120)
cache_op("SET", "redis", 80)
cache_op("SET", "redis", 95)
cache_op("DEL", "redis", 60)

-- 记录内存缓存操作
cache_op("GET", "memory", 5)    -- 5微秒
cache_op("GET", "memory", 3)
cache_op("GET", "memory", 8)
cache_op("SET", "memory", 10)
cache_op("SET", "memory", 12)

-- 对比不同缓存的性能
local redis_get = cache_operation_duration:labels("GET", "redis")
local memory_get = cache_operation_duration:labels("GET", "memory")

print("Redis GET - 平均延迟:", (redis_get.sum / redis_get.count) * 1000000, "微秒")
print("Memory GET - 平均延迟:", (memory_get.sum / memory_get.count) * 1000000, "微秒")
```

### 示例 7: 文件上传大小分布

```lua validate
local histogram = require "silly.metrics.histogram"

-- 文件上传大小分布（MB）
local upload_size = histogram(
    "file_upload_size_megabytes",
    "File upload size distribution",
    {"file_type"},
    {0.1, 0.5, 1, 5, 10, 50, 100, 500}
)

-- 上传处理时间
local upload_duration = histogram(
    "file_upload_duration_seconds",
    "File upload duration",
    {"file_type"}
)

-- 模拟文件上传
local function upload_file(file_type, size_bytes, duration)
    local size_mb = size_bytes / (1024 * 1024)
    upload_size:labels(file_type):observe(size_mb)
    upload_duration:labels(file_type):observe(duration)
end

-- 记录上传
upload_file("image", 2 * 1024 * 1024, 1.23)       -- 2MB
upload_file("image", 5 * 1024 * 1024, 2.45)       -- 5MB
upload_file("image", 1.5 * 1024 * 1024, 0.89)     -- 1.5MB

upload_file("video", 50 * 1024 * 1024, 23.4)      -- 50MB
upload_file("video", 120 * 1024 * 1024, 56.7)     -- 120MB

upload_file("document", 0.5 * 1024 * 1024, 0.34)  -- 0.5MB
upload_file("document", 2 * 1024 * 1024, 1.12)    -- 2MB

-- 分析上传速度
local video_size = upload_size:labels("video")
local video_time = upload_duration:labels("video")

local avg_video_size = video_size.sum / video_size.count
local avg_video_time = video_time.sum / video_time.count

print("视频上传 - 平均大小:", avg_video_size, "MB")
print("视频上传 - 平均耗时:", avg_video_time, "秒")
print("视频上传 - 平均速度:", avg_video_size / avg_video_time, "MB/s")
```

### 示例 8: 完整监控系统集成

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local histogram = require "silly.metrics.histogram"
local prometheus = require "silly.metrics.prometheus"
local task = require "silly.task"

-- 通过 prometheus 创建并自动注册
local request_duration = prometheus.histogram(
    "http_request_duration_seconds",
    "HTTP request duration",
    {"method", "path", "status"}
)

local response_size = prometheus.histogram(
    "http_response_size_bytes",
    "HTTP response size",
    {"method", "path"},
    {100, 500, 1000, 5000, 10000, 50000, 100000}
)

task.fork(function()
    -- 启动业务服务器
    local server = http.listen {
        addr = "0.0.0.0:8080",
        handler = function(stream)
            local start_time = silly.time.now()
            local method = stream.method
            local path = stream.path

            -- 模拟业务处理
            silly.time.sleep(math.random(10, 200))

            local response_body = '{"status":"ok","data":[]}'
            local status = 200

            stream:respond(status, {
                ["content-type"] = "application/json",
                ["content-length"] = #response_body
            })
            stream:closewrite(response_body)

            -- 记录指标
            local duration = (silly.time.now() - start_time) / 1000
            request_duration:labels(method, path, tostring(status)):observe(duration)
            response_size:labels(method, path):observe(#response_body)
        end
    }

    -- 启动指标导出服务器
    local metrics_server = http.listen {
        addr = "0.0.0.0:9090",
        handler = function(stream)
            if stream.path == "/metrics" then
                local metrics = prometheus.gather()
                stream:respond(200, {
                    ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
                    ["content-length"] = #metrics
                })
                stream:closewrite(metrics)
            else
                stream:respond(404, {["content-type"] = "text/plain"})
                stream:closewrite("Not Found")
            end
        end
    }

    print("业务服务器: http://localhost:8080")
    print("监控指标: http://localhost:9090/metrics")
end)
```

## 注意事项

### 桶边界选择

选择合适的桶边界对于准确计算分位数至关重要：

1. **覆盖预期范围**：
   - 桶边界应该覆盖大部分（95%+）的观察值
   - 最小桶应该小于 P50，最大桶应该大于 P99

2. **关键分位数附近密集**：
   - 如果需要精确的 P95，在 90%-98% 分位附近设置更密集的桶
   - 示例：`{0.01, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.5, 1.0}` 在低延迟区域更密集

3. **桶数量适中**：
   - 通常 10-20 个桶足够
   - 桶数量过多会增加内存和计算开销
   - 桶数量过少会降低分位数精度

4. **使用对数刻度**：
   - 对于跨度大的数据（如延迟、大小），使用对数刻度
   - 示例：`{0.001, 0.01, 0.1, 1, 10, 100}` 或 `{1, 2, 5, 10, 20, 50, 100}`

**不同场景的推荐桶边界**：

```lua validate
local histogram = require "silly.metrics.histogram"

-- 1. 快速 API 延迟（毫秒级）
local fast_api = histogram("fast_api_latency", "Fast API latency",
    nil, {0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5})

-- 2. 常规 Web 请求延迟（100ms - 10s）
local web_latency = histogram("web_latency", "Web request latency",
    nil, {0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 10.0})

-- 3. 数据库查询延迟（微秒到秒）
local db_latency = histogram("db_latency", "Database query latency",
    nil, {0.0001, 0.001, 0.01, 0.1, 1.0})

-- 4. 文件大小（字节）
local file_size = histogram("file_size", "File size bytes",
    nil, {1024, 10240, 102400, 1048576, 10485760, 104857600})

-- 5. 批处理大小（数量）
local batch_size = histogram("batch_size", "Batch processing size",
    nil, {10, 50, 100, 500, 1000, 5000})

print("已创建 5 个不同场景的直方图")
```

### 内存使用

Histogram 的内存使用与以下因素相关：

1. **桶数量**：每个桶需要存储一个计数器
2. **标签组合数**：每个标签组合都会创建独立的桶数组
3. **观察值数量**：不影响内存（只更新计数器）

**内存估算**：
```
单个 Histogram 内存 ≈ 桶数量 × 8 字节 + 固定开销（约 200 字节）
HistogramVec 总内存 ≈ 单个 Histogram 内存 × 标签组合数
```

**避免内存爆炸**：

```lua validate
local histogram = require "silly.metrics.histogram"

-- 坏例子：高基数标签导致内存爆炸
local bad_histogram = histogram("bad_requests", "Requests",
    {"user_id", "session_id"},  -- 标签组合数 = 用户数 × 会话数（可能数百万）
    {0.1, 0.5, 1.0, 5.0})

-- 好例子：低基数标签
local good_histogram = histogram("good_requests", "Requests",
    {"method", "status"},  -- 标签组合数 = 方法数 × 状态数（几十个）
    {0.1, 0.5, 1.0, 5.0})

-- 如果有 10 个 HTTP 方法，10 个状态码，10 个桶：
-- 内存使用 ≈ (10 × 8 + 200) × 10 × 10 ≈ 28KB

print("推荐使用低基数标签")
```

### 性能考虑

1. **observe() 操作的时间复杂度**：
   - O(桶数量)，遍历所有桶以实现 Prometheus Histogram 的累积特性
   - 每次观察需要更新所有值大于等于观察值的桶计数器

2. **热路径优化**：
   ```lua validate
   local histogram = require "silly.metrics.histogram"

   local h = histogram("api_latency", "API latency", {"endpoint"})

   -- 不好：每次都查找标签
   for i = 1, 10000 do
       h:labels("/api/users"):observe(0.1)  -- 每次都查找缓存
   end

   -- 好：缓存标签实例
   local users_h = h:labels("/api/users")
   for i = 1, 10000 do
       users_h:observe(0.1)  -- 直接操作，无查找开销
   end

   print("推荐缓存常用标签组合")
   ```

3. **桶数量建议**：
   - 桶数量 < 20：性能影响可忽略
   - 桶数量 20-50：可接受
   - 桶数量 > 50：需要评估性能影响

### 与 Prometheus 集成

**导出格式**：

Histogram 导出为 Prometheus 文本格式时包含三部分：

```
# HELP http_request_duration_seconds HTTP request duration
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.005"} 10
http_request_duration_seconds_bucket{le="0.01"} 25
http_request_duration_seconds_bucket{le="0.025"} 50
http_request_duration_seconds_bucket{le="0.05"} 80
http_request_duration_seconds_bucket{le="0.1"} 95
http_request_duration_seconds_bucket{le="+Inf"} 100
http_request_duration_seconds_sum 4.56
http_request_duration_seconds_count 100
```

**常用 PromQL 查询**：

```promql
# 这些 PromQL 查询在 Prometheus 服务器中执行

# 1. 计算 P95 延迟
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))

# 2. 计算 P99 延迟
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))

# 3. 计算平均延迟
rate(http_request_duration_seconds_sum[5m]) / rate(http_request_duration_seconds_count[5m])

# 4. 计算 QPS
rate(http_request_duration_seconds_count[5m])

# 5. 按 endpoint 分组的 P95 延迟
histogram_quantile(0.95, sum by (endpoint, le) (rate(http_request_duration_seconds_bucket[5m])))
```

示例代码：

```lua validate
local histogram = require "silly.metrics.histogram"
local h = histogram("example_metric", "Example metric")
h:observe(1.0)
print("Histogram 指标可通过 Prometheus 的 histogram_quantile() 函数计算分位数")
```

### 线程安全

- Silly 框架使用单线程事件循环（Worker 线程）
- 所有 Histogram 操作都在 Worker 线程中执行
- 无需担心并发问题
- 如果使用多进程架构，每个进程需要独立收集指标

### 精度与误差

Histogram 计算的分位数是**估算值**，精度取决于桶划分：

1. **精确场景**：观察值恰好等于某个桶边界
   - 示例：P95 = 1.0，且有桶边界 `le="1.0"`

2. **估算场景**：观察值分布在两个桶之间
   - 示例：P95 在 0.5 和 1.0 之间，Prometheus 会线性插值

3. **提高精度**：
   - 在关键分位数附近设置更密集的桶
   - 使用更多桶（但会增加开销）

```lua validate
local histogram = require "silly.metrics.histogram"

-- 粗粒度桶：P95 精度较低
local coarse = histogram("coarse_metric", "Coarse buckets",
    nil, {0.1, 1.0, 10.0})

-- 细粒度桶：P95 精度较高
local fine = histogram("fine_metric", "Fine buckets",
    nil, {0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 2.0, 5.0, 10.0})

-- 自适应桶：在关键区域（0.5-2.0）更密集
local adaptive = histogram("adaptive_metric", "Adaptive buckets",
    nil, {0.1, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.2, 1.5, 2.0, 5.0, 10.0})

print("推荐在关键分位数附近使用更密集的桶")
```

## 参见

- [silly.metrics.prometheus](./prometheus.md) - Prometheus 指标导出模块
- [silly.metrics.counter](./counter.md) - Counter 指标类型
- [silly.metrics.gauge](./gauge.md) - Gauge 指标类型
- [silly.net.http](../net/http.md) - HTTP 服务器和客户端
- [Prometheus Histogram 文档](https://prometheus.io/docs/concepts/metric_types/#histogram)
- [Histogram vs Summary](https://prometheus.io/docs/practices/histograms/)
