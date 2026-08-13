# Silly 1.0 `net` 发布封板审计计划

> 制定日期：2026-08-13（Asia/Shanghai）
> 工作量：至少 24 小时净静态审计，不含等待、构建和外部协调时间
> 审计分支：`codex/silly-net-review`
> 产品基线：`master@d1aef7ffd8439340dfd957a49fccba3fbf133055`
> `cluster` 对照：`origin/cluster@0f2c8773842edb818c1aac74ade3f975d1cbd068`
> 既有结论：master 基线 209 项（P1 88、P2 112、P3 9），另有 4 项 `cluster` 分支独有问题

当前滚动进度（2026-08-13）：底层 engine/socket、TCP/UDP/addr、DNS、TLS/OpenSSL、HTTP common/HTTP1、HTTP/2/HPACK与WebSocket阶段已收口；共287项（P1 104、P2 158、P3 25）。H2本轮完成每种frame×role×stream state、flow-control、SETTINGS、HPACK/native builder、pool、36组HTTP2测试、18组HPACK测试及双语文档复核，新增`H2-035`至`H2-041`、`HPACK-004`、`HTTPC-008/009`、`DOC-014`至`DOC-017`；`H2-003/024/028`等既有项补强但不重复计数。WebSocket完成RFC 6455双角色矩阵、H1/H2交界、双语文档及全部7组测试映射，新增`DOC-018`至`DOC-025`并与底层共享问题去重。gRPC审计中新增`GRPC-025`至`GRPC-034`与`DOC-026`。

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
- `src/engine.c`、`src/worker.c`、`src/timer.c`、`src/queue.c`：已审有归档；对应 `CORE-001` 至 `CORE-007` 及 `SOCK-008`，本轮未发现可独立于既有条目的新问题。
- `src/message.c`、`src/api.c`、`src/monitor.c` 及直接 header：已审无新增；公开转发、message id、shutdown调用顺序和monitor跨线程字段已映射到既有问题。
- `src/array.h`、`src/flipbuf.h`、`src/trigger.h`、`src/spinlock.h`、`src/platform.h`、`src/sockaddr.h`、`src/silly.h`、`src/silly_conf.h`、`src/socket.h`：已审有归档；新增Windows控制通道问题为`SOCK-016/018`，其他结论并入`CORE-007`、`SOCK-011/012/015/017/019`。
- `src/unix/unix.c`、`src/unix/event_epoll.h`、`src/unix/event_kevent.h`：已审有归档；注册/修改失败、裸slot userdata和nonblocking失败已由`SOCK-009/010/013`覆盖，固定resolver路径及读取失败策略另见`DNS-018`、`DOC-008`。
- `src/win/win.c`：已审有归档；本轮新增`SOCK-016`至`SOCK-019`及`DNS-016/017`，resolver读取失败策略另见`DNS-018`。
- `src/win/event_iocp.h`、`src/win/wepoll.h`、`src/win/wepoll.c`：已审无新增；完整检查handle tree、reflock、poll cancel/delete、事件映射和Silly wrapper，项目侧代际及控制API偏差已归入`SOCK-009/010/016/019`。
- `luaclib-src/lnet.c`：已审有归档；本轮新增`NET-003`，既有裸pointer/address长度问题见`NET-002`、`SOCK-006/011`。
- `luaclib-src/laddr.c`：已审有归档；新增`ADDR-002`，既有binary sockaddr边界另见`ADDR-001`、`SOCK-011`。
- `luaclib-src/ltls.c`：已审有归档；逐项复核context/SSL/BIO/read/write/GC、certificate/SNI、ALPN、session/early-data、error queue与Lua调用链；本轮新增`TLS-009`至`TLS-018`，既有风险由`TLS-001`至`TLS-008`覆盖。
- `luaclib-src/ldns.c`：已审有归档；完成query/name compression、header/question、各RR/RDLENGTH、section/class、EDNS/RCODE、TTL/negative和Lua stack/offset矩阵，新增`DNS-009/010/013/014`，其余偏差由`DNS-001/002/003/008`覆盖。
- `luaclib-src/lhttp.c`：已审有归档；HPACK static/dynamic table、Huffman、varint、Lua stack/整数/size转换及全部frame builder已逐函数核对，保留`HPACK-001/002`，本轮新增`HPACK-004`；Huffman tree预分配经静态节点计数恰为270，排除realloc悬空指针候选。
- `luaclib-src/lcluster.c`、`mysql/lmysql.c` 及其直接 header：待审。

### 3.2 Lua transport 和协议层

