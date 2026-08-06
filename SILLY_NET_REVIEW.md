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

HTTP/2 + HPACK 审计清单（状态：进行中；SETTINGS 角色与方向性已开始逐条核对）：

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
| RFC9112-7-CHUNK-SIZE-OVERFLOW | MUST | `lualib/silly/net/http/h1.lua:174-204`; `deps/lua/lbaselib.c:61-79,83-113`; `deps/lua/luaconf.h:133-178` | client/server | 偏离 | `tonumber(hex, 16)` 的累加没有 overflow 检查；超长 size 按 `lua_Unsigned` 模数回绕，当前 64-bit 配置中 `2^64` 会变成 0 并被当作 last-chunk | 现有 Test 74/75 仅覆盖小尺寸合法 hex，没有超范围值 | HTTP1-005 |
| RFC9110-6.5.1/6.6.2-TRAILER-SEND | MUST/SHOULD | `lualib/silly/net/http/h1.lua:102-123,421-438,694-702,790-798` | client/server sender | 偏离 | `closewrite` 原样序列化任意 trailer，没有阻止定义不允许出现在 trailer 的 framing/routing/auth/content 字段；API 在 header flush 后才接收 trailer map，无法自动生成建议的 `Trailer` 声明 | Test 18 只发送自定义字段，且初始 header 没有 `Trailer` 声明；无禁止字段覆盖 | HTTP1-006 |
| RFC9110-6.5/RFC9112-7.1.2-TRAILER-SEPARATE | MUST | `lualib/silly/net/http/h1.lua:174-192,468-486` | client/server recipient | 符合 | 收到的 trailer 写入独立 `s.trailer`，没有合并到 `s.header` | Test 18、conformance Test 121 验证独立 trailer 读取 | — |
| RFC9110-2.3/5.4/17.5-LIMITS | SHOULD/security | `lualib/silly/net/http.lua:11-47`; `lualib/silly/net/http/h1.lua:129-168,174-204,512-553,818-890`; `lualib/silly/net/tcp.lua:68-98,127-148,213-225` | server | 偏离 | HTTP listener 没有行长、字段数量/总大小或 header deadline；底层 buffer 默认无 limit，HTTP 配置也无法设置。无换行行和无限字段序列均可持续扩内存 | Test 4 明确要求接受 1000 个字段；Test 80 的 414 覆盖被 TODO 注释 | HTTP1-007 |
| RFC6455-4.2.1-SERVER-HANDSHAKE | MUST | `lualib/silly/net/websocket.lua:30-34,226-266`; `lualib/silly/net/http/h1.lua:818-869` | server | 偏离 | 必需字段仅在存在时校验；HTTP version/Host 未校验，Connection 用子串，Upgrade 错误地精确区分大小写，Key 未验证解码长度 | 现有测试只覆盖本库 client 生成的标准握手，没有逐项缺失/非法输入 | WS-001 |
| RFC6455-4.1-CLIENT-HANDSHAKE | MUST | `lualib/silly/net/websocket.lua:292-337` | client | 偏离 | 收到响应后只检查 status 101；没有验证 Upgrade、Connection、按请求 Key 计算的 Accept，也不检查未请求的 extension/subprotocol | 现有测试只连接本库 server，没有畸形/伪造 101 响应 | WS-002 |
| RFC6455-5.2/5.5-FRAME-HEADER | MUST | `lualib/silly/net/websocket.lua:51-128,139-176` | client/server | 偏离 | 接收端忽略 RSV、最短长度、64-bit 高位和控制帧 FIN/长度规则；发送端把 125 与 65535 bytes 编成非最短扩展长度。mask 方向校验符合 | 现有测试只覆盖正常短帧/大消息，没有畸形帧头和两个边界长度 | WS-003 |
| RFC6455-5.4-FRAGMENT-STATE | MUST | `lualib/silly/net/websocket.lua:139-176` | client/server | 偏离 | continuation 可在无进行中消息时出现；已有 fragmented message 时新 text/binary 被作为独立消息交付。控制帧穿插并保留 stash 的方向正确 | 现有测试只覆盖本库 writer 生成的规范连续 fragments，没有非法序列或穿插控制帧 | WS-004 |
| RFC6455-10.4-SIZE-LIMITS | MUST/SHOULD | `lualib/silly/net/websocket.lua:51-95,139-176,273-289`; `lualib/silly/net/http.lua:11-47` | client/server | 偏离 | 没有 frame 或 message 总大小限制；reader 按 wire length 等待完整 frame，fragmentation 无界累积后 concat，API 也没有 limits 配置 | 现有大消息测试只覆盖约 1 MiB 正常数据，没有超限或无限 fragments | WS-005 |
| RFC6455-5.5.1/5.6/8.1-UTF8 | MUST | `lualib/silly/net/websocket.lua:139-213` | client/server | 偏离 | text message 与 Close reason 收发均无 UTF-8 验证；fragmented text 只 concat，不在完整消息边界校验 | 无 invalid UTF-8、跨 fragment code point 或 invalid close reason 覆盖 | WS-006 |
| RFC6455-5.5.1/7-CLOSE-STATE | MUST/SHOULD | `lualib/silly/net/websocket.lua:139-223`; `docs/src/reference/net/websocket.md:160-224` | client/server | 偏离 | 没有 close payload/status 校验或 CLOSING 状态；Close 后仍可写 data，`sock:close()` 发帧后立即断 TCP、不等待 peer Close | Test 1/3 只覆盖空 Close；双方调用 close 的时序没有断言 clean handshake | WS-007 |
| RFC6455-5.5.2-PING | MUST | `lualib/silly/net/websocket.lua:139-213`; `docs/src/reference/net/websocket.md:160-197` | application endpoint | 契约明确 | read 把 ping 及 payload 交给应用，文档示例要求立即回同 payload pong；属于显式应用层责任，不单独作为库缺陷 | Test 3 覆盖手动 ping/pong | — |
| RFC6455-4.1/5.3-MASK-ENTROPY | MUST | `lualib/silly/net/websocket.lua:104-127,292-320`; `luaclib-src/crypto/lutils.c:15-23`; `src/engine.c:125-151` | client | 偏离 | mask/key 由 time-seeded 非密码学 PRNG 的小写字母生成；每帧 mask 仅 26^4 种且后续序列可预测，不是强熵 32-bit value | 正常测试只验证 mask 方向和解码结果，不检查熵、取值空间或可预测性 | WS-008 |
| RFC6455-FRAME-WRITE-ATOMICITY | safety | `lualib/silly/net/websocket.lua:104-127,179-213`; `lualib/silly/net/tcp.lua:307-315`; `src/flipbuf.h:30-51`; `src/socket.c:1614-1659` | client/server | 符合 | 单次 frame 先组装为完整 string，再以一个 TCP send op 入带锁队列；Lua 路径不 yield，未发现并发调用导致帧内交错 | 现有 50-client stress 不是同 socket 并发，但静态原子边界成立 | — |
| RFC9113-6.5.2-ENABLE-PUSH-ROLE | MUST | `lualib/silly/net/http/h2.lua:1211-1278,1500-1537,1651-1710` | client recipient | 偏离 | client/server 共用 `frame_settings`；收到值 1 时只设 `ch.enablepush=true`，没有识别发送方是 server 并发送 `PROTOCOL_ERROR`。server 发送值 0 符合 RFC，不属于偏离 | 现有测试只覆盖双方发送值 0，没有 server→client 值 1 | H2-001 |
| RFC9113-4.1-UNUSED-FLAGS | MUST | `lualib/silly/net/http/h2.lua:270-307` | client/server recipient | 偏离 | `read_frame` 对任意 frame type 的 flag 0x08 都执行 padding 解析；该位在 SETTINGS/PING 等类型未定义，本应忽略，却会删除 payload 字节或触发错误 | 现有测试没有在非 padding frame 上设置 unused flag | H2-002 |
| RFC9113-5.2/6.9-RECV-FLOW-CONTROL | MUST/security | `lualib/silly/net/http/h2.lua:151-207,239-263,479-482,502-542,1177-1204` | client/server recipient | 偏离 | channel/stream 没有剩余 receive-window 状态；DATA 无条件 append，仅累计将来回补的 debt，超过已广告 credit 也不会报 `FLOW_CONTROL_ERROR` | 现有测试只覆盖守规发送方和正常 1 MiB 消息，没有超 window DATA | H2-003 |
| RFC9113-6.5.2-HEADER-TABLE-DIRECTION | MUST | `lualib/silly/net/http/h2.lua:151-170,239-263,1211-1278` | client/server | 偏离 | 收到 peer 的 HEADER_TABLE_SIZE 后错误地 hard-limit `recvhpack` decoder；该 setting 描述 peer decoder 的上限，应约束本端 `sendhpack` encoder | HPACK 单测只同时修改 encoder/decoder；HTTP/2 测试没有非默认 peer setting | H2-004 |

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

