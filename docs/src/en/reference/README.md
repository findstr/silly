---
title: API Reference
index: true
icon: code
category:
  - Reference
---

# API Reference Manual

Complete Silly framework API documentation, including detailed descriptions of all modules, functions, parameters, and return values.

## Core Modules

Core functionality of the framework, including coroutine scheduling, timers, signal handling, etc.

- [silly](./silly.md) - Core module
- [silly.task](./task.md) - Coroutine task management
- [silly.time](./time.md) - Timers and time management
- [silly.signal](./signal.md) - Unix signal handling
- [silly.logger](./logger.md) - Logging system
- [silly.hive](./hive.md) - Worker thread pool

## Utility Modules

Development and operations tools, including console, debugger, hot reload, etc.

- [silly.console](./console.md) - Interactive console
- [silly.debugger](./debugger.md) - Interactive debugger
- [silly.patch](./patch.md) - Module hot reload

## Data Structure Modules

Efficient data structure implementations for handling network data streams and queue management.

- [silly.adt.buffer](./adt/buffer.md) - Byte buffer
- [silly.adt.queue](./adt/queue.md) - FIFO queue

## Cryptographic Modules

Cryptography-related functionality, based on OpenSSL implementation.

- [silly.crypto.cipher](./crypto/cipher.md) - Symmetric encryption (AES, DES, etc.)
- [silly.crypto.hash](./crypto/hash.md) - Hash functions (SHA256, MD5, etc.)
- [silly.crypto.hmac](./crypto/hmac.md) - Message authentication codes (HMAC)
- [silly.crypto.pkey](./crypto/pkey.md) - Asymmetric encryption (RSA, EC)

## Encoding Modules

Data encoding and decoding utilities.

- [silly.encoding.json](./encoding/json.md) - JSON encoding/decoding
- [silly.encoding.base64](./encoding/base64.md) - Base64 encoding/decoding

## Synchronization Modules

Coroutine synchronization primitives for coordination and communication between coroutines.

- [silly.sync.mutex](./sync/mutex.md) - Mutex lock
- [silly.sync.channel](./sync/channel.md) - Channel (inter-coroutine communication)
- [silly.sync.waitgroup](./sync/waitgroup.md) - Wait group

## Network Modules

Network-related functionality, including support for TCP, UDP, TLS, HTTP, and other protocols.

### Basic Protocols

- [silly.net](./net.md) - Network base module (low-level API)
- [silly.net.tcp](./net/tcp.md) - TCP protocol
- [silly.net.udp](./net/udp.md) - UDP protocol
- [silly.net.tls](./net/tls.md) - TLS/SSL encryption

### Application Protocols

- [silly.net.http](./net/http.md) - HTTP/1.1 and HTTP/2 protocols
- [silly.net.websocket](./net/websocket.md) - WebSocket protocol
- [silly.net.grpc](./net/grpc.md) - gRPC protocol
- [silly.net.dns](./net/dns.md) - DNS domain name resolution
- [silly.net.cluster](./net/cluster.md) - Distributed cluster communication

## Storage Modules

Data storage and persistence, including relational databases, key-value stores, distributed configuration, etc.

- [silly.store.mysql](./store/mysql.md) - MySQL database client
- [silly.store.redis](./store/redis.md) - Redis key-value store client
- [silly.store.etcd](./store/etcd.md) - etcd distributed configuration store

## Security Modules

Authentication and authorization related functionality.

- [silly.security.jwt](./security/jwt.md) - JSON Web Token (JWT) authentication

## Monitoring Modules

Application performance monitoring and metrics collection with Prometheus format export support.

### Core Metric Types

- [silly.metrics.counter](./metrics/counter.md) - Counter (monotonically increasing)
- [silly.metrics.gauge](./metrics/gauge.md) - Gauge (can increase or decrease)
- [silly.metrics.histogram](./metrics/histogram.md) - Histogram (distribution statistics)

### Metrics Management

- [silly.metrics.prometheus](./metrics/prometheus.md) - Prometheus integration (convenience wrapper)
- [silly.metrics.registry](./metrics/registry.md) - Metrics registry
- [silly.metrics.collector](./metrics/collector.md) - Custom collector interface
- [silly.metrics.labels](./metrics/labels.md) - Label management (internal module)

## Usage Notes

- **Information-Oriented**: Accurate, dry technical descriptions
- **Completeness**: Covers all public APIs
- **Searchable**: Use search functionality to quickly find needed APIs

## Related Resources

- [Tutorials](/en/tutorials/) - Learn how to use
- [How-To Guides](/en/guides/) - Solve specific problems
- [Concepts](/en/concepts/) - Understand design principles
