---
title: silly.metrics.counter
description: Prometheus 风格计数器指标 API
category: reference
---

# silly.metrics.counter

::: info 模块描述
`silly.metrics.counter` 提供 Prometheus 风格的 Counter 指标类型。Counter 是一个只能递增的累积指标，用于表示单调递增的计数器，例如请求总数、错误总数、任务完成数等。Counter 的值只能增加或重置为零（重启时）。
:::

## 简介

Counter（计数器）是 Prometheus 监控系统中最简单的指标类型之一。它适用于以下场景：

- **请求计数**：统计 HTTP 请求、RPC 调用、数据库查询等总次数
- **错误统计**：记录各类错误、异常、超时的累计次数
- **任务统计**：跟踪任务完成数、消息处理数等
- **资源使用**：累计发送/接收的字节数、处理的记录数等

Counter 的关键特性：

1. **单调递增**：值只能增加，不能减少（重启除外）
2. **累积统计**：记录从启动到当前的累计值
3. **速率计算**：可通过 Prometheus 查询计算增长速率（如 QPS）
4. **标签支持**：支持多维度标签，实现细粒度统计

## 核心概念

### Counter 类型

模块提供两种 Counter 类型：

1. **简单 Counter**：不带标签的单一计数器
   - 直接调用 `inc()` 或 `add()` 方法
   - 适用于全局统计场景

2. **Counter Vector**：带标签的计数器向量
   - 需要先调用 `labels()` 选择标签组合
   - 适用于多维度统计场景（如按状态码、用户类型分类）

### 标签机制

标签（Labels）用于实现多维度监控：

```lua
local counter = require "silly.metrics.counter"
local vec = counter("http_requests_total", "Total HTTP requests", {"method", "status"})

-- 不同标签组合代表不同的时间序列
vec:labels("GET", "200"):inc()    -- GET 请求成功
vec:labels("POST", "500"):inc()   -- POST 请求失败
```

每个标签组合会创建独立的计数器实例，Prometheus 会自动聚合和查询。

### 最佳实践

1. **命名规范**：使用 `_total` 后缀表示累计值（如 `requests_total`）
2. **单位说明**：在 help 文本中明确说明单位（次数、字节数等）
3. **避免递减**：永远不要尝试减少 Counter 的值
4. **标签基数**：控制标签的取值范围，避免创建过多时间序列
5. **初始化值**：Counter 会自动初始化为 0，无需手动设置

## API 参考

### counter()

创建一个新的 Counter 指标。

```lua
local counter = require "silly.metrics.counter"
local c = counter(name, help, labelnames)
```

**参数：**

- `name` (string)：指标名称，必须符合 Prometheus 命名规范（`[a-zA-Z_:][a-zA-Z0-9_:]*`）
- `help` (string)：指标描述文本，解释该指标的含义和用途
- `labelnames` (string[]?)：可选的标签名称数组，创建 Counter Vector

**返回值：**

- 不带 `labelnames`：返回 `silly.metrics.counter` 对象（简单 Counter）
- 带 `labelnames`：返回 `silly.metrics.countervec` 对象（Counter Vector）

**示例：**

```lua validate
local counter = require "silly.metrics.counter"

-- 创建简单 Counter
local total = counter("app_requests_total", "Total application requests")

-- 创建带标签的 Counter Vector
local errors = counter("app_errors_total", "Total errors by type", {"error_type"})
```

---

### inc()

将 Counter 的值加 1。

```lua
counter:inc()
```

**参数：** 无

**返回值：** 无

**示例：**

```lua validate
local counter = require "silly.metrics.counter"
local requests = counter("requests_total", "Total requests")

-- 每次请求时增加计数
requests:inc()
requests:inc()
requests:inc()
-- 此时 requests.value == 3
```

---

### add()

将 Counter 的值增加指定数量。

```lua
counter:add(v)
```

**参数：**

- `v` (number)：要增加的值，必须 >= 0（非负数）

**返回值：** 无

**错误：**

- 如果 `v < 0`，会抛出断言错误："Counter can only increase"

**示例：**

```lua validate
local counter = require "silly.metrics.counter"
local bytes_sent = counter("network_bytes_sent_total", "Total bytes sent")

-- 发送数据后累加字节数
bytes_sent:add(1024)   -- 发送 1KB
bytes_sent:add(2048)   -- 发送 2KB
-- 此时 bytes_sent.value == 3072

-- 错误用法（会抛出异常）：
-- bytes_sent:add(-100)  -- 不能传递负数
```

---

### labels()

选择 Counter Vector 中特定标签组合的计数器实例。

```lua
local sub_counter = countervec:labels(...)
```

**参数：**