### HTTP1-005 — P1 — 超大 chunk-size 整数回绕可伪造 last-chunk 边界

- 状态：已确认；RFC 明确要求与确定性整数运算推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9112 §7 明确要求接收方预见并防止 chunk-size 转换中的整数溢出或精度丢失。协议本身不限制 hex 位数，因此实现必须在转换时检测自身表示上限，不能截断或回绕。
- 位置：`lualib/silly/net/http/h1.lua:174-204`、`deps/lua/lbaselib.c:61-79,83-113`、`deps/lua/luaconf.h:133-178`；后续负值还进入 `lualib/silly/net/tcp.lua:263-300`、`luaclib-src/adt/lbuffer.c:318-377` 或 TLS 的 `lualib/silly/net/tls.lua:435-447`、`luaclib-src/ltls.c:514-542`。
- 触发：发送超出 `lua_Unsigned` 表示范围的 chunk-size。当前默认配置为 64-bit `lua_Integer`；例如十六进制 `10000000000000000`（`2^64`）在 base-16 转换中回绕为 0。
- 影响：`read_chunk` 看到回绕后的 0 会立即读取 trailer、设置 EOF，把声明 chunk 后的剩余字节留给连接上的后续 HTTP 消息解析。在前后端对大整数采用拒绝、饱和或更宽表示时，同一字节流会产生不同消息边界，形成直接的请求走私/响应拆分风险。其他回绕结果还可能变成负数并进入只接受 C `int` 尺寸的 buffer/TLS reader，产生额外的错误状态差异。
- 证据：内置 Lua 的 `b_str2int` 以 `lua_Unsigned n` 执行 `n = n * base + digit`，没有上溢判断，最后直接 cast 为 `lua_Integer`；无符号溢出按模数回绕。`read_chunk` 不检查 `tonumber` 结果是否为非负、是否超出表示范围或配置上限，只对 `sz == 0` 作 last-chunk 判断。
- 建议解法：不要用通用 `tonumber(..., 16)` 解析 framing。逐个 hex digit 累加，并在每步计算前检查 `value > (limit - digit) / 16`；`limit` 同时受实现可安全读取的整数上限和可配置 body/chunk 上限约束。任何超范围 size 都必须作为不可恢复 framing error，client/server 关闭并禁止复用连接。
- 后续回归条件：修复阶段覆盖实现上限边界、边界加一、`2^63`、`2^64-1`、`2^64`、更多前导零和极长 numeral；断言超范围值绝不能成为 0/负数或消费后续消息。本轮不新增测试代码。

### HTTP1-006 — P2 — trailer 发送 API 可生成规范禁止的字段且不自动声明

