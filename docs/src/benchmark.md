---
title: 性能基准测试
icon: chart-line
order: 10
---

# 性能基准测试

本页面展示 Silly 框架在不同场景下的性能表现。

## 测试环境

**测试机型**：
- CPU: Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz
- 测试工具: redis-benchmark

**测试命令**：
```bash
./redis-benchmark -t ping -c 100 -n 100000
```

## 测试代码

```lua
local tcp = require "silly.net.tcp"

local readline = tcp.readline
local write = tcp.write

local listenfd = tcp.listen("127.0.0.1:6379", function(fd, addr)
    while true do
        local l = readline(fd, "\r\n")
        if not l then
            break
        end
        if l == "save\r\n" then
            write(fd, "*2\r\n$4\r\nsave\r\n$23\r\n3600 1 300 100 60 10000\r\n")
        elseif l == "appendonly\r\n" then
            write(fd, "*2\r\n$10\r\nappendonly\r\n$2\r\nno\r\n")
        elseif l == "PING\r\n" then
            write(fd, "+PONG\r\n")
        end
    end
end)
```

## 测试结果

### PING_INLINE

```
====== PING_INLINE ======
  100000 requests completed in 0.42 seconds
  100 parallel clients
  3 bytes payload
  keep alive: 1
  host configuration "save": 3600 1 300 100 60 10000
  host configuration "appendonly": no
  multi-thread: no

Latency by percentile distribution:
0.000% <= 0.087 milliseconds (cumulative count 1)
50.000% <= 0.223 milliseconds (cumulative count 53428)
75.000% <= 0.247 milliseconds (cumulative count 82236)
87.500% <= 0.263 milliseconds (cumulative count 90896)
93.750% <= 0.279 milliseconds (cumulative count 95021)
96.875% <= 0.295 milliseconds (cumulative count 96880)
98.438% <= 0.327 milliseconds (cumulative count 98451)
99.219% <= 0.391 milliseconds (cumulative count 99243)
99.609% <= 0.455 milliseconds (cumulative count 99642)
99.805% <= 0.983 milliseconds (cumulative count 99806)
99.902% <= 1.007 milliseconds (cumulative count 99905)
99.951% <= 1.183 milliseconds (cumulative count 99953)
99.976% <= 1.503 milliseconds (cumulative count 99976)
99.988% <= 1.511 milliseconds (cumulative count 99990)
99.994% <= 1.527 milliseconds (cumulative count 100000)
100.000% <= 1.527 milliseconds (cumulative count 100000)

Cumulative distribution of latencies:
0.006% <= 0.103 milliseconds (cumulative count 6)
25.212% <= 0.207 milliseconds (cumulative count 25212)
97.423% <= 0.303 milliseconds (cumulative count 97423)
99.369% <= 0.407 milliseconds (cumulative count 99369)
99.697% <= 0.503 milliseconds (cumulative count 99697)
99.763% <= 0.607 milliseconds (cumulative count 99763)
99.765% <= 0.703 milliseconds (cumulative count 99765)
99.905% <= 1.007 milliseconds (cumulative count 99905)
99.962% <= 1.207 milliseconds (cumulative count 99962)
99.976% <= 1.503 milliseconds (cumulative count 99976)
100.000% <= 1.607 milliseconds (cumulative count 100000)

Summary:
  throughput summary: 235849.06 requests per second
  latency summary (msec):
          avg       min       p50       p95       p99       max
        0.230     0.080     0.223     0.279     0.367     1.527
```

**关键指标**：
- **吞吐量**: 235,849 请求/秒
- **平均延迟**: 0.230ms
- **P50 延迟**: 0.223ms
- **P95 延迟**: 0.279ms
- **P99 延迟**: 0.367ms
- **最大延迟**: 1.527ms

### PING_MBULK