- `...` (string|number)：标签值，数量必须与创建时的 `labelnames` 一致

**返回值：**

- `silly.metrics.countersub`：对应标签组合的 Counter 实例，可调用 `inc()` 或 `add()`

**注意：**

- 首次调用时会创建新实例（值初始化为 0）
- 后续相同标签组合会返回同一实例
- 标签值顺序必须与 `labelnames` 定义顺序一致

**示例：**

```lua validate
local counter = require "silly.metrics.counter"
local requests = counter("http_requests_total", "Total HTTP requests", {"method", "status"})

-- 按 method 和 status 分类统计
requests:labels("GET", "200"):inc()
requests:labels("GET", "404"):inc()
requests:labels("POST", "200"):inc()
requests:labels("GET", "200"):inc()  -- 复用之前创建的实例

-- 每个标签组合有独立的计数器：
-- http_requests_total{method="GET",status="200"} = 2
-- http_requests_total{method="GET",status="404"} = 1
-- http_requests_total{method="POST",status="200"} = 1
```

---

### collect()

收集 Counter 的当前值，供 Prometheus 格式化输出使用。

```lua
counter:collect(buf)
```

**参数：**

- `buf` (silly.metrics.metric[])：用于收集指标的数组

**返回值：** 无

**注意：**

- 这是内部 API，通常由 `silly.metrics.prometheus.gather()` 自动调用
- 普通用户代码不需要直接调用此方法

---

## 使用示例

### 示例 1：简单请求计数

统计应用的总请求数。

```lua validate
local counter = require "silly.metrics.counter"

-- 创建请求计数器
local requests_total = counter("app_requests_total", "Total application requests")

-- 模拟处理请求
local function handle_request()
    requests_total:inc()
    -- ... 处理业务逻辑 ...
end

-- 处理多个请求
for i = 1, 100 do
    handle_request()
end

-- 当前计数：requests_total.value == 100
```

---

### 示例 2：HTTP 状态码统计

按 HTTP 状态码统计请求数量。

```lua validate
local counter = require "silly.metrics.counter"

local http_requests = counter(
    "http_requests_total",
    "Total HTTP requests by status code",
    {"status"}
)

-- 模拟 HTTP 请求处理
local function handle_http_request(status_code)
    http_requests:labels(tostring(status_code)):inc()
end

-- 处理各种状态码的请求
handle_http_request(200)  -- 成功
handle_http_request(200)
handle_http_request(404)  -- 未找到
handle_http_request(500)  -- 服务器错误
handle_http_request(200)

-- 结果：
-- http_requests_total{status="200"} = 3
-- http_requests_total{status="404"} = 1
-- http_requests_total{status="500"} = 1
```

---

### 示例 3：多维度错误统计

按错误类型和服务模块统计错误次数。

```lua validate
local counter = require "silly.metrics.counter"

local errors_total = counter(
    "service_errors_total",
    "Total errors by type and module",
    {"module", "error_type"}
)

-- 模拟不同模块的错误
local function report_error(module, error_type)
    errors_total:labels(module, error_type):inc()
end

-- 记录各种错误
report_error("database", "timeout")
report_error("database", "connection_failed")
report_error("cache", "timeout")
report_error("database", "timeout")
report_error("api", "invalid_request")

-- 结果：
-- service_errors_total{module="database",error_type="timeout"} = 2
-- service_errors_total{module="database",error_type="connection_failed"} = 1
-- service_errors_total{module="cache",error_type="timeout"} = 1
-- service_errors_total{module="api",error_type="invalid_request"} = 1
```

---

### 示例 4：流量统计（字节数）

统计网络发送和接收的总字节数。

```lua validate
local counter = require "silly.metrics.counter"

local bytes_sent = counter("network_bytes_sent_total", "Total bytes sent over network")
local bytes_received = counter("network_bytes_received_total", "Total bytes received from network")

-- 模拟数据传输
local function send_data(size)
    bytes_sent:add(size)
end

local function receive_data(size)
    bytes_received:add(size)
end

-- 传输数据
send_data(1024)      -- 发送 1KB
receive_data(2048)   -- 接收 2KB
send_data(512)       -- 发送 512B
receive_data(4096)   -- 接收 4KB

-- 统计结果：
-- network_bytes_sent_total = 1536 字节
-- network_bytes_received_total = 6144 字节
```

---

### 示例 5：游戏服务器事件统计

统计游戏服务器中各类玩家事件。

