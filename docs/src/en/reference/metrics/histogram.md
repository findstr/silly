---
title: histogram
icon: chart-histogram
category:
  - API Reference
tag:
  - metrics
  - histogram
  - monitoring
---

# silly.metrics.histogram

Histogram metric module for statistical distribution of observed values, automatically calculating quantiles and statistical characteristics.

## Module Overview

The `silly.metrics.histogram` module implements the Prometheus Histogram metric type, used for sampling observed values and calculating their distribution characteristics. Histogram allocates observed values into predefined buckets and automatically maintains three key statistics:

- **Bucket counts**: Cumulative count of observations in each bucket
- **Sum**: Total sum of all observed values
- **Count**: Total number of observations

Through these statistics, important performance metrics such as average, quantiles (P50, P95, P99) can be calculated.

## Module Import

```lua validate
local histogram = require "silly.metrics.histogram"

-- Create a basic histogram
local latency = histogram("request_latency_seconds", "Request latency in seconds")

-- Record observations
latency:observe(0.123)
latency:observe(0.456)
latency:observe(0.789)

-- View internal state
print("Sum:", latency.sum)
print("Count:", latency.count)
```

::: warning Standalone Usage
The `histogram` module must be required separately and cannot be accessed via `prometheus.histogram`. If you need automatic registration to the Prometheus Registry, use `silly.metrics.prometheus.histogram()`.
:::

## Core Concepts

### Buckets

Buckets are the core concept of Histogram, defining the grouping boundaries for observed values. Each bucket has an upper bound (le = less than or equal), and all observations less than or equal to that value are counted in that bucket.

**Default bucket boundaries**:
```lua
{0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0}
```

These defaults are suitable for measuring latency in seconds (from 5ms to 10s).

**Cumulative nature of buckets**:
- Bucket counts are cumulative: if an observed value is 0.3, it increments the counts of all buckets with boundaries greater than or equal to 0.3 (`le="0.5"`, `le="0.75"`, `le="1.0"`, etc.)
- There's always a `le="+Inf"` bucket that includes all observations

**Example**:

```lua validate
local histogram = require "silly.metrics.histogram"

-- Use custom bucket boundaries (suitable for byte size statistics)
local response_size = histogram(
    "response_size_bytes",
    "HTTP response size distribution",
    nil,  -- No labels
    {100, 500, 1000, 5000, 10000, 50000, 100000}
)

-- Record some observations
response_size:observe(250)   -- Counted in le="500", le="1000", ..., le="+Inf"
response_size:observe(1500)  -- Counted in le="5000", le="10000", ..., le="+Inf"
response_size:observe(75000) -- Counted in le="100000", le="+Inf"

print("Buckets:", table.concat(response_size.buckets, ", "))
```

### Quantiles

Quantiles represent specific percentile points in the data distribution. For example:

- **P50 (Median)**: 50% of observations are less than or equal to this value
- **P95**: 95% of observations are less than or equal to this value
- **P99**: 99% of observations are less than or equal to this value

While Histogram itself doesn't directly calculate quantiles, through bucket counts, Prometheus can estimate quantiles using the `histogram_quantile()` function.

**PromQL Example**:
```promql
# Calculate P95 latency
histogram_quantile(0.95, rate(request_latency_seconds_bucket[5m]))

# Calculate P99 latency
histogram_quantile(0.99, rate(request_latency_seconds_bucket[5m]))
```

**Bucket boundary selection recommendations**:
- Choose bucket boundaries based on actual data distribution
- Ensure sufficient buckets around critical quantiles (like P95, P99) for better precision
- Bucket count typically between 10-20

### Statistics

Each Histogram automatically maintains three statistics:

1. **sum**: Total sum of all observed values
   - Used to calculate average: `sum / count`

2. **count**: Total number of observations
   - Represents how many observations have been recorded

3. **bucketcounts**: Cumulative count for each bucket
   - Used to calculate quantiles and distribution characteristics

