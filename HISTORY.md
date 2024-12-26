## Unreleased

##### Bug fixes:
##### New features:
- Add `mingw` support

## v0.6.0 (Dec 18, 2024)

##### Bug fixes:

- Fix `websocket` frame header byte order
- Fix `http2` scheme header && reset_frame error code
- Fix `http2` window handle
- Fix some lint warnings

##### New features:

- Add `grpc` support
- Add `signal` support
- Add `cancel` for `timer` and redesign node cache
- Add `metrics` of prometheus
- Add distributed tracing via log(expriemental)
- Add `cluster.lua` to provide a more flexible alternative to `cluster.rpc` and `cluster.msg`
- Add annotations for LuaLS/lua-language-server to enable type checking and enhance navigation capabilities
- Support `TLS` `sni` cert
- Support `HTTP` automatic switching between http and http2
- Support `ETCDv3` client(kv, lease, watch) partially
- Handle `websocket` connection close gracefully
- Remove `redis` response of '\r\n'
- Refine endless loop warning introduce tracebacks for improved problem diagnosis
- Use clang-format to unify code style
- Reimplement startup mechanism and module layout
- Reimplement logger to support log level(debug, info, warn, error) and more faster

---
## v0.5.0 (Dec 1, 2021)

##### Bug fixes:

- fix incorrect session type in netpacket.rpcpack
- fix incorrect call of lua_gc
- handle socket close event in send_msg_tcp/send_msg_udp

##### New features:

- add cluster module to provide some help for cluster networking
- use parameters instead of environment variables to override startup variables ([#984308b](https://github.com/findstr/silly/tree/984308b82012e733bcf8c8481875a6a6f888a2ff))
- add examples for timer,socket,rpc,http,websocket
- refine core.timeout for large number of timer events(delay create task for timer event can reduce the memory usage to 30% of the original)
- crypto.base64encode support url safe code and add crypto.sha256, crypto.digestsign, crypto.digestverify
- TLS support SNI,ALPN
- support http2
- refine patch(more flexible, more powerful)
- more monitor data(timer event info, more memory info)

---

## v0.4.0 (Nov 2, 2020)

##### Bug fixes:

- fix timer session race condition
- fix tls.read, may read broken data
- fix dns name cache
- fix sys.socketq(renamed from sys.socketdispatch) auth race condition
- fix dns session overflow
- fix netpacket when hash conflict
- fix core.exit, no code should be run after core.exit()
- fix saux.rpc when more than one message pops up in a loop
- fix saux.rpc timer leak

##### New features:

- dns support ipv6 server address
- http support dom parser
- add wakegroup for waiting for a collection of coroutines to finish
- add fd round back check for sys.socket
- add monitor thread to monitor slow events(events that take too long to process)
- abstract `task(special use of coroutine)` for wrapper of event(socket, timer)
- console add task/net info for debug
- core.env support number index key
- add flow control
- upgrade to lua5.4 and enable generational gc by default

---

## v0.3.0 (Oct 1, 2017)

##### Bug fixes:

- netpacket expand queue
- netstream.check and netstream gc
- profiler timestamp
- aes cbc mode
- redis reconnect the dbindex will be reseted

##### New features:

- add ssl for http.client
- add base64
- add hotpatch for lua code
- add pidfile
- import jemalloc as default memory allocator
- import accept4 in linux
- import cpu affinity which can be user defined in linux
- config file add 'include' command
- remove old rpc and add saux.rpc and saux.msg to support rpc/msg server
- socket add 'tag' for more easy debug
- config file support shell environment
- support multicast in data send level
- synchroize zproto to support float
- dns support cname nested
- socket.write support pass string array as parameter
- redis support pipeline
- core.write support lightuserdata/string/string array
- process the condition of run out of fd when accept
- remove lualib-log and refine daemon log to replace it


-----
## v0.2.2 (Jan 3, 2017)

##### Bug fixes:

- http protocol
- [socket] trysend

##### New features:

- new profiler
- modify socket.lua default limit of  max packet size to 65535
- modify default backlog to 256

---
## v0.2.1 (Oct 9, 2016)

##### Bug fixes:

- daemon log buffer mode
- zproto map key bug sync
- netpacket memory leak
- udp message memory leak

##### New features:

- update to lua 5.3.3
- count the memory used of luaVM
- daemon log path can be customed
- add silly.channel as synchronize tool
- add core.wait2/core.wakeup2 interface


----
## v0.2.0 (Aug 8, 2016)

Hello World!
Roughly complete socket I/O and some basic library.

