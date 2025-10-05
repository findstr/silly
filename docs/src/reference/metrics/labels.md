---
title: silly.metrics.labels
description: 指标标签管理与序列化 API
category: reference
---

# silly.metrics.labels

::: info 模块描述
`silly.metrics.labels` 是 Silly 框架 metrics 系统的底层标签管理模块。它负责标签的缓存优化和 Prometheus 格式序列化，为 Counter、Gauge、Histogram 等指标类型提供高效的多维度标签支持。
:::

## 简介

`silly.metrics.labels` 是一个内部模块，主要为指标向量（Metric Vector）提供标签管理功能。它的核心职责包括：

- **标签键生成**：将标签名和标签值组合生成唯一的缓存键
- **Prometheus 格式化**：将标签序列化为 Prometheus 格式字符串（如 `method="GET",status="200"`）
- **性能优化**：使用多级缓存避免重复序列化，提升热路径性能

该模块被 `silly.metrics.counter`、`silly.metrics.gauge`、`silly.metrics.histogram` 等指标类型内部使用，普通用户代码通常不需要直接调用此模块，而是通过指标对象的 `labels()` 方法间接使用。

## 核心概念

### 标签（Labels）

在 Prometheus 监控体系中，标签用于实现指标的多维度统计。每个指标可以有多个标签维度，每个标签维度有若干个可能的取值：

```lua
-- 示例：HTTP 请求指标有两个标签维度
http_requests_total{method="GET", status="200"} = 1024
http_requests_total{method="POST", status="500"} = 5
```

每个唯一的标签组合对应一条独立的时间序列（time series）。

### 标签基数（Cardinality）

标签基数指的是标签可能取值的组合数量。例如：

- 标签 `method` 有 4 个取值：GET、POST、PUT、DELETE
- 标签 `status` 有 5 个取值：200、404、500、502、503
- 总基数 = 4 × 5 = 20 条时间序列

**重要**：高基数标签（如 user_id、session_id）会导致时间序列数量爆炸，严重影响性能和存储。

### 标签缓存机制

`silly.metrics.labels` 使用多级缓存结构来优化标签序列化：

```
labelcache (table)
├── value1 (table)
│   ├── value2 (table)
│   │   └── value3 → "label1=\"value1\",label2=\"value2\",label3=\"value3\""
│   └── value2' → "label1=\"value1\",label2=\"value2'\""
└── value1' (table)
    └── value2 → "label1=\"value1'\",label2=\"value2\""
```

这种设计使得相同标签组合只需序列化一次，后续查询直接返回缓存结果。

### Prometheus 标签格式

模块将标签序列化为 Prometheus 文本格式：

```
labelname1="value1",labelname2="value2",labelname3="value3"
```

注意：
- 标签名和值之间用 `=` 连接
- 值用双引号 `"` 包裹
- 多个标签用逗号 `,` 分隔
- 最后一个标签后无逗号

## API 参考

### key()

生成标签组合的唯一缓存键，如果不存在则创建并缓存 Prometheus 格式的标签字符串。

```lua
local key_string = labels.key(lcache, lnames, values)
```

**参数：**

- `lcache` (table)：标签缓存表，通常由指标向量对象管理
- `lnames` (string[])：标签名称数组，定义标签的顺序和名称
- `values` (table)：标签值数组，与 `lnames` 一一对应

**返回值：**

- `string`：Prometheus 格式的标签字符串，如 `method="GET",status="200"`

**断言：**

- 如果 `#lnames ≠ #values`，会触发断言错误

**算法说明：**

1. 按照标签值顺序在 `lcache` 中递归查找或创建嵌套表
2. 使用最后一个标签值作为最终缓存键
3. 如果缓存不存在，调用内部 `compose()` 函数生成标签字符串
4. 将生成的字符串缓存并返回

**示例：**