```lua validate
local histogram = require "silly.metrics.histogram"

local h = histogram("test_histogram", "Test histogram")

h:observe(1.0)
h:observe(2.0)
h:observe(3.0)

-- Access statistics
print("Sum:", h.sum)           -- 6.0
print("Count:", h.count)         -- 3
print("Average:", h.sum / h.count) -- 2.0
```

### Histogram vs Summary

Prometheus has two similar metric types:

| Feature | Histogram | Summary |
|---------|-----------|---------|
| Quantile calculation | Server-side (Prometheus) | Client-side |
| Aggregatable | Yes (can merge multiple instances) | No |
| Accuracy | Estimated (depends on bucket division) | Exact |
| Resource overhead | Lower | Higher |
| Configuration flexibility | Quantiles adjustable at query time | Fixed quantiles |

The Silly framework only implements Histogram because it's more suitable for distributed systems.

## API Reference

### histogram(name, help, labelnames, buckets)

Creates a new Histogram metric or HistogramVec (Histogram with labels).

- **Parameters**:
  - `name`: `string` - Metric name, must comply with Prometheus naming conventions
  - `help`: `string` - Metric description text
  - `labelnames`: `table?` - Label name list (optional), e.g., `{"method", "endpoint"}`
  - `buckets`: `table?` - Bucket boundary array (optional), defaults to `{0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0}`

- **Returns**:
  - `histogram` - Histogram object (when no labels)
  - `histogramvec` - HistogramVec object (when labels provided)

- **Notes**:
  - Bucket boundaries are automatically sorted
  - Bucket boundaries must be positive numbers
  - Without label names, returns a simple Histogram object
  - With label names, returns a HistogramVec object, requiring `labels()` to get specific instances

- **Example**:

```lua validate
local histogram = require "silly.metrics.histogram"

-- Basic usage: no labels, default bucket boundaries
local request_latency = histogram(
    "request_latency_seconds",
    "Request latency in seconds"
)
request_latency:observe(0.123)

-- Custom bucket boundaries
local db_query_duration = histogram(
    "db_query_duration_seconds",
    "Database query duration",
    nil,  -- No labels
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0}
)
db_query_duration:observe(0.023)

-- Histogram with labels
local http_response_size = histogram(
    "http_response_size_bytes",
    "HTTP response size by endpoint",
    {"endpoint"},
    {100, 1000, 10000, 100000, 1000000}
)
http_response_size:labels("/api/users"):observe(5432)
http_response_size:labels("/api/products"):observe(12345)
```

## Histogram Object Methods

### histogram:observe(value)

Records an observed value.

- **Parameters**:
  - `value`: `number` - Observed numerical value

- **Returns**: None

