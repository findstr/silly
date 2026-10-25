---
title: silly.net
index: true
icon: network-wired
---

# silly.net

The `silly.net` module provides network-related functionality, including implementations of various protocols and network services.

## net.free(ptr)

Releases a raw receive buffer passed to the caller by a low-level `data` callback.
`ptr` is a `lightuserdata`. Only release a buffer that has not been transferred to
another API or freed already. Release each buffer exactly once.

## Module List

### Transport Layer Protocols
- [tcp](tcp.md) - TCP network protocol
- [udp](udp.md) - UDP network protocol
- [tls](tls.md) - TLS/SSL encrypted transport

### Application Layer Protocols
- [http](http.md) - HTTP server and client
- [websocket](websocket.md) - WebSocket protocol
- [grpc](grpc.md) - gRPC protocol

### Network Services
- [dns](dns.md) - DNS domain name resolution
- [cluster](cluster.md) - Cluster node communication

### Utilities
- [addr](addr.md) - Address parsing and joining helpers
- [url](url.md) - URL parsing, resolution, and encoding
