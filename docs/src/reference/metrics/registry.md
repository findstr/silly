---
title: silly.metrics.registry
description: Prometheus 指标注册表 API
category: reference
---

# silly.metrics.registry

::: info 模块描述
`silly.metrics.registry` 提供指标注册表（Registry）功能，用于统一管理和收集所有 Prometheus 指标收集器（Collector）。注册表是 Prometheus 监控系统的核心组件，负责维护指标集合并提供统一的收集接口。
:::

## 简介

Registry（注册表）是 Prometheus 监控架构中的核心容器，负责管理所有 Collector 实例。它的主要作用包括：

- **集中管理**：统一维护所有 Counter、Gauge、Histogram 等指标收集器
- **去重保护**：防止重复注册同一个 Collector 实例
- **统一收集**：提供单一接口收集所有已注册指标的当前值
- **隔离控制**：支持创建多个独立 Registry 实现指标隔离

Registry 的典型应用场景：

1. **全局监控**：使用默认 Registry 收集整个应用的指标
2. **模块隔离**：为不同子系统创建独立 Registry，避免指标冲突
3. **自定义导出**：创建专用 Registry 导出特定指标集合
4. **测试验证**：在单元测试中创建临时 Registry 验证指标行为

## 核心概念

### Registry 与 Collector

Registry 和 Collector 的关系：

```
Registry (注册表)
  └─ Collector 1 (Counter)
  └─ Collector 2 (Gauge)
  └─ Collector 3 (Histogram)
  └─ Collector 4 (自定义 Collector)
```

- **Registry**：容器，负责管理和收集指标
- **Collector**：指标收集器，实现 `collect(buf)` 方法输出指标

### Collector 接口

所有注册到 Registry 的对象必须实现 Collector 接口：

```lua
-- Collector 接口定义
interface Collector {
    name: string                    -- 收集器名称
    collect(self, buf: metric[])    -- 收集指标到 buf 数组
}
```

内置的 Counter、Gauge、Histogram 都实现了此接口。

### 去重机制

Registry 使用引用相等性检查防止重复注册：

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c = counter("test", "Test counter")

reg:register(c)
reg:register(c)  -- 第二次注册会被忽略（同一对象）
```

注意：只有完全相同的对象引用才会被去重，名称相同但对象不同的 Collector 不会被拦截。

### 收集流程

调用 `registry:collect()` 时的执行流程：

1. 创建空的 metrics 数组
2. 遍历所有已注册的 Collector
3. 调用每个 Collector 的 `collect(metrics)` 方法
4. Collector 将自己的指标追加到 metrics 数组
5. 返回包含所有指标的 metrics 数组

### 默认 Registry

`silly.metrics.prometheus` 模块内部维护一个默认 Registry：

```lua
-- prometheus.lua 内部
local R = registry.new()  -- 默认全局 Registry

function M.counter(name, help, labels)
    local ct = counter(name, help, labels)
    R:register(ct)  -- 自动注册到默认 Registry
    return ct
end
```

通过 `prometheus.counter()` 等方法创建的指标会自动注册到默认 Registry。

## API 参考

### registry.new()

创建一个新的指标注册表实例。

```lua
local registry = require "silly.metrics.registry"
local reg = registry.new()
```

**参数：** 无

**返回值：**

- `silly.metrics.registry`：新的注册表对象

**注意：**

- 每次调用都会创建全新的独立 Registry 实例
- 新 Registry 初始为空，不包含任何 Collector
- 多个 Registry 之间完全隔离，互不影响

**示例：**

```lua validate
local registry = require "silly.metrics.registry"

-- 创建全局 Registry
local global_reg = registry.new()

-- 创建模块专用 Registry
local auth_reg = registry.new()
local api_reg = registry.new()

