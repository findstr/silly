# Silly `net` 全量审计记录

> 状态：进行中
> 审计日期：2026-08-06
> 源码目录：`/home/findstrx/Documents/Codex/2026-08-06-remote/silly`
> 上游：`https://github.com/findstr/silly.git`
> 审计基线：`d1aef7ffd8439340dfd957a49fccba3fbf133055`（2026-07-19）

## 1. 记录规则

每条问题包含：严重度、状态、位置、触发条件、影响、证据、根因、建议解法和回归测试。

- `P0`：可被远程触发的任意代码执行、认证绕过、关键数据破坏，或普遍性服务不可用。
- `P1`：高概率崩溃/挂死、跨请求数据破坏、严重协议或安全缺陷。
- `P2`：特定条件下的错误结果、资源泄漏、明显延迟/可用性问题、标准未定义行为。
- `P3`：诊断、兼容性、文档、低影响边界问题。
- `已确认`：代码路径成立，且有动态证据、确定性推导或协议依据。
- `待复现`：静态审阅发现，仍需故障注入或互操作验证。
- `误报/接受风险`：验证后不构成缺陷，保留原因。

本报告只记录审计结论和建议，当前不修改 Silly 源码。若开始修复，每条问题会新增修复提交、回归用例和验证结果。

## 2. 长计划与完成标准

1. 固化上游提交、仓库状态、构建参数、模块清单和依赖图。
2. 建立 ASan/UBSan/coverage 基线；为并发核心补建 TSAN 版本。
3. 审阅核心 engine/worker/message/queue/timer/socket：线程模型、唤醒、关闭、内存所有权、FD 与 slot 生命周期。
4. 审阅 `net.lua` 和 C/Lua 边界：消息注册、lightuserdata 所有权、回调重入、错误对象和退出行为。
5. 审阅 TCP：listen/connect/accept、读写、半关闭、背压、超时、并发 close、slot 重用和错误传播。
6. 审阅 UDP：bind/connect、报文边界、截断、异步错误、排队发送、关闭和计数。
7. 审阅 TLS：上下文、证书验证、hostname/SNI、ALPN、握手状态机、close-notify、超时和内存 BIO。
8. 审阅 addr/DNS/cluster：解析、IPv4/IPv6、缓存/TTL、并发请求、故障恢复和资源释放。
9. 审阅 HTTP 公共层：`lhttp.c`、URL、header、helper、DOM、buffer 和 C/Lua 所有权。
10. 审阅 HTTP/1：request/response framing、Content-Length、Transfer-Encoding、chunked、Expect、keepalive、upgrade、超时和 request smuggling。
11. 审阅 HTTP/2/HPACK：preface、帧校验、流状态、流控、SETTINGS、RST/GOAWAY、header 限制、并发和资源上限。
12. 审阅 HTTP client/server 聚合层：连接复用、DNS/TLS、重定向、压缩、取消、错误语义；补 Go 互操作/畸形输入矩阵。
13. 审阅 WebSocket：升级握手、mask、fragment、控制帧、UTF-8、close、最大长度、WSS 和并发写。
14. 审阅 gRPC：路由、四种 RPC、5-byte framing、压缩、deadline/cancel、metadata/trailer/status、连接复用和流清理。
15. 审阅 Redis：RESP codec、pipeline、nil/error、嵌套数组、AUTH、重连、并发、超时和关闭。
16. 审阅 MySQL C codec：包长、分片、sequence、lenenc、row、prepared statement 和恶意输入边界。
17. 审阅 MySQL Lua driver：认证/TLS、连接池公平性、超时泄漏、事务、statement cache、重连；补 MySQL 8 与 MariaDB 版本矩阵。
18. 审阅 etcd 及其 HTTP 依赖；做跨模块取消、超时和错误一致性检查。
19. 增加故障注入、连接风暴、慢读写、大帧、资源上限、TSAN/ASan/UBSan 和跨平台静态检查。
20. 核对 LuaLS API 注解、`silly.errno`/`string?` 契约、文档与示例，输出按优先级排序的修复路线。

完成标准：每个范围都至少包含静态调用链、正常/失败状态机、所有权表、现有测试缺口、针对性动态验证；最终问题按 P0→P3 排序，不能把未验证疑点写成已确认缺陷。

### 2.1 HTTP / WebSocket / gRPC 规范符合性矩阵

规范检查与功能测试分开记账。功能用例通过不能替代 MUST/MUST NOT 逐条核对；每条偏离都要标明发送端/接收端、客户端/服务端、HTTP 版本、触发字节序列和连接后续状态。

权威基线：

