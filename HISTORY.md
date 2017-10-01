## v0.3.0 (Oct 1, 2017)
Bug fixes:

- netpacket expand queue
- netstream.check and netstream gc
- profiler timestamp
- aes cbc mode
- redis reconnect the dbindex will be reseted

New features:

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


## v0.2.2 (Jan 3, 2017)
Bug fixes:

- http protocol
- [socket] trysend

New features:

- new profiler
- modify socket.lua default limit of  max packet size to 65535
- modify default backlog to 256

## v0.2.1 (Oct 9, 2016)
Bug fixes:
- daemon log buffer mode
- zproto map key bug sync
- netpacket memory leak
- udp message memory leak

New features:
- update to lua 5.3.3
- count the memory used of luaVM
- daemon log path can be customed
- add silly.channel as synchronize tool
- add core.wait2/core.wakeup2 interface


## v0.2.0 (Aug 8, 2016)

Hello World!
Roughly complete socket I/O and some basic library.