- **Notes**:
  - Automatically updates `sum` (accumulates observed value)
  - Automatically updates `count` (increments by 1)
  - Automatically assigns observed value to corresponding buckets (all bucket boundary counts where `<= value` are incremented, reflecting Prometheus Histogram's cumulative nature)
  - Observed value is counted in all bucket boundaries greater than or equal to that value

- **Example**:

```lua validate
local histogram = require "silly.metrics.histogram"

local latency = histogram("request_latency", "Request latency in seconds")

-- Record multiple observations
latency:observe(0.005)  -- Fast request
latency:observe(0.123)  -- Normal request
latency:observe(2.456)  -- Slow request
latency:observe(15.0)   -- Timeout request (exceeds default max bucket 10.0)

-- View statistics
print("Total count:", latency.count)  -- 4
print("Sum:", latency.sum)      -- 17.584
print("Average:", latency.sum / latency.count)  -- 4.396
```

### histogram:collect(buf)

Collects metric data into buffer (internal method).

- **Parameters**:
  - `buf`: `table` - Metric data buffer

- **Returns**: None

- **Notes**:
  - This method is automatically called by Registry when calling `gather()`
  - Generally no need to call manually
  - Adds current Histogram object to buffer

- **Example**:

```lua validate
local histogram = require "silly.metrics.histogram"

local h = histogram("test_metric", "Test metric")
h:observe(1.0)

-- Internal collection method
local buf = {}
h:collect(buf)

print("Collected metrics:", #buf)  -- 1
print("Metric name:", buf[1].name)   -- "test_metric"
print("Metric type:", buf[1].kind)   -- "histogram"
```

## HistogramVec Object Methods

### histogramvec:labels(...)

Gets or creates a Histogram instance with specified label values.

- **Parameters**:
  - `...`: `string|number` - Label values, must match count and order of `labelnames` parameter at creation

- **Returns**:
  - `histogram` - Histogram instance

- **Notes**:
  - First call creates a new Histogram instance
  - Subsequent calls with same label values return the same instance
  - Label value order must match `labelnames` order
  - Label values are cached to avoid duplicate creation

- **Example**:

```lua validate
local histogram = require "silly.metrics.histogram"

-- Create HistogramVec with labels
local request_duration = histogram(
    "http_request_duration_seconds",
    "HTTP request duration by method and endpoint",
    {"method", "endpoint"}
)

-- Get instances for different label combinations
local get_users = request_duration:labels("GET", "/api/users")
local post_orders = request_duration:labels("POST", "/api/orders")
local get_products = request_duration:labels("GET", "/api/products")

-- Record observations
get_users:observe(0.023)
get_users:observe(0.045)

post_orders:observe(0.156)
post_orders:observe(0.234)

get_products:observe(0.012)

-- Get same label combination again, returns same instance
local get_users_again = request_duration:labels("GET", "/api/users")
get_users_again:observe(0.034)  -- Accumulates to previous statistics

print("GET /api/users count:", get_users.count)  -- 3
```

### histogramvec:collect(buf)

Collects metric data for all label combinations into buffer (internal method).

- **Parameters**:
  - `buf`: `table` - Metric data buffer

- **Returns**: None

- **Notes**:
  - This method is automatically called by Registry when calling `gather()`
  - Collects all created label combinations
  - Generally no need to call manually

## Usage Examples

### Example 1: HTTP Request Latency Monitoring

```lua validate
local histogram = require "silly.metrics.histogram"

-- Create HTTP request latency histogram
local http_request_duration = histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    {"method", "path"},
    {0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0}
)

-- Simulate request handling
local function handle_request(method, path, duration)
    http_request_duration:labels(method, path):observe(duration)
end

-- Record various requests
handle_request("GET", "/api/users", 0.023)
handle_request("GET", "/api/users", 0.018)
handle_request("GET", "/api/users", 0.156)
handle_request("POST", "/api/orders", 0.234)
handle_request("POST", "/api/orders", 0.089)
handle_request("GET", "/api/products", 0.012)

-- View statistics
local get_users = http_request_duration:labels("GET", "/api/users")
print("GET /api/users - count:", get_users.count)
print("GET /api/users - avg latency:", get_users.sum / get_users.count, "seconds")
```

### Example 2: Database Query Performance Monitoring

```lua validate
local histogram = require "silly.metrics.histogram"

-- Database query duration histogram (millisecond level)
local db_query_duration = histogram(
    "db_query_duration_seconds",
    "Database query duration",
    {"operation", "table"},
    {0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0}
)

-- Simulate database operations
local function execute_query(operation, table_name, duration_ms)
    local duration_sec = duration_ms / 1000
    db_query_duration:labels(operation, table_name):observe(duration_sec)
end

-- Record queries
execute_query("SELECT", "users", 2.3)    -- 2.3ms
execute_query("SELECT", "users", 1.8)
execute_query("SELECT", "users", 15.6)
execute_query("INSERT", "orders", 23.4)
execute_query("INSERT", "orders", 18.9)
execute_query("UPDATE", "products", 45.2)
execute_query("DELETE", "cache", 1.2)

-- Statistics for SELECT users performance
local select_users = db_query_duration:labels("SELECT", "users")
print("SELECT users - total times:", select_users.count)
print("SELECT users - total time:", select_users.sum * 1000, "ms")
print("SELECT users - avg time:", (select_users.sum / select_users.count) * 1000, "ms")
```

### Example 3: Message Processing Time Distribution

```lua validate
local histogram = require "silly.metrics.histogram"

-- Message processing time histogram
local message_processing_time = histogram(
    "message_processing_seconds",
    "Message processing time by type",
    {"message_type"},
    {0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0, 30.0, 60.0}
)

-- Simulate message processing
local function process_message(msg_type, processing_time)
    message_processing_time:labels(msg_type):observe(processing_time)
end

-- Record processing time for various message types
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

-- View statistics for each message type
local email_stats = message_processing_time:labels("email")
local sms_stats = message_processing_time:labels("sms")
local push_stats = message_processing_time:labels("push")

print("Email - avg time:", email_stats.sum / email_stats.count, "seconds")
print("SMS - avg time:", sms_stats.sum / sms_stats.count, "seconds")
print("Push - avg time:", push_stats.sum / push_stats.count, "seconds")
```

### Example 4: API Response Size Statistics

```lua validate
local histogram = require "silly.metrics.histogram"

-- API response size histogram (bytes)
local api_response_size = histogram(
    "api_response_size_bytes",
    "API response size distribution",
    {"endpoint"},
    {100, 500, 1000, 5000, 10000, 50000, 100000, 500000, 1000000}
)

-- Simulate API responses
local function send_response(endpoint, size_bytes)
    api_response_size:labels(endpoint):observe(size_bytes)
end

-- Record response sizes for various endpoints
send_response("/api/users", 1234)
send_response("/api/users", 2345)
send_response("/api/users", 987)

send_response("/api/products", 45678)
send_response("/api/products", 56789)
send_response("/api/products", 34567)

send_response("/api/orders", 123456)
send_response("/api/orders", 234567)

send_response("/api/stats", 5432100)  -- Large data export

-- Statistical analysis
local users_stats = api_response_size:labels("/api/users")
local products_stats = api_response_size:labels("/api/products")

print("/api/users - avg size:", users_stats.sum / users_stats.count, "bytes")
print("/api/products - avg size:", products_stats.sum / products_stats.count, "bytes")
```

### Example 5: Batch Job Size Distribution

```lua validate
local histogram = require "silly.metrics.histogram"

-- Batch job size histogram
local batch_size = histogram(
    "batch_processing_size",
    "Number of items processed per batch",
    {"job_type"},
    {10, 50, 100, 500, 1000, 5000, 10000}
)

-- Batch job execution time
local batch_duration = histogram(
    "batch_processing_duration_seconds",
    "Batch processing duration",
    {"job_type"},
    {1, 5, 10, 30, 60, 300, 600}
)

-- Simulate batch processing
local function process_batch(job_type, item_count, duration)
    batch_size:labels(job_type):observe(item_count)
    batch_duration:labels(job_type):observe(duration)
end

-- Record batch jobs
process_batch("email_dispatch", 523, 12.3)
process_batch("email_dispatch", 1234, 23.4)
process_batch("email_dispatch", 876, 15.6)

process_batch("data_sync", 5432, 123.4)
process_batch("data_sync", 7890, 234.5)

process_batch("report_generation", 150, 45.6)
process_batch("report_generation", 200, 56.7)

-- Analyze batch processing efficiency
local email_size = batch_size:labels("email_dispatch")
local email_time = batch_duration:labels("email_dispatch")

local avg_size = email_size.sum / email_size.count
local avg_time = email_time.sum / email_time.count

print("Email batch - avg batch size:", avg_size, "emails")
print("Email batch - avg processing time:", avg_time, "seconds")
print("Email batch - throughput:", avg_size / avg_time, "emails/second")
```

### Example 6: Cache Operation Latency Monitoring

```lua validate
local histogram = require "silly.metrics.histogram"

-- Cache operation latency (microsecond level)
local cache_operation_duration = histogram(
    "cache_operation_duration_seconds",
    "Cache operation latency",
    {"operation", "cache_type"},
    {0.00001, 0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05}
)

-- Simulate cache operations
local function cache_op(operation, cache_type, latency_us)
    local latency_sec = latency_us / 1000000
    cache_operation_duration:labels(operation, cache_type):observe(latency_sec)
end

-- Record Redis operations
cache_op("GET", "redis", 50)    -- 50 microseconds
cache_op("GET", "redis", 45)
cache_op("GET", "redis", 120)
cache_op("SET", "redis", 80)
cache_op("SET", "redis", 95)
cache_op("DEL", "redis", 60)

-- Record memory cache operations
cache_op("GET", "memory", 5)    -- 5 microseconds
cache_op("GET", "memory", 3)
cache_op("GET", "memory", 8)
cache_op("SET", "memory", 10)
cache_op("SET", "memory", 12)

-- Compare performance of different caches
local redis_get = cache_operation_duration:labels("GET", "redis")
local memory_get = cache_operation_duration:labels("GET", "memory")

print("Redis GET - avg latency:", (redis_get.sum / redis_get.count) * 1000000, "microseconds")
print("Memory GET - avg latency:", (memory_get.sum / memory_get.count) * 1000000, "microseconds")
```

### Example 7: File Upload Size Distribution

```lua validate
local histogram = require "silly.metrics.histogram"

-- File upload size distribution (MB)
local upload_size = histogram(
    "file_upload_size_megabytes",
    "File upload size distribution",
    {"file_type"},
    {0.1, 0.5, 1, 5, 10, 50, 100, 500}
)

-- Upload processing time
local upload_duration = histogram(
    "file_upload_duration_seconds",
    "File upload duration",
    {"file_type"}
)

-- Simulate file uploads
local function upload_file(file_type, size_bytes, duration)
    local size_mb = size_bytes / (1024 * 1024)
    upload_size:labels(file_type):observe(size_mb)
    upload_duration:labels(file_type):observe(duration)
end

-- Record uploads
upload_file("image", 2 * 1024 * 1024, 1.23)       -- 2MB
upload_file("image", 5 * 1024 * 1024, 2.45)       -- 5MB
upload_file("image", 1.5 * 1024 * 1024, 0.89)     -- 1.5MB

upload_file("video", 50 * 1024 * 1024, 23.4)      -- 50MB
upload_file("video", 120 * 1024 * 1024, 56.7)     -- 120MB

upload_file("document", 0.5 * 1024 * 1024, 0.34)  -- 0.5MB
upload_file("document", 2 * 1024 * 1024, 1.12)    -- 2MB

-- Analyze upload speed
local video_size = upload_size:labels("video")
local video_time = upload_duration:labels("video")

local avg_video_size = video_size.sum / video_size.count
local avg_video_time = video_time.sum / video_time.count

print("Video upload - avg size:", avg_video_size, "MB")
print("Video upload - avg time:", avg_video_time, "seconds")
print("Video upload - avg speed:", avg_video_size / avg_video_time, "MB/s")
```

### Example 8: Complete Monitoring System Integration

```lua validate
local silly = require "silly"
local http = require "silly.net.http"
local histogram = require "silly.metrics.histogram"
local prometheus = require "silly.metrics.prometheus"
local task = require "silly.task"

-- Create and auto-register via prometheus
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
    -- Start business server
    local server = http.listen {
        addr = "0.0.0.0:8080",
        handler = function(stream)
            local start_time = silly.time.now()
            local method = stream.method
            local path = stream.path

            -- Simulate business processing
            silly.time.sleep(math.random(10, 200))

            local response_body = '{"status":"ok","data":[]}'
            local status = 200

            stream:respond(status, {
                ["content-type"] = "application/json",
                ["content-length"] = #response_body
            })
            stream:close(response_body)

            -- Record metrics
            local duration = (silly.time.now() - start_time) / 1000
            request_duration:labels(method, path, tostring(status)):observe(duration)
            response_size:labels(method, path):observe(#response_body)
        end
    }

    -- Start metrics export server
    local metrics_server = http.listen {
        addr = "0.0.0.0:9090",
        handler = function(stream)
            if stream.path == "/metrics" then
                local metrics = prometheus.gather()
                stream:respond(200, {
                    ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
                    ["content-length"] = #metrics
                })
                stream:close(metrics)
            else
                stream:respond(404, {["content-type"] = "text/plain"})
                stream:close("Not Found")
            end
        end
    }

    print("Business server: http://localhost:8080")
    print("Metrics: http://localhost:9090/metrics")
end)
```

## Important Notes

### Bucket Boundary Selection

Choosing appropriate bucket boundaries is crucial for accurate quantile calculation:

1. **Cover expected range**:
   - Bucket boundaries should cover most (95%+) of observations
   - Minimum bucket should be less than P50, maximum bucket should be greater than P99

2. **Dense around critical quantiles**:
   - If precise P95 is needed, set denser buckets around 90%-98% percentiles
   - Example: `{0.01, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.5, 1.0}` is denser in low-latency region

3. **Moderate bucket count**:
   - Usually 10-20 buckets are sufficient
   - Too many buckets increase memory and computation overhead
   - Too few buckets reduce quantile precision

4. **Use logarithmic scale**:
   - For data with large spans (like latency, size), use logarithmic scale
   - Example: `{0.001, 0.01, 0.1, 1, 10, 100}` or `{1, 2, 5, 10, 20, 50, 100}`

**Recommended bucket boundaries for different scenarios**:

```lua validate
local histogram = require "silly.metrics.histogram"

-- 1. Fast API latency (millisecond level)
local fast_api = histogram("fast_api_latency", "Fast API latency",
    nil, {0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5})

-- 2. Regular web request latency (100ms - 10s)
local web_latency = histogram("web_latency", "Web request latency",
    nil, {0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 10.0})

-- 3. Database query latency (microseconds to seconds)
local db_latency = histogram("db_latency", "Database query latency",
    nil, {0.0001, 0.001, 0.01, 0.1, 1.0})

-- 4. File size (bytes)
local file_size = histogram("file_size", "File size bytes",
    nil, {1024, 10240, 102400, 1048576, 10485760, 104857600})

-- 5. Batch processing size (count)
local batch_size = histogram("batch_size", "Batch processing size",
    nil, {10, 50, 100, 500, 1000, 5000})

print("Created 5 histograms for different scenarios")
```

### Memory Usage

Histogram memory usage is related to:

1. **Bucket count**: Each bucket stores a counter
2. **Label combination count**: Each label combination creates an independent bucket array
3. **Observation count**: Does not affect memory (only updates counters)

**Memory estimation**:
```
Single Histogram memory ≈ bucket count × 8 bytes + fixed overhead (~200 bytes)
HistogramVec total memory ≈ single Histogram memory × label combination count
```

**Avoid memory explosion**:

```lua validate
local histogram = require "silly.metrics.histogram"

-- Bad example: high cardinality labels cause memory explosion
local bad_histogram = histogram("bad_requests", "Requests",
    {"user_id", "session_id"},  -- label combinations = user count × session count (potentially millions)
    {0.1, 0.5, 1.0, 5.0})

-- Good example: low cardinality labels
local good_histogram = histogram("good_requests", "Requests",
    {"method", "status"},  -- label combinations = method count × status count (dozens)
    {0.1, 0.5, 1.0, 5.0})

-- If 10 HTTP methods, 10 status codes, 10 buckets:
-- Memory usage ≈ (10 × 8 + 200) × 10 × 10 ≈ 28KB

print("Recommend using low cardinality labels")
```

### Performance Considerations

1. **Time complexity of observe() operation**:
   - O(bucket count), traverses all buckets to implement Prometheus Histogram's cumulative nature
   - Each observation needs to update all bucket counters with values greater than or equal to the observed value

2. **Hot path optimization**:
   ```lua validate
   local histogram = require "silly.metrics.histogram"

   local h = histogram("api_latency", "API latency", {"endpoint"})

   -- Bad: lookup label every time
   for i = 1, 10000 do
       h:labels("/api/users"):observe(0.1)  -- Cache lookup each time
   end

   -- Good: cache label instance
   local users_h = h:labels("/api/users")
   for i = 1, 10000 do
       users_h:observe(0.1)  -- Direct operation, no lookup overhead
   end

   print("Recommend caching common label combinations")
   ```

3. **Bucket count recommendations**:
   - Bucket count < 20: negligible performance impact
   - Bucket count 20-50: acceptable
   - Bucket count > 50: evaluate performance impact

### Integration with Prometheus

**Export format**:

Histogram exports to Prometheus text format in three parts:

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

**Common PromQL queries**:

```promql
# These PromQL queries are executed in Prometheus server

# 1. Calculate P95 latency
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))

# 2. Calculate P99 latency
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))

# 3. Calculate average latency
rate(http_request_duration_seconds_sum[5m]) / rate(http_request_duration_seconds_count[5m])

# 4. Calculate QPS
rate(http_request_duration_seconds_count[5m])

# 5. P95 latency grouped by endpoint
histogram_quantile(0.95, sum by (endpoint, le) (rate(http_request_duration_seconds_bucket[5m])))
```

Example code:

```lua validate
local histogram = require "silly.metrics.histogram"
local h = histogram("example_metric", "Example metric")
h:observe(1.0)
print("Histogram metrics can calculate quantiles via Prometheus histogram_quantile() function")
```

### Thread Safety

- Silly framework uses single-threaded event loop (Worker thread)
- All Histogram operations execute in Worker thread
- No need to worry about concurrency issues
- In multi-process architecture, each process needs to collect metrics independently

### Precision and Error

Histogram-calculated quantiles are **estimates**, with precision depending on bucket division:

1. **Precise scenario**: Observed value exactly equals a bucket boundary
   - Example: P95 = 1.0, and there's a bucket boundary `le="1.0"`

2. **Estimation scenario**: Observed value distributed between two buckets
   - Example: P95 is between 0.5 and 1.0, Prometheus will linearly interpolate

3. **Improve precision**:
   - Set denser buckets around critical quantiles
   - Use more buckets (but increases overhead)

```lua validate
local histogram = require "silly.metrics.histogram"

-- Coarse buckets: lower P95 precision
local coarse = histogram("coarse_metric", "Coarse buckets",
    nil, {0.1, 1.0, 10.0})

-- Fine buckets: higher P95 precision
local fine = histogram("fine_metric", "Fine buckets",
    nil, {0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 2.0, 5.0, 10.0})

-- Adaptive buckets: denser in critical region (0.5-2.0)
local adaptive = histogram("adaptive_metric", "Adaptive buckets",
    nil, {0.1, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.2, 1.5, 2.0, 5.0, 10.0})

print("Recommend using denser buckets around critical quantiles")
```

## See Also

- [silly.metrics.prometheus](./prometheus.md) - Prometheus metrics export module
- [silly.metrics.counter](./counter.md) - Counter metric type
- [silly.metrics.gauge](./gauge.md) - Gauge metric type
- [silly.net.http](../net/http.md) - HTTP server and client
- [Prometheus Histogram documentation](https://prometheus.io/docs/concepts/metric_types/#histogram)
- [Histogram vs Summary](https://prometheus.io/docs/practices/histograms/)
