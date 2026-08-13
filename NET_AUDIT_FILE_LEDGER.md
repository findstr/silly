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
| `src/socket.c` | 已审有归档 | SOCK-001至SOCK-019、NET-001、METRIC-005 | slot generation、poll、send/recv、close、stats |
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
| `src/worker.c` | 已审有归档 | CORE-001/002/004/005/011、SOCK-008 | callback、wakeup drain、thread start/exit、ID生成 |
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
| `luaclib-src/lsignal.c` | 已审有归档 | DOC-058 | logger控制依赖；注册错误/映射与replacement调用链 |
| `luaclib-src/lsilly.c` | 已审有归档 | CORE-011 | core metadata/exit/callback、genid导出 |
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
| `lualib/protoc.lua` | 已审有归档 | DOC-045、GRPC-038 | gRPC/protobuf codegen、path与proto2 group能力 |
| `lualib/silly.lua` | 已审有归档 | CORE-011、DOC-046/053 | core公开导出、genid、tostring、exit |
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
| `lualib/silly/metrics/collector.lua` | 已审有归档 | DOC-070 | collector instance/factory type contract |
| `lualib/silly/metrics/collector/jemalloc.lua` | 已审有归档 | METRIC-003 | native tuple与gauge字段 |
| `lualib/silly/metrics/collector/process.lua` | 已审有归档 | CORE-008 | CPU/RSS/heap collector与平台能力 |
| `lualib/silly/metrics/collector/silly.lua` | 已审有归档 | METRIC-005 | engine counters、gauge与sent/received语义 |
| `lualib/silly/metrics/counter.lua` | 已审有归档 | METRIC-004/006/008 | descriptor、labels与counter value语义 |
| `lualib/silly/metrics/gauge.lua` | 已审有归档 | METRIC-004/006/008/009 | descriptor、labels与gauge value语义 |
| `lualib/silly/metrics/histogram.lua` | 已审有归档 | METRIC-002/004/007/008/011 | bucket storage、schema、lifetime与descriptor |
| `lualib/silly/metrics/labels.lua` | 已审有归档 | METRIC-001/006/008 | cache、value escaping与label arity/name schema |
| `lualib/silly/metrics/prometheus.lua` | 已审有归档 | METRIC-001至004/007至011 | registration、family formatting、cache/异常收尾与collectors |
| `lualib/silly/metrics/registry.lua` | 已审有归档 | METRIC-004/010 | identity/name registration、mutation与collect |
| `lualib/silly/sync/channel.lua` | 已审有归档 | ETCD channel/wakeup问题 | queue/token/close行为按etcd调用链覆盖 |
| `lualib/silly/sync/mutex.lua` | 已审无新增 | DNS/cluster/gRPC/Redis互斥 | FIFO owner/wakeup/error路径已核对 |
| `lualib/silly/sync/singleflight.lua` | 已审有归档 | DNS singleflight项 | leader/waiter/error共享 |
| `lualib/silly/sync/waitgroup.lua` | 已审无新增 | 测试与示例并发helper | 不被产品net路径直接require |
| `lualib/silly/task.lua` | 已审有归档 | CORE/NET/CLUSTER/GRPC生命周期项 | scheduler、trace、wakeup、exit、pool |
| `lualib/silly/time.lua` | 已审有归档 | CORE-006/009、NET-007、DOC-052 | timer ownership、one-shot语义、clock |
| `lualib/silly/trace.lua` | 已审有归档 | CORE-010 | task trace API导出与唯一性契约 |
| `lualib/silly/logger.lua` | 已审无新增 | net/trace日志wrapper | formatter与native sink已核对 |
| `lualib/silly/console.lua` | 已审有归档 | CORE-008、METRIC-003 | network/process/jemalloc观测输出 |
| `lualib/silly/debugger.lua` | 范围外 | debugger orchestration | 不参与产品net协议路径 |
| `lualib/silly/hive.lua` | 范围外 | optional hive codec wrapper | cluster只接收caller-supplied marshal |
| `lualib/silly/internal/autoload.lua` | 已审无新增 | native module searcher | net/codec native加载与types路径已核对 |
| `lualib/silly/internal/stdin.lua` | 范围外 | REPL/stdin helper | 不参与socket engine协议处理 |
| `lualib/silly/patch.lua` | 已审有归档 | CORE-012 | hot-reload guide依赖；module exports/upvalue traversal |
| `lualib/silly/security/jwt.lua` | 范围外 | application JWT实现 | 非内建net认证；其文档错误用genid已归CORE-011 |
| `lualib/silly/signal.lua` | 已审有归档 | DOC-058 | single-handler replacement与logger SIGUSR1 ownership |
| `lualib/zproto.lua` | 范围外 | optional zproto wrapper | 非cluster固定wire codec |