- 状态：已确认；RFC 规范与确定性发送路径推导。本阶段只做静态 review，不新增复现代码。接收侧将 trailer 独立保存在 `s.trailer`，这一点符合规范，不属于本问题。
- 规范：RFC 9110 §6.5.1 要求发送方只有在对应字段定义明确允许时才能把它生成在 trailer 中；message framing、routing、authentication、request modifier、response control 和 content format 等需要在内容之前处理的字段不能后置。§6.6.2 还建议发送 trailer 时在初始 header 的 `Trailer` 字段中预告可能出现的字段名。
- 位置：`lualib/silly/net/http/h1.lua:102-123`、`:421-438`、`:694-702`、`:790-798`；现有覆盖为 `test/testhttp.lua:509-534`。
- 触发：client 或 server 使用 chunked 输出并把任意 table 传给 `closewrite`；table 中可以包含 `content-length`、`transfer-encoding`、`connection`、认证或内容格式字段，也可以完全不在初始 `Trailer` header 中声明。
- 影响：库会主动生成不符合 HTTP 语义的消息。不同接收方或跨版本 intermediary 可能选择丢弃、保留或错误合并这些字段，从而造成安全策略、元数据和消息解释不一致；framing/connection 字段尤其会扩大协议链中的歧义。即便仅发送合法自定义 trailer，默认路径也错过了预告机制，降低跨 intermediary 保留与处理的互操作性。
- 证据：`close_write` 先通过 `flush_header` 固化并输出初始 header，之后才对 trailer table 调用通用 `compose_header`；该函数除 `host` 外不检查任何字段名，也没有 trailer allowlist/denylist 或字段定义校验。由于 trailer 参数只在 header flush 后出现，实现无法根据它补充 `Trailer` 声明。Test 18 正是未在初始 header 声明便发送两个自定义 trailer，且没有禁止字段测试。
- 建议解法：在初始 header 尚未发送时注册 trailer 名称，校验名称并生成/核对 `Trailer` 字段；发送时至少拒绝所有已知不允许 trailer 的标准字段，并为扩展字段提供显式允许策略或由调用者声明其定义允许 trailer。HTTP/1 与 HTTP/2 应共享同一语义校验层，协议编码层只负责各自 framing。
- 后续回归条件：修复阶段验证合法已声明 trailer 可互操作，未声明策略明确；覆盖 framing、routing、connection、authentication、content format 等禁止类别，确保 client/server 都拒绝生成，而接收侧仍将允许的 trailer 与 header 分开。本轮不新增测试代码。

### HTTP1-007 — P1 — HTTP/1 行和字段集合无上限，可被未认证连接耗尽内存

- 状态：已确认；确定性缓冲/解析路径推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9110 §2.3 要求接收方防御性解析并只对协议元素能装入合理 buffer 抱有限预期；§17.5 明确警告不限制字段名、数值、chunk length 等处理范围会增加拒绝服务风险。§5.4 允许部署选择字段限制，但一旦超过其处理意愿，server 必须返回合适 4xx，不能忽略字段。RFC 9112 §3 同时要求超过实现意愿的 request-target 返回 414。
- 位置：`lualib/silly/net/http.lua:11-47`、`lualib/silly/net/http/h1.lua:129-168`、`:174-204`、`:512-553`、`:818-890`；底层为 `lualib/silly/net/tcp.lua:68-98`、`:127-148`、`:213-225`，TLS 同类路径为 `lualib/silly/net/tls.lua:105-137`、`:250-278`、`:398-407`。
- 触发：未认证客户端可以持续发送没有 LF 的 request/header/chunk-size/trailer 行，或发送任意数量的短 header/trailer 字段；连接也没有解析阶段 deadline。
- 影响：无 LF 时底层接收 buffer 持续增长并保持 coroutine 等待；有 LF 时 `read_header` 会把每个字段及重复值持续保存在 Lua table 中。攻击者可以用一个或多个慢速连接长期增长堆内存和占用连接/协程，最终造成进程 OOM 或服务不可用。HTTP/1 明文和 TLS 入口都受影响。
- 证据：TCP/TLS connection 的 `buflimit` 默认都是 nil；`http.listen` 的配置没有 limit、header timeout、最大行长、最大字段数或总字节数，并直接把新连接交给 `h1.httpd`。`read_header` 循环到空行为止且不累计/检查大小，request-line 和 chunk-size 也直接 `read("\n")`。底层 `limit()` 即使由其他调用方设置也只是暂停 read event，不返回错误、4xx 或 deadline；标准 HTTP listener 没有机会配置它。Test 4 明确要求约 1000 个自定义字段仍返回 200，Test 80 的 414 用例则整体位于 TODO 注释中。
- 建议解法：为 HTTP listener/client 增加可配置且有安全默认值的 request/status line、单字段、header/trailer 总字节、字段数量和解析 deadline；读取每行前就应用硬上限，超限立即终止缓冲。server 对完整但超限的请求返回 414/431/400 后关闭；对慢速或始终不换行的输入按 deadline 关闭。TCP backpressure limit 不能替代协议错误和生命周期回收。
- 后续回归条件：修复阶段覆盖边界值、边界加一、单行无 LF、许多短字段、巨大 trailer/chunk-size extension、慢速逐字节发送，以及明文/TLS；断言超限连接释放、handler 不执行、内存有界，合法最小 8 KiB request-line 仍受支持。本轮不新增测试代码。

### WS-001 — P1 — WebSocket 服务端把缺失或无效的 opening handshake 当成成功

- 状态：已确认；RFC 6455 与确定性控制流推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 6455 §4.2.1 要求服务端只接受 HTTP/1.1 或更高的 GET，并要求 Host、包含 `websocket` 的 Upgrade、包含独立 `Upgrade` token 的 Connection、解码后 16 bytes 的 Sec-WebSocket-Key 和受支持的 Sec-WebSocket-Version；任一握手语法不匹配都必须停止并返回 HTTP 错误。Upgrade/token 比较是 ASCII 大小写不敏感。
- 位置：`lualib/silly/net/websocket.lua:30-34`、`:226-266`；HTTP version/Host 来源为 `lualib/silly/net/http/h1.lua:818-869`。
- 触发：调用 `websocket.upgrade(stream)` 时，请求只要 method 为 GET 且存在任意字符串的 `Sec-WebSocket-Key` 即可；`Upgrade`、`Connection`、`Sec-WebSocket-Version` 和 Host 可以缺失，HTTP version 可以是 1.0。`Connection: notupgrade` 也因子串命中而通过。反向地，合法大小写或 token-list 形式的 Upgrade 还可能被错误拒绝。
- 影响：HTTP endpoint 会在没有完成 WebSocket opt-in/proof 的请求上发送 101 并把连接切换到 frame parser，破坏 WebSocket 防止跨协议混淆的握手边界。代理和 origin 对是否发生 Upgrade 可能得出不同结论，造成连接状态分歧；宽松接受与错误拒绝也会破坏标准客户端/中间件互操作。
- 证据：`checklist` 包含三个必需字段，但循环用 `if verify then ... end`，缺失值直接跳过。Connection 仅执行 `lower():find("upgrade", ..., true)`，没有逗号 token 解析；其他字段用区分大小写的精确字符串比较。代码只检查 Key 非空并直接参与 Accept 哈希，从未验证 Base64 语法或解码长度；也不检查 `stream.version` 和 Host。底层 H1 server 只拒绝高于 1.1 的 version，不要求 Upgrade 必须是 HTTP/1.1。
- 建议解法：建立严格的 server handshake validator：先要求 HTTP/1.1+ GET 和有效 Host；合并重复字段后按逗号 token、OWS 和 ASCII 大小写不敏感规则验证 Upgrade/Connection；严格解析单一 version 13；验证 Key 是合法 Base64 且解码恰为 16 bytes，再用原编码字符串计算 Accept。unsupported version 返回 426 并携带 `Sec-WebSocket-Version: 13`，其他错误返回 400 并关闭。
- 后续回归条件：修复阶段对每个必需项做缺失、重复、大小写、token-list、substring、非法 Base64、非 16-byte、HTTP/1.0 和缺失 Host 覆盖；合法 `Upgrade: WebSocket` 与 `Connection: keep-alive, Upgrade` 必须通过。本轮不新增测试代码。

