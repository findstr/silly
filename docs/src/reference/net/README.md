---
title: silly.net
index: true
icon: network-wired
---

# silly.net

`silly.net` 模块提供了网络相关的功能，包括多种协议和网络服务的实现。

## net.free(ptr)

释放底层 `data` 回调交给调用方的原始接收缓冲区，`ptr` 为 `lightuserdata`。
仅用于尚未转交给其他接口、也尚未释放的缓冲区。每块缓冲区只能释放一次。

## 模块列表

### 传输层协议
- [tcp](tcp.md) - TCP 网络协议
- [udp](udp.md) - UDP 网络协议
- [tls](tls.md) - TLS/SSL 加密传输

### 应用层协议
- [http](http.md) - HTTP 服务器和客户端
- [websocket](websocket.md) - WebSocket 协议
- [grpc](grpc.md) - gRPC 协议

### 网络服务
- [dns](dns.md) - DNS 域名解析
- [cluster](cluster.md) - 集群节点通信

### 工具
- [addr](addr.md) - 地址解析与拼接工具