```
====== PING_MBULK ======
  100000 requests completed in 0.44 seconds
  100 parallel clients
  3 bytes payload
  keep alive: 1
  host configuration "save": 3600 1 300 100 60 10000
  host configuration "appendonly": no
  multi-thread: no

Latency by percentile distribution:
0.000% <= 0.143 milliseconds (cumulative count 1)
50.000% <= 0.231 milliseconds (cumulative count 53801)
75.000% <= 0.255 milliseconds (cumulative count 78576)
87.500% <= 0.279 milliseconds (cumulative count 89337)
93.750% <= 0.311 milliseconds (cumulative count 93872)
96.875% <= 0.391 milliseconds (cumulative count 97004)
98.438% <= 0.447 milliseconds (cumulative count 98524)
99.219% <= 0.495 milliseconds (cumulative count 99232)
99.609% <= 0.559 milliseconds (cumulative count 99644)
99.805% <= 0.639 milliseconds (cumulative count 99811)
99.902% <= 0.679 milliseconds (cumulative count 99904)
99.951% <= 0.791 milliseconds (cumulative count 99954)
99.976% <= 0.839 milliseconds (cumulative count 99981)
99.988% <= 0.855 milliseconds (cumulative count 99992)
99.994% <= 0.863 milliseconds (cumulative count 99997)
99.998% <= 0.879 milliseconds (cumulative count 99999)
99.999% <= 0.887 milliseconds (cumulative count 100000)
100.000% <= 0.887 milliseconds (cumulative count 100000)

Cumulative distribution of latencies:
0.000% <= 0.103 milliseconds (cumulative count 0)
20.267% <= 0.207 milliseconds (cumulative count 20267)
93.185% <= 0.303 milliseconds (cumulative count 93185)
97.642% <= 0.407 milliseconds (cumulative count 97642)
99.303% <= 0.503 milliseconds (cumulative count 99303)
99.750% <= 0.607 milliseconds (cumulative count 99750)
99.920% <= 0.703 milliseconds (cumulative count 99920)
99.960% <= 0.807 milliseconds (cumulative count 99960)
100.000% <= 0.903 milliseconds (cumulative count 100000)

Summary:
  throughput summary: 224719.11 requests per second
  latency summary (msec):
          avg       min       p50       p95       p99       max
        0.241     0.136     0.231     0.335     0.479     0.887
```

**关键指标**：
- **吞吐量**: 224,719 请求/秒
- **平均延迟**: 0.241ms
- **P50 延迟**: 0.231ms
- **P95 延迟**: 0.335ms
- **P99 延迟**: 0.479ms
- **最大延迟**: 0.887ms

## 性能总结

| 测试类型 | 吞吐量 (请求/秒) | 平均延迟 | P99 延迟 |
|---------|----------------:|--------:|--------:|
| PING_INLINE | 235,849 | 0.230ms | 0.367ms |
| PING_MBULK  | 224,719 | 0.241ms | 0.479ms |

## 性能特点

Silly 框架展现出以下性能特点：

1. **高吞吐量** - 单进程单线程即可达到 20 万+ QPS
2. **低延迟** - P99 延迟小于 0.5ms，平均延迟约 0.24ms
3. **稳定性好** - 延迟分布集中，最大延迟控制在 2ms 以内
4. **资源高效** - 单线程业务逻辑模型，无锁竞争

## 优化建议

要获得最佳性能，建议：

1. **使用最新版本** - 每个版本都包含性能优化
2. **启用 jemalloc** - 编译时使用 `make MALLOC=jemalloc`
3. **CPU 亲和性** - 使用 `--socket_cpu_affinity` 和 `--worker_cpu_affinity` 绑定 CPU
4. **避免阻塞操作** - 所有 I/O 使用异步 API
5. **合理使用协程** - 避免创建过多协程导致调度开销

## 自行测试

您可以使用以下命令重现基准测试：

```bash
# 编译 Silly
make

# 运行测试服务器
./silly benchmark.lua

# 在另一个终端运行 redis-benchmark
redis-benchmark -t ping -c 100 -n 100000
```

其中 `benchmark.lua` 包含上述测试代码。