## 5. LuaLS / native 类型声明

| 路径 | 状态 | 问题/证据 | 尚需动作或排除理由 |
|---|---|---|---|
| `lualib/types/pb/parser.lua` | 已审有归档 | DOC-045 | descriptor parser返回与presence契约 |
| `lualib/types/pb/pb.lua` | 已审有归档 | DOC-045、GRPC protobuf项 | encode/decode/option/iterator/slice/path API |
| `lualib/types/silly/adt/buffer.lua` | 已审有归档 | NET-008、DOC-044 | buffer读写返回与size宽度 |
| `lualib/types/silly/adt/queue.lua` | 已审无新增 | task/channel/cluster native queue | 空pop与所有权由调用方/cluster stub覆盖 |
| `lualib/types/silly/c.lua` | 已审有归档 | CORE-011、DOC-053 | exit/tostring/error/version/genid公开签名与实现 |
| `lualib/types/silly/compress/gzip.lua` | 已审有归档 | HTTPC-001、COMP-001 | output budget、flush/end/error与签名 |
| `lualib/types/silly/crypto/cipher.lua` | 范围外 | caller-selected cipher API | 不参与内建TLS record实现 |
| `lualib/types/silly/crypto/hash.lua` | 已审无新增 | WebSocket/MySQL hash调用 | 方法与native返回已核对 |
| `lualib/types/silly/crypto/hmac.lua` | 范围外 | JWT/application HMAC | 不在内建net调用图 |
| `lualib/types/silly/crypto/pkey.lua` | 已审有归档 | DOC-045、MYSQL auth项 | verify/encrypt/decrypt与返回契约 |
| `lualib/types/silly/crypto/utils.lua` | 已审有归档 | WS-008、DOC-045 | random与bit conversion |
| `lualib/types/silly/debugger/helper.lua` | 范围外 | debugger types | 不参与net协议 |
| `lualib/types/silly/encoding/base64.lua` | 已审有归档 | WS-001 | decode返回与handshake严格性 |
| `lualib/types/silly/encoding/json.lua` | 范围外 | application/example codec | 非内建HTTP/gRPC framing |
| `lualib/types/silly/env.lua` | 已审无新增 | resolver/示例配置读取 | 同步key/value API，无网络状态 |
| `lualib/types/silly/errno.lua` | 已审有归档 | DOC-040/044 | native errno类型与公开比较契约 |
| `lualib/types/silly/hive/c.lua` | 范围外 | hive codec | 不在当前调用图 |
| `lualib/types/silly/http2/framebuilder.lua` | 已审有归档 | DOC-045、H2 sender项 | frame methods、多返回与size |
| `lualib/types/silly/http2/hpack.lua` | 已审有归档 | DOC-045、HPACK项 | encoder/decoder/table API |
| `lualib/types/silly/logger/c.lua` | 已审无新增 | net/trace log sink | level/format/write签名已核对 |
| `lualib/types/silly/metrics/c.lua` | 已审有归档 | CORE-008、METRIC-003/005 | stat tuple顺序、平台能力与net counters |
| `lualib/types/silly/net/addr.lua` | 已审有归档 | ADDR-001/002、DOC-044 | parse/format/interface契约 |
| `lualib/types/silly/net/c.lua` | 已审有归档 | DOC-044、NET/SOCK项 | native导出、pointer、multicast、ntop |
| `lualib/types/silly/net/cluster/c.lua` | 已审有归档 | DOC-042、CLUSTER native项 | request/pop返回、cmd/trace/queue |
| `lualib/types/silly/net/dns/c.lua` | 已审有归档 | DOC-044、DNS codec项 | answer nil、query/parse返回 |
| `lualib/types/silly/perf.lua` | 范围外 | profiler types | 不参与net运行路径 |
| `lualib/types/silly/signal/c.lua` | 已审无新增 | signal binding types | native返回/映射契约与DOC-058对账 |
| `lualib/types/silly/time/c.lua` | 已审有归档 | CORE-006/009、NET-007 | integer timeout与clock返回 |
| `lualib/types/silly/tls/ctx.lua` | 已审有归档 | TLS-001至018中的context项 | cert/key/verify/SNI/ALPN/session API |
| `lualib/types/silly/tls/tls.lua` | 已审有归档 | TLS-001至018中的connection项 | handshake/read/write/error/GC |
| `lualib/types/silly/trace/c.lua` | 已审有归档 | CORE-010 | node/trace整数与spawn/attach/resume |

## 6. 测试、fake peer 与 conformance 资产