-- 三个 Registry 相互独立
```

---

### registry:register()

将一个 Collector 注册到 Registry 中。

```lua
registry:register(obj)
```

**参数：**

- `obj` (silly.metrics.collector)：要注册的 Collector 对象，必须实现 `collect(buf)` 方法

**返回值：** 无

**行为：**

- 如果该对象已存在于 Registry 中（引用相等），则忽略此次注册
- 如果是新对象，追加到 Registry 的 Collector 列表末尾
- 不检查名称冲突，允许注册多个同名但不同实例的 Collector

**示例：**

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()

-- 创建并注册 Counter
local requests = counter("requests_total", "Total requests")
reg:register(requests)

-- 创建并注册 Gauge
local gauge = require "silly.metrics.gauge"
local temperature = gauge("cpu_temperature", "CPU temperature")
reg:register(temperature)

-- 重复注册同一对象会被忽略
reg:register(requests)  -- 无效操作
```

---

### registry:unregister()

从 Registry 中移除一个已注册的 Collector。

```lua
registry:unregister(obj)
```

**参数：**

- `obj` (silly.metrics.collector)：要移除的 Collector 对象

**返回值：** 无

**行为：**

- 如果找到该对象（引用相等），从 Registry 中移除
- 如果对象不存在，静默忽略
- 使用 `table.remove()` 实现，保持数组连续性

**注意：**

- 移除后该 Collector 不再出现在 `collect()` 结果中
- 但 Collector 对象本身仍然有效，可以继续使用或注册到其他 Registry

**示例：**

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c = counter("test", "Test counter")

-- 注册
reg:register(c)

-- 移除注册
reg:unregister(c)

-- 再次移除（无效但不报错）
reg:unregister(c)
```

---

### registry:collect()

收集所有已注册 Collector 的指标数据。

```lua
local metrics = registry:collect()
```

**参数：** 无

**返回值：**

- `silly.metrics.metric[]`：包含所有指标对象的数组

**行为：**

1. 创建空的 metrics 数组
2. 按注册顺序遍历所有 Collector
3. 调用每个 Collector 的 `collect(metrics)` 方法
4. Collector 将自己的指标追加到 metrics 数组
5. 返回 metrics 数组

**注意：**

- 返回的 metric 对象包含 `name`、`help`、`kind`、`value` 等字段
- 对于 Vector 类型（带标签），会包含 `metrics` 和 `labelnames` 字段
- 指标顺序取决于 Collector 的注册顺序
- 这是只读操作，不会修改 Collector 的状态

**示例：**

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"
local gauge = require "silly.metrics.gauge"

local reg = registry.new()

-- 注册多个指标
local requests = counter("requests_total", "Total requests")
requests:inc()
requests:inc()

local temperature = gauge("temperature", "Current temperature")
temperature:set(75.5)

reg:register(requests)
reg:register(temperature)

-- 收集所有指标
local metrics = reg:collect()

-- metrics 包含：
-- [1] = {name="requests_total", kind="counter", value=2, help="..."}
-- [2] = {name="temperature", kind="gauge", value=75.5, help="..."}

print("收集到 " .. #metrics .. " 个指标")
```

---

## 使用示例

### 示例 1：创建自定义 Registry

为特定模块创建独立的 Registry。

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"
local gauge = require "silly.metrics.gauge"

-- 创建数据库模块的专用 Registry
local db_registry = registry.new()

-- 创建数据库相关指标
local db_queries = counter("db_queries_total", "Total database queries")
local db_connections = gauge("db_connections_active", "Active database connections")
local db_latency = require "silly.metrics.histogram"(
    "db_latency_seconds",
    "Database query latency",
    nil,
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0}
)

-- 注册到专用 Registry
db_registry:register(db_queries)
db_registry:register(db_connections)
db_registry:register(db_latency)

-- 模拟数据库操作
db_queries:inc()
db_connections:set(25)
db_latency:observe(0.023)

