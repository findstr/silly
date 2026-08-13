# Silly 1.0 `net` 逐文件覆盖台账

> 基线：`master@d1aef7ffd8439340dfd957a49fccba3fbf133055`
> 审计分支：`codex/silly-net-review`
> 方法：纯静态审阅；不运行服务、测试、重现、畸形输入、并发 barrier 或 fault injection
> 状态：重建中；本文件没有收口前不得宣称 `net` 已全部审核

## 1. 状态与范围规则

- `已审有归档`：逐函数/逐路径核对完，发现已进入主报告的独立问题。
- `已审无新增`：逐函数/逐路径核对完，候选被静态排除或并入既有问题。
- `审阅中`：已读但仍有候选、调用链或契约未完成反查。
- `待审`：尚不能给出文件级完成证据。
- `范围外`：已读入口/引用，确认不属于内建 net/protocol/storage 依赖闭包；必须写理由。

每个路径单列一行。`问题/证据`只写最直接映射，不表示该文件只与这些问题相关。最终还要用仓库实际文件集合做差集；本台账当前只完成运行时代码第一版，测试、LuaLS、双语文档将在后续章节逐文件追加。

## 2. Engine、平台与公共 C 层

| 路径 | 状态 | 问题/证据 | 尚需动作或排除理由 |
|---|---|---|---|
| `src/api.c` | 已审有归档 | CORE-008、METRIC-003 | API转发、shutdown、stats与native consumers已核对 |
| `src/args.h` | 已审无新增 | main/worker启动参数边界 | 无网络状态或所有权 |
| `src/array.h` | 已审有归档 | CORE-007 | 扩容、size/cap与allocation failure |
| `src/compiler.h` | 已审无新增 | atomic/TLS/likely宏调用点 | 只提供平台编译属性 |
| `src/daemon.c` | 已审无新增 | daemon启动/stdio重定向 | 不持有socket engine对象 |
| `src/daemon.h` | 已审无新增 | daemon接口 | 同上 |
| `src/engine.c` | 已审有归档 | CORE-001至CORE-007、SOCK-008 | init/run/shutdown/cleanup顺序 |
| `src/engine.h` | 已审无新增 | engine生命周期接口 | 实现问题映射到`engine.c` |
| `src/errnoex.h` | 已审无新增 | errno保留与日志调用点 | 未发现独立网络语义偏差 |
| `src/flipbuf.h` | 已审有归档 | CORE-003、CORE-007 | 双区buffer交换与扩容 |
| `src/force_link.c` | 已审无新增 | Windows native module符号引用 | 无运行时状态 |
| `src/log.c` | 已审无新增 | logger跨线程/format/flush | log payload放大由具体协议问题记录 |
| `src/log.h` | 已审无新增 | logger接口 | 无独立状态机 |
| `src/main.c` | 已审无新增 | args→daemon→engine入口 | 无额外cleanup分支 |
| `src/mem.c` | 已审有归档 | CORE-007、CORE-008、METRIC-003 | allocator accounting、RSS fallback、mallctl |
| `src/mem.h` | 已审无新增 | allocator API | 实现问题映射到`mem.c` |
| `src/message.c` | 已审有归档 | CORE-002、SOCK-008 | message registry/free/worker ownership |
| `src/message.h` | 已审无新增 | message envelope与free callback | 实现映射到`message.c`/producers |
| `src/monitor.c` | 已审有归档 | CORE-004、CORE-005 | monitor thread/start-stop/data visibility |
| `src/monitor.h` | 已审无新增 | monitor API | 实现映射到`monitor.c` |
| `src/platform.h` | 已审有归档 | SOCK-016至SOCK-019、CORE-008 | Unix/Windows type与API分叉 |
| `src/queue.c` | 已审有归档 | CORE-001、CORE-002 | MPSC queue、stub、message visibility |
| `src/queue.h` | 已审无新增 | queue contract | 实现映射到`queue.c` |
| `src/repl.h` | 范围外 | main的可选REPL声明 | 未进入net/protocol/storage依赖闭包 |
| `src/silly.h` | 已审有归档 | CORE、SOCK、METRIC多项ABI | public structs、counter宽度、API类型 |
| `src/silly_conf.h` | 已审有归档 | CORE-004、SOCK-012 | worker/socket/timer默认配置 |
| `src/sockaddr.h` | 已审有归档 | SOCK-011、ADDR-001/002 | binary sockaddr layout与长度 |
| `src/socket.c` | 已审有归档 | SOCK-001至SOCK-019、NET-001 | slot generation、poll、send/recv、close、stats |
| `src/socket.h` | 已审有归档 | SOCK-006/011/019 | fd/sid/size API边界 |
| `src/spinlock.h` | 已审无新增 | socket pool/wlist锁调用点 | memory order与critical section已映射 |
| `src/timer.c` | 已审有归档 | CORE-006、CORE-009、NET-007 | wheel、session、wall/monotonic、shutdown |
| `src/timer.h` | 已审无新增 | timer API与stats | 实现映射到`timer.c` |
| `src/trace.c` | 已审有归档 | CORE-010 | 16-bit node/time/sequence、wrap与唯一性 |
| `src/trace.h` | 已审有归档 | CORE-010 | trace typedef与API宽度 |
| `src/trigger.h` | 已审无新增 | worker/socket wakeup信号 | ownership问题映射到CORE/SOCK |
| `src/unix/event_epoll.h` | 已审有归档 | SOCK-009/010/013 | add/mod/del/event userdata/error |
| `src/unix/event_kevent.h` | 已审有归档 | SOCK-009/010/013 | add/mod/del/event userdata/error |
| `src/unix/unix.c` | 已审有归档 | CORE-008、DNS-018 | procfs、rusage、rlimit、resolver/bootstrap |
| `src/unix/unix.h` | 已审有归档 | CORE-008 | Linux/macOS capability宏分叉 |
| `src/win/applink.c` | 已审无新增 | OpenSSL applink glue | 无net对象生命周期 |
| `src/win/event_iocp.h` | 已审无新增 | IOCP shim contract | Silly当前使用wepoll；平台偏差映射到socket/win层 |
| `src/win/wepoll.c` | 已审无新增 | handle tree、poll group、cancel/delete | 项目侧generation/control问题已归SOCK |
| `src/win/wepoll.h` | 已审无新增 | wepoll public declarations | 同上 |
| `src/win/win.c` | 已审有归档 | SOCK-016至019、DNS-016至018 | Winsock控制通道、path、resolver、handle宽度 |
| `src/win/win.h` | 已审有归档 | CORE-008、SOCK-016/019 | Windows stubs、fd/socket类型与platform API |
| `src/worker.c` | 已审有归档 | CORE-001/002/004/005、SOCK-008 | callback、wakeup drain、thread start/exit |
| `src/worker.h` | 已审无新增 | worker API/message boundary | 实现映射到`worker.c` |

