# Silly 1.0 `net` 发布封板审计计划

> 制定日期：2026-08-13（Asia/Shanghai）
> 工作量：至少 24 小时净静态审计，不含等待、构建和外部协调时间
> 审计分支：`codex/silly-net-review`
> 产品基线：`master@d1aef7ffd8439340dfd957a49fccba3fbf133055`
> `cluster` 对照：`origin/cluster@0f2c8773842edb818c1aac74ade3f975d1cbd068`
> 既有结论：master 基线 209 项（P1 88、P2 112、P3 9），另有 4 项 `cluster` 分支独有问题

完成性反证进度（2026-08-13）：不沿用目录级完成声明，正从仓库实际文件清单重建逐文件证据；当前共335项（P1 112、P2 180、P3 43），另有4项cluster分支独有问题。共享native buffer反查新增`NET-008`，低层net文档ownership反查新增`DOC-046`，双语文件差集新增`DOC-047`，HTTP教程安全缓解新增`DOC-048`，HTTP最佳实践无效API、timeout生命周期、高基数metrics和限流生命周期新增`DOC-049`至`052`，metrics wire反查新增`METRIC-001`至`004`；其余零引用依赖继续逐文件复核。发布状态保持阻断。

## 1. 目标和边界

本轮不是重复阅读已有报告，而是为 1.0 发布做逐文件封板：证明每个网络相关源码、native binding、engine 依赖、测试和公开契约都被映射到检查项；对状态机的正常、失败、超时、取消、关闭、重入和资源耗尽分支分别检查，并与既有 issue 去重。

继续遵守用户当前约束：只做静态审阅；不运行服务、协议流量、畸形输入、故障注入、并发 barrier 或已有重现脚本；不修改产品源码。每个新确认问题单独更新 `SILLY_NET_REVIEW.md` 与 `HANDOFF.md` 并单独提交。本轮计划和覆盖记录也保存在工作目录并提交，不推送远端。

“审核完成”必须同时满足：

1. 源码清单中的每个文件都有审计状态、调用者、被调用者、协议/并发检查和测试映射，不能只靠同目录其他文件的结论代替。
2. 每个公开 API 都核对 LuaLS 注解、中英文文档、默认值、单位、错误类型、close 后行为和并发契约。
3. 每个 wire protocol 都核对 parser 和 sender 两个方向、长度/整数边界、未知扩展、错误作用域、连接后续可否复用和资源预算。
4. 每个可能 yield 的边界都核对对象 generation、waiter 唯一性/公平性、timer ownership、late event 和 close/reconnect 交错；不把单 worker 错当成没有并发。
5. 每个 C/Lua 边界都核对 Lua stack、整数符号/截断、pointer/size、异常清理、GC、allocation failure 和跨平台类型。
6. 既有 209 项逐项保留；新疑点只有在证据独立、触发成立且不与旧项重复时才编号。
7. 最终输出 1.0 发布阻断清单：P1 默认阻断；P2 按协议互操作、数据一致性和资源泄漏决定阻断或显式接受风险；所有修复都有建议测试。

## 2. 24 小时执行表