```lua validate
local counter = require "silly.metrics.counter"

local player_events = counter(
    "game_player_events_total",
    "Total player events by type",
    {"event_type"}
)

local battle_results = counter(
    "game_battle_results_total",
    "Total battle results",
    {"result"}
)

-- 模拟玩家事件
local function track_event(event_type)
    player_events:labels(event_type):inc()
end

local function track_battle(result)
    battle_results:labels(result):inc()
end

-- 记录事件
track_event("login")
track_event("logout")
track_event("login")
track_event("purchase")
track_event("login")

track_battle("win")
track_battle("lose")
track_battle("win")
track_battle("draw")

-- 结果：
-- game_player_events_total{event_type="login"} = 3
-- game_player_events_total{event_type="logout"} = 1
-- game_player_events_total{event_type="purchase"} = 1
-- game_battle_results_total{result="win"} = 2
-- game_battle_results_total{result="lose"} = 1
-- game_battle_results_total{result="draw"} = 1
```

---

### 示例 6：任务处理统计

统计异步任务的完成和失败次数。

```lua validate
local counter = require "silly.metrics.counter"

local tasks_completed = counter(
    "tasks_completed_total",
    "Total completed tasks by priority",
    {"priority"}
)

local tasks_failed = counter(
    "tasks_failed_total",
    "Total failed tasks by reason",
    {"reason"}
)

-- 模拟任务处理
local function complete_task(priority)
    tasks_completed:labels(priority):inc()
end

local function fail_task(reason)
    tasks_failed:labels(reason):inc()
end

-- 处理任务
complete_task("high")
complete_task("normal")
complete_task("high")
complete_task("low")
fail_task("timeout")
fail_task("error")
fail_task("timeout")

-- 结果：
-- tasks_completed_total{priority="high"} = 2
-- tasks_completed_total{priority="normal"} = 1
-- tasks_completed_total{priority="low"} = 1
-- tasks_failed_total{reason="timeout"} = 2
-- tasks_failed_total{reason="error"} = 1
```

---

### 示例 7：API 调用追踪

追踪微服务间的 API 调用次数。

```lua validate
local counter = require "silly.metrics.counter"

local api_calls = counter(
    "api_calls_total",
    "Total API calls between services",
    {"source", "target", "method"}
)

-- 模拟服务间调用
local function call_service(source, target, method)
    api_calls:labels(source, target, method):inc()
end

-- 记录服务调用
call_service("gateway", "user-service", "GetUser")
call_service("gateway", "order-service", "CreateOrder")
call_service("order-service", "payment-service", "ProcessPayment")
call_service("gateway", "user-service", "GetUser")
call_service("user-service", "cache-service", "Get")

-- 结果：
-- api_calls_total{source="gateway",target="user-service",method="GetUser"} = 2
-- api_calls_total{source="gateway",target="order-service",method="CreateOrder"} = 1
-- api_calls_total{source="order-service",target="payment-service",method="ProcessPayment"} = 1
-- api_calls_total{source="user-service",target="cache-service",method="Get"} = 1
```

---

### 示例 8：与 Prometheus 集成

完整示例：创建 Counter 并通过 HTTP 暴露指标。

```lua validate
local counter = require "silly.metrics.counter"
local prometheus = require "silly.metrics.prometheus"
local http = require "silly.net.http"

-- 注意：直接 require counter 模块只能创建独立 counter
-- 要在 Prometheus 中注册，应使用 prometheus.counter()

-- 创建通过 prometheus 注册的 counter
local requests_total = prometheus.counter(
    "app_requests_total",
    "Total requests",
    {"path"}
)

local errors_total = prometheus.counter(
    "app_errors_total",
    "Total errors",
    {"type"}
)

-- 模拟请求处理
local function handle_request(path)
    requests_total:labels(path):inc()
end

local function handle_error(error_type)
    errors_total:labels(error_type):inc()
end

-- 记录一些指标
handle_request("/api/users")
handle_request("/api/orders")
handle_request("/api/users")
handle_error("timeout")

-- 启动 Prometheus 指标服务器
local server = http.listen {
    addr = "127.0.0.1:9090",
    handler = function(stream)
        if stream.path == "/metrics" then
            local metrics_data = prometheus.gather()
            stream:respond(200, {
                ["content-type"] = "text/plain; version=0.0.4; charset=utf-8",
                ["content-length"] = #metrics_data,
            })
            stream:closewrite(metrics_data)
        else
            stream:respond(404)
            stream:closewrite("Not Found")
        end
    end
}

-- 访问 http://127.0.0.1:9090/metrics 查看指标
-- 输出格式：
-- # HELP app_requests_total Total requests
-- # TYPE app_requests_total counter
-- app_requests_total{path="/api/users"} 2
-- app_requests_total{path="/api/orders"} 1
-- # HELP app_errors_total Total errors
-- # TYPE app_errors_total counter
-- app_errors_total{type="timeout"} 1
```