| 路径 | 状态 | 问题/证据 | 尚需动作或排除理由 |
|---|---|---|---|
| `test/adt/testbuffer.lua` | 已审有归档 | NET-006/008 | 正常读写覆盖，缺少overflow/limit自锁边界 |
| `test/adt/testlist.lua` | 范围外 | 独立Lua list测试 | 产品net调用图不依赖该list |
| `test/adt/testqueue.lua` | 已审无新增 | task/channel native queue | push/pop/empty/GC正常路径 |
| `test/conformance.lua` | 已审有归档 | HTTP/H2 conformance缺口 | Go peer启动、case dispatch与结果汇总 |
| `test/conformance/go/control/conn.go` | 已审有归档 | HTTP conformance transport | 控制连接framing与case生命周期 |
| `test/conformance/go/control/dispatch.go` | 已审有归档 | HTTP conformance dispatch | case/error/result通道 |
| `test/conformance/go/go.mod` | 已审无新增 | Go独立peer依赖版本 | 无产品实现逻辑 |
| `test/conformance/go/httpclient/client.go` | 已审有归档 | HTTP client独立peer覆盖 | request/response互操作范围已映射 |
| `test/conformance/go/httpserver/handlers.go` | 已审有归档 | HTTP server独立peer覆盖 | handler vectors与缺口已映射 |
| `test/conformance/go/httpserver/server.go` | 已审有归档 | HTTP server独立peer覆盖 | listener/TLS/H2配置与case lifecycle |
| `test/conformance/go/main.go` | 已审无新增 | conformance peer入口 | control/client/server装配 |
| `test/conformance/testhttp.lua` | 已审有归档 | HTTP1/H2互操作项 | Silly侧vectors、framing与错误缺口 |
| `test/etcdcheck.lua` | 已审有归档 | ETCD-001至017、GRPC项 | 真实etcd 15组正常路径与盲区 |
| `test/fake_etcd_server.lua` | 已审有归档 | ETCD watch/lease/generation项 | fake状态机能力与偏差已映射 |
| `test/fake_redis_server.lua` | 已审有归档 | REDIS-001至010 | partial/disconnect/restart fake peer能力 |
| `test/mock_dns_server.lua` | 已审有归档 | DNS-009至018 | UDP/TCP/record fake peer能力与盲区 |
| `test/prepare.lua` | 已审无新增 | suite环境/fixture准备 | 不改变协议语义 |
| `test/print.lua` | 范围外 | 手工输出helper | 不在自动net验证链 |
| `test/test.conf` | 已审无新增 | suite配置 | net测试选择与默认项已核对 |
| `test/test.lua` | 已审无新增 | suite调度入口 | module顺序/exit处理已核对 |
| `test/test.sh` | 已审无新增 | 跨配置test runner | 本轮按约束不执行 |
| `test/testaddr.lua` | 已审有归档 | ADDR-001/002、DOC-044 | IPv4/IPv6/Unix/interface/mask覆盖 |
| `test/testaux.lua` | 已审有归档 | CLUSTER-014等helper问题 | assert/async case/exit辅助语义 |
| `test/testbase64.lua` | 已审有归档 | WS-001 | permissive decode正常vectors与严格性缺口 |
| `test/testchannel.lua` | 已审有归档 | ETCD channel lifecycle项 | send/recv/close与waiter覆盖 |
| `test/testcipher.lua` | 范围外 | application cipher API | 不验证内建TLS record层 |
| `test/testcluster.lua` | 已审有归档 | CLUSTER-001至019 | 24组parser/RPC/concurrency/timeout/close |
| `test/testcompress.lua` | 已审有归档 | COMP-001、HTTPC-001 | gzip正常/错误与output budget缺口 |
| `test/testdns.lua` | 已审有归档 | DNS-001至018 | 31组codec/resolver/cache/fallback |
| `test/testdom.lua` | 已审无新增 | HTTP DOM helper | protected parse与normal input |
| `test/testearlyexit.lua` | 已审有归档 | CORE/SOCK shutdown项 | 启动早退与cleanup顺序 |
| `test/testec.lua` | 范围外 | application EC crypto | 不在内建net协议 |
| `test/testendless.lua` | 已审有归档 | CORE monitor项 | endless hook/monitor行为 |
| `test/testerrno.lua` | 已审有归档 | DOC-040/044 | errno identity/string/type契约 |
| `test/testetcd.lua` | 已审有归档 | ETCD-001至017、DOC-035/036/043 | fake etcd 17组与资源/错误盲区 |
| `test/testexit.lua` | 已审有归档 | CORE/SOCK exit项 | normal exit与pending state |
| `test/testexit2.lua` | 已审有归档 | CORE/SOCK exit项 | alternate shutdown ordering |
| `test/testgrpc.lua` | 已审有归档 | GRPC-001至039 | 九组同库四类RPC/timeout/concurrency/large message |
| `test/testhash.lua` | 已审无新增 | WebSocket/MySQL hash dependency | digest vectors与API |
| `test/testhive.lua` | 范围外 | hive codec | cluster不固定使用hive |
| `test/testhmac.lua` | 范围外 | application HMAC | 不在内建net调用图 |
| `test/testhpack.lua` | 已审有归档 | HPACK-001/002/004、H2项 | 18组static/dynamic/Huffman/table vectors |
| `test/testhttp.lua` | 已审有归档 | HTTPC/HTTP1/URL项 | H1/common全部case与错误盲区 |
| `test/testhttp2.lua` | 已审有归档 | H2-001至041 | 36组同库frame/state/flow-control覆盖 |
| `test/testjson.lua` | 范围外 | application JSON codec | 非HTTP wire parser |
| `test/testjwt.lua` | 范围外 | application JWT | 非内建net认证协议 |
| `test/testlog.lua` | 已审有归档 | CORE-010、MYSQLC-008等日志路径 | trace/log formatting与payload producer边界 |
| `test/testmutex.lua` | 已审无新增 | DNS/cluster/gRPC/Redis互斥 | FIFO/owner/wakeup正常与错误路径 |
| `test/testmysql.lua` | 已审有归档 | MYSQL/MYSQLC全部项 | 41组auth/pool/prepare/result/transaction/data type |
| `test/testpatch.lua` | 已审有归档 | CORE-012 | hot-reload依赖；仅覆盖纯function export table |
| `test/testprometheus.lua` | 已审有归档 | METRIC-001至011、CORE-008 | counter/gauge/histogram/registry正常路径与wire/异常/重入/GC盲区 |
| `test/testredis.lua` | 已审有归档 | REDIS-001至010 | 18组RESP/pipeline/concurrency/reconnect/close |
| `test/testrsa.lua` | 已审有归档 | MYSQL auth/pkey依赖 | RSA encrypt/decrypt/sign/verify正常路径 |
| `test/testsignal.lua` | 已审有归档 | DOC-058 | 验证replacement返回旧handler；未覆盖logger保留信号组合 |
| `test/testsingleflight.lua` | 已审有归档 | DNS singleflight项 | leader/waiter/error共享正常路径 |
| `test/testssl.lua` | 已审有归档 | TLS-001至018 | cert/ALPN/reload/read-write/close与failure缺口 |
| `test/testtask.lua` | 已审有归档 | CORE-010及跨模块task项 | scheduler/wakeup/trace/fork/wait/status |
| `test/testtcp.lua` | 已审有归档 | NET/SOCK transport项 | connect/listen/read/write/close正常路径 |
| `test/testtcp2.lua` | 已审有归档 | NET/SOCK并发/FD项 | partial/EAGAIN/multicast/close/metrics checks |
| `test/testtimer.lua` | 已审有归档 | CORE-006/009、NET-007 | schedule/cancel/sleep/clock与边界盲区 |
| `test/testudp.lua` | 已审有归档 | UDP-001、SOCK-001/011/012 | bind/connect/send/recv/address/multicast |
| `test/testwaitgroup.lua` | 范围外 | test/application同步helper | 产品net路径不require waitgroup |
| `test/testwakeup.lua` | 已审有归档 | CORE task/worker wakeup项 | ready queue与message后drain顺序 |
| `test/testwebsocket.lua` | 已审有归档 | WS-001至010 | handshake与11组frame data vectors |
| `test/testxor.lua` | 范围外 | application XOR helper | 不在net协议实现 |