| 净时间 | 范围 | 必查内容 | 阶段产物 |
|---|---|---|---|
| 0–1h | 基线和覆盖矩阵 | master/cluster 差异、全部源码/测试/文档、已有 issue 引用与零引用文件 | 文件级账本、补审清单 |
| 1–4h | engine + socket core | `src/socket.c`、worker/message/timer/queue、platform backend、`lnet.c`；slot/FD generation、跨线程消息、exit/final flush、write ownership | CORE/NET/SOCK 候选与平台差异 |
| 4–6h | TCP/UDP/addr | Lua transport wrapper、`laddr.c`；connect/listen/read/delimiter/readall/write/half-close/backpressure/timeout/close，IPv4/IPv6/Unix 地址 | transport API 和生命周期矩阵 |
| 6–8h | DNS | `dns.lua`、`ldns.c`；name codec、compression pointer、record length、EDNS、TC/TCP fallback、cache/TTL/negative cache、并发 query、resolver close | DNS wire 与 resolver 状态矩阵 |
| 8–10h | TLS | `tls.lua`、`ltls.c`；context/reload、certificate/hostname/SNI、ALPN、BIO wants、buffer、close-notify、timeout、session/renegotiation、OpenSSL error queue | TLS client/server 配置和状态矩阵 |
| 10–13h | HTTP common + H1 | `http.lua/client/dom/helper/statusname/url`、`lhttp.c`、`h1.lua`；URI/field/start-line、CL/TE/chunk/trailer、Expect、upgrade、keepalive/pool、redirect/compress、limits | HTTP/1 请求/响应双向矩阵 |
| 13–16h | HTTP/2 + HPACK | `h2.lua` 与 `lhttp.c` HPACK/builder；每种 frame × stream state、CONTINUATION、SETTINGS、flow control、RST/GOAWAY、quota/waiter、header budgets | H2 frame/state/flow-control 矩阵 |
| 16–17.5h | WebSocket | HTTP upgrade、Origin/subprotocol/extensions、mask/RSV/opcode、fragment/control/UTF-8、close handshake、并发写和消息上限 | RFC 6455 双角色矩阵 |
| 17.5–19h | gRPC | 顶层装配、conn/service/helper/server/registrar/code；四类 RPC、5-byte envelope、compression、metadata/trailer/status、deadline/cancel、handler exception | gRPC call lifecycle 矩阵 |
| 19–21h | Redis/MySQL/etcd | RESP/MySQL/etcd wire、transaction/lease/watch、pool/stream ownership、retry/reconnect、close、TLS/auth、budgets | storage client 并发和协议矩阵 |
| 21–22h | cluster | master 与 cluster 分支 codec/session/send/late response/node reconnect/close，文档和测试差异 | 共享问题与分支独有问题分账 |
| 22–23h | 跨模块组合 | errno/string 契约、absolute deadline、cancel propagation、GC/finalizer、resource budget、DNS→TCP→TLS→H2→gRPC 链、Linux/macOS/Windows | 跨层发布风险清单 |
| 23–24h | 发布收口 | test coverage、中文/英文文档、LuaLS、示例、编号/统计/索引/Git；按修复依赖排序 | 1.0 blocker、修复批次、最终交接 |

## 3. 文件级覆盖账本

状态只允许 `待审`、`审阅中`、`已审无新增`、`已审有归档`。已有问题数量不能自动把文件标为完成。

### 3.1 Engine 和 native 层

- `src/socket.c`：已审有归档；既有 `SOCK-001` 至 `SOCK-014`，本轮新增 `SOCK-015`、`SOCK-017`、`SOCK-019`，平台共用调用链另见 `SOCK-016/018`。
- `src/engine.c`、`src/worker.c`、`src/timer.c`、`src/queue.c`：已审有归档；对应 `CORE-001` 至 `CORE-007` 及 `SOCK-008`，平台process/socket资源观测另见`CORE-008`。
- `src/message.c`、`src/api.c`、`src/monitor.c` 及直接 header：已审无新增；公开转发、message id、shutdown调用顺序和monitor跨线程字段已映射到既有问题。
- `src/array.h`、`src/flipbuf.h`、`src/trigger.h`、`src/spinlock.h`、`src/platform.h`、`src/sockaddr.h`、`src/silly.h`、`src/silly_conf.h`、`src/socket.h`：已审有归档；新增Windows控制通道问题为`SOCK-016/018`，其他结论并入`CORE-007`、`SOCK-011/012/015/017/019`。
- `src/unix/unix.c`、`src/unix/event_epoll.h`、`src/unix/event_kevent.h`：已审有归档；注册/修改失败、裸slot userdata和nonblocking失败已由`SOCK-009/010/013`覆盖，固定resolver路径及读取失败策略另见`DNS-018`、`DOC-008`；macOS误用Linux procfs的资源观测见`CORE-008`。
- `src/win/win.c`：已审有归档；本轮新增`SOCK-016`至`SOCK-019`及`DNS-016/017`，resolver读取失败策略另见`DNS-018`。
- `src/win/event_iocp.h`、`src/win/wepoll.h`、`src/win/wepoll.c`：已审无新增；完整检查handle tree、reflock、poll cancel/delete、事件映射和Silly wrapper，项目侧代际及控制API偏差已归入`SOCK-009/010/016/019`。
- `luaclib-src/lnet.c`：已审有归档；本轮新增`NET-003`，既有裸pointer/address长度问题见`NET-002`、`SOCK-006/011`。
- `luaclib-src/laddr.c`：已审有归档；新增`ADDR-002`，既有binary sockaddr边界另见`ADDR-001`、`SOCK-011`。
- `luaclib-src/ltls.c`：已审有归档；逐项复核context/SSL/BIO/read/write/GC、certificate/SNI、ALPN、session/early-data、error queue与Lua调用链；本轮新增`TLS-009`至`TLS-018`，既有风险由`TLS-001`至`TLS-008`覆盖。
- `luaclib-src/ldns.c`：已审有归档；完成query/name compression、header/question、各RR/RDLENGTH、section/class、EDNS/RCODE、TTL/negative和Lua stack/offset矩阵，新增`DNS-009/010/013/014`，其余偏差由`DNS-001/002/003/008`覆盖。
- `luaclib-src/lhttp.c`：已审有归档；HPACK static/dynamic table、Huffman、varint、Lua stack/整数/size转换及全部frame builder已逐函数核对，保留`HPACK-001/002`，本轮新增`HPACK-004`；Huffman tree预分配经静态节点计数恰为270，排除realloc悬空指针候选。
- `luaclib-src/pb.c`、`pb.h`：已审有归档；完成descriptor label/oneof/map、全部scalar、encode/decode、unknown/packed/merge、递归/stack/size与gRPC finalizer交界，新增`GRPC-025/027-029/032-033/035-038`并补强map截断证据；通用pack/unpack非gRPC入口留到跨模块最终复核。
- `luaclib-src/lcluster.c`：已审有归档；553行parser/encoder逐函数完成frame partial/commit/clear/GC、queue/hash、length/session/cmd/trace整数域、pointer/size与master/raw-string wire差异核对，问题映射到`CLUSTER-001/004-006/009/011/012/015/017`，大帧窄化证据已补强，其他候选去重或排除。
- `luaclib-src/mysql/lmysql.c`、`binary.h`、`field_type.h`、`lenenc.h`、`lua_buffer_ex.h`：已审有归档；582行binding及340行直接header逐函数覆盖OK/ERR/EOF/column/binary row/parameter sender、Lua stack/buffer pointer、整数/长度/异常日志，问题由`MYSQLC-001`至`MYSQLC-009`覆盖；MariaDB progress零返回因未宣告capability对compliant peer不可达，未另编号。