- HTTP 通用语义：[RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html)。
- HTTP/1.1 消息语法、framing、连接管理与走私风险：[RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html)。
- HTTP/2 帧、流状态、流控和错误处理：[RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html)。
- HPACK：[RFC 7541](https://www.rfc-editor.org/rfc/rfc7541.html)。
- URI 解析与规范化：[RFC 3986](https://www.rfc-editor.org/rfc/rfc3986.html)。
- WebSocket：[RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html)；HTTP/2 Extended CONNECT 仅在实现支持时检查 [RFC 8441](https://www.rfc-editor.org/rfc/rfc8441.html)。
- gRPC 没有单一 IETF RFC；以官方 [gRPC over HTTP/2 protocol](https://grpc.github.io/grpc/core/md_doc__p_r_o_t_o_c_o_l-_h_t_t_p2.html) 为应用协议基线，同时强制满足 RFC 9110/9113/7541 的底层要求。

HTTP/1 审计清单（状态：进行中；消息体长度优先级已开始逐条核对）：

- start-line/field 的 octet parsing、CRLF、bare CR/LF、前导空行、非法 whitespace、obs-fold。
- method 大小写、四种 request-target、空 path、Host 缺失/重复/非法、absolute-form 权威信息。
- field-name token、大小写、重复字段保序与合并规则、Set-Cookie 特例、header/line/URI 上限。
- body-length precedence：HEAD、1xx/204/304、CONNECT、Transfer-Encoding、Content-Length、close-delimited。
- 重复 Content-Length 是否全部合法且一致；TE+CL、非 final chunked、非法 transfer-coding 是否拒绝并关闭，避免 request smuggling。
- chunk size/extension/trailer 语法、溢出、禁止 trailer 字段、不完整消息、过早 EOF。
- keep-alive、Connection token、hop-by-hop 字段、pipelining、重试安全性、半关闭、TLS close。
- Expect: 100-continue、interim responses、Upgrade、WebSocket 切换后的剩余 buffer 所有权。
- 发送端也必须生成规范报文；不能只检查 parser 的宽容度。

HTTP/2 + HPACK 审计清单（状态：待逐条核对）：

- client connection preface、首个 SETTINGS、ACK payload、设置值范围与重复设置。
- 9-byte frame header、length/stream-id/reserved bit、MAX_FRAME_SIZE、未知 frame、固定长度 frame。
- stream-id 单调与奇偶、idle/open/half-closed/closed 状态转换、frame 对状态的合法性、错误作用域。
- HEADERS/PUSH_PROMISE/CONTINUATION 的连续性、END_HEADERS/END_STREAM、padding/priority 长度校验。
- pseudo-header 必须在普通字段前、唯一性和必需集合；小写 field name；禁止 connection-specific 字段；`te` 仅允许 `trailers`。
- DATA/content-length 一致性；stream/connection flow-control、31-bit window、WINDOW_UPDATE 0/overflow、公平性与阻塞解除。
- RST_STREAM、GOAWAY last-stream-id、重试边界、PING、并发流限制和已关闭流的晚到帧。
- HPACK integer/Huffman 解码溢出、EOS/填充校验、索引 0/越界、动态表更新位置与上限、COMPRESSION_ERROR。
- 限制解压后 header list、动态表、并发流、待处理 body，防止内存/CPU 放大。

WebSocket 审计清单（状态：待逐条核对）：

- HTTP/1.1 GET upgrade、Upgrade/Connection token 列表及大小写、version 13、key 必须解码为 16 bytes、Accept 计算。
- Origin、subprotocol 必须来自客户端候选、extension 协商；未协商 RSV 位必须拒绝。
- 客户端帧必须使用不可预测的 32-bit mask；服务端必须拒绝未 mask 客户帧；客户端必须拒绝被 mask 的服务端帧。
- opcode/RSV、最短长度编码、64-bit 长度最高位、实现大小上限和整数/内存溢出。
- fragmentation 顺序、continuation 规则、允许控制帧穿插；控制帧必须 FIN 且 payload ≤125。
- text message 与 close reason 的完整 UTF-8 验证；close code 合法范围、payload 不能只有 1 byte。
- ping/pong payload、close handshake、收到协议错误后的 close code、TCP 关闭 deadline。
- 若不实现 RFC 8441 或 permessage-deflate，要明确为“不支持且不协商”，而不是错误宣称符合。

gRPC 审计清单（状态：待逐条核对）：

- HTTP/2 POST、`:scheme/:path/:authority`、`content-type`、`te: trailers`、`grpc-timeout` 语法与 header 顺序。
- 5-byte message envelope：compressed flag 只能 0/1、4-byte big-endian length、分片 DATA 重组、多个 message、上限。
- grpc-encoding/grpc-accept-encoding 协商；压缩位与 identity/未声明 encoding 的错误处理。
- ASCII/Binary metadata、`-bin` base64、重复值、保序、合法 key、大小限制和保留 `grpc-` namespace。
- initial metadata、正常 trailers、Trailers-Only；`grpc-status` 必需、`grpc-message` percent encoding、缺失/非法状态映射。
- HTTP status 与 gRPC status 的分工；非 gRPC HTTP 响应映射。
- deadline 传播、到期取消、RST_STREAM、client/server cancellation、handler 与 stream 资源清理。
- unary、client-stream、server-stream、bidi-stream 的半关闭、零/多消息约束、并发读写和 backpressure。
- GOAWAY/RST/连接丢失时哪些调用可重试；不能无条件重放非幂等 RPC。

规范结论输出格式：`SPEC-ID | MUST/SHOULD | 实现位置 | client/server | 符合/偏离/不适用 | 证据 | 互操作测试 | 问题编号`。

当前规范结论：

| SPEC-ID | 等级 | 实现位置 | 角色 | 结论 | 证据 | 现有测试 | 问题编号 |
|---|---|---|---|---|---|---|---|
| RFC9112-6.1-TECL-CLOSE | MUST | `lualib/silly/net/http/h1.lua:129-168,818-890` | server | 偏离 | `read_header` 在 TE+CL 共存时删除 CL 并继续；请求处理后仅在解析/handler 错误或 `Connection: close` 时断开，没有记录 TE+CL 并强制关闭 | Test 68 只验证按 chunked 返回 200，未验证响应后关闭 | HTTP1-001 |
| RFC9112-6.3-CL-LIST | MUST | `lualib/silly/net/http/h1.lua:129-149,512-553,818-848` | client/server | 偏离 | 重复字段被保存为 Lua table，单字段逗号列表保留为字符串；两条路径最终都直接交给 `tonumber`，无法接受全部值合法且相同的列表 | Test 72 只覆盖不同值必须拒绝，未覆盖相同值或 `5, 5` | HTTP1-002 |
| RFC9112-6.1/6.3/7-TE-LIST | MUST | `lualib/silly/net/http/h1.lua:129-168,512-553,818-848` | client/server | 偏离 | framing 只在字段值精确等于小写单值 `chunked` 时生效；未解析大小写不敏感的 coding 列表，也未判断最后一个 coding | 现有测试只覆盖精确小写单值 `chunked` | HTTP1-003 |
| RFC9112-7.1/7.1.1-CHUNK-EXT | MUST | `lualib/silly/net/http/h1.lua:174-204` | client/server | 偏离 | parser 只匹配行首十六进制数字，完全忽略该数字到换行之间的剩余字节；缺少分号、非法 token/quoted-string 或任意尾随垃圾均绕过 chunk-size/chunk-ext ABNF | Test 73 只覆盖两个合法扩展；Test 74/75 只覆盖合法 chunk-size | HTTP1-004 |

## 3. 基线结果

### 3.1 仓库与构建

- 已从官方 `origin/master` 拉取；拉取结果为 `Already up to date`。
- 工作副本在独立可写目录，Silly 仓库 `git status` 干净。
- 测试构建：`TEST=ON MALLOC=glibc SNAPPY=OFF`。
- 编译启用 AddressSanitizer、UndefinedBehaviorSanitizer、`float-cast-overflow` 和 coverage。
- 另建隔离 TSAN 工作副本，未污染主审计仓库。

### 3.2 已通过的基线测试

| 范围 | 结果 | 备注 |
|---|---:|---|
| TCP (`testtcp2`) | 通过 | 30 组；含大块、半关闭、超时、FD、partial write、EAGAIN、closewait |
| HTTP/1 (`testhttp`) | 通过 | 所有现有用例通过 |
| HTTP/2 (`testhttp2`) | 通过 | 36 组通过 |
| WebSocket (`testwebsocket`) | 通过 | 7 组；含 WSS、压力和 DNS 失败 |
| gRPC (`testgrpc`) | 通过 | 9 组；含四种 RPC、deadline、并发、1 MiB 消息 |
| Redis (`testredis`) | 通过 | 临时 Redis 6.0.16，18 组通过 |
| MySQL (`testmysql`) | 通过 | 临时 MariaDB 10.3，41 组通过 |

以上运行均未报告 ASan/UBSan 错误，框架最终 `netstat=0`、`leak memory size=0`。这些结果证明正常路径稳定，不等于畸形输入、罕见竞争和协议互操作已覆盖。

待补矩阵：MySQL 8、MariaDB 10.6、Go HTTP conformance、协议 fuzz/fault injection、Windows/macOS。

## 4. 已确认问题

### CORE-001 — P2 — worker 条件变量协议存在真实数据竞争与丢唤醒窗口

- 状态：已确认；TSAN 实证。
- 位置：`src/engine.c:45-46`、`:60-61`、`:73-80`。
- 触发：worker 将 `workerstatus=0` 并确认 backlog 为空后、真正进入 `pthread_cond_wait` 前，socket/timer 线程投递消息并 signal；或者并发线程读取/写入非原子的 `workerstatus`。
- 影响：C 语言内存模型下属于未定义行为；signal 可在 wait 前丢失，新消息的处理会至少推迟到后续 timer tick。当前 timer 每 10 ms 再次 signal，通常会掩盖永久挂起，但不能修复数据竞争，也会引入尾延迟和脆弱的跨平台行为。
- 证据：TSAN 在完整 `testtcp2` 中报告 `thread_worker` 写 `engine.c:76` 与 timer 线程读 `engine.c:45` 竞争。
- 根因：条件谓词没有由同一 mutex 保护；signal 方不持有 mutex；`workerstatus` 也不是原子变量。
- 建议解法：使用标准 predicate protocol。生产者在入队后锁 `R.mutex`、更新受保护谓词并 signal；worker 在同一锁内用 `while (predicate false && running)` 等待。若不希望生产者拿 mutex，则改用经过证明的原子 event-count/futex/semaphore 协议，不能只把 `workerstatus` 改成 atomic。
- 回归测试：TSAN 零告警；在关闭周期 timer wakeup 的测试构建中，用 socket/worker 精确 barrier 命中 “backlog check → wait” 窗口，断言消息无丢失且无额外 tick 延迟。

### CORE-002 — P2 — 消息队列 `head`/`size` 在锁外读取

- 状态：已确认；TSAN 实证。
- 位置：`src/queue.c:65-67`、`:75`、`:84`、`:91`。
- 触发：socket/timer 线程 `queue_push` 与 worker 的 `queue_pop`/`queue_size` 并发。
- 影响：`head` 和 `size` 的并发普通读写是 C 未定义行为；worker 可错误判断队列为空，造成消息处理延迟，并与 CORE-001 的唤醒窗口叠加。
- 证据：TSAN 在 `testtcp2` 中分别报告 `queue_size:91` 与 `queue_push:67`、`queue_pop:75` 与 `queue_push:65` 的竞争。
- 根因：所谓 double-check 的第一次检查在 spinlock 外；`queue_size` 完全不加锁/不使用 atomic。
- 建议解法：最直接的修复是让 `queue_pop` 从第一次检查开始就持锁，并让 `queue_size` 持锁；若性能数据证明需要无锁 fast path，则把相关字段改为正确的原子 MPSC 设计，并明确 acquire/release 关系，不能混用普通字段与锁。
- 回归测试：queue 的多生产者压力测试 + TSAN；用 barrier 交错 push/pop/size，并验证消息唯一、完整、有序且 backlog 最终为 0。

### CORE-003 — P2 — `running` 的 `volatile` 不能提供线程同步

- 状态：已确认；TSAN 实证。
- 位置：`src/engine.c:23`、`:74`、`:94`、`:128`、`:168`。
- 触发：worker 调用 `engine_shutdown` 写 `R.running=0`，main monitor 与 worker loop 并发读取。
- 影响：属于 C 未定义行为；理论上 monitor/worker 可延迟或无法观察退出，造成退出挂起。`volatile` 只约束编译器访问，不建立线程间 happens-before。
- 证据：TSAN 报告 `engine_shutdown:168` 写与 `thread_monitor:94` 读竞争。
- 根因：把 `volatile` 当作同步原语。
- 建议解法：将 shutdown 状态纳入 mutex predicate，或使用 `_Atomic int/bool` 并定义 acquire/release；退出状态若跨线程读写也应由同一锁或原子规则保护。
- 回归测试：重复快速启动/退出与并发 exit，TSAN 零告警；对 worker、timer、socket 创建/停止各阶段做故障注入。

### CORE-004 — P1 — `pthread_create` 失败判断永远漏掉标准错误码

- 状态：已确认；POSIX 返回契约与确定性代码推导。
- 位置：`src/engine.c:103-111`。
- 触发：线程创建因 `EAGAIN`、资源上限或无效属性失败。
- 影响：`pthread_create` 返回正错误码，但代码仅检查 `err < 0`，随后继续使用未成功创建的 thread id；可能 join 无效线程、永远运行 monitor、遗漏清理或崩溃。
- 根因：错误地按 syscall 的 `-1/errno` 风格解释 pthread API。
- 建议解法：检查 `err != 0`，日志用返回的 `err`；让 `thread_create` 返回错误，由 `engine_run` 按已创建线程数量逆序停止/join，释放 socket、worker、mutex/cond，避免在库式核心中直接 `exit(-1)`。
- 回归测试：链接包装 `pthread_create`，分别让第 1/2/3 次创建返回 `EAGAIN`，断言快速失败、无无效 join、无线程/FD/内存泄漏。

### CORE-005 — P3 — `worker.maxmsg` 诊断阈值发生数据竞争

- 状态：已确认；TSAN 实证。
- 位置：`src/worker.c:53`、`:90-99`、`:193`。
- 触发：timer/socket 线程在 `worker_push` 读取并更新 `maxmsg`，worker dispatch 同时重置它。
- 影响：C 未定义行为；主要表现为过载告警重复、遗漏或阈值异常，不直接破坏消息队列。
- 证据：TSAN 报告 timer 的 `worker_push:94` 与 worker 的 `worker_dispatch:193` 竞争。
- 建议解法：把阈值改为 atomic 并用 CAS 更新，或只让 worker 根据原子 backlog/max-observed 指标生成告警。
- 回归测试：多生产者推送压力下 TSAN 零告警，验证告警阈值单调且 dispatch 后正确复位。

### SOCK-001 — P2 — 排队 UDP 发送失败后 `sendsize` 永久虚高

- 状态：已确认；确定性路径推导，动态故障注入待补。
- 位置：`src/socket.c:1211-1238`，尤其 `:1218-1228`。
- 触发：UDP datagram 因 EAGAIN 进入 `wlist`，稍后重试得到永久错误（`sendudp == -1`）。
- 影响：节点和 payload 已释放，但 `wlbytes` 只在 `sz > 0` 时递减；失败时永不减，公开 `sendsize` 永久虚高，可能让上层错误地持续施加背压或判断连接仍有待发数据。
- 根因：把 syscall 返回值当作应扣减长度；失败分支仍应删除整个队列节点。
- 建议解法：只要节点从队列移除，就按 `w->size` 递减；同时明确并记录失败策略（丢包、回调或关闭），不要静默丢弃永久错误。
- 回归测试：为 UDP `sendto` 增加测试注入：第一次 EAGAIN、第二次 `ECONNREFUSED/EHOSTUNREACH`；断言 payload 只释放一次、`sendsize==0`、无 underflow，并验证错误语义。

### SOCK-002 — P3 — UDP connect 失败日志的格式参数类型不匹配

- 状态：已确认；确定性 varargs 类型检查。
- 位置：`src/socket.c:1504`、`:1540`。
- 触发：`socket_udp_connect` 在 socket/bind/connect/pool 分配阶段失败并进入 `end`。
- 影响：格式串用 `%d` 打印 `const char *port`，属于 varargs 未定义行为；日志端口为垃圾值，在部分 ABI/构建下可能造成更严重异常，妨碍故障定位。
- 建议解法：改为 `"[socket] udpconnect %s:%s, errno:%d\\n"`，或先统一格式化 endpoint；启用 `-Wformat-nonliteral`/让格式串保持 literal 以便编译器检查。
- 回归测试：用非法 bind 地址或资源注入命中失败路径，捕获日志并断言 endpoint/errno 正确；在 CI 增加 format warnings。

### SOCK-003 — P2 — 进程退出会泄漏仍在 socket `wlist` 中的发送 payload

- 状态：已确认；确定性复现 + Silly 内存计数 + LeakSanitizer 实证。
- 位置：`src/socket.c:1740-1754`、`:1803`、`:1977-1996`。
- 触发：发送 op 已转为一个或多个 `wlist` 节点，随后处理 `OP_EXIT`；退出阶段的一次 `flush_dirty` 未能完整发送所有节点（EAGAIN、partial write，或节点数超过一次 `writev` 的 64 个上限）。
- 影响：`socket_exit` 关闭 fd 并释放整个 manager，却没有遍历活跃 slot 调用 `wlist_free`，因此每个未完成节点拥有的发送 payload 永久泄漏。服务热重启/嵌入式反复启动时可积累；LSan 构建会以失败退出。
- 证据：`review-repros/socket_exit_pending_wlist.lua` 将 `sendv_cap` 固定为 1 字节，排入 8 个 4096-byte 节点后立即退出。Silly 报告 `leak memory size:32768`；LeakSanitizer 报告 8 个直接泄漏，共 32768 bytes，进程退出码 1。
- 根因：`OP_EXIT` 在 `op_process` 中直接 return，跳过该轮 `flush_dirty`；`socket_exit` 只尝试一次 flush，随后只 close fd，不释放 slot 的 owned `wlist` payload。flush 本身也不等同于资源清理。
- 建议解法：先定义退出语义（graceful drain 带 deadline，或立即 abort）。无论哪种语义，停止接收新 op 后都必须：遍历尚未消费的 op buffer 并释放 send payload；遍历所有活跃 slot 调用 `wlist_free`；再关闭 fd、销毁 flipbuf/pool/manager。graceful 模式超时后也要进入相同的 abort cleanup。
- 回归测试：保留当前确定性复现；分别覆盖 partial first node、超过 64 nodes、EAGAIN、UDP queued payload、`OP_EXIT` 前后两个 flipbuf slot，断言 payload 恰好释放一次、`leak memory size=0`、ASan/LSan 通过。

### SOCK-004 — P2 — TCP connect 在进入 multiplexer 前失败会泄漏 OS fd

- 状态：已确认；确定性复现，FD 计数逐次精确增长。
- 位置：`src/socket.c:755-772`、`:1456-1477`；同类风险还包括 `exec_accept:841-844` 和 `op_udp_connect:1552-1556` 的 `sp_add` 失败分支。
- 触发：非阻塞 `connect` 立即返回 `ENETUNREACH/EACCES` 等非 `EINPROGRESS` 错误，此时 socket 尚未执行 `add_to_sp`；代码调用 `free_socket`。
- 影响：`remove_from_sp` 在 `STATE_POLLING` 未设置时直接 return，因而从不 `close(s->fd)`；`pool_free` 随后把 fd 重置为 -1，永久丢失 OS fd。重复失败可耗尽 `RLIMIT_NOFILE`，使整个服务无法建立/接受连接。
- 证据：`review-repros/tcp_immediate_connect_fd_leak.lua` 连续 8 次连接 `255.255.255.255:9`，均立即得到 errno 101；`metrics.openfds()` 从 8 增到 16，delta 精确为 8。进程内存计数仍为 0，证明这是 OS fd 而非 heap 泄漏。
- 根因：`remove_from_sp` 把“未注册 multiplexer”错误地等同于“无需关闭 fd”；资源注销和 fd close 被绑在同一条件分支。
- 建议解法：`remove_from_sp` 仅条件执行 `sp_del`，但只要 `s->fd` 有效就必须无条件 close 并设为 invalid。统一所有 `free_socket` 调用点，不要让调用者猜测是否需要预先 close；避免现有 listen 分支修复后发生 double-close。
- 回归测试：保留当前 8 次立即失败复现并断言 delta=0；注入 `sp_add` 对 accept/TCP connect/UDP connect 分别失败，断言 fd、slot、wlist、netstat 全部回滚且没有 double-close。

### SOCK-005 — P2 — `socket_stat` 与 close 并发时数据竞争，可读取失效 fd 并触发进程断言

- 状态：已确认；TSAN 两条目标竞争，且同一复现触发 `ntop` 的 address-family 断言。
- 位置：`src/socket.c:26-69`、`:461`、`:520-528`、`:755-771`、`:2019-2064`。
- 触发：worker 对 listener 的旧 sid 高频调用 `metrics.socketstat`，同时 socket thread 执行 close/free；fd 关闭后可很快被新 socket 复用。
- 影响：`socket_stat` 不能返回受同一 generation 保护的一致快照。它可能把旧 sid/type 与已关闭或已复用 fd 的地址混合；name syscall 失败后仍解析未初始化的 `sockaddr`，本次最终在 `src/socket.c:552` 的 `family == AF_INET6` 断言终止进程。普通 `fd/type` 的并发读写本身已是 C11 未定义行为。
- 证据：`review-repros/socket_stat_close_race.lua` 的 ASan/UBSan 轮次完成 200 次 close、1600 次 stat，未命中 sanitizer；隔离 TSAN 构建随后分别报告 `socket_stat:2028` 读 fd 与 `remove_from_sp:763` 写 fd、`socket_stat:2029` 读 type 与 `socket_default:461` 写 type 的数据竞争，并以断言退出（status 134）。这说明普通轮次未崩溃只是调度结果，不构成并发安全证据。
- 2026-08-06 本轮最小复核：ASan/UBSan 完成 2000 次 close、16000 次 stat，正常退出且无 sanitizer 告警；同一复现的隔离 TSAN 轮次再次命中上述两条目标竞争，并在 `ntop:552` 因 address family 断言退出（status 134）。结论不变：close/reuse 期间无法保证返回同一 generation 的一致、安全快照。
- 根因：文件自己的并发契约只允许 worker lock-free 读取原子 sid；`socket_stat` 却在第一次 sid 校验后读取非原子 `fd/type`，第二次 sid 校验既发生得太晚，也不能阻止随后 close/reuse。`getsockname/getpeername` 的返回值同时被忽略。
- 建议解法：优先让 socket thread 通过 command/message 生成单一 generation 的 snapshot；若必须由 worker 直接读取，则需要覆盖 slot 生命周期和全部字段的真实锁/seqlock 协议。只有 name syscall 成功后才能调用 `ntop`，失败时返回显式无效/错误状态，不能解析旧栈内容。
- 回归测试：加入确定性 barrier 覆盖 sid check→close/free→fd reuse 窗口，断言旧 sid 只能得到完整旧快照或显式 invalid，绝不能得到混合字段；对两个 name syscall 分别注入 `EBADF/ENOTCONN`，断言不崩溃、不返回未初始化地址，并要求目标 TSAN 堆栈清零。

### HTTP1-001 — P2 — 接受 TE+CL 请求后未按 RFC 9112 强制关闭连接

- 状态：已确认；RFC 规范与确定性控制流推导。本阶段按用户要求只做静态 review，不新增复现代码。
- 规范：RFC 9112 §6.1 允许服务器拒绝同时包含 `Transfer-Encoding` 和 `Content-Length` 的请求，或仅按 `Transfer-Encoding` 处理；无论采用哪一种，响应后都必须关闭连接。
- 位置：`lualib/silly/net/http/h1.lua:129-168`、`:818-890`；现有覆盖为 `test/testhttp.lua:2008-2029`。
- 触发：HTTP/1.1 请求同时携带 `Transfer-Encoding: chunked` 与 `Content-Length`，且没有 `Connection: close`。
- 影响：实现删除 `Content-Length` 并按 chunked 读取，但在发送响应后继续进入持久连接循环。连接链中若有其他 HTTP 实现采用不同 framing 决策，后续字节边界可能不一致；即使没有中间节点，也直接违反 RFC 的连接关闭要求。
- 证据：`read_header` 只执行 `header["content-length"] = nil`，没有给 stream/connection 设置必须关闭标志；`httpd` 循环仅在解析错误、handler 错误、stream 错误或请求显式 `Connection: close` 时退出。Test 68 明确期望请求被接受并返回 200，但客户端立即自行关闭，未覆盖服务端必须关闭的语义。
- 建议解法：解析到 TE+CL 时优先返回 400 并关闭；若选择兼容模式按 TE 处理，则在连接状态上设置不可复用标志，并在该响应完整发送后无条件关闭。客户端收到 TE+CL 响应时也应采用一致的不可复用策略。
- 后续回归条件：修复阶段再补持久连接断言；本轮不新增报文复现代码。

### HTTP1-002 — P2 — 拒绝 RFC 9112 允许的相同 Content-Length 列表

- 状态：已确认；RFC 规范与确定性控制流推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9112 §6.3 要求无 `Transfer-Encoding` 时，非法 `Content-Length` 必须作为不可恢复 framing 错误；但若字段值能解析为逗号列表、每个值均合法且全部相同，则必须按该单一长度处理。
- 位置：`lualib/silly/net/http/h1.lua:129-149`、`:512-553`、`:818-848`；现有部分覆盖为 `test/testhttp.lua:2084-2094`。
- 触发：两个相同的字段行（例如两次相同长度），或一个包含多个相同十进制值的逗号列表字段。
- 影响：server 会返回 400，client 会把响应判为 `Invalid content-length`；合法但由代理规范化或合并过的 HTTP/1.1 消息无法互操作。不同值被拒绝是正确行为，不能因此拒绝全部重复形式。
- 证据：`read_header` 把重复字段保存为 table，而单字段列表仍为原字符串；server 和 client 随后均直接调用 `tonumber`，前者对 table 恒失败，后者对含逗号字符串失败。代码没有逐项 trim、纯十进制校验及“全部相同”判断。
- 建议解法：建立共享的 `Content-Length` 规范化函数，接受 string 或 string[]，按逗号拆分并去除 OWS；要求每项为非空十进制、数值无溢出且规范化后全部相同，返回单一整数，否则返回 framing error。client/server 必须共用同一实现。
- 后续回归条件：修复阶段分别覆盖两个相同字段行、`5, 5`、不同值、空项、符号、非数字和超范围十进制；本轮不新增测试代码。

### HTTP1-003 — P1 — Transfer-Encoding 未按列表与 final coding 决定 framing

- 状态：已确认；RFC 规范与确定性控制流推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9112 §6.1 将 `Transfer-Encoding` 定义为 transfer-coding 列表，§7 规定 coding 名大小写不敏感；§6.3 以最后一个 coding 是否为 chunked 决定消息边界。请求中的 chunked 若不是 final coding，服务端必须返回 400 并关闭；不理解的 request transfer-coding 应返回 501。
- 位置：`lualib/silly/net/http/h1.lua:129-168`、`:512-553`、`:818-848`。
- 触发：大小写不同的 `Chunked`、逗号列表（包括 final chunked）、重复 `Transfer-Encoding` 字段，或 chunked 不是最后一个 coding。
- 影响：server 仅在值精确等于字符串 `"chunked"` 时读取 chunked body，其他 TE 值一律把请求体长度设为 0；连接保持循环时，实际 body 字节留在 TCP buffer 并被当作下一条请求的起始内容。client 对 final-chunked 列表错误地改为读到连接关闭，破坏持久连接与响应完成判断。非 final chunked 请求也没有按规范报错并关闭。
- 证据：`read_header` 只将字段名转小写，不规范化字段值；重复字段被存成 table。server 与 client 都使用 `header["transfer-encoding"] == "chunked"` 的精确比较，没有 token 拆分、OWS 处理、大小写归一化、final coding 判断或 unsupported coding 分支。
- 建议解法：建立共享的 TE parser，合并重复字段并按逗号解析 coding/token 参数，大小写不敏感地判断 final coding；请求 final 非 chunked 时 400+close，不支持的 coding 明确 501；响应 final 非 chunked 时按 close-delimited 处理并禁止复用。若不实现 gzip/compress 等解码，不能把已编码 body 暴露为普通 content。
- 后续回归条件：修复阶段覆盖 `Chunked`、OWS、重复字段、`gzip, chunked`、`chunked, gzip`、重复 chunked、未知 coding，以及 client/server 连接后续状态；本轮不新增测试代码。

### HTTP1-004 — P2 — chunk-size 行的非法扩展和尾随垃圾被静默接受

- 状态：已确认；RFC 消息语法与确定性控制流推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9112 §7.1 将每个 chunk 严格定义为 `chunk-size [ chunk-ext ] CRLF`；§7.1.1 的扩展必须由分号起始，并满足 `token` 或 `quoted-string` 语法。接收方需要忽略的是“不认识但语法有效”的扩展，而不是任意无效尾缀。
- 位置：`lualib/silly/net/http/h1.lua:174-204`；现有部分覆盖为 `test/testhttp.lua:2096-2160`。
- 触发：chunk-size 的十六进制数字后出现不符合 `chunk-ext` ABNF 的内容，例如没有分号的尾缀、空扩展名、非法 token 字符、未闭合 quoted-string，或合法扩展之后的额外垃圾。
- 影响：client 和 server 共用该 reader，都会把语法无效的消息体当成合法 chunked body。严格实现与本实现对同一字节流可能作出不同的接受/拒绝决定；在代理链或连接复用场景中，这会扩大请求走私、响应拆分和消息边界歧义的攻击面。
- 证据：`line:match("^([0-9A-Fa-f]+)")` 只保存行首 hex，随后直接 `tonumber`；代码既没有确认 hex 后紧接 CRLF，也没有解析/验证剩余内容。Test 73 的 `;foo=bar` 与 `;baz=qux` 都是合法形式，只证明合法扩展未阻断 body；没有任何测试要求拒绝非法 suffix。
- 建议解法：把完整 chunk-size 行交给共享 parser：先验证 hex，再按 §7.1.1 逐个解析 `;`、BWS、扩展名和可选值，并要求解析位置最终恰好到达 CRLF；可以忽略合法但未知的扩展值，不能忽略语法错误。同步设置合理的 size-line/chunk-ext 总长度上限。
- 后续回归条件：修复阶段覆盖合法未知扩展、BWS、token/quoted-string，以及无分号尾缀、空名、非法字符、未闭合引号和合法扩展后的垃圾；client/server 都必须拒绝无效行并使连接不可复用。本轮不新增测试代码。

## 5. 正在验证的候选问题

### CAND-SOCK-002 — `wlbytes` 可记到已经复用的新 socket slot

- 位置：`src/socket.c:1614-1639`、`:1663-1686`、`:1757-1767`。
- 观察：worker 通过 sid 验证后，socket thread 仍可 free/reuse slot；随后 worker 对 slot 的原子 `wlbytes` 加值。旧 sid 的 op 被丢弃并释放 payload，却无法安全回滚已经落在新 socket 上的计数。
- 待验证：用精确 barrier 让 close/free/accept-reuse 发生在 sid check 与计数之间。
- 预期解法：把 per-socket accounting 移到 socket thread 在 sid 验证之后执行；如必须让 worker 立即可见，需要 generation-safe 的计数方案或完整 seqlock，不能仅依赖原子整数。

## 6. 已排除项

### REJECT-SOCK-001 — 固定接收 buffer 导致合法 UDP 报文截断

- 原候选：`CAND-SOCK-004`。
- 位置：`src/socket.c:1028-1057`、`src/silly_conf.h:49-50`。
- 结论：当前不构成缺陷。`recvfrom` 的固定 buffer 为 2 MiB，显著大于 IPv4/IPv6 可承载的最大合法 UDP datagram（约 64 KiB）；因此合法 UDP 报文不会因该 buffer 大小而被截断。
- 保留条件：若未来将 buffer 缩小到 UDP 上限以下，或加入平台特定的非标准超大 UDP/GSO 接收接口，必须重新检查 `MSG_TRUNC` 和报文边界语义。

## 7. TSAN 动态证据摘要

隔离构建参数：`-DSILLY_TEST -O1 -fsanitize=thread -fno-omit-frame-pointer`，运行完整 `testtcp2`。业务断言 30 组全部通过，但进程以 TSAN 告警状态退出，共报告 5 组竞争：

1. `engine.c:76` 写 `workerstatus` vs `engine.c:45` 读。
2. `queue.c:91` 读 `size` vs `queue.c:67` 写。
3. `queue.c:75` 读 `head` vs `queue.c:65` 写。
4. `worker.c:94` 读 `maxmsg` vs `worker.c:193` 写。
5. `engine.c:168` 写 `running` vs `engine.c:94` 读。
6. `socket.c:763` 写 `fd` vs `socket.c:2028` 的 `socket_stat` 读。
7. `socket.c:461` 写 `type` vs `socket.c:2029` 的 `socket_stat` 读。

因此“普通测试通过”与“并发实现没有 UB”是两个不同结论；后续并发模块将继续同时看功能结果和 sanitizer 结果。

## 8. 修复顺序（滚动更新）

当前建议顺序：

1. 先统一 engine 的 mutex/atomic predicate 协议，并修正 thread creation/rollback。
2. 修复 queue 的所有同步，再复跑 TSAN；避免在有底层竞争时判断上层并发现象。
3. 修复 shutdown 的 owned buffer 清理与 socket slot accounting。
4. 修复 UDP 队列计数和错误可见性。
5. 再进入 Lua net/TCP/UDP/TLS 与高层协议修复，避免上层测试被核心竞态干扰。

## 9. 审计日志

- 2026-08-06：建立独立最新工作副本，拉取官方 origin，确认 HEAD `d1aef7ff`。
- 2026-08-06：完成 ASan/UBSan 基线；TCP、HTTP/1、HTTP/2、WebSocket、gRPC、Redis、MariaDB 10.3 测试通过。
- 2026-08-06：完成第一轮 engine/queue/worker/socket 静态审阅，并用 TSAN 确认 5 组真实竞争。
- 2026-08-06：用 `sendv_cap=1` 的确定性复现确认退出路径泄漏全部待发 payload；LSan 报告 32768 bytes/8 objects。
- 2026-08-06：确认立即失败的 TCP connect 泄漏 fd；8 次失败令 open fd 从 8 增至 16。
- 2026-08-06：排除合法 UDP datagram 因 2 MiB 固定接收 buffer 被截断的候选；保留未来 buffer/GSO 变更时的复查条件。
- 2026-08-06：用 close/stat 最小复现将 `CAND-SOCK-003` 升级为 `SOCK-005`；TSAN 确认 fd/type 数据竞争，同一轮触发未检查 `getsockname` 后的 address-family 断言。
- 2026-08-06：开始 HTTP/1 RFC 9112 静态矩阵；确认 TE+CL 请求被接受后连接仍可复用，记录为 `HTTP1-001`。按用户要求暂停新增复现代码，先完成协议 review。
- 2026-08-06：确认 client/server 都会拒绝 RFC 9112 允许的相同 `Content-Length` 列表，记录为 `HTTP1-002`；不同值的现有拒绝测试仍然正确。
- 2026-08-06：确认 `Transfer-Encoding` 被错误地当作精确小写单值而非 coding 列表，导致 client/server framing 偏离，记录为 `HTTP1-003`。
- 2026-08-06：确认 chunk reader 只提取行首 hex 并忽略全部尾缀，非法 chunk extension/尾随垃圾会被静默接受，记录为 `HTTP1-004`。