## 3. Native Lua binding 与内建 codec

| 路径 | 状态 | 问题/证据 | 尚需动作或排除理由 |
|---|---|---|---|
| `luaclib-src/adt/bitmask.h` | 已审无新增 | cluster/queue bit operations | 宽度与shift调用点已核对 |
| `luaclib-src/adt/idpool.h` | 已审有归档 | CLUSTER-001/003 session关联 | 分配/回收行为由cluster调用链覆盖 |
| `luaclib-src/adt/lassert.h` | 已审无新增 | native assert wrapper | 无独立资源状态 |
| `luaclib-src/adt/lbuffer.c` | 已审有归档 | NET-002/005/006/008 | buffer node ownership、signed size、read/readall |
| `luaclib-src/adt/lqueue.c` | 已审无新增 | task/channel/cluster queue | push/pop/GC已核对，无独立新增 |
| `luaclib-src/adt/stack.h` | 已审无新增 | HPACK/Huffman builder stack | cap与node计数已核对 |
| `luaclib-src/cbuf.h` | 已审无新增 | native temporary output buffer | resize/finish调用点映射到codec问题 |
| `luaclib-src/crypto/lcipher.c` | 范围外 | caller-selected crypto API | 不参与内建TLS record或net framing |
| `luaclib-src/crypto/lhash.c` | 已审无新增 | WebSocket SHA-1与用户hash API | handshake校验问题由WS-001覆盖 |
| `luaclib-src/crypto/lhmac.c` | 范围外 | JWT/application HMAC | 不在内建net依赖闭包 |
| `luaclib-src/crypto/lpkey.c` | 已审无新增 | MySQL RSA helper调用链 | auth能力/ownership问题已归MYSQL |
| `luaclib-src/crypto/lutils.c` | 已审无新增 | PEM/key utility | MySQL/TLS调用契约已映射 |
| `luaclib-src/crypto/md_cache.h` | 已审无新增 | digest cache lifetime | process-lifetime cache有界 |
| `luaclib-src/crypto/pkey.h` | 已审无新增 | pkey userdata contract | 实现映射到`lpkey.c` |
| `luaclib-src/encoding/lbase64.c` | 已审有归档 | WS-001 | WebSocket key decode严格性 |
| `luaclib-src/encoding/ljson.c` | 范围外 | application/example codec | HTTP/gRPC/cluster内核不依赖JSON framing |
| `luaclib-src/http2_table.h` | 已审有归档 | HPACK-001/002/004 | static/Huffman tables与decoder |
| `luaclib-src/laddr.c` | 已审有归档 | ADDR-001/002、SOCK-011 | sockaddr parse/format/mask/interface |
| `luaclib-src/lcluster.c` | 已审有归档 | CLUSTER-001至019中的native项 | frame/session/cmd/trace/queue/GC |
| `luaclib-src/lcompress.c` | 已审有归档 | COMP-001、HTTPC-001 | gzip limits、flush/end/error cleanup |
| `luaclib-src/ldebugger.c` | 范围外 | debugger transport外的诊断binding | 不参与net协议实现 |
| `luaclib-src/ldns.c` | 已审有归档 | DNS-001至018中的codec项 | DNS name/RR/section/offset/length |
| `luaclib-src/lenv.c` | 已审无新增 | resolver/config示例环境读取 | 无异步状态 |
| `luaclib-src/lerrno.c` | 已审无新增 | errno object/value导出 | 类型/文档偏差归DOC-040/044 |
| `luaclib-src/lhive.c` | 范围外 | hive codec | 不在当前内建协议调用图 |
| `luaclib-src/lhttp.c` | 已审有归档 | HPACK-001/002/004、H2多项 | HPACK/Huffman/frame builder/C-Lua边界 |
| `luaclib-src/llogger.c` | 已审无新增 | net错误/trace日志sink | payload泄露/放大由具体producer问题覆盖 |
| `luaclib-src/lmetrics.c` | 已审有归档 | CORE-008、METRIC-003 | native stats顺序、平台值、integer边界 |
| `luaclib-src/lnet.c` | 已审有归档 | NET-002/003、SOCK-006/011 | pointer ownership、pack/multicast/address |
| `luaclib-src/lperf.c` | 范围外 | profiler binding | 不参与net运行路径 |
| `luaclib-src/lsignal.c` | 范围外 | process signal API | 无协议/socket ownership |
| `luaclib-src/lsilly.c` | 已审无新增 | core metadata/exit/callback binding | shutdown问题映射到engine/worker |
| `luaclib-src/ltest.c` | 范围外 | test-only hooks | 产品构建不依赖其协议行为 |
| `luaclib-src/ltime.c` | 已审有归档 | CORE-006/009、NET-007 | timeout integer、clock契约、session |
| `luaclib-src/ltls.c` | 已审有归档 | TLS-001至018中的native项 | SSL_CTX/SSL/BIO/SNI/ALPN/GC/error |
| `luaclib-src/ltrace.c` | 已审有归档 | CORE-010 | node窄化、trace整数转换、attach/resume |
| `luaclib-src/luabuf.h` | 已审无新增 | Lua buffer growth helpers | codec调用点的size问题已分别归档 |
| `luaclib-src/luafmt.h` | 已审无新增 | native Lua formatting helper | 无跨yield状态 |
| `luaclib-src/luastr.h` | 已审无新增 | string view/check helpers | pointer仅在同步native调用内使用 |
| `luaclib-src/mysql/binary.h` | 已审有归档 | MYSQLC-001至009 | checked reader与异常payload |
| `luaclib-src/mysql/field_type.h` | 已审有归档 | MYSQLC类型映射项 | enum/wire type覆盖 |
| `luaclib-src/mysql/lenenc.h` | 已审有归档 | MYSQLC长度/NULL项 | lenenc整数与边界 |
| `luaclib-src/mysql/lmysql.c` | 已审有归档 | MYSQLC-001至009 | OK/ERR/column/row/parameter codec |
| `luaclib-src/mysql/lua_buffer_ex.h` | 已审有归档 | MYSQLC buffer/异常项 | writer size与allocation |
| `luaclib-src/pb.c` | 已审有归档 | GRPC-025/027至039 | protobuf descriptor/scalar/map/unknown/size |
| `luaclib-src/pb.h` | 已审有归档 | GRPC protobuf边界 | implementation contract随`pb.c`覆盖 |
| `luaclib-src/zproto/LICENSE` | 范围外 | third-party metadata | 无代码 |
| `luaclib-src/zproto/README.md` | 范围外 | optional zproto codec文档 | cluster只接收caller-supplied marshal |
| `luaclib-src/zproto/lzproto.c` | 范围外 | optional application codec binding | 非cluster固定wire codec |
| `luaclib-src/zproto/zproto.c` | 范围外 | optional application codec core | 同上 |
| `luaclib-src/zproto/zproto.h` | 范围外 | optional codec header | 同上 |