### 3.2 Lua transport 和协议层

- `lualib/silly/net/tcp.lua`、`udp.lua`：已审有归档；新增`NET-005`至`008`、`DOC-007`，既有`UDP-001`、`SOCK-012`等条目已逐路径去重；`NET-007`覆盖TLS/H2/connect在大timeout timer异常前发布operation的跨层事务缺口，`NET-008`覆盖共享native buffer的累计字节溢出。
- `lualib/silly/net/tls.lua`：已审有归档；配置、connect/listen/reload、握手三态、timeout、read/write、buffer limit、close、GC、SNI/ALPN与native所有权均已完成；transport交叉项见`NET-005/006`，TLS独有项为`TLS-001`至`TLS-018`。
- `lualib/silly/net/dns.lua`：已审有归档；完成UDP/TCP fallback、singleflight、timer、CNAME/search、cache/TTL、reconfigure、平台bootstrap与close/wakeup交错矩阵，新增`DNS-011/012/015/018`，Windows边界见`DNS-016/017`。共享TCP旧recv覆盖新连接候选已按worker每消息后清空wakeup queue的顺序排除。
- `lualib/silly/net/cluster.lua`：已审有归档；331行逐路径完成serve/connect/listen/call/send、codec/handler、waiter/timer、trace、reconnect、active/passive close及全局context生命周期核对，问题由`CLUSTER-001`至`019`覆盖；raw-string分支状态与4项独有问题另见专项报告。
- `lualib/silly/net/http.lua`、`http/client.lua`、`http/h1.lua`、`http/url.lua`：已审有归档；本轮新增`HTTPC-006/007`、`HTTP1-018`至`HTTP1-023`、`DOC-012/013`，既有URL、pool、framing、Expect/upgrade/keepalive与limits问题已逐项去重。
- `lualib/silly/net/http/dom.lua`、`http/helper.lua`、`http/statusname.lua`：已审无新增；DOM异常受protected parse边界收敛，target/status helper的协议偏差已并入`HTTP1-008/010`，未另立重复条目。
- `lualib/silly/net/http/h2.lua`：已审有归档；完成DATA/HEADERS/PRIORITY/RST/SETTINGS/PING/GOAWAY/WINDOW_UPDATE/CONTINUATION/PUSH_PROMISE按client/server与idle/open/half-closed/closed矩阵，新增`H2-035`至`H2-041`并补强padding flow-control到`H2-003`。未知RST code由元表稳定格式化、Huffman tree恰好不扩容等候选已排除。
- `lualib/silly/net/websocket.lua`：已审有归档；opening handshake、frame parser/sender、fragment/control/close、并发、H1/H2交界与文档测试矩阵已完成。重复close与`__close`组合归入`WS-007`，WSS空payload挂起归入`TLS-009`，127-length最高位的TCP重分帧/TLS挂起归入`WS-003`；H2非法101/nil conn路径归入`WS-001`，未重复编号。
- `lualib/silly/net/grpc.lua`、`grpc/code.lua`、`grpc/helper.lua`、`grpc/server.lua`、`grpc/registrar.lua`、`grpc/client/conn.lua`、`grpc/client/service.lua`：已审有归档；四类RPC的headers/envelope/status/deadline/cancel/metadata/cardinality、conn round-robin/close、server dispatch/shutdown、timer/异常收尾及所有公开方法已映射到`GRPC-001`至`GRPC-038`，顶层装配与status常量无独立新增。
- `lualib/silly/store/redis.lua`：已审有归档；RESP2 sender/parser、FIFO reader ownership、connect/auth/select/reconnect/close、pipeline、transaction与push mode逐路径核对，问题由`REDIS-001`至`REDIS-010`覆盖；`MONITOR`和RESP3 push归入`REDIS-007/001`，阻塞命令、pipeline写序与断线后不重放已静态排除为独立候选。
- `lualib/silly/store/mysql.lua`：已审有归档；1264行逐路径完成handshake/auth switch/caching-sha2/sha256、packet sequence/fragment、prepare/execute/result phases、pool wait/handoff/expiry/close、transaction与异常cleanup，问题由`MYSQL-001`至`MYSQL-020`覆盖；BLOB真实集成路径已有byte数据测试，未把VARCHAR parameter type候选升级为独立问题。
- `lualib/silly/store/etcd.lua`：已审有归档；624行逐路径完成KV/lease/watch option转换、retry/deadline、stream generation、queue/registry ownership、cancel/close/reconnect与资源预算，问题由`ETCD-001`至`ETCD-017`覆盖；本轮新增caller request别名污染，关闭后unary会由gRPC稳定返回Closed且额外attempt/末轮sleep已归入`ETCD-012`，channel wakeup只排ready queue、不会在registry发布前同步抢占。