### WS-002 — P1 — WebSocket 客户端仅凭 101 状态就接受服务端握手

- 状态：已确认；RFC 6455 与确定性控制流推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 6455 §4.1 要求 client 在 101 后继续验证：Upgrade 必须大小写不敏感地等于 websocket，Connection 必须包含独立 Upgrade token，Sec-WebSocket-Accept 必须等于本次 Key 与 GUID 的 SHA-1/Base64；服务器选择未请求的 extension 或 subprotocol 也必须使连接失败。任一条件不符都必须 Fail the WebSocket Connection。
- 位置：`lualib/silly/net/websocket.lua:292-337`。
- 触发：目标 HTTP server 返回任意 `101 Switching Protocols`，即使缺失所有 WebSocket 响应字段、Accept 错误，或声明 client 从未请求的 extension/subprotocol。
- 影响：client 无法验证响应者确实理解并接受了本次 WebSocket nonce，普通 HTTP 101、错误代理响应、串线连接或恶意 endpoint 都会被提升为 WebSocket socket。随后任意响应/连接字节被 frame parser 解释，造成协议混淆、数据错误和潜在安全边界绕过；在明文 ws 中尤其不能依赖传输层替代握手证明。
- 证据：client 正确生成随机 16-byte Key 并发送握手，但该值没有保存为 expected Accept；`waitresponse()` 成功后代码只读取 `stream.status` 并比较 101，随后立即 `newsocket(stream, true)`。`stream.header` 中的 Upgrade、Connection、Sec-WebSocket-Accept、Sec-WebSocket-Extensions 和 Sec-WebSocket-Protocol 从未访问。
- 建议解法：生成 Key 时同时计算并保存 expected Accept；收到 101 后使用共享 token parser 验证 Upgrade/Connection，常量时间或普通精确字符串比较 Accept，并对 extension/subprotocol 响应执行“只能从请求集合中选择”的规则。任何失败都关闭底层连接且不得返回 socket；如果功能暂不支持 extension/subprotocol，应拒绝任何非空协商响应。
- 后续回归条件：修复阶段为每个响应字段覆盖缺失、错误值、大小写、token-list、重复字段；Accept 覆盖其他 Key、空值和格式错误；服务器擅自选择 extension/subprotocol 必须失败，标准握手保持通过。本轮不新增测试代码。

### WS-003 — P2 — WebSocket 基础帧头缺少规范校验且发送边界编码错误

- 状态：已确认；RFC 6455 与确定性位解析/编码推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 6455 §5.2 要求未协商 extension 时 RSV1/2/3 全为 0，未知 opcode 必须使连接失败；64-bit payload length 的最高位必须为 0，且长度必须使用最短编码。§5.5 要求所有控制帧 FIN=1 且 payload 不超过 125 bytes。client→server 必须 mask、server→client 必须不 mask。
- 位置：`lualib/silly/net/websocket.lua:51-128`、`:139-176`。
- 触发：对端发送任何非零 RSV、126 编码的 0..125、127 编码的 0..65535、64-bit 高位为 1、未知 opcode，或 fragmented/超长控制帧；本库发送恰好 125 或 65535 bytes 的 data/control payload 也会触发非最短编码。
- 影响：接收端会消费并向应用交付 RFC 要求使连接失败的帧，不同实现对同一 TCP 字节流产生接受/关闭差异；控制帧可能进入错误的 fragmentation 路径。发送端则会生成严格 peer 必须拒绝的非规范帧，造成稳定互操作失败。若非法 header 同时声明巨大 payload，当前实现还会在 opcode/control 校验前尝试读取完整数据，资源风险另行跟踪。
- 证据：首字节只提取 FIN 与低 4-bit opcode，RSV 三位被丢弃；扩展长度 `unpack` 后没有最短编码或最高位检查。`read_frame` 在任何 opcode 下先读取完整 payload，`s.read` 之后才查 `data_type`，且从未按 opcode 检查 FIN/125。mask 的 `needmask ~= mask` 校验是符合项。发送端使用 `len < 125` 与 `len < 0xffff`，导致合法直接编码的上界 125 和 16-bit 上界 65535 分别被提升一级。
- 建议解法：在读取 payload 前完整验证 header：RSV 与协商 extension 状态、已知 opcode、角色对应 mask、canonical length、63-bit 上限和控制帧 FIN/长度。编码条件改为 `len <= 125`、`len <= 0xffff`。任何 protocol error 进入统一 Fail WebSocket Connection 状态，必要时发送 1002 Close，且不得继续向应用交付帧。
- 后续回归条件：修复阶段按 client/server 两角色覆盖 RSV1/2/3、全部保留 opcode、mask 反向、125/126、65535/65536、非最短 126/127、64-bit 高位，以及 close/ping/pong 的 FIN 与 125/126；本轮不新增测试代码。

### WS-004 — P2 — fragmentation/continuation 状态机接受非法消息序列

