---
title: API 参考
index: true
icon: code
category:
  - 参考
---

# API 参考手册

完整的 Silly 框架 API 文档，包含所有模块、函数、参数和返回值的详细说明。

## 核心模块

框架的核心功能，包括协程调度、定时器、信号处理等。

- [silly](./silly.md) - 核心调度器
- [silly.time](./time.md) - 定时器和时间管理
- [silly.signal](./signal.md) - Unix信号处理
- [silly.logger](./logger.md) - 日志系统
- [silly.hive](./hive.md) - 工作线程池

## 工具模块

开发和运维工具，包括控制台、调试器、热更新等。

- [silly.console](./console.md) - 交互式控制台
- [silly.debugger](./debugger.md) - 交互式调试器
- [silly.patch](./patch.md) - 模块热更新

## 加密模块

密码学相关功能，基于 OpenSSL 实现。

- [silly.crypto.cipher](./crypto/cipher.md) - 对称加密（AES、DES等）
- [silly.crypto.hash](./crypto/hash.md) - 哈希函数（SHA256、MD5等）
- [silly.crypto.hmac](./crypto/hmac.md) - 消息认证码（HMAC）
- [silly.crypto.pkey](./crypto/pkey.md) - 非对称加密（RSA、EC）

## 编码模块

数据编码和解码工具。

- [silly.encoding.json](./encoding/json.md) - JSON编码解码

## 同步模块

协程同步原语，用于协程间的协作和通信。

- [silly.sync.mutex](./sync/mutex.md) - 互斥锁
- [silly.sync.channel](./sync/channel.md) - 通道（协程间通信）
- [silly.sync.waitgroup](./sync/waitgroup.md) - 等待组

## 网络模块

网络相关功能，包括TCP、UDP、TLS、HTTP等协议支持。

### 基础协议

- [silly.net](./net.md) - 网络基础模块（底层API）
- [silly.net.tcp](./net/tcp.md) - TCP协议
- [silly.net.udp](./net/udp.md) - UDP协议
- [silly.net.tls](./net/tls.md) - TLS/SSL加密

### 应用协议

- [silly.net.http](./net/http.md) - HTTP/1.1 和 HTTP/2 协议
- [silly.net.websocket](./net/websocket.md) - WebSocket 协议
- [silly.net.grpc](./net/grpc.md) - gRPC 协议
- [silly.net.dns](./net/dns.md) - DNS 域名解析
- [silly.net.cluster](./net/cluster.md) - 分布式集群通信

## 存储模块

数据存储和持久化，包括关系型数据库、键值存储、分布式配置等。

- [silly.store.mysql](./store/mysql.md) - MySQL 数据库客户端
- [silly.store.redis](./store/redis.md) - Redis 键值存储客户端
- [silly.store.etcd](./store/etcd.md) - etcd 分布式配置存储

## 安全模块

身份认证和授权相关功能。

- [silly.security.jwt](./security/jwt.md) - JSON Web Token (JWT) 认证

## 监控模块

应用性能监控和指标采集，支持 Prometheus 格式导出。

### 核心指标类型

- [silly.metrics.counter](./metrics/counter.md) - 计数器（只增不减）
- [silly.metrics.gauge](./metrics/gauge.md) - 仪表（可增可减）
- [silly.metrics.histogram](./metrics/histogram.md) - 直方图（分布统计）

### 指标管理

- [silly.metrics.prometheus](./metrics/prometheus.md) - Prometheus 集成（便捷封装）
- [silly.metrics.registry](./metrics/registry.md) - 指标注册表
- [silly.metrics.collector](./metrics/collector.md) - 自定义采集器接口
- [silly.metrics.labels](./metrics/labels.md) - 标签管理（内部模块）

## 使用说明

- **信息导向**: 准确、干燥的技术描述
- **完整性**: 涵盖所有公开API
- **可搜索**: 使用搜索功能快速找到需要的API

## 相关资源

- [教程](/tutorials/) - 学习如何使用
- [操作指南](/guides/) - 解决具体问题
- [原理解析](/concepts/) - 理解设计理念