### 3.3 测试、类型和文档

- transport：`testtcp.lua`、`testtcp2.lua`、`testudp.lua`、`testaddr.lua`已映射到本轮transport边界；`testdns.lua`与`mock_dns_server.lua`已逐31组case及fake-peer能力映射，缺口归入`DNS-009`至`DNS-018`；`testssl.lua`已逐项映射，positive ALPN、reload、读写/关闭等覆盖与certificate verification、close_notify、握手deadline、TLS版本、invalid config和failure cleanup缺口均已落到TLS条目。`testtimer.lua`及time native/LuaLS/双语reference的net间接依赖已映射到`CORE-006/009`与`NET-007`。
- HTTP/application protocols：`testhttp.lua`与`test/conformance/testhttp.lua`的H1/common部分已逐项映射；gzip metadata缺口归入既有`HTTPC-001`。`testhttp2.lua`全部36组与`testhpack.lua`全部18组已映射，确认缺少独立H2 peer、malformed frame/state、padding、极值table-size和错误作用域覆盖；Test28注释与当前延迟HPACK实现不符但用例顺序仍能防止旧回归，未立重复问题。`testwebsocket.lua`全部7组顶层场景及两组11项data vector已映射，相应缺口均已归档。`testgrpc.lua`全部9组已映射：只覆盖同库正常unary/三类stream、简单application error、已有连接unary timeout、10路并发、1MiB与单target DNS失败；缺少独立peer、malformed/status/header、TLS/ALPN、多target、metadata、shutdown、codec边界及异常后资源归零，均对应`GRPC-001`至`GRPC-038`。
- 双语HTTP文档：除reference与tutorial外，`docs/src/{en/,}guides/http-best-practices.md`各1885行已重新纳入逐文件范围；正文限额和最终middleware的同类绕过并入`DOC-048`，其余timeout、API、限流、TLS与代理示例继续逐段复核，不能再以目录级“文档已收口”代替。
- HTTP监控依赖：`lualib/silly/metrics/{labels,counter,gauge,histogram,prometheus}.lua`已沿官方HTTP示例纳入net依赖闭包；高基数raw path见`DOC-051`，label wire escaping见`METRIC-001`，其余registry/collector与双语metrics reference继续核对。
- storage/cluster：`testredis.lua`全部18组、`fake_redis_server.lua`及Redis双语reference各851行已映射，正常/1024并发/pipeline/error/partial read/disconnect/restart/db restore/close/waitq场景与缺少malformed、budget、null/nested error、transaction、push/TLS/deadline确定性覆盖均已落账。`testmysql.lua`全部41组/1472行已映射：native基本fixture、连接/认证、pool、prepared cache、transaction、large field、temporal/JSON/DECIMAL/BIT/BLOB/ENUM/SET、close等正常路径均对照，伪multi、timeout无效、sha256缺口及malformed/并发/故障路径均落入MYSQL/MYSQLC条目；双语reference各1657行、pool guide各1310行、database tutorial各1231行与error-handling中MySQL章节已核对，文档问题归入`DOC-027`至`DOC-034`，无独立MySQL types文件。etcd已映射`testetcd.lua`全部17组/919行、`fake_etcd_server.lua`692行、`etcdcheck.lua`真实server 15组/764行、KV/Lease/Watch生成descriptor与双语reference 1554/1564行；正常CRUD/range/revision/lease/watch/cancel/close/并发/reconnect用例及fake对filter/compaction/history/fragment/generation的盲区均落入`ETCD-001`至`ETCD-017`、`DOC-001/006/035-037`和`GRPC-039`。cluster已映射master `testcluster.lua`24组/604行、双语reference 1127/1126行及分支新增late-response用例；正常parser/扩容/limit/lazy connect/双向RPC/并发/timeout/close-connect/DNS failure覆盖与全部错误/安全/资源缺口已落入`CLUSTER-001`至`019`、`DOC-038`至`042`及`CLUSTER-B001`至`B004`。
- `lualib/types/silly/` 下DNS/TLS、HTTP2 HPACK/framebuilder、cluster、time/metrics/errno native stub公开面已审；WebSocket无独立type文件，inline LuaLS及双语reference/tutorial已收口。gRPC无独立types文件，7个模块inline LuaLS、`lualib/types/pb/pb.lua`、`lualib/types/pb/parser.lua`及中英文reference各1758行（64代码围栏、46标题）已核对，新增`DOC-026/045`并保留`DOC-004`；cluster高层/低层类型偏差归入`DOC-042`。etcd generated尾注与descriptor presence已核对，新增`DOC-043`并保留`DOC-036`；net/DNS native stub导出与stack ABI核账新增`DOC-044`，低层net双语reference的接收payload所有权错误归入`DOC-046`；time/metrics的跨平台/时钟语义见`CORE-008/009`，Redis/MySQL没有独立types文件。