## 4. Lua net、storage 与直接运行时依赖

| 路径 | 状态 | 问题/证据 | 尚需动作或排除理由 |
|---|---|---|---|
| `lualib/silly/net.lua` | 已审有归档 | NET-001至004、DOC-046 | callback tables、payload ownership、dispatch/close |
| `lualib/silly/net/cluster.lua` | 已审有归档 | CLUSTER-001至019 | master逐路径与cluster分支对照已收口 |
| `lualib/silly/net/dns.lua` | 已审有归档 | DNS-001至018 | UDP/TCP/cache/singleflight/reconfigure/close |
| `lualib/silly/net/grpc.lua` | 已审无新增 | gRPC顶层装配 | 方法组合问题映射到子模块 |
| `lualib/silly/net/grpc/client/conn.lua` | 已审有归档 | GRPC连接/pool/deadline项 | target、round-robin、close、stream acquire |
| `lualib/silly/net/grpc/client/service.lua` | 已审有归档 | GRPC四类call/status/metadata项 | unary/stream生命周期 |
| `lualib/silly/net/grpc/code.lua` | 已审有归档 | GRPC envelope/compression/status项 | 5-byte framing与codec |
| `lualib/silly/net/grpc/helper.lua` | 已审有归档 | GRPC header/timeout项 | grpc-timeout/content-type/status mapping |
| `lualib/silly/net/grpc/registrar.lua` | 已审有归档 | GRPC dispatch/cardinality/exception项 | service/method registration |
| `lualib/silly/net/grpc/server.lua` | 已审有归档 | GRPC server/shutdown项 | listen、handler、close与stream cleanup |
| `lualib/silly/net/http.lua` | 已审有归档 | HTTP listener/config项 | H1/H2 dispatch与server ownership |
| `lualib/silly/net/http/client.lua` | 已审有归档 | HTTPC-001至009 | pool、DNS/TLS、redirect、gzip、deadline/close |
| `lualib/silly/net/http/dom.lua` | 已审无新增 | protected parse调用链 | parser错误由HTTP client边界收敛 |
| `lualib/silly/net/http/h1.lua` | 已审有归档 | HTTP1-001至023 | 双向framing、state、reuse、limits |
| `lualib/silly/net/http/h2.lua` | 已审有归档 | H2-001至041 | frame×stream state、flow control、HPACK、close |
| `lualib/silly/net/http/helper.lua` | 已审有归档 | HTTP1-008/010、URL项 | target/header/status helpers |
| `lualib/silly/net/http/statusname.lua` | 已审无新增 | status lookup | 无状态与wire parser |
| `lualib/silly/net/http/url.lua` | 已审有归档 | URL-001至003、DOC-047 | parse/format/authority/path/fragment |
| `lualib/silly/net/tcp.lua` | 已审有归档 | NET-005至008、SOCK-012 | connect/listen/read/write/limit/timeout/close |
| `lualib/silly/net/tls.lua` | 已审有归档 | TLS-001至018、NET-005至007 | ctx/handshake/read/write/reload/close |
| `lualib/silly/net/udp.lua` | 已审有归档 | UDP-001、SOCK/NET共享项 | endpoint/connect/send/recv/close |
| `lualib/silly/net/websocket.lua` | 已审有归档 | WS-001至010 | handshake/frame/fragment/control/close/concurrency |
| `lualib/silly/store/etcd.lua` | 已审有归档 | ETCD-001至017 | KV/lease/watch/retry/generation/cancel/close |
| `lualib/silly/store/etcd/v3/proto.lua` | 已审有归档 | DOC-035/036/043、GRPC-039 | generated descriptor与presence/type |
| `lualib/silly/store/mysql.lua` | 已审有归档 | MYSQL-001至020 | auth/packet/result/prepare/pool/transaction |
| `lualib/silly/store/redis.lua` | 已审有归档 | REDIS-001至010 | RESP/FIFO/reconnect/pipeline/transaction/close |
| `lualib/silly/adt/list.lua` | 范围外 | 未被内建net/storage/metrics require | 单独容器，不在当前调用图 |
| `lualib/silly/metrics/collector.lua` | 已审无新增 | collector type alias | runtime仅返回type declaration |
| `lualib/silly/metrics/collector/jemalloc.lua` | 已审有归档 | METRIC-003 | native tuple与gauge字段 |
| `lualib/silly/metrics/collector/process.lua` | 已审有归档 | CORE-008 | CPU/RSS/heap collector与平台能力 |
| `lualib/silly/metrics/collector/silly.lua` | 审阅中 | engine counter wrap/reset候选 | 需完成long-running counter与reset语义反查 |
| `lualib/silly/metrics/counter.lua` | 审阅中 | METRIC-004调用链 | descriptor/value validation仍待收口 |
| `lualib/silly/metrics/gauge.lua` | 审阅中 | METRIC-004调用链 | descriptor/value validation仍待收口 |
| `lualib/silly/metrics/histogram.lua` | 已审有归档 | METRIC-002/004 | bucket storage与descriptor |
| `lualib/silly/metrics/labels.lua` | 已审有归档 | METRIC-001 | cache与wire escaping；name schema仍待收口 |
| `lualib/silly/metrics/prometheus.lua` | 已审有归档 | METRIC-001至004 | registration、family formatting、histogram、collectors |
| `lualib/silly/metrics/registry.lua` | 已审有归档 | METRIC-004 | identity/name registration与collect |
| `lualib/silly/sync/channel.lua` | 已审有归档 | ETCD channel/wakeup问题 | queue/token/close行为按etcd调用链覆盖 |
| `lualib/silly/sync/mutex.lua` | 已审无新增 | DNS/cluster/gRPC/Redis互斥 | FIFO owner/wakeup/error路径已核对 |
| `lualib/silly/sync/singleflight.lua` | 已审有归档 | DNS singleflight项 | leader/waiter/error共享 |
| `lualib/silly/sync/waitgroup.lua` | 已审无新增 | 测试与示例并发helper | 不被产品net路径直接require |
| `lualib/silly/task.lua` | 已审有归档 | CORE/NET/CLUSTER/GRPC生命周期项 | scheduler、trace、wakeup、exit、pool |
| `lualib/silly/time.lua` | 已审有归档 | CORE-006/009、NET-007、DOC-052 | timer ownership、one-shot语义、clock |
| `lualib/silly/trace.lua` | 已审有归档 | CORE-010 | task trace API导出与唯一性契约 |
| `lualib/silly/logger.lua` | 已审无新增 | net/trace日志wrapper | formatter与native sink已核对 |
| `lualib/silly/console.lua` | 已审有归档 | CORE-008、METRIC-003 | network/process/jemalloc观测输出 |

## 5. 下一批台账工作

1. 先收口所有`审阅中`运行时文件；新问题独立进入主报告并提交。
2. 从实际 `lualib/types/silly/**`、`test/**`、`docs/src/**` 与 `docs/src/en/**` 集合逐文件追加，不用目录级描述替代。
3. 对每个章节执行集合差：仓库实际路径减台账反引号路径必须为空，范围外路径也必须有理由。
4. 最后核对每个`已审有归档`ID真实存在、每个`已审无新增`都有调用边界说明，再允许更新完成状态。