```lua validate
local labels = require "silly.metrics.labels"

-- 准备标签缓存（通常由指标向量对象管理）
local cache = {}

-- 定义标签名称
local labelnames = {"method", "status"}

-- 生成标签键
local key1 = labels.key(cache, labelnames, {"GET", "200"})
print("Key 1:", key1)  -- method="GET",status="200"

local key2 = labels.key(cache, labelnames, {"POST", "500"})
print("Key 2:", key2)  -- method="POST",status="500"

-- 相同标签组合会返回缓存结果
local key3 = labels.key(cache, labelnames, {"GET", "200"})
print("Key 3:", key3)  -- method="GET",status="200" (从缓存返回)
assert(key1 == key3)   -- 相同引用
```

---

## 使用示例

### 示例 1：基本标签序列化

演示如何使用 `key()` 函数序列化标签。

```lua validate
local labels = require "silly.metrics.labels"

-- 创建缓存表
local cache = {}
local labelnames = {"region", "server"}

-- 序列化不同的标签组合
local k1 = labels.key(cache, labelnames, {"us-east", "web01"})
print("K1:", k1)  -- region="us-east",server="web01"

local k2 = labels.key(cache, labelnames, {"eu-west", "web02"})
print("K2:", k2)  -- region="eu-west",server="web02"

local k3 = labels.key(cache, labelnames, {"ap-south", "web03"})
print("K3:", k3)  -- region="ap-south",server="web03"
```

---

### 示例 2：缓存验证

验证相同标签组合确实返回缓存结果。

```lua validate
local labels = require "silly.metrics.labels"

local cache = {}
local labelnames = {"method", "path"}

-- 首次调用，创建缓存
local key1 = labels.key(cache, labelnames, {"GET", "/api/users"})

-- 第二次相同调用，从缓存返回
local key2 = labels.key(cache, labelnames, {"GET", "/api/users"})

-- 验证是完全相同的字符串对象（地址相同）
print("Key 1:", key1)
print("Key 2:", key2)
print("Same object:", key1 == key2)  -- true

-- 不同的标签值创建新对象
local key3 = labels.key(cache, labelnames, {"POST", "/api/orders"})
print("Key 3:", key3)
print("Different:", key1 ~= key3)  -- true
```

---

### 示例 3：单标签场景

演示单标签维度的序列化。

```lua validate
local labels = require "silly.metrics.labels"

local cache = {}
local labelnames = {"status"}

-- 单标签序列化
local k1 = labels.key(cache, labelnames, {"200"})
print(k1)  -- status="200"

local k2 = labels.key(cache, labelnames, {"404"})
print(k2)  -- status="404"

local k3 = labels.key(cache, labelnames, {"500"})
print(k3)  -- status="500"
```

---

### 示例 4：多标签场景

演示多标签维度的序列化。

```lua validate
local labels = require "silly.metrics.labels"

local cache = {}
local labelnames = {"method", "endpoint", "status", "datacenter"}

-- 4 个标签维度
local key = labels.key(cache, labelnames, {
    "POST",
    "/api/orders",
    "201",
    "us-west-2"
})

print(key)
-- 输出：method="POST",endpoint="/api/orders",status="201",datacenter="us-west-2"
```

---

### 示例 5：数值型标签值

标签值可以是数字，会自动转换为字符串。

```lua validate
local labels = require "silly.metrics.labels"

local cache = {}
local labelnames = {"user_type", "level", "score"}

-- 数值会自动转换为字符串
local key = labels.key(cache, labelnames, {"premium", 10, 9500})
print(key)
-- 输出：user_type="premium",level="10",score="9500"
```

---

### 示例 6：与 Counter 集成

演示 labels 模块如何被 Counter Vector 内部使用。