- 状态：已确认；RFC 6455 与确定性状态机推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 6455 §5.4 规定 fragmented message 由非零 data opcode 且 FIN=0 的首帧开始，随后只能是 continuation，直到 FIN=1；没有进行中的 fragmented message 时 continuation 非法，进行中也不能插入另一条 data message。控制帧可以穿插且必须被处理，不得改变当前 fragmented message。
- 位置：`lualib/silly/net/websocket.lua:139-176`。
- 触发：首个收到的帧使用 opcode 0；或 text/binary FIN=0 后，在 final continuation 前发送另一个 text/binary。fragmented 状态中发送 reserved nonzero opcode 也走同一绕过分支。
- 影响：应用会收到 RFC peer 应当判为协议错误的伪造消息边界：standalone continuation 被标为 `continuation` 交付，新 data frame 被作为独立消息交付，而旧 fragmented message 仍保留待后续拼接。不同 endpoint 的关闭/继续决定不一致，应用层消息顺序、类型和鉴权/解析边界可能被打乱。
- 证据：无 stash 时，任意已知 opcode 在 FIN=1 都直接返回，包括 opcode 0；FIN=0 时任意已知 opcode 都能建立 stash。已有 stash 后仅判断 `op ~= 0`，所有非零 opcode 都立即返回给应用且不清除 stash，没有区分允许穿插的 control 与禁止的新 data；该分支也不再验证 `data_type[op]` 是否存在。只有 opcode 0 才追加到 stash。合法 control frame 穿插返回后 stash 仍保留，这一行为本身符合规范。
- 建议解法：显式维护 `fragment_open` 与首帧 data type。IDLE 只允许 FIN 任意的 text/binary 或 FIN=1 control；FRAGMENTED 只允许 continuation 或 FIN=1 control。任何其他序列调用统一 protocol-failure 路径；control 交付/自动处理后恢复读取同一 fragmented message，final continuation 才拼接并清状态。
- 后续回归条件：修复阶段覆盖 standalone continuation、连续两个 data start、continuation 正常链、text/binary 类型保持、ping/pong/close 穿插、reserved opcode 穿插及 control 后继续拼接；client/server 两角色行为一致。本轮不新增测试代码。

### WS-005 — P1 — frame 与重组消息无大小上限，可被远端耗尽内存

- 状态：已确认；RFC 6455 明确安全要求与确定性缓冲路径推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 6455 §10.4 要求受实现/平台上限约束的 endpoint 必须防止 frame 或重组消息超过这些上限，并建议同时限制单帧及 fragmented message 总大小；规范明确列举声明 `2^60` 的单帧和无限小 fragments 造成内存耗尽/DoS。
- 位置：`lualib/silly/net/websocket.lua:51-95`、`:139-176`、`:273-289`；入口配置为 `lualib/silly/net/http.lua:11-47`。
- 触发：对端声明巨大 payload length 后持续发送数据，或用任意数量的 FIN=0 data/continuation fragments 组成一条始终不结束或总量巨大的消息。
- 影响：单帧路径要求底层连接缓冲到完整 `payload` 才返回；分片路径把每段字符串永久保存在 `stashbuf`，结束时还要 `concat` 分配完整连续结果。未认证远端可持续增长堆内存、占用连接和 coroutine，最终导致 OOM、长时间 GC 或服务不可用；client 和 server 都受恶意 peer 影响。
- 证据：64-bit wire length 解码后直接传给 `conn:read(payload)`，此前没有配置或检查上限。`s.read` 对每个 continuation 执行 `stashbuf[#stashbuf + 1] = dat`，不维护累计字节数；只有 final fragment 才 concat/清理。socket/newserver/connect API 都没有 `max_frame_size`、`max_message_size` 或 read deadline 配置。现有测试的正常大消息不能证明恶意无限输入有界。
- 建议解法：为 client/server socket 增加安全默认值和可配置 `max_frame_size`、`max_message_size`、frame read deadline；解析 header 后、读取 payload 前拒绝超限长度，以 1009（Message Too Big）开始关闭。fragmentation 状态累计总字节并在追加前检查，失败时立即释放 stash。若需要真正流式大消息，应设计分块消费 API而不是取消上限。
- 后续回归条件：修复阶段覆盖 frame/message 边界及边界加一、巨大 64-bit length 但无 payload、许多小 fragments、control 穿插不重置计数、失败后 stash 释放，以及 ws/wss、client/server 四条路径；本轮不新增测试代码。

### WS-006 — P2 — text message 与 Close reason 完全不验证 UTF-8

- 状态：已确认；RFC 6455 与确定性数据路径推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 6455 §5.6 要求完整 text message 为合法 UTF-8，单个 fragment 可以只包含部分序列但重组后必须校验；§5.5.1 要求 Close status 后的 reason 为 UTF-8；§8.1 要求 endpoint 一旦发现应解释为 UTF-8 的字节流无效，就必须 Fail the WebSocket Connection。
- 位置：`lualib/silly/net/websocket.lua:139-213`。
- 触发：对端发送含孤立 continuation byte、overlong encoding、surrogate、超范围 code point、截断序列等无效 text message 或 Close reason；本地应用也可以用 `write(..., "text")` / `write(..., "close")` 发送同类无效字节。
- 影响：接收端把规范要求关闭连接的无效 Unicode 原样交给应用，后续 JSON、日志、数据库或安全过滤层可能采用不同替换/拒绝规则，造成验证和解释差异。发送端主动生成对端必须拒绝的消息，破坏互操作；fragment boundary 上的错误若只逐帧检查也会漏报，因此修复必须按完整消息状态验证。
- 证据：`s.read` 只根据 opcode 返回 Lua string；fragmented message 仅执行 `concat(stashbuf)`，没有 UTF-8 decoder/state。`s.write` 对 text/close 仅检查 payload 长度与 opcode，再原样传给 `write_frame`，没有任何 encoding 校验；文件也未引入 UTF-8 模块。
- 建议解法：引入严格、拒绝 overlong/surrogate/out-of-range 的增量 UTF-8 validator。接收 text 时跨 continuation 保存 decoder state，并在 final fragment 要求完整；Close 先解析 status，再独立校验 reason。发送 text/Close reason 在写帧前验证；失败时不发送。接收无效 UTF-8 使用 1007 开始关闭并清理 fragmented state。
- 后续回归条件：修复阶段覆盖所有非法类别、有效多字节、code point 跨 fragment、final 时截断、control 穿插保持 decoder state，以及合法/非法 Close reason；client/server 和发送/接收四个方向均覆盖。本轮不新增测试代码。

### WS-007 — P2 — Close payload 和 closing handshake 没有协议状态机