-- 收集数据库模块的指标
local metrics = db_registry:collect()
print("数据库模块指标数量：" .. #metrics)
```

---

### 示例 2：多 Registry 隔离管理

为不同子系统创建独立 Registry，实现指标隔离。

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

-- 为不同服务创建独立 Registry
local auth_registry = registry.new()
local api_registry = registry.new()
local cache_registry = registry.new()

-- 认证服务指标
local auth_attempts = counter("auth_attempts_total", "Total authentication attempts")
auth_registry:register(auth_attempts)

-- API 服务指标
local api_requests = counter("api_requests_total", "Total API requests")
api_registry:register(api_requests)

-- 缓存服务指标
local cache_hits = counter("cache_hits_total", "Total cache hits")
cache_registry:register(cache_hits)

-- 各服务独立运行
auth_attempts:inc()
api_requests:add(10)
cache_hits:add(100)

-- 独立收集各服务指标
local auth_metrics = auth_registry:collect()
local api_metrics = api_registry:collect()
local cache_metrics = cache_registry:collect()

print("认证服务指标：" .. #auth_metrics)  -- 1
print("API 服务指标：" .. #api_metrics)    -- 1
print("缓存服务指标：" .. #cache_metrics)  -- 1
```

---

### 示例 3：动态注册和移除

运行时动态管理 Collector 的注册状态。

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()

-- 创建多个 Collector
local c1 = counter("metric1", "Metric 1")
local c2 = counter("metric2", "Metric 2")
local c3 = counter("metric3", "Metric 3")

-- 初始注册
reg:register(c1)
reg:register(c2)

c1:inc()
c2:inc()

-- 收集指标（2 个）
local metrics1 = reg:collect()
print("注册 2 个 Collector：" .. #metrics1)  -- 2

-- 添加新 Collector
reg:register(c3)
c3:inc()

-- 收集指标（3 个）
local metrics2 = reg:collect()
print("注册 3 个 Collector：" .. #metrics2)  -- 3

-- 移除一个 Collector
reg:unregister(c2)

-- 收集指标（2 个）
local metrics3 = reg:collect()
print("移除后剩余 2 个 Collector：" .. #metrics3)  -- 2
```

---

### 示例 4：自定义 Collector

实现自定义 Collector 并注册到 Registry。

```lua validate
local registry = require "silly.metrics.registry"

-- 创建自定义 Collector
local function create_system_collector()
    local collector = {
        name = "system_collector"
    }

    function collector:collect(buf)
        -- 收集系统信息（模拟）
        buf[#buf + 1] = {
            name = "system_uptime_seconds",
            help = "System uptime in seconds",
            kind = "gauge",
            value = 3600  -- 1 小时
        }

        buf[#buf + 1] = {
            name = "system_memory_used_bytes",
            help = "Memory used in bytes",
            kind = "gauge",
            value = 1024 * 1024 * 512  -- 512 MB
        }
    end

    return collector
end

-- 注册自定义 Collector
local reg = registry.new()
local sys_collector = create_system_collector()
reg:register(sys_collector)

-- 收集指标
local metrics = reg:collect()
print("自定义 Collector 输出 " .. #metrics .. " 个指标")  -- 2

for i, m in ipairs(metrics) do
    print(string.format("%s = %s", m.name, m.value))
end
```

---

### 示例 5：Registry 合并

将多个 Registry 的指标合并收集。

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

-- 创建多个子 Registry
local reg1 = registry.new()
local reg2 = registry.new()

local c1 = counter("module1_requests", "Module 1 requests")
local c2 = counter("module2_requests", "Module 2 requests")

c1:inc()
c2:add(5)

reg1:register(c1)
reg2:register(c2)

-- 创建聚合 Registry
local aggregated_reg = registry.new()

-- 创建聚合 Collector
local aggregator = {
    name = "aggregator",
    registries = {reg1, reg2}
}

function aggregator:collect(buf)
    for _, reg in ipairs(self.registries) do
        local metrics = reg:collect()
        for _, m in ipairs(metrics) do
            buf[#buf + 1] = m
        end
    end
end

aggregated_reg:register(aggregator)

-- 一次性收集所有子 Registry 的指标
local all_metrics = aggregated_reg:collect()
print("合并收集到 " .. #all_metrics .. " 个指标")  -- 2
```

---

### 示例 6：防止重复注册

验证 Registry 的去重保护机制。

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c = counter("test", "Test counter")

-- 多次注册同一对象
reg:register(c)
reg:register(c)
reg:register(c)

-- 收集指标（只有 1 个）
local metrics = reg:collect()
print("重复注册验证：" .. #metrics .. " 个指标")  -- 1

-- 注意：名称相同但对象不同不会被去重
local c2 = counter("test", "Test counter")  -- 新对象
reg:register(c2)

local metrics2 = reg:collect()
print("不同对象注册：" .. #metrics2 .. " 个指标")  -- 2（不推荐）
```

---

### 示例 7：测试环境中的临时 Registry

在单元测试中使用临时 Registry 验证指标行为。

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

-- 测试函数：验证计数器功能
local function test_counter_increments()
    -- 创建临时 Registry（不影响全局）
    local test_reg = registry.new()

    -- 创建测试用 Counter
    local test_counter = counter("test_requests", "Test requests")
    test_reg:register(test_counter)

    -- 执行操作
    test_counter:inc()
    test_counter:inc()
    test_counter:add(3)

    -- 验证结果
    local metrics = test_reg:collect()
    assert(#metrics == 1, "应该只有 1 个指标")
    assert(metrics[1].value == 5, "值应该是 5")

    print("✓ 测试通过：Counter 累加正确")
end

-- 运行测试
test_counter_increments()
```

---

### 示例 8：与 Prometheus 集成导出

结合 Prometheus 格式化输出，通过 HTTP 暴露自定义 Registry 的指标。

```lua validate
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"
local gauge = require "silly.metrics.gauge"

-- 创建自定义 Registry
local custom_reg = registry.new()

-- 注册业务指标
local orders = counter("business_orders_total", "Total orders", {"status"})
local revenue = gauge("business_revenue_dollars", "Current revenue in dollars")

orders:labels("completed"):add(100)
orders:labels("pending"):add(20)
orders:labels("cancelled"):add(5)
revenue:set(45678.90)

custom_reg:register(orders)
custom_reg:register(revenue)

-- 简化的 Prometheus 格式化函数
local function format_metrics(metrics)
    local lines = {}

    for _, m in ipairs(metrics) do
        lines[#lines + 1] = "# HELP " .. m.name .. " " .. m.help
        lines[#lines + 1] = "# TYPE " .. m.name .. " " .. m.kind

        if m.metrics then
            -- 带标签的指标
            for label_str, metric_obj in pairs(m.metrics) do
                lines[#lines + 1] = string.format(
                    "%s{%s} %s",
                    m.name,
                    label_str,
                    metric_obj.value
                )
            end
        else
            -- 简单指标
            lines[#lines + 1] = string.format("%s %s", m.name, m.value)
        end
    end

    return table.concat(lines, "\n")
end

-- 收集并格式化指标
local metrics = custom_reg:collect()
local output = format_metrics(metrics)
print(output)

-- 输出示例：
-- # HELP business_orders_total Total orders
-- # TYPE business_orders_total counter
-- business_orders_total{status="completed"} 100
-- business_orders_total{status="pending"} 20
-- business_orders_total{status="cancelled"} 5
-- # HELP business_revenue_dollars Current revenue in dollars
-- # TYPE business_revenue_dollars gauge
-- business_revenue_dollars 45678.90
```

---

## 注意事项

### 1. Registry 不检查名称冲突

Registry 只检查对象引用的重复，不验证 Collector 的名称是否冲突：

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()

-- 创建两个同名但不同实例的 Counter
local c1 = counter("test", "Test 1")
local c2 = counter("test", "Test 2")

reg:register(c1)
reg:register(c2)  -- 不会被拦截（不同对象）

-- 收集时会出现两个同名指标（不推荐）
local metrics = reg:collect()  -- 包含 2 个 name="test" 的指标
```

**建议**：应用层面自行保证 Collector 名称的唯一性。

---

### 2. 去重基于对象引用

Registry 使用 `==` 运算符判断对象是否相同，只有引用完全相等才会被去重：

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c1 = counter("test", "Test")

reg:register(c1)
reg:register(c1)  -- ✅ 去重成功（同一引用）

-- 即使参数完全相同，新创建的对象也是不同的引用
local c2 = counter("test", "Test")
reg:register(c2)  -- ❌ 不会被去重（不同引用）
```

---

### 3. Collector 必须实现正确的接口

注册到 Registry 的对象必须实现 `collect(self, buf)` 方法：

```lua
local registry = require "silly.metrics.registry"

local reg = registry.new()

-- ❌ 错误：对象没有 collect 方法
local invalid_collector = {
    name = "invalid"
}
reg:register(invalid_collector)

-- 调用 collect() 时会报错：attempt to call a nil value (method 'collect')
-- local metrics = reg:collect()
```

---

### 4. collect() 返回的是引用

`collect()` 返回的 metrics 数组中包含的是 Collector 对象的引用，不是副本：

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c = counter("test", "Test")
reg:register(c)

local metrics1 = reg:collect()
c:inc()  -- 修改 Counter 的值

local metrics2 = reg:collect()
-- metrics1[1] 和 metrics2[1] 指向同一个对象
-- 两者的 value 字段都会反映最新值
```

如果需要快照，应该深拷贝 metrics 数组。

---

### 5. 移除 Collector 不影响对象本身

`unregister()` 只是从 Registry 中移除引用，不会销毁 Collector 对象：

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()
local c = counter("test", "Test")

reg:register(c)
c:inc()

reg:unregister(c)  -- 从 Registry 中移除

-- Counter 对象仍然有效，可以继续使用
c:inc()
print(c.value)  -- 2

-- 可以注册到其他 Registry
local another_reg = registry.new()
another_reg:register(c)
```

---

### 6. 默认 Registry 是全局单例

`silly.metrics.prometheus` 内部维护的默认 Registry 是全局单例，所有通过 `prometheus.counter()` 等方法创建的指标都会注册到同一个 Registry：

```lua
local prometheus = require "silly.metrics.prometheus"

-- 这些都注册到同一个全局 Registry
local c1 = prometheus.counter("metric1", "Metric 1")
local c2 = prometheus.counter("metric2", "Metric 2")

-- 通过 prometheus.gather() 可以收集所有指标
local output = prometheus.gather()
```

如果需要隔离，应使用 `registry.new()` 创建独立 Registry，并手动注册 Collector。

---

### 7. Registry 不是线程安全的

Silly 框架使用单线程 Worker 模型，Registry 的所有操作都在同一线程执行，因此无需考虑线程安全问题。但如果在其他语言的扩展中使用，需注意并发保护。

---

### 8. 收集顺序与注册顺序一致

`collect()` 按照 Collector 的注册顺序收集指标：

```lua
local registry = require "silly.metrics.registry"
local counter = require "silly.metrics.counter"

local reg = registry.new()

local c1 = counter("aaa", "AAA")
local c2 = counter("bbb", "BBB")
local c3 = counter("ccc", "CCC")

reg:register(c2)
reg:register(c1)
reg:register(c3)

local metrics = reg:collect()
-- metrics 顺序：c2, c1, c3（按注册顺序，不是字母顺序）
```

如果需要特定顺序，应在注册时控制，或在收集后手动排序。

---

## 参见

- [silly.metrics.prometheus](./prometheus.md) - Prometheus 指标集成（使用默认 Registry）
- [silly.metrics.counter](./counter.md) - Counter 指标类型
- [silly.metrics.gauge](./gauge.md) - Gauge 指标类型
- [silly.metrics.histogram](./histogram.md) - Histogram 指标类型

---

## 参考资料

- [Prometheus Registry 概念](https://prometheus.io/docs/instrumenting/writing_clientlibs/#overall-structure)
- [Prometheus Collector 接口](https://prometheus.io/docs/instrumenting/writing_clientlibs/#collector)
- [Prometheus 数据模型](https://prometheus.io/docs/concepts/data_model/)