- `lualib/silly/net/tcp.lua`、`udp.lua`：已审有归档；新增`NET-005/006`、`DOC-007`，既有`UDP-001`、`SOCK-012`等条目已逐路径去重。
- `lualib/silly/net/tls.lua`：已审有归档；配置、connect/listen/reload、握手三态、timeout、read/write、buffer limit、close、GC、SNI/ALPN与native所有权均已完成；transport交叉项见`NET-005/006`，TLS独有项为`TLS-001`至`TLS-018`。
- `lualib/silly/net/dns.lua`：已审有归档；完成UDP/TCP fallback、singleflight、timer、CNAME/search、cache/TTL、reconfigure、平台bootstrap与close/wakeup交错矩阵，新增`DNS-011/012/015/018`，Windows边界见`DNS-016/017`。共享TCP旧recv覆盖新连接候选已按worker每消息后清空wakeup queue的顺序排除。
- `lualib/silly/net/cluster.lua`：待审。
- `lualib/silly/net/http.lua`、`http/client.lua`、`http/h1.lua`、`http/url.lua`：已审有归档；本轮新增`HTTPC-006/007`、`HTTP1-018`至`HTTP1-023`、`DOC-012/013`，既有URL、pool、framing、Expect/upgrade/keepalive与limits问题已逐项去重。
- `lualib/silly/net/http/dom.lua`、`http/helper.lua`、`http/statusname.lua`：已审无新增；DOM异常受protected parse边界收敛，target/status helper的协议偏差已并入`HTTP1-008/010`，未另立重复条目。
- `lualib/silly/net/http/h2.lua`：已审有归档；完成DATA/HEADERS/PRIORITY/RST/SETTINGS/PING/GOAWAY/WINDOW_UPDATE/CONTINUATION/PUSH_PROMISE按client/server与idle/open/half-closed/closed矩阵，新增`H2-035`至`H2-041`并补强padding flow-control到`H2-003`。未知RST code由元表稳定格式化、Huffman tree恰好不扩容等候选已排除。
- `lualib/silly/net/websocket.lua`：已审有归档；opening handshake、frame parser/sender、fragment/control/close、并发、H1/H2交界与文档测试矩阵已完成。重复close与`__close`组合归入`WS-007`，WSS空payload挂起归入`TLS-009`，127-length最高位的TCP重分帧/TLS挂起归入`WS-003`；H2非法101/nil conn路径归入`WS-001`，未重复编号。
- `lualib/silly/net/grpc.lua`、`grpc/code.lua`、`grpc/helper.lua`、`grpc/server.lua`、`grpc/registrar.lua`、`grpc/client/conn.lua`、`grpc/client/service.lua`：待审；其中顶层 `grpc.lua` 当前没有直接文件证据引用，优先补审。
- `lualib/silly/store/redis.lua`、`mysql.lua`、`etcd.lua`：待审。

### 3.3 测试、类型和文档

- transport：`testtcp.lua`、`testtcp2.lua`、`testudp.lua`、`testaddr.lua`已映射到本轮transport边界；`testdns.lua`已逐31组case映射，缺口归入`DNS-009`至`DNS-018`；`testssl.lua`已逐项映射，positive ALPN、reload、读写/关闭等覆盖与certificate verification、close_notify、握手deadline、TLS版本、invalid config和failure cleanup缺口均已落到TLS条目。
- HTTP/application protocols：`testhttp.lua`与`test/conformance/testhttp.lua`的H1/common部分已逐项映射；gzip metadata缺口归入既有`HTTPC-001`。`testhttp2.lua`全部36组与`testhpack.lua`全部18组已映射，确认缺少独立H2 peer、malformed frame/state、padding、极值table-size和错误作用域覆盖；Test28注释与当前延迟HPACK实现不符但用例顺序仍能防止旧回归，未立重复问题。`testwebsocket.lua`全部7组顶层场景及两组11项data vector已映射：均为同库正常互通，WSS只读非空data，空Close只走ws；缺少握手拒绝、畸形frame、WSS空控制帧、预算/deadline、关闭幂等和独立peer覆盖，相应实现问题均已归档。`testgrpc.lua`待审。
- storage/cluster：`testredis.lua`、`testmysql.lua`、`testetcd.lua`、fake servers、`testcluster.lua`。
- `lualib/types/silly/` 下DNS/TLS与HTTP2 HPACK/framebuilder公开面已审；双语DNS/TLS及HTTP reference/guide的H1/H2契约已核对，新增`DOC-012`至`DOC-017`并确认既有`DOC-003`仍完整。H2指南遗漏TLS开关和ALPN会实际启动明文H1，已按安全误导列为P2；WebSocket没有独立type文件，inline LuaLS及双语reference/tutorial已逐段核对，新增`DOC-018`至`DOC-025`。gRPC/storage/cluster类型、guide/example继续对应专项及最终一致性核对。

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

最终只有在文件账本全部终态、所有候选已归档或排除、统计一致、工作区干净时，才会把本计划标记为完成。