## 7. 双语文档、教程与导航

静态图片、favicon、logo和SCSS只影响展示，不表达API/协议契约，按规则排除；其余133个Markdown页面与6个VuePress TypeScript配置逐路径列入。中文缺失的URL页面不存在可列路径，差异由`DOC-047`和两份sidebar映射。

| 路径 | 状态 | 问题/证据 | 尚需动作或排除理由 |
|---|---|---|---|
| `docs/src/.vuepress/config.ts` | 已审无新增 | locale/theme入口 | 中英文路由装配已核对 |
| `docs/src/.vuepress/navbar.en.ts` | 已审无新增 | 英文导航 | net入口存在 |
| `docs/src/.vuepress/navbar.ts` | 已审无新增 | 中文导航 | net入口存在 |
| `docs/src/.vuepress/sidebar.en.ts` | 已审有归档 | DOC-047 | 英文URL reference已挂载 |
| `docs/src/.vuepress/sidebar.ts` | 已审有归档 | DOC-047 | 中文URL reference及导航缺失 |
| `docs/src/.vuepress/theme.ts` | 已审无新增 | 双语theme/navigation assembly | 无API契约 |
| `docs/src/README.md` | 范围外 | 中文站点首页 | 不描述net API或协议 |
| `docs/src/benchmark.md` | 范围外 | benchmark展示 | 非正确性/契约文档 |
| `docs/src/concepts/README.md` | 范围外 | 概念索引 | 无net契约 |
| `docs/src/en/README.md` | 范围外 | 英文站点首页 | 不描述net API或协议 |
| `docs/src/en/benchmark.md` | 范围外 | benchmark展示 | 非正确性/契约文档 |
| `docs/src/en/concepts/README.md` | 范围外 | 英文概念索引 | 无net契约 |
| `docs/src/en/guides/README.md` | 已审无新增 | guide索引 | 页面集合与链接 |
| `docs/src/en/guides/error-handling.md` | 已审有归档 | DOC-001/002及storage错误项 | errno、HTTP、DB错误示例 |
| `docs/src/en/guides/hot-reload.md` | 审阅中 | CORE-012、reload/close/config契约 | 继续核timer与rollback生命周期示例 |
| `docs/src/en/guides/http-best-practices.md` | 已审有归档 | DOC-017/048至052/054至056、METRIC-001/002 | 1885行逐段收口：TLS/body/timeout/rate/proxy/status/metrics |
| `docs/src/en/guides/logging-monitoring.md` | 已审有归档 | CORE-010/011、DOC-051/054/057至062/064、METRIC-002至006 | logger/trace/HTTP/metrics/PromQL/alert逐例收口 |
| `docs/src/en/guides/mysql-connection-pool.md` | 已审有归档 | DOC-027/028/030至033 | pool/transaction/retry/monitoring示例 |
| `docs/src/en/guides/tls-configuration.md` | 已审有归档 | DOC-003/005/009及TLS项 | version/cipher/verify/reload示例 |
| `docs/src/en/reference/README.md` | 已审无新增 | 英文reference索引 | net/store/core链接集合 |
| `docs/src/en/reference/adt/buffer.md` | 已审有归档 | NET-006/008 | size/limit/read ownership契约 |
| `docs/src/en/reference/adt/list.md` | 范围外 | 独立list API | 产品net调用图不依赖 |
| `docs/src/en/reference/adt/queue.md` | 已审无新增 | task/channel queue契约 | native queue返回已核对 |
| `docs/src/en/reference/console.md` | 已审有归档 | CORE-008、METRIC-003 | network/process/jemalloc字段 |
| `docs/src/en/reference/crypto/cipher.md` | 范围外 | application cipher | 非内建TLS record API |
| `docs/src/en/reference/crypto/hash.md` | 已审无新增 | WS/MySQL hash dependency | 所用SHA方法与返回契约 |
| `docs/src/en/reference/crypto/hmac.md` | 范围外 | application HMAC | 不在内建net调用图 |
| `docs/src/en/reference/crypto/pkey.md` | 已审有归档 | DOC-045、MYSQL auth项 | key load/encrypt/verify返回 |
| `docs/src/en/reference/debugger.md` | 范围外 | debugger API | 不参与net协议 |
| `docs/src/en/reference/encoding/base64.md` | 已审有归档 | WS-001 | decoder严格性与handshake调用 |
| `docs/src/en/reference/encoding/json.md` | 范围外 | application JSON codec | 非HTTP wire parser |
| `docs/src/en/reference/env.md` | 已审无新增 | resolver/config examples | 同步环境API |
| `docs/src/en/reference/errno.md` | 已审有归档 | DOC-040/044 | errno identity/string/比较契约 |
| `docs/src/en/reference/hive.md` | 范围外 | optional hive codec | 非cluster固定codec |
| `docs/src/en/reference/logger.md` | 已审有归档 | DOC-057/058/063 | level/formatter/eager args/SIGUSR1/reopen与native逐项对账 |
| `docs/src/en/reference/metrics/collector.md` | 已审有归档 | CORE-008、METRIC-003/005/009至011、DOC-070 | custom collector contract、异常/重入/lifetime与内置字段 |
| `docs/src/en/reference/metrics/counter.md` | 已审有归档 | METRIC-004/006/008、DOC-051 | descriptor、cardinality与output examples |
| `docs/src/en/reference/metrics/gauge.md` | 已审有归档 | METRIC-004/006/008/009、DOC-065/066/069 | descriptor/value/label/HTTP examples与截断EOF |
| `docs/src/en/reference/metrics/histogram.md` | 已审有归档 | METRIC-002/004/006至008/011、DOC-051/067 | cumulative bucket契约、vectors/lifetime与完整示例 |
| `docs/src/en/reference/metrics/labels.md` | 已审有归档 | METRIC-001/006/008 | cache/cardinality/arity/name/value wire |
| `docs/src/en/reference/metrics/prometheus.md` | 已审有归档 | METRIC-001至011、CORE-008、DOC-051/054/068/070 | constructor/gather/HTTP/custom collector examples |
| `docs/src/en/reference/metrics/registry.md` | 已审有归档 | METRIC-004/009至011、DOC-068/070 | duplicate family、mutation/lifetime、export与custom collector |
| `docs/src/en/reference/net.md` | 已审有归档 | DOC-046 | raw payload ownership与callback yield |
| `docs/src/en/reference/net/README.md` | 已审有归档 | DOC-047 | net子模块索引含URL |
| `docs/src/en/reference/net/addr.md` | 已审有归档 | ADDR-001/002、DOC-044 | endpoint/address/interface契约 |
| `docs/src/en/reference/net/cluster.md` | 已审有归档 | DOC-038至042、CLUSTER项 | 1127行API/wire/timeout/trace |
| `docs/src/en/reference/net/dns.md` | 已审有归档 | DNS/DOC对应项 | resolver/cache/record/platform契约 |
| `docs/src/en/reference/net/grpc.md` | 已审有归档 | DOC-004/026/045、GRPC项 | 1758行四类RPC/protobuf/status |
| `docs/src/en/reference/net/http.md` | 已审有归档 | HTTP/DOC对应项 | client/server/H1/H2/url公开契约 |
| `docs/src/en/reference/net/tcp.md` | 已审有归档 | NET/SOCK/DOC对应项 | connect/read/write/close/timeout |
| `docs/src/en/reference/net/tls.md` | 已审有归档 | TLS/DOC对应项 | ctx/listener/verify/SNI/ALPN/reload |
| `docs/src/en/reference/net/udp.md` | 已审有归档 | UDP/SOCK/DOC对应项 | bind/connect/send/recv/multicast |
| `docs/src/en/reference/net/url.md` | 已审有归档 | URL-001至003、DOC-047 | 英文唯一URL API页面 |
| `docs/src/en/reference/net/websocket.md` | 已审有归档 | WS/DOC对应项 | handshake/frame/close/concurrency |
| `docs/src/en/reference/patch.md` | 范围外 | Lua patch API | 不在net调用图 |
| `docs/src/en/reference/perf.md` | 范围外 | profiler API | 不参与net运行路径 |
| `docs/src/en/reference/security/jwt.md` | 已审有归档 | CORE-011 | genid作为unique user/JTI的安全示例 |
| `docs/src/en/reference/signal.md` | 已审有归档 | DOC-058 | logger保留SIGUSR1与single-handler替换契约 |
| `docs/src/en/reference/silly.md` | 已审有归档 | CORE-011、DOC-053 | genid/tostring/core导出 |
| `docs/src/en/reference/store/README.md` | 已审无新增 | storage索引 | etcd/mysql/redis页面链接 |
| `docs/src/en/reference/store/etcd.md` | 已审有归档 | ETCD、DOC-035至037/043 | 1554行KV/lease/watch契约 |
| `docs/src/en/reference/store/mysql.md` | 已审有归档 | MYSQL/MYSQLC、DOC-029/033/034 | 1657行auth/query/pool/transaction |
| `docs/src/en/reference/store/redis.md` | 已审有归档 | REDIS对应项 | 851行RESP/commands/pipeline/close |
| `docs/src/en/reference/sync/channel.md` | 已审有归档 | ETCD channel项 | send/recv/close/waiter契约 |
| `docs/src/en/reference/sync/mutex.md` | 已审无新增 | DNS/cluster/gRPC/Redis lock | owner/FIFO/yield语义 |
| `docs/src/en/reference/sync/singleflight.md` | 已审有归档 | DNS singleflight项 | leader/waiter/error共享 |
| `docs/src/en/reference/sync/waitgroup.md` | 范围外 | application/test sync helper | 产品net不require |
| `docs/src/en/reference/task.md` | 已审有归档 | CORE/NET并发项 | fork/wait/wakeup/trace/exit |
| `docs/src/en/reference/time.md` | 已审有归档 | CORE-006/009、NET-007 | wall/monotonic/timer/cancel |
| `docs/src/en/reference/trace.md` | 已审有归档 | CORE-010 | ID layout/unique/attach/propagate |
| `docs/src/en/tutorials/README.md` | 已审无新增 | tutorial索引 | 网络教程页面集合 |
| `docs/src/en/tutorials/database-app.md` | 已审有归档 | DOC-030/032等MySQL项 | transaction/error/retry示例 |
| `docs/src/en/tutorials/echo-server.md` | 审阅中 | TCP/UDP ownership与failure examples | 需最终核nil/error/close分支 |
| `docs/src/en/tutorials/getting-started.md` | 审阅中 | first network app | 需最终核connect/listen失败与API名称 |
| `docs/src/en/tutorials/http-server.md` | 已审有归档 | DOC-048及HTTP项 | body limit、routing、response示例 |
| `docs/src/en/tutorials/websocket-chat.md` | 已审有归档 | DOC-021至025 | schema/XSS/heartbeat/cleanup/socket字段 |