## 4. 每个文件的固定检查模板

1. 列出公开入口、内部状态字段、所有 yield 点和所有跨线程/native callback。
2. 为状态字段画出创建、发布、使用、关闭、清除和 GC 顺序；检查 late callback 是否携带 generation。
3. 检查每个失败返回和 exception：资源、waiter、timer、queue token、pool quota、协议同步状态是否恰好收尾一次。
4. 检查长度、计数、ID、时间和 offset 的 wire 类型、Lua integer、C integer、`size_t` 之间转换。
5. 检查攻击者可控循环、递归、buffer、table、cache、queue 和日志是否有合理预算。
6. 检查 sender 不会主动生成非法 wire，parser 不会宽容到与 proxy/peer 形成不同边界。
7. 检查关闭前、关闭中、关闭后及重复关闭；同对象并发 read/write/connect/reload/cancel 的契约必须明确。
8. 对照测试：正常路径不能替代错误路径，库的 client/server 互测不能替代独立 peer，sleep 不能替代确定性同步。
9. 对照中英文文档、LuaLS 与实现；option name、单位、默认值、错误返回和方法集合必须一致。
10. 写下结论：旧 issue ID、新 issue ID、接受风险，或“已审无新增”及证据范围。

## 5. 1.0 发布判定

- P1：默认 release blocker。若不修，必须由维护者逐项书面接受风险，说明部署缓解和不影响范围。
- P2：涉及 wire framing、跨请求/事务错配、认证/TLS、无限等待/泄漏、close 后复活、严格 peer 互操作的，按 blocker 处理；纯诊断或极窄兼容性可延期。
- P3：允许进入 1.0 后修复，但文档中会误导安全、事务或数据一致性承诺的除外。
- 修复顺序按依赖：engine/socket → TCP/TLS/DNS → HTTP/HPACK → WebSocket/gRPC → storage/cluster → 文档和发布回归。不能先用高层 workaround 掩盖底层 ownership/framing 缺陷。

完成判定暂缓：只有仓库实际文件宇宙与新建逐文件账本完全对应、零引用依赖复核完毕、所有候选归档或排除、主报告/HANDOFF重新核账且工作区干净后，才恢复“完成”状态。动态验证仍按用户约束进入修复阶段，不属于本次静态判定。
