---
title: silly.perf
icon: gauge-high
category:
  - API参考
tag:
  - 核心
  - 性能
  - 分析
---

# silly.perf

性能分析模块，提供高精度时间测量和函数执行时间统计。

## 模块导入

```lua validate
local perf = require "silly.perf"
```

## 时间函数

### perf.hrtime()
获取高精度单调时间（纳秒）。

- **返回值**: `integer` - 单调时间（纳秒）
- **用途**: 高精度性能测量
- **示例**:
```lua validate
local perf = require "silly.perf"

local start = perf.hrtime()
-- ... do something ...
local elapsed_ns = perf.hrtime() - start
local elapsed_ms = elapsed_ns / 1e6
print("Elapsed:", elapsed_ms, "ms")
```

## 分析函数

### perf.start(name)
开始对指定名称的代码段计时。

- **参数**:
  - `name`: `string` - 代码段名称
- **注意**: 必须与 `perf.stop(name)` 配对使用
- **示例**:
```lua validate
local perf = require "silly.perf"

perf.start("process_data")
-- ... do something ...
perf.stop("process_data")
```

### perf.stop(name)
停止对指定名称的代码段计时。

- **参数**:
  - `name`: `string` - 代码段名称（必须与 `start` 匹配）
- **错误**:
  - 如果没有对应的 `start` 调用，将抛出错误
  - 如果 `start` 和 `stop` 不配对，将抛出错误

### perf.yield()
在协程 yield 前调用，暂停当前协程的计时。

- **用途**: 确保协程挂起期间不计入执行时间
- **示例**:
```lua validate
local perf = require "silly.perf"
local silly = require "silly"

-- 在自定义调度器中使用
perf.yield()
silly.yield()
```

### perf.resume(co)
在协程 resume 后调用，恢复目标协程的计时。

- **参数**:
  - `co`: `thread` - 被恢复的协程
- **示例**:
```lua validate
local perf = require "silly.perf"

-- 在自定义调度器中使用
coroutine.resume(co)
perf.resume(co)
```

### perf.dump([name])
导出性能统计数据。

- **参数**:
  - `name`: `string` (可选) - 指定代码段名称，不传则返回所有统计
- **返回值**: `table` - 统计数据表
  - 如果指定 `name`: 返回 `{time = ns, call = count}`
  - 如果不指定: 返回 `{[name] = {time = ns, call = count}, ...}`
- **字段说明**:
  - `time`: 累计执行时间（纳秒）
  - `call`: 调用次数
- **示例**:
```lua validate
local perf = require "silly.perf"

-- 获取所有统计
local stats = perf.dump()
for name, data in pairs(stats) do
    print(name, "time:", data.time / 1e6, "ms", "calls:", data.call)
end

-- 获取指定统计
local data = perf.dump("process_data")
if data then
    print("process_data:", data.time / 1e6, "ms", data.call, "calls")
end
```

## 使用示例

### 示例1：简单性能测量

```lua validate
local perf = require "silly.perf"

local start = perf.hrtime()
local sum = 0
for i = 1, 1000000 do
    sum = sum + i
end
local elapsed = perf.hrtime() - start
print("Elapsed:", elapsed / 1e6, "ms")
```

### 示例2：函数执行时间统计

```lua validate
local perf = require "silly.perf"

local function process_request(data)
    perf.start("process_request")
    -- 模拟处理
    local result = data
    perf.stop("process_request")
    return result
end

-- 模拟多次调用
for i = 1, 100 do
    process_request("data" .. i)
end

-- 查看统计
local stats = perf.dump("process_request")
print("Total time:", stats.time / 1e6, "ms")
print("Calls:", stats.call)
print("Avg time:", stats.time / stats.call / 1e6, "ms")
```

### 示例3：多代码段对比

```lua validate
local perf = require "silly.perf"

local function method_a()
    perf.start("method_a")
    local t = {}
    for i = 1, 10000 do
        t[i] = i
    end
    perf.stop("method_a")
end

local function method_b()
    perf.start("method_b")
    local t = {}
    for i = 1, 10000 do
        table.insert(t, i)
    end
    perf.stop("method_b")
end

-- 执行测试
for _ = 1, 100 do
    method_a()
    method_b()
end

-- 对比结果
local stats = perf.dump()
for name, data in pairs(stats) do
    print(name .. ":", data.time / 1e6, "ms total,",
          data.time / data.call / 1e6, "ms avg")
end
```

## 精度说明

- **hrtime() 精度**: 纳秒级（Linux 使用 `CLOCK_MONOTONIC`，macOS 使用 `task_info`）
- **单位**: 所有时间值均为纳秒
- **转换**:
  - 纳秒 → 微秒: `ns / 1e3`
  - 纳秒 → 毫秒: `ns / 1e6`
  - 纳秒 → 秒: `ns / 1e9`

## 注意事项

1. `start` 和 `stop` 必须严格配对
2. 同一名称在同一协程中不能嵌套调用 `start`
3. 在协程环境中使用时，建议配合 `yield` 和 `resume` 确保时间统计准确
4. 统计数据使用弱表存储，协程结束后相关数据会被自动回收

## 参见

- [silly.time](./time.md) - 定时器模块
- [silly.trace](./trace.md) - 追踪模块