- 状态：已确认；RFC 6455 与确定性 API/连接状态推导。本阶段只做静态 review，不新增复现代码。Ping/Pong 被 API 明确委托给应用并有文档示例，不作为本问题。
- 规范：RFC 6455 §5.5.1 要求非空 Close payload 至少包含 2-byte 合法 status，reason 为 UTF-8；发送或收到 Close 后进入 CLOSING，发送 Close 后不得再发送 data，收到未响应的 Close 必须回 Close。双方都发送和收到 Close 后才完成 handshake 并关闭 TCP；server 立即关闭，client 通常等待 server，异常时才按合理 timeout 退出。
- 位置：`lualib/silly/net/websocket.lua:139-223`；公开契约为 `docs/src/reference/net/websocket.md:160-224`。
- 触发：收到或发送长度为 1 的 Close、保留/越界 status、Close 后继续读写 data；或任一方调用 `sock:close()` 主动结束正常连接。
- 影响：非法 close data 被原样交付/发送，应用无法可靠获得 close code/reason；Close 后仍可发送应用数据，违反连接状态边界。主动关闭总是在写出 Close 后立即关闭 TCP，peer 的 Close response 无法被读取，因此正常关闭不能确认完成，容易表现为 abnormal/unclean closure，丢失对端状态并造成严格实现互操作失败。
- 证据：reader 对 opcode 8 与其他类型一样返回 raw `dat`，不解析长度/status，也不改变 socket 状态。`s.write(..., "close")` 只受控制帧 125-byte 检查，返回后仍可继续调用 write。`s.close` 调用 `sock:write("", "close")` 后立刻 `conn:close()` 并置 nil，没有等待 peer Close、角色区分或 deadline。现有 Test 3 的接收方由应用读到 Close 后再调用 close，接近响应路径；但最初发送方已经立即断开，测试未验证 clean handshake。
- 建议解法：为 socket 引入 OPEN/CLOSING/CLOSED 及 sent_close/received_close。集中编码/解析合法 status 与 reason；收到首个 Close 自动或由受控 API 回应，禁止后续 data write。`close()` 发起 handshake 后等待 peer Close，并按角色执行 TCP close；加入有限 deadline 防止对端不响应。协议错误使用适当 status，底层异常则标记 unclean。
- 后续回归条件：修复阶段覆盖空 payload、1 byte、合法 code/reason、1005/1006/1015 等禁止 code、未知合法范围、双方同时 close、Close 后 write/read、peer 不响应 timeout，以及 client/server 谁先 TCP close；断言 clean/unclean 结果。本轮不新增测试代码。

### WS-008 — P1 — client masking key 来自可预测的小空间弱随机源

- 状态：已确认；RFC 6455 明确安全要求与确定性随机源推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 6455 §5.3 要求 client 为每帧从允许的完整 32-bit 值中选择新的 masking key，必须来自强熵源，且当前 key 不能让 server/proxy 轻易预测后续 key；规范指出不可预测性是阻止恶意应用控制 wire bytes、实施 HTTP intermediary/cache poisoning 的必要条件。§4.1 的 16-byte Sec-WebSocket-Key 同样要求每连接随机选择。
- 位置：`lualib/silly/net/websocket.lua:104-127`、`:292-320`、`luaclib-src/crypto/lutils.c:15-23`、`src/engine.c:125-151`、`src/silly_conf.h:84`。
- 触发：任何 WebSocket client frame 与 opening handshake 都会调用 `utils.randomkey`；攻击者观察一个或多个 key，或推测进程启动秒数后预测 PRNG 序列。
- 影响：每个 mask byte 只可能是 `a`..`z`，单帧 key 空间仅 `26^4 = 456,976`，远小于 32-bit；PRNG 由进程启动时的秒级时间 seed，且不是密码学安全生成器。恶意 client-side 数据源与协作 server/proxy 可以恢复/预测 mask，使攻击者控制线上 masked bytes，削弱 WebSocket 为保护 HTTP intermediaries 设计的核心安全机制。握手 nonce 也只有约 75 bits 字母空间且可预测，直接违反随机 16-byte 要求。
- 证据：`lrandomkey` 对每个字节执行 `random() % 26 + 'a'`；engine 只调用 `srand(time(NULL))`。Windows 配置还把 `random()` 映射到 `rand()`。`write_frame` 每次直接取该函数的 4 bytes 作为 mask，connect 用同函数的 16 bytes 作为 Key，没有操作系统 CSPRNG/OpenSSL `RAND_bytes`。
- 建议解法：将 `randomkey` 改为操作系统 CSPRNG 或 OpenSSL `RAND_bytes`，返回任意 octet；失败必须显式传播，不能降级到 `rand/random`。mask 每帧独立读取 4 bytes，handshake 每连接独立读取 16 bytes。通用 crypto API 名称也应避免把弱随机实现暴露给其他安全用途。
- 后续回归条件：修复阶段用可注入 RNG 验证每帧都会请求新的 4 bytes、handshake 请求 16 bytes、失败停止发送；统计测试只作辅助，核心断言是调用 CSPRNG 且不做 `%26`/time seed。并检查 fork/Windows/macOS 的实现。本轮不新增测试代码。

### H2-001 — P2 — client 接受 server 非法启用 PUSH 的 SETTINGS