```lua validate
local counter = require "silly.metrics.counter"

-- 创建 Counter Vector
local requests = counter("http_requests_total", "Total HTTP requests", {"method", "status"})

-- Counter 内部使用 silly.metrics.labels 生成缓存键
requests:labels("GET", "200"):inc()
requests:labels("POST", "201"):inc()
requests:labels("GET", "200"):inc()  -- 复用缓存

-- 查看内部结构（仅用于演示，实际代码不要访问内部字段）
print("Label names:", table.concat(requests.labelnames, ", "))  -- method, status

-- 查看生成的标签组合（metrics 表的键就是 labels.key() 的返回值）
for k, v in pairs(requests.metrics) do
    print("Label key:", k, "Value:", v.value)
end
-- 输出示例：
-- Label key: method="GET",status="200" Value: 2
-- Label key: method="POST",status="201" Value: 1
```

---

### 示例 7：标签基数分析

演示不同标签组合数量对内存的影响。

```lua validate
local labels = require "silly.metrics.labels"

local cache = {}
local labelnames = {"region", "server_type"}

-- 模拟创建多个标签组合
local regions = {"us-east", "us-west", "eu-west", "ap-south"}
local server_types = {"web", "api", "db", "cache"}

local count = 0
for _, region in ipairs(regions) do
    for _, server_type in ipairs(server_types) do
        local key = labels.key(cache, labelnames, {region, server_type})
        count = count + 1
        print(string.format("[%d] %s", count, key))
    end
end

print("\nTotal unique label combinations:", count)
-- 输出：4 regions × 4 server_types = 16 条时间序列
```

---

### 示例 8：高基数问题演示

演示使用高基数标签（如 user_id）的问题。

```lua validate
local labels = require "silly.metrics.labels"

-- 模拟使用 user_id 作为标签（不推荐！）
local cache = {}
local labelnames = {"user_id"}

-- 假设有 10000 个用户，每个用户创建一条时间序列
local user_count = 10000
local memory_estimate = 0

for i = 1, user_count do
    local key = labels.key(cache, labelnames, {tostring(i)})
    -- 每个标签字符串约占用 20-30 字节
    memory_estimate = memory_estimate + #key
end

print(string.format("Created %d time series", user_count))
print(string.format("Estimated label cache memory: ~%d KB", memory_estimate / 1024))
print("\n⚠️  WARNING: High cardinality labels can cause:")
print("  - Excessive memory usage")
print("  - Slow Prometheus queries")
print("  - High storage costs")
print("\n✅ SOLUTION: Use bounded labels like 'user_type' instead of 'user_id'")
```

---

## 注意事项

### 1. 不应直接使用此模块

`silly.metrics.labels` 是底层模块，通常不应在业务代码中直接使用。应该通过指标对象的 `labels()` 方法间接使用：

```lua
-- ❌ 不推荐：直接使用 labels 模块
local labels = require "silly.metrics.labels"
local cache = {}
local key = labels.key(cache, {"method"}, {"GET"})

-- ✅ 推荐：通过指标对象使用
local counter = require "silly.metrics.counter"
local requests = counter("requests_total", "Total requests", {"method"})
requests:labels("GET"):inc()  -- 内部自动调用 labels.key()
```

---

### 2. 标签值顺序必须一致

调用 `key()` 时，`values` 数组的顺序必须与 `lnames` 一致：

```lua
local labels = require "silly.metrics.labels"
local cache = {}
local labelnames = {"method", "status"}

-- ✅ 正确：顺序一致
local k1 = labels.key(cache, labelnames, {"GET", "200"})

-- ❌ 错误：顺序颠倒会生成不同的标签字符串
local k2 = labels.key(cache, labelnames, {"200", "GET"})
-- k2 = method="200",status="GET" （错误！）
```

---

### 3. 标签值会自动转换为字符串

数值类型的标签值会通过 `tostring()` 转换为字符串：

```lua
local labels = require "silly.metrics.labels"
local cache = {}
local labelnames = {"port"}

local key = labels.key(cache, labelnames, {8080})
print(key)  -- port="8080" （数字被转换为字符串）
```

注意：`8080` 和 `"8080"` 会生成相同的标签字符串。

---

### 4. 避免高基数标签

