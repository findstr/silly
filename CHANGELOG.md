## Unreleased

### Added
- `net.http.url` for URL parsing, resolution, reconstruction, and query/path escaping; replaces the URL helpers in `net.http.helper` (`parseurl`, `urlencode`, `urldecode`).
- HTTP client redirects (301/302/303/307/308) with loop detection and a redirect limit, and `client.close()` for graceful connection-pool shutdown.
- Configurable HTTP/2 PING keepalive for HTTP and gRPC clients and servers: `keepalive.read_idle_timeout` and `keepalive.ping_timeout` (milliseconds). Probes are disabled by default, work without active streams and outside DATA flow control, require a matching ACK, and wake waiters on timeout.
- `silly.errno` for uniform transport errors with human-readable messages and numeric suffixes. Only `net`, `net.tcp`, `net.tls`, and `net.udp` expose comparable errno contracts; higher-level errors remain opaque strings.
- Go-backed HTTP/1.1 and HTTP/2 conformance tests, including bidirectional interoperability and HPACK decoder comparisons.

### Changed
- HTTP/1.1 and HTTP/2 derive Host/`:authority` from the URL authority and preserve caller-supplied header tables, with one authoritative host header per request.
- HTTP/1.1 `request()` accepts an optional timeout for `Expect: 100-continue`.
- Cluster connections are eager and independent: `connect()` performs DNS/TCP setup in a coroutine and returns `peer?, err?`; auto-reconnect is removed, and callers reconnect after `call`/`send` reports `"Peer closed"`. `accept(peer)` receives the client address through `peer.remoteaddr`, replacing `addr` and the callback's address argument.
- Cluster calls use raw data strings instead of `cmd` and `marshal`/`unmarshal` options. Sessions are 64-bit, with `[session(8)][traceid(8)]` request and `[session(8)]` response headers. This breaks wire compatibility; all peers must upgrade together.
- API references refreshed against the implementation in English and Chinese; repository agent guidance consolidated in `AGENTS.md`.

### Fixed
- Cluster drops late responses after request timeout instead of waking a missing coroutine.
- HTTP/1.1 handles malformed chunk sizes without calling `tonumber` on missing hex, skips informational responses until the final response, and resets body EOF after `100 Continue`. Client body reads share one deadline to prevent timeout amplification.
- HPACK preserves the correct send/receive table direction when applying SETTINGS, emits required table-size updates, evicts only the oldest entries needed on insertion or shrink, handles oversized indexed entries without changing the table for unindexed fields, preserves opaque field bytes with unambiguous cache keys, and rejects truncated or overflowing integers.
- HTTP/2 emits contiguous HEADERS/CONTINUATION blocks with correct frame types and flags, validates initial SETTINGS, GOAWAY, padding, server ENABLE_PUSH settings, disabled server push and response trailers, and distinguishes informational from final responses.
- HTTP/2 maintains stream/connection windows and stream limits, isolates malformed-message errors to their streams, preserves valid completed responses after `RST_STREAM NO_ERROR` and handler cleanup failures without losing validation errors, sends graceful GOAWAY, and wakes blocked readers, writers and stream openers on connection shutdown. Cleartext server streams report the `http` scheme.
- gRPC retains status and message from trailers-only error responses.
- Task recycling quarantines coroutines left in an invalid state after failed yields, preventing stale events from resuming a reused coroutine.
- TLS skips zero-length buffers in `SSL_write`; Windows uses explicit socket errno handling and supports `writev` on non-socket file descriptors.

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