| `docs/src/guides/README.md` | 已审无新增 | 中文guide索引 | 页面集合与链接 |
| `docs/src/guides/error-handling.md` | 已审有归档 | DOC-001/002及storage错误项 | errno、HTTP、DB错误示例 |
| `docs/src/guides/hot-reload.md` | 审阅中 | CORE-012、reload/close/config契约 | 继续核timer与rollback生命周期示例 |
| `docs/src/guides/http-best-practices.md` | 已审有归档 | DOC-017/048至052/054至056、METRIC-001/002 | 1885行逐段收口：TLS/body/timeout/rate/proxy/status/metrics |
| `docs/src/guides/logging-monitoring.md` | 已审有归档 | CORE-010/011、DOC-051/054/057至062/064、METRIC-002至006 | logger/trace/HTTP/metrics/PromQL/alert逐例收口 |
| `docs/src/guides/mysql-connection-pool.md` | 已审有归档 | DOC-027/028/030至033 | pool/transaction/retry/monitoring示例 |
| `docs/src/guides/tls-configuration.md` | 已审有归档 | DOC-003/005/009及TLS项 | version/cipher/verify/reload示例 |
| `docs/src/reference/README.md` | 已审无新增 | 中文reference索引 | net/store/core链接集合 |
| `docs/src/reference/adt/buffer.md` | 已审有归档 | NET-006/008 | size/limit/read ownership契约 |
| `docs/src/reference/adt/list.md` | 范围外 | 独立list API | 产品net调用图不依赖 |
| `docs/src/reference/adt/queue.md` | 已审无新增 | task/channel queue契约 | native queue返回已核对 |
| `docs/src/reference/console.md` | 已审有归档 | CORE-008、METRIC-003 | network/process/jemalloc字段 |
| `docs/src/reference/crypto/cipher.md` | 范围外 | application cipher | 非内建TLS record API |
| `docs/src/reference/crypto/hash.md` | 已审无新增 | WS/MySQL hash dependency | 所用SHA方法与返回契约 |
| `docs/src/reference/crypto/hmac.md` | 范围外 | application HMAC | 不在内建net调用图 |
| `docs/src/reference/crypto/pkey.md` | 已审有归档 | DOC-045、MYSQL auth项 | key load/encrypt/verify返回 |
| `docs/src/reference/debugger.md` | 范围外 | debugger API | 不参与net协议 |
| `docs/src/reference/encoding/base64.md` | 已审有归档 | WS-001 | decoder严格性与handshake调用 |
| `docs/src/reference/encoding/json.md` | 范围外 | application JSON codec | 非HTTP wire parser |
| `docs/src/reference/env.md` | 已审无新增 | resolver/config examples | 同步环境API |
| `docs/src/reference/errno.md` | 已审有归档 | DOC-040/044 | errno identity/string/比较契约 |
| `docs/src/reference/hive.md` | 范围外 | optional hive codec | 非cluster固定codec |
| `docs/src/reference/logger.md` | 已审有归档 | DOC-057/058/063 | level/formatter/eager args/SIGUSR1/reopen与native逐项对账 |
| `docs/src/reference/metrics/collector.md` | 已审有归档 | CORE-008、METRIC-003/005/009至011、DOC-070 | custom collector contract、异常/重入/lifetime与内置字段 |
| `docs/src/reference/metrics/counter.md` | 已审有归档 | METRIC-004/006/008、DOC-051 | descriptor、cardinality与output examples |
| `docs/src/reference/metrics/gauge.md` | 已审有归档 | METRIC-004/006/008/009、DOC-065/069 | descriptor/value/label/HTTP examples |
| `docs/src/reference/metrics/histogram.md` | 已审有归档 | METRIC-002/004/006至008/011、DOC-051/067 | cumulative bucket契约、vectors/lifetime与完整示例 |
| `docs/src/reference/metrics/labels.md` | 已审有归档 | METRIC-001/006/008 | cache/cardinality/arity/name/value wire |
| `docs/src/reference/metrics/prometheus.md` | 已审有归档 | METRIC-001至011、CORE-008、DOC-051/054/068/070 | constructor/gather/HTTP/custom collector examples |
| `docs/src/reference/metrics/registry.md` | 已审有归档 | METRIC-004/009至011、DOC-068/070 | duplicate family、mutation/lifetime、export与custom collector |
| `docs/src/reference/net.md` | 已审有归档 | DOC-046 | raw payload ownership与callback yield |
| `docs/src/reference/net/README.md` | 已审有归档 | DOC-047 | 中文net索引缺URL |
| `docs/src/reference/net/addr.md` | 已审有归档 | ADDR-001/002、DOC-044 | endpoint/address/interface契约 |
| `docs/src/reference/net/cluster.md` | 已审有归档 | DOC-038至042、CLUSTER项 | 1126行API/wire/timeout/trace |
| `docs/src/reference/net/dns.md` | 已审有归档 | DNS/DOC对应项 | resolver/cache/record/platform契约 |
| `docs/src/reference/net/grpc.md` | 已审有归档 | DOC-004/026/045、GRPC项 | 1758行四类RPC/protobuf/status |
| `docs/src/reference/net/http.md` | 已审有归档 | HTTP/DOC对应项 | client/server/H1/H2公开契约 |
| `docs/src/reference/net/tcp.md` | 已审有归档 | NET/SOCK/DOC对应项 | connect/read/write/close/timeout |
| `docs/src/reference/net/tls.md` | 已审有归档 | TLS/DOC对应项 | ctx/listener/verify/SNI/ALPN/reload |
| `docs/src/reference/net/udp.md` | 已审有归档 | UDP/SOCK/DOC对应项 | bind/connect/send/recv/multicast |
| `docs/src/reference/net/websocket.md` | 已审有归档 | WS/DOC对应项 | handshake/frame/close/concurrency |
| `docs/src/reference/patch.md` | 范围外 | Lua patch API | 不在net调用图 |
| `docs/src/reference/perf.md` | 范围外 | profiler API | 不参与net运行路径 |
| `docs/src/reference/security/jwt.md` | 已审有归档 | CORE-011 | genid作为unique user/JTI的安全示例 |
| `docs/src/reference/signal.md` | 已审有归档 | DOC-058 | logger保留SIGUSR1与single-handler替换契约 |
| `docs/src/reference/silly.md` | 已审有归档 | CORE-011、DOC-053 | genid/tostring/core导出 |
| `docs/src/reference/store/README.md` | 已审无新增 | storage索引 | etcd/mysql/redis页面链接 |
| `docs/src/reference/store/etcd.md` | 已审有归档 | ETCD、DOC-035至037/043 | 1564行KV/lease/watch契约 |
| `docs/src/reference/store/mysql.md` | 已审有归档 | MYSQL/MYSQLC、DOC-029/033/034 | 1657行auth/query/pool/transaction |
| `docs/src/reference/store/redis.md` | 已审有归档 | REDIS对应项 | 851行RESP/commands/pipeline/close |
| `docs/src/reference/sync/channel.md` | 已审有归档 | ETCD channel项 | send/recv/close/waiter契约 |
| `docs/src/reference/sync/mutex.md` | 已审无新增 | DNS/cluster/gRPC/Redis lock | owner/FIFO/yield语义 |
| `docs/src/reference/sync/singleflight.md` | 已审有归档 | DNS singleflight项 | leader/waiter/error共享 |
| `docs/src/reference/sync/waitgroup.md` | 范围外 | application/test sync helper | 产品net不require |
| `docs/src/reference/task.md` | 已审有归档 | CORE/NET并发项 | fork/wait/wakeup/trace/exit |
| `docs/src/reference/time.md` | 已审有归档 | CORE-006/009、NET-007 | wall/monotonic/timer/cancel |
| `docs/src/reference/trace.md` | 已审有归档 | CORE-010 | ID layout/unique/attach/propagate |
| `docs/src/tutorials/README.md` | 已审无新增 | tutorial索引 | 网络教程页面集合 |
| `docs/src/tutorials/database-app.md` | 已审有归档 | DOC-030/032等MySQL项 | transaction/error/retry示例 |
| `docs/src/tutorials/echo-server.md` | 审阅中 | TCP/UDP ownership与failure examples | 需最终核nil/error/close分支 |
| `docs/src/tutorials/getting-started.md` | 审阅中 | first network app | 需最终核connect/listen失败与API名称 |
| `docs/src/tutorials/http-server.md` | 已审有归档 | DOC-048及HTTP项 | body limit、routing、response示例 |
| `docs/src/tutorials/websocket-chat.md` | 已审有归档 | DOC-021至025 | schema/XSS/heartbeat/cleanup/socket字段 |

## 8. 下一批台账工作

1. 收口文档章节标为`审阅中`的双语页面；新问题独立进入主报告并提交。
2. 文档Markdown与导航第一版列全后执行实际集合差，不用目录级描述替代逐路径证据。
3. 对每个章节执行集合差：仓库实际路径减台账反引号路径必须为空，范围外路径也必须有理由。
4. 最后核对每个`已审有归档`ID真实存在、每个`已审无新增`都有调用边界说明，再允许更新完成状态。
