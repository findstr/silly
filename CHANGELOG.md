## Unreleased

### Added
- `adt.queue:remove(value)`.
- `headeronly` on HTTP/2 client streams identifies responses completed by their initial headers.
- `net.http.url` for URL parsing and escaping; replaces `net.http.helper` URL functions (`parseurl`, `urlencode`, `urldecode`).
- HTTP client redirects (301/302/303/307/308) with loop detection and a redirect limit, and `client.close()` for graceful connection-pool shutdown.
- Optional HTTP/2 PING keepalive for HTTP and gRPC clients via `send_ping_timeout`, `ping_timeout` (milliseconds), and `channel:keepalive()`. Disabled by default.
- `silly.errno` for comparable errors from `net`, `net.tcp`, `net.tls`, and `net.udp`; higher-level errors remain opaque strings.
- Go-backed HTTP/1.1, HTTP/2 and HPACK conformance tests.

### Changed
- HTTP/2 waits for a stream slot when sending initial request headers instead of in `openstream()`; reads no longer flush headers. gRPC streaming calls send headers before returning.
- HTTP/2 validates incoming fields, joins split Cookie fields and enforces a 65535-byte decoded header-list limit.
- `h2.httpd(handler, conn, scheme)` now requires the transport scheme.
- HTTP/1.1 Host and HTTP/2 `:authority` follow the URL; request APIs preserve supplied header tables.
- HTTP/1.1 `request()` accepts an optional timeout for `Expect: 100-continue`.
- Cluster `connect()` connects immediately and returns `peer?, err?`. Connections are independent and no longer reconnect automatically.
- Cluster callbacks use `accept(peer)`; the client address is available via `peer.remoteaddr`, replacing `peer.addr`.
- Cluster RPC APIs exchange raw strings; `cmd`, `marshal` and `unmarshal` are removed. The wire protocol is incompatible with earlier versions; all peers must upgrade together.

### Fixed
- Cluster ignores late responses after request timeout.
- HTTP/1.1: fix informational responses, malformed chunk handling and read timeout behavior.
- HPACK: fix table synchronization, incorrect header decoding and packing memory errors.
- HTTP/2: fix framing, flow control, stream limits and CONNECT handling.
- HTTP/2: prevent blocked operations and leaked streams during errors or shutdown; preserve completed responses.
- gRPC: preserve status and message from trailers-only responses.
- Task: prevent invalid coroutine wakeups after failed yields.
- TLS: fix empty writes. Windows: fix socket error reporting and vectored writes.

## v0.7.1 (Apr 10, 2026)

### Added
- `sync.singleflight` to suppress duplicate concurrent work.
- `perf.hrtime` for high-resolution timing.
- `net.addr` module extracted, centralized host:port handling.
- Snappy and LZ4 codecs in `compress`.

### Changed
- Logger redesigned with a ring buffer and async flushing.
- JSON encoding module rewritten in C for performance and RFC 8259 compliance.
- DNS resolver reimplemented with a C-based wire format parser.
- Cluster packet header expanded to 4 bytes and packet size limits enforced (may affect protocol compatibility).
- Hive workers now inherit package path and restrict module access.
- Profiler renamed to `perf`.
- Timer refactored to use unified command buffer instead of separate after/cancel buffers.
- Timer shutdown sequence refactored with explicit thread termination via OP_EXIT commands.

### Fixed
- TLS: propagate handshake/write errors to callers; fix UAF in server ALPN handling.
- Signal: fix async-signal-unsafe handler and cross-thread `lua_sethook` race.
- HTTP/2: validate `:status` in responses; skip content-length validation for no-body responses; mask `WINDOW_UPDATE` reserved bit; remove duplicate SETTINGS ACK during handshake.
- Worker: fix `lua_close` order to prevent use-after-free.
- Timer: refine locking in flipbuf and timer pool.

## v0.7.0 (Dec 28, 2025)

### Added
- New peer-based cluster implementation (`cluster.lua`) as an alternative to legacy cluster APIs.
- Interactive Lua REPL when running without a script or from stdin.
- MySQL `caching_sha2_password` authentication support and connection pooling.
- Etcd v3 client (kv, lease, watch).
- Unified timeout support for `tcp.connect`, `tls.connect`, and `net.connect`.
- Public C API layer (`api.c`) for embedding and integration.
- `silly.hive` thread pool for offloading blocking operations.
- Zlib compression support.
- Dockerfile for containerized builds and deployment.

### Changed

#### Breaking changes
- **Lua runtime upgraded to 5.5.0**.
- Modules reorganized into namespaces (`silly.net`, `silly.store`, `silly.security`, `silly.internal`).
- TCP, UDP, and TLS networking APIs refactored to object-oriented, coroutine-friendly interfaces.
- UDP receive model changed from callbacks to pull-based APIs (e.g. `udp:recvfrom()`).
- HTTP/1.x and HTTP/2 APIs redesigned for protocol correctness.
- `tcp.read` / `tls.read` now return `nil, err` on error and `"" , err` on EOF.
- Legacy `cluster.rpc` and `cluster.msg` APIs removed.
- Internal entry point `silly.start()` made private as `silly._start`.

#### Improvements
- HTTP/2 implementation reworked with proper flow control and stream lifecycle handling.
- gRPC behavior improved for large requests via correct HTTP/2 frame fragmentation handling.
- Socket subsystem refactored with new pooling, ID handling, and error semantics.
- Socket read path redesigned to use a bounded temporary buffer instead of prediction-based growth.
- UDP implementation rewritten to align with coroutine-based networking model.
- WebSocket implementation refined for RFC 6455 compliance.
- TLS enhanced to support loading certificates from PEM content and dynamic reload.
- Redis client API updated (`redis.new` replacing `redis:connect`, `redis.call` added).
- Internal error handling standardized to use string-based error descriptions instead of numeric errno.
- Tracing improved with more robust trace ID generation.
- Logging improved (fixed format specifiers, better consistency, deterministic table truncation using `{...}`, and fallback of unsupported value types to string).
- Atomic operations migrated from GCC built-ins to C11 atomics.
- Platform-specific code isolated into `unix/` and `win/` directories.
- Internal source layout and naming normalized (drop `silly_` prefix, rename `silly-src` → `src`, `lualib-src` → `luaclib-src`).
- Crypto reimplemented on top of OpenSSL.

### Fixed
- HTTP/2 trailer headers arriving before response body.
- Race conditions in `sync.channel`.
- Timer session race conditions.
- Socket-related race conditions and stability issues.

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