---

## 注意事项

### 1. Counter 只能递增

Counter 的设计原则是单调递增，尝试减少值会破坏 Prometheus 的速率计算逻辑。

```lua
-- ❌ 错误：Counter 不能递减
local counter = require "silly.metrics.counter"
local c = counter("test", "test counter")
c:add(-10)  -- 会抛出错误：Counter can only increase
```

如果需要可增可减的指标，请使用 `silly.metrics.gauge`。

---

### 2. 标签基数控制

每个唯一的标签组合都会创建一个独立的时间序列。过多的标签取值会导致：

- 内存占用增加
- Prometheus 查询变慢
- 存储成本上升

```lua
-- ❌ 不好：user_id 有数百万个可能值
local counter = require "silly.metrics.counter"
local logins = counter("user_logins_total", "User logins", {"user_id"})
logins:labels("user_12345"):inc()  -- 每个用户创建一个时间序列

-- ✅ 好：使用有限的分类标签
local logins_by_type = counter("user_logins_total", "User logins", {"user_type"})
logins_by_type:labels("vip"):inc()      -- 只有几种用户类型
logins_by_type:labels("normal"):inc()
```

**建议**：标签的唯一组合数应控制在数千到数万级别。

---

### 3. 标签顺序必须一致

调用 `labels()` 时，参数顺序必须与创建时的 `labelnames` 一致。

```lua
local counter = require "silly.metrics.counter"
local requests = counter("requests_total", "Requests", {"method", "status"})

-- ✅ 正确：顺序与 labelnames 一致
requests:labels("GET", "200"):inc()

-- ❌ 错误：顺序颠倒（会创建不同的时间序列）
requests:labels("200", "GET"):inc()  -- 实际是 {method="200", status="GET"}
```

---

### 4. 命名规范

遵循 Prometheus 官方命名最佳实践：

- 使用小写字母和下划线
- 以应用名或库名为前缀（如 `myapp_`）
- Counter 使用 `_total` 后缀
- 包含单位（如 `_bytes`、`_seconds`）

```lua
local counter = require "silly.metrics.counter"

-- ✅ 好的命名
local good1 = counter("myapp_requests_total", "Total requests")
local good2 = counter("myapp_bytes_sent_total", "Total bytes sent")

-- ❌ 不好的命名
local bad1 = counter("requestCount", "Requests")  -- 使用了驼峰命名
local bad2 = counter("requests", "Requests")      -- 缺少 _total 后缀
```

---

### 5. 使用 prometheus.counter() 注册

如果要在 Prometheus 中暴露指标，应使用 `silly.metrics.prometheus.counter()` 而非直接 `require "silly.metrics.counter"`：

```lua
-- ❌ 不会自动注册到 Prometheus
local counter = require "silly.metrics.counter"
local c1 = counter("test_total", "Test counter")

-- ✅ 自动注册到全局 registry
local prometheus = require "silly.metrics.prometheus"
local c2 = prometheus.counter("test_total", "Test counter")
```

直接使用 `silly.metrics.counter` 创建的指标不会出现在 `prometheus.gather()` 的输出中，除非手动注册到 registry。

---

### 6. 避免在热路径创建新标签

`labels()` 首次调用会创建新实例，虽然有缓存但仍建议预热常用标签组合：

```lua
local counter = require "silly.metrics.counter"
local requests = counter("requests_total", "Requests", {"status"})

-- ✅ 在初始化时预创建常用标签组合
requests:labels("200")
requests:labels("404")
requests:labels("500")

-- 后续调用会直接命中缓存，性能更好
```

---

### 7. 线程安全说明

Silly 框架使用单线程 Worker 模型，所有业务逻辑在同一个线程执行，因此 Counter 操作是线程安全的，无需额外加锁。

---

### 8. 重启后值会重置

Counter 的值存储在内存中，进程重启后会重置为 0。这是正常行为，Prometheus 会自动检测并处理 Counter 重置。

---

## 相关 API

- [silly.metrics.prometheus](./prometheus.md) - Prometheus 指标集成
- [silly.metrics.gauge](./gauge.md) - 可增可减的仪表盘指标
- [silly.metrics.histogram](./histogram.md) - 直方图指标（分布统计）
- [silly.net.http](../net/http.md) - HTTP 服务器（用于暴露 /metrics 端点）

---

## 参考资料

- [Prometheus Counter 官方文档](https://prometheus.io/docs/concepts/metric_types/#counter)
- [Prometheus 命名最佳实践](https://prometheus.io/docs/practices/naming/)
- [Prometheus 数据模型](https://prometheus.io/docs/concepts/data_model/)