- 状态：已确认；RFC 9113 与确定性角色/分支推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §6.5.2 允许 server 省略 `SETTINGS_ENABLE_PUSH` 或显式发送值 0，但 server 明确不得发送值 1；client 收到 server 的值 1 必须将其作为 `PROTOCOL_ERROR` connection error。client 向 server 发送 0 或 1 均合法。
- 位置：`lualib/silly/net/http/h2.lua:1211-1278`；client/server frame table 与握手位于 `:1500-1537`、`:1651-1710`。
- 触发：Silly HTTP/2 client 连接到在任意 SETTINGS frame 中发送 `SETTINGS_ENABLE_PUSH=1` 的 server。
- 影响：client 接受规范要求终止的非法 server 配置并继续复用连接，协议状态与严格实现不一致；这也掩盖错误或恶意 peer，令后续 PUSH 行为和错误诊断失去可靠前提。当前 client 没有注册 PUSH_PROMISE handler，收到实际 push 会被静默忽略，因此问题不只是一个无害布尔值。
- 证据：client 与 server 都把 `FRAME_SETTINGS` 分派给同一个 `frame_settings`。该函数仅检查值是否为 0/1，随后无条件执行 `ch.enablepush = (val == 1)`；channel 没有供该 handler 判断角色的字段，也没有 client-only 的值 1 拒绝分支。双方握手主动发送值 0，这一点符合 RFC 9113，不计入问题。
- 根因：SETTINGS 值域校验已实现，但遗漏了 `SETTINGS_ENABLE_PUSH` 的发送方角色约束；共享 frame handler 没有携带或推导 endpoint role。
- 建议解法：在 channel 中保存明确 role，或为 client/server 使用独立 SETTINGS wrapper。client 路径收到值 1 时立即 `channel_goaway(ch, PROTOCOL_ERROR)` 且停止应用剩余设置；server 路径继续接受 client 的 0/1。保留 server 发送值 0 的现有合法行为。
- 后续回归条件：修复阶段覆盖 server→client 的省略、0、1、2，以及 client→server 的 0、1、2；断言只有 server→client 1 和任一方向越界值触发 `PROTOCOL_ERROR`，错误后不再创建或复用 stream。本轮不新增测试代码。

### H2-002 — P2 — 全局解释 PADDED 位，未忽略 frame-type 未使用 flag

- 状态：已确认；RFC 9113 与确定性 frame parser 推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §4.1 规定 flag 的语义由 frame type 决定；对某类型没有定义语义的 unused flag，接收方必须忽略。PADDED(0x08) 只由 DATA、HEADERS、PUSH_PROMISE 定义，SETTINGS、PING、GOAWAY、WINDOW_UPDATE、CONTINUATION 及未知类型上的该位不能触发 padding 解析。
- 位置：`lualib/silly/net/http/h2.lua:270-307`，后续固定长度/结构校验位于 `:1211-1278`、`:1311-1372`。
- 触发：peer 在非 DATA/HEADERS/PUSH_PROMISE frame 上设置 bit 0x08。例如合法 6-byte SETTINGS payload 的 flag 设为 0x08，或合法 8-byte PING payload 的 flag 设为 0x08。
- 影响：接收方没有忽略扩展/未使用 flag，而是把 payload 首字节当 Pad Length 后裁剪数据。合法 SETTINGS 会被改成非 6-byte 倍数并触发 `FRAME_SIZE_ERROR`；PING/GOAWAY 等会被错误解析或断开。如果首字节大于等于 payload 长度，还会直接发送 `PROTOCOL_ERROR`。这破坏 HTTP/2 对未知 flag 的前向兼容性。
- 证据：`read_frame` 在知道 `frame_type` 后仍只判断 `if n > 0 and f & PADDED == PADDED`，没有限定允许 padding 的 frame type；随后执行 `dat:byte(1)` 和 `dat:sub(2, #dat-pad_length)`，传给所有后续 handler。RFC 要求的未知 frame 丢弃也发生在该预处理之后，因此未知类型同样可能先错误终止连接。
- 根因：把部分 frame 类型共有的字段解析放到了通用 frame reader，并仅按 flag bit 分派，没有把 flag semantics 与 type 绑定。
- 建议解法：通用 reader 只解析 9-byte header 和原始 payload；在 DATA、HEADERS、PUSH_PROMISE 的各自 parser 中解析/校验 padding，其他类型保持原 payload 并忽略未定义 flag。若保留 helper，也必须以允许集合 `(DATA|HEADERS|PUSH_PROMISE)` 作为前置条件。
- 后续回归条件：修复阶段对每个已知非 padding frame 和一个未知 frame 设置 0x08/其他 unused bits，断言按未设置时相同地处理；同时覆盖三种合法 padding frame 的 0、最大合法、过长 padding，确认错误作用域不变。本轮不新增测试代码。

### H2-003 — P1 — 接收方向不维护 flow-control window，超额 DATA 仍被缓存

- 状态：已确认；RFC 9113 与确定性状态/数据路径推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §5.2 将 flow control 定义为 receiver 广告、sender 必须遵守的 connection/stream 双层 credit；初始值均为 65,535 octets。§6.1/§6.9 要求完整 DATA payload 计入两层 window，receiver 必须持续记账，才能识别 peer 超出可用 credit 的 `FLOW_CONTROL_ERROR`；流控正是限制未消费资源承诺的协议边界。
- 位置：channel/stream 字段与初始化在 `lualib/silly/net/http/h2.lua:151-207,239-263,479-482`；credit 回补在 `:502-542,760-771`；DATA 接收在 `:1177-1204`。
- 触发：peer 在没有收到足够 stream WINDOW_UPDATE 时，向同一 open stream 发送累计超过已广告 65,535 octets 的 DATA；connection 方向同样可发送超过当时有效 credit 的连续 DATA。应用尚未读取该 stream 时最清晰，因为实现不会发送 stream-level 回补。
- 影响：Silly 不会以 stream/connection `FLOW_CONTROL_ERROR` 拒绝超额数据，而会继续把 payload append 到 `s.recvbuf`。不守规或恶意 peer 因而能绕过 HTTP/2 为慢消费者提供的每流内存上限；结合多个 stream 和没有消息体上限，可持续消耗服务端或 client 内存。connection-level 自动回补也不能替代对已用 credit 的校验。
- 证据：channel 只有发送窗口 `sendwindow` 和名为 `recvwindebt` 的待回补累计值；stream 同样只有 `sendwindow` 与待回补 `recvwindebt`，没有 receive-window remaining。`frame_data` 只调用 `channel_windebt(ch, #dat)`，随后无条件 `s.recvbuf:append(dat)`；两者都不减窗口、不检查负值、不调用 `FLOW_CONTROL_ERROR`。stream debt 只有应用消费/等待读取时才由 `stream_flush` 生成 WINDOW_UPDATE，因此超出 65,535 的未读 DATA 路径确定成立。
- 根因：实现了 outbound sender window 和 inbound WINDOW_UPDATE 回补机制，但把 receiver accounting 简化成“收到多少以后就回多少”，遗漏了独立的已广告 credit/remaining window 状态与违规检测。
- 建议解法：为 connection 和每个 stream 分别维护 receive-window remaining。读取 DATA header 后按原始完整 payload 长度先扣 connection window，再按合法 stream 状态扣 stream window；connection 负值触发 connection `FLOW_CONTROL_ERROR`，stream 负值触发 stream `FLOW_CONTROL_ERROR`。应用消费后生成 WINDOW_UPDATE 时再增加本地 remaining，并保证 31-bit 边界；错误/关闭 stream 的 DATA 仍须按 RFC 更新 connection accounting。
- 后续回归条件：修复阶段在不读取 body 的单 stream 上覆盖恰好 65,535、65,536、多 frame 超限；覆盖多 stream 共享 connection window、消费后恢复 credit、closed/error stream DATA、padding 计入和 SETTINGS 初始窗口变化，分别断言正确的 stream/connection 错误作用域。本轮不新增测试代码。