每个唯一的标签组合都会创建独立的缓存项和时间序列。高基数标签（如 user_id、session_id）会导致：

- **内存爆炸**：数百万用户 = 数百万条时间序列
- **性能下降**：Prometheus 查询变慢
- **存储成本**：时间序列数据库存储成本线性增长

**最佳实践**：

```lua
-- ❌ 不好：user_id 有百万级基数
local labelnames = {"user_id"}

-- ✅ 好：user_type 只有几种取值
local labelnames = {"user_type"}  -- vip, normal, guest

-- ❌ 不好：ip_address 有数十万种可能
local labelnames = {"ip_address"}

-- ✅ 好：region 只有几个数据中心
local labelnames = {"region"}  -- us-east, eu-west, ap-south
```

**建议**：单个指标的唯一标签组合数应控制在 **1000 以内**，最多不超过 10000。

---

### 5. 标签名称必须符合规范

虽然 `labels` 模块不会验证标签名称，但 Prometheus 要求标签名称符合以下规范：

- 只能包含字母、数字、下划线
- 不能以数字开头
- 不能以 `__` 双下划线开头（保留给 Prometheus 内部使用）

```lua
-- ✅ 合法的标签名称
local labelnames = {"method", "status_code", "datacenter_1"}

-- ❌ 非法的标签名称
local bad_names = {"method-type", "1st_label", "__internal"}
```

---

### 6. 缓存表由调用方管理

`lcache` 缓存表的生命周期由调用方（指标对象）管理。不同的指标对象有独立的缓存表：

```lua
local counter = require "silly.metrics.counter"

local c1 = counter("metric1", "First metric", {"label1"})
local c2 = counter("metric2", "Second metric", {"label1"})

-- c1 和 c2 有各自独立的 labelcache
-- c1.labelcache 和 c2.labelcache 互不影响
```

---

### 7. 标签字符串不可修改

`key()` 返回的字符串是缓存的引用，不应修改：

```lua
local labels = require "silly.metrics.labels"
local cache = {}
local key = labels.key(cache, {"method"}, {"GET"})

-- ❌ 不要尝试修改标签字符串
-- Lua 字符串是不可变的，但不要依赖返回值做其他用途
```

---

### 8. 线程安全说明

由于 Silly 使用单线程 Worker 模型，`silly.metrics.labels` 的所有操作都在同一个线程执行，因此是线程安全的，无需加锁。

---

### 9. 内存优化

`compose()` 函数使用全局 `buf` 表进行字符串拼接，避免了大量临时字符串的创建：

```lua
-- 内部实现使用 table.concat 优化
local buf = {}  -- 全局复用
buf[1] = 'method="'
buf[2] = 'GET'
buf[3] = '",status="'
buf[4] = '200'
buf[5] = '"'
local str = table.concat(buf)
```

这种设计在高频调用场景下显著减少 GC 压力。

---

## 相关 API

- [silly.metrics.counter](./counter.md) - Counter 指标类型（内部使用 labels 模块）
- [silly.metrics.gauge](./gauge.md) - Gauge 指标类型（内部使用 labels 模块）
- [silly.metrics.histogram](./histogram.md) - Histogram 指标类型（内部使用 labels 模块）
- [silly.metrics.prometheus](./prometheus.md) - Prometheus 指标集成

---

## 参考资料

- [Prometheus 数据模型](https://prometheus.io/docs/concepts/data_model/)
- [Prometheus 标签最佳实践](https://prometheus.io/docs/practices/naming/)
- [标签基数与性能优化](https://www.robustperception.io/cardinality-is-key)
- [Lua 字符串优化技巧](https://www.lua.org/pil/11.6.html)

---

## 参见

- [Prometheus 指标体系概述](./prometheus.md#核心概念)
- [如何选择合适的标签维度](./prometheus.md#标签设计最佳实践)
- [监控系统性能优化](./prometheus.md#性能优化建议)
