## Unreleased

### Added
- Add `mingw` support

---

## v0.6.0 (Dec 18, 2024)

### Fixed
- Fix websocket frame header byte order
- Fix http2 scheme header and reset_frame error code
- Fix http2 window handling
- Fix various lint warnings

### Added
- Add gRPC support
- Add signal support
- Add cancel support for timer and redesign node cache
- Add Prometheus metrics
- Add distributed tracing via log (experimental)
- Add cluster.lua as a flexible alternative to cluster.rpc and cluster.msg
- Add LuaLS/lua-language-server annotations for type checking and navigation
- Support TLS SNI certificates
- Support automatic HTTP/HTTP2 protocol switching
- Support ETCDv3 client (kv, lease, watch) partially

### Changed
- Handle websocket connection close gracefully
- Remove trailing '\r\n' from Redis responses
- Refine endless loop warnings and include tracebacks
- Unify code style using clang-format
- Reimplement startup mechanism and module layout
- Reimplement logger with log levels (debug, info, warn, error) and improved performance

---

## v0.5.0 (Dec 1, 2021)

### Fixed
- Fix incorrect session type in netpacket.rpcpack
- Fix incorrect lua_gc invocation
- Handle socket close events in send_msg_tcp/send_msg_udp

### Added
- Add cluster module for cluster networking
- Allow startup parameters to override environment variables
- Add examples for timer, socket, rpc, http, and websocket
- Optimize core.timeout for large timer workloads
- Extend crypto module with URL-safe base64, sha256, digestsign, and digestverify
- Support TLS SNI and ALPN
- Support HTTP/2
- Refine patch mechanism for flexibility
- Add extended monitor data (timer events, memory usage)

---

## v0.4.0 (Nov 2, 2020)

### Fixed
- Fix timer session race condition
- Fix tls.read returning corrupted data
- Fix DNS name cache
- Fix sys.socketq authentication race condition
- Fix DNS session overflow
- Fix netpacket hash collision handling
- Ensure no code executes after core.exit()
- Fix saux.rpc handling of multiple messages per loop
- Fix saux.rpc timer leak

### Added
- Support IPv6 DNS server addresses
- Add DOM parser for HTTP
- Add wakegroup for waiting on coroutine groups
- Add fd round-back check for sys.socket
- Add monitor thread for slow event detection
- Abstract task (coroutine wrapper for socket and timer events)
- Extend console with task and network debug info
- Support numeric index keys in core.env
- Add flow control
- Upgrade to Lua 5.4 and enable generational GC by default

---

## v0.3.0 (Oct 1, 2017)

### Fixed
- Expand netpacket queue
- Fix netstream.check and netstream GC
- Fix profiler timestamp handling
- Fix AES-CBC mode
- Reset Redis dbindex on reconnect

### Added
- Add SSL support for http.client
- Add base64 support
- Add hotpatch support for Lua code
- Add pidfile support
- Use jemalloc as default memory allocator
- Import accept4 on Linux
- Support configurable CPU affinity on Linux
- Add include directive to config files
- Replace old RPC with saux.rpc and saux.msg
- Add socket tag for debugging
- Support shell environment expansion in config files
- Support multicast data sending
- Synchronize zproto to support float
- Support nested CNAME resolution in DNS
- Allow socket.write to accept string arrays
- Add Redis pipeline support
- Extend core.write to support lightuserdata and string arrays
- Handle file descriptor exhaustion during accept
- Remove lualib-log and refine daemon logger

---

## v0.2.2 (Jan 3, 2017)

### Fixed
- Fix HTTP protocol handling
- Fix socket trysend behavior

### Added
- Add new profiler
- Increase default max packet size to 65535
- Increase default listen backlog to 256

---

## v0.2.1 (Oct 9, 2016)

### Fixed
- Fix daemon log buffer mode
- Fix zproto map key synchronization bug
- Fix netpacket memory leak
- Fix UDP message memory leak

### Added
- Update to Lua 5.3.3
- Track Lua VM memory usage
- Allow custom daemon log paths
- Add silly.channel synchronization primitive
- Add core.wait2 and core.wakeup2 interfaces

---

## v0.2.0 (Aug 8, 2016)

Initial release.

- Basic socket I/O
- Core libraries
