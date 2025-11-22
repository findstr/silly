---
title: Benchmark
icon: chart-line
order: 10
---

# Benchmark

This page shows Silly framework's performance in different scenarios.

## Test Environment

**Test Machine**:
- CPU: Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz
- Test Tool: redis-benchmark

**Test Command**:
```bash
./redis-benchmark -t ping -c 100 -n 100000
```

## Test Code

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

## Test Results

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

**Key Metrics**:
- **Throughput**: 235,849 requests/second
- **Average Latency**: 0.230ms
- **P50 Latency**: 0.223ms
- **P95 Latency**: 0.279ms
- **P99 Latency**: 0.367ms
- **Max Latency**: 1.527ms

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

**Key Metrics**:
- **Throughput**: 224,719 requests/second
- **Average Latency**: 0.241ms
- **P50 Latency**: 0.231ms
- **P95 Latency**: 0.335ms
- **P99 Latency**: 0.479ms
- **Max Latency**: 0.887ms

## Performance Summary

| Test Type | Throughput (req/s) | Avg Latency | P99 Latency |
|-----------|------------------:|------------:|------------:|
| PING_INLINE | 235,849 | 0.230ms | 0.367ms |
| PING_MBULK  | 224,719 | 0.241ms | 0.479ms |

## Performance Characteristics

Silly framework exhibits the following performance characteristics:

1. **High Throughput** - Single process, single thread can reach 200,000+ QPS
2. **Low Latency** - P99 latency under 0.5ms, average latency around 0.24ms
3. **Good Stability** - Concentrated latency distribution, max latency controlled within 2ms
4. **Resource Efficient** - Single-threaded business logic model, no lock contention

## Optimization Recommendations

For best performance, it's recommended to:

1. **Use Latest Version** - Each version includes performance optimizations
2. **Enable jemalloc** - Compile with `make MALLOC=jemalloc`
3. **CPU Affinity** - Use `--socket_cpu_affinity` and `--worker_cpu_affinity` to bind CPUs
4. **Avoid Blocking Operations** - Use async APIs for all I/O
5. **Reasonable Coroutine Usage** - Avoid creating too many coroutines causing scheduling overhead

## Run Your Own Tests

You can reproduce the benchmark with the following commands:

```bash
# Compile Silly
make

# Run test server
./silly benchmark.lua

# Run redis-benchmark in another terminal
redis-benchmark -t ping -c 100 -n 100000
```

Where `benchmark.lua` contains the test code above.