### H2-004 — P2 — SETTINGS_HEADER_TABLE_SIZE 被应用到反向 HPACK context

- 状态：已确认；RFC 9113/RFC 7541 与确定性对象流向推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §6.5.2 定义 `SETTINGS_HEADER_TABLE_SIZE` 为发送该 setting 的 endpoint 用于解码 field block 的最大 compression table size；收到它的一端必须据此约束自己的 encoder。RFC 7541 §2.2 强调双向连接的 encoding/decoding dynamic table 完全独立，§4.2 要求 encoder 使用的容量不得超过协议给出的上限。
- 位置：`lualib/silly/net/http/h2.lua:151-170,239-263,1211-1278`；HPACK context 实现在 `luaclib-src/lhttp.c:246-260,489-548,696-789`。
- 触发：peer 发送非默认的 `SETTINGS_HEADER_TABLE_SIZE`，最清晰的是值 0 或小于 4096 的值；随后任一方向发送会使用 dynamic table 的 field block。
- 影响：Silly 的 outbound encoder `sendhpack` 继续使用最多 4096-byte dynamic table，违反 peer 声明的 decoder 内存上限，并可能生成 peer 必须以 compression error 拒绝的 block。与此同时，本端 decoder `recvhpack` 被错误缩小；peer 仍可合法按照 Silly 自己广告的 4096-byte 上限编码，却会被本端错误拒绝，导致连接级 `COMPRESSION_ERROR` 和互操作失败。
- 证据：channel 明确分别创建 `sendhpack` 与 `recvhpack`，写 header 使用前者、`read_header` 使用后者。`frame_settings` 处理 id 1 时却执行 `hpack_hardlimit(ch.recvhpack, val)`，从不触碰 `sendhpack`。双方发出的本端 decoder 上限始终为 `default_header_table_size=4096`，所以 peer 的 setting 不应改变本端 decoder hard limit。
- 根因：把 setting 发送者的“我能解码多大”误读成“你将编码多大”，颠倒了 HPACK 独立方向。
- 建议解法：收到 setting 时更新 `ch.sendhpack` 的 encoder maximum，并让 encoder 在下一 field block 开头发出 RFC 7541 要求的 dynamic table size update；`recvhpack` hard limit 只能由本端广告值/配置决定。不要简单把当前调用换对象后忽略 size-update wire signaling。
- 后续回归条件：修复阶段建立两个独立 HPACK context，分别改变单向 setting 为 0/小值/恢复值；断言只影响该方向 outbound encoding，本端 inbound decoder 仍接受其已广告上限内的 block。配合严格 peer 验证 table-size update、ACK 时序和 connection `COMPRESSION_ERROR`。本轮不新增测试代码。

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
- 2026-08-06：确认内置 Lua 的 base-16 转换会让超大 chunk-size 按机器字长回绕，其中 `2^64` 在当前配置下成为 last-chunk 0，记录为 `HTTP1-005`。
- 2026-08-06：trailer 接收侧独立存储符合规范；发送侧可原样生成禁止字段且 API 无法自动预告 trailer 名称，记录为 `HTTP1-006`。
- 2026-08-06：确认标准 HTTP/1 listener 没有行、字段集合或解析 deadline 上限，底层默认无 buffer limit，未认证连接可持续增长内存，记录为 `HTTP1-007`。
- 2026-08-06：开始 RFC 6455 静态 review；确认服务端 opening handshake 的多数必需条件可缺失或被非 token 子串绕过，记录为 `WS-001`。
- 2026-08-06：确认 WebSocket client 只验证 101 status，完全不核对 Upgrade/Connection/Accept 及协商结果，记录为 `WS-002`。
- 2026-08-06：确认 frame reader 忽略 RSV/canonical length/63-bit/control 限制，writer 又在 125 和 65535 边界生成非最短编码，记录为 `WS-003`；mask 方向校验符合。
- 2026-08-06：确认 continuation 可脱离 fragmented message，进行中又允许新 data start；合法 control 穿插保留 stash 的路径符合，状态偏离记录为 `WS-004`。
- 2026-08-06：确认 WebSocket 没有 frame/message 大小或读取 deadline，上层无配置入口，单帧与无限 fragments 均可造成内存耗尽，记录为 `WS-005`。
- 2026-08-06：确认 text message 与 Close reason 的收发均无 UTF-8 校验，fragmented text 也没有完整消息验证，记录为 `WS-006`。
- 2026-08-06：确认 Close payload/status 无校验且没有 CLOSING 状态，主动 close 发帧后立即断 TCP，记录为 `WS-007`；ping/pong 依据文档属于应用显式响应契约。
- 2026-08-06：确认 client mask 与握手 nonce 使用 time-seeded、小写字母弱随机源，mask 仅 26^4 且可预测，记录为 `WS-008`；单帧并发写的发送边界静态核对符合。
- 2026-08-06：进入 HTTP/2 RFC 9113 静态 review；确认 server 显式发送 ENABLE_PUSH=0 合法，但 client 会接受规范禁止的 server 值 1 并继续连接，记录为 `H2-001`。
- 2026-08-06：确认通用 frame reader 会把所有类型的 0x08 都解释为 PADDED，未按 RFC 忽略 frame-type 未使用 flag，记录为 `H2-002`。
- 2026-08-06：确认 HTTP/2 接收方向没有剩余 connection/stream window，超出已广告 credit 的 DATA 仍会无条件进入 recvbuf，记录为 `H2-003`。
- 2026-08-06：确认 peer 的 HEADER_TABLE_SIZE 被错误应用到 `recvhpack` 而非 `sendhpack`，双向独立 HPACK context 发生颠倒，记录为 `H2-004`。
