# Silly `net` 全量审计记录

> 状态：两轮全量纯静态审计、`cluster`三轮专项及第三轮 HTTP/2、gRPC、etcd、MySQL、Redis 重点查漏已完成
> 审计日期：2026-08-06 至 2026-08-12
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

原完成标准包含针对性动态验证；2026-08-06 用户明确要求停止新增重现代码和故障注入，改为优先完成静态review。因此本轮完成口径调整为：所有范围完成静态调用链、正常/失败状态机、所有权、资源上限、现有测试缺口及协议依据审查；已有动态证据保留，新的畸形输入、并发barrier、独立peer互操作和版本矩阵列入修复阶段。不能把仍依赖未验证前提的疑点写成已确认缺陷。

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

HTTP/1 审计清单（状态：首轮静态核对完成；修复阶段补独立peer与畸形输入）：

- start-line/field 的 octet parsing、CRLF、bare CR/LF、前导空行、非法 whitespace、obs-fold。
- method 大小写、四种 request-target、空 path、Host 缺失/重复/非法、absolute-form 权威信息。
- field-name token、大小写、重复字段保序与合并规则、Set-Cookie 特例、header/line/URI 上限。
- body-length precedence：HEAD、1xx/204/304、CONNECT、Transfer-Encoding、Content-Length、close-delimited。
- 重复 Content-Length 是否全部合法且一致；TE+CL、非 final chunked、非法 transfer-coding 是否拒绝并关闭，避免 request smuggling。
- chunk size/extension/trailer 语法、溢出、禁止 trailer 字段、不完整消息、过早 EOF。
- keep-alive、Connection token、hop-by-hop 字段、pipelining、重试安全性、半关闭、TLS close。
- Expect: 100-continue、interim responses、Upgrade、WebSocket 切换后的剩余 buffer 所有权。
- 发送端也必须生成规范报文；不能只检查 parser 的宽容度。

HTTP/2 + HPACK 审计清单（状态：首轮静态核对完成；修复阶段补独立peer与畸形输入）：

- client connection preface、首个 SETTINGS、ACK payload、设置值范围与重复设置。
- 9-byte frame header、length/stream-id/reserved bit、MAX_FRAME_SIZE、未知 frame、固定长度 frame。
- stream-id 单调与奇偶、idle/open/half-closed/closed 状态转换、frame 对状态的合法性、错误作用域。
- HEADERS/PUSH_PROMISE/CONTINUATION 的连续性、END_HEADERS/END_STREAM、padding/priority 长度校验。
- pseudo-header 必须在普通字段前、唯一性和必需集合；小写 field name；禁止 connection-specific 字段；`te` 仅允许 `trailers`。
- DATA/content-length 一致性；stream/connection flow-control、31-bit window、WINDOW_UPDATE 0/overflow、公平性与阻塞解除。
- RST_STREAM、GOAWAY last-stream-id、重试边界、PING、并发流限制和已关闭流的晚到帧。
- HPACK integer/Huffman 解码溢出、EOS/填充校验、索引 0/越界、动态表更新位置与上限、COMPRESSION_ERROR。
- 限制解压后 header list、动态表、并发流、待处理 body，防止内存/CPU 放大。

WebSocket 审计清单（状态：1.0封板静态复核完成；修复阶段补独立peer与畸形输入）：

- HTTP/1.1 GET upgrade、Upgrade/Connection token 列表及大小写、version 13、key 必须解码为 16 bytes、Accept 计算。
- Origin、subprotocol 必须来自客户端候选、extension 协商；未协商 RSV 位必须拒绝。
- 客户端帧必须使用不可预测的 32-bit mask；服务端必须拒绝未 mask 客户帧；客户端必须拒绝被 mask 的服务端帧。
- opcode/RSV、最短长度编码、64-bit 长度最高位、实现大小上限和整数/内存溢出。
- fragmentation 顺序、continuation 规则、允许控制帧穿插；控制帧必须 FIN 且 payload ≤125。
- text message 与 close reason 的完整 UTF-8 验证；close code 合法范围、payload 不能只有 1 byte。
- ping/pong payload、close handshake、收到协议错误后的 close code、TCP 关闭 deadline。
- 若不实现 RFC 8441 或 permessage-deflate，要明确为“不支持且不协商”，而不是错误宣称符合。

gRPC 审计清单（状态：首轮静态核对完成；修复阶段补独立 peer 互操作）：

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
| RFC9112-6.2-TECL-SEND | MUST NOT | `lualib/silly/net/http/h1.lua:342-365,387-438,562-577,761-798` | client/server sender | 偏离 | writer原样输出TE与CL；因CL优先，正文又按固定长度直写而不生成chunk framing | 无sender拒绝TE+CL及零字节输出覆盖 | HTTP1-016 |
| RFC9110-15.3.6-205-NO-CONTENT | MUST NOT | `lualib/silly/net/http/h1.lua:94-100,524-552,761-770` | client/server | 偏离 | bodyless判定漏掉205；server可发送content，client对无framing的合法205改为读到EOF | 无205 response覆盖 | HTTP1-017 |
| RFC9110-6.4.1-NO-CONTENT-H2 | MUST NOT | `lualib/silly/net/http/h2.lua:938-1025,1177-1204,1446-1497` | client/server | 偏离 | H2只跳过部分Content-Length校验，仍允许并接收HEAD/204/205/304的DATA content | 无H2 no-content DATA覆盖 | H2-031 |
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
| RFC8305-3/4-CONNECT-RACING | SHOULD | `lualib/silly/net/websocket.lua:292-323`; `lualib/silly/net/dns.lua:588-654` | client | 偏离 | hostname 固定单次 A lookup 且只连接首个 IPv4 地址，没有 AAAA 或多地址 fallback | 单地址正常连接无法覆盖 IPv6-only、首候选失败或双栈竞速 | WS-009 |
| WS-CONNECT-DEADLINE | safety | `lualib/silly/net/websocket.lua:292-336`; `lualib/silly/net/tcp.lua:190-210`; `lualib/silly/net/tls.lua:282-323`; `lualib/silly/net/http/h1.lua:512-553,604-629` | client | 偏离 | opening handshake 没有 timeout/cancel 配置，且未向底层已有的 timeout 入口传递预算 | 正常本机连接只覆盖即时成功/拒绝，不能证明 silent peer 下有界返回 | WS-010 |
| RFC6455-FRAME-WRITE-ATOMICITY | safety | `lualib/silly/net/websocket.lua:104-127,179-213`; `lualib/silly/net/tcp.lua:307-315`; `src/flipbuf.h:30-51`; `src/socket.c:1614-1659` | client/server | 符合 | 单次 frame 先组装为完整 string，再以一个 TCP send op 入带锁队列；Lua 路径不 yield，未发现并发调用导致帧内交错 | 现有 50-client stress 不是同 socket 并发，但静态原子边界成立 | — |
| RFC9113-6.5.2-ENABLE-PUSH-ROLE | MUST | `lualib/silly/net/http/h2.lua:1211-1278,1500-1537,1651-1710` | client recipient | 偏离 | client/server 共用 `frame_settings`；收到值 1 时只设 `ch.enablepush=true`，没有识别发送方是 server 并发送 `PROTOCOL_ERROR`。server 发送值 0 符合 RFC，不属于偏离 | 现有测试只覆盖双方发送值 0，没有 server→client 值 1 | H2-001 |
| RFC9113-4.1-UNUSED-FLAGS | MUST | `lualib/silly/net/http/h2.lua:270-307` | client/server recipient | 偏离 | `read_frame` 对任意 frame type 的 flag 0x08 都执行 padding 解析；该位在 SETTINGS/PING 等类型未定义，本应忽略，却会删除 payload 字节或触发错误 | 现有测试没有在非 padding frame 上设置 unused flag | H2-002 |
| RFC9113-6.1/6.2-PAD-LENGTH-REQUIRED | MUST | `lualib/silly/net/http/h2.lua:268-307,1177-1205,1446-1499,1562-1648` | client/server recipient | 偏离 | payload长度为0时完全跳过PADDED解析；缺失强制Pad Length字段的DATA可被当作合法空DATA并用END_STREAM结束消息 | 现有测试没有zero-length PADDED DATA/HEADERS或错误作用域断言 | H2-041 |
| RFC9113-5.2/6.1/6.9-RECV-FLOW-CONTROL | MUST/security | `lualib/silly/net/http/h2.lua:151-207,239-307,479-482,502-542,757-771,1177-1204` | client/server recipient | 偏离 | 不维护receive-window remaining，超额DATA仍缓存；padding又在记账前被剥离，合法padded DATA消耗的credit永不完整回补 | 现有测试只覆盖无padding守规发送方和正常1 MiB消息，没有超window或padding耗尽 | H2-003 |
| RFC9113-6.5.2-HEADER-TABLE-DIRECTION | MUST | `lualib/silly/net/http/h2.lua:151-170,239-263,1211-1278` | client/server | 偏离 | 收到 peer 的 HEADER_TABLE_SIZE 后错误地 hard-limit `recvhpack` decoder；该 setting 描述 peer decoder 的上限，应约束本端 `sendhpack` encoder | HPACK 单测只同时修改 encoder/decoder；HTTP/2 测试没有非默认 peer setting | H2-004 |
| RFC7541-4.2/6.3-TABLE-SIZE-UPDATE | MUST | `luaclib-src/lhttp.c:246-260,489-548,782-791` | HPACK encoder | 偏离 | `hardlimit` 只改本地 limit/evict；`pack` 不保存或编码 pending dynamic table size update，下一 header block 不会以 0x20 update 开头 | Test 12 同时手改 encoder/decoder，Test 15 的 decoder 保持较大表；都没有断言 wire update | HPACK-001 |
| RFC9113-5.1.2/6.5.2-MAX-CONCURRENT-DIRECTION | MUST | `lualib/silly/net/http/h2.lua:151-160,239-263,618-659,1211-1278,1555-1648` | server recipient | 偏离 | server 收到 client setting 后覆盖用于限制 inbound request 的 `ch.streammax`；client setting 只限制 server 发起的 streams | 现有双方恰好都发送 100，没有非对称/运行时变更覆盖 | H2-005 |
| RFC9113-6.3-PRIORITY-SIZE-SCOPE | MUST | `lualib/silly/net/http/h2.lua:1281-1310` | client/server recipient | 偏离 | PRIORITY payload 非 5 bytes 时调用 connection `GOAWAY(FRAME_SIZE_ERROR)`；规范要求 stream error | 现有测试没有 malformed PRIORITY 或错误作用域断言 | H2-006 |
| RFC9113-4.2/6.8-GOAWAY-MIN-SIZE | MUST | `lualib/silly/net/http/h2.lua:1357-1367` | client/server recipient | 偏离 | GOAWAY handler 只检查 stream-id，完全忽略 payload；少于强制 8 bytes 的 frame 也被接受，而非 `FRAME_SIZE_ERROR` | 现有测试没有 malformed GOAWAY 长度 | H2-007 |
| RFC9113-6.8-GOAWAY-LAST-STREAM | MUST/reliability | `lualib/silly/net/http/h2.lua:1357-1367,1425-1448`; `lualib/silly/net/http/client.lua:318-390` | client recipient | 偏离 | 合法 GOAWAY 只置 bool，不解析 Last-Stream-ID/error；高编号未处理 streams 不结束/不标 retryable，高层默认 readall 可无限等待 | 现有 Test 20/26 是本端主动 close，不覆盖 peer graceful GOAWAY 与在途 streams | H2-008 |
| RFC9113-8.1.1/8.2/8.3-RESPONSE-FIELDS | MUST | `lualib/silly/net/http/h2.lua:367-384,1441-1500` | client recipient | 偏离 | response/trailer 未验证 pseudo 集合/顺序、lowercase、field syntax 或 connection-specific fields；`:status` 仅 `tonumber`，接受非三位语法 | 现有测试只覆盖本库 server 生成的规范 headers | H2-009 |
| RFC9113-8.1-INTERIM-RESPONSES | MUST | `lualib/silly/net/http/h2.lua:1441-1500,1075-1123` | client recipient | 偏离 | 第一个 HEADERS 无论 1xx/最终都进入 HEADER 并唤醒 waiter；后续 final response 被当 trailer，未实现零到多个 interim→一个 final 的状态 | 现有测试没有 100/103 response | H2-010 |
| RFC9113-8.1-TRAILER-END-STREAM | MUST | `lualib/silly/net/http/h2.lua:1177-1204,1441-1500` | client recipient | 偏离 | final 后的 HEADERS 无论 END_STREAM 都被当 trailer；不终止时后续 DATA 仍被接受并把 TRAILER 状态倒退为 DATA | 现有 trailer 测试只覆盖本库 server 生成的 END_STREAM trailer | H2-011 |
| RFC9113-8.3.1/8.5-CONNECT-PSEUDO | MUST | `lualib/silly/net/http/h2.lua:126-133,386-444,700-738` | client sender/server recipient | 偏离 | client 对 CONNECT 仍发送 scheme/path；server 固定要求 scheme/path 且不要求 authority，正好与 CONNECT mandatory/omitted 集合相反 | 现有 HTTP/2 测试没有 CONNECT | H2-012 |
| RFC9113-10.5/10.5.1-FIELD-LIMITS | SHOULD/security | `lualib/silly/net/http/h2.lua:74-80,314-384`; `luaclib-src/lhttp.c:696-780` | client/server recipient | 偏离 | 只限制 65,535 compressed wire bytes，不累计 uncompressed name+value+32、字段数或单字段大小，也无配置/advertisement | 现有测试没有 indexed expansion、超限并发 field blocks | H2-013 |
| RFC9113-5.1-HALF-CLOSED-REMOTE | MUST | `lualib/silly/net/http/h2.lua:64-70,845-877,1177-1205` | client/server recipient | 偏离 | 已收到 END_STREAM 后再收 DATA 应为该 stream 的 STREAM_CLOSED；当前升级为整连接 GOAWAY(PROTOCOL_ERROR) | 现有测试没有 END_STREAM 后 DATA 与并发 stream 隔离 | H2-014 |
| RFC9113-5.1/6.9-CLOSED-WINDOW-UPDATE | MUST NOT | `lualib/silly/net/http/h2.lua:238-241,1038-1080,1366-1407,1562-1648` | client recipient | 偏离 | client 不记录本端已用 stream-id；完成 stream 移除后，合法 late WINDOW_UPDATE 被误判为 idle 并触发 GOAWAY | 现有测试只覆盖 active stream flow-control，没有 close 后在途 update | H2-015 |
| RFC9113-4.1/6.8-GOAWAY-LAST-ID | MUST | `lualib/silly/net/http/h2.lua:238-241,596-608,1562-1648`; `luaclib-src/lhttp.c:1049-1072` | client/server sender | 偏离 | 无 peer stream 时 last id=-1 被转成 0xffffffff；reserved bit 非零且错误声明最大 Last-Stream-ID，而非 0 | 现有测试未检查 outbound GOAWAY bytes/processed boundary | H2-016 |
| RFC9113-8.1/5.1-RST-AFTER-RESPONSE | MUST NOT | `lualib/silly/net/http/h2.lua:845-877,1038-1123,1336-1351,1446-1499` | client recipient | 偏离 | 完整响应后的RST(NO_ERROR)在对象尚存时覆盖END；对象已回收时又被误判idle并GOAWAY | 现有测试没有response END后两种时序的RST | H2-017 |
| RFC9113-8.1.1/8.2.2/8.3-SENDER-FIELDS | MUST/MUST NOT | `lualib/silly/net/http/h2.lua:700-738,938-1025`; `lualib/silly/net/http/client.lua:318-365`; `luaclib-src/lhttp.c:357-556` | client/server sender | 偏离 | request/response/trailer 在 HPACK 前无 sender validation；可生成 connection-specific/uppercase/非法或重复 pseudo/status fields | 现有测试只验证正常 fields，未检查 outbound malformed block | H2-018 |
| RFC9113-8.1.1/8.2.1-FIELD-VALIDITY | MUST/security | `lualib/silly/net/http/h2.lua:331-447,1562-1648` | server recipient | 偏离 | request validator 未拒绝非法 name bytes/冒号及 value 中 NUL/CR/LF/首尾空白；Content-Length 又用宽松 tonumber | 现有测试没有 generic invalid field octets 或非十进制 length | H2-019 |
| RFC9113-4.3/6.2/6.10-FRAGMENT-SEQUENCE | MUST | `luaclib-src/lhttp.c:883-949`; `lualib/silly/net/http/h2.lua:700-738,1018-1024` | client/server sender | 偏离 | 大于 frame size 的 field block 最后一帧被硬编码为 HEADERS，而非 CONTINUATION+END_HEADERS | 现有测试没有 outbound header block 跨 frame | H2-020 |
| RFC9113-6.9.2-INITIAL-WINDOW-OVERFLOW | MUST | `lualib/silly/net/http/h2.lua:1131-1172,1211-1278` | client/server recipient | 偏离 | SETTINGS initial-window delta 使任一 stream window 超过 2^31-1 时只 RST stream；规范要求 connection FLOW_CONTROL_ERROR | 现有测试没有高 window 后再增 initial setting | H2-021 |
| RFC9113-8.1.1-CONTENT-LENGTH-SCOPE | MUST | `lualib/silly/net/http/h2.lua:845-877,1177-1205,1446-1499,1562-1648` | client/server recipient | 偏离 | DATA 总量与 Content-Length 不符时发送 connection GOAWAY；规范要求对应 stream PROTOCOL_ERROR | 现有测试未验证 mismatch 与并发 stream 隔离 | H2-022 |
| RFC9113-8.1.1-CONTENT-LENGTH-SENDER | MUST/interoperability | `lualib/silly/net/http/h2.lua:176-214,453-495,700-738,805-877,938-1029` | client/server sender | 偏离 | sender 保存任意 Content-Length，却不累计 DATA 或在 END_STREAM 前校验；request/response 均可成功生成声明长度与正文不符的 malformed message | 现有测试只覆盖声明值恰好等于正文长度，没有少发、多发、零body或trailer结束 mismatch | H2-040 |
| RFC9113-5.1.1/5.1.2/8.1.1-REQUEST-ADMISSION | MUST | `lualib/silly/net/http/h2.lua:453-495,845-894,1038-1080,1562-1648` | server recipient | 偏离 | initial HEADERS admission非事务：拒绝可复用id/泄漏quota；early END长度不符在teardown后仍发布并调用handler | 现有malformed tests未检查id/quota/handler隔离 | H2-023 |
| RFC9113-5.1/5.4.2-CLOSED-HPACK | MUST | `lualib/silly/net/http/h2.lua:1038-1080,1446-1499`; `luaclib-src/lhttp.c:692-780` | client recipient | 偏离 | local RST tombstone 固定只留 100 个；淘汰后 late HEADERS 在 HPACK 前直接 GOAWAY，未 minimally process compression state | 现有测试没有 >100 cancel 后 delayed response headers | H2-024 |
| RFC9113-10.5-PROGRESS-LIMITS | SHOULD/security | `lualib/silly/net/http/h2.lua:268-365,1420-1547,1668-1738`; `lualib/silly/net/http.lua:10-45`; `lualib/silly/net/http/client.lua:206-274` | client/server | 偏离 | preface/SETTINGS/ACK/frame body/CONTINUATION 所有 read 均无 progress deadline，配置也无入口 | 现有测试不覆盖 slow preface/frame/header block | H2-025 |
| RFC9113-6.6/8.4-PUSH-DISABLED | MUST | `lualib/silly/net/http/h2.lua:1500-1547` | client recipient | 偏离 | client 广告 ENABLE_PUSH=0 并获 ACK 后仍静默忽略 PUSH_PROMISE；未报 PROTOCOL_ERROR且未处理 HPACK/stream state | 现有测试没有 disabled-push violation | H2-026 |
| RFC7541-5.1-INTEGER-LIMITS | MUST/safety | `luaclib-src/lhttp.c:558-583,613-630,696-771` | HPACK decoder | 偏离 | varint continuation/value 无上限，移位可有符号溢出或超过位宽；unsigned 结果缩成 int 后作为 string pointer/length，未按 decoding error 拒绝 | 现有测试没有超长/溢出/未终止 varint；本轮按要求不新增复现 | HPACK-002 |
| RFC9113-6.5.2/7541-4.2-TABLE-LIMIT-WIDTH | MUST/safety | `lualib/silly/net/http/h2.lua:1211-1278`; `luaclib-src/lhttp.c:22-30,246-260,289-318,782-791` | HPACK client/server | 偏离 | 合法32位SETTINGS_HEADER_TABLE_SIZE未经范围转换写入C int；大值成为负limit，已有动态表时limit减size触发signed overflow/UB | 现有setting测试只使用小值，HPACK resize只覆盖4096→2048 | HPACK-004 |
| GRPC-CALL-AUTHORITY | MUST/interoperability | `lualib/silly/net/grpc/client/conn.lua:49-79`; `lualib/silly/net/http/h2.lua:231-263,700-738,1718-1724`; `luaclib-src/lhttp.c:489-548` | client sender | 偏离 | endpoint 保存的 hostname 只用于 TLS SNI，调用 `h2.newchannel` 时漏传 host；channel 的 authority 为 nil，HPACK sender 经 `luaL_tolstring` 将其编码为字面量 `"nil"` | gRPC 自测只连接不校验 authority 的 Silly server，无法覆盖虚拟主机或严格 peer | GRPC-001 |
| GRPC-CALL-TE-TRAILERS | MUST/interoperability | `lualib/silly/net/grpc/client/service.lua:134-257` | client sender | 偏离 | unary、server-streaming、client-streaming、bidi 四条 request path 均只发送 `content-type`，没有 mandatory `te: trailers` | 自测直连 Silly HTTP/2 server，不经过依赖 TE 判断 trailer 能力的 proxy | GRPC-002 |
| GRPC-CALL-SERVER-VALIDATION | MUST/SHOULD | `lualib/silly/net/grpc/server.lua:8-27` | server recipient | 偏离 | dispatch 仅按 `:path` 查 handler，不校验 POST、gRPC Content-Type 或 TE；非 gRPC Content-Type 也不返回建议的 HTTP 415 | 自测仅由同库 client 发送 POST/application-grpc，且 client 本身缺 TE | GRPC-003 |
| GRPC-MESSAGE-COMPRESSION | MUST | `lualib/silly/net/grpc/helper.lua:16-50`; `lualib/silly/net/grpc/client/service.lua:38-81` | client/server recipient | 偏离 | 任意非零 compressed flag 被统一当 unsupported，未校验 0/1 domain 或 `grpc-encoding`；server 固定回 UNIMPLEMENTED，client 不能稳定映射 INTERNAL | 无 compression、非法 flag、encoding/flag 组合测试 | GRPC-004 |
| GRPC-MESSAGE-SIZE-LIMIT | security | `lualib/silly/net/grpc/helper.lua:6-50`; `lualib/silly/net/http/h2.lua:779-799,1084-1105,1177-1204` | client recipient | 偏离 | 4 MiB cap 仅用于 request；response 按 peer 的 32-bit length 无上限等待并缓存，且持续 WINDOW_UPDATE | 无 oversized response；server-only request cap 不覆盖 client | GRPC-005 |
| GRPC-METHOD-CARDINALITY | MUST | `lualib/silly/net/grpc/registrar.lua:80-190`; `lualib/silly/net/grpc/client/service.lua:56-63,134-176` | client/server | 偏离 | 单 request读第一条即调用handler；单 response raw drain多余bytes；handler返回nil仍发OK零响应，均未验证恰好一条 | 自测只由守规 peer 各发一条且handler总返回对象 | GRPC-006 |
| GRPC-SERVER-PARSE-STATUS | MUST | `lualib/silly/net/grpc/helper.lua:16-50`; `lualib/silly/net/grpc/registrar.lua:17-31,80-228`; `lualib/silly/net/http/h2.lua:1549-1559` | server | 偏离 | unary parse errors end without grpc-status；client/bidi stream read status is ignored and wrapper emits OK；truncated envelope at EOS is mistaken for clean EOF | 无 malformed/truncated protobuf envelope 与 final status 覆盖 | GRPC-007 |
| GRPC-TRAILERS-ONLY-CLIENT | MUST | `lualib/silly/net/grpc/client/service.lua:38-81,164-173`; `lualib/silly/net/http/h2.lua:1441-1500` | streaming client recipient | 偏离 | streaming status helper只查 trailer map；Trailers-Only 的 status 位于 END_STREAM initial header，故真实错误一律变 UNKNOWN；只有 unary 特判 header fallback | 无 streaming immediate-error/Trailers-Only 测试 | GRPC-008 |
| GRPC-HTTP-STATUS-FALLBACK | MUST/interoperability | `lualib/silly/net/grpc/client/service.lua:38-81,134-176`; `lualib/silly/net/http/h2.lua:1463-1487` | client recipient | 偏离 | transport 保存 HTTP status/header，但 gRPC client 不检查 status 或 Content-Type；缺 grpc-status 时不按标准表映射 HTTP错误 | 无 proxy/non-gRPC HTTP response 测试 | GRPC-009 |
| GRPC-STATUS-SYNTAX | MUST | `lualib/silly/net/grpc/client/service.lua:38-53,164-174` | client recipient | 偏离 | `tonumber` 接受空白/符号/hex/指数/小数/前导零；非法形式可成为 OK，parse failure 可返回 nil而非 UNKNOWN | 只覆盖本库生成的 canonical integer status | GRPC-010 |
| GRPC-STATUS-MESSAGE-CODEC | MUST | `lualib/silly/net/grpc/server.lua:8-27`; `lualib/silly/net/grpc/registrar.lua:80-228`; `lualib/silly/net/grpc/client/service.lua:38-53,164-173` | client/server | 偏离 | server 原样发送 message，不做 UTF-8 percent encoding；client原样返回且 unary Trailers-Only 不从 initial header 取 message | 自测错误文本仅简单 ASCII，未覆盖 `%`/Unicode/control/Trailers-Only message | GRPC-011 |
| GRPC-DEADLINE | API/protocol | `lualib/silly/net/grpc/client/conn.lua:49-79,127-155`; `lualib/silly/net/grpc/client/service.lua:12-32,134-257`; `lualib/silly/net/grpc/server.lua`; `lualib/silly/net/grpc/registrar.lua`; `docs/src/en/reference/net/grpc.md:343-397,521-530` | client/server | 偏离 | unary timer在openstream/dial之后才启动；server-stream timer建立后立即取消，另两种无参数，stream read忽略 timeout；不发/收grpc-timeout且handler不可观察deadline | Test 6只覆盖已有连接上的unary response wait | GRPC-012 |
| GRPC-TRANSPORT-STATUS-MAPPING | MUST/interoperability | `lualib/silly/net/http/h2.lua:103-124,563-590,1333-1349`; `lualib/silly/net/grpc/client/service.lua:38-81,134-176` | client recipient | 偏离 | H2 RST/断连只留下文本；gRPC client缺 error-code context和 mapping，统一变 UNKNOWN/raw string | 无 peer RST 各 error code或 connection failure gRPC status 测试 | GRPC-013 |
| GRPC-PROTOBUF-SERVICE-NAME | MUST/interoperability | `lualib/silly/net/grpc/client/service.lua:259-279`; `lualib/silly/net/grpc/registrar.lua:264-290`; `lualib/protoc.lua:498-505,827` | client/server | 偏离 | full path无条件插入 package与点；无 package时值为 nil并经 `%s` 变 `nil`，生成 `/nil.Service/Method`而非 `/Service/Method` | gRPC test proto总是声明 package | GRPC-014 |
| GRPC-CLIENT-PARSE-STATUS | MUST | `lualib/silly/net/grpc/helper.lua:16-50`; `lualib/silly/net/grpc/client/service.lua:38-81,134-176` | client | 偏离 | response envelope/protobuf parse error不生成 INTERNAL；streaming finalizer可被 peer OK trailer覆盖为成功 status | 无 malformed/truncated response message 测试 | GRPC-015 |
| GRPC-STREAM-FINAL-STATUS-API | MUST/API | `lualib/silly/net/grpc/client/service.lua:38-81,95-132`; `docs/src/{en/,}reference/net/grpc.md:521-530` | streaming client | 偏离 | read到EOS后只写未文档化对象字段并返回nil；client-streaming有message时不管最终status仍返回对象，所有路径都不返回文档承诺的error | tests只断言两个OK status字段，没有任何streaming非OK或read错误tuple | GRPC-034 |
| GRPC-HANDLER-EXCEPTION-STATUS | MUST/interoperability | `lualib/silly/net/grpc/registrar.lua:80-228` | server | 偏离 | 四种 wrapper将 application handler抛出异常统一映射 INTERNAL；gRPC library-generated mapping要求 UNKNOWN | 无 handler throw status-code assertion | GRPC-016 |
| GRPC-STATUS-SENDER | MUST | `lualib/silly/net/grpc/registrar.lua:80-228`; `luaclib-src/lhttp.c:489-548` | server sender | 偏离 | application `err.code` 无类型/range/canonical校验，truthy值直接经通用字符串化写 grpc-status；可发送非法文本或error+OK | 自测仅覆盖0与合法常量 | GRPC-017 |
| GRPC-REQUEST-EOS-DATA | MUST | `lualib/silly/net/grpc/client/service.lua:65-70,215-257`; `lualib/silly/net/http/h2.lua:992-1025` | streaming client sender | 偏离 | client/bidi零消息closewrite时pending request header直接带END_STREAM；未发送gRPC要求的空DATA+END_STREAM | tests的client/bidi均先write至少一条 | GRPC-018 |
| GRPC-CLEARTEXT-SCHEME | transport/API | `lualib/silly/net/grpc/server.lua:38-55`; `lualib/silly/net/http/h2.lua:231-262,456-467,1730-1739` | plaintext server | 偏离 | cleartext gRPC listener仍把H2 channel/stream scheme写死为https，与收到的`:scheme: http`及实际TCP安全属性矛盾 | 现有handler不检查stream.scheme，明文自测无法暴露 | GRPC-019 |
| RFC8305-3/4-CONNECT-RACING | SHOULD | `lualib/silly/net/grpc/client/conn.lua:16-29,49-79,127-155`; `lualib/silly/net/dns.lua:588-654` | client | 偏离 | 每个target固定单次A lookup并永久只保存首个IPv4 endpoint，无AAAA或同名多地址fallback | 单地址/IPv4本机自测不能覆盖AAAA-only或首地址故障 | GRPC-020 |
| GRPC-CLIENT-CLOSE-LIFECYCLE | safety/concurrency | `lualib/silly/net/grpc/client/conn.lua:44-117` | client | 偏离 | close不与in-flight newchannel共锁；close返回后迟到建连仍可向已摘除endpoint发布channel并返回stream | 普通串行close无法覆盖connect yield窗口 | GRPC-021 |
| GRPC-TLS-ALPN-H2 | MUST/interoperability | `lualib/silly/net/grpc/client/conn.lua:49-79`; `lualib/silly/net/grpc/server.lua:38-55`; `lualib/silly/net/tls.lua:198-204,250-258,464-466`; `lualib/silly/net/http/client.lua:243-279` | TLS client/server | 偏离 | 双方只配置h2 ALPN但不核对最终选择；无ALPN/非h2会话仍直接进入H2 handshake/parser | 同库双方总提议h2，不能覆盖legacy/misconfigured TLS peer | GRPC-022 |
| GRPC-LISTEN-CONFIG | API/security | `lualib/silly/net/grpc/server.lua:29-55`; `lualib/silly/net/tls.lua:326-365`; `lualib/silly/net/tcp.lua:152-175`; `docs/src/en/reference/net/grpc.md:146-166` | server | 偏离 | 公开ciphers/backlog/alpnprotos配置被adapter静默丢弃，TLS policy、listen queue与声明的ALPN override均不生效 | 默认配置自测不会检查实际ctx/listener option | GRPC-023 |
| GRPC-ERROR-TRAILERS | MUST | `lualib/silly/net/grpc/server.lua:8-26`; `grpc/helper.lua:16-50`; `http/h2.lua:704-738,992-1025` | server sender | 偏离 | request超限/压缩错误在initial response后再次respond，final field section携带第二个`:status`而非合法trailers | 无超限/compression error field-section序列测试 | GRPC-024 |
| PROTOBUF-COMPLETE-CONSUMPTION | MUST/security | `luaclib-src/pb.c:1902-1924,1943-1988`; `luaclib-src/pb.h:410-607` | client/server recipient | 偏离 | message/map循环无法区分EOF与截断tag，unknown skip失败被忽略，map unknown value不skip | 无malformed/unknown map与完整消费测试 | GRPC-025 |
| GRPC-TARGET-FAILURE-ISOLATION | reliability | `lualib/silly/net/grpc/client/conn.lua:82-155` | client | 偏离 | constructor要求所有target DNS同时成功，picker机械选择单endpoint且dial失败不尝试健康target | 单target正常/DNS失败测试不能覆盖一坏一好 | GRPC-026 |
| PROTOBUF-STRUCTURE-DEPTH | security | `luaclib-src/pb.c:1595-1660,1737-1777,1853-1988` | client/server | 偏离 | encode/decode embedded message均无depth/cycle budget，Lua stack check不保护C stack | 无递归schema、深度边界或cycle测试 | GRPC-027 |
| PROTOBUF-STRING-UTF8 | MUST/interoperability | `luaclib-src/pb.c:406-533` | client/server | 偏离 | string与bytes共用裸字节codec，收发均不执行UTF-8不变量 | 只有ASCII string，无Unicode边界/非法序列 | GRPC-028 |
| PROTOBUF-PROTO2-REQUIRED | MUST/compatibility | `lualib/protoc.lua:354,474-493`; `luaclib-src/pb.c:1388-1405,1691-1701`; `pb.h:322-333` | client/server | 偏离 | descriptor把required/optional折叠成同一non-repeated状态，收发无法验证required presence | 测试全部proto3 | GRPC-029 |
| GRPC-SERVER-SHUTDOWN | lifecycle | `lualib/silly/net/grpc/server.lua:38-55`; `lualib/silly/net/http/h2.lua:1549-1740` | server | 偏离 | server对象只拥有listener，close后既有H2 channel仍可无限创建RPC | teardown先关client，未覆盖旧channel新RPC | GRPC-031 |
| GRPC-LENGTH-PREFIXED-MESSAGE | MUST | `lualib/silly/net/grpc/helper.lua:6-67`; `lualib/silly/net/http/h2.lua:1084-1105,1177-1204` | client/server | 基础格式符合 | writer使用1-byte flag+4-byte big-endian length；reader exact-size读取可跨任意DATA边界重组。压缩语义、上限、parse status另见GRPC-004/005/007/015 | 正常测试覆盖unary/三种streaming与1 MiB message | — |
| GRPC-PROTOBUF-ENCODE-FINALIZE | API/safety | `lualib/silly/net/grpc/helper.lua:53-67`; `grpc/client/service.lua:12-23,134-213`; `grpc/registrar.lua:83-191`; `luaclib-src/pb.c:1597-1777` | client/server sender | 偏离 | `pb.encode`类型/schema错误直接抛Lua异常；多个wrapper没有protected encode/finalizer，异常可绕过timer取消、grpc-status及H2 stream回收 | 现有测试只编码字段类型正确的对象，没有错误输出、请求对象或资源归零断言 | GRPC-032 |
| PROTOBUF-SCALAR-DOMAIN | schema/data integrity | `luaclib-src/pb.c:316-359,406-470,1616-1668`; `lualib/silly/net/grpc/helper.lua:53-67` | client/server sender | 偏离 | 32位整数静默取低32位、signed/unsigned 64位不查范围，enum接受fractional number并转整数，bool把任意truthy值编码为true | gRPC测试只用小范围int32和正确Lua类型，没有边界外值或encode→decode等值断言 | GRPC-033 |
| PROTOBUF-ONEOF-INVARIANT | MUST/data integrity | `luaclib-src/pb.c:1304-1307,1728-1757,1943-1973`; `lualib/silly/net/grpc/helper.lua:16-67` | client/server | 偏离 | decoder遇到新oneof member只更新case名、不清除旧member；encoder也会发送table中全部members，破坏API层“至多一个/last wins”不变量 | gRPC schema与测试完全没有oneof | GRPC-035 |
| PROTOBUF-SINGULAR-MESSAGE-MERGE | MUST/data integrity | `luaclib-src/pb.c:1869-1876,1943-1973`; `lualib/silly/net/grpc/helper.lua:16-50` | client/server recipient | 偏离 | 同一singular embedded-message field重复出现时每次新建table并整块覆盖，未按protobuf规则递归merge | gRPC测试没有重复singular field或拆分embedded message | GRPC-036 |
| PROTOBUF-PACKED-COMPAT | MUST/interoperability | `luaclib-src/pb.c:1884-1899,1926-1941`; `luaclib-src/pb.h:1697-1701` | client/server recipient | 偏离 | descriptor声明`packed=false`的repeated numeric收到合法packed wire时走普通type check并抛mismatch；只接受声明格式，未实现parser双格式兼容 | gRPC测试proto3 numeric为默认packed但没有proto2/unpacked descriptor或反向wire格式 | GRPC-037 |
| PROTOBUF-PROTO2-GROUP | compatibility | `lualib/protoc.lua:363-394,444-495,637-650`; `luaclib-src/pb.c:406-483,486-535,1644-1668`; `luaclib-src/pb.h:82-109` | client/server | 偏离 | bundled parser拒绝proto2 group语法；外部descriptor的TYPE_GROUP虽可表示，native encoder/decoder均落入unknown type | 无proto2 group schema或wire测试 | GRPC-038 |
| GRPC-NORMAL-RESPONSE-TRAILERS | MUST | `lualib/silly/net/grpc/registrar.lua:80-228`; `lualib/silly/net/http/h2.lua:992-1025` | server sender | 正常路径符合 | normal success/application error在initial response headers后以最终HEADERS+END_STREAM发送grpc-status；parse/exception/status-code偏离另行编号 | 现有正常与application error用例覆盖 | — |
| GRPC-CUSTOM-METADATA | optional/API | `lualib/silly/net/grpc/client/service.lua`; `lualib/silly/net/grpc/registrar.lua`; `docs/src/{en/,}reference/net/grpc.md` | client/server | 能力缺口 | API没有传入/取出initial/trailing metadata或call context的入口，也未实现`-bin` Base64；认证/trace/tenant服务无法正常使用 | 无metadata tests | GRPC-030 |
| GRPC-AUTOMATIC-RETRY | safety | `lualib/silly/net/grpc/client/conn.lua:82-100`; `lualib/silly/net/grpc/client/service.lua:134-257` | client | 不适用/安全 | 实现没有automatic retry，不会无条件重放非幂等RPC；GOAWAY/REFUSED_STREAM可靠性与status mapping缺口见H2-008/GRPC-013 | 无retry tests | — |

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

### 3.3 远端 `cluster` 分支专项复核

2026-08-09至2026-08-12继续只读审阅`origin/cluster@0f2c8773842edb818c1aac74ade3f975d1cbd068`；2026-08-12已重新查询远端，尖端未变化。该分支与`master`的共同祖先为`295f30b879e5c29e12ab2ac1325d8b80abe8fb53`，相对共同祖先只有1个独有提交且落后`master` 3个提交，因此专项复核以分支自身代码和共同祖先diff为基线，没有切换当前工作树。

既有`CLUSTER-001`至`CLUSTER-015`逐项状态、64位/raw-string协议改造和分支独有问题记录在[`CLUSTER_BRANCH_REVIEW.md`](CLUSTER_BRANCH_REVIEW.md)。其中`CLUSTER-003`已由nil guard修复；`CLUSTER-008`的lazy-connect触发路径因eager connect消除；另确认4项只属于该分支的问题：`CLUSTER-B001`（P2，eager connect无deadline）以及3项P3文档/测试回归（`CLUSTER-B002`至`B004`）。分支独有编号不计入本报告以master为基线的199项统计。本轮没有运行cluster测试、建立peer、发送frame或新增重现代码。

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

### CORE-006 — P2 — timer 大时间跳变被窄化为 `int`，可崩溃或长期错时

- 状态：已确认；整数范围、时钟单位与确定性控制流推导。本阶段不通过长期SIGSTOP/虚拟机快照做动态复现。
- 位置：`src/timer.c:366-381,501-539`；timer线程消费返回值在`src/engine.c:34-48`；默认分辨率在`src/silly_conf.h:53-58`。
- 触发：timer线程连续两次`timer_update()`间的monotonic clock差超过`INT_MAX`毫秒（约24.8天），例如进程长期SIGSTOP、调试冻结、支持该语义的平台休眠或虚拟机快照/迁移造成的大时钟步进。较小但很大的delta也会触发逐tick catch-up。
- 影响：64位`time-lasttick`先赋给`int delta`，结果超出范围时实现定义；常见平台会成为负数并在assert build触发`assert(delta>0)`终止进程，NDEBUG下则可能计算负`ticks/tickstep`并以无符号atomic add形成巨大跳变。若低32位恰为小正数，实现只推进错误的一小段时间，既有timer可额外延迟约49.7天的整数倍。尚未越界时，代码也按10ms逐tick循环，24天量级需要约2.1亿次`update_timer`，恢复后长时间占满timer线程。
- 证据：`ticktime()`返回`uint64_t`毫秒，`lasttick`也是atomic uint64；`timer_update`却把`delta/ticks/tickstep/i`全部声明为int。`tickstep=ticks*TIMER_RESOLUTION`还有第二处signed overflow边界，随后被传给uint64 atomic add。`TIME_DELAY_WARNING`仅打印日志，不限制或安全处理大delta。顶部`time < lasttick + resolution`提前return也使后面的rewind日志分支在正常无溢出范围内不可达。
- 根因：64位monotonic时间域与32位循环/返回值混用，并假定timer线程不会长时间停止；分层时间轮已有级联结构，但catch-up仍按每个基础tick线性迭代。
- 建议解法：用`uint64_t`计算delta/ticks/tickstep，只在最终sleep已证明为`0..TIMER_RESOLUTION`时转int；显式处理rewind。为大delta实现有界fast-forward/cascade策略，在保持32位jiffies wrap语义下直接定位并触发到期节点，或每轮设catch-up预算且保证过期timer最终及时交付，不能用signed溢出截断时间。
- 回归测试：修复阶段注入可控clock，覆盖resolution边界、`INT_MAX`前后、`UINT32_MAX`前后、49.7天倍数、rewind和jiffies wrap；assert/NDEBUG均不崩溃、不出现数十亿循环，已到期timer恰好触发一次，未来timer保持正确相对顺序。当前不新增长暂停复现。

### CORE-007 — P2 — flip buffer 的 32 位有符号容量扩展可溢出并破坏内存

- 状态：已确认；整数类型、扩容表达式与两个生产/消费路径静态推导。本轮不堆积大队列、不运行内存压力复现。
- 位置：通用数组的字段和扩容在`src/array.h:10-35`；双槽带锁封装在`src/flipbuf.h:9-51`；socket operation生产/消费在`src/socket.c:1730-1804`及各公开异步API；timer command生产/消费在`src/timer.c:300-339,475-499,542-547`。
- 触发：socket线程或timer线程长期停滞，而应用侧继续排队足够多的send/close/read-enable/timer命令，使单个writing slot接近`INT32_MAX` bytes。这个条件可由本地调用压力触发；远端事件只能间接延长消费者停滞，本报告不把它表述为独立远程攻击面。
- 影响：`a->size + size`、`a->cap * 2`和循环内`new_cap *= 2`均在signed `int`域执行且无检查。超过表示范围后属于C未定义行为；典型结果是负capacity被转成巨大`size_t`交给`mem_realloc`、扩容判断失效后继续`memcpy`越界，或扩容循环不终止，导致崩溃、挂死或heap破坏。
- 证据：`struct array`把`cap/size`定义为`int32_t`，`array_write`的输入与临时`new_cap`又是`int`；它先执行可能溢出的加法和倍增，再把结果隐式转换给接受`size_t`的allocator。`flipbuf_write`只有mutex互斥，没有总量上限、backpressure或checked arithmetic；socket op附带的payload不在buffer内，因此大量固定尺寸op仍可持续推高该数组。
- 根因：把可累计的字节计数当作小型容器的signed整数，并默认consumer总能及时清空；增长算法没有表示上限或队列预算。
- 建议解法：将size/cap/write length统一为`size_t`，在加法和倍增前检查`SIZE_MAX`与项目硬上限；达到可配置的pending-op预算时返回明确错误或施加backpressure。allocator失败也必须保留原pointer并向caller传播，不能继续copy。
- 回归测试：修复阶段用小型可配置cap或allocator stub覆盖恰好满、加一、倍增越界、hard-limit和allocation failure；分别验证socket/timer caller得到有限错误且已有命令仍可安全消费。当前不生成或运行这些压力条件。

### NET-001 — P2 — listener 关闭与已排队 ACCEPT 竞态会遗留孤儿连接

- 状态：已确认；worker消息顺序、callback table生命周期与socket ownership的确定性推导。本阶段不新增accept/close barrier复现。
- 位置：accept/listen callback表与close在`lualib/silly/net.lua:37-81,149-179`；TCP/TLS listener包装在`lualib/silly/net/tcp.lua:155-187`、`lualib/silly/net/tls.lua:338-386`；C accept创建、注册并上报在`src/socket.c:805-849,664-679`。
- 触发：socket线程成功accept并已将ACCEPT消息排入worker queue，但在该消息被Lua dispatch前，另一条已就绪task关闭listener；`net.close`立即清空`accept_callback[listenid]`，稍后ACCEPT handler读取到nil。
- 影响：handler执行`assert(cb, listenid)`后异常退出；accepted socket已经在C pool与poller中注册，却没有继承data/close callback、没有创建TCP/TLS对象，也没有执行`socket_close(fd)`。连接可继续占用OS fd、socket slot及接收资源，客户端输入随后只会被底层读取再由缺失callback路径释放；关闭服务时的一批并发accept可形成持续到进程退出的资源泄漏。
- 证据：`exec_accept`先`pool_alloc/add_to_sp`，再把accepted sid和listener sid写入消息；listener关闭不会遍历或拥有子连接。Lua `M.close`在异步C close完成前同步清空三个callback table；ACCEPT callback对缺失listener callback只有assert，没有关闭消息携带的accepted fd。worker中的Lua异常会被记录并关闭该callback coroutine，但没有通用socket回滚。
- 根因：listener callback registration被同时当作“是否仍应交付accept”和accepted socket的唯一初始化依据；事件snapshot与listener生命周期之间没有late-event处理策略。
- 建议解法：ACCEPT handler发现listener已关闭/代际不匹配时必须直接调用底层`socket_close(fd)`并返回，不能assert；正常路径应先建立accepted fd的最小close ownership，再调用用户callback。更完整地让C accept event携带listener generation并在close时定义drain/reject边界，所有late accept都走显式拒绝清理。
- 回归测试：修复阶段用barrier让C层完成accept/report后关闭listener、再dispatch消息；断言无Lua异常，accepted fd立即关闭，callback表、pool slot、连接计数和open-fd恢复基线。TCP与TLS listener都覆盖。当前不新增并发复现。

### NET-002 — P2 — raw data callback 异常会永久泄漏已转移的接收 payload

- 状态：已确认；C message unpack、Lua callback异常处理与free ownership的确定性推导。本阶段不新增故意抛错复现。
- 位置：C消息解包/释放在`src/socket.c:373-394,602-635,697-728`；Lua dispatch在`lualib/silly/net.lua:211-237`；task异常路径在`lualib/silly/task.lua:47-64`；公开消费函数在`luaclib-src/lnet.c:323-339`和`luaclib-src/adt/lbuffer.c:411-446`；所有权文档在`docs/src/reference/net.md:375-445`。
- 触发：使用公开低层`silly.net` API时，TCP/UDP `event.data`在调用`net.tostring(ptr,size)`、`c.free(ptr)`或把pointer成功交给buffer之前抛出Lua错误；例如业务parser、assert或参数检查先失败。连接无需关闭，后续每个data callback都可重复触发。
- 影响：每条消息的网络payload永久泄漏；若异常由特定远端输入触发，peer可在连接存活期间重复发送并持续增加进程内存。task框架会记录异常并关闭callback coroutine，但既不知道pointer存在，也不关闭对应socket，因此不会阻止重复泄漏。
- 证据：`tcpdata_unpack/udpdata_unpack`在把lightuserdata压入Lua栈后立即将`md->ptr=NULL`，所以worker随后调用message free时只释放message envelope。`net.lua`仅在callback不存在时显式`c.free(ptr)`；存在callback时直接`task_resume`且忽略其false/error返回。真正释放只发生在用户调用`tostring/free`或buffer最终销毁其已接管node后，callback提前异常时没有任何owner。
- 根因：裸lightuserdata采用隐式、一次性的ownership transfer，却没有RAII/finalizer或异常边界；dispatcher无法判断callback是尚未接管、已经接管还是已经释放payload。
- 建议解法：把接收payload包装为full userdata/opaque buffer handle并附`__gc/__close`，消费或转移时原子清空其owner；Lua callback异常退出后未消费payload由finalizer释放。若保留裸pointer API，则dispatcher必须以受保护调用配合显式take/consume协议，并在异常时关闭socket，不能盲目finally-free造成已转移后的double-free。
- 回归测试：修复阶段让TCP/UDP callback分别在消费前、消费后、buffer接管后抛错；断言payload各释放恰好一次、无泄漏/double-free，异常策略会阻止同连接无限重复。ASan/LSan与Silly allocator计数均回基线。当前不新增异常触发。

### NET-003 — P1 — `multipack` 裸引用计数可提前释放仍在异步发送的共享缓冲区

- 状态：已确认；native refcount、send failure ownership与公开API契约的确定性静态推导。本轮不调用multicast或制造失效socket。
- 契约：公开`net.multipack(data, fanout)`以预期接收者数初始化共享buffer，随后每个`net.tcpmulticast`异步send完成时递减一次；一个可安全复用的API必须拒绝非法fanout，并保证失败/重试不会让调用方在已释放pointer上继续操作。裸handle不能在没有generation/ref acquisition的情况下被任意重复提交。
- 位置：共享header、`multifinalizer`与`lmultipack/lmultifree`在`luaclib-src/lnet.c:17-78`；`tcpmulticast`入口在`:199-220`；底层send同步失败立即调用finalizer在`src/socket.c:1614-1629`，异步错误/完成释放在`:396-450,1118-1161,1642-1660`；公开导出和文档在`lualib/silly/net.lua:45-54`及`docs/src/{en/,}reference/net.md:153-169`。
- 触发：以`fanout=1`创建pack，第一次向已关闭sid发送并收到`false,err`后按常规失败语义重试另一个sid；或声明fanout小于实际`tcpmulticast`调用数、重复提交同一pointer。反向地，fanout为0/负数/大于实际终局调用数会进入泄漏路径。
- 影响：同步失败仍执行`multifinalizer`，fanout为1时已释放整块header/data；调用方仍持有原lightuserdata且返回值/文档没有说明失败会消费引用，重试把悬空pointer交给异步socket线程，形成heap use-after-free、相邻内存发送、double/invalid free或崩溃。多个已排队send超过fanout时，第N个完成也会在其他wlist仍引用同一data时释放。零/负数被截成`uint32_t`后首次decrement下溢，过大或少发则永久泄漏。
- 证据：`lmultipack`把未经范围验证的Lua integer先存入C `int refcount`，再直接赋给`uint32_t hdr->ref`；返回的是无生命周期信息的lightuserdata。`multifinalizer`仅做atomic decrement并在结果为0时free，不检测原值0或重复消费。`socket_tcp_send`遇到invalid/zombie sid在返回`-EXCLOSED`之前已经调用传入finalizer；成功操作的所有wlist也各自保存相同pointer/finalizer。因此引用数与实际finalizer调用数只要不完全相等，就确定性进入提前释放或泄漏。
- 根因：调用方提供的“未来异步使用次数”被当作buffer唯一所有权模型，handle本身没有不可伪造type、alive状态或每次send的ref acquire；失败是否消费引用也没有协议化。lightuserdata让Lua/Native双方都无法阻止retry、重复发送或use-after-free。
- 建议解法：改为full userdata/opaque multicast buffer，内部保存alive与原始size；每次`tcpmulticast`在验证handle和sid后原子acquire一个独立send reference，operation终局release，Lua handle的GC/close只释放owner reference。这样无需调用方预报fanout。若保留旧API，至少要求`1 <= fanout <= UINT32_MAX`、拒绝重复超过配额、明确失败消费语义并使handle终局失效，但裸pointer仍难以安全验证。size也必须来自handle，不能由调用方再次声明。
- 回归测试：修复阶段覆盖fanout 0/负/边界、closed sid后retry、少发、多发、重复fd、发送中GC/close和不同完成顺序；ASan/LSan下buffer只能在最后一个真实operation与Lua owner均释放后销毁，失败不留下悬空可用handle或泄漏。当前不运行这些ownership场景。

### NET-004 — P2 — 事件回调在 socket 发布后才校验，配置错误会遗留不可达 fd

- 状态：已确认；Lua异常顺序、callback表发布与C socket ownership的确定性静态推导。本轮不创建缺字段listener或触发accept。
- 公开契约：低层`tcplisten/tcpconnect/udpbind/udpconnect`接收event table；无论选择要求哪些callback，都应在分配OS/C资源前完整验证。若文档声明callback可选，实现就不能在正常事件上断言其存在。
- 位置：公共listen/connect wrapper在`lualib/silly/net.lua:55-148`，回调注册和assert位于`:73-83,119-138`；ACCEPT handler在`:168-178`；低层关闭又要求已有`close_callback`，见`:150-166`。中文/英文`docs/src/{en/,}reference/net.md:48-62`把TCP `event.accept`写成可选。底层listener/connect在`src/socket.c:1279-1559`完成创建、pool发布和poll注册后才向Lua报告成功。
- 触发：event为nil或缺少`data/close`时调用任一公开listen/connect；或者按文档给`tcplisten`传入没有`accept`、但具有data/close的event，随后远端建立连接。
- 影响：前一类调用先等待native成功，再在读取/assert callback时抛错；`socket_pending`已经清除，fd没有作为返回值交给调用方，C slot和OS socket继续存在。若缺`close`，`M.close`也因callback表为空而拒绝关闭；可重复调用持续泄漏listener/connection。缺`accept`的listener会成功返回，但每个远端连接到达时handler执行`assert(cb)`，accepted socket已在C pool/poller注册却没有Lua owner，形成可远程重复的孤儿fd；该后果与`NET-001`的late-accept清理缺失相同，但本条触发是稳定公开配置而非close竞态。
- 证据：listen成功分支依次写`accept_callback`、`assert(event.close)`、`assert(event.data)`，connect分支依次assert data/close；任一步异常都没有protected cleanup或`socket_close(fd)`。ACCEPT在继承data/close之前先assert listener accept callback，失败后也没有关闭消息携带的new fd。
- 根因：event schema校验与资源获取顺序颠倒，同时callback表被当作close capability；“可选accept”文档和实现的mandatory断言相互矛盾。
- 建议解法：入口在地址解析/任何native调用之前验证event table及该socket模式要求的全部function；TCP listener必须明确要求accept，或为nil定义立即拒绝并关闭accepted fd。所有成功后发布步骤用受保护的transaction：任意异常都调用底层close并清空已写表项；`M.close`不应仅凭callback存在判断底层fd是否可关闭。
- 回归测试：修复阶段覆盖nil event、逐个缺accept/data/close、字段非function、callback table写入中异常，以及无accept listener收到多连接；断言调用在分配前失败或每个fd立即关闭，pool/open-fd/callback表回到基线。当前不新增误配置复现。

### NET-005 — P1 — TCP/TLS 单 reader 门禁晚于缓存读取，并发调用可偷走字节并永久挂起旧 reader

- 状态：已确认；TCP/TLS缓存、唯一waiter槽和worker调度的确定性静态时序。本轮不新增并发barrier或发送分片数据。
- 并发契约：同一byte stream若只允许一个在途reader，第二个read必须在观察或消费任何连接状态前稳定fail fast；若允许多个reader，则必须有FIFO请求队列并保证每个字节只交付给确定的owner。不能根据当时缓存是否凑巧满足第二个请求而改变门禁结果。
- 位置：TCP先读缓存、后登记/assert唯一waiter在`lualib/silly/net/tcp.lua:263-300`，data callback按旧reader的delimiter尝试读取在`:127-148`；TLS结构相同，公开read在`lualib/silly/net/tls.lua:435-448`，真正的`assert(not s.co)`直到`block_read`的`:169-191`，data callback在`:242-278`。
- 触发时序：协程A调用`read(100)`并登记为`s.co`；peer只到达10字节，callback按100读取失败并把10字节留在buffer。A仍挂起时，协程B调用同一连接的`read(1)`；B在检查`s.co`前从buffer成功取走1字节并返回。若B请求超过当前缓存，则反而进入等待分支并命中assert，因此行为取决于网络分片与请求长度。
- 影响：A的逻辑请求边界被B静默破坏；peer总共发送A原先需要的100字节时，buffer最终只剩99字节，A不会被唤醒且无timeout时永久挂起。面向协议的reader还会把属于另一操作的prefix/body交给错误协程，引发response错配或状态机反同步。TLS与TCP具有相同漏洞，且现有文档没有声明同连接并发read为非法；即使将其定义为非法，当前也没有一致拒绝。
- 证据：两个`conn.read`都先调用`bread/tls.read`并在成功时直接return；唯一reader断言只存在于首次读取失败后的等待登记路径。旧reader的`co/delim`在第二次缓存成功读取时完全未检查或清理，后续data callback仍按旧delimiter和旧co继续运行。UDP虽然也在`qpop`后检查waiter，但有waiter时第一包会直接清槽并唤醒，不会形成“部分datagram留存”，因此本条限定byte-stream TCP/TLS。
- 根因：把single-reader检查当成“能否登记waiter”的局部条件，而不是整个read operation的并发ownership条件；缓存fast path绕过了门禁。
- 建议解法：在任何buffer/SSL读取之前检查并占用per-connection reader token，并让token在同步成功、异步成功、timeout、close和error的所有终局统一释放；更清晰的是用operation对象绑定co、delimiter、timer与generation。若只支持单reader，第二调用稳定返回明确`BUSY`错误而非assert；若要支持多reader，则实现FIFO队列并明确拆分语义。
- 回归测试：修复阶段用可控分片覆盖A等待100/B读1、A delimiter/B fixed-size、TLS decrypted partial buffer、B在0/1/99/100字节时进入，以及timeout/close与第二reader交错；断言第二调用永不消费A的字节、A有限完成或得到明确终态、timer不误唤醒新operation。当前只记录静态时序。

### NET-006 — P1 — TCP/TLS buffer limit 可在满足当前 read 前暂停输入并形成自锁

- 状态：已确认；read、data callback与高/低水位状态机的确定性静态推导。本轮不发送大数据或运行等待复现。
- 公开契约：`conn:limit(size)`被双语文档推荐用于限制接收缓存并在消费后恢复；启用资源保护不能让一个语法和长度都合法的在途read失去取得剩余字节的机会。API至少必须规定单次read与limit的关系，并以明确错误替代无限等待。
- 位置：TCP水位切换在`lualib/silly/net/tcp.lua:85-98`，data callback先尝试完整read、失败后按buffer size暂停在`:127-148`，公开read/恢复逻辑在`:213-225,263-300`；TLS对应路径在`lualib/silly/net/tls.lua:124-137,242-278,398-447`。双语TCP reference在`docs/src/{en/,}reference/net/tcp.md`多次建议设置limit，TLS reference的`conn:limit`说明位于两文件`:528-530`。
- 触发：设置`conn:limit(64KiB)`后调用`read(1MiB)`；或者调用`read("\\n")`而peer在前64KiB没有发送LF。接收buffer达到limit时，当前请求尚不能返回。
- 影响：data callback执行完整读取失败，随后`readenable(fd,false)`停止socket输入；等待协程仍是唯一能消费该请求的reader，但它只有在完整长度/分隔符满足后才会被唤醒。恢复读取的`check_limit(...size < limit)`只在另一次成功read或调用`limit(nil)`时发生，因此正常单reader程序自锁。无timeout永久占用连接和task；有timeout只返回TIMEDOUT并留下已满、仍暂停的buffer，后续相同大read会重复失败。TLS明文buffer路径完全相同。
- 证据：TCP/TLS callback都先以当前`s.delim`调用all-or-nothing reader；返回nil后仍对未消费总量运行`check_limit`。达到阈值用`readenable(false)`，等待operation没有partial delivery或内部低水位drain。公开read从wait恢复前不会执行任何恢复分支；文档也没有要求`limit >= 每次定长读取/最大delimiter距离`。该问题与`SOCK-012`的“默认无资源上限”独立：开启现有保护反而破坏合法读取的liveness。
- 根因：把application undecoded buffer的高水位直接当作transport pause阈值，却没有为当前解析operation预留进度预算；hard cap、backpressure watermark和单次消息上限被混成一个数值。
- 建议解法：分离协议/operation hard limit与transport高低水位。登记read时若固定`n`超过允许上限应立即返回明确`LIMIT`错误；delimiter模式应在达到hard cap且仍未匹配时终止/关闭，而不是暂停等待。若limit只表达backpressure，则当前唯一reader必须能流式消费/匹配并让buffer降到低水位，或临时保证其完成所需的有界输入预算；timeout/close后统一恢复或关闭，不能留下永久paused状态。
- 回归测试：修复阶段覆盖`n`在limit-1/limit/limit+1、delimiter位于边界前/边界/边界后/永不出现、单chunk与多chunk、TCP/TLS、带/不带timeout及timeout后下一次read；断言所有路径有限终止，read-enable状态与buffer预算一致且无busy loop。当前只保存静态证据。

### UDP-001 — P2 — `sendto` 不区分 bound/connected socket，缺失或显式目标被静默错误处理

- 状态：已确认；公开文档、Lua对象状态与C发送分支静态核对。本轮不发送datagram。
- 位置：UDP对象构造与`sendto`在`lualib/silly/net/udp.lua:48-62,108-133,194-204`；Lua/C边界在`luaclib-src/lnet.c:239-278`；C operation构造与类型分支在`src/socket.c:1663-1727`；契约在`docs/src/en/reference/net/udp.md:26-31,166-190`及中文对应文档。
- 触发：对`udp.bind`返回的socket调用`conn:sendto(data)`而省略文档规定必填的destination；或对`udp.connect`返回的socket传入一个显式destination，期望按`sendto(data, address)`参数发送到该地址。
- 影响：bound路径仍返回`true,nil`，但operation中的address保持全零；socket线程把family 0按IPv6长度交给`sendto`，永久失败后静默丢弃datagram，调用者既拿不到同步错误也没有异步错误事件。connected路径则无条件把operation address置为NULL，显式目标被静默忽略并发送给默认peer；路由到错误目标时可能造成业务数据误投。
- 证据：所有UDP对象由同一个`new_socket(fd)`构造，未保存bound/connected mode或default peer。`conn.sendto`只检查fd，原样把可选addr传给`net.udpsend`；C operation以零初始化开始，仅在addrlen>0时复制。消费时只根据底层socket type决定：`SOCKET_UDP_LISTEN`使用`&op->addr`，`SOCKET_UDP_CONNECTION`强制使用NULL，而两条分支都不会把永久send error报告给Lua。文档却明确声明bound address required，并把可选`address`描述为destination。
- 根因：一个API复用了两种不同socket模式，却没有在对象或operation中表达目标地址的有效性规则；异步acceptance又被错误当成实际发送成功。
- 建议解法：Lua对象保存mode。bound socket在入队前要求合法address，缺失直接返回`false, EINVAL`；connected socket应明确选择并文档化“禁止override”或实现平台一致的显式目标发送，禁止静默忽略。C层仍须验证sockaddr并为永久UDP发送失败提供可观察的错误/计数，而不是只释放payload。
- 回归测试：修复阶段覆盖bound缺地址、合法IPv4/IPv6目标、connected省略地址、connected显式同/异目标及永久send error；断言目标选择与文档一致，错误不返回成功且payload/`sendsize`只结算一次。本轮不创建或运行网络复现。

### TLS-001 — P1 — TLS client 完全不验证服务端证书链或 hostname

- 状态：已确认；OpenSSL默认契约、公开配置面与确定性调用链推导。本阶段不搭建MITM/伪证书动态复现。
- 规范/权威依据：OpenSSL文档明确新建context默认不验证peer（`SSL_VERIFY_NONE`）；标准client流程需启用`SSL_VERIFY_PEER`、加载默认或指定trust store，并在握手前设置期望DNS hostname/IP。参见 [SSL_CTX_set_verify](https://docs.openssl.org/3.0/man3/SSL_CTX_set_verify/)、[TLS client guide](https://docs.openssl.org/3.3/man7/ossl-guide-tls-client-block/) 与 [SSL_set1_host](https://docs.openssl.org/3.0/man3/SSL_set1_host/)。
- 位置：全局client context创建在`luaclib-src/ltls.c:217-230`；TLS对象/SNI设置在`:458-496`；Lua公开connect options在`lualib/silly/net/tls.lua:284-330`；双语reference的client示例与错误安全声明在`docs/src/{en/,}reference/net/tls.md:169-235,567-595`。
- 触发：任何`silly.net.tls.connect`（以及使用它的HTTPS/WSS/gRPC client）连接到攻击者、错误配置或被DNS/路由劫持的endpoint；peer提供任意自签名、过期、不受信任或hostname不匹配的证书。即使调用方传入正确`hostname`也会触发，因为该参数只用于SNI。
- 影响：链路虽然加密但没有服务端身份认证；主动中间人可终止并重新建立TLS，读取或篡改HTTP凭据、cookies、gRPC metadata及应用数据。API/文档把该连接描述为TLS/HTTPS且没有“不安全模式”警告，调用方也没有可用选项自行开启验证。
- 证据：`lctx_client`只调用`SSL_CTX_new(TLS_method())`，从未调用`SSL_CTX_set_verify(...SSL_VERIFY_PEER...)`、`SSL_CTX_set_default_verify_paths`或加载CA。`ltls_open`对hostname只调用`SSL_set_tlsext_host_name`，没有`SSL_set1_host/SSL_set1_ipaddr`，握手成功路径也不检查`SSL_get_verify_result`。整个Lua conf没有CA、verify或expected-name字段。两种语言却逐字声明“Clients verify server certificates by default / 客户端默认会验证服务器证书，自签名会失败”，common-errors还列出certificate mismatch/untrusted certificate；这些状态在当前client根本不会由验证产生。
- 根因：把SNI（告诉服务端选择证书）误当作/替代了peer authentication，且client context只有一个无配置的全局实例。
- 建议解法：安全默认开启peer verification并加载系统trust store；要求从目标URI自动导出expected hostname/IP，分别调用适用的OpenSSL verification API，SNI只对DNS名设置。提供`cafile/capath/ca_pem`和可选client cert；若确需测试用insecure模式，必须显式命名、默认false并向上层传播，不能让hostname=nil静默关闭所有认证。任何verify配置失败或握手验证失败均返回明确TLS错误。
- 回归测试：修复阶段用独立证书矩阵覆盖受信CA+正确SAN成功，自签名、未知CA、过期、错误SAN、DNS/IP类型不匹配均失败；custom CA成功，显式insecure仅在主动配置时成功。HTTPS/WSS/gRPC集成路径均验证默认安全行为。当前不新增MITM复现。

### TLS-002 — P1 — reload/释放 listener context 可使在途 SNI handshake 使用失效 userdata

- 状态：已确认；Lua userdata引用关系、OpenSSL callback arg与握手时序的确定性推导。本阶段不新增GC/reload握手竞态复现。
- 位置：native ctx布局/销毁在`luaclib-src/ltls.c:41-55,138-165`；SNI callback与注册在`:353-446`；TLS object创建不保留ctx在`:167-185,458-496`；Lua accepted connection与reload在`lualib/silly/net/tls.lua:105-123,186-205,372-395`。
- 触发：server accept TCP后，TLS handshake因尚未收到完整ClientHello而yield；此时另一task调用`listener:reload()`替换`l.ctx`，或关闭listener并丢弃最后一个Lua引用，随后GC finalize旧ctx；peer再发送带SNI的ClientHello，使旧SSL_CTX中注册的servername callback运行。
- 影响：callback arg仍是旧`struct ctx *` userdata的裸地址，但accepted TLS userdata没有保留该Lua对象；GC后读取`entry_count/entries/cert`属于use-after-free，可崩溃或读取已复用内存。即使内存尚未复用，`ctx_destroy`已经free各entry的cert/SSL_CTX且没有清空pointer，callback的fallback仍读取`entries[0].ptr`并传给`SSL_set_SSL_CTX`，生命周期依赖偶然的OpenSSL内部ref而不是本实现所有权。公开“零停机证书热重载”正会触发该窗口。
- 证据：`SSL_CTX_set_tlsext_servername_arg(ptr, ctx)`保存native userdata地址；`new_tls(...,0)`创建零uservalue TLS userdata，`ltls_open`调用`SSL_new`后从未把Lua ctx设为uservalue。Lua connection table只保存`ssl`，没有`ctx`字段。reload直接`l.ctx=new_server_ctx(...)`，旧accepted `s.ssl`因此不能使Lua GC看到旧ctx仍可达。
- 根因：OpenSSL对象对内部`SSL_CTX`的native引用计数被误认为也能保活包含callback state的Lua userdata；实际上callback arg是外部裸地址，未参与OpenSSL refcount或Lua reachability。
- 建议解法：每个TLS userdata用uservalue强引用创建它的ctx，至少保持到handshake完成；若callback在connection后续仍可能运行，则保持到SSL释放。更稳妥是把SNI routing state移到独立native refcount对象，由所有SSL_CTX/SSL共同持有，reload构造完整新generation后原子切换listener，新旧generation分别在最后一条connection释放时销毁。`ctx_destroy`清空每个指针并保证幂等。
- 回归测试：修复阶段让连接停在ClientHello之前，循环reload/close listener、强制full GC后继续带SNI握手；覆盖默认/第二证书与多个在途连接。ASan不得出现UAF，旧连接使用旧generation、新连接使用新generation，所有ctx/cert最终只释放一次。当前不新增竞态复现。

### TLS-003 — P1 — `SSL_read` 的 close/error 状态被吞掉，TLS reader 可永久挂起

- 状态：已确认；OpenSSL I/O契约与确定性数据/协程路径推导。本阶段不发送alert或close_notify做动态复现。
- 规范/权威依据：OpenSSL要求`SSL_read`返回`<=0`后调用`SSL_get_error`区分WANT_READ/WANT_WRITE、`SSL_ERROR_ZERO_RETURN`和fatal error；ZERO_RETURN表示peer发送了`close_notify`，并不表示底层TCP已关闭。参见 [SSL_read](https://docs.openssl.org/3.4/man3/SSL_read/) 与 [SSL_get_error](https://docs.openssl.org/3.0/man3/SSL_get_error/)。
- 位置：native record input在`luaclib-src/ltls.c:617-635`，错误helper/flush仅用于handshake/write在`:58-96,531-615`；Lua data/read等待在`lualib/silly/net/tls.lua:139-180,250-278,428-447`。
- 触发：握手后peer发送合法`close_notify`但保持TCP open等待本端shutdown；或发送fatal alert/导致decrypt、record MAC、protocol error的TLS记录；也包括`SSL_read`返回WANT_WRITE并在out BIO生成控制数据的状态。
- 影响：`ltls_push`在`SSL_read<=0`时直接break并仅返回当前plaintext buffer size，不返回terminal/retry状态，也不flush out BIO。若Lua coroutine正等待更多字节/分隔符，EVENT.data无法唤醒它；底层TCP没有close event时可无限挂起。fatal错误同样不关闭连接或通知调用方，攻击者可稳定占用连接、task和上层HTTP/gRPC stream资源；应答alert/KeyUpdate等输出还可能滞留。
- 证据：循环只在`n>0`时增加buffer，`n<=0`没有`ERR_clear_error`、`SSL_get_error`、`push_ssl_error`或`flushwrite`。Lua EVENT只根据新plaintext尝试满足`delim`，`tls.push`没有错误返回槽；只有原始socket CLOSE callback会设置`s.err/wakeup`，而TLS `close_notify`明确无需关闭TCP。
- 根因：memory-BIO适配层把TLS record processor误当作永远只有“产出plaintext/需要更多TCP字节”两态，丢失OpenSSL的shutdown、fatal、WANT_WRITE和alert-output状态机。
- 建议解法：让`tls.push`返回`plaintext_size,state,error`；每次`SSL_read<=0`立即在清空error queue的正确调用边界使用`SSL_get_error`。WANT_READ继续等待，WANT_WRITE先flush并维持重试，ZERO_RETURN标记authenticated EOF、唤醒reader并进入shutdown，fatal error flush alert后关闭并传播明确errno。所有产生out BIO数据的读/握手路径统一drain，且避免在fatal error后调用`SSL_shutdown`。
- 回归测试：修复阶段覆盖peer close_notify但TCP保持open、fatal alert、bad record MAC、unexpected EOF、WANT_READ/WANT_WRITE与TLS 1.3 post-handshake control；断言reader及时返回EOF/错误、alert被发送、连接不泄漏且不会busy-loop。当前不新增alert输入。

### TLS-004 — P2 — 正常关闭直接断 TCP，永远不发送 TLS `close_notify`

- 状态：已确认；公开close到native SSL API的完整调用链推导。本阶段不新增strict peer互操作复现。
- 规范/权威依据：OpenSSL说明`SSL_shutdown()`发送`close_notify`；若不等待双向shutdown，至少一次成功调用后再关闭transport才是受支持的fast shutdown。直接`SSL_free/close TCP`会让peer无法获得经认证的流结束，对不能自行确定消息完整性的应用存在truncation风险。参见 [SSL_shutdown](https://docs.openssl.org/3.1/man3/SSL_shutdown/)。
- 位置：Lua close在`lualib/silly/net/tls.lua:409-426`；native TLS只导出open/read/write/handshake/push/size/free，在`luaclib-src/ltls.c:642-689`；`ltls_free`仅调用`SSL_free`在`:187-200`。
- 触发：任意已完成握手的TLS connection调用`conn:close()`或经`__close/__gc`收尾；无需异常条件。
- 影响：peer看到底层EOF而非authenticated TLS EOF，严格实现会报告`unexpected eof while reading`并可能拒绝session reuse；若上层协议没有自身无歧义长度/结束标记，应用无法区分正常结尾与攻击者截断。HTTPS/WSS等常见路径也失去规范的TLS关闭语义。
- 证据：`conn.close`立即清Lua状态后调用`net.close(fd)`，从不访问`s.ssl`；native模块全文没有`SSL_shutdown`。GC只`SSL_free`内存对象，既不drain out BIO也不发送alert。OpenSSL quiet-shutdown也未配置，因此不是一个显式、受约束的兼容模式。`test/testssl.lua:125-135`甚至把同一个`cfd:close()`注释为“Close cleanly (with SSL_shutdown)”，但测试只观察对端最终raw EOF，没有验证wire close_notify，形成错误覆盖信号。
- 根因：TLS wrapper只代理握手和application data，把连接关闭完全委托给TCP层，缺少独立的TLS shutdown状态机与write-close deadline。
- 建议解法：提供异步TLS close：在未发生fatal error时调用`SSL_shutdown`，drain并发送out BIO中的close_notify；可选择一次调用后关闭的documented fast shutdown，或在deadline内等待peer close_notify后关闭。fatal路径不得错误调用shutdown，但应尽力发送已生成alert。区分`abort()`与graceful `close()`，并保证GC finalizer采用有界、不会yield的安全策略。
- 回归测试：修复阶段让OpenSSL/Go等strict peer验证主动client/server close都收到close_notify，双向关闭在deadline内完成；同时覆盖peer不响应、已有fatal error、pending ciphertext和GC fallback，无挂起/double-close。当前不新增互操作复现。

### TLS-005 — P1 — server TLS handshake 无 deadline，可被空连接永久占用资源

- 状态：已确认；accept、handshake与timeout配置调用链的确定性推导。本阶段不新增慢连接压力复现。
- 位置：server accept固定无timeout调用handshake在`lualib/silly/net/tls.lua:186-205`；等待/timer逻辑在`:139-180`；listen配置在`:338-367`；底层accept后立即注册connection在`src/socket.c:805-849`。
- 触发：远端完成TCP三次握手后不发送ClientHello，或只发送不足以完成握手的零散TLS字节，并保持TCP连接；可并行建立大量连接。
- 影响：每个连接在应用`accept` callback运行前永久保留OS fd、C socket slot、SSL/BIO/buffer userdata和一个WAIT coroutine；业务handler尚未获得connection，无法设置read timeout或主动淘汰。攻击者可低带宽耗尽fd/内存，阻止合法TLS连接。
- 证据：EVENT.accept执行`handshake(s)`时没有第二参数；当`SSL_do_handshake`返回WANT_READ时，`block_read(s,HANDSHAKE,nil)`直接`wait()`且不创建timer。`tls.listen`配置没有handshake timeout/deadline字段。TCP keepalive不能提供短期握手防护，socket层也没有accept-age deadline。
- 根因：client connect实现了可选的TCP+TLS总deadline，但server accept路径没有对应资源生命周期预算，并把握手放在用户callback之前。
- 建议解法：listener提供有安全默认值的`handshake_timeout`和可选全局/每IP pending-handshake上限；从TCP accept时刻开始单调deadline，超时以TLS alert（若可行）后abort close，并释放所有callback/table状态。握手每次进展不能无限重置总deadline；若另设idle-progress timeout需同时保留absolute cap。
- 回归测试：修复阶段覆盖完全不发ClientHello、逐字节slow ClientHello、握手中断、正常临界时间成功及大量并发；断言超时后fd/task/SSL/slot全部回收，应用accept只收到成功握手连接。当前不新增慢连接复现。

### TLS-006 — P2 — protocol minimum 允许 TLS 1.1，且 client 版本基线依赖环境默认值

- 状态：已确认；RFC要求与context构造调用链推导。本阶段不启用legacy cipher做动态协商。
- 规范：RFC 8996要求实现不得协商TLS 1.0或TLS 1.1；见 [RFC 8996](https://www.rfc-editor.org/rfc/rfc8996.html)。最低版本应由实现/API明确设为TLS 1.2或更高，不能依赖发行版OpenSSL配置偶然禁用旧协议。
- 位置：client context在`luaclib-src/ltls.c:217-230`；每个server certificate context在`:285-352`，其中`:298`显式设置`TLS1_1_VERSION`；Lua TLS配置在`lualib/silly/net/tls.lua:43-48,338-367`。
- 触发：在允许legacy协议/cipher的OpenSSL构建或系统策略下，与只提供TLS 1.1的peer协商；server路径代码明确允许1.1，client则完全使用库默认minimum。不同部署可因此产生不一致结果。
- 影响：成功协商已被BCP禁止的旧TLS版本，继承其过时算法/协议风险；同一应用在不同OpenSSL版本或系统配置上安全基线漂移。配置API也无法把minimum提升到TLS 1.3或为受控legacy场景显式声明例外。双语安全指南又教用户用cipher string“禁用TLS1.0/1.1并强制TLS1.2+”，部署按该示例配置后仍可能协商代码允许的TLS1.1，形成安全策略假象。
- 证据：server唯一版本调用是`SSL_CTX_set_min_proto_version(ptr,TLS1_1_VERSION)`且忽略返回值；client context没有任何min/max调用。`TLS_method()`本身是version-flexible method，不等价于TLS 1.2 minimum。Lua conf只暴露cipher/cert/ALPN。双语`docs/src/{en/,}guides/tls-configuration.md:488-519`把`ciphers="DEFAULT:!SSLv3:!TLSv1:!TLSv1.1"`标成version control，但实现只把它交给不设置protocol min/max的cipher-list API；`TLS-010`另记录其对TLS1.3 suite也不生效。
- 根因：实现保留旧兼容minimum并把client policy隐式委托给OpenSSL全局默认，没有建立统一、可验证的TLS policy层。
- 建议解法：client/server默认明确设置minimum TLS 1.2并检查API返回值；可选`min_version/max_version`只接受受支持、安全的枚举，任何legacy override需显式风险开关和告警。分别配置TLS≤1.2 cipher list与TLS1.3 ciphersuites，并在启动时记录最终policy。
- 回归测试：修复阶段用TLS 1.0/1.1-only peer断言client/server均拒绝，TLS 1.2/1.3成功；覆盖不同OpenSSL major与系统security-level，显式配置错误必须启动失败而非静默回退。当前不启用legacy互操作。

### TLS-007 — P2 — listener 在 TLS context 创建前已发布，配置失败会泄漏并留下失效 accept 回调

- 状态：已确认；Lua语句顺序、低层listener注册与ctx错误行为静态推导。本轮不加载故意损坏的证书。
- 位置：`net.tcplisten`成功后安装callback在`lualib/silly/net.lua:55-86`；TLS listener创建顺序在`lualib/silly/net/tls.lua:326-365`；accept回调解引用listener在`:209-224`；native证书/key/cipher失败返回在`luaclib-src/ltls.c:256-368,398-456`。
- 触发：地址listen成功后，`ctx.server`因证书PEM、private key、key mismatch、cipher配置或SSL_CTX创建失败返回`nil,error`；`new_server_ctx`随即`assert(c,err)`抛出。证书内容部署错误是普通配置失败，不要求远端输入。
- 影响：已注册的TCP listener没有进入`listener_pool`，也没有执行`net.close`，持续占用OS fd、C socket slot和三张net callback表。端口保持监听但调用方只看到Lua异常；若peer随后连接，通用ACCEPT仍调用TLS EVENT，后者对nil `listener_pool[listenid]`读取`lc.ctx`再次异常，accepted连接也无法建立所有权并可能形成孤儿slot。重试listen还会遇到地址已占用。
- 证据：`M.listen`先执行可yield且完成注册的`net.tcplisten`，只有成功返回fd后才调用`new_server_ctx`；该helper用assert把所有native配置错误升级为非局部Lua异常。唯一构造`new_listener`和保存`listener_pool[fd]`发生在ctx成功之后，两个函数之间没有`pcall`、to-be-closed guard或失败清理。
- 根因：资源获取顺序与异常安全不匹配：可失败的纯配置构造放在外部可见listener发布之后，且没有统一rollback owner。
- 建议解法：先完整构造并验证TLS ctx，再调用`net.tcplisten`；若transport仍可能在后续初始化失败，使用受保护的cleanup guard保证任何异常都关闭fd并删除callback。`new_server_ctx`应返回`nil,error`给`M.listen`而非assert，让公开API保持声明的`listener?, error`契约。accept入口对缺失listener也必须关闭accepted fd而非解引用nil。
- 回归测试：修复阶段覆盖malformed cert/key、mismatch、invalid cipher和native ctx失败；断言返回`nil,error`而非抛出，端口可立即重新bind，fd/slot/callback恢复基线。另覆盖失败窗口内的late accept，必须关闭accepted fd且无二次异常。当前不创建这些配置复现。

### TLS-008 — P2 — reload 先污染保存配置再构造 ctx，失败时抛异常且无法事务回滚

- 状态：已确认；reload table更新顺序、ctx构造错误路径与双语API契约静态核对。本轮不加载损坏证书或cipher。
- 位置：`listener.reload`与`new_server_ctx`在`lualib/silly/net/tls.lua:326-397`；公开返回契约及示例在`docs/src/reference/net/tls.md:392-438`和英文同名文档。
- 触发：对活动listener调用`reload(conf)`，其中新cert/key不匹配、PEM损坏、cipher/ALPN无效或native ctx构造失败；也包括只覆盖部分字段的增量reload。
- 影响：调用不会按文档返回`false,err`，而是由`assert(c,err)`抛出Lua异常。更重要的是，代码已把conf字段原地写入`l.conf`，但`l.ctx`仍是旧的可用context，形成“运行旧策略、保存新/坏配置”的混合状态；调用方捕获异常后若以`reload()`重试或只修正一个字段，其余已污染字段会再次参与构造，可能长期无法完成证书轮换。监控若只检查返回值分支甚至记录不到reload失败。
- 证据：reload先取`old_conf=l.conf`并以`for k,v in pairs(conf) do old_conf[k]=v end`直接提交修改，然后才调用`l.ctx=new_server_ctx(old_conf)`。helper内`ctx.server`失败不是返回给reload，而是`assert`非局部退出；因此赋值到`l.ctx`未发生、对old_conf的修改却无法撤销。双语reference和两处示例都使用`local ok,err=listener:reload(...)`及if/else失败分支，该分支对配置错误不可达。
- 根因：配置更新和runtime资源替换没有copy-build-commit事务；内部helper用异常表达普通配置错误，与公开result API冲突，也绕过了rollback。
- 建议解法：从当前conf深/受控复制出candidate，合并并完整校验；`new_server_ctx`返回`ctx?,err?`而非assert。只有candidate ctx成功后才原子替换`l.ctx/l.conf`，失败返回`false,err`且旧ctx/旧conf保持完全不变。敏感错误不泄露key内容，并与TLS-002一起让旧ctx由在途连接保活到安全释放。
- 回归测试：修复阶段覆盖坏PEM、key mismatch、invalid cipher/ALPN、部分更新失败后修复重试及无参reload；断言无异常、旧连接/新连接策略明确、失败后conf深度相等、下一次合法reload成功。当前只做控制流核对。

### TLS-009 — P2 — TLS `read(0)` 被登记为永远无法满足的异步读取

- 状态：已确认；Lua/native read返回约定与data callback的确定性静态推导。本轮不建立TLS连接或等待复现。
- 公开契约：`conn:read(n)`承诺精确读取n字节；零长度是合法、已经满足的请求，应与TCP一致立即返回空字符串。所有非法或不可表示长度也必须在登记waiter前同步拒绝。
- 位置：TLS native定长读取在`luaclib-src/ltls.c:514-542`，Lua fast path与waiter登记在`lualib/silly/net/tls.lua:169-191,435-448`，data callback重试在`:242-278`；TCP对照在`luaclib-src/adt/lbuffer.c:318-333`。WebSocket无条件读取frame payload在`lualib/silly/net/websocket.lua:51-95`；双语TLS reference的契约位于`docs/src/{en/,}reference/net/tls.md:439-452`。
- 触发：对任意开放TLS connection调用`conn:read(0)`且不提供timeout；不要求peer发送数据。正常WSS路径也会在收到零payload的Close、Ping、Pong、text或binary frame后调用同一`conn:read(0)`。负数或经`lua_Integer→int`窄化为非正数的大整数会进入相同不可满足路径。
- 影响：native `tls.read`返回nil，Lua进入`block_read`并把`s.delim=0`、当前协程写入唯一waiter槽。Lua中数字0为truthy，后续每次TLS data callback都会再次调用`tls.read(...,0)`，仍返回nil，因此请求永不成功并占住该连接的reader；只有外部close或显式timeout能打断。它会让WSS reader在完全合法且常见的空Close控制帧上永久挂起，无法进入应用的close处理；TCP WebSocket收到同一frame则立即返回，形成ws/wss协议行为分叉。
- 证据：TLS `read_bytes`把`size <= 0`与“缓存不足”统一为`lua_pushnil`；`conn.read`看到nil且无错误就无条件登记等待。callback的`elseif delim then`对0成立，但native永远重复nil。相反buffer reader对`bytes <= 0`明确push空字符串。WebSocket解出payload后，即使值为0也在mask/unmask两分支调用`conn:read(payload)`，没有空payload短路。现有WSS Test 5只读取非空`"secure"`消息后由本端close，没有读取peer的空Close；Test 3的空Close只走明文ws，因此未覆盖该分叉。两条C入口还把64-bit Lua integer无范围检查地传给C `int`，所以超范围值具有实现相关窄化结果。
- 根因：TLS native把zero-length completed operation编码成“尚未完成”，Lua层又没有验证read count或区分invalid/empty/would-block三种状态。
- 建议解法：在共享TCP/TLS Lua入口要求n为可表示的非负整数；n==0直接返回`"",nil`，负数或超过明确最大单次读取值返回稳定参数/limit错误。native binding也使用`luaL_checkinteger`后做checked range conversion，并让返回状态显式区分empty success与insufficient data，避免依赖nil重载。
- 回归测试：修复阶段覆盖TCP/TLS的0、-1、1、`INT_MAX`、`INT_MAX+1`与非整数number，分别在空缓存、已有缓存、peer close和timeout配置下核对；0必须同步成功且不写`s.co/delim`，非法值同步失败且不消费buffer。另让WSS client/server分别读取零payload的Close/Ping/Pong/data frame，断言与明文ws一致立即返回且不占用reader槽。当前只记录静态证据。

### TLS-010 — P2 — `ciphers` 只限制 TLS 1.2 及以下，TLS 1.3 仍使用 OpenSSL 默认套件

- 状态：已确认；OpenSSL cipher API契约、server context调用链与双语安全指南静态核对。本轮不启动TLS server或协商cipher。
- API契约：[OpenSSL `SSL_CTX_set_cipher_list` 文档](https://docs.openssl.org/3.3/man3/SSL_CTX_set_cipher_list/)明确说明该函数只设置TLS 1.2及以下cipher list，不影响TLS 1.3；TLS 1.3必须单独调用`SSL_CTX_set_ciphersuites()`。两套列表组合参与版本协商，前者成功不代表后者受控。
- 位置：唯一消费`conf.ciphers`的native路径在`luaclib-src/ltls.c:436-449`；Lua下传在`lualib/silly/net/tls.lua:326-365`。公开参数与生产安全建议见双语`docs/src/{en/,}reference/net/tls.md:317-327,580-587`，明确包含TLS 1.3 suite的推荐示例在双语`docs/src/{en/,}guides/tls-configuration.md:448-476`。
- 触发：OpenSSL 1.1.1/3.x server配置`ciphers` allowlist并与TLS 1.3 client握手；尤其照指南把`TLS_AES_*`/`TLS_CHACHA20_*`与若干TLS 1.2 suite合并到同一字符串。因为至少一个旧版suite有效，现有返回值检查仍成功。
- 影响：listener成功启动，TLS 1.2策略按配置收紧，但TLS 1.3继续接受库的默认ciphersuites；管理员无法禁用不符合组织/FIPS/硬件策略的TLS 1.3 suite，也无法限制为指南中声称的集合。审计、合规和incident response依据配置得出错误结论；不同OpenSSL版本/发行版默认变化还会让同一Silly配置协商出不同套件。
- 证据：代码只在每个ctx调用一次`SSL_CTX_set_cipher_list(ptr,cipher)`，全文没有`SSL_CTX_set_ciphersuites`。OpenSSL会忽略旧API字符串中的TLS 1.3名称；指南的混合示例又含三个有效TLS 1.2名称，因此旧API仍返回1，现有失败分支检测不到策略缺口。server minimum允许TLS 1.3且未设置maximum，故该路径现实可达。
- 根因：公开配置把两个不同语法/作用域的OpenSSL policy合并成单一`ciphers`字符串，并把旧API的“至少选出一个旧suite”返回值误当成完整TLS版本策略已验证。
- 建议解法：拆分为`ciphers`（TLS<=1.2）与`ciphersuites`（TLS1.3），对每个certificate ctx分别调用并检查对应API；或提供结构化TLS policy后集中生成两套列表。启动时记录最终生效的min/max version和两套suite集合，未知/全被忽略的token应fail fast；同步修正双语指南，不能再把TLS 1.3名称传给旧API。
- 回归测试：修复阶段用OpenSSL 1.1.1/3.x分别配置只允许一个TLS1.2 suite和一个TLS1.3 suite，枚举实际协商结果；覆盖未知token、空列表、混合列表、多SNI ctx及reload，断言未列出的TLS1.3 suite被拒绝且失败不会留下listener/污染旧策略。当前只保存静态证据。

### TLS-011 — P1 — plaintext buffer 以 signed int 无检查扩容，远端累计数据可触发溢出与越界写

- 状态：已确认；native buffer算术、`SSL_read`目标范围与Lua默认limit数据流静态核对。本轮不发送大流量、不做内存压力或sanitizer复现。
- 内存安全契约：攻击者可推动的累计buffer尺寸必须在任何有符号运算和allocation前以checked `size_t`验证；达到hard cap应在仍有合法指针/长度时终止连接，不能依赖接近地址空间耗尽后的整数回绕。
- 位置：TLS plaintext `struct buf`全部字段为`int`在`luaclib-src/ltls.c:30-35`；首次分配、`size+offset+size`与`cap*3/2`扩容在`:96-135`；每个record循环取得目标指针/长度并调用`SSL_read`在`:646-664`。Lua默认无`buflimit`且先push/decrypt后检查可选limit在`lualib/silly/net/tls.lua:105-137,242-279`，资源无界性另见`SOCK-012`。
- 触发：已握手peer持续发送application data，而handler不读取或读取速度长期低于输入，且未设置较小limit；累计未读plaintext让`cap/size`接近`INT_MAX`。这可由正常长连接流量累计，不需要畸形TLS record；32-bit构建或受限地址空间会更早碰到分配边界。
- 影响：`b->size+b->offset+size`和`b->cap*3/2`发生C signed overflow（UB），优化器可据此产生不可预测控制流；现实结果包括比较错误而跳过扩容、负/过小capacity隐式转为巨大`size_t`、丢失原realloc pointer，随后以错误的`s/e`指针和`e-s`长度调用`SSL_read`。最终可造成heap越界写、崩溃或内存破坏，而不只是已有条目描述的可控内存耗尽。
- 证据：四个容量字段及`buf_prepsize`参数均为int，所有加法/乘法在signed域发生；没有`INT_MAX`、`SIZE_MAX`、hard cap或checked helper。`buf_prepsize`返回`b->buf+b->offset+b->size`，caller又以`buf+cap`相减并窄化给`SSL_read`，因此任何回绕都会直接污染写地址/长度。可选Lua high-water检查发生在整次`tls.push`和SSL_read循环之后，且默认nil，不能作为native安全边界。
- 根因：早期固定小buffer实现把OpenSSL I/O的`int`长度类型扩展成了整个累计storage的类型，并用增长算法保证容量，却没有区分单次read长度与总容量，也没有协议/产品资源上限。
- 建议解法：累计offset/size/cap改用`size_t`并使用checked-add/multiply；在每次指针计算前验证invariant `offset<=cap && size<=cap-offset`，单次传给OpenSSL的长度再限制为`INT_MAX`。设置远低于表示上限的native hard cap和安全默认Lua limit，达到cap时返回结构化limit错误并关闭TLS状态；realloc使用临时指针并定义OOM收尾，不能覆盖旧owner。
- 回归测试：修复阶段用小型可配置cap/allocator stub覆盖恰好cap、cap+1、compact后增长、乘法/加法边界与realloc失败；断言只返回limit/OOM并释放一次，ASan/UBSan无越界或signed overflow。再以慢reader验证远端输入受硬上限约束。当前只保存静态证据。

### TLS-012 — P2 — client 在 TCP 发布后才编码 ALPN/创建 SSL，初始化异常会遗留不可达连接

- 状态：已确认；TCP connect发布顺序、Lua表达式异常与native SSL/BIO构造路径静态核对。本轮不传非法配置或注入OpenSSL allocation failure。
- 资源契约：建立并向net层注册的socket必须立即有异常安全owner；任何后续配置编码/native构造失败都要关闭fd、删除callback并返回稳定错误，不能依赖尚未构造成功的connection finalizer。
- 位置：底层connect成功后安装data/close callback在`lualib/silly/net.lua:97-140`；TLS connect随后调用`new_socket`在`lualib/silly/net/tls.lua:279-325`，而ALPN编码和`tls.open`发生在connection table进入`conn_pool`之前的`:78-124`。native `SSL_new/BIO_new`错误使用`luaL_error`在`luaclib-src/ltls.c:459-495`。
- 触发：`tls.connect`传入含非string元素、长度大于255或其`__len`抛错的`alpnprotos`，使`#k`/`string.char(#k)`异常；或TCP成功后`SSL_new`、input/output `BIO_new`因资源失败抛错。server accept的`tls.open`资源异常也存在同类窗口，但正常server不经过ALPN编码。
- 影响：异常越过`M.connect`，没有返回声明的`nil,error`；已建立TCP fd仍在C socket pool和net callback表中，但没有TLS conn对象、`conn_pool[fd]`或调用方handle可以关闭它。后续data事件因找不到TLS conn而被忽略，close事件也不能回收Lua所有权；远端保持连接时可长期占用fd/slot，重复错误配置或资源压力可稳定泄漏。accepted方向还可能把同类无owner fd留给远端。
- 证据：`net.tcpconnect`返回前已写`data_callback[fd]`和`close_callback[fd]`；之后没有to-be-closed guard或`pcall`。`new_socket`先运行`wire_alpn_protos`，再在table constructor中调用可能longjmp的`tls.open`，最后才执行`conn_pool[fd]=s`。因此任何中间异常都发生在唯一Lua owner发布前，`M.connect`的handshake失败cleanup只覆盖`new_socket`已经返回的情况。
- 根因：异步TCP acquisition与TLS对象构造没有统一事务，且普通配置错误/native资源错误以非局部异常表达；代码只为返回式handshake失败实现了rollback。
- 建议解法：在TCP成功后立刻建立to-be-closed socket guard；先严格验证/编码ALPN与hostname，再以受保护调用构造SSL，只有全部成功才提交到conn pool并解除guard。native构造应返回`nil,errno/error`或保证userdata持有全部中间BIO并可幂等finalize；accepted路径也使用同一factory/rollback。公开API对配置错误统一同步返回或抛出，但无论选择哪种都必须关闭transport。
- 回归测试：修复阶段覆盖ALPN非string、空/255/256字节、`__len`异常、SSL_new及两个BIO_new逐点失败，client和accepted方向均断言fd/slot/callback/SSL/BIO回到基线、端口可重用且错误形状稳定。当前只保存静态证据。

### TLS-013 — P2 — certificate table 长度从 Lua integer 窄化为 int，伪造 `__len` 可破坏 native ctx 布局

- 状态：已确认；Lua length metamethod、C整数转换、flexible-array allocation与accept使用路径静态推导。本轮不构造metatable输入或建立连接。
- FFI契约：Lua动态值进入C allocation count前必须验证类型、非负范围与乘加不溢出；userdata flexible-array大小应以checked `size_t`计算，错误输入只能返回参数错误，不能产生零entry/错尺寸context。
- 位置：Lua listener只检查`#certs>0`在`lualib/silly/net/tls.lua:326-365`；native `ncert=luaL_len`窄化、`new_ctx`的int乘加与后续entry循环在`luaclib-src/ltls.c:137-151,398-429`；accept/open无条件读取`ctx->entries[0].ptr`在`:459-495`。
- 触发：传入带`__len` metamethod的certificate table，让长度返回大于`INT_MAX`的正Lua integer（例如在常见32-bit int ABI上为`2^32`或`INT_MAX+1`）。Lua的前置`#certs>0`按完整integer为真，listener先成功发布；C `luaL_len`再次得到该值并赋给int。
- 影响：窄化是implementation-defined，常见结果可成为0或负数；`ctx_count*sizeof(entry)`及与offset相加还可能signed overflow。结果可能是异常巨大的allocation、过小userdata后循环越界写，或`entry_count==0`却成功返回ctx。最后一种在首个accept的`SSL_new(ctx->entries[0].ptr)`读取userdata边界外指针并可崩溃/破坏内存；此前listener已发布，配置调用看似成功。
- 证据：`luaL_len`返回`lua_Integer`，源码未保存到同宽变量或检查`INT_MAX`；`new_ctx`参数、局部`size`和`entry_count`均为int，乘法也在signed int域完成。`new_ctx`按计算结果分配后直接相信count，且`lctx_server`对0 entry没有失败分支；`ltls_open`则无条件索引entry 0。Lua table的`__len`属于标准语言能力，不需要真实分配数十亿元素即可到达数值边界。
- 根因：native代码把“数组长度来自普通dense table”的注解假设当成C内存安全验证，并用单一signed int同时表示Lua数量、allocation bytes与循环上界。
- 建议解法：Lua入口先要求plain dense array或复制到受控candidate并限制合理certificate count；C层把`luaL_len`保存在`lua_Integer/size_t`，验证`1<=n<=MAX_CERTS`，用checked `size_t`乘加后再分配，最后才安全窄化循环count。`ltls_open`同时拒绝`entry_count<1`或空entry，任何错误发生在listener发布前或可靠rollback。
- 回归测试：修复阶段覆盖普通0/1/MAX证书、MAX+1、`INT_MAX+1`、`2^32`、负/非整数/抛错`__len`及稀疏table；全部非法输入只返回错误，listener/fd/context不发布，ASan/UBSan无overflow/OOB。当前只保存静态证据。

### TLS-014 — P2 — vectored write 后段失败会把前段 ciphertext 留到下一次调用再发送

- 状态：已确认；table element校验、逐段`SSL_write`、out BIO drain与Lua连接状态的确定性静态推导。本轮不写入TLS连接或制造OpenSSL retry状态。
- 写入契约：一次返回失败/抛异常的vectored write不能在未来无关write中悄悄提交其前缀；若底层已接受部分plaintext，API必须显式报告partial progress或把连接转为不可继续使用的确定状态，并立即处理所有生成的protocol output。
- 位置：Lua直接转发table在`lualib/silly/net/tls.lua:449-457`；native逐元素检查/写入在`luaclib-src/ltls.c:558-595`，错误早退在`:596-600`，唯一`flushwrite`位于所有元素成功后的`:602-608`。out BIO创建/绑定在`:478-487`。
- 触发：调用`conn:write({"prefix", false})`等让第二/后续元素的`luaL_checklstring`抛类型错误；或前面一个或多个非空string已成功后，后续`SSL_write`返回WANT_READ/WANT_WRITE/fatal error。无需大payload，第一种只依赖动态Lua输入。
- 影响：早先成功的`SSL_write`已推进TLS record/sequence state并把encrypted prefix写入memory out BIO，但异常或`ret<=0`分支都在`flushwrite`之前离开。连接没有设置`s.err`或关闭；若调用方捕获异常/false后继续写，下一次成功调用末尾的`flushwrite`会把旧prefix与新ciphertext一起发送。业务可能在已判失败、回滚或重试后仍执行旧命令/请求，造成重复写、协议帧拼接或事务状态与调用方认知分叉。
- 证据：element类型在循环内才校验，不是先完整验证；每个成功`SSL_write`的out BIO从不按段清空。失败分支只push error并return，没有`BIO_reset`（即使reset也不能回滚SSL sequence）、flush alert、close或partial byte count。Lua wrapper只检查fd，native false不会写`s.err`，所以后续write被允许并确定会drain此前pending BIO。
- 根因：把memory BIO当作一次Lua调用的临时output buffer，但它实际属于长期SSL状态；vectored write又没有预验证或定义partial-write语义，错误处理误以为失败前没有可观察副作用。
- 建议解法：调用任何`SSL_write`前先验证/固定整张string vector和每段长度；明确API为all-or-connection-fatal或返回accepted-prefix。每次OpenSSL调用后都统一检查state并drain必须发送的ciphertext/alert；一旦后段失败且已有plaintext被接受，应标记connection不可重用并关闭，而不是让未来write提交旧prefix。更稳妥可把vector合并/使用支持的write_ex循环，但仍需总量cap和partial语义。
- 回归测试：修复阶段覆盖首/中/末元素类型错误、空元素、第二段WANT_READ/WANT_WRITE/fatal、flush transport失败及随后再次write；断言失败调用的prefix绝不在未来成功调用中出现，或连接已确定关闭且报告准确partial状态。当前只保存静态证据。

### TLS-015 — P2 — certificate 字段类型错误以 Lua longjmp 绕过 native SSL_CTX 清理

- 状态：已确认；`fill_entry`资源获取顺序、Lua C API异常和userdata GC可见所有权静态核对。本轮不传错误类型证书或循环reload。
- 异常安全契约：C函数在调用可抛出的Lua类型检查前，必须把已获取native资源交给可见owner或建立能跨longjmp清理的边界；普通配置类型错误不能永久遗失SSL_CTX/BIO/X509。
- 位置：`fill_entry`先创建局部SSL_CTX、后读取`cert/key`字段并调用`luaL_checklstring`在`luaclib-src/ltls.c:256-280`；只有正常成功末尾才把指针写入entry在`:351-354`，C cleanup label在`:356-368`。外层ctx创建/调用在`:398-435`，Lua listen/reload入口在`lualib/silly/net/tls.lua:326-397`。
- 触发：certificate数组任一元素缺少`cert`或`key`，字段为boolean/table/function等不可转换类型，或字段访问metamethod抛错。首项、后续项以及活动listener的`reload`都可触发；无需建立TLS连接。
- 影响：`luaL_checklstring`/metamethod以Lua longjmp直接越过`fail:`，本次已创建的`SSL_CTX *ptr`仍只在C局部变量中，既不释放也未写入`ctx->entries[i]`。Lua userdata最终GC只遍历entry里已提交的指针，无法找回当前ptr；反复配置/reload可持续泄漏OpenSSL context及其内部资源。公开API同时抛异常而非返回声明的错误，并叠加`TLS-007/008`的listener泄漏或配置污染。
- 证据：赋值`entry->ptr=ptr`严格位于所有PEM/key解析成功之后；类型检查位于任何BIO创建前但SSL_CTX创建后。`fail:`只处理显式NULL/return-code分支，Lua非局部退出不会执行它。ctx userdata初始被memset为0，因此GC不会误打误撞持有local ptr；后续entry出错时仅已完成entry可被ctx_destroy释放。
- 根因：native helper混用返回式OpenSSL错误和longjmp式Lua参数错误，却只为前者设计goto cleanup；资源owner提交过晚，也没有在进入helper前完整验证Lua schema。
- 建议解法：在任何SSL_CTX创建前先于Lua层/独立C pass完整验证cert数组、每项table及cert/key string并固定引用；随后构造阶段不再调用会抛的API。或创建后立即写入entry让userdata成为owner，失败时清空/幂等销毁。公开listen/reload用protected copy-build-commit返回稳定错误，并保证敏感PEM不进入日志。
- 回归测试：修复阶段逐项覆盖cert/key缺失、boolean/table、抛错`__index`、第一/第二证书失败与重复reload；allocator/OpenSSL计数回基线，旧listener/config保持可用，端口无泄漏，错误不含key内容。当前只保存静态证据。

### TLS-016 — P2 — 未协商 ALPN 返回空字符串而非 nil，Lua truthiness 会误判为已协商

- 状态：已确认；OpenSSL absence表示、native返回值、Lua字段传播与双语公开契约静态核对。本轮不建立无ALPN/no-overlap握手。
- API契约：没有协商出ALPN必须以明确absence值表示；双语reference规定`conn:alpnproto()`在未协商时返回nil。Lua中空字符串为truthy，不能把`""`作为nil的等价替代。
- 位置：native握手成功后无条件读取并push ALPN string在`luaclib-src/ltls.c:611-626`；Lua client/server保存返回值在`lualib/silly/net/tls.lua:169-180,242-263`，getter在`:459-463`；公开契约与示例在双语`docs/src/{en/,}reference/net/tls.md:493-525`。
- 触发：client未发送ALPN、server未配置ALPN，或双方配置列表没有交集；TLS规范允许握手成功但不选择应用协议。直接`tls.connect`不传`alpnprotos`就是常规可达场景。
- 影响：OpenSSL以selection length 0表示absence，binding却返回Lua空字符串，`s.alpn`因而不是初始化的nil。任何按文档写`if conn:alpnproto() then ...`或`alpnproto() or default`的代码都会进入“已协商”分支/拒绝使用default，可能把未受ALPN约束的连接交给错误协议parser或绕过required-protocol检查。精确比较`=="h2"`的现有HTTP路径不受truthiness影响，但通用API及其他上层会分叉。
- 证据：`SSL_get0_alpn_selected`之后不检查`len==0`，始终`lua_pushlstring(data,len)`；Lua handshake对任何成功都执行`s.alpn=alpnproto`。reference明确写“returns nil if not negotiated”，示例也把else作为no negotiation。testssl只覆盖双方共同选择h2，没有未配置/no-overlap断言。
- 根因：native binding把OpenSSL的字节串输出机械转换为Lua string，没有在FFI边界把zero-length sentinel规范化为Lua optional value；测试只验证positive selection。
- 建议解法：`len==0`时push nil，否则push非空string；Lua field保持nil。若调用方声明某协议required，另提供/执行显式`required_alpn`校验并在absence/no-overlap时关闭，而不是依赖truthiness；generic TLS仍可允许无ALPN。同步native type stub的optional返回。
- 回归测试：修复阶段覆盖双方无配置、仅client、仅server、无交集、共同h2/http1和自定义protocol；absence必须严格`==nil`，共同项为非空string，required模式无选择时失败且连接关闭。当前只保存静态证据。

### TLS-017 — P3 — native ctx/tls 显式 free 后 GC 会再次调用非幂等 finalizer 并抛类型错误

- 状态：已确认；userdata metatable、手动方法、meta tombstone与GC二次进入路径静态核对。本轮不调用低层free或强制GC。
- 生命周期契约：公开的显式`free/close`与`__gc`必须共享幂等finalizer；手动释放后GC再次进入只能no-op，不能把正常closed tombstone当成错误userdata并从GC阶段抛异常。
- 位置：ctx/tls的`check_*`、destroy与手动free在`luaclib-src/ltls.c:154-215`；同一函数注册为`__gc`在`:676-715,718-745`。低层方法由`lualib/types/silly/tls/ctx.lua:1-21`和`lualib/types/silly/tls/tls.lua:1-44`公开描述。
- 触发：直接使用`require("silly.tls.ctx")`创建ctx后调用`ctx:free()`，或创建低层TLS userdata后调用`:close()`；对象随后失去引用并被正常GC。重复显式free/close也立即走相同路径。
- 影响：首次调用正确释放资源并把`meta=NULL`，第二次/GC却由`check_ctx/check_tls`调用`luaL_typeerror`；显式重复调用会打断业务，GC阶段则产生finalizer error/warning并污染日志、测试或宿主错误处理。类型文件主动把这些方法呈现为公开资源API，却没有声明“一次调用后必须阻止GC”这种不可能契约。
- 证据：`lctx_free`与`ltls_free`入口第一句都是strict `check_*`，成功末尾将meta清空；metatable的`__gc`仍永久指向同一个函数。没有raw test、`meta==NULL` no-op分支、closed flag或移除metatable动作。高层Lua conn finalizer本身幂等，但不能保护直接导出的native对象。
- 根因：一个函数同时承担“公开严格方法”和“不可抛的GC finalizer”，tombstone校验没有区分错误类型与已正常释放状态。
- 建议解法：拆成内部`*_destroy_if_live`与严格公开wrapper；`__gc`只raw-test userdata并在live时释放，closed时no-op，绝不抛。公开free/close可选择重复返回false/closed error或幂等true，但需与type/doc一致；销毁后清空所有owned pointer/count并保持GC安全。
- 回归测试：修复阶段覆盖ctx/tls的只GC、手动一次后GC、手动两次、部分构造失败后GC及错误类型参数；资源只释放一次、无finalizer warning/double-free，显式返回契约稳定。当前只保存静态证据。

### TLS-018 — P2 — 非法 ALPN 被静默清空，配置可无告警降级

- 状态：已确认；Lua wire encoder、client/server native入口与OpenSSL ALPN格式/返回契约静态核对。本轮不发起握手或构造畸形协议向量。
- 位置：无校验编码在`lualib/silly/net/tls.lua:54-65`，client忽略设置结果在`luaclib-src/ltls.c:445-466`，server直接保存同一向量并交给选择器在`:236-255,398-443`；公开参数说明在`docs/src/{en/,}reference/net/tls.md:319-325,356-374`。
- 触发：`tls.connect(...,{alpnprotos={"", "h2"}})`，或server listen/reload给出含空字符串的动态协议列表。公开契约只写`string[]`，runtime没有非空/长度校验。
- 影响：Lua把空名字编码成`\0`；OpenSSL规定protocol-list每项必须是1..255字节，client的`SSL_set_alpn_protos`会以非零返回拒绝该向量，但binding丢弃返回值。TCP/TLS握手随后可继续且不携带预期ALPN，调用方只看到“成功”；依赖ALPN隔离HTTP/2、gRPC或安全策略时会静默走无协议/错误协议路径。server也把非法向量保留到握手回调才解析，配置阶段无法诊断。超过255字节虽由`string.char`抛出，但又落入`TLS-007/012`已记录的初始化后异常泄漏，本项不重复计算。
- 证据：OpenSSL官方[`SSL_CTX_set_alpn_select_cb`](https://docs.openssl.org/3.0/man3/SSL_CTX_set_alpn_select_cb/)契约明确wire vector由“nonempty, 8-bit length-prefixed”字符串组成，长度0无效；`SSL_set_alpn_protos`成功返回0、失败返回非0，并特别警告其返回惯例相反。当前C代码仅调用函数而不保存/检查返回；Lua encoder仅做`char(#k)..k`，没有`#k>=1 and #k<=255`断言。
- 根因：ALPN序列化分散在Lua，而格式合法性和native API返回检查两端都缺失；成功建立TLS被错误地当成ALPN配置也成功。
- 建议解法：在任何socket/listener创建前一次性验证数组连续、元素为string且长度1..255、总wire长度不超native unsigned-int，并缓存编码结果；native仍必须检查`SSL_set_alpn_protos != 0`并把明确配置错误返回Lua。server ctx创建时用同一validator，禁止把非法向量延迟到peer握手。
- 回归测试：修复阶段增加空名称、256字节、稀疏数组、非string、空列表及合法多协议用例；stub native返回失败时断言connect关闭已建TCP且listen不发布，合法配置再覆盖match/no-overlap与协商值。当前只保存静态证据。

### DNS-001 — P2 — typed RDATA 解析不受 `RDLENGTH` 边界约束

- 状态：已确认；RFC wire format与确定性parser边界推导。本阶段不新增畸形DNS packet复现。
- 规范：RFC 1035 §4.1.3定义`RDLENGTH`为其后RDATA字段的精确octet长度；A/AAAA有固定长度，CNAME/SRV/SOA内部字段必须完整落在该RDATA内。参见 [RFC 1035](https://www.rfc-editor.org/rfc/rfc1035.html)。
- 位置：RR header记录boundary在`luaclib-src/ldns.c:318-347`；A/AAAA在`:349-372`；CNAME/SRV/SOA在`:374-456`；外层按声明长度推进在`:486-513`。
- 触发：匹配当前query的DNS response包含A/AAAA RDLENGTH大于规定长度，或CNAME/SRV/SOA声明过短RDLENGTH、但后续RR/message字节恰好能让domain-name/fixed fields解码成功。
- 影响：parser可把下一RR或message尾部的字节借作当前RDATA，构造并缓存wire中并不存在于该RR边界内的CNAME/SRV/SOA值；A/AAAA则静默忽略多余字节。随后外层仍按伪造的短`rdlen`从中间位置继续解析，形成错误记录集、错误CNAME跳转或negative cache，而不是拒绝整条malformed response。
- 证据：`parse_rr_begin`正确保存`rdpos/rdlen`，但CNAME/SRV/SOA为`read_name`构造的input都使用`size=ctx->size`（完整message）而非`rdpos+rdlen`，SOA fixed-field检查也对`ctx->size`。它们不验证decoder最终位置等于RDATA end。A/AAAA只检查`rdlen < 4/16`，接受大于固定长度。`push_rrs`遇到有效返回后立即把记录交给Lua cache。
- 根因：通用name decoder只知道message级压缩指针目标边界，调用方没有同时约束“编码本体必须在RDATA内、compression pointer可引用message其他位置”这两个不同范围。
- 建议解法：decoder接收`field_end`与`message_size`两个边界：读取label/pointer encoding octet不得越过RDATA end，pointer解引用目标仍按完整message验证；返回consumed position必须恰好等于RDATA end。A/AAAA要求rdlen分别严格等于4/16，SRV先保证6字节后再限定target编码，SOA两name及20-byte tail全部在RDATA内。任一RR malformed应拒绝整个响应，不能缓存partial prefix。
- 回归测试：修复阶段逐项覆盖fixed length±1、CNAME/SRV/SOA在每个label/pointer/fixed-field字节截断、借用下一RR、合法compression pointer指向RDATA外的既有name，以及trailing垃圾；只有编码本体完整且消费恰好到RDATA end才成功。当前不新增畸形packet。

### DNS-002 — P1 — 合并所有 response section 并缓存无关记录，可覆盖任意名字

- 状态：已确认；RFC trust ranking与确定性parser/cache路径推导。本阶段不搭建恶意authority/recursive互操作。
- 规范：RFC 2181 §5.4.1规定DNS data按来源具有不同trustworthiness，additional section最低，低可信数据不得替换更可信的既有data；response section与bailiwick不能在cache时丢失。参见 [RFC 2181](https://www.rfc-editor.org/rfc/rfc2181.html)。
- 位置：C parser把三个count相加并统一输出在`luaclib-src/ldns.c:475-515,552-605`，RR CLASS被忽略在`:330-347`；Lua无条件merge/cache在`lualib/silly/net/dns.lua:110-133,194-226`。
- 触发：匹配当前ID/QNAME/QTYPE的response在authority或additional section携带A/AAAA/CNAME/SRV记录，owner name可与当前查询完全无关；也可使用非IN CLASS。该响应可能来自错误/恶意上游、被攻击者影响的authority经recursive转发，或伪造响应。
- 影响：resolver对每个记录调用`try_create_rr`，第一次见到该owner/type就`clear_rr`，随后缓存rdata与TTL；因此最低可信additional数据能覆盖此前从answer获得的任意域名地址/CNAME/SRV。后续连接可被重定向到攻击者地址，且transaction-local `merge_records`还给这些记录设置`maxinteger`，在同次CNAME解析中立即使用。忽略CLASS进一步允许非Internet namespace数据进入同一cache。
- 证据：`lanswer`用`total_rr=ancount+nscount+arcount`调用一次`push_rrs`，输出record没有section/class字段。`dispatch_resp`遍历全部records并按record owner直接写server cache，既不要求owner属于QNAME/CNAME chain，也不限制SRV glue target/bailiwick，更没有trust rank；已有更可信rr会被`clear_rr`覆盖。
- 根因：wire parser为简化返回结构丢弃section与CLASS provenance，cache层因而无法执行最小相关性、bailiwick和可信度规则，并把“configured server发来的整包”误当作“包中每条记录都可全局缓存”。
- 建议解法：parser分别返回answer/authority/additional并保留CLASS；先严格要求question与可消费RR为IN。stub解析仅接受与QNAME及受验证CNAME chain相关的answer；negative cache只使用匹配authority SOA。若为SRV等保留additional glue，限定到已接受target和相应bailiwick，赋较低trust且绝不覆盖更高trust cache；最安全的stub策略是不全局缓存additional，而按需另查。
- 回归测试：修复阶段构造answer正常但additional含`victim.example`、authority含伪A/CNAME、非IN CLASS及同名低trust覆盖；断言只返回/缓存query相关answer，既有高trust记录不变。另覆盖合法CNAME chain、SRV target glue及negative SOA。当前不新增恶意上游互操作。

### DNS-003 — P1 — query ID 可预测且长期复用单一 UDP source port

- 状态：已确认；RFC防伪要求与transaction/socket生命周期推导。本阶段不发送伪造DNS response。
- 规范：RFC 5452要求outgoing query使用不可预测的query ID与source port，并在接收时匹配地址、端口、ID、QNAME、QCLASS和QTYPE，以扩展伪响应所需entropy；参见 [RFC 5452](https://www.rfc-editor.org/rfc/rfc5452.html)。
- 位置：每个rr的version初始化/递增在`lualib/silly/net/dns.lua:91-107,350-381`；每个server复用UDP connection在`:305-330`；socket只在首次创建/错误后重建在`:229-247,305-321`；response matching在`:185-202`。
- 触发：首次查询任意新name时TXID必为1，之后只需知道该name此前的查询次数即可预测16-bit递增值；同一nameserver的所有查询长期使用同一个connected UDP socket，由OS只在首次connect选择一次ephemeral source port。能spoof nameserver源地址并猜出/侧信道获知该固定端口的off-path攻击者可竞速发送匹配question的响应。
- 影响：预期的TXID entropy完全消失，攻击者只剩至多source-port搜索空间；一旦端口被观察或推断，单个伪响应即可被接受并写入cache。结合`DNS-002`，匹配一个攻击者可预测的查询还可能携带无关记录污染其他名字。connected UDP会校验source endpoint，但不能弥补可预测ID和固定本地端口。
- 证据：新rr固定`version=0`，新request使用`(version+1)&0xffff`，没有任何随机源；不同name的首个并发query全部ID=1。`server.udp_conn`跨query保留且没有port rotation。matcher验证ID/name/type，但C parser跳过QCLASS，且这些匹配字段除端口外均可由触发/观察query的攻击者得知。
- 根因：cache version counter被复用为wire transaction nonce，并为连接复用牺牲source-port entropy；transaction identity与cache generation没有分离。
- 建议解法：每个UDP transaction用CSPRNG生成不可预测且当前socket内不冲突的16-bit ID，cache generation另设字段；采用RFC 5452建议的source-port randomization/安全socket pool与适当轮换，同时保持connected-source校验。接收端严格匹配source/destination endpoint、ID、完整QNAME、QCLASS=IN和QTYPE；必要时加入0x20 case randomization作为额外而非替代防线，优先支持加密resolver或DNSSEC验证。
- 回归测试：修复阶段统计大量并发/顺序query，断言不同name首包不恒定、活动ID唯一且port按策略具有entropy；伪造错误ID/port/name/class/type均被丢弃且不改cache。当前不发送spoofed response。

### DNS-004 — P2 — `ndots`/search list 查询顺序错误，绝对名与尾随点语义不兼容系统 resolver

- 状态：已确认；resolver配置语义与确定性控制流静态核对。本轮不发DNS查询。
- 规范/兼容依据：[resolv.conf(5)](https://man7.org/linux/man-pages/man5/resolv.conf.5.html)规定：名字点数达到`ndots`时先尝试absolute query，失败后仍依次尝试search list；点数不足时先按search list尝试，均失败后再尝试absolute。以尾随点结束的名字是完整域名，只按absolute处理。
- 位置：name规范化、首轮resolve和search fallback在`lualib/silly/net/dns.lua:585-640`；`ndots/search`解析在`:663-706,757-807`；wire name构造在`luaclib-src/ldns.c:94-159`。
- 触发：配置search suffix并解析无点/少点短名（例如`db`、`api.dev`），或配置`ndots>1`后解析带尾随点的absolute name。常见容器环境会设置多个search domains和较高`ndots`。
- 影响：短名先泄漏给上游absolute/root namespace并多付一次timeout；若上游DNS、网关或恶意resolver对短名返回合成地址，Silly立即接受并永不查询预期的`db.<search>`，可连接错误服务。点数达到阈值的absolute尝试失败后完全跳过search，合法内部名称解析失败；尾随点在某些`ndots`配置下又会被拼成`name..suffix`并由encoder折叠空label，错误查询另一个名字。
- 证据：`resolve`无条件先调用`resolve_r(server, trans, name, ...)`；search loop只在`conf_ndots > dotcount(name)`时执行，因此既颠倒低点数顺序，也删除了高点数失败后的search阶段。代码没有单独识别末尾`.`；当条件成立时直接拼接`name .. "." .. suffix`，而`q_name`会跳过zero-length label。
- 根因：把`ndots`误实现为“是否允许search”的布尔门，而不是决定absolute与search候选顺序的阈值；FQDN marker在lower/拼接前没有建模。
- 建议解法：先生成有序且去重的候选列表：trailing-dot只含absolute；否则dots>=ndots为`absolute→search...`，dots<ndots为`search...→absolute`。每个候选在编码前重新验证总长/label，保留清晰的最终错误与整体deadline，缓存key使用canonical absolute name。
- 回归测试：修复阶段以记录query-name顺序的resolver覆盖0/1/多search、`ndots=0/1/2/15`、无点/等阈值/高于阈值、尾随点、空search和NXDOMAIN/timeout组合；断言候选顺序、次数、最终cache key与系统resolver一致。当前不创建或运行resolver。

### DNS-005 — P2 — retry rounds 固定在单一 nameserver，健康备用服务器不会在同次查询接管

- 状态：已确认；nameserver选择、request状态与retry callback的确定性控制流静态核对。本轮不制造resolver超时或发送查询。
- 兼容依据：`resolv.conf`的`nameserver`列表用于在当前服务器无响应时依次尝试其他服务器，`attempts`表示在放弃前遍历服务器列表的轮数；参见 [resolv.conf(5)](https://man7.org/linux/man-pages/man5/resolv.conf.5.html)。项目文档也把`nameservers`描述为列表、把`attempts`描述为retry rounds（`docs/src/en/reference/net/dns.md:185-210`）。
- 位置：每次`resolve`只选择一次server在`lualib/silly/net/dns.lua:589-627`；request永久保存该server在`:433-455`；timeout retry与UDP发送在`:350-392`；failcount只在整项请求结束时更新在`:175-200`。
- 触发：配置至少两个nameserver，当前最低`failcount`的首选服务器丢包、不可达或无响应，而列表中的后续服务器可正常回答；这是主/备DNS维护、网络分区与单节点故障的常见场景。
- 影响：当前lookup会把全部`conf_attempts`耗在同一故障服务器上并最终返回timeout，健康备用服务器完全没有机会回答；只有随后发起的另一项查询才可能因前一项结束后增加的`failcount`选择备用服务器。关键的首次解析因此无谓失败并承受全部重试延迟，多个调用共享同一inflight时会一起失败。
- 证据：`resolve`在进入`resolve_r`前只设置一个局部`server`；`query`复制为`request.server`。`retry_cb`只增加`req.attempt`后再次调用`send_udp_req(req)`，后者始终读取同一个`req.server`，没有nameserver index或轮次推进逻辑。`finish_req`直到所有attempt结束才修改该服务器的`failcount`，不能帮助当前请求故障转移。
- 根因：实现把attempt建模为“对选定服务器重复发送”，并把多服务器列表仅用于跨查询的粗粒度failcount选择；没有把resolver的attempt round与nameserver traversal组合成单次查询状态机。
- 建议解法：request保存当前server index与round，每次超时按配置顺序推进到下一nameserver，遍历一轮后才增加attempt round；每个server使用自己的connection/cache provenance，同时以调用的absolute deadline限制总体等待。即时send/connect失败也应推进而非直接终止；成功后再更新健康度，且不得让一个调用的短timeout破坏共享request的其他waiter。
- 回归测试：修复阶段用可控resolver覆盖首个丢包/第二个成功、首个send失败、全部失败、第二轮首个恢复、并发共享inflight和不同caller timeout；断言单次查询按server/round顺序推进并在健康备用服务器返回时成功。当前不创建或运行resolver。

### DNS-006 — P2 — UDP 截断后的 TCP connect 不受 DNS deadline 约束，请求结束后仍可滞留资源

- 状态：已确认；TCP fallback、request timer与底层connect timeout传递的确定性生命周期静态核对。本轮不制造黑洞连接或截断响应。
- 位置：UDP的TC response派生fallback task在`lualib/silly/net/dns.lua:256-272`；TCP连接与复用在`:305-345`；UDP retry/request结束在`:350-392`；TCP timeout只有显式opts才启用在`lualib/silly/net/tcp.lua:190-210`与`lualib/silly/net.lua:89-140`。
- 触发：resolver返回TC=1后，DNS模块向其TCP端口发起连接，但该端口被防火墙静默丢弃、SYN长期重传或连接完成时间超过DNS request/caller timeout；同一TC响应重复到达还可排队多个fallback task。
- 影响：DNS retry timer会正常`finish_req`并向调用方返回timeout，但正在执行的`tcp.connect(server.addr)`没有timeout参数，也没有被`finish_req`持有或取消；对应socket、`socket_pending`项、协程和per-server mutex可滞留到操作系统连接超时。若迟到连接最终成功，代码先把它发布到`server.tcp_conn`并启动recv/idle timer，才重新发现原request已结束，于是还会保留一个无人需要的TCP连接至idle清理。连续TC查询可累积等待该锁的fallback协程并放大延迟与资源占用。
- 证据：`tcp_fallback`在进入mutex后直接调用`tcp.connect(server.addr)`，未传`{timeout=...}`，且连接期间没有可由`finish_req`访问的handle。请求的`req.timer`仅调用`finish_req`并清理inflight/waiters；底层`connect_wrap`只有`timeout`非nil才注册`connect_timer`，否则无期限`task_wait()`。连接返回后`:325-331`先赋值/派生recv loop，`:332-335`才检查request是否仍inflight。
- 根因：UDP transaction deadline与异步TCP fallback生命周期彼此分离，request对象不拥有派生的连接任务；同时发布连接与验证request存活的顺序相反。
- 建议解法：为每项request维护absolute deadline，把剩余预算传入`tcp.connect(...,{timeout=remaining})`及TCP reads；在持锁/建连前后和每次write前核对request generation。连接成功后先确认至少仍有live request需要它，再原子发布并启动recv loop；request结束或reconfigure时取消/关闭尚未完成的专用connect，避免旧task继续写包。若共享单一TCP连接，应由独立的per-server连接管理器拥有connect及pending队列，而不是由某一request的fallback task拥有。
- 回归测试：修复阶段覆盖TC后TCP黑洞、连接恰在deadline前后完成、caller timeout短于共享request、重复TC、多request等待同一server lock及reconfigure；断言deadline后无pending connect/task/socket、不会发布迟到连接或发送已结束request。当前不运行这些场景。

### DNS-007 — P2 — public timeout 在每个 CNAME/search 候选上重新计时，无法限制整次解析耗时

- 状态：已确认；公开参数契约与递归/search调用链的确定性静态核对。本轮不构造慢resolver或长CNAME链。
- 位置：API把timeout描述为一次lookup/resolve的query timeout在`docs/src/en/reference/net/dns.md:85-150`；每次`query`独立创建caller timer在`lualib/silly/net/dns.lua:424-475`；CNAME递归原样复用完整timeout在`:547-571`；初始名与每个search suffix又各自调用`resolve_r(...,timeout,...)`在`:585-640`。
- 触发：响应给出只含CNAME而目标名需要另查，或配置一个/多个search suffix且前面的候选超时/失败；每一步都可以接近调用方传入的timeout才结束。CNAME深度上限为100，search list在程序配置和resolv.conf parser中没有数量上限。
- 影响：调用`dns.lookup(name,type,5000)`不能保证约5秒内返回：两跳CNAME可消耗约10秒，初始名加多个search候选可线性乘大，组合时进一步放大。依赖该参数实现请求SLA、shutdown或资源上限的上层会被长期阻塞；每一阶段的inflight waiter/timer也随之延长存活。
- 证据：`query`对每次wire query执行`time.after(timeout, query_timer, trans)`；`resolve_r`递归时未减去已耗时间，`resolve`的search loop也给每个候选传入同一原始值。代码没有记录入口时间、absolute deadline或remaining budget。内部`conf_timeout/conf_attempts`只控制共享wire request，不构成公开调用的总deadline。
- 根因：timeout被建模为“当前query wait上限”，但公开入口及调用者把它暴露为整项解析参数；递归与候选搜索之间没有统一的operation context。
- 建议解法：入口把timeout一次转换为monotonic absolute deadline；每次cache miss、CNAME递归、search候选、nameserver轮转及TCP fallback都传递同一deadline并只等待`max(0, deadline-now)`。到期后把当前caller从共享request安全移除而不伤害其他deadline更长的waiter，并返回一致的`ETIMEDOUT`；另将内部每attempt上限取配置值与剩余预算的较小者。
- 回归测试：修复阶段覆盖多跳CNAME、多个search候选及二者组合，让每步在预算边缘响应；断言总wall time不超过单一deadline容差、cache hit不额外耗时、短deadline caller退出不取消长deadline caller。当前不运行慢响应场景。

### DNS-008 — P2 — NXDOMAIN 与 NODATA provenance 被抹平，name error 被错误地按 qtype 缓存

- 状态：已确认；RFC negative caching key与C parser→Lua cache结构的确定性静态核对。本轮不发送NXDOMAIN/NODATA响应。
- 规范：[RFC 2308 §5](https://www.rfc-editor.org/rfc/rfc2308.html)区分NXDOMAIN与NODATA：NXDOMAIN cache entry绑定`<QNAME,QCLASS>`，对该名字的所有type生效；NODATA才绑定`<QNAME,QTYPE,QCLASS>`。两者必须保留response type以便正确查找和重传。
- 位置：C parser读取但不向Lua返回RCODE在`luaclib-src/ldns.c:516-592`；SOA和无SOA的NXDOMAIN都被映射为当前qtype record在`:288-298,407-438,471-509,587-590`；Lua cache固定按`name→qtype`组织和查找在`lualib/silly/net/dns.lua:32-45,99-126,478-514`。
- 触发：对某名字的A查询收到权威NXDOMAIN，随后在negative TTL内查询同名AAAA、SRV或其他支持类型；并发或上游状态不一致时，不同qtype也可能分别收到互相冲突的name existence结果。
- 影响：已确认不存在的名字仍按每个qtype重复访问网络，放大NXDOMAIN流量、延迟和上游压力；更重要的是resolver无法维持“该名字不存在”的一致cache语义，后续另一type的positive/伪造回答可与仍有效的NXDOMAIN并存。反向若简单共享当前type-negative又会错误地把NODATA扩大为整名不存在，因此现有返回结构无法在Lua层正确修补。
- 证据：`lanswer`局部变量`rcode`只用于允许0/3和决定无record时是否创建默认negative RR，五个返回值中不含rcode/negative kind。`parse_rr_soa`无论RCODE为何都把SOA owner改成question name、rtype改成question qtype；`try_create_rr`及`lookup_server`只能命中当前qtype，没有name-level NXDOMAIN entry或CLASS维度。
- 根因：wire parser把negative answer降格成“没有rdata的普通qtype RR”，丢失了NXDOMAIN/NODATA分类与authority provenance；cache schema随之无法表达RFC要求的不同key。
- 建议解法：parser明确返回rcode、answer/authority section与经校验的SOA negative TTL；cache分别建模name-level NXDOMAIN和type-level NODATA并保留CLASS=IN。positive answer写入前按RFC规则使冲突negative entry失效，negative命中时保持CNAME语义；不得把additional/unrelated SOA当negative proof。
- 回归测试：修复阶段覆盖A-NXDOMAIN后AAAA/SRV均不发包、A-NODATA后AAAA仍可查询、NXDOMAIN+CNAME、无SOA默认策略、TTL到期、positive/negative替换与不同CLASS；断言query计数和cache冲突规则。当前不构造响应。

### DNS-009 — P2 — 普通非尾随点域名的 query encoder 构造越过 one-past-end 的指针

- 状态：已确认；C指针算术与公开正常查询路径的确定性静态推导。本轮不执行DNS查询或依赖sanitizer触发。
- 语言约束：C只允许构造数组元素或one-past-end指针；即使随后不解引用，把指针推进到one-past-end之外也属于未定义行为。正常域名编码必须在所有编译器/优化级别下保持定义良好。
- 位置：wire QNAME encoder在`luaclib-src/ldns.c:143-159`；公开resolver对无尾随点名字调用`question`在`lualib/silly/net/dns.lua:424-455,585-640`。同类已归档边界模式见`ADDR-002`，但本条属于独立DNS编码器和不同公开触发。
- 触发：调用`dns.lookup/resolve("example.com",...)`或任何最后一个label后没有`.`的正常名字；绝大多数应用输入以及search候选都满足。带尾随点的FQDN最后一次推进恰好到`end`，不触发这一具体越界构造。
- 影响：最后一轮`memchr`未找到dot而令`dot=end`、`len=end-p`；写完label后执行`p += len + 1`得到`end+1`。虽然while下一次比较通常立即结束且未解引用该指针，标准仍不定义这一执行，优化器和UB sanitizer可据此产生告警或不可移植行为；每个普通DNS query都落入该路径，使发布构建的基础wire encoder依赖偶然ABI表现。
- 证据：循环条件只在迭代开头检查`p < end`；无dot分支没有在写完最终label后break，而是无条件执行与“越过dot”共用的`+1`。合法C数组只提供到`end`的one-past位置，不提供`end+1`。输入已由`validname`验证并不能改变指针算术规则。
- 根因：用同一指针推进表达“跳过找到的dot”和“处理没有dot的最后一段”，但后一种情况不存在可跳过的分隔字节。
- 建议解法：在`dot == end`时写完label后直接`p=end; break`，只有真实找到`.`才赋值`p=dot+1`；或改用剩余长度/index循环，确保所有中间指针始终在`[start,end]`。尾随点应作为显式分支处理，避免再次靠zero-length隐式跳过。
- 回归测试：修复阶段对单label、多label、63-byte label、253-byte name、尾随点及search拼接做固定wire vector；在UBSan与高优化构建下编码普通名字零告警，结果QNAME恰以一个root zero结束。当前只保存静态证据。

### DNS-010 — P2 — RR 解析失败被降格为跳过/提前结束，malformed response 的有效前缀仍会提交缓存

- 状态：已确认；C parser返回值、Lua response提交与公开类型契约的确定性静态核对。本轮不构造截断DNS消息。
- 协议/解析契约：DNS header中的section counts定义消息包含的RR数量；声明的任一RR结构截断或已支持类型的RDATA畸形时，整条response必须判为malformed，不能把此前解析的记录当作完整答案提交。合法但不支持的TYPE可以按其RDLENGTH安全跳过，这与结构解析失败必须区分。
- 位置：RR循环与返回值在`luaclib-src/ldns.c:441-509`，`lanswer`无条件返回records在`:516-592`；Lua提交cache并完成request在`lualib/silly/net/dns.lua:204-253`。类型声明`lualib/types/silly/net/dns/c.lua:34-39`明确声称任何parse failure返回nil。
- 触发：matching response声明两个answer，第一个为合法A/AAAA/CNAME/SRV，第二个RR name/fixed header/RDATA在消息末尾截断；或者声明一个已支持TYPE但使用过短A/AAAA、坏CNAME pointer或不完整SRV/SOA。前者最直接产生非空有效前缀。
- 影响：`answer`仍返回正常id/name/qtype及records table，`dispatch_resp`把前缀记录清空并替换对应cache、重置server failcount，再以成功唤醒所有waiter；调用方得到攻击者/故障resolver提供的“不完整但看似成功”结果，而不是等待另一个合法响应或失败。只有畸形记录时也会把请求按成功结束并可能清除旧cache，造成错误NODATA语义。TCP fallback同用此parser，因此不局限UDP。
- 证据：`push_rrs`中`parse_rr_begin<0`只执行`break`，随后直接返回已提交数量n，没有“是否遍历count项”状态；`push_rr`对已知RDATA解析失败与unsupported TYPE都返回-1，caller统一不入结果但继续下一RR。`lanswer`只在`total_rr>1000`时恢复stack/return nil，从不检查RR loop是否完整；Lua只以`records==nil`识别server failure，空表和有效前缀都属于成功。
- 根因：parser把“输出中不包含该RR”同时用于unsupported-but-well-formed与malformed两种结果，外层又只返回成功记录数，失去transactional parse状态。
- 建议解法：RR parser返回三态`OK/SKIP/MALFORMED`并始终先完整验证owner、fixed header和RDLENGTH；合法unknown TYPE只SKIP，任何结构/已知RDATA失败立即回滚records table并让`lanswer`返回nil。只有严格消费完header声明的全部section count后才能发布records；section边界/来源还需与`DNS-002/008`一起保留。
- 回归测试：修复阶段覆盖每个RR name/fixed/RDATA字节的截断、合法第一项+坏第二项、坏第一项+合法第二项、unknown合法TYPE、unsupported TYPE后合法A及TC路径；malformed响应必须零cache改动且request继续等待合法response，unknown合法项可跳过。当前只保存静态证据。

### DNS-011 — P2 — caller timer 创建晚于 singleflight waiter 发布，参数异常会遗留 dead waiter 并打断共享完成

- 状态：已确认；公开timeout、timer C边界、task状态与DNS singleflight完成顺序的确定性静态推导。本轮不传入超范围timer或运行并发复现。
- 并发/异常契约：加入共享inflight request必须是事务操作；任何参数校验或timer创建失败都不能把未再等待的coroutine发布给其他完成者。一个caller的错误也不能阻止同一DNS query的其他合法caller完成。
- 位置：waiter字段写入和timer创建顺序在`lualib/silly/net/dns.lua:424-475`；timer binding对`timeout>UINT32_MAX`抛错在`luaclib-src/ltime.c:14-27`；共享完成遍历/wakeup在`dns.lua:175-200`，task只允许唤醒WAIT状态在`lualib/silly/task.lua:177-190`。双语DNS reference只声明timeout为integer milliseconds，位于`docs/src/{en/,}reference/net/dns.md:85-150`，未给上限。
- 触发：调用`dns.lookup/resolve(name,type,UINT32_MAX+1)`；在该name已有其他正常caller加入同一inflight时影响最清楚。timer allocator/内部异常也会落入相同发布窗口，但不作为本条成立条件。
- 影响：DNS query已经发送，当前coroutine先被写入`request.waiting`，随后`time.after`抛`expire too large`使caller task异常退出，且没有finally清除waiting entry。response或retry终局调用`finish_req`时遍历到dead coroutine，`task.wakeup`再次抛错并中止循环；排序在它之后的合法waiter收不到真实结果，只能等各自caller timeout。完成函数虽已删除inflight，但waiting表和req仍可能被其他timer引用，错误从一个参数调用扩散到共享并发请求。
- 证据：`trans.co/trans.req/request.waiting[co]`三项均在`time.after(timeout,...)`之前提交，且函数没有`pcall`或to-be-closed rollback。`ltime.c`对大于32-bit毫秒明确`luaL_argerror`，不是普通返回值。`finish_req`在for循环中直接调用wakeup且不检查task status/保护单项，第一处异常会跳过余下waiter。
- 根因：caller-local timer acquisition发生在共享状态发布之后；waiter集合存裸coroutine，没有operation generation/status与幂等`finish_waiter`边界。
- 建议解法：公开入口先验证timeout为允许范围内的非负整数，并在发布waiting之前成功创建timer；若后续任一步失败，用guard取消timer并撤回entry。waiter保存operation对象及其timer，所有response/reconfigure/caller-timeout路径调用不抛异常的幂等finish；唤醒前验证operation仍active，单个异常不得中断其他waiter。
- 回归测试：修复阶段覆盖`-1/0/UINT32_MAX/UINT32_MAX+1`、非整数、timer创建失败及1个坏caller与多个正常caller共享请求；非法调用零wire/零waiting残留，合法caller仍收到原response且每个operation只完成一次。当前只保存静态证据。

### DNS-012 — P2 — `dns.conf` 在验证新配置前销毁健康 resolver，异常会留下空或半配置状态

- 状态：已确认；公开配置函数的语句顺序、地址工具与双语契约静态核对。本轮不执行reconfigure或传入错误配置。
- 配置契约：替换全局resolver应采用validate/build/commit；新配置无效时必须在触碰旧连接、inflight、cache和选项前同步拒绝，不能让普通配置错误造成不可回滚的全局解析中断。
- 位置：`dns.conf`的teardown、全局重置和逐字段应用在`lualib/silly/net/dns.lua:394-411,757-808`，地址规范化在`:91-97`与`luaclib-src/laddr.c:95-120`；双语公开配置说明位于`docs/src/{en/,}reference/net/dns.md:183-224`。
- 触发：活动resolver上调用`dns.conf(nil)`、`nameservers=false`、nameserver/search元素为非字符串、timeout/attempts/ndots为不可比较类型，或其他使后续Lua/C helper抛错的值。字符串形式畸形nameserver还会被无错误转换为`:53`并延迟到查询失败。
- 影响：函数首先对所有inflight返回`"Dns reconfigured"`并关闭每个UDP/TCP connection，随后把`servers/search_list`替换为空表并恢复默认值；后面的参数访问、`#`、`lower`、数值比较或地址helper一旦异常，旧resolver已经不可恢复，新resolver只完成了部分字段甚至没有nameserver。调用方捕获异常继续运行时，全进程DNS会稳定返回`No nameserver`/`Send failed`，直到另一次完整配置成功；健康查询也已被无谓终止。
- 证据：入口第一句是`close_servers()`，其后才第一次读取`opts.nameservers`；函数没有type/range/endpoint validation、候选局部对象或protected rollback。`ns_addr`不检查`parse_addr`结果，nil host会被`join_addr(nil,"53")`编码为`:53`。此外空nameserver table被原地写入`nameservers[1]="8.8.8.8"`，说明candidate与caller对象也未隔离。
- 根因：全局mutable配置被按“先清空、再就地填充”实现，把不可失败的commit放在所有可失败validation之前；API没有错误返回或schema校验层。
- 建议解法：先在局部candidate中严格验证opts table、每个endpoint可解析且host/port完整、search name合法、timeout/attempts/ndots为定义范围内integer，并复制所有caller table；成功后一次交换配置generation，再结束旧generation请求/连接。失败应返回`false,error`或同步抛出但保持旧generation完全不变，且所有recv/timer callback按generation忽略迟到事件。
- 回归测试：修复阶段在健康cache、活动UDP query和TCP fallback三种状态下逐字段传nil/错误类型/空/畸形地址/边界数值；失败后旧查询与新lookup仍使用原resolver、全局配置深度相等、caller table不变。合法commit才恰好终止旧generation一次。当前只保存静态证据。

### DNS-013 — P2 — 发送 EDNS0 OPT 却丢弃 response extended RCODE/version，扩展错误被误报为成功空答案

- 状态：已确认；RFC 6891 OPT wire定义与query/response codec的确定性静态核对。本轮只查RFC原文，不发送EDNS流量。
- 协议规范：[RFC 6891 §6.1.2-6.1.3](https://www.rfc-editor.org/rfc/rfc6891.html#section-6.1.3)定义OPT TTL字段包含8-bit EXTENDED-RCODE与8-bit VERSION；完整RCODE由该高8位和DNS header低4位组成。发送OPT的requestor必须按完整transaction控制信息解释response，不能把OPT当普通未知RR丢弃。
- 位置：query无条件附加EDNS0 version0 OPT在`luaclib-src/ldns.c:127-201`；response header只取4-bit RCODE在`:516-579`；RR parser虽然读到所有RR的TTL，但TYPE=OPT统一skip在`:300-329,441-467`。Lua将空records当成功提交在`lualib/silly/net/dns.lua:204-253`。
- 触发：resolver返回header RCODE低4位为0、OPT extended RCODE非0的错误，例如EDNS BADVERS；也包括response声明非零EDNS VERSION或malformed/重复OPT，而question/id/type均匹配当前请求。
- 影响：实现计算`rcode=0`，忽略携带扩展错误的OPT，再以空records table完成request、把目标qtype旧cache清成过期/negative形态并重置nameserver failcount。调用方最终得到`Not found`而非server/protocol错误，可能把能力协商、策略或resolver故障误判成域名不存在；重试和备用nameserver选择也不会按真实失败语义运行。
- 证据：`q_opt`固定ARCOUNT=1、TYPE41、version0，证明本端主动使用EDNS。`lanswer`的RCODE mask仅为`0x000F`；`parse_rr_begin`读取OPT TTL到`ctx.ttl`后，`push_rr` default直接返回-1且没有任何位置提取extended RCODE/version。records非nil即走success，空table不会触发`Server failure`。
- 根因：OPT被当成“unsupported data record”跳过，而不是DNS message级控制元数据；header解析和additional-section解析之间没有共同的完整RCODE/EDNS状态对象。
- 建议解法：保留section与OPT provenance，严格要求response最多一个合法root-owner OPT；组合`full_rcode=(ext_rcode<<4)|header_rcode`并验证version/flags/options，再决定成功、BADVERS或其他错误。未知option按RFC忽略，但OPT本身不能忽略。是否短期无EDNS重试可按RFC 6891 §6.2.2与产品策略实现，不能用降级掩盖extended error。
- 回归测试：修复阶段覆盖无OPT普通RCODE、合法OPT ext=0/version0、BADVERS、其他extended RCODE、非零version、重复OPT、非root owner及unknown option；扩展错误不得产生negative cache或成功结果，后续合法response仍可完成。当前只保存静态证据。

### DNS-014 — P2 — RRset cache 只采用首条 TTL，未按 RFC 2181 收紧到组内最低值

- 状态：已确认；RFC 2181 RRset TTL规则与Lua cache提交循环的确定性静态核对。本轮只查RFC原文，不发送TTL不一致响应。
- 协议规范：[RFC 2181 §5.2](https://www.rfc-editor.org/rfc/rfc2181.html#section-5.2)规定同一label/class/type的RR组成RRset且TTL必须一致；client从其配置的server收到不一致TTL时，应对所有用途按组内最低TTL处理。不能让wire顺序决定整组缓存寿命。
- 位置：response record生成保留逐条TTL在`luaclib-src/ldns.c:274-285,441-509`；server cache按首见RR设置一次expiry在`lualib/silly/net/dns.lua:229-245`，同次transaction merge则固定maxinteger在`:128-148`；cache命中在`:495-514`。
- 触发：matching A、AAAA或SRV response包含同owner/type的多条rdata，第一条TTL高、后续一条TTL低；错误或中间设备造成的异TTL RRset即可，调用方无需特殊配置。
- 影响：`seen[cache_rr]`使只有第一条执行`clear_rr(rr,now+ttl)`，后续记录只append，较低TTL完全丢失；整组地址/服务会在最短权威寿命之后继续从cache返回。下线节点、安全轮换、服务发现权重/成员变化可能长期不可见，且攻击者/故障resolver可仅调整记录顺序选择高TTL。若低TTL恰在首位则提前过期，行为同样由wire顺序而非RRset语义决定。
- 证据：C records table为每条RR独立保存`rec[3]`。Lua循环第一次见到对象时设`seen`并写expiry，第二次起不再比较TTL或修改`cache_rr.ttl`。`merge_records`又把transaction-local RR设为`math.maxinteger`，所以没有其他层对同组TTL取min；现有multiple A/AAAA/SRV测试统一TTL，无法覆盖。
- 根因：cache builder把“首条时清空旧RRset”与“确定新RRset统一expiry”合并成一次操作，没有先验证/聚合完整RRset元数据。
- 建议解法：先按section/class/owner/type分组并验证完整RRset，计算minimum TTL（也可记录异TTL诊断），再一次性替换cache与expiry；不得跨trust来源/section拼组，需与`DNS-002/010`共同修复。transaction-local结果可以在当前调用内使用，但持久cache必须遵守minimum deadline。
- 回归测试：修复阶段覆盖TTL顺序`high,low`与`low,high`、三条不同TTL、统一TTL、A/AAAA/SRV、同owner不同type和不同section；两个顺序都必须在同一最低TTL到期，且到期后重新查询整组。当前只保存静态证据。

### DNS-015 — P1 — 每个查询名字永久留在 server cache，过期、失败与 TTL=0 均无淘汰

- 状态：已确认；name cache创建、查询终局与命中路径的确定性生命周期静态核对。本轮不生成高基数查询或做内存压力。
- 资源契约：TTL cache必须回收过期/无效entry并有per-server/global name与byte预算；查询临时identity不能无条件升级成永久cache节点。失败或明确不可缓存的TTL=0响应结束后，不应保留只用于singleflight的空对象。
- 位置：`name_cache`与RR intern在`lualib/silly/net/dns.lua:32-46,99-126`；每次cache miss在发包前创建RR于`:424-455`；成功/失败只清inflight在`:175-200,204-253`；lookup遇过期只返回miss而不删除在`:478-545`。唯一整体释放是`dns.conf`替换server对象在`:757-808`。
- 触发：持续解析大量互不相同的合法hostname；上游可正常返回TTL=0、NX/NODATA、超时或send失败，均能增长。应用若接受用户URL、tenant域名、service-discovery key或代理目标，外部请求可间接提供这些名字；结合`DNS-002`，单个response还可携带最多约1000个无关owner加速增长。
- 影响：`try_create_rr`为每个name永久保存name-key、by-name table、RR table及元数据；失败后`finish_req`只删`inflight[rr]`，TTL=0不写持久数据但空RR仍保留，expired positive/negative也从不evict。进程生命周期内heap和GC扫描集合随历史唯一名字单调增长，攻击者或高基数正常流量可最终耗尽内存；TTL文档所称“过期”只表示不命中，不表示释放资源。
- 证据：`name_cache[name]=by_name`和`by_name[qtype]=rr`没有任何反向删除语句。`clear_rr`只清数组rdata并改ttl，不删除RR或空name bucket。`lookup_server`检查`ttl>=now`失败后直接return nil；没有LRU、timer、size/byte cap、negative/empty admission或metrics。`close_servers`不清当前server cache，只有随后`servers={}`失去整组引用。
- 根因：同一个永久intern table同时承担cache与inflight dedup identity；为方便用RR对象作`inflight` key，所有查询名字都被提升为强引用cache entry，TTL没有对应的storage lifecycle。
- 建议解法：把transaction key与cache entry分离，inflight用canonical `(server-generation,name,qtype,class)` key；只在完整可缓存response提交时创建cache RRset。实现按deadline的expiry queue/timing wheel或有界LRU，命中/周期扫描时删除过期RR及空name bucket，并设置per-server/global entry/byte hard cap与可观测eviction；TTL=0和失败仅保留当前operation结果，不持久化。
- 回归测试：修复阶段用小cap/可控clock覆盖大量唯一成功、TTL0、NX、timeout、send失败、CNAME/additional与重复热key；过期/失败对象回到基线，cache entries/bytes不超过cap，singleflight仍合并同key且eviction不破坏在途request。当前只保存静态证据。

### DNS-016 — P2 — Windows resolver 配置扩容分配未检查，OOM 时把 NULL 传给系统 API

- 状态：已确认；Windows resolver bootstrap 的两次调用契约与本地分配路径静态核对。本轮不做allocator故障注入或启动Windows进程。
- API契约：[Microsoft `GetNetworkParams` 文档](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getnetworkparams)要求调用方为`FIXED_INFO`输出缓冲区分配内存；官方示例在第二次调用前明确检查分配结果。不能把`NULL`作为所需长度的输出buffer再次调用。
- 位置：`src/win/win.c:295-329`，尤其`ERROR_BUFFER_OVERFLOW`分支的`malloc(buf_len)`与紧随其后的第二次`GetNetworkParams(info,&buf_len)`。
- 触发：初始栈上`FIXED_INFO`不足，API按正常约定返回`ERROR_BUFFER_OVERFLOW`和所需大小；随后heap分配因进程内存压力、地址空间碎片或allocator故障返回`NULL`。
- 影响：实现仍以`info==NULL`调用系统API，违反其输出缓冲区前置条件；具体系统版本可能返回错误，也可能在native调用内触发access violation，使`require("silly.net.dns")`或进程启动直接终止。即使系统恰好返回错误，调用方只得到nil并退回硬编码resolver，真实原因没有结构化诊断，系统DNS配置也被静默绕过。
- 证据：分支对`malloc`结果没有任何判断；第二次调用无条件发生。后续仅按API result区分成功/nil，无法识别本地OOM；`free(NULL)`本身安全，但不能补救此前的无效API调用。仓库其他可增长buffer使用受检分配器，而这条Windows专用bootstrap路径直接使用raw `malloc`。
- 根因：采用Win32常见的probe-size/reallocate/retry模板时遗漏了中间allocation failure状态，把“获得required size”误当作“已获得可用buffer”。
- 建议解法：分配后立即检查；失败时不要再次调用API，返回明确的Lua错误或至少记录OOM并让上层决定是否使用fallback。更稳妥的是使用项目统一的checked allocator，同时为异常大`buf_len`设置`SIZE_MAX`/合理上限检查，并保证所有退出路径只有一个owner释放buffer。
- 回归测试：修复阶段以Windows allocator shim令第二次分配确定失败，断言不会再次调用`GetNetworkParams`、不会解引用NULL、错误可诊断且无泄漏；再覆盖栈buffer一次成功、overflow后二次成功、二次API失败。当前只保存静态证据。

### DNS-017 — P3 — Windows hosts 路径拼接复用 MAX_PATH 缓冲区，合法长系统目录会被静默截断

- 状态：已确认；Win32 path-length返回契约与固定缓冲区拼接的算术静态核对。本轮不修改系统目录或读取真实hosts文件。
- API契约：[Microsoft `GetSystemDirectoryA` 文档](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getsystemdirectorya)说明成功返回值只是不含NUL的系统目录长度；只有目录本身超出传入buffer时才返回required size。它不为调用方随后追加的路径片段预留空间。
- 位置：`src/win/win.c:351-362`；`syspath`和`hostspath`都固定为`MAX_PATH`，入口只验证`len < MAX_PATH`，然后用未检查返回值的`snprintf(hostspath,sizeof(hostspath),"%s\\drivers\\etc\\hosts",syspath)`追加18字符后缀。
- 触发：`GetSystemDirectoryA`成功返回长度242至259字符的合法system-directory路径。目录本身及NUL能通过现有检查，但追加18字符后缀及NUL需要261至278字节，超过260字节的传统`MAX_PATH`缓冲区。
- 影响：标准`snprintf`会保证终止但截断目标路径，返回值完全未检查；随后的`fopen`读取错误位置并通常返回nil。DNS模块继续初始化，不给出截断诊断，系统hosts中的本地名称、运维覆盖和安全阻断规则被静默忽略，查询转而发给resolver；短默认安装路径不受影响。
- 证据：两个数组容量相同，而目标串严格长于源串；`len >= MAX_PATH`检查只能证明`syspath`未截断，不能证明目标拼接可容纳。代码不比较`snprintf`返回值与`sizeof(hostspath)`，`push_file`也把所有open失败统一折叠为nil，故无法在上层区分“没有hosts文件”和“内部路径截断”。
- 根因：把producer API的source-buffer成功条件误用为derived-path的容量证明，并沿用固定`MAX_PATH`而未按实际长度分配目标字符串。
- 建议解法：用`len + sizeof("\\drivers\\etc\\hosts")`做checked size计算并动态分配，或使用支持长路径的Unicode Win32 path API；必须检查格式化返回值并把截断/打开失败作为可诊断状态传给Lua。不要仅把目标数组再放大一个常量而继续忽略返回值。
- 回归测试：修复阶段stub `GetSystemDirectory`覆盖长度241、242、259、required-size及failure，断言生成路径完整、无截断/越界，且打开失败保留可区分原因；另覆盖非ASCII/Unicode系统路径。当前只保存静态证据。

### DNS-018 — P1 — 系统 resolver 配置读取失败时自动改用公共 8.8.8.8，绕过本机 DNS 策略

- 状态：已确认；Unix/Windows配置入口、模块初始化fallback与公开默认行为的确定性静态核对。本轮不删除配置文件、不改权限，也不向公共resolver发送查询。
- 安全契约：读取系统DNS策略失败与“系统明确配置公共resolver”不是同一状态；网络库不得在没有调用方显式授权时把原本应由本机resolver处理的查询转交固定第三方。配置不可用应fail closed并保留可诊断原因，或只使用显式opt-in的fallback。
- 位置：Unix固定读取`/etc/resolv.conf`在`src/unix/unix.h:57-58`和`src/unix/unix.c:154-181`；Windows合成配置在`src/win/win.c:295-329`；无内容的自动fallback在`lualib/silly/net/dns.lua:742-747`。程序化空列表同样被改写为Google DNS在`:766-774`。
- 触发：Unix下`/etc/resolv.conf`不存在、不可读、被沙箱隐藏或open失败；Windows下`GetNetworkParams`失败；也包括调用方传入空`nameservers`本意为禁用外部DNS。模块加载仍成功并建立固定server entry。
- 影响：后续hostname、service-discovery和SRV查询被发往`8.8.8.8:53`，绕过VPN、企业审计/过滤、DNSSEC/加密stub、容器注入与split-horizon策略；内部服务名、tenant名或用户目标会离开预期信任边界。公共DNS还可能为内部名字返回不同结果，使连接错误目标；在禁止直连公网DNS的环境则把清晰的配置错误变成反复超时。单条warn日志不能授权或修复这种策略变化。
- 证据：`c.resolvconf()`返回nil后唯一分支把内容硬编码为`"nameserver 8.8.8.8"`并继续`parse_resolvconf`；没有启动配置、环境变量或API opt-in。底层`push_file`把open/read失败统一为nil，Windows也把所有API错误统一为nil，因此上层甚至不能根据失败原因选择安全策略。`dns.conf`对省略/空list同样无条件插入该地址，并会原地修改调用方空table（另见`DNS-012`）。
- 根因：把“保证总有nameserver”的可用性默认置于系统网络策略之上，并把配置读取错误、无配置和调用方显式空配置折叠为同一个公共服务默认值。
- 建议解法：自动初始化读取失败时保持无resolver并返回带cause的`No nameserver`，同时提供明确日志/health metric；若产品确需公共fallback，必须由启动参数或`dns.conf`显式启用并可选择地址。区分missing/permission/parse/API/OOM，避免故障原因丢失；空列表应表示禁用或被明确拒绝，不能静默改写调用方数据。
- 回归测试：修复阶段stub Unix open失败、Windows API失败、空文件、无nameserver内容与显式空list，断言默认不会创建任何公共endpoint或发送包、错误保留cause；另覆盖显式opt-in后才使用调用方指定fallback。当前只保存静态证据。

### CLUSTER-001 — P1 — RPC response 只按全局 session 匹配，可跨 peer 注入或串话

- 状态：已确认；wire header、C→Lua返回值与wait table调用链的确定性推导。本阶段不构造伪ACK frame。
- 位置：全局session生成与ACK解析在`luaclib-src/lcluster.c:31-49,333-366,398-437`；C pop返回fd/session在`:294-331`；Lua response dispatch忽略fd在`lualib/silly/net/cluster.lua:52-95`；wait_pool注册在`:238-258`。
- 触发：节点同时连接多个cluster peer；任一peer发送ACK_BIT置位且session等于当前另一peer在途调用的response frame。session是进程全局递增值，连接双方可从自己收到的request观察相邻值并预测；运行足够久发生2^31 wrap时，旧连接的late ACK也可与新调用碰撞。
- 影响：攻击/错误peer可抢先完成发往另一节点的RPC，让调用方把攻击者body交给原cmd的`unmarshal`并接受伪造结果；真正response随后变成unknown/late ACK。即使peer都可信，重连、延迟与wrap也会造成跨请求错误归属，破坏RPC完整性和业务状态。
- 证据：`c.pop(ctx)`明确返回`fd,buf,session,...`，但`cmd==nil`分支只执行`co=wait_pool[session]`并立即清除/wakeup，没有比较fd、peer generation、cmd或request nonce。`wait_pool`值只是coroutine；C ACK header也只有32-bit session。session generator为单一static counter且不避开仍active id。
- 根因：session被视为全进程唯一且永不碰撞，response correlation没有绑定transport identity/lifecycle；C层已经保留fd provenance但上层丢弃。
- 建议解法：pending key至少使用`(fd generation,session)`，值保存co/cmd/peer/request generation；分配session时跳过该connection仍active的值。response必须验证同一live peer generation后才能consume pending项，unknown/late response按协议策略丢弃或关闭该peer。更强方案为每连接随机起点+足够宽nonce，若跨不可信节点使用还需TLS mutual auth/message authentication。
- 回归测试：修复阶段建立A/B两个peer，让B发送A的active session ACK，断言A waiter不被唤醒且B按策略报错；覆盖断线重连同slot、late response、强制session wrap和同session不同fd并发。当前不构造伪ACK。

### CLUSTER-002 — P2 — peer 断开不结束其 pending RPC，调用只能等到 timeout

- 状态：已确认；pending table与两个close路径的确定性推导。本阶段不新增disconnect timing复现。
- 位置：`wait_pool`定义/response/timer/wait注册在`lualib/silly/net/cluster.lua:46-47,84-91,114-151,226-258`；request send在`:260-293`。
- 触发：一个或多个`cluster.call`已发送并进入`task.wait()`后，peer远端关闭、发生socket错误，或本地调用`cluster.close(peer)`；timeout可配置为任意较长值。
- 影响：已经确定无法从该transport获得响应的所有coroutine仍保持WAIT，`wait_pool`和timer持续存活到timeout；调用方延迟错误处理/重连，关闭阶段可积累大量无效tasks。主动close同样不取消调用，若timeout设置很长会表现为业务挂起和有界但长期的内存占用。
- 证据：`wait_pool[session]`只保存co，不保存fd/peer。`close_fd`仅clear C incomplete frame、close socket和更新peer/callback；`close_peer`只清peer/socket maps，两者都不遍历或索引pending。唯一清理点是matching response或`timer_func`。
- 根因：request生命周期只按session建立单向timer，没有归属peer的反向索引，也没有将transport terminal event作为所有在途RPC的终态。
- 建议解法：pending entry保存fd generation/peer/cmd/timer/co，并在peer维护active session set；任何close路径原子摘除该generation全部pending、cancel timers并以实际close errno唤醒。response/timeout/close竞争都用单一`finish_pending`保证恰好完成一次；可重连peer不得把旧调用迁移/静默重放到新连接。
- 回归测试：修复阶段并发多个call后分别触发EOF、RST、local close和connect replacement；断言所有waiter立即返回对应错误、timer取消、wait tables清空，late response/late timer不二次wakeup。当前不新增断线复现。

### CLUSTER-003 — P2 — unknown/late ACK 对 nil coroutine 执行 wakeup，可被持续触发异常与日志

- 状态：已确认；response dispatch与task状态检查的确定性推导。本阶段不发送ACK flood。
- 位置：cluster response分支在`lualib/silly/net/cluster.lua:52-95`；timeout删除pending在`:226-258`；`task.wakeup`状态校验在`lualib/silly/task.lua:178-190`。
- 触发：peer发送任意ACK_BIT frame，其session从未分配、已timeout/完成、重复，或因`CLUSTER-001`来自错误连接；合法response与本地timeout相邻到达也可产生late ACK。
- 影响：`wait_pool[session]`为nil，代码仍清slot并`task.wakeup(nil,buf)`，触发`BUG: wakeup on task stat:nil`异常与完整traceback日志。`process`在处理当前packet前已经`task.fork(process)`，异常不会关闭peer；恶意peer可用最小4-byte body持续生成coroutine异常、日志I/O和CPU负载，并干扰诊断。
- 证据：response分支没有`if not co`检查。`task.wakeup`只允许WAIT task，否则主动`error`。C parser只要求ACK packet body至少4字节并不验证session active，因此任意32-bit ACK session都能进入该分支。
- 根因：RPC协议把所有ACK默认假设为本地active request，没有为unmatched/duplicate/late response定义接收状态机与连接级违规策略。
- 建议解法：在验证`(fd generation,session)`pending存在后才consume/wakeup；unknown和late ACK应有bounded metric/log并按配置丢弃，重复/明显恶意流量可关闭该peer，绝不能以Lua exception作为控制流。timeout/response/close统一finish函数保留短期tombstone可区分late与never-issued。
- 回归测试：修复阶段覆盖随机、重复、刚timeout、错误fd及wrap-old ACK；断言无task异常/traceback、active waiter不变、日志限速，达到违规阈值时只关闭发送peer。当前不发送ACK flood。

### CLUSTER-004 — P2 — 主动 close 不清理该 fd 的 incomplete frame buffer

- 状态：已确认；两条close路径与C hash ownership的确定性推导。本阶段不发送大partial frame。
- 位置：remote/error close的`c.clear`在`lualib/silly/net/cluster.lua:97-114`，主动`close_peer`在`:116-128`；C incomplete hash分配/清除在`luaclib-src/lcluster.c:67-113,193-281,283-293,464-472`；net主动close同步移除callback在`lualib/silly/net.lua:149-163`。
- 触发：peer已发送完整4-byte length和部分body，使C parser为该fd分配最高接近hardlimit的`incomplete.buff`；随后本地业务调用`cluster.close(peer)`，而不是等待远端close/error。
- 影响：TCP/socket与Lua peer map被清除，但incomplete node及body allocation继续挂在全局`ctx.hash`；主动close同时移除net close callback，后续C close event不会再进入`close_fd`补做clear。每个不同sid都可遗留一块，默认单块最高128MiB，直到重新`serve`使旧ctx GC或进程退出才释放。
- 证据：`close_fd`第一句执行`c.clear(ctx,fd)`，`close_peer`没有；C `clear_incomplete`是唯一按sid摘除hash node的接口，packet GC才会全量清理。socket sid含generation，后续fd/slot复用不会命中旧key自动替换。
- 根因：主动与被动关闭没有共享统一cluster teardown；protocol parser的per-fd ownership未纳入peer对象生命周期。
- 建议解法：所有close入口调用同一个幂等teardown，先摘除peer generation的pending/complete/incomplete state，再清map和关闭socket；`c.clear`应同时考虑已完成但尚未pop的packet，或C ctx提供`clear_fd`统一释放该fd全部状态。明确listener与connection类型避免对listener误操作。
- 回归测试：修复阶段发送length=hardlimit与少量body后主动close，断言allocator立即回基线、hash无该sid；覆盖header partial、body partial、complete queued、重复close及sid复用，无double-free。当前不发送大partial frame。

### CLUSTER-005 — P1 — 合法 `UINT32_MAX` hardlimit 使 frame allocation/total 长度回绕

- 状态：已确认；配置范围与确定性unsigned arithmetic/memcpy路径推导。按要求不构造超大length或越界copy触发。
- 位置：hard/soft limit validation在`luaclib-src/lcluster.c:77-105`；接收length与allocation/copy在`:167-246`；发送request/response size计算在`:333-397,398-437`；lightuserdata length入口在`:295-304`。
- 触发：应用通过公开`cluster.serve{hardlimit=0xffffffff,...}`或直接`c.create`使用被接受的最大值。远端随后只需发送host-order length prefix `0xffffffff`及任意body字节；发送侧也可用接近上限的string，或直接C module的lightuserdata+claimed length生成接近4GiB body。
- 影响：接收侧`ic->header.psize + 1`在32-bit unsigned域回绕为0，得到零/极小allocation，紧接着把网络body复制到`ic->buff`造成heap overflow。发送侧`total=HEADER_SIZE+body`赋给uint32后回绕，按小total分配，再复制16/4-byte header和巨大payload，同样heap overflow/越界读取；可能导致进程崩溃或可利用的内存破坏。
- 证据：`lcreate`明确允许`hardval <= UINT32_MAX`；wire psize与hardlimit均uint32，validate仅比较大小。allocation表达式没有先提升到size_t或检查`SIZE_MAX-1`。pack路径虽用uint64计算body并验证，但随后无`body<=UINT32_MAX-HEADER_SIZE`检查就窄化到uint32 total。默认128MiB不会触发，不代表公开合法配置安全。
- 根因：协议32-bit body length的理论最大值被直接当作可配置资源上限，没有为NUL sentinel、外层4-byte prefix和allocation arithmetic保留空间；多个域之间缺少checked add/narrow。
- 建议解法：定义远低于`UINT32_MAX`且受`INT_MAX/SIZE_MAX`约束的绝对protocol cap；对`psize+1`、`HEADER_SIZE+body`、allocation与copy全部使用checked `size_t/uint64_t`加法，验证后才窄化wire字段。lightuserdata入口同时校验非负、实际owner范围或改opaque buffer。配置超出安全cap应立即报错。
- 回归测试：修复阶段只做checked-arithmetic单元边界，覆盖hardlimit/psize/body在cap、`UINT32_MAX-4..UINT32_MAX`及负claimed length，断言在allocation/copy前拒绝；不分配4GiB。ASan/UBSan下合法最大安全frame round-trip。当前不构造越界包。

### CLUSTER-006 — P2 — wire integers 使用 host byte order，跨端序节点无法互操作

- 状态：已确认；序列化/反序列化逐字段调用链推导。本阶段不运行big-endian peer。
- 位置：wire structs与header在`luaclib-src/lcluster.c:15-49`；length接收/发送在`:193-246,333-437`；request/response header解析在`:294-331`；协议文档在`docs/src/reference/net/cluster.md:24-37`。
- 触发：little-endian与big-endian节点之间建立cluster TCP连接，或任一独立实现按文档/通常network byte order编码；相同问题也会出现在将录制frame跨架构重放时。
- 影响：4-byte psize首先被按接收机host order解释，常见小frame会变成超过hardlimit的巨大值并断连；即使长度偶然对称，session ACK bit、cmd和64-bit traceid仍被反序，导致请求误路由、响应无法匹配或trace污染。cluster自称节点间RPC却只能在隐含同端序ABI内工作。
- 证据：所有字段均以`memcpy(&native_integer,wire,...)`或把native struct直接`memcpy`到wire，没有`htonl/ntohl`、显式shift或codec；static_assert只保证struct size 16，不能定义byte order。文档反而写“2字节长度、业务数据、trace/cmd/session”，与实际“4-byte native length + native header + body”不一致。
- 根因：进程内C布局被直接提升为网络协议，没有定义版本、字节序和逐字段wire schema，测试只覆盖同一主机/ABI。
- 建议解法：定义版本化wire format，所有u32/u64固定network(big-endian)或明确little-endian并用逐字段codec，禁止raw struct serialization；为旧同端序部署提供显式版本协商/迁移，而非启发式猜端序。同步更正文档的长度、顺序、limit语义。
- 回归测试：修复阶段使用固定golden byte vectors验证encode/decode，与独立实现互操作；通过字节交换模拟big-endian，覆盖length/session ACK/cmd/traceid及协议版本拒绝。当前不运行big-endian peer。

### CLUSTER-007 — P2 — accept 回调参数错位，incoming peer 的 `remoteaddr` 实际是 listener id

- 状态：已确认；底层event callback ABI与cluster adapter函数形参逐项静态核对。不建立监听连接。
- 位置：net accept事件以`(fd,listenid,addr)`恢复callback在`lualib/silly/net.lua:168-178`；cluster callback只接收`(fd,addr)`并写入peer在`lualib/silly/net/cluster.lua:147-163`；公开契约在`docs/src/en/reference/net/cluster.md:64-75,81-85`及中文对应位置。
- 触发：任意客户端连接`cluster.listen`创建的listener；Lua调用多余实参会被静默丢弃，因此不会立即抛错。
- 影响：`peer.remoteaddr`保存第二实参`listenid`（socket id整数），真实第三实参客户端endpoint被丢弃。accept/call/close回调若用remoteaddr做日志、allowlist、租户映射、限流或连接追踪，会记录/判断listener自身id而非远端身份；多个客户端还可能得到同一错误值。文档和类型注解均承诺string，使问题容易传播到业务层。
- 证据：`task_resume(t,fd,listenid,addr)`明确传三个业务参数；cluster的`function(fd,addr)`把第二个位置直接赋给`remoteaddr`。现有`test/testcluster.lua:359-377`只断言`accept_addr ~= nil`，socket id满足该断言，未验证string类型或与真实endpoint一致。
- 根因：net accept ABI增加/保留listener id后，cluster adapter仍沿用二参数签名；Lua宽松实参数量掩盖了接口漂移，测试又只检查存在性。
- 建议解法：改为`accept=function(fd,listenid,addr)`并把第三参写入`remoteaddr`；若业务需要同时暴露listener，显式保存受验证的listener handle/id而非复用地址字段。为event callback定义共享类型/adapter，避免各模块手写位置参数继续漂移。
- 回归测试：修复阶段从IPv4/IPv6客户端连接两个listener，断言`remoteaddr`为可解析endpoint string、不同客户端值独立，listener id单独可用且不会进入地址字段；把当前非nil断言提升为类型和值断言。当前不运行连接测试。

### CLUSTER-008 — P1 — RPC timeout 在 connect/send 之后才启动，黑洞 endpoint 可让 call 永久等待

- 状态：已确认；cluster公开timeout、lazy connect及底层timer传递路径的确定性静态核对。本轮不连接黑洞endpoint。
- 位置：配置timeout在`lualib/silly/net/cluster.lua:311-329`；lazy DNS/TCP connect在`:179-218`；timer仅由`waitfor`创建在`:251-272`；调用顺序在`:274-305`；底层TCP仅在显式传参时定时在`lualib/silly/net.lua:89-140`。
- 触发：首次call/send或断线后的自动重连进入DNS慢响应、TCP SYN被静默丢弃、connect事件迟迟不返回；即使`cluster.serve{timeout=1000}`也相同。marshal和send之前的其他yield同样不在预算内。
- 影响：业务coroutine可远超配置timeout，TCP connect路径没有参数时可等到操作系统级超时；服务shutdown、上游故障切换、请求SLA及容量隔离均失效。并发请求虽由per-peer mutex串行建连，但其余调用会一起阻塞在锁后，单个故障endpoint可积累大量task并占住socket/pending connect资源。
- 证据：`callx`先执行`connect(peer)`，其中`dns.lookup`不传cluster剩余预算且`tcp_connect(addr,EVENT)`的timeout实参缺失；随后marshal、构造frame和`tcp_send`，最后才调用`waitfor`并执行`after(expire,...)`。因此配置值完全不参与DNS/connect，且底层`connect_wrap`在timeout为nil时直接`task_wait()`无timer。
- 根因：timeout被实现成“已发送request的response wait timer”，却作为整个RPC的唯一timeout配置公开；lazy connection state没有dial deadline或可取消operation context。
- 建议解法：在`cluster.call/send`入口计算absolute deadline并把remaining预算贯穿mutex acquire、DNS、TCP connect、send admission和response wait；另允许独立`dial_timeout`但总RPC deadline始终取更早者。到期必须按peer generation关闭pending connect、从mutex wait queue安全移除、完成对应pending且不影响新generation；错误要区分dial与response timeout但保持公开opaque contract。
- 回归测试：修复阶段分别在mutex、DNS、TCP connect、send queue和response阶段停住，配置短deadline并断言总耗时受同一预算约束、socket/task/timer清零；覆盖多个caller共享connect且deadline不同、close与connect timeout相邻。当前不运行blackhole或时序场景。

### CLUSTER-009 — P2 — `send` 与 `call` 使用同一 request frame，正常 handler response 会制造 unmatched ACK

- 状态：已确认；public one-way路径、wire header与server response分支的确定性静态核对。不发送消息。
- 位置：`send/call`共用`callx`与`c.request`在`lualib/silly/net/cluster.lua:274-309`；server对所有request统一调用handler并编码response在`:64-104`；request wire没有one-way字段在`luaclib-src/lcluster.c:22-34,410-449`；文档承诺send不等待response在`docs/src/en/reference/net/cluster.md:428-448`。
- 触发：调用`cluster.send(peer,cmd,obj)`，远端正常`call` handler为该cmd返回一个非nil结果，且`marshal("response",...)`能够编码它；通用echo/统一response handler会自然满足，无需恶意peer。
- 影响：远端发送本不需要的response，浪费序列化、带宽和队列；本地`send`在发送后立即返回且从未写`wait_pool[session]`，ACK到达必然成为unknown session，触发`CLUSTER-003`的nil wakeup异常/traceback。高频notification会稳定制造异常日志和CPU开销；若仅修unknown ACK为丢弃，冗余response与协议语义错误仍存在。
- 证据：`callx(true)`仍先调用`c.request`分配普通session并发送完全相同frame，只在send成功后直接`return true`，不调用`waitfor`。request header只有session/cmd/traceid，无one-way bit；接收端也不知道调用来源，始终执行`call`，只要response marshal首返回值非nil就调用`c.response`并`tcp_send`。
- 根因：one-way只作为发送端本地等待策略实现，没有进入wire contract或server dispatch context；系统错误假设业务marshal会按cmd自行返回nil，却未在API契约要求或验证。
- 建议解法：版本化协议中增加明确one-way flag，server handler仍可执行但必须跳过response marshal/send；或定义保留session/flag并让C parser返回request kind。不能用“发送端丢弃ACK”代替，因为仍浪费远端工作与带宽。旧peer协商不支持时应拒绝one-way或提供明确legacy行为。
- 回归测试：修复阶段让统一handler总是返回对象，分别call/send同一cmd；断言call仅一条matching ACK、send零ACK且本地无pending/unknown日志。覆盖旧协议协商、handler nil/error和高频send。当前不运行peer互操作。

### CLUSTER-010 — P2 — hostname 只解析单个 A 记录，IPv6-only 与多地址故障转移不可用

- 状态：已确认；cluster endpoint解析与DNS返回类型的确定性静态核对。不执行DNS或连接。
- 位置：hostname判断、唯一A lookup和单地址connect在`lualib/silly/net/cluster.lua:179-217`；DNS同时公开A/AAAA及多结果resolve在`lualib/silly/net/dns.lua:574-656`；cluster文档允许hostname endpoint在`docs/src/en/reference/net/cluster.md:249-319`。
- 触发：peer hostname只有AAAA记录，或同时有多个A/AAAA而首个A地址不可达、后续地址健康；IPv6-only集群、双栈迁移和DNS负载均衡均会遇到。
- 影响：AAAA-only名字在A lookup返回nil后被直接报告`dns lookup ... failed`，从不查询AAAA；多A只使用`dns.lookup`返回的第一项，该地址connect失败后整次call失败，不尝试同一DNS答案的其他endpoint。合法可达节点因此不可用，自动重连也会重复同样的单地址选择，故障恢复依赖DNS排序/TTL偶然改变。
- 证据：`connect`对所有`is_host(name)`路径硬编码`dns.lookup(name,dns.A)`，随后只调用一次`join_addr(ip,port)`和一次`tcp_connect`。代码没有`dns.AAAA`、`dns.resolve`、address list、family preference或逐地址剩余deadline循环；直接IPv6 literal虽可绕过DNS，但不能修复hostname语义。
- 根因：endpoint解析被简化为“hostname→一个IPv4字符串”，没有采用family-neutral address set或连接候选状态机。
- 建议解法：DNS/addr层返回有序A+AAAA候选，并在同一absolute deadline下实现RFC 8305风格的受控Happy Eyeballs或至少顺序故障转移；每个失败地址保留诊断，成功地址可按TTL/健康度缓存但不能永久钉死。直接literal继续保持单候选。
- 回归测试：修复阶段覆盖AAAA-only、A-only、双栈首选成功/失败、多A首个拒绝后次个成功、总deadline和全部失败诊断；用静态可控resolver/connector验证候选顺序。当前不运行解析或连接。

### CLUSTER-011 — P1 — 完整帧队列与 handler 并发均无上限，单个读批次可放大成海量 task

- 状态：已确认；socket read batch、C parser queue与Lua dispatcher fork时序的确定性静态核对。本轮不发送frame burst或运行压力测试。
- 位置：TCP read buffer为2MiB在`src/silly_conf.h:50`及`src/socket.c:997-1024`；C queue初始/扩容及整批push在`luaclib-src/lcluster.c:12-15,53-61,149-187,219-300`；Lua先fork下一个process再执行可yield handler在`lualib/silly/net/cluster.lua:64-113`；配置仅有per-frame limits在`:311-329`。
- 触发：一个已连接peer在单个或连续TCP read批次中发送大量最小合法request frame，业务`unmarshal/call`发生异步等待或处理速度低于输入；最小request仅含4-byte length与16-byte request header，甚至无需业务payload。
- 影响：`c.push`在返回Lua前先解析完整2MiB chunk并为每帧分配body、扩张全局ring，可一次积累约十万帧；随后每个`process`在调用可能yield的handler前先`task.fork(process)`，形成近似每个阻塞request一个task，没有per-peer/global admission、read pause或队列byte cap。单个peer可快速耗尽内存/CPU、扩大trace/log/response队列并拖垮同一worker上的所有业务；128MiB hardlimit对此无效，因为它只检查单帧大小。
- 证据：`push`的do/while会消费整块data，`push_complete`在ring满时每次增加2048槽且无max count/bytes；`EVENT.data`只在全部push完成后调用一次`process()`。`process`弹出一帧后立即fork successor，再进入`pcall(call,...)`；若handler yield，successor继续对下一帧重复此过程。cluster没有调用`net.readenable`或任何semaphore/concurrency配置。
- 根因：frame size限制被误当作完整的资源边界，parser、dispatcher和业务执行之间没有带水位的有界队列及所有权反馈；通过fork维持并发却没有配套admission control。
- 建议解法：按connection与global同时限制queued frame count、queued bytes和active handlers；达到高水位立即暂停该fd读取，降到低水位再恢复，超过hard queue cap时以明确错误关闭违规peer。parser应流式交付到有界队列而非先展开整批；dispatcher用固定worker/信号量，保证close/cancel能释放排队项并保持每peer所需顺序/公平性。
- 回归测试：修复阶段用内存中的frame计数/调度器边界覆盖单个2MiB chunk、连续chunks、慢handler、多peer公平性与close时排队回收；断言active/queued/bytes不越配置水位、read pause/resume配对、无task线性爆炸。当前不构造burst或运行压力测试。

### CLUSTER-012 — P1 — 仅收到 4-byte length 即预分配完整 body，无 partial deadline 或 aggregate budget

- 状态：已确认；frame allocation时点、per-fd incomplete ownership与连接生命周期的确定性静态核对。本轮不发送partial frame或建立慢连接。
- 位置：默认hardlimit与incomplete结构在`luaclib-src/lcluster.c:11-14,40-61`；length完成后立即整块分配在`:219-279`；partial只在close/ctx GC释放在`:302-311,508-531`；cluster无读/帧timeout和aggregate配置在`lualib/silly/net/cluster.lua:311-329`。
- 触发：peer只发送一个host-order 4-byte合法length（默认可声明128MiB），不发送body或极慢发送；对多个accepted连接重复。无需先通过业务unmarshal/call，也不要求超过hardlimit。
- 影响：parser在第4个字节到达时立即`malloc(psize+1)`，默认单连接可占约128MiB并无限等待余下body；少量慢连接即可耗尽进程内存或触发allocator abort，且没有global/per-peer partial bytes、连接数联动或progress deadline。softlimit只在完整发送pack时告警，接收预分配路径不提供保护；把hardlimit调大进一步放大风险。
- 证据：`push_once`在`hdr_off==4 && buff==NULL`时验证仅`psize<=hardlimit`，随即分配完整长度，再把已到数据复制进去并把node挂入hash；后续没有timer/timestamp。只有收到socket close走`c.clear`或整个ctx GC才释放，正常保持连接时可永久保留。与`CLUSTER-004`不同，本项无需主动close且关注分配策略/总预算，而非teardown遗漏。
- 根因：length-prefixed parser把对端声明长度当作可信的即时allocation尺寸，并只设置单帧上限；没有增量buffer、资源预留器或slow-frame状态机。
- 建议解法：为partial frames设置严格的per-connection/global reserved-byte预算和absolute progress deadline；采用分段/增量buffer，至少避免在body到达前提交完整物理内存。reservation失败立即关闭该peer并限速日志，connection admission也计入预算；hardlimit保持合理默认且设置不可越过的安全cap。
- 回归测试：修复阶段以parser级可控clock/allocation accounting覆盖header-only、每次少量progress、多连接预算竞争、deadline边界、close/reconfigure释放和合法最大frame；断言reserved/committed bytes有界且超时后归零。当前不发送partial frame或做内存压力。

### CLUSTER-013 — P3 — 随机分片测试的完整性断言没有比较实际值与期望值

- 状态：已确认；Lua `assert` 调用语义与测试辅助函数的确定性静态核对。`master`与远端`cluster`分支均存在；本轮不运行测试。
- 位置：`test/testcluster.lua:59-74`的`randompush`分片与末尾断言；远端`cluster`分支提交`0f2c8773842edb818c1aac74ade3f975d1cbd068`中对应位置为`:59-75`。
- 触发：`randompush`辅助函数未来因边界修改而漏掉、重复或重排某段，但每次`justpush`仍返回成功；现有代码本来想在所有分片送入后验证重新拼接结果。
- 影响：`assert(table.concat(buf), pk)`只检查第一个参数是否truthy，第二个参数只是失败时的错误消息。Lua字符串（包括空字符串）恒为truthy，因此它不会比较拼接数据与原packet；parser的随机分片用例会在辅助函数生成错误输入时继续运行，可能把测试helper错误误认为parser行为，或漏掉预期的分片覆盖。该项不直接改变生产cluster实现，严重度定为P3。
- 证据：正确比较应形成布尔条件，例如`assert(table.concat(buf) == pk)`或使用`testaux.asserteq(table.concat(buf), pk, ...)`；当前表达式没有`==`，且`pk`只作为`assert`的第二实参。该写法在共同祖先`295f30b879e5c29e12ab2ac1325d8b80abe8fb53`、`master`和`cluster`分支中完全相同。
- 根因：把`assert(value, message)`误写成了预期的`assert(actual == expected)`/`asserteq(actual, expected)`；测试没有自证其随机切片辅助函数保持原始字节序列。
- 建议解法：改用`testaux.asserteq(table.concat(buf), pk, "Test X.Y: random fragments reconstruct packet")`，并按`CLAUDE.md`补齐case/assert编号；另外用确定性边界切片覆盖1-byte header/body边界、最后1 byte与多帧粘包，随机分片只作为补充。
- 回归测试：修复阶段先给helper注入一个只在测试内生效的漏字节/重复字节变体，确认新断言必然失败，再恢复helper并运行cluster parser用例；本轮只记录静态缺口，不修改或执行测试。

### CLUSTER-014 — P2 — RPC timeout配置延迟到发包后验证，非法值可造成远端已执行而本地抛错

- 状态：已确认；配置、send与timer创建顺序的确定性静态核对。`master`与远端`cluster`分支均存在；本轮不发送请求或运行边界测试。
- 位置：`master`基线的配置赋值在`lualib/silly/net/cluster.lua:311-329`、request/send/wait顺序在`:261-305`；远端`cluster`分支对应位置为`:207-270`；timer C入口的实际约束在`luaclib-src/ltime.c:14-27`。
- 触发：应用成功执行`cluster.serve{timeout=4294967296,...}`（即`UINT32_MAX+1`），或传入其他不能被`luaL_checkinteger`接受的truthy值，随后发起`cluster.call`。配置函数本身不会验证timeout；负数虽被timer层压成0，也说明公开配置没有一致的范围策略。
- 影响：call先构造frame并调用不yield的`tcp_send`，成功后才进入`waitfor`并以配置值调用`time.after`。超范围/非整数值此时由C层抛Lua异常，caller得不到`nil, err`，pending也尚未登记，但请求已经排入socket并可能在远端产生不可逆副作用。上层若把异常当作未发送而重试，会重复执行非幂等RPC；返回的ACK则成为unknown/late response。branch的nil guard只避免再次异常，不能恢复调用结果。
- 证据：`M.serve`只是`expire = conf.timeout or 5000`；`callx`按`c.request → tcp_send → waitfor`执行，而`waitfor`第一步才是`after(expire,...)`。`ltime.c:lafter`要求Lua integer且拒绝`timeout > UINT32_MAX`。因此验证点严格晚于不可回滚的网络send，且失败路径没有pending/timer可供统一finish。
- 根因：公开配置没有在发布前完成类型/范围验证，response deadline又被惰性创建在有副作用的send之后；模块把timer API的内部前置条件当成了RPC配置验证。
- 建议解法：`serve`先在局部变量中验证timeout为可接受范围内的整数（明确0/负数策略），与新ctx/callback一起事务性提交；`call`入口先计算并成功创建deadline状态，再构造/发送request，任何后续失败都通过单一finish路径取消timer和pending。若send失败，必须清理预注册pending且不遗留timer。
- 回归测试：修复阶段覆盖`nil`默认、0、负数、非整数、`UINT32_MAX`和`UINT32_MAX+1`；断言非法配置在`serve`阶段且零网络副作用地失败，边界合法值不在call阶段抛错。另用mock send计数确认timer/setup失败时没有request写出。本轮不运行这些场景。

### CLUSTER-015 — P1 — 同批次合法帧后的解析错误会把完整frame滞留在全局队列并跨连接累积

- 状态：已确认；C parser提交顺序、Lua错误分支与clear范围的确定性静态核对。`master`与远端`cluster`分支均存在；本轮不构造混合frame批次。
- 位置：完整frame入ring、批量push及错误早退在`luaclib-src/lcluster.c:149-188,219-300`，`c.clear`只清incomplete hash在`:302-311`；Lua data错误路径直接close/return在`lualib/silly/net/cluster.lua:115-175`。远端`cluster`分支为同一状态机（C约`:144-305`，Lua`:98-158`）；单次TCP read buffer上限在`src/silly_conf.h:49-50`。
- 触发：同一个`c.push`输入/TCPDATA批次先包含一个或多个完整合法frame，随后包含非法length或request header。前面的frame已由`push_complete`加入全局ring；解析后续frame返回负错误，使整个`c.push`对Lua报告失败。
- 影响：Lua错误分支调用`close_fd`后直接return，不执行`process()`；`c.clear(ctx,fd)`只摘除该fd的半包节点，不扫描complete ring。因此已经提交的body allocation与queue slot会一直保留到未来任意连接的一次成功data触发全局process，或整个ctx GC。攻击者可反复建连并在单批次尾部追加错误frame，使每个连接遗留合法frame并跨连接累计内存/queue容量；如果滞留的是ACK，它在以后被pop时还会脱离已关闭transport按全局session处理，叠加`CLUSTER-001`造成迟延跨peer完成。
- 证据：`push`逐帧循环且没有transaction/rollback marker；每个成功的`push_once`立即推进`head`并转移`ic->buff`到ring。后续`n < 0`直接return，未返回“已入队数量”。`EVENT.data`只有`ok`分支才调用`process()`；error分支的`clear_incomplete`无法访问`struct packet queue`。ring本身全局属于ctx而非peer，因此后续连接可继续在同一滞留队列后扩容。
- 根因：parser将“一批输入的部分成功”隐藏成单一失败返回值，而调用者把失败理解为该fd所有状态均已清理；complete queue缺少per-fd teardown/rollback能力，解析提交与连接错误处理不具事务性。
- 建议解法：优先让`c.push`返回结构化结果（已完成frame数/错误），Lua无论尾部是否出错都先受控地drain或逐fd丢弃已提交frame，再关闭连接；更稳妥的是为每次push建立临时完成链，整批验证成功后再原子splice到dispatch queue。C层提供幂等`clear_fd`，同时释放该generation的incomplete与尚未dispatch complete项；响应仍必须验证fd generation/session，不能因drain而接受已关闭peer ACK。
- 回归测试：修复阶段在parser级分别输入`valid request + invalid length`、`valid ACK + malformed request`、多valid+invalid与跨多fd交错；断言错误返回后该fd的complete/incomplete bytes和queue count均为0，其他fd帧不丢失，后续data不会执行已关闭peer帧。用小内存计数验证重复错误连接不增长；本轮不创建或运行混合frame。

### ADDR-001 — P2 — IP 分类忽略 embedded NUL 后缀，验证结果与完整地址字符串不一致

- 状态：已确认；Lua string长度与C string调用链的确定性推导。本阶段不新增NUL endpoint连接复现。
- 位置：`iptype`及三个Lua入口在`luaclib-src/laddr.c:64-72,137-168`；DNS fast path在`lualib/silly/net/dns.lua:472-493,524-535`；socket参数最终以C string读取在`luaclib-src/lnet.c:109-142,145-166`。
- 触发：公开addr/DNS/network API接收包含embedded NUL的Lua string，例如`"127.0.0.1\0.attacker"`或`"::1\0suffix"`；Lua层及`luastr`知道完整长度，但IP分类函数只把NUL-terminated pointer交给`inet_pton`。
- 影响：`iptype/isv4/isv6`把带任意后缀的完整值判为合法IP，`ishost`反向判为false。DNS `resolve/lookup`据此跳过name验证与DNS、原样返回带NUL值；后续join/日志/ACL可保留并比较后缀，而socket C API再次按首个NUL截断并实际连接前缀IP，形成校验、审计显示与真实endpoint不一致。依赖这些helper做SSRF/allowlist判断的调用方可能被绕过。
- 证据：`liptype/lisv4/lisv6`均调用`luaL_checkstring`而不取得长度；`inet_pton`没有length参数。`lishost`虽取得`len`，仍把同一pointer传给`iptype`，只用len判断是否空。DNS的IP fast path直接返回原始Lua string；低层connect又用`luaL_checkstring`传给OS resolver。
- 根因：二进制安全Lua string与NUL-terminated OS address API之间没有统一的“不得含NUL”验证，分类与消费分别截断但中间层仍把值当完整字符串。
- 建议解法：所有address入口先用`luaL_checklstring`取得长度并拒绝任何embedded NUL；再复制/确保唯一terminator后调用inet_pton/getaddrinfo。让parse/join/iptype/connect共享同一validated endpoint类型，避免helper与最终consumer规则漂移。
- 回归测试：修复阶段覆盖IPv4/IPv6/hostname/port在每个位置嵌NUL，addr分类、DNS和TCP/UDP/TLS/cluster均返回明确EINVAL且不发起连接；合法普通string行为不变。当前不新增NUL连接复现。

### ADDR-002 — P2 — 无端口 bracket 地址构造越过 one-past-end 的指针

- 状态：已确认；C指针算术规则与公开支持输入的确定性静态推导。现有功能测试通过不代表未定义行为已消除，本轮不运行UBSan。
- 语言约束：对数组只能构造从首元素到one-past-end范围内的指针；在one-past-end基础上再加1本身已越界，随后对该指针做关系比较也不具备已定义语义。
- 位置：bracket地址解析在`luaclib-src/laddr.c:17-57`，关键为`:24-35,49-55`；公开类型和双语契约在`lualib/types/silly/net/addr.lua:7-10`、`docs/src/{en/,}reference/net/addr.md:14-58`；现有明确覆盖在`test/testaddr.lua:36-40,75-84`。
- 触发：调用公开`addr.parse("[::1]")`、`addr.parse("[]")`或任意恰好以`]`结尾且没有`:port`的bracket输入。
- 影响：闭括号`p`位于最后一个字符，`se`是one-past-end；代码无条件执行`ps=p+2`，得到`se+1`，再在`if (ps < se)`中参与关系比较。优化器可基于未定义行为做不可预测转换；当前常见构建通常表现为碰巧返回`port=nil`，但不能保证跨编译器、优化级别或未来改动仍稳定，属于公开正常输入上的潜在错误结果或崩溃点。
- 证据：代码只检查`p+1 < se`时后一字符必须为冒号，却没有在`p+1 == se`时直接表示“无端口”；两条测试和`addr.join`都会生成这种无端口bracket形式，因此不是不可达畸形输入。
- 根因：把“跳过闭括号和冒号”写成统一`p+2`，没有把“闭括号就是末尾”和“闭括号后确有冒号”分成两个控制分支。
- 建议解法：若`p+1 == se`，直接设置`port->str=NULL/len=0`并返回；只有确认`p[1]==':'`后才令`ps=p+2`。最好用剩余长度而不是先构造候选指针来表达边界。
- 回归测试：修复阶段保留现有`[::1]`与`[]`断言，并在ASan/UBSan及高优化构建覆盖最短`[]`、`[a]`、带端口、空端口和尾随非法字符；所有路径不得构造数组范围外指针。当前不重跑既有测试。

### URL-001 — P1 — URL fragment 被保留在 HTTP request target 并发送给服务端

- 状态：已确认；RFC URI/HTTP语义与URL→HTTP/1/HTTP/2调用链推导。本阶段不发送含敏感fragment的请求。
- 规范：RFC 3986 §3.5/§5规定fragment在dereference前从URI其余部分分离；RFC 9110 §7.1明确target URI排除fragment，因为它只供client-side处理。参见 [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986.html) 与 [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html)。
- 位置：URL parse/resolve/build在`lualib/silly/net/http/url.lua:18-137`；HTTP client把`u.path`直接交给stream在`lualib/silly/net/http/client.lua:278-314,329-382`；HTTP/1与HTTP/2 request sender分别在`lualib/silly/net/http/h1.lua`和`h2.lua`的`stream.request`路径。
- 触发：调用HTTP client请求`https://host/path?x=1#secret`，或redirect Location包含/继承`#fragment`；parse pattern把`#`包含在尾部`path`，fragment-only resolve也显式拼回`bpath`。
- 影响：fragment原样进入HTTP/1 request-line或HTTP/2`:path`，被origin、proxy和access log观察。OAuth implicit flow token、reset secret、客户端解密key或页面内定位私有值常依赖“fragment不会上网”的语义，因而可能直接泄露；还会生成不规范request target并改变cache/router匹配。
- 证据：parts注解甚至把`path`描述为`path + query + fragment`；`parsehostport`只处理空path/leading query，不在`#`处分割。`request_url`无转换地调用`stream:request(method,u.path,header)`。`url.resolve`的fragment-only分支返回`base-without-old-fragment .. ref`，之后同样发送。
- 根因：URL model没有独立query/fragment component，把“用于重建显示URL的reference”与“允许上wire的HTTP target”混为一个字段。
- 建议解法：按RFC 3986解析为scheme/authority/path/query/fragment；`build`可按需要包含fragment，但HTTP dereference必须构造只含path+可选query的request target。redirect resolution先完整处理fragment继承/替换，再在发送边界剥离；日志和sensitive-data policy也应避免默认记录fragment。
- 回归测试：修复阶段覆盖absolute、query+fragment、fragment-only、redirect Location相对/绝对及percent-encoded `%23`；wire捕获断言literal fragment永不出现，而合法path中的`%23`保留。当前不发送敏感fragment。

### URL-002 — P2 — 显式 port 绕过 supported-scheme 校验并回落到明文 TCP

- 状态：已确认；URL构造条件与HTTP/WebSocket transport选择推导。本阶段不对非HTTP服务发请求。
- 位置：scheme/default-port校验在`lualib/silly/net/http/url.lua:27-70`；HTTP transport选择在`lualib/silly/net/http/client.lua:230-277`；WebSocket选择在`lualib/silly/net/websocket.lua:290-321`；现有测试只覆盖无port ftp在`test/testhttp.lua:1133-1140,1221-1225`。
- 触发：解析/请求任意未知scheme但显式给port，例如`ftp://host:21/file`或`custom://127.0.0.1:80/`。`makeurl`仅在`port==nil`时查`default_port`并拒绝unsupported scheme，有port则直接成功。
- 影响：URL API声称unsupported scheme会返回错误，但显式port绕过；HTTP client将所有非`https` scheme当普通TCP并发送HTTP framing，WebSocket将所有非`wss` scheme当普通TCP并发送Upgrade。若上层用`url.parse`作scheme allowlist/SSRF边界，攻击者可让进程连接任意port；scheme拼写错误也可能静默选择明文transport而非fail closed。
- 证据：`if not port then ... if not default_port[scheme] then error end end`使校验与port presence错误耦合。`connect`端只有二分`scheme==https`/else，WebSocket只有`scheme==wss`/else，没有第二道精确allowlist。现有ftp测试没有显式port，故未覆盖绕过。
- 根因：scheme合法性检查被实现为default-port lookup的副作用，transport层又以“secure special case，否则plaintext”选择协议。
- 建议解法：parse或各consumer首先对精确scheme集合做allowlist，与port是否显式完全分离；HTTP client只接受http/https，WebSocket只接受ws/wss，其他一律在DNS/connect前报错。transport使用显式switch并让default分支失败，禁止fallback-to-plaintext。
- 回归测试：修复阶段对每个合法scheme覆盖默认/显式/非默认port；对ftp/custom/大小写/近似拼写均覆盖有无port，断言不做DNS或connect。当前不对非HTTP服务发请求。

### URL-003 — P2 — relative-reference resolution 未实现 RFC 3986 path/query 合并与 dot-segment 移除

- 状态：已确认；RFC reference-resolution算法与确定性字符串路径推导。本阶段不新增redirect server复现。
- 规范：RFC 3986 §5.2要求按component继承scheme/authority/path/query，并执行merge paths与remove_dot_segments；空reference继承base path和query。参见 [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986.html)。
- 位置：`lualib/silly/net/http/url.lua:72-126`，尤其query/fragment特殊分支与`:122-125`的path-relative拼接；redirect消费在`lualib/silly/net/http/client.lua:347-382`。
- 触发：HTTP redirect Location为`../x`、`./x`、空字符串或相对path，而base含多级path、query中含`/`或dot segments；例如base`http://h/a/b?next=/q`与ref`../c`。
- 影响：client生成与RFC目标不同的request：query内容可能被当作目录，`../`/`./`原样留在wire，空ref错误退到父目录而非保持当前资源/query。服务器、proxy和签名组件对dot-segment规范化策略不一致时，可请求错误资源、破坏redirect loop detection/cache key，或跨越预期path prefix。
- 证据：实现用`match(bpath,"^(.*/)")`直接在包含query/fragment的整串上贪婪找最后slash，再拼`ref`；注释明确承认不normalize dot segments。它没有RFC component tuple或empty-reference分支。`seen`使用该未规范化build结果，随后同一值直接上wire。
- 根因：redirect helper以少量字符串特例代替URI reference state machine，并让显示/发送/循环比较共用未规范化path字符串。
- 建议解法：实现RFC 3986 §5.2 component级resolver：先分离path/query/fragment，正确处理defined-vs-empty query，merge paths并remove dot segments；redirect loop key使用规范化、无fragment URI，HTTP target仍只发path+query。也可采用经过互操作验证的URI parser而不是继续叠加pattern特例。
- 回归测试：修复阶段采用RFC 3986 §5.4 normal/abnormal examples作为golden vectors，并覆盖base query含slash、empty/`?`/`#`、encoded `%2e`不误归一化、IPv6 authority；redirect wire target与loop detection均核对。当前不新增redirect server复现。

### HTTPC-001 — P1 — convenience client 无响应大小上限且自动 gzip 解压无 output budget

- 状态：已确认；默认header、readall与native inflate路径推导。本阶段不生成gzip bomb或大响应。
- 位置：自动gzip、readall和decompress在`lualib/silly/net/http/client.lua:329-401`；gzip inflate循环在`luaclib-src/lcompress.c:61-109`；HTTP/1、HTTP/2底层buffer/flow paths见既有`HTTP1-007`、`H2-003`与`SOCK-012`。
- 触发：使用`http.get/post`或client同名方法访问远端；server返回任意长close/chunk/content-length body，或返回`Content-Encoding: gzip`及高压缩比payload。客户端默认主动广告gzip，即使调用方没有要求解压。
- 影响：方法总是完整缓存response body才返回，大小不可配置；gzip C函数继续向Lua buffer追加直到结束，也没有max output或ratio，压缩体很小即可消耗大量内存/CPU。redirect的每一跳也先完整读取body，攻击者可在到达最终响应前重复消耗资源，最终进程OOM/不可用。
- 证据：client options只有pool size/idle timeout/ALPN；`do_with_redirects`若无header就设置`accept-encoding=gzip`，随后`stream:readall()`，最后`gzip.decompress(resp_body)`。任何层都没有比较wire bytes、decoded bytes、Content-Length或累计redirect budget。native inflate每轮固定栈buffer并无条件`luaL_addlstring`。
- 根因：高层API被设计成一次性materialize response，却没有把资源预算作为client/request配置；自动content decoding又增加第二个、可放大的内存域。
- 建议解法：client/request提供安全默认的`max_body_bytes`、`max_decoded_bytes`与可选ratio/CPU budget，并在stream读取过程中增量执行，超限立即RST/close且不归还H1连接。gzip使用streaming decoder、总output checked counter及deadline；只有client自动添加Accept-Encoding时才自动解码，并同步移除/更新Content-Encoding与Content-Length。
- 回归测试：修复阶段覆盖固定/分块/close-delimited/H2 DATA超限、gzip高ratio/多member/truncated及redirect累计预算；断言在cap附近准确成功/失败、内存有界、连接不被错误复用。当前不生成大响应。

### HTTPC-002 — P1 — HTTP client 无端到端 request deadline 或 cancellation

- 状态：已确认；公开options与DNS→connect→handshake→response调用链推导。本阶段不运行slow peer。
- 位置：client options在`lualib/silly/net/http/client.lua:67-73,191-226`；connect未传timeout在`:230-277`；request/readall/redirect loop在`:278-401`；HTTP/1 read默认timeout nil，HTTP/2 progress问题另见`H2-025`；TLS client虽支持timeout但此处未传。
- 触发：DNS之后的target或中间redirect endpoint在TCP connect、TLS handshake、response headers、body framing任一阶段停滞，或持续低速发送；调用`get/post/request`没有可传deadline/cancel token。
- 影响：coroutine可无限WAIT并持有连接、pool entry、stream、request body/header及已收响应buffer；多个慢peer可耗尽task/fd/memory。`idle_timeout`不会触及using H1连接，H2 timer还把non-idle channel的`lastfree`持续刷新，因此也不会中止在途stream。
- 证据：opts仅有`max_idle_per_host/idle_timeout/alpnprotos`。`tcp.connect(a)`无timeout，`tls.connect`opts只含hostname/ALPN；`stream:readall()`无timeout参数，redirect每跳重新走同一路径且没有absolute deadline。`M.close(client)`是全client破坏性关闭，不是单request cancellation，也不能由同步阻塞调用自身按deadline触发。
- 根因：pool lifecycle timeout被误当成足够的网络生命周期管理，没有为一次logical request建立跨DNS/connect/TLS/redirect/protocol reads传播的absolute monotonic deadline。
- 建议解法：提供request context/deadline并从入口计算一次absolute deadline，向DNS、TCP、TLS、H1/H2每次等待传播remaining time；redirect共享原deadline与预算。到期时H1关闭连接、H2发送RST_STREAM(CANCEL)并清pending，所有timer/stream恰好释放一次；另提供显式cancel handle且与timeout/response竞态安全。
- 回归测试：修复阶段在DNS、connect、ClientHello、header、chunk、H2 frame/body和redirect各阶段停滞，断言同一absolute deadline内返回、资源清零且其他H2 streams不受影响。当前不运行slow peer。

### HTTPC-003 — P2 — connection lookup 为每个失败 origin 永久创建两张空 pool entry

- 状态：已确认；pool metatable、lookup失败与cleanup timer启动条件的确定性静态核对。本轮不发起高基数URL请求。
- 位置：自动创建entry的pool metatable在`lualib/silly/net/http/client.lua:75-85`；每次lookup读取H2/H1 key在`:183-204`；DNS/connect失败直接返回在`:228-254`；timer只在成功release/channel创建后启动在`:154-180,262-280`，cleanup在`:87-152`。
- 触发：复用一个长寿命client请求大量不同`scheme/host/port`组合，尤其每个host都DNS失败、connect失败或在生成可池化connection前失败；URL可来自crawler、proxy、webhook等外部输入。
- 影响：每个新origin仅执行一次查找就分别在`h2pool`和`h1pool`留下空Lua table，失败路径不删除，且没有alive entry时cleanup timer根本不运行。唯一host数量可无界增长，持续占用key字符串、hash slot和两个table，最终增加GC/CPU与内存直到client显式close或进程退出；请求本身失败也不会回收。
- 证据：`pool_mt.__index`无条件创建、写回并返回`entries={}`；`find_conn`依次索引两个pool。后续`dns.lookup/tcp.connect/tls.connect/h2.newchannel`任一步失败都直接return，没有按key清除空entry。`ensure_timer`只在H1 release成功入池或H2 channel成功创建时调用，所以全失败工作负载没有扫描机会。
- 根因：read lookup被赋予隐式mutation，用“访问即创建”简化成功路径，却没有给失败transaction配套rollback或全局key cardinality策略。
- 建议解法：查找使用`rawget`/nil不创建；只有确实要插入可复用entry时才显式创建数组。cleanup仍应删除空key，并对origin cache/key cardinality设置合理预算；所有连接建立失败路径保持pool不变。不要依赖timer弥补lookup side effect。
- 回归测试：修复阶段以注入式resolver/connector让成千唯一origin在DNS、TCP、TLS、H2初始化各阶段失败，断言两pool key count保持0/有界；成功入池/取出/淘汰行为不变。当前不发起请求或故障注入。

### HTTPC-004 — P2 — hostname 固定单次 A lookup，缺少 IPv6 与多地址连接回退

- 状态：已确认；HTTP connect调用链与DNS返回集合的确定性静态核对。本轮不连接外部或合成endpoint。
- 位置：`lualib/silly/net/http/client.lua:228-277`，其中`:238`固定调用`dns.lookup(u.host,dns.A)`并只连接一个返回值；DNS的`lookup`只取`resolve`结果首项在`lualib/silly/net/dns.lua:641-654`，而`resolve`本身可返回多条A/AAAA在`:588-640`。
- 触发：URL hostname仅有AAAA记录，或同时有多个A/AAAA而首个IPv4地址不可达、后续地址可达；显式IP literal不需要触发DNS，因此不受同一路径影响。
- 影响：IPv6-only origin必然在A查询阶段失败；多地址origin不会在首地址connect/TLS失败后尝试其他候选，造成单点地址故障放大、双栈互操作失败和明显高于常规HTTP client的连接失败率。redirect到此类origin同样失败。
- 证据：connect在pool miss后只保存一个`ip`，构造一次`join_addr`，随后只调用一次`tcp.connect`或`tls.connect`；失败立即return。代码没有AAAA查询、A/AAAA候选合并、逐地址attempt或Happy Eyeballs调度。DNS模块已有AAAA常量与多结果`resolve`，但HTTP client没有使用。
- 根因：HTTP transport把“解析hostname”建模成返回单个IPv4字符串，而非带共同deadline的地址候选连接过程。
- 建议解法：解析A与AAAA候选并在同一absolute deadline/取消上下文内执行RFC 8305风格的地址排序与错峰连接，首个成功者胜出并关闭其余attempt；至少也应顺序尝试全部解析结果。TLS SNI/证书hostname始终保留原host，错误结果聚合而不是只暴露首地址错误，并与`HTTPC-002`的总deadline一起设计。
- 回归测试：修复阶段用注入式resolver/connector覆盖AAAA-only、A-only、双栈首地址失败后成功、全部失败、慢首地址/快次地址、literal IPv4/IPv6及redirect；断言地址尝试共享一个deadline、输家资源释放且SNI仍为hostname。当前不执行DNS或连接。

### HTTPC-005 — P1 — `close()` 可与在途建连交错，并在返回后复活 orphan pool/请求

- 状态：已确认；HTTP client入口、DNS/TCP/TLS让出点、pool发布与close清理的静态时序。本轮不运行并发barrier或建立连接。
- 位置：request的唯一closed检查在`lualib/silly/net/http/client.lua:287-317`；建连及H1/H2发布在`:211-280`；H1 release重新归池在`:160-181`；close清理在`:417-443`。
- 触发时序：task A通过`request_url`的closed检查后阻塞于DNS、TCP connect、TLS handshake或H2初始化；task B调用`client:close()`，标closed、清空当时pool/using并返回；A随后成功继续。
- 影响：H2路径把迟到channel重新加入`client.h2pool`并返回可发送stream；H1路径把conn加入全局`h1using`并同样继续request。请求因此可在close返回后访问网络。H1 stream稍后正常release时还会向closed client新建idle pool entry，H2则已经直接复活pool；`ensure_timer`因closed拒绝清理timer，而第二次close立即return，这些连接/channel及pool引用可永久残留直到GC/进程退出。
- 证据：入口只在connect前检查`client.closed`，`connect()`每个yield后及发布前均不复查。H2无条件`client.h2pool[key][#...+1]=entry`，H1无条件写`h1using[conn]`；`releaseh1`也不检查entry.client.closed。close只遍历调用瞬间已有结构，然后设置的closed使后续close和timer都跳过，没有generation、in-flight registry或late-result rollback。
- 根因：client生命周期只保护调用入口和已有pool，没有把“正在建立但尚未发布”的transport纳入ownership；连接创建/发布不是受closed generation约束的事务。
- 建议解法：为client建立lifecycle generation和in-flight connect registry；每个让出点后、创建channel后及返回stream前复查generation/closed，失效时关闭局部conn/channel并返回closed。close先禁止admission，再取消/关闭在途attempt并等待其收尾，最后清pool；releaseh1遇closed只能close，绝不重新归池。与HTTPC-002统一为可取消absolute request context。
- 回归测试：修复阶段分别把DNS、TCP、TLS、H2 init停在close两侧，覆盖H1/H2和release晚到；断言close返回后无request发送、pool/h1using/in-flight均为空，所有transport关闭且重复close幂等。当前仅记录静态时序。

### HTTPC-006 — P2 — redirect 过度改写 method 且残留 entity headers，跨跳请求语义错误

- 状态：已确认；301/302/303/307/308 method/body/header转换与RFC 9110 redirect语义静态核对。本轮不建立redirect endpoint。
- 规范：RFC 9110 §15.4.2/15.4.3只允许历史兼容下把`POST`随301/302改为`GET`；其他方法应保留。§15.4.4的303后续是GET或HEAD，原方法为HEAD时仍应HEAD。参见[RFC 9110 3xx定义](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.4)。
- 位置：status分类在`lualib/silly/net/http/client.lua:19-33`，redirect循环与转换在`:329-399`，H1 Expect/body许可消费在`lualib/silly/net/http/h1.lua:556-601`，H2使用同一高层method/header输入。
- 触发：高层redirect helper以PUT/PATCH/DELETE/HEAD等方法收到301/302/303；也可让POST redirect前header包含`Expect`、`Transfer-Encoding`、`Trailer`、`Content-Encoding`等body元数据。
- 影响：301/302把PUT/PATCH/DELETE静默改成GET，redirect目标不再执行调用者要求的写操作；303把HEAD改成GET，可能下载本应省略的representation。转换时仅删除Content-Length/Content-Type，残留Expect、TE及其他entity headers会描述一个已被删除的body；H1上的`Expect: 100-continue`还能让新GET在发送结束前等待100/final，与不预期该组合的server永久互等，H2则收到语义不一致字段。行为在H1/H2间还可能因各自body许可不同而分叉。
- 证据：`method_change_redirect`对301/302/303一律为true，分支无条件`cur_method="GET"; send_body=nil`，完全不检查原method/status组合。清理清单只有`content-length`和`content-type`两项；header table在所有跳之间复用，其余representation/framing/expect字段原样传给下一stream。
- 根因：redirect policy被简化为status布尔值，没有把原method、status、body replayability与header transformation建模为一次受约束转换。
- 建议解法：按(status,method)矩阵处理：301/302仅在明确兼容策略下POST→GET，303为HEAD→HEAD、其他→GET，307/308严格保留method/body；提供禁用自动改写/redirect hook。丢弃body时统一移除全部body-specific/framing/Expect/trailer字段并重新生成，保留body时确认可重放且每跳错误/预算受总deadline约束。
- 回归测试：修复阶段覆盖五种status×GET/HEAD/POST/PUT/PATCH/DELETE、自定义method，以及有无body和Expect/TE/content-* headers；捕获每跳method/header/body，断言语义矩阵、不可重放body策略及H1/H2一致。当前只保存静态证据。

### HTTPC-007 — P2 — 重复 Location/Content-Encoding 把远端响应升级为未捕获 Lua 类型异常

- 状态：已确认；H1/H2重复字段表示、redirect resolver与自动解压分支静态核对。本轮不发送重复响应字段。
- 位置：H1重复字段提升为array在`lualib/silly/net/http/h1.lua:129-169`；H2同样映射在`lualib/silly/net/http/h2.lua:367-387`；高层消费在`lualib/silly/net/http/client.lua:357-397`，URL resolver字符串操作在`lualib/silly/net/http/url.lua:78-127`。
- 触发：redirect response携带两个`Location`字段，或最终response携带两个`Content-Encoding`字段（后者可以是协议上可合并的field list）；H1和H2 parser都把对应map value变为Lua array。
- 影响：redirect路径把array直接传入`url.resolve`，其首个`string.match`对table抛类型错误；解压路径把array直接传给`string.lower`也会抛错。异常从`get/post`逃逸，而非按公开契约返回`nil,error`；调用方若只处理返回值，业务task会被终止。`<close>`通常能收尾当前stream，但错误分类、redirect响应及可诊断信息全部丢失，同一合法多行Content-Encoding也无法按列表语义处理。
- 证据：两个parser明确使用`string|string[]`联合表示所有重复字段；高层没有type check、列表合并或protected conversion。`if stream.header["location"]`对非空table为true，随后resolver的`match(ref,...)`要求string；`encoding and lower(encoding)`走同一确定性类型错误路径。现有测试只覆盖普通自定义重复字段，没有覆盖被高层解释的字段。
- 根因：通用header map把重复值的动态union暴露给上层，但各语义消费者仍假定singleton string；没有集中执行field-specific combine/singleton validation与结构化协议错误转换。
- 建议解法：在解析完成、进入业务逻辑前按field schema规范化：Location若非单一合法值则结束该redirect并返回明确响应错误；Content-Encoding按HTTP list语法合并、顺序解析coding链，只自动解码库实际支持且协商过的组合，其他作为普通响应或typed error处理。所有remote-input解析错误经统一边界返回`nil,error`，不得泄露Lua类型异常；H1/H2共用同一规范化层。
- 回归测试：修复阶段在H1/H2分别覆盖零/一/重复Location、重复及逗号列表Content-Encoding、未知coding、空值和大小写；断言API从不抛异常、redirect选择规则明确、coding按正确逆序解码或完整保留响应，并验证stream/connection收尾。当前只保存静态证据。

### HTTPC-008 — P2 — H2 pool 没有记录真实 idle 起点，新连接会提前淘汰

- 状态：已确认；pool entry初始化、timer扫描、stream close与时间源静态推导。本轮不建立H2连接或等待idle timer。
- 契约：`idle_timeout`公开含义是连接保持空闲后再淘汰的毫秒数；计时必须从active→idle转换开始，不能从零值、请求开始或上一次扫描估算。duration还应使用monotonic clock，避免wall-clock校时改变资源生命周期。
- 位置：client默认值和pool timer在`lualib/silly/net/http/client.lua:57-158`；H1准确release时间对照在`:160-181`；H2 entry创建在`:245-271`；H2 stream close只更新channel count在`lualib/silly/net/http/h2.lua:1041-1080`。双语公开配置见`docs/src/{en/,}reference/net/http.md:254-270,383-404`。
- 触发：在进程启动任意时刻新建H2 channel，完成其第一个request并在首次pool scan前使channel idle；默认timer在创建约15秒后运行。长请求在两次timer tick之间结束、或系统wall clock向前/后调整，也会触发不同程度的提前/延后。
- 影响：新entry的`lastfree=0`，首次扫描使用Unix毫秒`time.now()`，因此条件`0+idle_timeout>=now`恒false；刚空闲的新H2连接在默认配置下最多约15秒就被关，而不是承诺的30秒。连接复用率下降、TLS/H2握手和DNS负载上升，突发流量更易形成连接风暴；长请求的idle起点只能近似为最近timer tick，系统时间跳变还可让H1/H2池立即清空或超期保留。
- 证据：H1在stream release时执行`entry.lastfree=time.now()`，但H2 entry固定以0发布，`S.close`没有pool callback或时间字段。timer仅在channel non-idle时把lastfree刷新为扫描时的now；若首个request已完成，它从未走该分支，直接进入expired分支。后续复用只在acquire时更新时间，也不是请求结束/真正idle的时刻。`silly.time`另有`monotonic()`，当前pool却使用wall-clock `now()`。
- 根因：H1有明确的connection release事件，H2却把多stream channel简化为周期性`isidle()`采样，没有保存前一active状态或最后一个stream释放事件；初始化哨兵又与绝对wall-clock直接比较。
- 建议解法：让H2 channel在`streamcount`从1降到0时通知所属pool并记录`time.monotonic()`；创建entry时若channel已active只标active，不伪造idle timestamp。timer同样使用monotonic duration，并基于精确idle_since淘汰；acquire不应重置仍active channel的idle计时。统一验证idle_timeout为正且处理client close/generation。
- 回归测试：修复阶段用可控monotonic clock覆盖新channel首请求立即完成、跨多个tick的长请求、多个并发stream最后一个关闭、复用后再次idle、wall-clock前后跳及边界`timeout-1/timeout/timeout+1`；断言只按真实idle duration关闭且H1/H2一致。当前只保存静态证据。

### HTTPC-009 — P2 — 奇数/非正 idle timeout 在资源发布后触发 timer 异常或即时循环

- 状态：已确认；公开option、Lua数值除法、timer native参数验证及H1/H2入池顺序静态推导。本轮不创建pool timer。
- 契约：`idle_timeout`声明为任意整数毫秒；构造器应在网络资源创建前验证其支持范围，并把内部扫描周期转换成明确整数。无效配置必须同步返回/抛参数错误，不能等到连接发布后失败；0/负数若不支持也应拒绝，不能隐式变成零延时循环。
- 位置：option/default和timer计算在`lualib/silly/net/http/client.lua:57-79,87-158,160-181,245-280`；`time.after`转发在`lualib/silly/time.lua:23-33`；native只接Lua integer并把负数钳为0在`luaclib-src/ltime.c:10-25`；双语配置见`docs/src/{en/,}reference/net/http.md:254-270,383-404`。
- 触发：构造`http.newclient{idle_timeout=30001}`并让首个H2连接发布，或让首个H1 response完整归池；任意奇数值相同。配置0/负数并保留至少一个pool entry时，会不断安排立即到期的下一轮扫描；极大值的除半结果还可能超过timer的UINT32上限。
- 影响：Lua `/`总产生float，奇数除2得到`.5`；`luaL_checkinteger`拒绝它，异常发生在H2 entry已append或H1 conn已release进pool之后。公开request/get/post因此不是返回`nil,error`而是抛异常，且`client.timer`仍为nil，已发布连接以后不会自动淘汰。非正值被native变成0，alive pool每轮又安排0ms callback，可持续占用scheduler/CPU；错误配置的失败位置和资源状态依赖实际协商H1还是H2。
- 证据：`ensure_timer`与续约都执行`time.after(c.idle_timeout / 2,...)`，没有floor、最小值或构造期检查。H2路径先写`entries[#entries+1]=entry`再调用ensure；H1同样先append后ensure。timer C入口用`luaL_checkinteger`要求exact integer，随后只拒绝大于UINT32_MAX，负数则静默改0。文档只写`integer`和默认值，没有偶数/范围限制，因此奇数是合法公开输入。
- 根因：动态option没有集中schema validation，周期派生使用Lua浮点除法并把timer API的整数/范围前置条件留到资源所有权已经转移之后才检查。
- 建议解法：client构造时要求`idle_timeout`位于文档化正整数范围，以整数除法计算`max(1,idle_timeout//2)`并保证不超过timer上限；`max_idle_per_host`同样校验非负范围。先完成所有option normalization再允许DNS/socket/pool创建；timer安排若仍可能失败，必须rollback entry并关闭transport。续约使用已规范化scan_interval。
- 回归测试：修复阶段覆盖1/2/3、默认值、0、负数、UINT32边界及超界，H1 release与H2 create两条路径都断言合法奇数不抛、无效值在建连前失败；检查timer session唯一、无0ms自旋、失败后pool/fd为空。当前只保存静态证据。

### HTTP1-008 — P1 — server 不要求唯一合法 Host，也不处理 absolute-form authority

- 状态：已确认；RFC 9112 mandatory routing规则与server parser调用链推导。本阶段不新增Host ambiguity报文。
- 规范：RFC 9112 §3.2要求HTTP/1.1请求缺Host、包含多条Host或Host值非法时server必须返回400；§3.2.2要求接受absolute-form，并在origin server以request-target authority替代收到的Host。参见 [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html)。
- 位置：通用header reader在`lualib/silly/net/http/h1.lua:94-140`；request-line/handler dispatch在`:818-889`；target helper在`lualib/silly/net/http/helper.lua:27-43`。
- 触发：发送HTTP/1.1请求缺失Host、带两条Host、非法/空Host，或absolute-form target与Host指向不同authority；请求语法其他部分可正常。
- 影响：所有这些请求都进入业务handler。多租户virtual host、cache、反向代理或鉴权若从不同位置/合并表读取authority，可能路由到默认/错误tenant，产生Host-header poisoning、cache key混淆、reset-link/absolute URL污染或访问控制绕过；absolute-form整串还被当普通path，authority语义完全丢失。
- 证据：duplicate fields被`read_header`变为Lua array，但httpd从不读取或验证`header["host"]`。request target仅交给`parsetarget`按第一个`?`分path/query，它不识别absolute-form/authority-form/asterisk-form；handler stream也没有规范化effective authority字段。只有WebSocket审计曾将缺Host作为其握手子问题，普通HTTP路径尚未拦截。
- 根因：HTTP/1 parser只完成framing，没有建立request-target form与effective request URI/authority模型；Host被视为普通业务header而非HTTP/1.1路由控制字段。
- 建议解法：解析四种request-target form；HTTP/1.1 origin-form/asterisk-form要求恰好一个语法合法Host，absolute-form解析URI authority并按规范忽略/替代Host用于effective target，同时检查安全策略，CONNECT要求合法authority-form。任何缺失/重复/非法组合在handler前400并关闭，stream暴露单一validated authority。
- 回归测试：修复阶段覆盖missing/empty/duplicate/comma-list/whitespace/invalid port/IPv6 Host，absolute-form Host一致/冲突、CONNECT authority与OPTIONS `*`；断言违规请求不进handler且连接关闭。当前不新增Host ambiguity报文。

### HTTP1-009 — P1 — field name/value 无 octet 校验，sender 可直接生成 CRLF injection

- 状态：已确认；RFC field grammar与收发共同helper调用链推导。本阶段不构造header injection报文。
- 规范：RFC 9110 §5.1/§5.5要求field name为token，field value不得含CR、LF、NUL；RFC 9112要求含非法field-name或value的消息作为malformed处理，sender不得生成这类消息。不同recipient对非法whitespace/line的容忍会形成request smuggling/response splitting风险。
- 位置：receiver `read_header`在`lualib/silly/net/http/h1.lua:94-140`；sender `compose_header/flush_header/close_write`在`:79-93,347-467`；client/server公开header入口在`:557-600,761-798`及`lualib/silly/net/http/client.lua:278-345`。
- 触发：远端发送包含非token字符、额外colon或NUL/控制字节的field name/value；或本地应用把包含`\r\n`的untrusted key/value传给request/respond/trailer header table。
- 影响：receiver把其他实现会拒绝/不同解释的字段交给handler，并可能让控制字段识别与中间层分叉。sender逐片拼接后，value中的CRLF可结束当前字段并注入Host、Content-Length、Transfer-Encoding、Connection等额外字段甚至空行/body，造成HTTP request smuggling、response splitting、cache poisoning或header-based安全策略绕过。
- 证据：receiver pattern只有`^(%S+):%s*(.-)%s*$`，`%S`不是RFC token allowlist，也没有逐octet value检查。`compose_header`对除client内建Host外的key/value直接追加`k,": ",v,"\r\n"`；table多值同样无验证，trailer复用该helper。高层client只lowercase key，不能消除非法字符。
- 根因：Lua table到wire和wire到Lua之间没有统一field validator，代码依赖调用方与peer永远给规范文本；控制字段语义校验也在已经宽松解析之后。
- 建议解法：共享严格HTTP/1 field validator：name逐octet符合`tchar`且非空，value拒绝CR/LF/NUL及不允许的CTL并按规范处理OWS；receiver任一非法字段400/关闭，sender在写任何字节前返回错误。不同context另加Host/TE/CL/trailer/hop-by-hop规则，禁止用字符串替换“清洗”危险值。
- 回归测试：修复阶段枚举全部0..255 octet用于name/value，覆盖colon、space、tab、NUL、CRLF、obs-fold及table multi-value；sender必须零字节输出后失败，receiver不得进handler且关闭。当前不构造injection报文。

### HTTP1-010 — P2 — request/status-line grammar 宽松且方法白名单破坏 HTTP 可扩展性

- 状态：已确认；RFC grammar与双向parser静态推导。本阶段不构造畸形start-line。
- 规范：RFC 9112 §3规定request-line为`method SP request-target SP HTTP-version CRLF`，HTTP-version只允许`HTTP-name "/" DIGIT "." DIGIT`；§4要求status-line的status-code恰为3位数字。RFC 9110 §9.1说明method token可扩展；501表示服务器不认识/未实现方法，405只适用于已知但目标资源不允许的方法。
- 位置：server request-line解析与版本判断在`lualib/silly/net/http/h1.lua:811-866`；client status-line解析在`:512-553`；固定`valid_methods`表在`:54-63`。
- 触发：请求行带leading junk、TAB/多空白、空target、`HTTP/1|1`或合法扩展method；或响应行带leading junk、非规范version以及1/2/4位status code。
- 影响：Silly与严格proxy/upstream可能对同一字节流形成不同的message boundary/语义，放大为request smuggling或策略绕过；`HTTP/1|1`使`tonumber(ver)`返回nil，随后`nil > 1.1`抛异常并静默断开。合法扩展方法被错误拒绝为405，畸形/未知方法也无法得到正确400/501；client可接受规范上无效的响应并据伪status决定body framing。
- 证据：两处pattern均未以`^...$`锚定；`[%d|.]`显式包含literal `|`，separator使用`%s+`而非SP，client status使用`%d+`。server在确认`target/ver`和转换version之前先执行`valid_methods[method]`，仅允许八个内建方法。
- 根因：以宽松substring regex同时承担词法、语法、版本和能力判断，且把method语法合法性与应用method policy混在transport parser中。
- 建议解法：对完整行做长度受限、逐字段且全字符串匹配的parser；只接受精确HTTP-version grammar与三位status，request separator要求SP并拒绝额外octet。先区分malformed(400)、valid but unsupported(501)，再让router决定known method对resource的405；client遇非法status-line必须标记连接broken。
- 回归测试：修复阶段覆盖leading/trailing junk、HTAB/多SP、empty target、`HTTP/1|1`、多位version/status及合法extension method；验证400/501/route policy分类和client不复用broken连接。当前不新增畸形网络输入。

### HTTP1-011 — P1 — outbound method/request-target 未校验，literal CRLF 可注入额外请求字节

- 状态：已确认；URL→client→HTTP/1 request-line的确定性字符串拼接静态核对。本轮不发送注入请求。
- 规范：RFC 9112 §3要求sender生成严格的`method SP request-target SP HTTP-version CRLF`，method必须为token且各组件不能含whitespace/CTL；RFC 9110 §7.1要求HTTP target URI排除fragment并形成相应request-target。sender不得把调用方字符串当作已验证wire语法。
- 位置：request-line模板与无校验格式化在`lualib/silly/net/http/h1.lua:66,556-601`；URL parser原样保留path octet在`lualib/silly/net/http/url.lua:60-80`；高层client直传method/path在`lualib/silly/net/http/client.lua:282-317`。
- 触发：调用`client:request`或底层stream request时，method/path含SP、HTAB、CR、LF、NUL或其他CTL；例如不可信URL的path含literal CRLF。URL parser只按scheme/authority分段，不拒绝这些octet。
- 影响：HTTP/1 sender会把CRLF直接写进request-line，使攻击者提前结束target并注入Host、Content-Length、Transfer-Encoding等字段、空行/body，甚至在持久连接中追加第二条request。经proxy/pool发送时可形成request smuggling、cache poisoning、credential错配或对同origin下一请求的响应队列污染；非法method/target也会让不同recipient产生分歧。HTTP/2为二进制header问题且已有`H2-018`，不能缓解协商到H1的路径。
- 证据：`format(request_line,method,path)`是request的第一段输出，前后没有任何validator；`request_url`仅检查stream创建成功便调用`stream:request(method,u.path,header)`。现有`HTTP1-009`只检查field name/value，`HTTP1-010`只覆盖接收start-line，均不阻止本地出站组件注入。
- 根因：API把语义字符串直接当作协议语法片段，收发校验未共享；URL模型也没有“合法URI reference”与“已验证HTTP request-target”之间的类型边界。
- 建议解法：写入sendbuf前原子验证全部组件：method逐octet符合`tchar`且非空；request-target拒绝SP/HTAB/CR/LF/NUL/CTL并按method/context验证origin/absolute/authority/asterisk form；URL入口同时拒绝URI不允许的原始控制字符。验证失败必须保证零字节写入、stream不可复用状态明确；不要用percent-encode CRLF来掩盖已非法输入。
- 回归测试：修复阶段枚举method/target的0..31与127 octet、SP/HTAB、CRLF组合、合法扩展method、CONNECT authority和OPTIONS `*`；断言非法输入在任何flush前失败且peer收不到字节，合法目标wire保持精确。当前不发送注入内容。

### HTTP1-012 — P2 — `101 Switching Protocols` 后连接仍进入 HTTP keepalive/reuse 路径

- 状态：已确认；101终态、client pool release与server loop的确定性静态核对。本轮不执行Upgrade握手。
- 规范：RFC 9110 §7.8规定101表示连接已经切换到响应Upgrade字段指定的协议，server发送101后即继续使用新协议；HTTP client也必须按新协议处理，不能再把该连接当普通HTTP/1持久连接复用。
- 位置：client把101视为final在`lualib/silly/net/http/h1.lua:604-627`；bodyless framing在`:94-100,512-553`；pool release条件在`:710-729`；server响应后继续HTTP循环在`:758-798,818-890`。
- 触发：合法Upgrade请求获得101，或peer对普通请求发送未验证的101；response没有`Connection: close`，request也保持默认keepalive。新协议字节可在101后立即到达。
- 影响：client将101设为无body/eof，stream close时既不是CONNECT、eof-delimited也没有close token，因而把已切换协议的socket放回H1 pool；下一HTTP请求会写入新协议连接，并把对端的新协议数据误作status-line/header。server侧`respond(101)`后同样回到`conn:read("\n")`解析HTTP。结果是协议状态混淆、请求失败、残留字节污染后续response边界及连接资源泄漏。
- 证据：`client_waitresponse`的终止条件显式为`status>=200 or status==101`；`bodyless_response`把所有1xx设为无body。`h1c.close`的broken表达式没有`status==101`或upgrade状态；`httpd`结束handler后只看stream completeness和request `Connection: close`，没有101分支或hijack ownership transfer。
- 根因：实现只把101当作特殊的“最终无body status”，没有把它建模为transport ownership/协议状态转换。
- 建议解法：先严格验证request/response的Connection/Upgrade token匹配；101成功时从HTTP parser/pool永久摘除socket，并通过显式`hijack/upgrade` API把连接所有权恰好一次交给新协议handler。若调用方不接管则立即关闭；收到非请求升级对应的101应标记broken并失败。server发送101后必须退出HTTP loop。
- 回归测试：修复阶段覆盖合法upgrade接管、未请求101、缺失/不匹配Upgrade、101后立即新协议字节及stream GC；断言连接从不回H1 pool、server不再读HTTP、所有权只交接一次。当前不运行Upgrade互操作。

### HTTP1-013 — P2 — Connection 未按 token list/版本解析，close 要求与 HTTP/1.0 默认关闭均可失效

- 状态：已确认；RFC persistence规则与client/server复用条件的确定性静态核对。本轮不建立持久连接。
- 规范：RFC 9110 §7.6.1将Connection定义为不区分大小写的逗号分隔connection-option列表；出现`close`表示sender将在响应后关闭。RFC 9112 §9.3规定HTTP/1.1默认持久，而HTTP/1.0只有显式`keep-alive` option时才持久。
- 位置：request侧keepalive只做精确字符串比较在`lualib/silly/net/http/h1.lua:556-572`；client pool release再精确检查response在`:710-729`；server loop只精确检查request在`:818-890`；header重复值会成为table在`:129-149`。
- 触发：Connection值使用合法大小写/OWS/token list，例如`keep-alive, Close`或`CLOSE`，字段重复出现，或HTTP/1.0消息没有显式`Connection: keep-alive`；client接收HTTP/1.0 fixed-length response也相同。
- 影响：server在peer明确要求close后仍读取下一request，并对HTTP/1.0默认保持连接；client可把应关闭的socket归还pool并发送下一request。若对端已关闭会产生竞态失败；若中间层/旧server停止HTTP解析但尚未close，则请求挂起或字节落入错误协议状态。重复/列表形式还会使hop-by-hop字段处理与其他代理分叉，破坏连接边界可靠性。
- 证据：三处逻辑都使用`header["connection"] ==/~= "close"`，不lower value、不按逗号拆token，也不支持string[]。`s.version`虽然保存response版本，pool判断从不读取它；server解析出的`ver`同样不参与持久性决策，因此1.0沿用1.1默认。
- 根因：把语法为列表且依赖HTTP版本的连接状态压缩成单一字符串相等判断，没有共享的connection-option parser或persistence state。
- 建议解法：合并重复字段、按逗号/OWS解析并ASCII case-fold每个合法token；presence of close始终优先。HTTP/1.1无close才可持久，HTTP/1.0必须显式keep-alive且完整framing/双方允许；非法option语法使消息失败/连接不可复用。将决定保存为stream的validated persistence状态供所有close路径共用。
- 回归测试：修复阶段覆盖大小写、OWS、多token、重复字段、同时close+keep-alive，以及HTTP/1.0/1.1×有无CL/TE；断言server循环次数与client pool状态符合规范。当前不运行连接复用测试。

### HTTP1-014 — P2 — `closewrite(data)` 吞掉 write/Content-Length 错误，可发送永久不完整的 message

- 状态：已确认；write/flush/closewrite返回值与client/server完成检查的确定性静态核对。本轮不发送长度不一致消息。
- 位置：`write`的长度校验及flush在`lualib/silly/net/http/h1.lua:367-419`；`close_write`忽略返回值在`:421-438`；client wrapper无返回且直接标closed在`:684-703`；server只在handler结束后检查在`:790-798,872-890`；高层client忽略closewrite结果在`lualib/silly/net/http/client.lua:351-360`。
- 触发：显式Content-Length小于/大于`closewrite(data)`累计body，bodyless状态仍传data，或flush时socket write失败。直接stream API允许调用方自设header；高层未来任何header/body归一化遗漏也会进入同一路径。
- 影响：超长/不允许的data使`write`返回false但`close_write`仍flush header并把stream标成writeclosed；不足长度则直接发送partial body而没有终止chunk/连接。client随后等待response，server依据Content-Length等待永远不会到达的剩余字节，双方在无总deadline时可永久挂起。socket发送失败也只能稍后从`s.err`间接发现，调用`closewrite`本身始终看似成功；server侧会事后断连接但无法让handler知道response被截断。
- 证据：`:425-427`裸调用`write(s,data)`不接收`ok,err`；`:428-437`无条件flush。`h1c.closewrite`没有return语句并无条件`s.writeclosed=true`。完整性检查`check_close_error`只在stream close/server handler返回后执行，client在`:635-681`等待response前不调用它，无法阻止已知不完整request。
- 根因：closewrite被当作best-effort finalizer而非可失败的状态转换，发送错误、framing invariant和资源终止没有统一的原子finish函数。
- 建议解法：`closewrite`返回`boolean,error`并传播`write/flush`失败；在写任何final bytes和进入response wait前验证fixed-length累计值恰好相等。失败时将stream标broken、关闭H1连接且禁止归池，不能发送一个已知不完整message；server handler也必须收到失败。高层client必须检查结果并立即返回。
- 回归测试：修复阶段覆盖CL精确/少1/多1、分多次write后close、bodyless data、chunked final write以及socket write失败；断言错误同步返回、对端不会无限等、连接不复用且错误只完成一次。当前不发送长度不一致消息。

### HTTP1-015 — P2 — Expect/1xx 状态机不能发送 interim response，且 client 把 102/103 误作 final

- 状态：已确认；Expect request路径、informational response循环与server单response状态的确定性静态核对。本轮不执行100-continue交互。
- 规范：RFC 9110 §10.1.1允许server在检查headers后发送100 Continue，再读取content并发送最终响应；client在收到100前不得发送等待中的content，但收到其他informational response（如103）也不能把它当final，必须继续等待100或最终status。最终响应可代替100并终止上传。
- 位置：client Expect分支只读取一次response在`lualib/silly/net/http/h1.lua:556-601`；普通client loop才会跳过1xx在`:604-627`；server handler只有单一`respond/closewrite`状态在`:758-798,818-890`；高层request不传Expect wait timeout在`lualib/silly/net/http/client.lua:282-301`。
- 触发：Silly client向Silly server发送`Expect: 100-continue`且handler需要读取body；或任意server先返回102/103再返回100/final。高层client传Expect header时第四个timeout为nil。
- 影响：Silly server在handler前不会自动发送100，handler读body时与尚未上传的client永久互等；handler若调用`respond(100)`，同一stream随即进入普通close/write完成路径，无法重置后再发送最终response。client若先收到102/103，会执行`status~=100`分支，将`hasresponse/writeclosed=true`并把它作为最终结果，后续真正response残留并污染连接复用。没有Expect timeout时挂起无期限。
- 证据：server read headers后直接创建stream并`pcall(handler,stream)`，没有Expect token解析或interim API。`h1s.respond`每次都向同一sendbuf写status-line且没有informational state。client Expect路径只调用一次`waitresponse`; 除精确100外的所有status都走`:594-596`final分支，而正常`client_waitresponse`的1xx loop被`hasresponse=true`绕过。
- 根因：实现把每个stream建模为恰好一组response headers，没有“0..N informational + 1 final”的HTTP响应序列；Expect又被作为request发送前的单次特例叠加。
- 建议解法：建立统一response state machine：client循环消费任意合法1xx，101单独升级，100授权发送content，其余informational暴露callback/忽略后继续；final才锁定headers/body framing。server提供只发送1xx且不关闭write state的`inform` API，并在策略允许时自动/显式发送100；若拒绝则发送final、关闭或安全drain request body。
- 回归测试：修复阶段覆盖100→200、103→100→200、多个103→final、417无100、Expect timeout，以及server handler读取body/先验证后拒绝；断言无互等、final headers不被1xx覆盖且连接边界正确。当前不运行100-continue互操作。

### HTTP1-016 — P1 — sender 可生成 TE+CL 冲突且正文编码与 `chunked` 声明不一致

- 状态：已确认；共享writer的header选择与body编码路径确定性静态核对。本轮不构造或发送歧义报文。
- 规范：RFC 9112 §6.2规定sender不得在任何含Transfer-Encoding的message中发送Content-Length；TE+CL是已知request smuggling/response splitting信号，发送前必须消除歧义。参见 [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.2)。
- 位置：共享`flush_header`在`lualib/silly/net/http/h1.lua:342-365`；body编码与结束在`:387-438`；client request入口在`:562-577`；server respond入口在`:761-798`。
- 触发：client request header或server response header同时含`content-length`与`transfer-encoding`，包括TE值为`chunked`；这些公开API接受调用方header table，proxy/gateway常会转发或合并外部字段。
- 影响：wire中同时出现两套边界声明。更严重的是writer因Content-Length分支优先，把`writeexpect`设为数字，之后正文按固定长度原样输出，即使同时声明`Transfer-Encoding: chunked`也没有chunk-size或last-chunk。不同proxy/server按TE或CL划界时会把同一字节流拆成不同message，形成request smuggling、response splitting、cache poisoning或连接 desynchronization；纯endpoint也会收到确定性畸形消息。
- 证据：`flush_header`先读取CL，只有`elseif`才检查TE，之后`compose_header`仍序列化原header的两字段。`write`仅在`writeexpect=="chunked"`时加chunk framing；CL存在使该条件永远为false。client与server共享这条路径，入口均未在任何字节写出前拒绝冲突。
- 根因：framing选择只更新内部`writeexpect`，没有把wire header集合、body encoder与RFC mutual-exclusion invariant作为一个原子构建步骤。
- 建议解法：在写request/status line之前规范化并验证全部framing字段；TE与CL共存立即返回错误且保证零字节输出，或由受信任的高层API明确选择一种并删除另一种。解析TE coding list后让header、encoder、结束标记共享同一不可变framing mode；client/server均复用此validator，错误连接不得归池。
- 回归测试：修复阶段覆盖client/server×CL+`chunked`/其他TE/重复字段/大小写，以及单独CL和单独chunked正常路径；冲突必须在任何socket write前失败，合法chunked必须含正确size与last-chunk。当前不生成或发送TE+CL消息。

### HTTP1-017 — P2 — `205 Reset Content` 被当成有正文响应，合法 keepalive response 可永久等待

- 状态：已确认；bodyless predicate及收发framing分支的确定性静态核对。本轮不发送205响应。
- 规范：RFC 9110 §15.3.6规定server不得在205 response中生成content；它的message在header section结束处终止。参见 [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.3.6)。
- 位置：共同bodyless predicate在`lualib/silly/net/http/h1.lua:94-100`；client response framing在`:524-552`；server respond body许可在`:761-770`；无deadline高层读取另见`HTTPC-002`。
- 触发：外部HTTP/1.1 server返回合法`205 Reset Content`，不含Content-Length/Transfer-Encoding并保持连接；反向方向上，Silly handler对205调用`write/closewrite(data)`。
- 影响：client把205判为可带body，因没有CL/TE而选择`readexpect="eof"`，`readall()`等待连接关闭；正常keepalive server不会关闭，调用可无限挂起且连接无法复用。Silly server则可输出规范禁止的content，peer可能忽略这些字节并把它们解释为下一条响应的开头，造成持久连接desynchronization。
- 证据：`bodyless_response`只列HEAD、204、304、全部1xx与成功CONNECT，没有205。client的非bodyless且无CL/精确chunked分支固定选择EOF framing；server把同一predicate取反为`allowbody=true`，不会删除CL/TE并允许正文发送。
- 根因：无正文status集合不完整，并被client framing与server send permission共同复用，单个遗漏同时破坏两个方向。
- 建议解法：将205加入无content语义；server在写任何header前拒绝/移除会声明或发送content的配置，并让write失败；client在205 header结束时立即标EOF且不消费后续字节。用共享、按规范版本审计的response-semantics函数统一H1/H2，同时保持HEAD/304的Content-Length元数据规则。
- 回归测试：修复阶段覆盖205有无CL0、保持/关闭连接、后续同连接200 response及server尝试写body；client必须立即完成并正确解析下一response，server不得输出content。当前不发送205响应。

### HTTP1-018 — P1 — fixed-length body 成功读取后 `recvbytes` 被重复累计，可提前复用残留正文连接

- 状态：已确认；fixed-length增量读取、完成判定、stream close与H1 pool归还链静态推导。本轮不建立连接或发送响应。
- 位置：重复计数在`lualib/silly/net/http/h1.lua:205-228`，fixed-length增量读取/EOF判定在`:231-270`，close完整性与pool release在`:440-464,710-729`，pool归还在`lualib/silly/net/http/client.lua:154-181`。
- 触发：对带`Content-Length: N`的response/request body使用`stream:read(k)`增量消费，且第一次或累计实际读取字节数达到`ceil(N/2)`但仍小于N；例如client收到`Content-Length: 10`后只调用`read(6)`再关闭stream。
- 影响：每次成功底层read都连续执行两次`s.recvbytes = s.recvbytes + #b`，实际6字节被记为12。`check_close_error`仅判断`recvbytes < readexpect`，因此把尚余4字节的响应判为完整并将socket归还H1 pool；下一请求读取response-line时从这4字节正文开始，形成确定性跨响应串线、错误响应归属和连接污染。若继续分段读取，虚高计数还会令`left`变为0/负数、EOF永远不精确命中或把非法长度交给底层read，产生错误/挂起。server读取request body使用同一函数，也会提前认为正文完成并破坏下一request边界。
- 证据：`read_eof`成功分支有两行完全相同的累计语句，随后返回append后的buffer size；fixed-length `read`以`left=len-recvbytes`计算下一次读取，并只在`recvbytes==len`时置EOF。stream close则用较弱的`recvbytes < readexpect`检查，所以overcount明确绕过broken判定。一次性`readall`通常请求全部left并另行置EOF，不能覆盖增量API和提前close路径。
- 根因：成功读取的统计语句重复，完成条件又混用`==`与`>=`/`<`，没有把“native实际消费量、buffer交付量、message剩余量”置于单一checked invariant。
- 建议解法：每批输入只累计一次实际`#b`，并在加法前保证`0 <= recvbytes <= readexpect`；fixed-length读取不得请求负数，超过声明长度或计数异常必须标broken并关闭。pool release应要求明确`eof`且`recvbytes == readexpect`，不能用`not less than`把overcount当完成；client/server共用同一终态验证。
- 回归测试：修复阶段覆盖CL=10按1/4/5/6/9/10字节组合读取、读一半后close、读完后同连接下一消息，以及client response/server request两个方向；断言计数等于wire消费、未读body从不归池、完整消息后下一条边界正确。当前只保存静态证据。

### HTTP1-019 — P1 — chunked 空写会提前生成 last-chunk，双终止块可污染下一消息

- 状态：已确认；共享writer的空payload、chunk encoder、close终止与持久连接复用路径静态推导。本轮不发送chunked报文。
- 位置：chunk编码在`lualib/silly/net/http/h1.lua:367-419`，`close_write`再次生成last-chunk在`:421-438`，client/server公开write与closewrite在`:684-703,774-798`，完成检查与连接复用在`:440-464,710-729,872-890`。
- 触发：没有显式Content-Length、因而由`flush_header(...,false)`选择chunked的client request或server response调用`write("")`；或者直接调用`closewrite("")`。空字符串在Lua中为真，因此closewrite会进入write路径。
- 影响：`write("")`编码`format("%x",0)..CRLF`，wire正是`0\r\n\r\n` last-chunk，但stream仍保持`writeclosed=false`并允许继续write应用数据；peer已把后续字节视为下一HTTP message。`closewrite("")`先写一份last-chunk，再无条件追加第二份`0\r\n\r\n`；本地完整性检查仍成功，连接可复用，残留终止块会成为下一request/status-line之前的空行/非法起始行。client与server共用代码，均可主动造成request smuggling式边界分叉、响应反同步或稳定连接失败。
- 证据：chunked分支没有`#data==0`特例，始终把size的十六进制值、CRLF、data、CRLF加入sendbuf；只有`close_write`应生成的终止块使用相同size 0编码。普通write不更新EOF/writeclosed状态，close_write也不检查前面是否已经意外发出zero chunk。`sendsize`增加0且完整性检查对chunked不核对任何结束计数，因此本地无法发现畸形wire。
- 根因：实现复用了data-chunk编码公式，却遗漏RFC chunk-data必须对应非零chunk-size、zero size专用于终止状态转换的语义；空应用写没有被规范化为no-op。
- 建议解法：公共`write("")`在任何header/body字节写出前直接成功no-op（或明确拒绝），绝不能调用chunk encoder；last-chunk只能由一次性的`closewrite`状态转换生成。closewrite(data)先传播data write失败，再原子标记closed并恰好生成一个terminal chunk/trailer；重复close稳定no-op且不追加wire。
- 回归测试：修复阶段覆盖client/server的`write("")`、多次空写、空写后非空写、`closewrite("")`、重复close及其后同连接下一消息；捕获wire断言仅close产生一个last-chunk，空write不改变framing，下一消息从正确start-line开始。当前只保存静态证据。

### HTTP1-020 — P1 — `Content-Length` 用 Lua number grammar 解析，可与严格 peer 形成边界分叉

- 状态：已确认；H1 sender/client/server parser、Lua数字语法与RFC Content-Length ABNF静态核对。本轮不构造或发送歧义报文。
- 规范：RFC 9110 §8.6把`Content-Length`定义为`1*DIGIT`，接收方还必须预防整数转换溢出；符号、hex、指数、小数或其他Lua number形式都不是合法字段值。参见[RFC 9110 §8.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.6)。
- 位置：sender framing选择在`lualib/silly/net/http/h1.lua:342-365`，client response解析在`:514-552`，server request解析在`:818-850`；重复字段/列表的独立问题见`HTTP1-002`。
- 触发：peer发送单一`Content-Length: +5`、`0x10`、`1e3`、`1.0`等Lua `tonumber`可转换且结果非负/整数可用的值；反向上，应用把同类string或完全非法string作为outbound content-length。
- 影响：receiver会按Lua数值（如16或1000）读取正文，而严格proxy/peer按规范拒绝或采用其他边界；同一持久字节流因此被拆成不同request/response，形成request smuggling、response splitting、cache poisoning或跨请求错配。sender对可转换的非十进制值按转换结果编码body却把原文本上wire；对不可转换值则以`or 0`把内部body设为禁止/空，同时仍原样发送非法header，主动产生本地状态与wire framing不一致。
- 证据：三个入口都直接调用`tonumber`，没有`^%d+$`、逐位overflow或canonical decimal校验。receiver只检查nil/负数；Lua接受十六进制、指数、前导符号和部分整数值浮点文本。sender的`tonumber(cl) or 0`甚至把解析失败折叠成合法内部零值，`compose_header`随后照旧序列化调用方的原始字段值。
- 根因：把HTTP十进制wire整数交给通用编程语言数字parser，且sender没有先把validated framing mode与canonical header原子化。
- 建议解法：client/server共享专用Content-Length parser：先规范化`HTTP1-002`的重复/list形式，再要求每项非空ASCII DIGIT、逐位checked accumulation、全部值相同，输出受实现/配置上限约束的integer；sender只接受validated integer或canonical decimal并重新格式化，任何错误在写start-line前失败且连接不复用。
- 回归测试：修复阶段覆盖0、前导零、上限/上限加一、`+/-`、hex、指数、小数、内部/首尾空白、非ASCII digit及重复/list组合；client/server parser与request/response sender四向都必须对非法值零字节fail closed，合法值采用同一边界。当前只保存静态证据。

### HTTP1-021 — P1 — sender 按 Lua key 大小写识别控制字段，可自行生成重复 Host 与 TE+CL

- 状态：已确认；高层/streaming client、server response、shared writer与HTTP字段名case-insensitive语义静态核对。本轮不发送带混合大小写的字段。
- 规范：HTTP field name不区分大小写；sender决定Host、Content-Length、Transfer-Encoding、Connection、Expect等控制语义时必须先统一名称，且不得生成TE+CL。参见[RFC 9110 §5.1](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.1)与[RFC 9112 §6.2](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.2)。
- 位置：只有convenience路径lowercase header在`lualib/silly/net/http/client.lua:329-345`，streaming `M.request`直传在`:303-327`；H1控制字段查找/Host suppression在`lualib/silly/net/http/h1.lua:79-93,342-365,556-577`，server respond共享writer在`:758-798`。
- 触发：公开`client:request`或server `stream:respond`使用合法常规拼写`Host`、`Content-Length`、`Transfer-Encoding`、`Connection`或`Expect`；例如POST header为`{["Content-Length"]="5"}`后写5字节body。文档说明接收后的map为小写，但没有在发送入口拒绝其他合法HTTP大小写。
- 影响：`Host`不会被suppression识别，client先生成自己的`host:`再发调用方Host，形成重复/冲突authority。`Content-Length`不被framing选择识别：有data时库自动补小写`transfer-encoding: chunked`并发送原CL，形成TE+CL且body按chunked编码；无data时又补小写`content-length: 0`形成重复不同长度。Connection/Expect/TE也会在本地状态机中失效。严格peer、proxy与Silly本地writer据同一字段采用不同边界/连接语义，可导致request smuggling、response splitting、路由歧义和pool反同步；server response方向相同。
- 证据：receiver会`lower(k)`，证明项目知道字段名case-insensitive；sender却仅以精确小写Lua key索引，并在`compose_header`只跳过`k=="host"`。高层get/post复制为小写掩盖问题，但公开streaming request和server respond没有复制/验证。字段名`Content-Length`本身完全符合H1 token grammar，因此`HTTP1-009`的非法octet校验不能修复；调用方也未显式同时提供TE，区别于`HTTP1-016`。
- 根因：接收map规范化、高层client规范化与底层writer控制解析各自实现，底层把“调用方恰好使用小写”当成未经执行的前置条件。
- 建议解法：所有sender入口在写任何start-line/header前复制并ASCII lowercase名称，合并或拒绝大小写折叠后的重复控制字段，再执行Host/CL/TE/Connection/Expect语义校验；H2使用同一规范化结果并拒绝connection-specific fields。若API坚持只收小写，也必须运行时在资源/字节发布前明确拒绝uppercase，不能按普通字段发送。
- 回归测试：修复阶段对client streaming/convenience和server response分别覆盖每个控制字段的lower/title/upper及大小写重复组合；捕获wire断言恰好一个Host、永无TE+CL、framing/keepalive/Expect一致，并验证非法输入零字节失败。当前只保存静态证据。

### HTTP1-022 — P2 — server 错删 HEAD/304 的合法 Content-Length/Transfer-Encoding 元数据

- 状态：已确认；response body语义、H1 framing fields与server sender共享predicate静态核对。本轮不发送HEAD或304响应。
- 规范：HEAD response不得含content，但其response fields表示等价GET会有的值；RFC 9110 §8.6明确允许HEAD携带与GET一致的Content-Length，并允许304携带对应200的Content-Length。RFC 9112 §6.1也允许HEAD/304用Transfer-Encoding指示原响应会采用的coding，而1xx/204才是MUST NOT发送TE。参见[RFC 9110 §8.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.6)与[RFC 9112 §6.1](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.1)。
- 位置：共同bodyless分类在`lualib/silly/net/http/h1.lua:94-100`，server `respond`无差别删除字段在`:758-771`，header flush/发送在`:342-365,790-798`。
- 触发：handler响应HEAD并显式提供等价GET representation长度，或返回304并提供对应selected representation的长度/coding；例如`stream:respond(304,{["content-length"]="1234"})`。
- 影响：库在应用无法观察/阻止的情况下删除合法元数据。HEAD调用方无法预估下载大小、比较representation或验证缓存；304 cache revalidation失去可用于检查stored response的长度/coding信息，造成互操作和缓存元数据偏差。H2 sender并不走这段删除逻辑，因ALPN不同而得到不同HTTP语义。
- 证据：`bodyless_response`把HEAD、所有1xx、204、304和successful CONNECT统一成true；`h1s.respond`对任何true都执行`header["content-length"]=nil`和`header["transfer-encoding"]=nil`，没有按method/status区分“无message content”与“字段也被禁止”。client正确地以header结束划界并不要求删除这些字段，说明删除纯属sender策略错误。
- 根因：单个boolean同时承担body framing终止与field legality；规范实际需要二维response semantics（是否有content、哪些长度/coding元数据允许、其值约束）。
- 建议解法：用method/status矩阵分离body许可与field规则：HEAD/304禁止实际content但保留经校验且符合would-be response约束的CL/TE；1xx/204禁止TE并按各自规则处理CL；successful CONNECT另行进入tunnel状态。H1/H2共享语义层，编码层只负责wire framing。
- 回归测试：修复阶段覆盖HEAD/304/1xx/204/205/successful CONNECT与普通200的CL/TE/body组合；捕获H1/H2 fields，断言HEAD/304合法元数据保留但无body，禁止组合在任何header写出前失败。当前只保存静态证据。

### HTTP1-023 — P2 — 读取失败后再次 `readall` 会把缓冲的残缺正文作为成功返回

- 状态：已确认；H1 buffer、cached error、incremental/chunk读取与stream收尾静态推导。本轮不制造timeout、截断或错误chunk。
- 位置：部分数据进入stream buffer在`lualib/silly/net/http/h1.lua:174-228`；`read/read_all_body`错误保存于`:231-324`；cached-error特殊分支在`:326-340`；client timeout wrapper在`:641-681`。
- 触发：一次`read(n)`或`readall(timeout)`在若干完整chunk/部分body已写入`s.recvbuf`后遇到timeout、transport EOF、非法chunk ending或其他读取错误，调用方收到`nil,err`后为重试/收尾再次调用`readall()`。
- 影响：第二次调用先看到`s.err`，只要buffer非空就返回全部残缺数据和nil error，永久丢弃已缓存的协议/transport错误。应用可能把截断request当完整输入执行写操作，或把截断response当可信成功结果进行解析、缓存或签名校验；错误peer只需在选定前缀后终止/破坏framing。连接最终通常会因`s.err`不归池，但业务完整性已经在错误返回形状处被破坏。
- 证据：首次失败路径执行`s.err=err; return nil,err`且不会清掉先前append的数据；再次进入`readall`时明确执行`dat=s.recvbuf:readall()`，若`#dat>0`便`return dat,nil`，只有空buffer才返回cached error。普通`read`对不足n的数据保留buffer，chunked `read_all_body`也可在多个成功chunk后失败，所以该分支可达；现有timeout测试只让不足Content-Length的字节停留在底层conn buffer，没有覆盖已完成chunk/增量read留下的stream buffer。
- 根因：实现试图允许错误后取回partial bytes，却使用普通成功返回通道且消费掉唯一错误状态；“partial data + terminal error”没有明确API表示或一次性状态机。
- 建议解法：一旦进入terminal error，所有后续`read/readall`必须稳定返回同一错误；如确需暴露partial data，首次失败原子返回`nil,err,partial`或专用方法/structured result，并明确数据不完整，不能在下一调用伪装成功。error、buffer与EOF转移由统一终态函数管理，client/server一致；close仍强制broken且清理残留。
- 回归测试：修复阶段覆盖fixed-length先`read(n)`不足后timeout/EOF、chunked完成一块后非法size/ending/timeout、close-delimited部分数据后错误，以及client/server两个方向；连续调用`readall/read`必须始终保留错误，若提供partial接口则只交付一次且带incomplete标记。当前只保存静态证据。

### COMP-001 — P2 — gzip inflate 未要求完整 stream，截断输入可作为部分成功返回

- 状态：已确认；zlib状态机与RFC 1952静态核对。本阶段不生成截断/拼接gzip样本。
- 规范：[zlib 1.3.1 manual](https://www.zlib.net/manual.html)说明`inflate()`只有在gzip member结尾返回`Z_STREAM_END`，且不会自动解码concatenated members；[RFC 1952 §2.2](https://www.rfc-editor.org/rfc/rfc1952.html#section-2.2)定义gzip file为一系列members，compliant decompressor须接受符合规范的file。
- 位置：`lgzip_decompress`在`luaclib-src/lcompress.c:62-110`；HTTP convenience client自动调用点在`lualib/silly/net/http/client.lua:389-395`。
- 触发：输入在header/deflate stream/trailer中途截断、只产生少于一个Lua buffer的partial output，或包含多个合法gzip members/第一个member后的尾随octet；超大Lua string还会在赋给zlib `uInt avail_in`时窄化。
- 影响：截断或未校验完整性的HTTP响应会以成功和partial plaintext交给应用，可能绕过“解压失败即拒绝”的完整性策略；合法concatenated gzip只返回首member而静默丢数据，尾随垃圾也不报错。大于`UINT_MAX`的输入可能只处理前缀却仍报告成功。
- 证据：loop条件是`while (stream.avail_out == 0)`而非`ret != Z_STREAM_END`；switch仅拒绝`Z_NEED_DICT/Z_DATA_ERROR/Z_MEM_ERROR`，`Z_BUF_ERROR`和普通`Z_OK`在output未填满时直接落入成功；结束时不检查`ret`、`avail_in`或重置解码下一member。
- 根因：把“当前调用还有输出空间”误当作“压缩流完整结束”，并缺少明确的single-member/multi-member及trailing-data API契约。
- 建议解法：分块喂入`uInt`范围内input，持续inflate直到`Z_STREAM_END`；输入耗尽但未到终态必须报truncated，其他非`Z_OK`终态失败。选择并文档化strict single-member（要求无剩余）或按RFC循环`inflateReset2`处理全部members；同时与`HTTPC-001`的decoded-size/ratio budget统一实现。
- 回归测试：修复阶段覆盖每个header/trailer边界截断、deflate中途截断、CRC/ISIZE错误、空输入、尾随垃圾、两个members以及大于单次`uInt`的分块输入；失败不得返回partial output。当前不新增压缩样本。

### REDIS-001 — P1 — RESP 畸形响应触发未清理异常，永久占住 reader queue

- 状态：已确认；parser到reader ownership调用链静态推导。本阶段不向driver发送畸形RESP。
- 规范：[Redis RESP specification](https://redis.io/docs/latest/develop/reference/protocol-spec/)规定首byte标识合法type、所有protocol片段以CRLF结束、integer为有符号64位十进制，RESP2 bulk/array只有`-1`表示null；客户端应把非法编码作为protocol error并丢弃连接。
- 位置：`read_response/response_header`在`lualib/silly/store/redis.lua:33-82`；单命令reader ownership与queue交接在`:215-264,266-300`；pipeline对应路径在`:310-348`。
- 触发：peer返回未知type byte、空/非数字bulk或array length、非法负length、错误line terminator，或使递归parser内部抛出的其他异常。
- 影响：当前reader coroutine异常退出而不执行`close_socket`或`wakeup_next_reader`，`redis.readco`永久指向已死亡coroutine，socket仍可能保留；所有后来请求在`waitq`永久挂起。若异常发生在pipeline同样会遗留整条连接和等待者，单个错误响应可造成持久性应用级DoS。
- 证据：`read_response`不检查`response_header[head]`即调用`func(...)`；bulk/array handler不验证`tonumber`结果就执行`nr < 0`；line只用`sub(...,-3)`盲删两byte，不验证CRLF，bulk body也不验证尾随CRLF。外层命令/pipeline没有`pcall/finally`，正常路径末尾才交接reader。
- 根因：协议解析错误使用Lua runtime exception表达，而reader token和pending waiter清理依赖显式正常/已知I/O错误分支，没有统一的connection-fatal收尾边界。
- 建议解法：parser对每个type、数字grammar/range、null sentinel和CRLF显式验证并只返回structured protocol error；reader owner以protected/finally结构保证任意失败都关闭并清空socket、复位`readco`、唤醒全部waiters。协议错误连接绝不复用，保留原始错误给所有受影响调用。
- 回归测试：修复阶段逐项覆盖unknown prefix、empty/nondecimal/overflow length、`-2`、LF-only、错误bulk terminator和nested malformed element；断言所有并发调用有限时间返回同一connection error，`readco=false`且下一次命令能新建连接。当前不生成畸形RESP。

### REDIS-002 — P2 — command write failure 调用错误 ownership 清理路径并触发断言

- 状态：已确认；write failure与reader token不变量静态推导。本阶段不注入socket send failure。
- 位置：普通动态command发送分支在`lualib/silly/store/redis.lua:266-300`；`close_socket`的owner约束在`:215-235`；pipeline发送失败分支在`:310-348`。
- 触发：连接已被peer关闭但Redis对象尚保留`sock`，下一条普通命令的`sock:write`返回false；并发`close()`与已捕获sock的命令也可触发。pipeline在相同send failure下进入另一条错误分支。
- 影响：普通命令不会按API返回`false, err`，而是在`close_socket`内因`redis.readco`不是当前coroutine（单请求时通常为false）触发assert并终止task；有现存reader时还可能把它的连接状态错误地交给writer清理。pipeline则不关闭或清除失败socket，后续请求持续使用坏连接并重复失败。
- 证据：write发生在`wait_for_read(self)`之前；失败立即调用`close_socket(self, err)`，而该函数明确assert“must be called by redis.readco”。pipeline的`if not ok then return nil, err end`完全跳过socket/reset/waiter收尾。
- 根因：连接fatal cleanup与当前response reader ownership硬绑定，但send side同样能首先发现fatal error；普通命令与pipeline又复制出不一致的失败逻辑。
- 建议解法：建立可由任意coroutine安全调用、幂等且按socket generation核对的`fail_connection`；原子清除当前sock、关闭它并唤醒属于该generation的reader/waiters，不能assert caller identity。普通命令与pipeline复用同一发送/失败路径；若已有reader负责最终广播，则writer只标记fatal并安全唤醒它。
- 回归测试：修复阶段覆盖idle peer close后的首个command/pipeline、concurrent close/write以及已有reader时另一writer send failure；所有调用只返回错误、不抛异常，坏socket被清除且随后可重连。当前不做send fault injection。

### REDIS-003 — P1 — connect/handshake/command/pipeline 无 deadline 或 cancellation

- 状态：已确认；全部blocking API调用链静态核对。本阶段不运行slow Redis peer。
- 位置：配置对象在`lualib/silly/store/redis.lua:148-166`；connect与AUTH/SELECT handshake在`:135-145,180-213`；command/pipeline read路径在`:266-348`。
- 触发：地址connect不完成，peer接受后不回复AUTH/SELECT，普通或pipeline命令只回复前缀/部分bulk，或合法阻塞命令永不返回；调用者也没有API取消已经进入driver的操作。
- 影响：首个reader永久占有`readco`，同一client的全部后续请求无限堆在`waitq`；handshake期间同一对象的连接mutex也被永久占用。上层request deadline无法下传，服务关闭只能依赖另一个task恰好调用`close()`，形成task/queue/socket retention与级联服务耗尽。
- 证据：`config`只有`addr/auth/db`；`tcp.connect(redis.addr)`不传timeout，所有`sock:read(...)`均不传timeout；`task.wait()`等待reader token也没有timer/cancel分支。command和pipeline签名同样不接受deadline。
- 根因：driver把连接生命周期和串行response配对实现为无限等待的协程队列，没有把时间预算作为跨connect/handshake/write/read/queue的统一状态。
- 建议解法：配置合理的connect/handshake默认timeout，并允许每次call/pipeline传absolute deadline/cancel token；所有阶段使用同一剩余预算。owner超时/取消后必须按connection generation关闭连接并失败该连接上所有已发送pending请求，因为RESP2无法安全跳过迟到响应；尚未发送的排队请求可单独取消。阻塞命令允许调用者显式覆盖。
- 回归测试：修复阶段分别让connect、AUTH、SELECT、response line、bulk body和pipeline第N项停住，覆盖排队前/后取消；断言在预算内全部相关waiter结束、socket不复用且无timer/queue残留。当前不运行slow peer。

### REDIS-004 — P1 — RESP line/bulk/aggregate 无大小、元素数或递归深度上限

- 状态：已确认；parser资源路径静态推导。本阶段不生成大RESP或深嵌套array。
- 规范：[Redis RESP specification](https://redis.io/docs/latest/develop/reference/protocol-spec/)说明bulk string默认server上限可达512MiB，aggregate可嵌套；client仍需按自身内存/栈预算验证长度、count和nesting，不能无条件信任peer声明。
- 位置：line读取与type dispatch在`lualib/silly/store/redis.lua:33-64`；bulk直接定长读取在`:44-54`；递归array分配/解析在`:66-82`；新连接没有调用TCP buffer limit的路径在`:180-213`。
- 触发：peer持续发送不含LF的prefix line，声明超大bulk后慢速/完整发送body，声明巨大array count，或返回深层nested arrays。
- 影响：line和bulk可使单连接持续增长内存；巨大count使CPU长循环并扩展Lua table；深嵌套通过`read_response`递归耗尽C/Lua stack并崩溃。攻击发生在命令响应与AUTH/SELECT阶段，且在共享client上会连带阻塞全部调用者。
- 证据：所有line使用`sock:read("\n")`且conn未配置limit；bulk对`tonumber(res)`仅判负后直接`read(nr+2)`；array按peer count创建table并逐项递归，没有max line/bulk/elements/total bytes/depth，也没有累计response budget。
- 根因：driver完全继承server声明的资源规模，未在RESP结构层定义可配置的解析预算；通用socket backpressure不能限制已接受的单条合法长度消息或递归复杂度。
- 建议解法：client配置并默认启用max line、bulk bytes、aggregate elements、nesting depth及每response/pipeline累计decoded bytes；在分配/定长read前做整数overflow和budget检查，并给socket设置略高于parser工作集的buffer limit。超限视为connection-fatal protocol/resource error并失败同连接pending。
- 回归测试：修复阶段覆盖无LF长行、limit边界bulk、超大/负/overflow count、宽array、深array及pipeline累计超限；断言在有界内存/时间内关闭且无partial result。当前不生成资源消耗输入。

### REDIS-005 — P2 — close 看不到 in-flight connect/handshake，关闭对象可被晚到连接复活

- 状态：已确认；close/connect interleaving静态推导。属于并发时序问题，本阶段不强行动态复现。
- 位置：`redis:close`在`lualib/silly/store/redis.lua:168-174`；lazy connect、AUTH/SELECT与返回在`:180-213`；caller在`:266-277,310-321`收到返回后写入`self.sock`。
- 触发：task A进入`tcp.connect`或AUTH/SELECT并yield，此时新socket只在`connect_to_redis`局部变量；task B调用`redis:close()`，看到`self.sock=false`后只设置`closed=true`；随后A连接/握手完成。
- 影响：close无法取消/关闭in-flight socket，若peer停在handshake可在close返回后继续保留task与fd；若完成，A不复查closed就返回socket，caller把它赋回`self.sock`并发送命令，使逻辑已关闭的client重新拥有活连接。该连接之后不会再被最初close回收，破坏shutdown与资源所有权契约。
- 证据：`closed`只在connect锁内、建立socket之前检查一次；局部`sock`直到函数返回后才由caller赋值。`close()`既不获取同一mutex，也无connecting generation/cancel handle；AUTH/SELECT后及两处赋值前均无second check。
- 根因：对象状态只有`false/socket`两态，缺少CONNECTING状态和连接generation；close与异步建立连接之间没有共同的发布/撤销协议。
- 建议解法：在锁保护下登记in-flight generation/cancel state；close原子标记closed并取消/关闭已建立或正在建立的transport。connect/每步handshake后及publish前复查generation与closed，失效即关闭局部socket并返回ECLOSED；socket发布也必须在同一同步边界完成，避免caller二次赋值窗口。
- 回归测试：修复阶段在TCP connect、AUTH read和SELECT read三个yield点分别并发close，再让peer成功/失败/保持静默；断言close后命令不成功、无socket重新发布且所有fd/task最终结束。当前只说明并发时序。

### REDIS-006 — P2 — RESP null 写入 Lua array 后槽位消失，合法响应无法无损表示

- 状态：已确认；Lua table语义与RESP null array规范静态核对。不需要网络复现。
- 规范：[Redis RESP specification](https://redis.io/docs/latest/develop/reference/protocol-spec/#null-elements-in-arrays)允许array中的单个元素为null bulk string；其位置属于响应语义，例如`SORT ... GET`缺失值。客户端必须保留array元素数量、顺序与null位置。
- 位置：bulk null转换在`lualib/silly/store/redis.lua:44-53`；array元素写入在`:66-81`；pipeline扁平结果写入在`:335-348`。
- 触发：`MGET`、`SORT ... GET`、transaction/module等返回中间或末尾`$-1`；pipeline任一command合法返回top-level null。
- 影响：`cmd_res[i] = nil`实际删除该key，末尾null会改变/丢失长度，中间null形成Lua sparse table并使`#`/`ipairs`行为不可靠；无法区分`["a"]`、`["a", null]`等不同合法RESP。pipeline的result slot同样消失，其flat pair contract无法稳定迭代，业务可能把值错配到另一个key/command。
- 证据：bulk handler把任意negative length返回Lua nil；array和pipeline均直接赋值，没有NULL sentinel、显式`n`字段或typed reply。Lua table不存储值为nil的entry。
- 根因：wire protocol的first-class null被直接映射到Lua“absence”，但aggregate返回格式没有另外保存shape metadata。
- 建议解法：定义公开且唯一的`redis.null` sentinel（或typed reply对象），array/pipeline内部一律保存sentinel并保持dense sequence；顶层命令可为兼容性选择继续返回nil，但文档须区分。pipeline最好返回每项`{ok=..., value=...}`而非含nil的flat tuple，并提供迁移策略。
- 回归测试：修复阶段覆盖首/中/尾/全null、nested arrays、空array与null array、pipeline null/error混合；断言元素count、顺序和null identity可精确round-trip。当前仅作静态语义核对。

### REDIS-007 — P2 — server-push/持续输出模式没有专用 reader，消息会与命令响应错配

- 状态：已确认；RESP2 subscribed/monitor mode语义、单response command wrapper与公开文档的确定性静态核对。本轮不连接Redis或发布消息。
- 规范：Redis RESP2在`SUBSCRIBE/PSUBSCRIBE`后进入subscribed mode：首次返回订阅确认，之后server可在没有对应request的情况下持续推送`message/pmessage/subscribe/...`数组；client必须以独立push reader交付这些消息，并只允许该模式规定的命令，不能继续按严格request→one response配对。
- 位置：所有命令共用的一次write/一次`read_response` wrapper在`lualib/silly/store/redis.lua:266-303`，reader token队列在`:238-264`；对象没有push/read subscription API，文件到`:351`结束。中英文文档宣称所有标准命令并给出Pub/Sub章节，见`docs/src/reference/store/redis.md:49-57,224-232,665-701`与英文同名文档。
- 触发：调用`subscriber:subscribe("news")`取得确认后，server推送一条message；应用随后调用订阅态允许的`PING`、`UNSUBSCRIBE`或再次`SUBSCRIBE`，或错误地尝试普通命令以读取下一结果。`MONITOR`取得OK后持续收到无request对应的simple-string流时存在相同错配。若调用文档所说的“任意标准命令”执行`HELLO 3`，RESP3 map前缀会先进入`REDIS-001`的unknown-type异常路径；即便未来只补map解析，`>` push/client tracking仍需要本条所述的独立owner。
- 影响：第一条SUBSCRIBE只消费确认并执行`wakeup_next_reader`，后续push留在socket buffer且没有公开读取入口。下一命令的`read_response`会消费最早push并把它作为该命令结果返回，真实command response继续滞后，之后每次调用都可能错一拍；消息无法可靠交付，unsubscribe count/state也无法跟踪。若应用从不再调用命令，push则在无上限TCP buffer路径持续积累。
- 证据：动态method对任何命令完全相同：write一次、取得reader ownership、read一个RESP value、立即释放ownership。代码没有subscribe/monitor/protocol-version mode flag、后台read loop、push callback/channel、allowed-command gate或reconnect后的resubscribe逻辑；type dispatch也固定只有RESP2的`+-:*$`五种前缀。双语reference开篇仍宣称“完整RESP”和“所有标准命令”，其“发布订阅”示例创建subscriber但从未调用subscribe或读取message，只用另一连接publish，因此无法验证并扩大了所宣称能力边界。
- 根因：driver建立在“每个request恰有一个按序response”的普通RESP2模型上，却无条件把会改变连接为server-push状态的命令也暴露为相同动态method。
- 建议解法：提供独立subscription对象/connection owner：握手后由唯一reader loop持续解析push，按channel/pattern交付并维护subscription count，只允许规范列出的订阅态命令；close/cancel/reconnect有明确语义与有界push queue。普通client应在发送SUBSCRIBE类命令前拒绝并引导使用该API，避免污染通用response队列。
- 回归测试：修复阶段覆盖subscribe确认后message、message先于PING reply、多channel/pattern、unsubscribe至0恢复普通模式、server disconnect/reconnect及consumer背压；断言每个push与command response归属准确、队列有界。当前不运行Pub/Sub交互。

### REDIS-008 — P1 — 共享连接不隔离 `MULTI/WATCH` 会话，其他协程命令可被并入错误事务

- 状态：已确认；Redis connection-scoped transaction语义与client多协程共享模型的确定性时序核对。本轮不执行事务或并发barrier。
- 规范：`MULTI`到`EXEC/DISCARD`以及相关`WATCH/UNWATCH`状态属于单条Redis连接；MULTI后收到的所有普通命令都会排入当前transaction，与发送它的本地协程无关。多调用者复用连接时，client必须把整个transaction session独占或将完整序列原子发送，不能只按单response交接reader。
- 位置：单连接/并发队列模型在`lualib/silly/store/redis.lua:19-30,238-264`，任意动态命令每次独立write/read在`:266-303`，批量原子write入口在`:310-349`；中英文文档明确所有请求共享单连接并支持并发，见`docs/src/reference/store/redis.md:40-57,758-772,838-849`与英文同名文档。
- 触发时序：task A调用`db:multi()`并读到OK后yield；task B调用`db:set(...)`；task A随后发送自己的命令并`exec()`。WATCH与后续读取/MULTI/EXEC跨协程交错同理。
- 影响：task B的SET实际返回`QUEUED`并被纳入task A的EXEC结果，而B可能把它当普通成功；A的事务包含非本意副作用且结果元素数/顺序变化。WATCH条件也可保护或取消错误调用者的事务。涉及余额、锁、幂等标记等操作时，原子性与调用者隔离被直接破坏，错误不会表现为transport failure。
- 证据：reader ownership只围绕“一次read_response”保持，命令返回后`wakeup_next_reader`立即释放；对象没有transaction owner/state/mutex。动态method无条件暴露MULTI、EXEC、DISCARD、WATCH、UNWATCH，与普通命令完全相同。发送发生在获取reader token之前，且不同API调用之间应用可正常yield；因此跨调用的连接状态不可能绑定到原协程。单个pipeline会一次write整批命令，但公开API没有要求或验证事务必须使用该形式。
- 根因：把RESP按序response multiplexing误当成connection-level command state也可安全multiplex；client只跟踪socket/read owner，不跟踪Redis mode与logical session owner。
- 建议解法：提供`transaction(fn)`或transaction对象，在同一owner lock下覆盖WATCH/MULTI到EXEC/DISCARD全部序列，并禁止其他命令写入该socket；取消/异常必须DISCARD或直接关闭连接，避免状态泄漏。普通动态API检测到stateful命令时应拒绝或转入显式session。若支持pipeline事务，验证MULTI/EXEC配对并以typed results保持归属。
- 回归测试：修复阶段以可控scheduler覆盖A MULTI→B SET→A EXEC、WATCH交错、owner异常/取消、DISCARD和并发普通命令；断言B永不进入A事务、结果基数稳定、结束后连接恢复normal。当前仅记录静态交错。

### REDIS-009 — P1 — client 不支持 TLS，`AUTH` credential 与全部数据固定明文传输

- 状态：已确认；公开配置、connect/handshake调用链与Redis TLS部署能力的确定性静态核对。本轮不建立TLS或抓取credential。
- 权威依据：[Redis TLS documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/security/encryption/)说明Redis可为client connection启用TLS，并可关闭普通TCP port形成TLS-only部署；client需要验证server certificate/identity并可按部署提供client certificate。AUTH只提供应用认证，不加密其password或后续command/data。
- 位置：唯一配置面在`lualib/silly/store/redis.lua:19-30,148-166`；连接固定调用`tcp.connect`及AUTH/SELECT handshake在`:135-145,180-213`；中英文reference配置同样只列`addr/auth/db`在`docs/src/reference/store/redis.md:61-104`与英文同名文档。
- 触发：配置非空`auth`连接任何跨主机Redis，或连接只启用TLS port/要求client certificate的生产Redis；网络路径上的被动监听者或主动中间人可观察/修改TCP字节。
- 影响：AUTH password、key names、values、Pub/Sub消息和transaction内容全部以明文暴露；主动peer还可伪装server收集credential并返回看似正常RESP。driver无法连接关闭明文port的安全部署，使用者只能另加本地TLS tunnel或降低server安全策略；若文档/部署误把AUTH当作保密机制，会直接泄露长期凭据和业务数据。
- 证据：module只require `silly.net.tcp`，没有TLS依赖、scheme解析、CA/hostname/client cert配置或upgrade分支。`connect_to_redis`在socket建立后立即以RESP写`AUTH`，其参数由`compose`原样进入bulk string；连接成功也没有任何peer identity验证。配置和返回路径均无法表达TLS required/verify失败。
- 根因：最小RESP client把transport固定为开发环境明文TCP，把AUTH误当成足够的连接安全边界；transport identity没有进入client配置或reconnect generation。
- 建议解法：支持明确且默认fail-closed的TLS配置/`rediss` endpoint，至少提供required、CA trust、hostname/SAN验证和可选client cert/key；复用修复后的TLS层并在发送AUTH前完成验证，绝不静默降级明文。若保留plaintext，要求显式选择并在文档突出credential/data不保密；连接generation必须携带相同安全策略。
- 回归测试：修复阶段覆盖受信TLS、错误CA/hostname、mTLS、TLS-only server、握手失败及明确plaintext opt-in；断言认证只在验证成功后发送、失败连接不发布/复用、日志不含password。当前不建立TLS连接或发送credential。

### REDIS-010 — P2 — RESP aggregate 丢失嵌套 error 的类型与位置，事务结果无法可靠归因

- 状态：已确认；RESP error作为first-class value、array decoder与pipeline/transaction返回模型的确定性静态核对。本轮不执行MULTI/EXEC或构造nested error。
- 规范：[Redis RESP protocol](https://redis.io/docs/latest/develop/reference/protocol-spec/)允许aggregate内嵌error reply，典型场景是`EXEC`返回每条事务命令各自的结果或错误。client必须保留每个元素的type和位置；一个error元素不把array本身变成top-level error，也不能与内容相同的simple/bulk string合并成不可区分的Lua值。
- 位置：simple/error handlers在`lualib/silly/store/redis.lua:33-43`；array递归和aggregate success折叠在`:55-82`；动态command/pipeline返回在`:266-300,310-348`。
- 触发：`EXEC`、module command或其他array response中同时包含成功字符串、bulk string与一个或多个`-ERR ...`元素；特别是正常bulk string内容恰与error文本相同。nested array重复该问题。
- 影响：decoder把error与普通字符串都存成同一种Lua string，只用`cmd_success = cmd_success and success`把整个aggregate压成单个false。调用方知道“某处失败”却无法定位哪一项、无法区分失败元素与同文正常数据，也会把本身合法返回的EXEC array标成top-level command失败。事务结果无法按命令序号可靠提交、补偿或审计；nested aggregate的信息损失会继续向上传播。
- 证据：`'-'` handler返回`true,false,res`，`'+'/'$'`返回相同Lua string类型和`success=true`；array loop只保存`cmd_res[i]=data`，丢弃每个元素的success bit，最后返回所有元素AND。不存在error sentinel/typed reply或并行status数组。pipeline只在顶层为每个command保存success；若该command结果本身是array，元素级状态已永久丢失。18组Redis测试只覆盖top-level`-ERR`和pipeline中一个top-level错误，没有EXEC/nested errors。
- 根因：三返回值parser把type压成“连接可继续/整体success/data”，这一模型只适合top-level reply；递归进入aggregate后没有保留child reply的类型标签。
- 建议解法：parser内部使用typed RESP value（至少区分simple、error、integer、bulk、null、array），aggregate保存dense child values；公开层仅对top-level error映射`ok=false`，array本身保持成功，child error以稳定`redis.error`对象/标签保留code/message/index。pipeline返回每个top-level typed result，和`REDIS-006`的null sentinel统一设计并提供兼容迁移。
- 回归测试：修复阶段覆盖EXEC全成功、单/多错误、error位于首中尾、与error文本相同的simple/bulk string、nested array及null混合；断言array top-level成功、每个child类型/位置完整，pipeline仍按输入命令对齐。当前不发送事务。

### MYSQLC-001 — P1 — binary result row 未验证 NULL bitmap 长度即发生 C 越界读

- 状态：已确认；C pointer与官方binary row布局静态推导。本阶段不生成截断MySQL packet。
- 规范：[MySQL Binary Protocol Resultset Row](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_binary_resultset.html)规定row为1-byte header、长度`(column_count + 7 + 2) / 8`的NULL bitmap及非null values；parser必须先确认packet完整包含bitmap再逐bit访问。
- 位置：`lparse_row_data_binary`在`luaclib-src/mysql/lmysql.c:430-471`，特别是bitmap pointer/size推进`:439-456`；通用checked readers在`luaclib-src/mysql/binary.h:36-145`。
- 触发：prepared statement返回的column definitions有足够列数，但某个binary row packet只有header和不足长度的NULL bitmap。例如8列需要2-byte bitmap，packet只带1 byte后截断。
- 影响：`null_map[byte]`从Lua string边界外读取原生内存，ASan构建可abort，普通构建产生undefined behavior并可能依据相邻内存错误判断列是否null；随后解析位置也已越界。恶意/受劫持MySQL peer可远程触发进程崩溃，并潜在影响数据完整性。
- 证据：函数仅在`chk.pos += 1`后检查`chk.pos >= chk.len`；随后保存`null_map = data + pos`并无条件`chk.pos += null_bytes`，loop内直接访问`null_map[byte]`。该访问不经过会检查`pos/len`的`binary_read_*`。
- 根因：bitmap被当作可信固定区间的裸pointer，而不是经统一checked slice取得；列元数据长度与当前row packet长度之间没有显式前置条件。
- 建议解法：用overflow-safe计算null_bytes，在保存slice前验证`null_bytes <= chk.len - chk.pos`；最好新增`binary_read_slice`统一返回受界限约束的pointer/length。拒绝非`0x00`row header，解析所有非null值后还应按协议决定是否要求完整消费packet；任何codec error使连接fatal。
- 回归测试：修复阶段按column_count 1/6/7/8/9等bitmap边界截断每一个byte，并覆盖空values、全部null和尾随数据；在ASan/UBSan下断言只返回protocol error且无越界。当前不新增packet样本。

### MYSQLC-002 — P2 — 无符号列与 OK 计数经 signed lua_Integer 返回为负值

- 状态：已确认；C integer conversion与Lua数值范围静态核对。不需要网络复现。
- 规范：MySQL binary protocol的`MYSQL_TYPE_LONGLONG`配合UNSIGNED flag表示完整64-bit unsigned范围；[MySQL OK_Packet](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_ok_packet.html)中的`affected_rows`和`last_insert_id`也都是length-encoded integer。client不能把`2^63..2^64-1`静默解释为负的signed值，无法原生表示时应返回decimal string/typed value或显式范围错误。
- 位置：`binary_read_uint64le`及lenenc在`luaclib-src/mysql/binary.h:107-124,160-195`；OK字段解码在`luaclib-src/mysql/lmysql.c:64-109`；unsigned LONGLONG dispatch在`:343-383`；现有边界测试在`test/testmysql.lua:9-49,128-365`。
- 触发：prepared SELECT返回值大于`9223372036854775807`的`BIGINT UNSIGNED`，包括常见id/bitmask/counter最大值；或OK packet的affected row count/auto-increment id通过0xfe lenenc表达相同区间。代理、批量操作或未来server扩展可以送达完整协议域，即使普通单表DML很少达到该数量。
- 影响：值发生模2^64符号wrap，例如`18446744073709551615`返回`-1`；应用可能进行错误的排序、权限bit判断、游标/主键续查和账务计算，写回时又作为signed LONGLONG发送，造成不可逆数据错误。OK字段变负还会绕过`affected_rows==0/1`等业务完整性判断，并把高位insert id作为负主键传播。
- 证据：reader构造`uint64_t`后以`lua_Integer`返回；parse_field在UNSIGNED分支直接`lua_pushinteger`，OK parser也用相同signed `binary_read_lenenc`结果直接push两个字段。64-bit Lua integer只有signed范围，代码没有range check或alternate representation。测试中的`0xFFFFFFFFFFFFFFFF`在Lua同样解释为`-1`，OK fixtures只使用3和5，未比较真实decimal语义。
- 根因：wire unsigned domain被强制映射到较窄的signed native domain，类型签名隐藏了不可表示区间。
- 建议解法：若值<=LUA_MAXINTEGER可返回integer；否则默认返回精确decimal string或`mysql.uint64` typed userdata/table，并在文档稳定约定。提供显式lossy-number opt-in也必须标注；parameter side增加相同typed value编码能力。
- 回归测试：修复阶段覆盖`2^63-1/2^63/2^64-1`及round-trip parameter，分别验证signed/unsigned column与OK affected_rows/last_insert_id；测试用decimal string/byte pattern建立期望，不能再用会wrap的Lua hex literal。

### MYSQLC-003 — P2 — temporal length 未严格验证，可伪造时间并使后续列错位

- 状态：已确认；codec switch静态核对。本阶段不生成非法temporal row。
- 规范：MySQL binary DATE/DATETIME/TIMESTAMP value只有0/4/7/11-byte forms，TIME只有0/8/12-byte forms；未知length必须作为protocol error，不能合成与wire无关的成功值，也不能跨未知边界继续解析同一row。
- 位置：`parse_timestamp`与`parse_time`在`luaclib-src/mysql/lmysql.c:259-341`；temporal dispatch在`:394-403`。
- 触发：date-family length不是0/4/7/11，或TIME length不是0/8/12，例如1、5、9、11、13或255；截断/反同步packet也可能使当前位置出现这些值。
- 影响：date-family向应用返回固定`2017-09-09 20:08:09`，可能被当作真实审计、过期、账务或调度时间；default不按声明边界推进，下一列错位。TIME对任何非零length固定先消费8bytes，只凭`len>8`再消费4bytes：1～7和9～11会越过当前value读取下一列，>12则留下尾部字节。整行可静默错配或迟发异常，连接错误状态也不会由C API自动标记。
- 证据：timestamp switch default直接push硬编码字符串并return；TIME不检查`len in {8,12}`，无条件读取sign/day/hour/minute/second，并以`len>8`代替`len==12`。两者都没有length-bounded subcursor、精确remaining检查或消费断言。
- 根因：开发期placeholder被留在production parser，length byte未被当作严格submessage boundary；TIME又把“含microseconds”简化成宽松大小比较。
- 建议解法：仅接受各field type允许的精确length，先验证remaining后以bounded subcursor读取并要求完整消费；任何其他length立即返回structured codec error并使上层connection fatal。另验证month/day/time/microsecond、TIME sign/day范围与zero-date策略。
- 回归测试：修复阶段枚举0..255 length；date-family合法0/4/7/11、TIME合法0/8/12检查边界值，其余必须失败且marker列不移位、不返回partial row/硬编码值；随后query必须使用新连接。当前不生成非法row。

### MYSQLC-004 — P2 — 未协商 SESSION_TRACK 时仍把 OK info 当 lenenc string

- 状态：已确认；capability flags与官方OK grammar静态核对。
- 规范：[MySQL OK_Packet](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_ok_packet.html)规定：协商`CLIENT_SESSION_TRACK`时info为`string<lenenc>`并可能跟session state；未协商时info是packet剩余的`string<EOF>`。
- 位置：client flags在`lualib/silly/store/mysql.lua:414-436`，没有SESSION_TRACK；OK parser在`luaclib-src/mysql/lmysql.c:64-109`；误导性unit fixture在`test/testmysql.lua:25-49`。
- 触发：MySQL/MariaDB在OK固定字段后返回非空human-readable info，而连接未协商CLIENT_SESSION_TRACK；常见DML可能包含rows matched/changed信息。
- 影响：info首个ASCII byte被解释为长度，通常因长度大于剩余packet而抛codec异常，也可能只返回错误长度的后缀并静默丢首字符。正常成功SQL因此被报告失败；结合`MYSQL-011`，异常后的connection还可能被错误归池。
- 证据：client capability没有`0x00800000 CLIENT_SESSION_TRACK`；parser只要有剩余就调用`binary_read_lenenc`再复制该长度。unit test人为在`hello`前加入`0x05`，验证的是SESSION_TRACK形态，却没有相应capability context参数。
- 根因：C API不接收negotiated capabilities，无法选择packet variant，测试把一种variant当成无条件格式。
- 建议解法：parser显式接收capabilities/status flags；未协商时复制全部remaining bytes，协商时严格解析info及可选session-state并完整消费。测试分别建立两种capability fixture，driver只解析自己实际宣告的格式。
- 回归测试：覆盖无SESSION_TRACK的空/ASCII/binary info，以及SESSION_TRACK的info、state-changed、截断state；与MySQL 8/MariaDB实际UPDATE互操作并断言message完整。

### MYSQLC-005 — P1 — luaL_Buffer 扩容后继续写旧 null/type pointer，prepared 参数编码损坏

- 状态：已确认；Lua auxiliary buffer pointer lifetime与encoder静态推导。本阶段不构造大参数execute。
- 位置：`add_params`在`luaclib-src/mysql/lmysql.c:473-519`；各append helper在`luaclib-src/mysql/lua_buffer_ex.h:10-91`；调用者`lcompose_stmt_execute`在`:521-545`。
- 触发：取得`null_map/types_buf` pointer后，第二次`luaL_prepbuffsize`或后续integer/string value append使`luaL_Buffer`扩容；一个足够大的早期string参数即可让后面的type/null entry写到旧buffer。
- 影响：后续参数的type bytes保持初始化的0（MYSQL_TYPE_DECIMAL）或NULL bitmap缺位，而value区域按真实Lua类型编码，server从此按错误grammar消费value并返回错误/断开；更糟时旧pointer已失效，C写入不再属于当前buffer，构成undefined behavior与潜在内存破坏。合法prepared call可触发，无需恶意server。
- 证据：函数先保存`null_map = luaL_prepbuffsize(...)`，随后再次prep保存`types_buf`；loop中一边通过`luaL_add*`追加可任意大的value（这些helper都会prep/可能搬移），一边在后续iteration直接写`types_buf[i*2]`和`null_map[...]`。Lua C API不保证buffer扩容后旧地址稳定。
- 根因：把可增长builder当作固定arena并跨可能扩容操作持有内部pointer；编码需要回填header却没有two-pass sizing/offset abstraction。
- 建议解法：two-pass扫描参数，先验证类型并overflow-safe计算完整payload size，再一次性reserve，之后以offset写且期间不调用可能扩容API；或把null/type arrays放独立稳定allocation/string后与values拼接。所有size乘加检查`SIZE_MAX/LUA_MAXINTEGER`。
- 回归测试：修复阶段让第1/中间参数跨LUAL_BUFFERSIZE，后续分别为每种type/null，覆盖多次扩容与大量参数；逐byte对照官方COM_STMT_EXECUTE decoder并在ASan/UBSan下运行。当前不生成大execute。

### MYSQLC-006 — P2 — row 只按 column alias 建表，重复列名被静默覆盖

- 状态：已确认；column metadata到row materialization静态核对。
- 位置：column parser只返回name/type/flags在`luaclib-src/mysql/lmysql.c:216-257`；row以name作key在`:430-470`；`compact_arrays`只声明未实现在`lualib/silly/store/mysql.lua:78-90,1138-1160`。
- 触发：`SELECT a.id, b.id ... JOIN ...`、两个expression使用相同alias或server返回重复column labels；任一列为NULL还会表现为key缺失。
- 影响：后解析列无提示覆盖前列，result无法恢复wire上的列数、顺序和第一个值；业务可能把另一张表的id/权限/金额当成目标列。即使调用者知道会重复，API也没有ordinal数组或完整metadata可用。
- 证据：`parse_column_def`读取但丢弃schema/table/original column，只保存column alias；`parse_row_data_binary`逐列执行`lua_settable`，相同string key覆盖。open opts注释有`compact_arrays`，pool object不保存它且全仓只有该一处引用。
- 根因：wire的ordered columns过早降维成name map，未定义duplicate/null保真策略；预留的array模式没有接线且unknown option不报错。
- 建议解法：默认返回ordered row values加完整columns metadata，或同时提供`row.values`和仅在unique时生成的name map；duplicate alias可映射value list/qualified keys但不能静默覆盖。真正实现并文档化`compact_arrays`，open时拒绝未支持opts。
- 回归测试：修复阶段覆盖两个/三个重复alias、跨table相同name、duplicate含NULL及显式alias唯一场景；断言column count/order/value全部可访问，并验证compact_arrays选项生效。

### MYSQLC-007 — P1 — 8-byte lenenc 经 signed/unchecked cursor arithmetic 可绕过边界并越界读

- 状态：已确认；native lenenc返回类型、size_t cursor运算与所有string消费者的静态算术核对。本轮不构造packet或运行sanitizer。
- 规范：MySQL length-encoded integer的`0xfe`分支携带unsigned 64-bit值；parser必须先验证该值可由本地size类型表示，再以`len <= remaining`的减法式检查约束每次cursor推进。不得先做`pos+len`或把unsigned长度塞入signed整数后继续指针运算。
- 位置：uint64/lenenc reader在`luaclib-src/mysql/binary.h:107-124,160-195`；unchecked column-definition cursor在`luaclib-src/mysql/lmysql.c:216-257`；addition-based checks在OK/ERR/string field路径`:64-109,156-214,343-427`。
- 触发：peer在OK info、ERR progress info、column definition任一lenenc string或binary row string字段声明高位64-bit长度（例如大于`LUA_MAXINTEGER`），或选择使`size_t pos + converted len`发生wrap的值；packet本身可很短。
- 影响：长度先变成负的`lua_Integer`，与`size_t`运算时再转为巨大unsigned并可能回绕；`if (len + pos > total)`因此不能保证范围。随后`lua_pushlstring(data+pos,len)`把负值转换为巨大`size_t`，或column parser在多次`pos += len`后从错误地址读取fixed fields，造成native越界读、进程崩溃、巨额allocation尝试或把相邻内存作为Lua string暴露。异常未必在安全检查处触发。
- 证据：`binary_read_uint64le`声明返回`lua_Integer`，直接return `uint64_t`组合值；`binary_read_lenenc`继续沿用该signed类型。三个consumer明确使用`len + chk.pos > chk.len`，而column parser六次`chk.pos += len`均未先检查remaining。底层fixed-width checks同样使用`chk.pos + N > chk.len`，一旦pos已wrap便不能恢复不变量。现有MYSQLC-002只记录合法UNSIGNED BIGINT应用值wrap，不覆盖长度驱动的pointer安全后果。
- 根因：协议中的unsigned length、Lua application integer和native memory size共用一个`lua_Integer`返回类型；cursor helper没有封装checked advance/slice，调用者各自使用易溢出的加法。
- 建议解法：lenenc decoder返回`uint64_t`加明确null/status；每个长度用途先检查`value <= SIZE_MAX`和本地配置上限，再用`value <= chk.len - chk.pos`，仅在成立后推进。提供`binary_read_slice`统一返回pointer/size并禁止调用者直接修改pos；fixed-width检查也改为subtraction形式。应用整数若超Lua范围用string/decimal或显式overflow error。
- 回归测试：修复阶段覆盖`2^63-1/2^63/2^64-1`、使pos刚好/差1/wrap的值，并逐一经过OK、ERR、column及各string field；ASan/UBSan下只能得到structured protocol error，无大allocation/OOB。当前不生成lenenc输入。

### MYSQLC-008 — P3 — capability 协商前 ERR 无条件吞掉 message 首字节，初始连接错误失真

- 状态：已确认；ERR packet能力变体与initial connection调用链静态核对。本轮不构造server初始ERR。
- 规范：[MySQL ERR_Packet](https://dev.mysql.com/doc/dev/mysql-server/8.4.9/page_protocol_basic_err_packet.html)规定只有协商`CLIENT_PROTOCOL_41`后才存在`#`和5-byte SQLSTATE，否则errno后全部剩余字节都是error message；[Connection Phase](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html)特别说明server在initial handshake之前返回ERR时尚未协商capability，因此该包不含SQLSTATE。
- 位置：native ERR parser在`luaclib-src/mysql/lmysql.c:156-214`；`_mysql_login`在解析任何HandshakeV10字段前把首包ERR直接交给它，见`lualib/silly/store/mysql.lua:341-353`；现有fixture只覆盖含`#HY000`的4.1形态，见`test/testmysql.lua:64-77`。
- 触发：server在发送HandshakeV10前以ERR拒绝连接，例如连接数耗尽、启动/关闭状态、host被阻止或proxy admission失败；payload为`0xff + errno + message`且没有SQLSTATE marker。最短的空message错误同样合法到达该分支。
- 影响：非空message的第一个byte被永久丢弃，例如`Too many connections`暴露为`oo many connections`，日志、告警分类与基于稳定错误文本的fallback会误判；空message则在探测marker时越界并抛Lua异常，叠加`MYSQL-011`使刚建立fd和pool capacity不能按返回值路径收尾。errno仍可用，因此定为诊断级P3。
- 证据：parser读取errno后无条件执行`binary_read_uint8(&chk)`，只有读到`#`才解析SQLSTATE；不等于`#`时既不回退`chk.pos`也不接收negotiated capability，随后从已推进一byte的位置复制remaining message。调用点在首包阶段无法假设PROTOCOL_41，而C API签名也没有variant参数。
- 根因：typed parser把4.1 ERR grammar当成可通过内容嗅探的通用格式，但`#`字段presence由连接状态决定；用破坏性读取做嗅探又没有rewind。
- 建议解法：让ERR parser显式接收已协商capabilities/phase；pre-handshake直接把errno后剩余内容作为message，post-handshake仅在PROTOCOL_41已协商时严格要求`#`和完整5-byte SQLSTATE。所有长度先检查，空message正常返回结构化ERR；不要用message首字符猜协议版本。
- 回归测试：修复阶段覆盖pre-handshake空/单字节/普通/以`#`开头message，以及post-handshake合法SQLSTATE、缺marker、截断state；断言message逐byte保真、malformed post-handshake连接fatal且任何分支不抛出public API。当前不发送ERR packet。

### MYSQL-001 — P1 — idle/lifetime/GC 销毁连接不递减 open_count，pool 可永久假满

- 状态：已确认；pool counter状态机静态推导。不需要并发复现。
- 位置：取连接时淘汰expired idle在`lualib/silly/store/mysql.lua:1018-1037`；max-open判断/等待在`:1038-1047`；周期清理在`:1082-1115`；leaked lease的GC在`:1235-1245`；只有普通物理close递减在`:1008-1013`。
- 触发：配置`max_open_conns > 0`并让idle连接因`max_lifetime/max_idle_time`被`conn_new/pool_clear`淘汰；或应用丢失一个未close的checked-out transaction conn，使`cmt.__gc`回收它；之后请求新连接。
- 影响：每个被这些路径关闭的fd仍在`open_count`保留幽灵连接。计数达到max后，新调用进入`task.wait()`，但不存在相应checked-out连接可归还并唤醒它；请求永久挂起。GC路径本意是回收leak，却只修复OS fd、不修复pool capacity，使一次应用lease遗漏永久毒化pool。
- 证据：`:1035`、`:1104`与`:1243`都调用`tcp_close`并置`conn.fd=nil`，均无`pool.open_count = ... - 1`；GC甚至已能通过`conn.pool`访问owner但没有更新。max-open只依据该计数。只有`conn_close`普通物理关闭路径递减，其他销毁未复用它。
- 根因：连接物理销毁散落在多个分支，计数更新不是统一的原子/invariant操作；pool没有assert `open_count == idle + checked_out + connecting`。
- 建议解法：集中`destroy_conn(pool, conn)`并幂等更新fd、open_count、statement state及waiter调度；所有过期、broken、login失败、pool close路径复用。更稳妥地显式跟踪idle/in-use/connecting集合，并在每次状态转换校验计数；销毁释放capacity后应立即唤醒/授权最早waiter创建连接。
- 回归测试：修复阶段用max_open=1/2覆盖checkout时过期、timer清理、idle/lifetime同时命中、未close lease GC及连续多轮；每轮断言真实fd数、open_count与队列一致，销毁后新query不会等待，并验证waiter按MYSQL-016获得permit。当前仅静态验证。

### MYSQL-002 — P1 — 不支持 TLS/server identity，full-auth 接受未认证 peer 提供的 RSA key

- 状态：已确认；MySQL握手与认证调用链静态核对。本阶段不搭建MITM。
- 规范：[MySQL 8.4 encrypted connection guide](https://dev.mysql.com/doc/refman/8.4/en/using-encrypted-connections.html)要求client可选择REQUIRED/VERIFY_CA/VERIFY_IDENTITY，并强调验证server identity以防MITM；[connection options](https://dev.mysql.com/doc/refman/8.4/en/connection-options.html)区分从server临时获取RSA key与使用client-side trusted public-key path。
- 位置：pool配置与TCP建立在`lualib/silly/store/mysql.lua:78-90,1018-1079,1138-1160`；client capability未设置`CLIENT_SSL`在`:414-466`；sha256/caching_sha2 public-key retrieval及password加密在`:482-760`。
- 触发：任意TCP MySQL连接均无加密/peer认证；当`sha256_password`或`caching_sha2_password`要求full authentication时，peer返回其选择的PEM key，driver无pin/CA验证即用它加密`password .. NUL`。
- 影响：网络旁路者可读取/修改SQL、参数、结果和事务控制；可伪装server、提供攻击者RSA key、解密client发回的password，然后转接真实server，造成数据库凭据泄露。driver也无法连接`require_secure_transport=ON`或`REQUIRE SSL/X509`部署，文档宣称的MySQL 8完全兼容不成立。
- 证据：`conn_new`只调用`tcp_connect`；虽然定义`CLIENT_SSL`，client flags从未包含它，也不发送SSLRequest。full-auth直接`pkey.new(pubkey_data)`，无trusted key comparison、证书链或hostname输入；opts没有tls/ssl-mode/CA/client-cert/public-key pin字段。
- 根因：把RSA password wrapping当作server authentication/transport security；连接API没有MySQL SSLRequest后原位升级TLS与验证策略的抽象。
- 建议解法：实现MySQL规范SSLRequest后、发送credential前的TLS upgrade，提供DISABLED/REQUIRED/VERIFY_CA/VERIFY_IDENTITY（安全默认至少REQUIRED，生产推荐VERIFY_IDENTITY）、trust store、SNI/hostname和mTLS配置；复用修复后的TLS验证能力。非TLS full-auth只在显式允许且server public key已预配置/pinned时发送密码，默认拒绝运行时未认证key retrieval。
- 回归测试：修复阶段与MySQL 8/MariaDB分别覆盖require_secure_transport、CA/hostname正确与错误、mTLS、TLS downgrade；用不同临时RSA key确认pin失败且client不发送可解密credential。当前不建立MITM。

### MYSQL-003 — P1 — connect/auth/query/pool wait 无 deadline，connect_timeout 选项被静默忽略

- 状态：已确认；配置读取与所有blocking路径静态核对。本阶段不运行slow MySQL peer。
- 位置：声明的open opts在`lualib/silly/store/mysql.lua:78-90`；packet read在`:303-332`；连接/认证在`:339-774,1018-1079`；pool capacity wait在`:1038-1047`；pool配置构造在`:1138-1160`。
- 触发：TCP connect长期不完成、server只发送partial handshake/auth/packet、查询永久执行，或max-open耗尽且checked-out连接永不归还；现有调用即使传`connect_timeout`也无效。
- 影响：调用task无限挂起；受限pool的waiter无界保留且无取消，慢查询占满连接后所有业务级联阻塞。pool close只能唤醒capacity waiters，无法中断正在connect、auth或query的checked-out连接，服务shutdown也可能无法收敛。
- 证据：`pool_open`不读取任何timeout字段，`conn_new`调用`tcp_connect(pool.addr)`不传opts，`read_packet`两次`tcp_read`均无timeout，`task.wait()`无timer。`test/testmysql.lua:489-502`传`connect_timeout=1`，但目标是本机拒绝端口，测试只接受immediate `connection refused`，未验证elapsed deadline或silent peer。
- 根因：driver没有absolute deadline/cancel模型，现有pool lifecycle参数只管理idle/lifetime，不管理单次operation；无效配置也未被schema校验拒绝。
- 建议解法：明确connect/auth/read/query/acquire timeout默认值，并允许per-operation absolute deadline/cancel；跨所有packet和multi-result使用同一剩余预算。超时后将connection标broken并物理关闭，唤醒capacity waiter；尚未取得连接的waiter可独立移除。open时拒绝unknown opts，避免安全配置静默失效。
- 回归测试：修复阶段分别停在connect、initial handshake、auth key、header/body、query、pool wait，验证elapsed上界、取消、close协同与capacity恢复；新增断言`connect_timeout`确实传到transport。当前不运行slow peer。

### MYSQL-004 — P1 — conn:close 后原对象仍可用且可重复归池，破坏 connection lease 隔离

- 状态：已确认；pool handoff与公开conn API静态推导。不依赖并发动态复现。
- 契约：`docs/src/reference/store/mysql.md:486-495`明确`conn:close()`归还连接后对象不可再使用；pool必须保证同一physical MySQL stream任一时刻只有一个有效borrower，release应幂等。
- 位置：公开connection methods/metatable在`lualib/silly/store/mysql.lua:1224-1246`；`conn_close`归还idle/waiter在`:985-1014`；`conn_new`直接返回同一对象在`:1018-1079`。
- 触发：事务连接调用`close()`后保留引用并再次`query/ping/commit/close`；或把带`<close>`的变量手动close，scope退出时`__close`再次执行。连接可能已被pool交给另一个等待者。
- 影响：旧borrower与新borrower可同时向同一fd发送prepared statement并竞争读取response，造成响应错配、事务/用户数据串线、协议反同步和连接崩溃；重复close可把同一conn对象多次加入idle数组或同时交给多个waiter，之后即使守规调用者也会并发复用。`open_count`还可能被重复物理关闭减成错误值。
- 证据：归池分支不修改`conn.fd`、不设置released/lease id，也不更换caller看到的对象；所有methods只使用`self.fd`，没有checkout校验。`conn_close`无幂等guard，第二次会再次执行rollback/handoff/idle append。
- 根因：pool内部physical connection对象同时充当可外泄的lease handle，release没有撤销caller capability；对象状态只表示protocol health，不表示ownership generation。
- 建议解法：分离internal connection与每次checkout的新lease wrapper；wrapper持generation并在每个method校验active，close原子置inactive且幂等，再把internal conn归池。若保留单对象设计，至少维护checked_out/token并确保旧引用无法与新owner共享，但新wrapper更清晰。handoff使用FIFO并为waiter生成新lease。
- 回归测试：修复阶段覆盖close后每个method、double close、manual close加`<close>`、归池后旧/新引用并发，以及两个idle槽重复同对象检查；断言旧handle只返回closed error、wire上始终单owner且open_count不变。当前仅静态核对。

### MYSQL-005 — P1 — COMMIT/ROLLBACK 失败仍把状态未知的事务连接归池

- 状态：已确认；transaction状态转换与pool release静态推导。本阶段不故障注入COMMIT/ROLLBACK。
- 位置：commit/rollback共同实现`conn_close_transaction`在`lualib/silly/store/mysql.lua:948-983`；自动rollback与归池判断在`:985-1014`；begin状态设置在`:1191-1221`。
- 触发：active transaction执行COMMIT或ROLLBACK后server返回ERR；或`conn:close()`自动rollback时收到ERR。网络read/write失败会标broken，但合法ERR packet不会。
- 影响：连接上的transaction状态仍可能active或unknown，本地却认为已结束并把它交给其他request。后续borrower的SQL可能运行在前一用户事务中，被未来commit/rollback意外包含，或观察未提交session state，造成跨请求数据隔离、原子性和权限边界破坏。
- 证据：函数在任何I/O之前执行`conn.is_autocommit = true`；收到ERR只`return nil, parse_err_packet(data)`，不恢复flag也不设`is_broken`。`conn_close`调用`conn_rollback(conn)`后丢弃结果，随后仅按当前true flag和`is_broken=false`进入waiter/idle归还。
- 根因：本地transaction状态记录“请求已尝试”而非server确认状态；pool把protocol同步与session cleanliness混为同一个`is_broken`布尔值，没有unknown/dirty状态。
- 建议解法：仅在成功OK且必要server-status确认后标记transaction ended；COMMIT/ROLLBACK任何ERR、codec异常或未知response都将连接标dirty并物理关闭，除非实现明确且成功的reset/change-user清理。自动rollback必须检查结果，绝不能把失败连接归池；公开错误仍返回给caller。
- 回归测试：修复阶段让COMMIT/ROLLBACK分别返回ERR、断线、malformed OK和超时，覆盖显式与auto rollback；断言连接不入idle/不交waiter、open_count释放，下一query使用新connection且看不到旧transaction。当前只作路径推导。

### MYSQL-006 — P2 — conn_new 不执行 closed 状态，pool 关闭后仍可新建连接并执行 SQL

- 状态：已确认；含确定性公开API路径及close/acquire interleaving静态推导。并发部分本阶段不强行复现。
- 契约：`docs/src/reference/store/mysql.md:106-113`声明pool关闭后不可再使用，所有等待连接的coroutine应被唤醒并收到错误。
- 位置：capacity wait与fallthrough在`lualib/silly/store/mysql.lua:1038-1079`；`pool_close`在`:1117-1136`；query只在进入`conn_new`前检查closed在`:1173-1189`；`pool_ping/pool_begin`在`:1163-1171,1191-1221`。
- 触发：确定性地在`pool:close()`后调用`pool:ping()`或`pool:begin()`；也可在max-open waiter、TCP connect或login期间由另一个task关闭pool。
- 影响：closed pool仍增加`open_count`、建立TCP和认证；`begin()`还发送BEGIN并返回可继续`query/commit`的connection。被close唤醒的waiter同样可执行原SQL，in-flight操作也继续。关闭动作不是barrier，shutdown后仍能访问数据库、创建凭据连接和产生副作用，且close调用者无法等待这些操作收敛。
- 证据：`pool_ping`和`pool_begin`不检查`self.is_closed`即调用`conn_new`，后者自身也从不检查。并发路径中`pool_close`对waiter执行无参数`task.wakeup(co)`；`if conn then return conn end`之后直接进入create分支。`tcp_connect/_mysql_login`后也没有closed复查；只有`pool_query`入口有一次检查。
- 根因：acquire结果以`nil`同时表示“被close取消”和“现在可自行建连”，缺少明确capacity permit/cancel状态；pool没有generation/in-flight registry与close barrier。
- 建议解法：waiter使用structured结果（lease/permit/error），close以ECLOSED完成全部pending acquire并从queue移除；connect/login各yield点和publish前复查pool generation，失效即关闭局部fd。pool跟踪connecting/checked-out operations，定义close是仅禁止新工作还是等待/取消全部工作，并在API文档明确。
- 回归测试：修复阶段先确定性覆盖close后的ping/begin及returned conn methods，再在capacity wait、TCP connect、initial handshake和auth各点并发close；断言全部返回closed、server未收到post-close command、无新fd/pool counter增加。并发部分当前仅说明时序。

### MYSQL-007 — P2 — packet fragmentation/sequence 未实现，≥0xffffff payload 会反同步

- 状态：已确认；官方packet framing与双向实现静态核对。本阶段不生成16MiB边界payload。
- 规范：[MySQL Packet protocol](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html)规定physical payload最大`2^24-1`，达到该长度即继续读取递增sequence的后续packet，逻辑payload为该序列拼接；精确整倍数以zero-length packet结束。每个新command从sequence 0开始并逐packet递增、可wrap。
- 位置：single-packet composer在`lualib/silly/store/mysql.lua:223-245,303-311`；reader在`:313-333`；prepared request发送在`:231-238,876-900`。
- 触发：SQL、prepared parameter、result row、auth/metadata等逻辑payload达到或超过`0xffffff`；或peer发送duplicate/skipped/out-of-order sequence id/合法zero terminator。
- 影响：inbound首个full-size chunk被当作完整row/packet解析，下一fragment被当作下一协议对象，导致数据截断、row错位、异常后连接可能继续复用；zero terminator被报`Empty packet`。outbound单个`I3`长度无法表示更大payload而抛错，不能与server的`max_allowed_packet`正常互操作。未校验sequence也失去检测packet丢失/插入和协议同步破坏的关键防线。
- 证据：`read_packet`只读一次4-byte header/body并立即return，`len==0`无条件失败；它把收到的byte直接赋给`conn.packet_no`而不与expected比较。`compose_packet`和global prepare cache均用一个`<I3B...>`header，不切片也不生成终结空包。
- 根因：实现把physical packet与logical protocol message等同，`packet_no`只用于生成下一auth包而非状态机不变量；max_packet_size只写进handshake，未驱动framing。
- 建议解法：统一`read_message/write_message`：逐physical packet校验expected sequence、累计budget并拼接，直到length `< 0xffffff`；整倍数接受/发送空终结包。每个command显式reset sequence，认证exchange按双向连续规则处理；超过本地/negotiated budget在分配前失败并关闭连接。
- 回归测试：修复阶段覆盖`0xfffffe/0xffffff/0x1000000/2*0xffffff`、空终结、sequence wrap/skip/duplicate，以及大SQL/BLOB/row双向互操作；当前不创建大payload。

### MYSQL-008 — P1 — client/server prepared statement cache 无界且从不 COM_STMT_CLOSE

- 状态：已确认；cache ownership与server resource静态核对。本阶段不生成高基数SQL。
- 规范：[MySQL DEALLOCATE PREPARE](https://dev.mysql.com/doc/refman/8.4/en/deallocate-prepare.html)说明未释放statement会触及全局`max_prepared_stmt_count`；[server variable](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_max_prepared_stmt_count)明确该限制用于防止大量prepare耗尽server内存。
- 位置：进程级`prepare_pkt_cache`在`lualib/silly/store/mysql.lua:223-238`；per-connection`stmt_cache`创建在`:1057-1073`；query按原始SQL永久缓存在`:876-889`；`COM_STMT_CLOSE`只定义在`:139`，无发送调用。
- 触发：应用把literal值、动态表/列名、注释或其他高基数字符串拼进SQL，持续调用`query`；多连接pool会在每条physical connection上各prepare一次。
- 影响：global cache永久保留每个SQL key及完整packet副本，所有connection cache又保留SQL key、metadata和statement id；server端每个session保留对应prepared object，累计可达到全局上限，使本应用及其他client无法再prepare。默认connection lifetime和cache size均无限，形成长期进程/数据库内存DoS。
- 证据：两张cache都是普通强引用table，无size/TTL/LRU；cache miss无条件COM_STMT_PREPARE并写`cache[sql]=stmt`。除断开整个TCP外没有COM_STMT_CLOSE发送，`COM_STMT_RESET`也未用于eviction。
- 根因：性能cache没有资源策略，把每个精确SQL字符串当作永久模板；global wire-packet memoization和server statement生命周期互相独立却都无界。
- 建议解法：默认限制每连接statement count/bytes并采用LRU；evict时发送COM_STMT_CLOSE（它无response）后移除metadata，连接关闭统一清cache。删除global full-packet strong cache或改为严格有界weak/LRU；提供metrics。文档要求值使用placeholder，但不能把安全完全交给caller。
- 回归测试：修复阶段在max cache N下执行N+k条不同SQL，验证client内存稳定、server Prepared_stmt_count回落、evicted SQL可重新prepare且statement id不误用；多连接与schema invalidation也覆盖。当前不生成高基数SQL。

### MYSQL-009 — P1 — max_packet_size 未执行且 result set 全量累计无总预算

- 状态：已确认；packet read与result materialization静态推导。本阶段不生成大result set。
- 规范：[MySQL Packet protocol](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html)允许单physical packet接近16MiB且逻辑message可跨多包；client声明/配置的接收上限必须在分配前执行，并为多packet/多row response设置累计预算或提供streaming。
- 位置：`max_packet_size`配置/handshake仅在`lualib/silly/store/mysql.lua:78-90,443-465,1138-1156`；`read_packet`在`:313-333`；column/result rows累计在`:776-846,913-945`。
- 触发：peer声明接近`0xffffff`的packet、返回大量column definitions/rows或持续用`SERVER_MORE_RESULTS_EXISTS`发送结果；合法大查询同样触发。
- 影响：每包进入TCP buffer和Lua string，所有decoded rows再完整保留至query结束；远端可用单query耗尽进程内存/CPU。`max_packet_size=1MiB`给调用者造成已有保护的错觉，但实际不会拒绝更大incoming packet，也没有max rows/columns/result bytes。
- 证据：header length解析后直接`tcp_read(fd, len)`，未与`pool.max_packet_size`比较；row loop对每包创建table并`rows[i]=...`直到EOF，没有limit/callback/iterator。column definition loop也不按advertised count或budget停止，只等待EOF。
- 根因：handshake capability值没有连接到实际parser resource policy，API只提供materialized result模式；socket backpressure无法限制driver主动持续读取并保留的完整结果。
- 建议解法：在任何body read前执行per-packet与logical-message上限，设置socket buffer limit；提供max columns/rows/decoded bytes和per-query覆盖，并优先增加streaming row iterator/callback以保持常量工作集。超限将连接标broken并关闭，因为剩余response无法安全复用。
- 回归测试：修复阶段覆盖packet limit-1/limit/limit+1、大量small rows、宽columns、multi-result累计与streaming早停；监测峰值内存并断言超限连接不归池。当前不生成大result。

### MYSQL-010 — P1 — SERVER_MORE_RESULTS_EXISTS 未按新 result 解析，剩余响应污染连接池

- 状态：已确认；multi-result官方状态机与query reader静态核对。本阶段不创建stored procedure。
- 规范：[MySQL stored-program protocol](https://dev.mysql.com/doc/dev/mysql-server/8.0.46/page_protocol_command_phase_sp.html)规定每个result set独立包含header/metadata/rows/terminator，terminator的`SERVER_MORE_RESULTS_EXISTS`表示下一完整result紧随；`CALL`还会有closing OK。client必须读取全部结果或丢弃连接后才能复用。
- 位置：capability flags在`lualib/silly/store/mysql.lua:152-167,414-436`；execute response与result loop在`:898-945`；OK/EOF parsers在`luaclib-src/mysql/lmysql.c:64-135`；名为multi-statement support的现有测试在`test/testmysql.lua:1026-1045`。
- 触发：prepared `CALL`、stored procedure/OUT parameter或其他server response产生多个result/closing OK；第一个response本身为带MORE flag的OK也可触发。
- 影响：首个OK路径立即return且不检查`server_status`，剩余packet留在socket；row EOF带MORE时则继续用旧`cols`把下一result的column-count/OK当binary row解析。异常路径未必标broken，to-be-closed lease会把反同步connection归池，下一无关query读取上一调用的packet，造成跨请求结果错配、数据泄露和业务误提交。
- 证据：`:910-912`只`parse_ok_packet`后return；EOF分支仅在MORE flag为0时break，为1时不重新进入“read result header/metadata”状态。返回类型也只能表达一个`ok_packet|row[]`，没有results collection/iterator。driver无条件宣告`CLIENT_MULTI_STATEMENTS|CLIENT_MULTI_RESULTS`，前者对其prepared user-query路径不可用，后者却允许server发送实现无法消费的stored-program multi results。Test 27的注释明确承认prepared statements不支持multi，然后只执行`SELECT 1 as first_result`，测试名和成功结果因此不能证明任一multi capability。
- 根因：把MORE理解为“当前rows继续”而不是“当前logical result结束、另一个result开始”；connection归池前没有统一的response-drained invariant。
- 建议解法：实现外层results loop，每轮解析OK/ERR或完整binary result，检查其终态status后决定继续；API返回result list/iterator，并提供显式drain。若暂不支持，不能宣告相关capability，且遇MORE必须完整discard或关闭连接。任何parser exception/未消费结果标broken。
- 回归测试：修复阶段先把当前伪multi测试重命名/删除；覆盖`CALL`返回0/1/2 result、OUT params、result+closing OK、首个OK+more、多statement（若公开支持）及中途ERR，逐项断言宣告capability与API能力一致；随后立即在同一pool发marker query，结果不串线。当前不创建procedure。

### MYSQL-011 — P1 — codec/unpack 异常绕过 broken cleanup，login 泄漏容量、query 归池坏连接

- 状态：已确认；Lua exception unwinding与connection lifecycle静态推导。本阶段不发送畸形handshake/result。
- 位置：`read_packet/_mysql_login`与大量`strunpack`在`lualib/silly/store/mysql.lua:313-774`；C codec调用在`:776-945`；`conn_close`归池条件在`:985-1014`；`conn_new` login在`:1048-1079`；pool query的`<close>`在`:1173-1189`。
- 触发：peer发送截断handshake/auth/prepare metadata、非法lenenc/column/binary row或任何令C codec/`string.unpack`抛Lua error的packet，而不是底层read返回nil。
- 影响：login阶段异常从`_mysql_login`直接穿出，`conn_new`已增加open_count且创建fd，但不会执行`conn_close`；最终`__gc`至多关闭fd、不递减open_count，受限pool可永久假满。query阶段异常触发lease的`__close`，但codec没有设置`conn.is_broken`，所以反同步socket被交给waiter/idle，下一请求读取残余旧response，造成结果串线和重复异常。
- 证据：parser APIs以`luaL_error/error`报告bounds/format问题，调用点无`pcall/xpcall`或finally标broken。只有`read_packet` I/O nil和write failure显式设置broken；`cmt.__gc`只close fd，不更新pool counter。`conn_close`默认把`is_broken=false`连接复用。
- 根因：error model混用return-value与exception，但资源/health transition只覆盖前者；缺少“开始解析peer response后，任意非成功退出都fatal”的统一guard。
- 建议解法：在connect/login/query最外层使用protected cleanup guard：创建后立即登记connecting资源，任意异常原子标broken、物理关闭、递减capacity并转换成structured ERR；只有完整消费且验证终态后commit健康状态。C codec可改为`nil,error`，但仍需finally防守应用/runtime异常。
- 回归测试：修复阶段在每个handshake/prepare/column/row字段边界截断并触发各codec error，断言无异常越出public API、fd/open_count恢复、连接不入idle，后续query新建干净连接。当前不生成畸形packet。

### MYSQL-012 — P2 — handshake/auth-switch 错误裁剪认证数据并越过 capability 交集

- 状态：已确认；HandshakeV10 layout与parser静态核对。
- 规范：[MySQL HandshakeV10](https://dev.mysql.com/doc/dev/mysql-server/8.0.46/page_protocol_connection_phase_packets_protocol_handshake_v10.html)按`auth_plugin_data_len`定义part-2长度；[MariaDB connection protocol](https://mariadb.com/docs/server/reference/clientserver-protocol/1-connecting/connection)明确part 2由`CLIENT_SECURE_CONNECTION`控制，而`PLUGIN_AUTH_LENENC_CLIENT_DATA`控制client response的auth长度编码；[MySQL AuthSwitchRequest](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_auth_switch_request.html)把plugin data定义成`string[EOF]`，不是无条件NUL结尾字符串。
- 位置：capability constants在`lualib/silly/store/mysql.lua:152-167`；initial handshake解析在`:359-403`；client response flag/format在`:414-465`；auth-switch extraction在`:482-505`。
- 触发：server支持SECURE_CONNECTION/PLUGIN_AUTH但不支持PLUGIN_AUTH_LENENC_CLIENT_DATA，auth plugin data长度不是代码假定的20-byte seed/12-byte part 2，或AuthSwitchRequest携带不以NUL结尾的合法20-byte opaque nonce；合法旧版、代理或其他auth plugin均可出现。server不提供代码无条件声明的某个base capability时也会产生不一致response grammar。
- 影响：driver遗漏part 2而用8-byte seed计算native/caching token，或从seed中间解析plugin name，导致合法server认证失败；固定offset还可能把NUL/plugin name切错并触发unpack异常。AuthSwitch路径无条件删除payload最后一byte，使20-byte nonce变19-byte并确定性生成错误token。对未知plugin代码又默认计算mysql_native token却宣告原plugin，进一步制造不一致握手；不取server capability交集会让双方按不同字段presence解释response。
- 证据：`:373`以`CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA`决定是否读取server seed part 2；内部`local len=12`完全忽略已解析的`auth_plugin_data_len`和SECURE_CONNECTION。AuthSwitch随后固定`sub(data,pos,#data-1)`，没有检查最后一byte是否真为NUL，直接违反其EOF边界。client flags只有PLUGIN_AUTH/LENENC两项按server条件加入，其余LONG/CONNECT_WITH_DB/PROTOCOL_41/TRANSACTIONS/SECURE/MULTI项无条件声明，并非双方intersection。若initial plugin不在两个已知值内，`:409-412`还生成native token但在response中发送原plugin名。
- 根因：把server handshake字段presence、client response encoding、可选NUL和具体plugin seed长度合并成一个MySQL-8特例；capability也按本地愿望拼装而未形成唯一negotiated state。
- 建议解法：按negotiated capability逐字段、remaining length和advertised auth length解析HandshakeV10；part 2长度使用规范公式，只在plugin规则明确要求且最后一byte确为NUL时移除terminator，再把完整EOF payload交给plugin handler。client flags取双方intersection，未知plugin明确拒绝或走实现的auth-switch机制。
- 回归测试：修复阶段构造SECURE/PLUGIN_AUTH/LENENC三flag组合及auth length 0/9/20/21/其他plugin；AuthSwitch覆盖19/20/21-byte data、末尾为零/非零和embedded NUL，断言nonce逐byte保真；分别与MySQL 5.7/8和MariaDB/proxy互操作。当前不新增handshake fixture。

### MYSQL-013 — P2 — `COM_PING` 响应无条件按 OK 解码，server ERR 可被伪造成健康

- 状态：已确认；COM_PING响应分支、native OK/ERR decoder与公开health-check契约的确定性静态核对。本轮不发送PING或构造server错误。
- 规范：MySQL command response必须先按payload首字节区分OK(`0x00`)、ERR(`0xff`)及命令允许的其他类型；COM_PING通常返回OK，但server拒绝、shutdown/权限/状态错误仍必须作为ERR传播，不能用另一packet grammar解码。连接健康检查尤其不能把server error报告为成功。
- 位置：`conn_ping`在`lualib/silly/store/mysql.lua:849-870`，pool wrapper在`:1163-1171`；native OK/ERR parser分别在`luaclib-src/mysql/lmysql.c:64-109,156-210`；中英文ping返回契约见`docs/src/reference/store/mysql.md:136-169`与英文同名文档。
- 触发：已建立连接对COM_PING返回任意合法ERR packet，例如server处于拒绝命令状态；恶意/代理peer也可控制errno、SQLSTATE和message bytes。
- 影响：长度与字节恰好可供OK parser消费时，driver返回伪造的`type="OK"` table和nil error，pool健康检查把明确失败的server判为可用并继续归池；其他ERR内容会被误读的lenenc info触发native exception，落入MYSQL-011的异常清理缺口。监控、startup readiness与连接选择均可得到错误结论。
- 证据：write/read成功后`conn_ping`直接`return parse_ok_packet(data),nil`，没有读取`strbyte(data)`。C OK decoder仅跳过第一个byte，随后依次把后续数据当两个lenenc整数、status和warning，并硬编码结果`type="OK"`；它从不验证被跳过的byte。ERR decoder虽已存在，query/login分支也会先判ERR，但ping没有复用。
- 根因：实现把“COM_PING成功时响应为OK”错误简化为“COM_PING任何response都是OK”，parser API本身又不自证packet类型，使调用点遗漏可静默变成另一种合法对象。
- 建议解法：建立统一command-response dispatcher，首字节为ERR时调用`parse_err_packet`并返回nil,error，只有OK才调用OK parser，其他type作为protocol error并标broken。native各typed parser也应验证discriminator，形成第二道防线；health check只有完整合法OK才算成功。
- 回归测试：修复阶段覆盖正常OK、多个合法ERR长度/errno/SQLSTATE、截断ERR及未知首字节；断言ERR永不返回OK、协议异常连接不归池、普通server ERR若响应完整可按明确策略决定是否保持同步。当前不发PING。

### MYSQL-014 — P2 — transaction control 把任意非 ERR packet 当作成功响应

- 状态：已确认；BEGIN/COMMIT/ROLLBACK response discriminator与本地transaction/pool状态的确定性静态核对。本轮不发送transaction命令或构造packet。
- 规范：COM_QUERY `BEGIN/COMMIT/ROLLBACK` 的命令终局必须按首字节明确区分OK和ERR；任何EOF、LOCAL_INFILE、resultset header或未知类型都不能证明事务状态已转换，必须作为protocol error并丢弃/重置连接。typed packet decoder不能替代上层discriminator。
- 位置：BEGIN response在`lualib/silly/store/mysql.lua:1191-1221`；COMMIT/ROLLBACK共用实现在`:948-983`；OK/ERR/EOF/LOCAL constants在`:145-150`，native OK parser不验证首字节见`luaclib-src/mysql/lmysql.c:64-109`。
- 触发：server/proxy在事务控制命令后返回首字节不是OK也不是ERR的packet；也可由先前response未排空/连接反同步导致当前read取得上一命令的metadata、row或terminator。
- 影响：BEGIN路径直接把连接标为in-transaction并返回给应用，packet若代表resultset还会留下后续metadata/rows，使第一条query读取旧response。COMMIT/ROLLBACK路径已提前把本地状态标为ended，再把任意非ERR送进宽松OK decoder，可能构造假OK或抛异常。连接可带未知事务状态/残余响应归池，造成跨请求结果和transaction串线。
- 证据：`pool_begin`只写`if first==ERR`，否则不要求`first==OK`、不调用`parse_ok_packet`，直接`conn.is_autocommit=false; return conn`。close-transaction函数同样只特判ERR，所有其他类型均`return parse_ok_packet(data),nil`；C decoder跳过而不校验discriminator。MYSQL-005已覆盖合法ERR前过早改flag，本项覆盖非ERR/非OK类型被错误接受的另一条路径。
- 根因：command handlers以“不是已知错误”代替“收到并完整验证唯一成功终态”，而typed native decoder缺少自校验，使协议状态提交不是fail-closed。
- 建议解法：共享严格dispatcher：只有首字节OK且OK packet完整、capability一致时才提交本地transaction transition；ERR返回结构化错误；其他类型一律protocol-fatal、标broken并物理关闭。状态更新必须发生在validator成功后，自动rollback仍需检查结果。
- 回归测试：修复阶段对BEGIN/COMMIT/ROLLBACK分别覆盖OK、ERR、EOF、LOCAL_INFILE、resultset header、未知byte、截断/尾随OK；只有合法OK改变本地状态，其余连接均不归池。当前不发送控制命令。

### MYSQL-015 — P1 — prepare/result phase 不验证 packet 类型与声明计数，错误可变成列或业务数据

- 状态：已确认；prepared-result packet phase、Lua discriminator与native row header处理的确定性静态核对。本轮不构造result/ERR packet。
- 规范：MySQL command/resultset各阶段允许的packet类型必须按phase和首字节分派；ERR(`0xff`)表示当前command失败并终止结果，不能进入ColumnDefinition或Binary Protocol Resultset Row decoder。binary row还必须验证首字节header为`0x00`，而不是盲目跳过任意byte。
- 位置：column-definition循环在`lualib/silly/store/mysql.lua:776-797`，prepare response/声明的param与field count在`:799-846`，execute首响应与row循环在`:898-945`；native binary row入口在`luaclib-src/mysql/lmysql.c:430-470`，column decoder在`:216-257`。
- 触发：server/proxy在prepare首响应、parameter/column metadata或row phase返回ERR/其他类型；metadata terminator过早、过晚或缺失，使实际definition数量不等于COM_STMT_PREPARE_OK/result header声明；或连接已因MYSQL-010等未排空response而读到上一command的packet。恶意peer也可构造以0xff开头、后续字节恰能满足当前decoder的payload。
- 影响：prepare的任意非OK首包被强制按ERR解析；metadata ERR/row/result header会被送进column parser并通常抛异常，触发MYSQL-011的坏连接清理问题。过多definition可一直写入数组并把后续phase吸走，过少definition仍被接受，使execute按错误column layout解析。row-phase ERR则被当binary row，decoder跳过0xff后把errno/SQLSTATE/message字节解释成NULL bitmap和字段，可能向应用返回伪造业务row；若之后遇EOF，query甚至报告成功并把connection归池，否则残余packet造成跨请求串线。
- 证据：`prepare`只做`if typ~=OK then parse_err_packet(data)`，不要求typ确为ERR。`recv_col_def_packet(conn,array)`没有接收expected count：只有`first==EOF`才break，其余一律append `parse_column_def`；调用者虽已解出`param_count/field_count`，却完全不用于控制或核对数组长度。execute result同样解析了`field_count`但只用`>0`决定是否进入无界metadata loop。row loop只有EOF分支，其余一律`parse_row_data_binary`；C row decoder在`:439-444`仅跳过首byte，从不检查其为0x00。
- 根因：result consumer把“非terminator”视作目标数据packet，没有为每个phase声明完整allowlist；native typed decoders也不验证discriminator，无法防守调用层遗漏。
- 建议解法：实现显式prepare/result state machine：每个read先统一识别ERR并终止；按声明的param/field count精确读取definition，随后只接受规定terminator；row phase只接受0x00 binary row及合法terminator/ERR。数量不符或未知type标protocol-fatal并关闭。所有native typed parser验证header/type，完整response验证后才允许lease归池。
- 回归测试：修复阶段在prepare首包、每个param/column位置、metadata terminator前后、首/中/末row注入合法ERR及未知type，并覆盖声明count的少1/相等/多1、零列和terminator缺失；断言ERR结构化返回、绝不生成row、连接按同步状态关闭/不归池，随后marker query不串线。当前不注入packet。

### MYSQL-016 — P1 — broken connection 释放 capacity 后不唤醒 waiter，受限 pool 可永久停住

- 状态：已确认；max-open acquire queue、broken return与capacity accounting的确定性静态时序。本轮不注入I/O失败或运行并发barrier。
- 位置：capacity wait在`lualib/silly/store/mysql.lua:1016-1055`；healthy handoff与broken physical close在`:985-1014`；query lease自动归还在`:1173-1189`。
- 触发时序：配置`max_open_conns=1`；task A取得唯一connection执行query，task B进入`waiting_for_conn`并`task.wait()`；A发生read/write failure使`conn.is_broken=true`，scope收尾调用`conn_close(A)`。
- 影响：broken fd和`open_count`被正确释放到0，但B永远没有被唤醒去创建替代connection；若没有第三个新请求，B永久挂起。即使第三个请求C后来看到count=0并成功建连，B也要等C归还后才可能取得connection，形成违反队列顺序的饥饿和无谓延迟。单次连接故障可令已有业务请求停滞。
- 证据：`conn_close`只有在`not pool.is_closed and not conn.is_broken`的healthy分支才检查`waiting_for_conn`并wake一个coroutine；broken/closed分支直接`open_count=open_count-1`、关闭fd后return，没有把“可创建一个新连接”的permit交给waiter。`conn_new` waiter没有timer或其他自唤醒机制，pool_clear也只处理idle数组。
- 根因：wait queue只支持把现成healthy connection直接handoff，不支持capacity释放事件；计数递减、fd销毁和waiter调度没有由统一pool state transition维护。
- 建议解法：任何物理销毁导致`open_count`下降后，若pool仍开放且有waiter，应以structured capacity permit唤醒最早waiter，让其在generation/closed复查后创建connection；或由pool内单一acquire scheduler统一决定handoff/新建。使用FIFO、可取消waiter，并避免多次释放同一permit造成超max。
- 回归测试：修复阶段以max_open=1/2覆盖唯一checked-out连接在write/read/login/expiry时销毁且已有1/N waiters；断言最早waiter立即获得create permit、open_count不超限、其余队列可继续推进，并覆盖pool close竞态。当前仅记录时序。

### MYSQL-017 — P1 — transaction conn 无并发命令门禁，可写入多条命令后响应错配

- 状态：已确认；MySQL command串行语义、transaction公开方法与TCP single-reader断言的确定性静态推导。本轮不运行并发barrier或数据库请求。
- 规范：经典MySQL protocol在一个connection上按command/response顺序工作；上一command的完整response结束前不能发送下一command，除非协议显式定义对应pipeline。driver若把connection对象暴露给多个协程，必须串行化command、绑定响应owner，或在第二个调用写wire前fail fast。
- 位置：transaction conn公开`query/ping/commit/rollback`在`lualib/silly/store/mysql.lua:849-983,1224-1246`；各方法均直接write后read且没有busy状态/锁；底层TCP唯一reader槽及`assert(not s.co)`在`lualib/silly/net/tcp.lua:258-300`。pool级query通过独占checkout避免共享，但`pool:begin()`把同一physical conn直接交给应用在`mysql.lua:1191-1221`。
- 触发：协程A对同一个transaction conn调用`query()`并在等待prepare/execute response时yield；协程B在A完成前调用`query()`、`ping()`、`commit()`或`rollback()`。并行处理事务内多个子任务、timeout cleanup与业务query交错都可自然形成该时序。
- 影响：B会在A尚有outstanding response时把另一条command写入同一socket，破坏MySQL严格command边界；随后B的首次`tcp_read`因A已占唯一reader槽触发Lua assert并终止B。server仍可能依次执行两条命令并发送两份response，A只消费自己的终局，B的response残留；下一次conn调用会把该旧response当作新command结果，造成事务内响应/数据错配、错误commit判断、未预期副作用及最终归池污染。
- 证据：所有conn methods在第一次可能yield之前先调用`tcp_write`，没有检查`busy/current_command`。A进入`read_packet→tcp_read→task.wait`后`s.co`非nil；B的write不yield且成功排队，随后同样进入read，命中`assert(not s.co)`。异常边界没有撤回已发送command或drain其response，也不会自动把transaction conn标broken；caller仍持有同一对象，后续操作可继续读取B遗留packet。
- 根因：pool checkout只建立“连接不被其他borrower使用”的外层隔离，却没有定义单个lease内部的协程并发契约；写入与response-reader ownership不是一个原子operation，底层single-reader断言发生得太晚。
- 建议解法：为每个physical conn建立command mutex/queue，在任何packet write前取得且持有到完整logical response消费或fatal cleanup；transaction control与ping共用同一门禁。若产品选择single-coroutine lease，所有methods也必须在写wire前以owner/busy token稳定返回错误，文档明确限制。异常/cancel后无法证明response已drain时必须标broken并物理关闭，不能让下一调用猜测边界。
- 回归测试：修复阶段以channel/barrier覆盖`query+query`、`query+ping`、`query+commit/rollback`和close/cancel相邻时序；断言第二操作要么排队后取得准确response，要么在零字节写出前失败，绝不触发TCP assert或残留packet。随后marker query验证连接同步与事务结果，当前不运行并发复现。

### MYSQL-018 — P2 — pool waiter 使用 LIFO handoff，持续负载下旧请求可无限饥饿

- 状态：已确认；Lua array栈语义、capacity wait与healthy connection handoff的确定性调度推导。本轮不运行连接池并发压力。
- 位置：waiter按到达顺序append在`lualib/silly/store/mysql.lua:1038-1047`；healthy connection归还时以无index的`table.remove`取队尾在`:991-1000`；pool wait没有timeout/cancel见`:1039-1044`及`MYSQL-003`。
- 触发：设置较小`max_open_conns`且全部connection被占用；旧请求A先进入`waiting_for_conn`，之后B进入。connection归还时B先获得它；B执行期间若C进入，下一次又由C先获得。只要每轮归还前都有至少一个更新请求到达，A可始终留在队首。
- 影响：连接池吞吐和新请求看似正常，最早等待的业务却没有等待上界，可永久挂起并持有task、调用参数与上游请求资源。热点持续时形成反公平tail latency，事务/锁操作可能超过业务deadline；因为API本身又没有acquire timeout，饥饿不会自动收敛或产生错误。
- 证据：Lua `table.remove(t)`省略位置时删除并返回最后一个元素，而enqueue固定写`waiting_for_conn[#waiting_for_conn+1]=co`，因此该容器是stack而不是注释/修复建议期望的queue。每次handoff只pop一个最新waiter；旧元素不会因新arrival或正常归还获得优先级，也没有aging、deadline或独立scheduler。
- 根因：用普通array同时充当wait list却未明确FIFO不变量；直接把physical conn wake给某个coroutine，使公平性、取消、pool close和capacity permit无法由单一acquire scheduler管理。
- 建议解法：改用真正FIFO queue并为每个waiter保存token/generation/deadline；归还connection或释放capacity时总是完成最早仍有效waiter，跳过已取消项。handoff后由waiter生成新lease，和`MYSQL-004/016`的ownership与capacity修复统一，避免在array头部`remove(1)`造成O(n)退化。
- 回归测试：修复阶段用max-open=1建立A/B/C确定性排队并连续插入新请求，记录acquire顺序严格FIFO；再覆盖中间waiter取消、pool close、broken/expired connection释放permit及多connection同时归还。断言旧请求有界推进、无重复/丢失connection且open_count不超限。本轮不运行压力或barrier。

### MYSQL-019 — P2 — checkout 用 `returned_at` 执行 lifetime 判断，繁忙连接可永不轮换

- 状态：已确认；pool时间字段、checkout淘汰条件与周期idle清理的确定性静态核对。本轮不等待真实lifetime或建立数据库连接。
- 契约：公开`max_lifetime`表示连接从创建起允许存在的最大秒数；它与`max_idle_time`语义不同。无论连接最近何时归还，只要`now-created_at`达到上限，就不能再被新borrower复用。
- 位置：`created_at/returned_at`字段在`lualib/silly/store/mysql.lua:45-60`；checkout计算与错误比较在`:1018-1037`；归还每次刷新`returned_at`在`:1001-1006`；周期清理的正确`created_at`对照在`:1082-1115`；公开配置说明在`docs/src/reference/store/mysql.md:61-72`及英文同名文档。
- 触发：设置非零`max_lifetime`；一个physical connection已存活超过该值，但刚被前一请求归还，下一请求在周期`pool_clear`扫描前取得它。持续负载下connection反复短暂归还/立即checkout，`returned_at`每轮刷新。
- 影响：超过部署轮换上限的connection可持续被复用，甚至在稳定负载下永不进入idle scan的淘汰窗口。credential/权限变更、server failover、网络设备会话上限和长期连接状态清理无法按配置收敛；运营方以为max_lifetime已限制陈旧session，实际行为更接近max idle age。最终若被timer关闭还会触发`MYSQL-001`的capacity计数泄漏。
- 证据：`conn_new`计算`lifetime_since=now-max_lifetime`，但接受条件写成`conn.returned_at > lifetime_since`；正确字段`conn.created_at`未参与checkout判断。`conn_close`在每次健康归还时把`returned_at`重置为当前秒，因此古老connection只要最近使用过就通过。后台timer虽以`created_at`判断，却只遍历当时仍位于`conns_idle`的对象，不能撤销已经checkout的lease。
- 根因：lifetime与idle age两种时间域在快速acquire路径中混用，并依赖周期best-effort清理代替checkout时的硬性配置不变量。
- 建议解法：checkout分别计算`idle_expired=returned_at<=idle_since`与`lifetime_expired=created_at<=created_since`，任一命中都通过统一destroy/capacity路径淘汰；归还时也可标记超过lifetime、直接销毁而非入池。时间边界统一定义等号语义并使用同一monotonic单位，和`MYSQL-001/016`一起保证计数及waiter唤醒。
- 回归测试：修复阶段用fake monotonic clock覆盖lifetime前1秒、恰好边界、超过边界，分别让连接长时间checked-out、刚归还立即checkout及等待timer；断言均按created_at轮换而max_idle仍按returned_at，open_count/waiter保持一致。本轮不运行计时测试。

### MYSQL-020 — P2 — 初始 `sha256_password` 握手错误发送 native SHA-1 token，合法账号无法认证

- 状态：已确认；认证plugin分派与MySQL官方client/server认证流程静态核对。本轮不创建`sha256_password`账号或建立连接。
- 规范：[MySQL Connection Phase](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html)要求initial handshake中client选择与声明plugin兼容的认证response；[MySQL `sha256_password`](https://dev.mysql.com/doc/refman/8.4/en/sha256-pluggable-authentication.html)规定非TLS连接必须使用RSA password exchange，[MySQL Router的协议实现](https://dev.mysql.com/doc/dev/mysql-server/9.4.0/classAuthSha256Password.html)明确其public-key request为单byte `0x01`。不能在声明`sha256_password`时发送`mysql_native_password`的SHA-1 challenge token。
- 位置：initial plugin选择与token构造在`lualib/silly/store/mysql.lua:390-465`；只有AuthSwitchRequest分支实现`sha256_password` public-key request/RSA exchange在`:482-604`；测试只覆盖`caching_sha2_password`，见`test/testmysql.lua:900-966`。
- 触发：server initial HandshakeV10把`sha256_password`作为optimistic auth plugin，目标账号也使用该plugin，且password非空；常见于把server默认authentication plugin配置为sha256，因双方plugin已匹配，server无需再发送AuthSwitchRequest。
- 影响：driver在HandshakeResponse中仍宣告plugin name为`sha256_password`，auth response却是20-byte native SHA-1 token。server把该payload交给sha256 plugin后拒绝认证或终止exchange；代码中已经存在的RSA实现完全不可达。双语reference所称MySQL 5.x/8.x完全兼容因此对这一合法MySQL配置不成立，部署迁移或账号策略切换会造成连接全面失败。
- 证据：token分派只有`if auth_plugin_name == "caching_sha2_password" then compute_token_sha256(...) else compute_token(...) end`；`compute_token`明确实现native的`SHA1(password) XOR SHA1(scramble || SHA1(SHA1(password)))`。随后packet尾部写入原始`auth_plugin_name`，造成payload algorithm与plugin标识矛盾。`sha256_password`专用`\x01`请求、public-key读取和OAEP加密只位于收到`0xfe` auth switch之后；初始plugin已经匹配时不会靠该分支纠正。
- 根因：认证实现以“caching SHA-2或其他”二分，未知/sha256均静默回落native；plugin handler只在switch路径完整分派，initial fast path没有复用同一状态机。
- 建议解法：按plugin name统一选择显式handler，initial和auth-switch共享；`mysql_native_password`生成native token，`caching_sha2_password`走其fast/full流程，非TLS `sha256_password`发送public-key request并完成RSA exchange，未知plugin在发送不匹配payload前明确失败。结合`MYSQL-002`提供TLS与可信server-public-key配置，不能继续默认信任线上取得的key。
- 回归测试：修复阶段分别让server initial plugin和账号plugin为native/caching/sha256，覆盖plugin匹配与auth switch、空/非空password、TLS/固定key/在线取key；断言sha256首个client payload为规范请求或加密值而非20-byte native token，未知plugin零凭据payload后失败。当前不进行认证交互。

### ETCD-001 — P1 — mutation RPC 在结果未知的失败后盲重试，可重复提交写操作

- 状态：已确认；etcd API语义、gRPC模糊失败边界与确定性retry loop静态推导。本阶段不注入“server已提交、response丢失”的网络故障。
- 规范/权威依据：[etcd v3 API](https://etcd.io/docs/v3.6/learning/api/)说明Put会创建新的store revision，LeaseGrant在ID为0时由server选择ID，Revoke会删除绑定key；这类mutation的response丢失并不证明请求未执行，client不能把任意错误都视作安全重放信号。
- 位置：无条件retry loops在`lualib/silly/store/etcd.lua:379-512`，覆盖Put、DeleteRange、Compact、LeaseGrant和LeaseRevoke；配置说明在`docs/src/reference/store/etcd.md:53-63`。
- 触发：server完成mutation并提交Raft revision后，response在返回client前因连接断开、RST/GOAWAY、client-side parse failure或deadline边界而丢失；任一调用只要得到nil便立即重发相同RPC，且不检查gRPC status、请求类型或是否已经到达server。
- 影响：Put可产生额外revision/version和重复watch事件；Delete第二次返回0并丢失第一次的deleted/prev_kvs语义；ID=0的LeaseGrant可创建多个不同lease却只向调用方暴露最后一个，形成孤儿lease及其资源；其他mutation也会把“结果未知”伪装成单次成功/最终失败。调用方无法知道实际提交次数，破坏etcd用于协调和状态机的线性化业务语义。
- 证据：五个method都以`for i=1,self.retry`调用RPC，唯一成功判据是`res`非nil，任何`err`内容均不分类；失败后甚至在最后一次attempt之后仍sleep。请求没有idempotency token、Txn compare guard或固定Lease ID补偿，driver也不返回ambiguous-commit标记。
- 根因：把“重新建立可用transport”与“重放一个可能已执行的application operation”合并成通用retry模板，没有定义per-method retry safety和gRPC failure stage。
- 建议解法：默认只自动重试可证明未送达的调用以及安全read；mutation遇到可能已送达的transport failure应返回结构化`outcome_unknown`。需要自动恢复时由调用方使用Txn compare/version guard、稳定Lease ID或业务idempotency key，并仅对明确retryable status按deadline/backoff重试；移除最后一次失败后的sleep并验证retry>=1。
- 回归测试：修复阶段在Put/Delete/Compact/Grant/Revoke的“发送前、server apply前、apply后response前”三个边界断链，记录revision/watch/lease数量；只有未送达请求可透明重试，模糊提交返回可判定错误，guarded mutation最多生效一次。本轮不做故障注入。

### ETCD-002 — P1 — watch 的公开 `revision` 参数未编码，历史事件回放被静默忽略

- 状态：已确认；公开文档、protobuf descriptor与encoder dataflow静态核对。不需要运行watch历史回放。
- 规范/权威依据：[etcd v3 API](https://etcd.io/docs/v3.6/learning/api/)定义WatchCreateRequest字段为`start_revision`且从该revision（inclusive）开始；未提供时表示从watch创建后的事件开始。Silly文档则明确承诺`revision`可用于历史事件回放。
- 位置：公开参数和构造在`lualib/silly/store/etcd.lua:557-600`；协议字段在`lualib/silly/store/etcd/v3/proto.lua:2316-2335`；protobuf table encoder在`luaclib-src/pb.c:1737-1756`；用户文档在`docs/src/reference/store/etcd.md:583-596`。
- 触发：调用`client:watch{key=...,revision=N}`，希望从已知revision回放更新；这也是断线后由应用自己恢复watch的标准用法。
- 影响：wire上的`start_revision`保持proto3默认0，server把watch解释为“now”；N到watch建立之间的历史事件全部缺失且API不报错。配置/协调、leader election或cache同步逻辑可能在无任何异常的情况下基于不完整状态继续运行。
- 证据：`M.watch`只执行prefix/sort等通用`apply_options`、filter转换和`watch_id`赋值，从未把`req.revision`复制为`req.start_revision`或删除别名。WatchCreateRequest descriptor没有`revision`字段；`pb.c`查不到table key对应field时直接忽略，因此调用成功但参数不出现在wire。现有测试只检查内部`start_revision`及收到事件后的重连，没有覆盖公开`revision`输入。
- 根因：Lua API使用了Range/Compaction风格的`revision`命名，却把用户table直接当protobuf message发送，缺少显式API→wire schema适配和未知参数校验。
- 建议解法：构造新的WatchCreateRequest，把公开`revision`严格校验并映射到`start_revision`；也可把API改名为`start_revision`并保留有弃用期的alias。拒绝同时提供两者或任何不属于公开schema的字段，避免继续静默丢配置；不要原地修改调用方table。
- 回归测试：修复阶段先写revision N、再产生N/N+1事件后创建`revision=N` watch，断言首个事件从N开始；覆盖0、已compact revision、future revision、alias冲突和未知字段，并抓取create request验证wire字段。当前不新增测试代码。

### ETCD-003 — P1 — watch 重连 checkpoint 不完整，断线窗口或 fragmented revision 会漏事件

- 状态：已确认；etcd watch恢复语义与recv/recreate状态机静态推导。本阶段不人为断开watch stream。
- 规范/权威依据：[etcd v3 API](https://etcd.io/docs/v3.6/learning/api/)说明`start_revision`是inclusive恢复点；未设置时从create response header revision之后开始，`progress_notify`专用于让client从近期已知revision恢复。协议还以`WatchResponse.fragment`标记同一大revision被拆成多条response，client必须在完整revision后才能越过它。
- 位置：response checkpoint更新在`lualib/silly/store/etcd.lua:213-243`；断线后按保存的`createreq`重建在`:245-303`；created/progress/fragment字段在`lualib/silly/store/etcd/v3/proto.lua:2316-2410`。
- 触发：watch以默认start_revision=0创建，尚未收到普通event时stream断开；或启用filter/progress_notify、期间只有被过滤事件/空progress response后断开。另一条路径是request启用`fragment=true`，收到同一revision的前一fragment后、后续fragment到达前断线。
- 影响：第一类重连仍发送0，new stream再次从“now”开始，原stream创建到重连之间的事件可永久缺失；fragment路径在第一块后立即保存`last mod_revision+1`，重连会跳过同revision尚未交付的其余块。watch仍继续输出后续事件且不报告gap，调用方无法察觉本地cache/协调状态已经不完整。
- 证据：`watch_recv_task`对`res.created`完全不处理，对无event的progress response也不更新revision；它只在普通response有event时取最后一个`mod_revision+1`。代码从不读取`res.header.revision`或`res.fragment`。reconnect枚举watcher并原样重发该mutable`createreq`，所以0或过早+1直接成为新的恢复点。
- 根因：把“最后看到某个event”当作完整watch delivery checkpoint，没有实现created/progress确认和revision fragmentation的提交边界。
- 建议解法：每个watch维护独立的confirmed revision：created response用`header.revision+1`建立初始恢复点，progress response在语义安全时推进；普通非fragmented response完整处理后推进到header/最后event之后。若支持fragment，先缓冲/交付同revision所有fragment并只在final fragment后commit checkpoint；否则禁止该option。重连始终使用已commit的inclusive revision，并在compaction时显式失败而非跳过。
- 回归测试：修复阶段在created后首事件前、progress后、filter-only revision后及每个fragment边界断流，重连后按revision/key序列核对无gap/dup；另覆盖compaction和重复response。当前仅记录静态时序。

### ETCD-004 — P1 — lease TTL 秒值被当作毫秒调度，keepalive 可形成集群请求风暴

- 状态：已确认；官方TTL单位、Silly clock单位和发送循环静态核对。不运行长TTL/多lease压力测试。
- 规范/权威依据：[etcd v3 API](https://etcd.io/docs/v3.6/learning/api/)明确LeaseGrant/LeaseKeepAlive response的TTL单位均为秒；client通常只需在TTL到期前按其一部分间隔续租。
- 位置：response调度在`lualib/silly/store/etcd.lua:143-159`；500ms发送loop在`:161-186`；初始keepalive state在`:539-555`；`time.now`毫秒来源在`lualib/silly/time.lua:18-26`和`src/timer.c:218-227,366-381`。
- 触发：对任意有效lease调用`keepalive`；server返回TTL=60时，代码设置next=now+20，含义实际是20毫秒而非20秒。TTL=1或2时整数除法得到0，response一到便再次到期。
- 影响：sender每500ms扫描一次，因next几乎总已到期而对每个lease约每秒发送2次请求；TTL越长，相对放大越严重，例如3600秒lease预期约20分钟一次却变成约0.5秒一次。大量client/lease会给etcd leader、gRPC stream和本进程CPU/带宽制造持续请求风暴，反而降低协调集群可用性。
- 证据：`time.now()`建立在毫秒monotonic clock上，`sleep`/常量也以毫秒为单位；`lease_recv_keepalive`却直接执行`now+resp.TTL`和`now+resp.TTL//3`，没有乘1000。发送成功后也不预先推进`nextkeepalive`，所以response稍慢时同一lease仍会每个500ms tick重复发送；`deadline`写入后从未被读取，不能抑制过期/失联项。
- 根因：wire API的seconds domain未经显式转换进入内部millisecond scheduler，并且keepalive state没有in-flight/backoff/deadline状态机。
- 建议解法：checked地将TTL秒转成毫秒，使用monotonic clock和合理jitter，在发送时立即设置下一次/in-flight期限，收到response再按server TTL校准；对TTL<=0移除并通知调用方，对超时/断流采用有上限backoff和lease-lost callback。避免所有lease在同一tick同步爆发。
- 回归测试：修复阶段用虚拟clock覆盖TTL 1/2/3/60/3600、response立即/延迟/丢失和多lease jitter；断言发送频率单位正确、每lease至多一个in-flight、失联可见且无同步风暴。本轮不做压力重现。

### ETCD-005 — P1 — watch 输出使用无界队列，慢/弃用 consumer 可耗尽进程内存

- 状态：已确认；watch receive、channel queue和consumer生命周期静态核对。本阶段不生成高速watch事件。
- 规范/权威依据：[etcd v3 API](https://etcd.io/docs/v3.6/learning/api/)把watch定义为持续的server-streaming event source；client必须为consumer速度与持续输入之间定义背压、上限或可见的取消策略，不能让网络peer决定无限驻留内存。
- 位置：每个watch创建channel在`lualib/silly/store/etcd.lua:568-600`，recv无条件push在`:213-240`；channel queue在`lualib/silly/sync/channel.lua:20-49`，只有显式read才pop在`:52-73`。
- 触发：应用读取watch慢于key更新速率、暂时停止读取但忘记cancel，或创建watch后丢弃返回对象；server继续发送合法event responses。
- 影响：recv task持续解码并把每个response及其events/value strings保存在Lua queue，没有条数、字节或时间预算，也不会通过HTTP/2 flow control向server施加per-consumer背压。单个高频prefix watch即可持续增长heap直至OOM；多个watch共享stream时，一个无人消费的watch不会阻塞recv，因而能在其他watch看似正常时隐蔽积累。
- 证据：`channel.push`在没有blocked reader时直接`qpush`，API没有capacity参数或push-wait；`watch_recv_task`忽略push返回值且从不检查queue length/bytes。watcher只在显式`cancel()`、server canceled或整个client close时关闭，Lua metatable没有`__gc/__close`，而`c.watchers[id]=w`又保持强引用，使丢弃对象也无法GC触发清理。
- 根因：用通用unbounded MPSC channel桥接network stream和application stream，却未给长期watch建立ownership与backpressure contract。
- 建议解法：提供可配置且默认有界的event/byte budget；可选择阻塞stream recv以利用HTTP/2 flow control、合并只保留安全progress state，或超限时取消该watch并返回RESOURCE_EXHAUSTED。watcher实现幂等`close/cancel`和`__close`，文档要求结构化生命周期；若无法可靠在`__gc`中发送cancel，至少从client registry移除并在后台generation-safe清理。
- 回归测试：修复阶段让一个watch不读、另一个正常读并持续写大value，监测queue/heap上界、HTTP/2 window与取消结果；覆盖显式cancel、scope close、丢引用GC和client close，确保response只释放一次。本轮不做流量压力测试。

### ETCD-006 — P1 — `dialtimeout` 配置未用于连接或 RPC，故障 endpoint 可无限挂起

- 状态：已确认；etcd wrapper到gRPC/TCP/TLS的配置传播静态核对。本阶段不连接blackhole endpoint。
- 位置：参数接收与唯一用途在`lualib/silly/store/etcd.lua:325-363`；gRPC lazy channel连接在`lualib/silly/net/grpc/client/conn.lua:46-99,121-156`；unary/watch/lease调用在`lualib/silly/store/etcd.lua:188-207,245-303,379-537`。
- 触发：用户按API传`dialtimeout=N`，endpoint在TCP connect、TLS handshake、HTTP/2初始协商、unary response或stream read阶段停止响应；也包括连接中的endpoint失效后自动重建。
- 影响：`newclient`可返回，但首个请求或后台watch/lease task无限等待；unary调用占住业务coroutine，watch/lease无法在承诺时间内转到其他endpoint。用户以为已设置timeout而不会再加外层保护，使服务shutdown、健康检查和故障切换永久停滞。
- 证据：etcd只把`opts.dialtimeout`存入对象，并用它计算一个从不读取的`keepalivetimeout`；调用`grpc.newclient`只传`targets`。gRPC conn options没有timeout字段，`tcp.connect/tls.connect`调用不传timeout；各etcd RPC也没有deadline参数。现有`GRPC-012`已记录gRPC通用deadline缺失，本项是etcd公开配置被静默吞掉的确定性API违约。
- 根因：wrapper定义了timeout配置但底层channel/call abstraction没有统一absolute deadline，字段因此退化成无效状态而未在构造时拒绝。
- 建议解法：明确拆分`dial_timeout`与每次RPC/default request timeout，并将absolute deadline贯穿DNS、connect、TLS、H2和gRPC call；watch/lease stream需有建立deadline、idle/progress policy和可取消重连backoff。底层尚未支持前应拒绝非nil配置并在文档声明无限等待，不能假装生效。
- 回归测试：修复阶段在DNS、TCP、TLS、H2 preface、unary body、watch/lease stream各阶段停住，断言同一总预算到期、资源关闭且故障切换发生；检查0/nil/边界值语义。本轮不做blackhole重现。

### ETCD-007 — P2 — range option 适配器丢失合法 `fromkey`/非 KEY 排序语义

- 状态：已确认；官方option契约、wire range语义与确定性table转换静态核对。不需要启动etcd。
- 规范/权威依据：[官方 clientv3 API](https://pkg.go.dev/go.etcd.io/etcd/client/v3)定义WithFromKey返回所有byte-compare大于等于起始key的项，WithSort允许KEY/VERSION/CREATE/MOD/VALUE配合NONE/ASCEND/DESCEND；etcd protobuf注释规定`range_end='\0'`表示无上界。
- 位置：option转换在`lualib/silly/store/etcd.lua:53-141`；get/delete/watch复用它在`:414-449,568-579`；公开文档在`docs/src/reference/store/etcd.md:145-168,228-244`。
- 触发：调用`get/delete/watch{key='',fromkey=true}`；或range get使用`sort_target='VERSION'|'CREATE'|'MOD'|'VALUE'`并指定ASCEND/DESCEND。
- 影响：空key fromkey只把key改为NUL却不设置range_end，server执行精确NUL key查询而非全key range，通常静默返回空；任何非KEY排序都会丢弃用户order并使用proto默认NONE，结果顺序与请求不符。分页、选latest revision、批量清理和全量同步可能漏数据或选错记录而无error。
- 证据：`opt_fromkey`在empty branch设置`options.key=no_prefix_end`后立即return，只有non-empty branch才写`range_end=no_prefix_end`。`opt_options`只在target为KEY时读取`options.sort_order`，其他target的local `sort_order`保持nil，随后`sort_order_num[nil]`赋nil并由protobuf encoder省略。函数还不验证prefix/fromkey互斥，`apply_options`用`pairs`执行冲突转换，使结果依赖table遍历顺序。
- 根因：option helper通过原地、稀疏修改用户table模拟官方typed OpOption，却没有先规范化、校验组合并生成完整wire request。
- 建议解法：建立纯函数request builder：先校验key与互斥option，再分别计算明确的key/range_end；排序target/order独立映射并验证enum，按etcd规则要求range。禁止依赖`pairs`顺序，未知/冲突option返回参数错误，且不修改调用方table。
- 回归测试：修复阶段覆盖empty/nonempty fromkey、prefix全0xff边界、五种target×三种order、invalid enum及prefix+fromkey冲突；抓取wire并与官方Go client输出/真实server结果逐项比较。当前不新增测试代码。

### ETCD-008 — P2 — unknown/late watch ID 触发 nil dereference，并永久停掉整条 watch manager

- 状态：已确认；multiplexed watch dispatch与task异常收尾静态推导。本阶段不伪造WatchResponse。
- 规范/权威依据：[etcd v3 API](https://etcd.io/docs/v3.6/learning/api/)说明同一watch stream以watch_id复用多个watch；client必须把response与已登记watch安全关联，对未知、失败创建或旧generation响应不能解引用不存在的本地对象。
- 位置：watch_id lookup与无条件使用在`lualib/silly/store/etcd.lua:213-243`；request manager只依赖recv正常push EOS来重连在`:245-303`；task异常处理在`lualib/silly/task.lua:47-64`。
- 触发：peer发送未登记watch_id的created/canceled/event response；也包括server/proxy bug、create conflict/error使用特殊ID，或stream切换/cancel边界出现late response而本地entry已移除。
- 影响：`w.outch`或`w.createreq`索引nil抛Lua异常，recv task立即终止；异常路径不会执行函数末尾的`c.watchreqc:push(EOS)`，request task仍认为stream有效并阻塞等下一条本地request。该client上所有watch从此不再接收或自动重连，调用方read无限等待且没有统一错误通知。
- 证据：代码在`local w=watchers[watchid]`后不检查w；canceled branch和event branch都立即索引它。EOS push不是protected/finally，只有read loop正常break才执行；task框架仅记录异常并关闭coroutine，不知道该stream及所有watchers需要失败/重连。
- 根因：把remote watch_id当作可信table key，并把关键control-plane cleanup放在普通函数尾部而非幂等finally/owner状态机。
- 建议解法：按stream generation验证response；未知ID记录受限日志并按协议严重性忽略或终止该stream，但必须走统一`fail_watch_stream`，原子清除current stream、通知request manager并保证所有watch可恢复/失败。created/canceled error应保留`compact_revision/cancel_reason`，不得用nil dereference替代structured error。
- 回归测试：修复阶段覆盖负数/0/未知/已cancel/旧stream ID、created/canceled/event三类response及recv decode异常；断言无Lua异常，manager必然重连或明确关闭全部watch，所有blocked read结束。当前不新增伪造response。

### ETCD-009 — P1 — etcd wrapper 无法启用 TLS 或认证，只能连接明文、未授权集群

- 状态：已确认；公开配置、gRPC channel选项和etcd Auth service暴露面静态核对。本阶段不搭建secure etcd。
- 规范/权威依据：[etcd transport security model](https://etcd.io/docs/v3.6/op-guide/security/)说明生产client-to-server通信可使用HTTPS、CA/server identity验证及client certificate authentication；etcd也提供Auth/Authenticate token机制。client library必须允许这些部署，而不应迫使用户关闭安全控制。
- 位置：etcd唯一配置面及channel构造在`lualib/silly/store/etcd.lua:325-363`；gRPC conn实际具有但未被传入的`tls`开关在`lualib/silly/net/grpc/client/conn.lua:121-155`；生成proto含Auth/Authenticate service在`lualib/silly/store/etcd/v3/proto.lua:1828-1964`，wrapper未创建或调用它。
- 触发：endpoint只监听HTTPS，要求受信CA/hostname、mTLS client cert或etcd username/password/token；这是常见的生产加固配置。
- 影响：Silly client无法连接安全集群，使用者只能额外部署降级明文proxy或关闭etcd TLS/auth；若为可用性而选择后者，KV、lease和watch数据及写权限暴露给网络攻击者。即使将来只透传`tls=true`，现有`TLS-001`还表明底层不验证server identity，因此必须一并修复而不能宣称安全。
- 证据：`newclient`类型与文档仅有endpoints/retry/timeout；它调用`grpc.newclient{targets=...}`，没有tls、CA、expected name、client cert或metadata。endpoint字符串的`https://`也会被gRPC `parse_target`作为unsupported scheme拒绝。wrapper只实例化KV/Lease/Watch service，没有Auth service和authorization metadata刷新路径。
- 根因：etcd adapter只覆盖本地无认证开发集群的最小RPC集合，没有把transport identity和application authentication纳入client状态机，却以通用etcd client API形式公开。
- 建议解法：支持明确的`https://` endpoint与安全默认TLS配置：系统/custom CA、SAN hostname/IP验证、可选client cert/key；实现Authenticate并在每个unary/stream携带token metadata，处理token过期的single-flight refresh且不把secret写日志。先修复底层TLS verification/custom metadata，再开放此配置；禁止静默明文回退。
- 回归测试：修复阶段覆盖受信TLS、错误CA/SAN、mTLS缺失/正确cert、RBAC username/password、token过期与watch/lease重连刷新；抓包确认无明文、日志无credential。当前不搭建secure peer。

### ETCD-010 — P2 — lease keepalive 重连遗留旧 stream/sender，可累积重复循环与资源

- 状态：已确认；keepalive双向stream的创建、读取失败、发送task与client关闭路径静态核对。本阶段不人为断开连接或运行并发barrier。
- 位置：sender生命周期在`lualib/silly/store/etcd.lua:161-186`，recv/reconnect循环在`:188-207`，client close只处理当前stream在`:606-622`。
- 触发：LeaseKeepAlive stream的读取方向因server关闭、HTTP/2 stream error或连接故障返回nil；client仍未关闭且至少登记过一个keepalive，recv task随后建立新stream并再次fork sender。
- 影响：旧sender没有收到generation取消信号，旧stream也没有被显式close。若旧写方向暂时未失败，旧、新sender可能同时对同一lease发送keepalive；若当前没有到期项，旧sender会每500ms永久扫描并保留旧stream引用。反复重连可线性累积task/stream，放大ETCD-004的续租流量；`client:close()`又只关闭最后写入`self.keepstream`的stream，不能可靠收敛早期generation。
- 证据：每次`LeaseKeepAlive()`成功都会无条件`task.fork(lease_send_task,{stream=stream})`；内层read loop退出后直接sleep/reconnect，没有`stream:close()`、没有等待/取消对应sender，也没有generation比较。sender的唯一退出条件是全局`c.closed`或其自身某次write失败；没有待发送项时两者都不会发生。重连会覆盖`c.keepstream`，因此旧stream失去owner但仍被sender闭包强引用。
- 根因：双向stream的读写两半由独立task持有，却没有以单一generation owner统一关闭、取消和join；共享`closed`只能关闭整个client，不能结束一次已经失效的stream generation。
- 建议解法：为每次keepalive stream建立generation-scoped session，recv或send任一侧失败都原子标记该generation关闭、显式close stream并唤醒/结束另一侧；只有当前generation可更新共享状态。重连前完成旧session收尾，`client:close()`取消并等待唯一owner；发送调度与ETCD-004一并改为单owner、单lease至多一个in-flight。
- 回归测试：修复阶段覆盖read-first failure、write-first failure、空keepalive集合、多个lease及连续多次重连；以task/stream计数和记录的lease ID断言任意时刻只有一个generation sender、旧stream均关闭、无重复发送且close后全部task退出。当前不执行断链测试。

### ETCD-011 — P2 — watch 公开的 `wait`/`limit` 参数被 protobuf 静默丢弃

- 状态：已确认；LuaLS公开签名、watch request构造、protobuf descriptor与encoder unknown-field行为静态核对。不建立watch stream。
- 位置：公开参数注解及原table直传在`lualib/silly/store/etcd.lua:557-600`；WatchCreateRequest字段集合在`lualib/silly/store/etcd/v3/proto.lua:2316-2361`；protobuf table encoder忽略未知key在`luaclib-src/pb.c:1737-1756`。
- 触发：调用方根据IDE/LuaLS签名传`wait=true`，或传`limit=N`期望watch在特定变化前等待/最多交付N个event；请求其余字段合法。
- 影响：API正常返回watcher且没有参数错误，但wire上两个字段均不存在。`wait`不改变本来就由`read()`阻塞的stream语义，`limit`也不会在N个event后cancel或停止交付；依赖有限事件数做资源控制、一次性观察或业务收尾的调用会无限存活，并可进一步暴露ETCD-005的无界队列风险。
- 证据：`M.watch`只转换prefix/filter并写入watch_id，随后把同一req作为`create_request`发送；代码从不读取、删除或实现`wait/limit`。官方WatchCreateRequest仅有key、range_end、start_revision、progress_notify、filters、prev_kv、watch_id、fragment；descriptor不存在wait/limit，通用encoder对查不到field的table key直接跳过。中英文reference也未列这两个选项，说明源码类型契约与文档/wire三者分叉。
- 根因：把其他KV/watch封装曾使用的便利参数留在公开注解中，却没有显式API schema、request builder或unknown-option验证来阻止无效字段进入protobuf table。
- 建议解法：若无明确兼容需求，从签名删除`wait/limit`并对未知字段fail fast；若保留便利能力，定义精确本地语义：watch创建本身始终异步，`limit`由watcher在完整event边界计数并generation-safe cancel，错误/compaction是否计数需文档化。不要伪造非标准wire字段，并与ETCD-002一起改为新建request而非原地复用caller table。
- 回归测试：修复阶段对公开watch option逐字段抓取编码table/wire，断言所有接受字段都生效、未知字段返回参数错误；若实现limit，覆盖单response多event、fragment、cancel竞态和0/负值。当前只做schema静态比对。

### ETCD-012 — P2 — `retry` 被当作总 attempt 数，零值会跳过 RPC 并返回 `nil, nil`

- 状态：已确认；中英文配置契约与六个unary retry loop静态核对。不调用RPC或等待重试计时。
- 位置：配置读取在`lualib/silly/store/etcd.lua:325-349`，Put/Range/DeleteRange/Compact/LeaseGrant/LeaseRevoke循环在`:379-512`，完全绕过retry的LeaseTimeToLive/LeaseLeases在`:514-537`；契约见`docs/src/reference/store/etcd.md:45-63`及英文同名文档。
- 触发：设置`retry=0`表达“首次请求失败后不重试”，或设置任意N并按文档期望一次初始attempt加N次retry；负数和非整数也未被构造器拒绝。另一条路径是调用`ttl()`或`leases()`遇到本可恢复的首次transport failure。
- 影响：零值时`for i=1,0`完全不进入RPC，method直接返回初始的`nil,nil`，调用方既没有响应也没有错误可诊断；默认5与配置N均少一次实际尝试。每次最终失败后代码还无条件sleep，使已经决定返回的调用额外延迟`retry_sleep`。此外两个只读lease查询始终只尝试一次，即使配置了retry；同一client的读API因此具有不同且未公开的可靠性。读写、压缩和lease API整体形成边界不可用的重试/时延契约。
- 证据：Lua中0为truthy，所以`opts.retry or 5`保留0；六个method都以`for i=1,self.retry`直接控制总RPC调用数，而`ttl/leases`直接return底层service调用。文档两种语言均把它描述为client级“请求失败时的重试次数”，未列method例外。循环body只在成功时break/return，失败后不判断是否还有下一轮便sleep；没有范围/type校验，也没有在零轮后合成错误。
- 根因：配置名按“额外retry”设计，循环变量却按“attempt budget”实现，且构造器没有把边界值规范化；各method手写retry导致覆盖漂移，模板也未区分attempt后的backoff与return。
- 建议解法：先定义并固定契约。按现有文档应校验`retry`为非负整数，执行一次初始请求并至多额外N次；仅在确实还有下一attempt时sleep。若改用`max_attempts`，应要求至少1并迁移/弃用旧名。由共享的method-aware helper覆盖所有安全read并分类status；所有最终失败必须返回最后一个结构化错误。mutation仍受ETCD-001约束，不能因此扩大盲重试范围。
- 回归测试：修复阶段以fake service计数覆盖全部八个unary method及retry=0/1/5、首轮成功、中途成功、全部失败、负数/小数/错误类型；断言attempt数、sleep数、最终error和mutation retry policy，并确保ttl/leases不再成为例外。当前只记录控制流。

### ETCD-013 — P2 — client 关闭后 `watch()` 仍报告成功，返回的 watcher 会永久等待

- 状态：已确认；client close、channel push与watch manager启动路径确定性静态推导。不调用close/watch或阻塞read。
- 位置：watch构造与未检查push结果在`lualib/silly/store/etcd.lua:557-600`，client close在`:606-622`；channel关闭后的push/pop语义在`lualib/silly/sync/channel.lua:20-73`。
- 触发：先调用`client:close()`，再调用`client:watch(req)`并对返回对象执行`read()`；也覆盖close已发生而上层因复用对象误发起新watch的常见生命周期错误。
- 影响：`watch()`返回非nil watcher和nil error，调用方认为创建成功；其out channel没有任何producer也未被关闭，`read()`设置waiter后永久挂起。watcher还被已关闭client的`watchers`表强引用，后续没有第二次close清理（close幂等直接return），形成对象/task泄漏并阻碍shutdown。
- 证据：`M.watch`从不读取`self.closed`；`watchreqc`已由close设置reason，故`push({create_request=...})`返回`false,"client closed"`，但返回值被丢弃。随后代码仍把w放进watchers并返回`w,nil`。若watchco为空，新fork的manager从closed channel pop后立即退出；若已有watchco，字段不会重置也不会产生新consumer。close对watchers的遍历已经发生，后来插入的w.outch保持open，`channel.pop`因此只能进入无期限`task.wait()`。
- 根因：watch创建没有以client lifecycle为admission gate，也没有把control-channel enqueue作为可能失败的事务步骤；对象发布、registry插入和manager ownership缺少统一成功/回滚边界。
- 建议解法：入口先检查closed并返回`nil,"client closed"`，再以同一generation/lifecycle锁原子完成enqueue与registry发布；必须检查channel push结果，失败时关闭outch、撤销registry并返回错误。close应阻止新的admission后再关闭manager和已登记watch，并等待owner收尾；watchco退出时清空句柄以便状态可诊断。
- 回归测试：修复阶段覆盖close前/后watch、watch与close交错、首次watch和已有manager两种状态；断言失败立即可见、没有watcher发布/registry残留/blocked read，并覆盖重复close/cancel。当前不运行生命周期交错。

### ETCD-014 — P2 — 旧 watch recv 的迟到 EOS 可关闭新 generation stream

- 状态：已确认；watch读写task分离、stream替换与无generation控制消息的静态竞态推导。本阶段不注入write failure或调度barrier。
- 位置：全局EOS sentinel与recv尾部push在`lualib/silly/store/etcd.lua:209-244`；manager关闭、重连、发布新stream及消费EOS在`:245-303`。
- 触发时序：watch manager向旧stream写create/cancel失败，主动close旧stream并开始重连；旧recv task因此从阻塞read返回nil，但在新stream写入`c.watchstream`、manager执行queue clear之后才恢复并push全局EOS。
- 影响：manager无法判断EOS来自哪个stream，会把当前的新stream关闭并再次重连；多个旧recv迟到时可连续击落健康generation，造成watch事件窗口扩大、重复创建/取消、额外task/连接 churn，并放大ETCD-003的恢复gap。极端调度或持续控制流量下watch可长时间抖动而无法稳定交付。
- 证据：`EOS`是所有stream共用的空table，不携带stream/generation。recv在read失败后不检查`stream==c.watchstream`便无条件`c.watchreqc:push(EOS)`；仅收到正常response后才做一次stale-stream比较。manager的EOS分支操作其局部变量`stream`（此时可为新generation），直接close/nil/goto reconnect。重连时的`watchreqc:clear()`只能删除已经排队的旧EOS，无法阻止clear之后才到达的迟到消息。
- 根因：stream failure事件没有owner identity，读写两侧也没有generation-scoped cancellation/join；用共享channel singleton表示“某个stream结束”破坏了重连前后的因果关联。
- 建议解法：EOS携带`{stream,generation,error}`，manager仅在消息匹配当前generation时执行failover；旧recv发现自己不再current时只做本地收尾。更稳妥的是让单一session owner管理recv/send，替换前先标旧generation canceled并显式等待其退出；统一幂等`fail_watch_stream`处理close、通知与checkpoint。
- 回归测试：修复阶段控制旧recv分别在新stream发布前/queue clear前/clear后/首个event后返回，断言迟到EOS不会关闭新stream，当前generation失败仍恰好触发一次重连；覆盖连续两代旧task和client close。当前仅记录竞态，不建立barrier。

### ETCD-015 — P2 — client 关闭后 `keepalive()` 仍静默登记，lease 会在“成功”后过期

- 状态：已确认；client/keepalive生命周期与后台owner退出条件的确定性静态推导。本轮不等待真实lease过期或运行close竞态。
- 位置：keepalive registry、owner handle与closed状态在`lualib/silly/store/etcd.lua:26-43,340-360`；公开`keepalive`入口在`:539-555`；recv/send owner均以`c.closed`为退出条件在`:161-209`；client close在`:603-622`。
- 触发：调用`client:close()`后继续调用`client:keepalive(id)`；也包括上层shutdown与lease注册交错、持有旧client引用的组件在close完成后登记新lease ID。
- 影响：方法没有错误返回，调用方会认为lease已经纳入持续续租；实际上新登记的entry永远不会发出LeaseKeepAlive，关联的服务注册、锁或选主key会在TTL后静默消失。entry仍被closed client的`keepalives`表保留；若此前从未启动owner，还会fork一个只为观察`closed=true`便退出的task，进一步掩盖admission失败。
- 证据：`M.keepalive`不检查`self.closed`，先写`keepalives[id]`，再只以`if not self.keepaliveco`决定fork，最后无返回值。close把`closed`置true并关闭当前stream/conn，却不清registry或将`keepaliveco`重置为可诊断终态。新fork的`lease_recv_task`首个`while not c.closed`条件直接失败；已有handle也不会产生新owner，因此两条分支都不会发送请求。
- 根因：keepalive registration没有纳入client lifecycle admission，fire-and-forget API又没有可观察的成功/失败契约；registry publication与后台owner存活性不是同一个事务。
- 建议解法：`keepalive(id)`在任何registry修改前检查lifecycle，并返回`true`或`false,"client closed"`；以client generation/owner lock原子完成登记与owner启动，close先封闭admission、再取消并join owner、清理registry并向每个lease观察者报告终态。若保留幂等重复登记，也必须区分“已登记且owner健康”与“client已终止”。
- 回归测试：修复阶段覆盖close前登记、close后登记、首次登记与close交错、已有owner时登记、重复ID及close幂等；通过可控sender断言失败调用零请求/零registry残留，成功调用有owner并在close时结束，所有分支返回值明确。真实etcd集成再验证不会出现API报告成功而lease到期。本轮不运行这些场景。

### ETCD-016 — P2 — watch compaction 取消丢弃恢复 revision 与服务端原因

- 状态：已确认；etcd WatchResponse schema与watcher交付路径的确定性静态核对。本轮不建立watch或触发compaction。
- 协议语义：`WatchResponse.canceled`终止对应watch；当请求的revision已被压缩时，响应通过`compact_revision`给出恢复所需的压缩边界，并可通过`cancel_reason`说明取消原因。client必须让调用方区分本地取消、服务端取消与compaction，且不能丢掉恢复游标。
- 位置：生成的WatchResponse字段在`lualib/silly/store/etcd/v3/proto.lua:2394-2405,3017-3018`；接收及取消分支在`lualib/silly/store/etcd.lua:211-243`；公开`watcher:read/cancel`在`:306-323`。
- 触发：watch以已经被etcd compact的`start_revision`建立，或运行中的watch被server因compaction/权限/其他原因取消，返回`canceled=true`并携带非零`compact_revision`或`cancel_reason`。
- 影响：调用方只得到固定字符串`"watch canceled"`，看不到服务端响应、压缩边界或原因，无法可靠决定从`compact_revision+1`重建、先做range snapshot，还是报告权限/参数错误。把所有终态折叠成同一文本会促使盲目从旧revision重试并形成取消循环，或从当前revision重启而静默跳过历史变更；这会放大`ETCD-003`的事件连续性风险。
- 证据：`watch_recv_task`检测`res.canceled`后立即删除registry entry并执行`w.outch:close("watch canceled")`，从未push/return `res`，也没有读取`res.compact_revision`或`res.cancel_reason`。本地`watcher:cancel()`最终走相同server response分支，因此公开`read()`的第二返回值无法区分原因。仓库除生成schema注释外没有消费这两个字段。
- 根因：watch输出channel只把普通event response当数据，把所有canceled response当无结构close signal；终态没有保留协议payload或typed error。
- 建议解法：定义结构化watch终态，至少包含`kind`、`watch_id`、`compact_revision`、`cancel_reason`及最后确认revision；可以先把完整canceled response交付一次再关闭，或让`read()`返回typed error。compaction恢复策略必须由调用方明确选择snapshot/restart，不能库内无信息盲重试；本地cancel也应有独立kind。
- 回归测试：修复阶段覆盖显式本地cancel、server普通cancel、auth error及已压缩revision；断言调用方精确取得compact revision/reason且watch恰好终止一次。再从边界执行snapshot+watch并验证无重复/缺口，当前不请求compaction。

### DOC-001 — P3 — etcd 中英文文档的构造、timeout、watch 与 lease 契约多处偏离实现

- 状态：已确认；中英文reference与公开Lua对象逐项对照。不修改产品文档正文，只在审计报告记录契约差异。
- 位置：双语构造与概念说明在`docs/src/reference/store/etcd.md:34-86`和英文同名文档；中文grant/revoke/keepalive在`:340-414,550-566`、英文对应段落；watch说明及示例在中文`:583-654`和英文`:593-664`并在后文重复。实际实现位于`lualib/silly/store/etcd.lua:325-363,477-622`。
- 触发：用户按文档配置`timeout=5`、按“grant后自动保活”假设不调用`keepalive(id)`、依赖keepalive超时自动移除lease，或按watch示例调用`stream:close()`；构造失败时又只用异常捕获而不检查第二返回值。
- 影响：timeout被完全忽略且调用仍可永久挂起；grant所得lease根本不会续租并可能连同业务key意外过期，revoke与自动保活的关系也被错误描述。keepalive deadline从未检查、stream不会按文档自动关闭；中文把持续注册API误称为“手动发送一次”，与英文和实现均冲突。watch返回的是只有`read/cancel`的watcher而非gRPC stream，调用`stream:close()`会抛“attempt to call a nil value”。newclient的DNS/target失败返回`nil,err`而非抛出，照文档写法可把nil client继续传下去。中英文大量示例重复这些错误，使照抄应用出现异常或错误的故障安全假设。
- 证据：文档参数名为`timeout`且单位秒，代码注解/读取名为`dialtimeout`，后者本身又未下传（ETCD-006）。双语概念页和grant段都宣称创建lease自动fork keepalive，但`M.grant`只返回LeaseGrant响应，唯一登记/启动点是显式`M.keepalive`。文档描述`keepalivetimeout`触发drop/close，实现只写`deadline`从不读。watcher metatable只定义`read/cancel`，示例统一使用不存在的`close`。`newclient`在grpc构造失败时明确`return nil,err`，与“Failure: Throws”相反。
- 根因：reference混合了早期/预期API和两种不同keepalive设计，未以可执行示例、LuaLS导出面或method dataflow做一致性检查；中英文复制又使部分错误同步扩散、部分语义彼此分叉。
- 建议解法：先决定真实API契约并修实现，再同步两种语言：构造统一返回`client?,error?`或明确抛错；timeout使用毫秒或absolute deadline的唯一命名/单位；明确grant是否自动注册keepalive，若需显式调用则所有概念/示例都展示它；keepalive描述为持续注册并提供可观察失联/取消；watch返回类型写为watcher且统一`cancel/close`。文档示例加入静态类型检查及最小运行验证，CI比较公开method/option schema。
- 回归测试：修复阶段对中英文所有etcd `lua validate` block执行doc-test，启用LuaLS unknown-member和未检查nil诊断；增加schema snapshot验证配置名、返回值、method集合及grant→keepalive调用序列一致。本轮不运行示例。

### DOC-002 — P3 — DNS 中英文文档把默认重试错误描述为三次递增间隔

- 状态：已确认；中英文reference、配置说明与实现常量/定时路径逐项静态对照。不运行文档示例。
- 位置：英文文档`docs/src/en/reference/net/dns.md:87-104,671-692`；中文文档`docs/src/reference/net/dns.md:87-104,671-692`；同一文档较新的配置表在两文件`:185-210`；实现位于`lualib/silly/net/dns.lua:78-80,350-390,757-807`。
- 触发：用户按API notes或“Timeout and Retry”示例估算默认等待、配置监控阈值或选择caller timeout；同一页面的配置表又显示`attempts`默认2，形成自相矛盾契约。
- 影响：文档声称默认重试3次、间隔依次5/10/15秒、最多等待30秒，实际共享wire request默认总共发送2次且每次固定5秒；公开caller timeout还可能先退出而后台request继续。运维会错误设置SLA、告警和上层deadline，排障时也会误判丢包次数与请求仍在后台存活的时间。
- 证据：`conf_attempts=2`、`conf_timeout=5000`；`retry_cb`仅在`attempt<conf_attempts`时递增，`send_udp_req`每次始终`time.after(conf_timeout,...)`，没有backoff乘数。两种语言的API notes和示例仍逐字承诺3次递增，而`:194`配置表正确写默认2。
- 根因：旧版叙述与示例未随resolver重构同步，reference没有从实现默认值生成或用静态契约检查验证，同一错误被翻译复制。
- 建议解法：先明确`attempts`究竟表示总发送次数还是额外retry次数，并与`DNS-005/007`修复后的nameserver round和absolute deadline语义统一；随后同步中英文参数、示例、最大等待公式和caller/shared request区别。CI从单一配置schema生成默认值表，并校验文档代码块中的数值。
- 回归测试：修复阶段以静态doc contract测试读取实现/schema默认值并核对两种语言；若保留时序示例，只验证可观测attempt序列和固定/退避策略与文字一致。当前不运行示例或计时测试。

### DOC-003 — P3 — HTTP 中英文文档虚构 `respond` 的 close 参数并统一承诺布尔返回

- 状态：已确认；中英文reference与H1/H2方法签名/返回路径逐项静态对照。本轮不调用HTTP API。
- 位置：中文文档两处契约在`docs/src/reference/net/http.md:128-138,442-450`；英文文档在`docs/src/en/reference/net/http.md:131-141`；H1实现为`lualib/silly/net/http/h1.lua:758-771`，H2实现为`lualib/silly/net/http/h2.lua:949-961`。
- 触发：应用按文档调用`stream:respond(status,headers,true)`期待不发送正文并立即关闭，或统一检查`local ok,err=stream:respond(...)`。
- 影响：Lua会静默丢弃第三参数，H1继续按header/body与keepalive状态运行；H2同样没有close语义。H1成功路径又返回nil，按文档检查`if not ok`会把每次成功误判成失败，而H2返回true，导致相同server handler在ALPN协议不同后出现分叉行为。调用方可能重复响应、执行错误补偿或错误地依赖连接已关闭。
- 证据：两份reference都列出可选`close:boolean`并承诺成功true/失败false+error；H1签名只有三个Lua形参（含self）且末尾无return，H2也只接收status/header但会返回boolean。两实现均由独立`closewrite`结束发送，H1持久性由Connection/version路径决定而非被忽略的实参。
- 根因：文档把不同协议stream的API理想化成统一接口，但没有以LuaLS签名/实现作为生成或审查来源，旧参数与返回契约残留。
- 建议解法：先决定稳定公共契约：推荐H1/H2 `respond(status,headers)`都返回`boolean,error`，删除虚构close参数并用`closewrite`/明确Connection语义结束；若必须保留close则两协议实现一致、定义它对body与连接/stream的精确行为。同步中英文两处重复章节及LuaLS annotation。
- 回归测试：修复阶段以API contract test覆盖H1/H2 respond成功/stream已关闭失败、返回值形状与第三参数策略；文档示例纳入静态签名检查。当前不调用API。

### DOC-004 — P3 — gRPC 中英文 reference 的所有 registrar 示例都遗漏 `service_name`

- 状态：已确认；中英文reference、公开导出与唯一registrar实现的静态签名核对。本轮不运行文档示例。
- 位置：两份文档把签名写成 `registrar:register(proto, service)`，见 `docs/src/en/reference/net/grpc.md:103-144` 与 `docs/src/reference/net/grpc.md:103-144`；两份文档各14处注册示例均为同一两参数形式。真实实现是 `lualib/silly/net/grpc/registrar.lua:264-290` 的 `M:register(proto, service_name, service_handlers)`；仓库测试使用正确三参数形式，见 `test/testgrpc.lua:55-127`。
- 触发：按任一语言的入门、server、streaming、TLS、负载均衡等示例调用 `reg:register(proto, {Method=fn})`。
- 影响：handler table 被绑定为 `service_name`，`service_handlers` 成为 nil；service查找不可能把descriptor name与table判等，随后构造错误文本时还会尝试拼接table并直接抛Lua类型异常。文档宣称可执行的全部server示例因此无法完成注册，用户无法按reference启动服务；真实多service proto又无法从文档得知如何选择service。
- 证据：registrar循环只比较 `v.name == service_name`，成功后还会读取 `service_handlers[name]`，明确要求独立字符串参数。英文与中文的API参数表都只列proto/service，并且grep可见每份14个 `reg*:register(p.loaded[...], {` 调用无service名称；唯一仓库测试则传入 `"TestService"` 后再传handler table。
- 根因：实现增加/保留了service选择参数，但reference签名、参数表与复制出的全部示例没有由LuaLS/API schema生成或通过doc-test校验；中英文文件同步复制了同一旧契约。
- 建议解法：把公开签名统一为 `registrar:register(proto, service_name, service_handlers)`，解释service_name是proto内descriptor短名，并修复两种语言所有示例；若产品希望支持只有一个service时的两参数便利形式，也必须在实现中显式重载并在多service时拒绝歧义。错误路径先校验参数类型，避免拼接table产生二次异常。
- 回归测试：修复阶段把两种语言所有 `lua validate` block纳入doc-test/LuaLS签名检查；覆盖正确service、未知service、单/多service proto、缺参数及错误类型，确保返回/异常信息与文档一致。当前不运行示例。

### DOC-005 — P3 — Redis pipeline 示例使用不存在的输出参数，`select` 提示契约也未实现

- 状态：已确认；中英文reference与公开Lua签名/返回路径逐项静态核对。本轮不运行文档示例或Redis命令。
- 位置：错误pipeline示例位于`docs/src/reference/store/redis.md:518-548`与`docs/src/en/reference/store/redis.md:518-548`；`select`契约在两文件`:221-231`。实现分别是`lualib/silly/store/redis.lua:176-178,310-349`。
- 触发：照抄“批量操作”示例，先声明`local results={}`，再调用`db:pipeline(requests, results)`并遍历原table；或调用已废弃`db:select(dbid)`期待文档所述的迁移提示。
- 影响：Lua静默忽略pipeline第二实参，真实结果作为第一个返回值被示例丢弃，局部`results`保持空table，示例的验证循环根本不执行，形成假成功并教会用户错误API。`select`确实抛错，但只得到通用`assertion failed!`，没有文档承诺的“应在redis.new指定db”诊断，迁移和排障信息丢失。
- 证据：`redis:pipeline`只声明/读取`req`并自行创建`local results={}`返回，从不接受out table；同页前面的API参考示例正确使用`local results,err=db:pipeline(...)`，页面自身矛盾。`redis:select`写成`assert(not "please specify the db when redis.new")`：字符串truthy、`not`后恒false，而message没有作为assert第二参数传入。
- 根因：用例来自旧的out-parameter API形态且未纳入doc-test；废弃method又把`assert(condition,message)`误写成对message取反，文档没有与实际error text核对。
- 建议解法：两种语言统一改为接收pipeline返回值并断言err；若不支持out table就从全部示例移除该形式。`select`改为`error("please specify ...",2)`或`assert(false,"...")`并统一大小写/措辞；更推荐返回明确deprecation error。所有`lua validate`块进入CI执行或至少做LuaLS调用签名检查。
- 回归测试：修复阶段运行双语Redis validate块，断言pipeline示例实际遍历预期result；直接检查select错误包含迁移提示且stack level指向caller。当前不执行示例。

### DOC-006 — P3 — etcd “事务性操作”示例实际是四个独立 RPC，并不原子

- 状态：已确认；双语示例、wrapper公开method集合与生成KV service静态核对。不运行示例或并发writer。
- 位置：中文示例在`docs/src/reference/store/etcd.md:947-1002`，英文对应在`docs/src/en/reference/store/etcd.md:957-1012`；wrapper method集合在`lualib/silly/store/etcd.lua:379-604`；底层proto的真实Txn RPC在`lualib/silly/store/etcd/v3/proto.lua:1616-1626`。
- 触发：用户照“事务性操作”“原子性的多键操作”示例实现计数器或需要all-or-nothing的多键更新；期间存在另一client写入、任一步RPC失败或进程退出。
- 影响：两个get和两个put各自独立提交，compare与revision没有绑定；并发writer可造成lost update，第二个put失败时只更新第一个key，读到的两值也可能来自不同revision。示例在输出“Counters incremented”时仍可能已破坏多键不变量，而用户因标题和说明相信获得了etcd transaction保证。
- 证据：示例虽然注明“需要通过底层gRPC客户端”，实际只调用wrapper的`get/put`，没有取得底层service、没有构造Compare/TxnRequest，也没有调用`KV.Txn`。`etcd.lua`创建`self.kv`但公开M没有txn方法；生成proto明确存在Txn RPC，证明示例遗漏的正是原子server operation而非等价封装。
- 根因：文档把顺序执行多个普通操作误称为事务，示例标题/叙述没有经过原子性语义审查；wrapper对proto能力的覆盖也没有生成式API清单或明确unsupported说明。
- 建议解法：删除“原子”声明或正式公开`client:txn{compare,success,failure}`并让示例使用单个Txn RPC，以mod_revision/version compare防止lost update；若暂不封装，提供准确的底层service访问方式和完整TxnRequest示例，并突出返回`succeeded`及失败分支。不要用client-side read-modify-write冒充事务。
- 回归测试：修复阶段doc-test捕获发出的RPC method并断言示例只调用一次KV/Txn；语义回归覆盖compare成功/失败、并发writer、第二操作非法及transport ambiguity，验证同revision/all-or-nothing。当前只核对文本与method表。

### DOC-007 — P3 — TCP/TLS 文档示例使用实现拒绝的多字节分隔符

- 状态：已确认；双语reference/guide/benchmark与buffer、TCP、TLS实现及现有单元测试的确定性静态对照。本轮不运行文档示例。
- 公开契约：`conn:read(string)`应清楚说明可接受的delimiter语法，所有标为可验证或可复制的示例必须落在真实API输入域内。
- 位置：TCP转发delimiter到buffer的路径在`lualib/silly/net/tcp.lua:263-300`，C buffer限制在`luaclib-src/adt/lbuffer.c:357-375`；TLS有相同限制，见`luaclib-src/ltls.c:525-540`。错误的`conn:read("\\r\\n")`出现在双语`docs/src/{en/,}reference/net/tcp.md`、`reference/net/tls.md`、`guides/tls-configuration.md`及`benchmark.md`，共10处。
- 触发：照抄任一HTTP/TLS/benchmark示例，以`"\r\n"`调用TCP或TLS connection的`read`；或者根据参数说明传入任何长度大于1的字符串delimiter。
- 影响：调用不会读取一行，而是在进入native buffer reader时立即抛出`delimiter length must be 1`。TCP reference中完整HTTP响应示例在第一条状态行即终止；TLS与benchmark示例同样不可运行。更危险的是通用说明只写“字符串分隔符”，让应用把多字节协议边界错误地建立在一个实现明确拒绝的能力上。
- 证据：`conn.read`未经转换把`n`交给`bread`；`lbuffer.c`对string执行`luaL_argcheck(delim.len == 1, ...)`，TLS reader也执行同一检查。buffer测试还专门断言多字节delimiter必须报该错误，而TCP测试只覆盖`"\n"`，因此不是未记录的多字节实现能力。仓库grep可见双语文档各五处使用`"\r\n"`。
- 根因：文档把单字节terminator泛化成任意字符串delimiter，并复制了基于CRLF的HTTP示例；文档代码块没有经过与底层参数约束一致的静态或运行校验。
- 建议解法：1.0若不扩展实现，应把TCP/TLS参数明确写成“恰好一个字节”，所有示例改为读`"\n"`后校验/剥离前置`\r`，或直接使用HTTP模块；benchmark也使用单字节分隔符。若要支持多字节delimiter，则需在跨buffer-node流式匹配、重叠前缀、EOF和limit语义都定义后实现，不能只放宽长度断言。
- 回归测试：修复阶段让双语doc-test执行所有相关代码块，并增加delimiter长度0/1/2、多字节UTF-8、跨chunk CRLF与重叠前缀契约测试；选择单字节契约时，长度非1必须在文档和错误类型上一致。当前不执行这些示例。

### DOC-008 — P3 — DNS 双语文档声明了实现不存在的环境变量路径覆盖

- 状态：已确认；双语reference、Unix编译期宏、Windows系统API与仓库全局引用静态核对。本轮不设置环境变量或改系统文件。
- 位置：不存在的配置承诺在`docs/src/en/reference/net/dns.md:43-52`和`docs/src/reference/net/dns.md:43-52`；Unix固定路径在`src/unix/unix.h:57-58`及`src/unix/unix.c:154-181`，Windows读取路径在`src/win/win.c:295-362`。仓库除两份文档外没有`sys.dns.resolv_conf`或`sys.dns.hosts`引用。
- 触发：用户按reference设置这两个环境变量，试图让测试、容器、chroot或自定义网络策略读取另一个resolv.conf/hosts文件，然后正常加载DNS模块。
- 影响：变量被完全忽略；Unix仍读取固定`/etc/resolv.conf`和`/etc/hosts`，Windows仍调用`GetNetworkParams`并拼系统hosts路径。测试可能意外访问宿主DNS，容器/沙箱读取错误配置；若固定resolver文件不可用，还会触发`DNS-018`的公共8.8.8.8 fallback。调用方没有unknown-setting错误，容易误以为隔离策略已经生效。
- 证据：两个Unix路径仅由`#define DNS_RESOLVCONF "/etc/resolv.conf"`与`DNS_HOSTS "/etc/hosts"`提供，`push_file`直接使用宏；Windows函数无环境读取。全仓库搜索只有文档出现两个键，Lua初始化也无`os.getenv`、config table或参数下传。
- 根因：reference保留了旧版或计划中的配置接口，但当前native平台抽象只暴露“读取系统默认内容”的无参数函数；文档代码块校验不覆盖叙述中的配置键。
- 建议解法：1.0前二选一并保持双语一致：若需要覆盖，提供显式、可验证且在首次module load前生效的配置API/启动项，定义平台、权限与路径编码语义；若不支持，删除环境变量承诺并指导使用`dns.conf`/`dns.sethosts`（同时说明二者不是文件路径加载器）。未知旧配置应至少产生迁移诊断。
- 回归测试：修复阶段增加公开配置schema/doc lint，确保文档中的每个键都存在consumer；若实现路径覆盖，用临时文件/stub验证resolver与hosts分别读取指定内容且错误可见。当前只保存静态证据。

### DOC-009 — P3 — TLS 双语 reference 的 listener/remoteaddr 示例缺必填地址或直接传 hostname

- 状态：已确认；两种语言的`lua validate`代码块与TLS/TCP公开入口、numeric address解析路径静态核对。本轮不运行文档示例或DNS/connect。
- 位置：缺少`addr`的`tls.listen` API示例在`docs/src/en/reference/net/tls.md:330-350`和`docs/src/reference/net/tls.md:330-350`；直接调用`tls.connect("example.com:443")`的remoteaddr示例在两文件`:547-565`。真实检查在`lualib/silly/net/tls.lua:279-325,326-365`及`lualib/silly/net.lua:97-140`，numeric-only socket解析在`src/socket.c:1242-1259`。
- 触发：照抄第一段启动listener，或照抄第二段获取远端地址；两段均被文档标记为可验证Lua代码。
- 影响：listener示例在任何socket操作前以`tls.listen missing addr`抛异常；remoteaddr示例把`example.com`传到底层带`AI_NUMERICHOST`的`getaddrinfo`，不会自动调用`silly.net.dns`，连接稳定失败并在`if not conn then return end`静默退出，永远不打印属性。用户会误判TLS能直接解析hostname、或在最基础API示例就无法启动服务。
- 证据：`M.listen`无条件`assert(addr,...)`，示例table只有certs/accept。`net.connect_wrap`只做语法拆分后进入native socket，后者hints固定`AI_NUMERICHOST`；同一reference前面的完整client示例正确地先`dns.lookup`再拼IP，证明remoteaddr段不是支持另一种入口，而是页面内部漂移。英文和中文逐字共享两个错误。
- 根因：独立API片段从完整示例复制/删减时遗漏required field和DNS步骤，`lua validate`标签没有接入签名/schema或实际doc-test。
- 建议解法：listener片段加入明确numeric `addr`并检查`listener,err`；remoteaddr片段复用`dns.lookup`或改成numeric endpoint，同时保留logical hostname给SNI/未来证书验证。若1.0决定让TLS connect接受hostname，应由统一双栈resolver/dialer实现并更新真实契约，不能只改示例。CI对所有validate块做required-option静态检查并用stub禁止外网。
- 回归测试：修复阶段让双语validate块在stub DNS/socket环境执行，断言listener参数完整、hostname解析调用明确、失败不会静默通过；同类片段由单一include/template生成以防翻译漂移。当前只保存静态证据。

### DOC-010 — P3 — TLS 底层 LuaLS 声明与真实 C ABI 相反

- 状态：已确认；逐项对照`lualib/types/silly/tls/{ctx,tls}.lua`、`luaclib-src/ltls.c`导出及高层唯一调用点。本轮不直接调用底层binding。
- 位置：错误ctx签名在`lualib/types/silly/tls/ctx.lua:11-23`，错误handshake返回声明在`lualib/types/silly/tls/tls.lua:22-25`；真实实现分别在`luaclib-src/ltls.c:222-234,398-445,611-648`，正确调用在`lualib/silly/net/tls.lua:37,197-208,326-339`。
- 触发：编辑器用户依据类型声明直接调用`silly.tls.ctx.server(cert_file,key_file,ca_file)`，或把`tls:handshake()`按boolean分支判断。
- 影响：server第一参数实际必须是`{ {cert=PEM内容,key=PEM内容}, ... }`，第二、三参数分别是cipher string与wire-format ALPN；照声明传路径字符串会把字符串长度当证书数量并逐字节取“entry”，随后异常。handshake实际第一返回值是三态整数`1/0/-1`，而Lua中的`0`和`-1`均为真；按声明写`if ssl:handshake() then`会把明确失败和需要继续IO都当成功，继续在未建成TLS通道上处理应用协议。
- 证据：`lctx_client`完全不读取参数；`lctx_server`对参数1执行`luaL_len/lua_geti`，参数2执行`SSL_CTX_set_cipher_list`，参数3作为已编码ALPN字节串保存。`ltls_handshake`明确压入integer 1（成功）、-1（WANT_READ/WANT_WRITE）或0（错误）；高层封装也用`HANDSHAKE_OK=1/HANDSHAKE_ERROR=0`精确比较，未按boolean消费。
- 根因：LuaLS stub仍保留旧的“文件路径加载”与二态握手接口，native接口改为内存PEM、ALPN和异步三态后没有同步契约或自动校验。
- 建议解法：将底层模块标记为internal并准确声明：client无参数，server接收PEM entry数组/cipher/wire ALPN，handshake返回`1|0|-1`及`string|silly.errno|nil`；最好用命名常量或枚举封装三态，避免任何boolean误用。由导出函数签名或共享schema生成stub，避免继续漂移。
- 回归测试：修复阶段增加LuaLS静态fixture，覆盖server参数shape及handshake三态穷举；再加文档/API lint对照唯一高层调用，确保底层stub不会建议文件路径或boolean分支。当前只保存静态证据。

### DOC-011 — P3 — TLS 指南虚构自动 session resumption 与 0-RTT 收益

- 状态：已确认；双语性能章节、完整TLS binding与OpenSSL官方session-cache/early-data契约交叉核对。本轮不建立TLS连接。
- 位置：错误承诺在`docs/src/{en/,}guides/tls-configuration.md:726-743`；client ctx/open/handshake/write全部实现在`luaclib-src/ltls.c:222-234,445-482,550-648`，高层每次连接新建SSL对象在`lualib/silly/net/tls.lua:72-94,291-324`。
- 触发：用户依据指南预期重复使用Silly TLS client连接时自动恢复session，或据0-RTT提示设计首包延迟/幂等与重放防护。
- 影响：每个连接都从共享ctx创建全新`SSL*`，实现既不导出/保存`SSL_SESSION`，也不在新连接调用`SSL_set_session`，所以Silly client不能把前一连接的ID/ticket带入下一连接；实际仍执行完整握手。0-RTT还需要显式early-data API及服务端启用额度，当前没有`SSL_write_early_data`、`SSL_read_early_data`或`SSL_CTX_set_max_early_data`，因此性能承诺不可达，也没有指南应同时说明的重放风险。
- 证据：OpenSSL官方[`SSL_CTX_set_session_cache_mode`](https://docs.openssl.org/3.6/man3/SSL_CTX_set_session_cache_mode/)文档说明默认模式是`SSL_SESS_CACHE_SERVER`，并非自动替client挑选旧session；[`SSL_set_session`](https://docs.openssl.org/3.0/man3/SSL_set_session/)正是“set a TLS/SSL session to be used during connect”的客户端入口。官方[`SSL_read_early_data`](https://docs.openssl.org/3.0/man3/SSL_read_early_data/)文档要求client在任何handshake/普通IO前调用`SSL_write_early_data`，server默认不接受early data，必须设置nonzero max early data并以专用读取API消费。仓库对这些符号全量检索为零。服务器OpenSSL默认行为可能允许其他正确实现的client恢复，这不等于Silly自身“自动受益”。
- 根因：指南把OpenSSL具备的协议能力与binding实际开放/编排的能力混写，并把一般TLS 1.3特性直接描述成当前产品优化。
- 建议解法：1.0若不实现，删除“自动”及0-RTT收益，明确当前只建议应用层复用已建立连接；若实现，增加以origin/SNI/ALPN/验证策略隔离且有过期和ticket更新的session cache，显式观测是否恢复。0-RTT必须另设opt-in API、服务端额度、拒绝回退及anti-replay/仅幂等请求规则，不能由普通`write`隐式开启。
- 回归测试：修复阶段用本地stub/受控TLS peer连续握手，断言第二次`SSL_session_reused`与full-handshake计数；0-RTT需分别覆盖accept/reject/replay/非幂等禁用。文档CI检查被宣传的OpenSSL特性至少存在对应binding符号或明确标注“不支持”。当前只保存静态证据。

### DOC-012 — P3 — `http.listen.backlog` 被双语 reference 公开但实现静默丢弃

- 状态：已确认；HTTP公开配置、TCP/TLS wrapper与双语reference逐字段静态核对。本轮不启动listener或制造accept queue压力。
- 位置：双语参数承诺在`docs/src/en/reference/net/http.md:42-56`和`docs/src/reference/net/http.md:41-55`；HTTP transport实现位于`lualib/silly/net/http.lua:10-50`，真实底层参数在`lualib/silly/net/tcp.lua:155-173`与`lualib/silly/net/tls.lua:326-365`。
- 触发：调用`http.listen{addr=...,backlog=N,handler=...}`，无论明文还是TLS；文档明确把该字段列为optional listen queue size。
- 影响：HTTP层构造传给`tcp.listen/tls.listen`的新table时没有`backlog`，底层最终总是采用通用默认256。部署者为突发连接、资源保护或平台限制设置的小/大queue完全不生效且没有错误/告警，压测与上线容量行为偏离配置；读取配置对象也无法发现丢失。
- 证据：`M.listen`明文分支只转发`addr/accept`，TLS分支只转发`addr/certs/alpnprotos/accept`；两种底层listen都明确读取`opts.backlog`并传给`net.tcplisten`。源内HTTP conf LuaLS注解也遗漏backlog，说明文档与wrapper schema同时漂移，而不是底层不支持。
- 根因：HTTP adapter手工重建配置table，新增/已有底层option没有共享schema或逐字段契约测试。
- 建议解法：在HTTP conf注解加入backlog并在两分支显式转发、验证integer/range；更稳妥地由统一listener option mapper处理共享transport字段，TLS专属字段另行allowlist，未知字段报错而非静默忽略。若1.0不支持HTTP级覆盖，则从双语文档删除并明确固定默认。
- 回归测试：修复阶段用stub替换tcp/tls listen，分别断言nil及边界backlog原样到达且invalid值在资源创建前失败；文档/schema lint确保每个公开option有consumer。当前只保存静态证据。

### DOC-013 — P3 — 中文 HTTP reference 虚构默认生效的 `read_timeout`

- 状态：已确认；中英文client配置、LuaLS option schema及完整请求链逐字段静态核对。本轮不连接slow peer或等待超时。
- 位置：中文承诺在`docs/src/reference/net/http.md:254-270`，英文配置表在`docs/src/en/reference/net/http.md:383-404`；真实option定义与构造在`lualib/silly/net/http/client.lua:67-73,191-226`，请求读取在`:278-401`。
- 触发：按中文reference构造`http.newclient{read_timeout=5000}`，或不传该字段并相信文档所称默认5秒，然后访问不结束response headers/body的peer。
- 影响：Lua table的未知字段被静默接受但从不保存或读取，底层`stream:readall()`仍以nil timeout调用，故请求可无限等待。部署者会误以为已有5秒防护而不加外层deadline，容量规划、故障切换和shutdown都建立在不存在的超时上；英文用户看到的配置面又与中文不同。实际无端到端deadline的实现风险已独立记录为`HTTPC-002`，本项记录错误公开承诺。
- 证据：真实`default_opts`和client对象仅有`max_idle_per_host/idle_timeout/alpnprotos`，LuaLS注解同样没有`read_timeout`；构造器只复制这三项。convenience路径在所有redirect hop执行无参数`stream:readall()`，connect/DNS/TLS也未读取client级read timeout。英文reference没有该字段，只有中文明确列出并宣称默认5000ms。
- 根因：翻译版reference保留了未实现或已删除的配置，而动态table构造器没有unknown-option校验；文档与实现schema没有单一来源。
- 建议解法：不要单独补一个只覆盖read的相对timer来伪装完整保护；按`HTTPC-002`建立跨DNS/connect/TLS/redirect/header/body的absolute request deadline与cancel，并明确idle/progress timeout是否另设。实现前从中文文档删除该字段或明确“不支持/无限等待”，构造器对unknown option返回参数错误；中英文配置表由同一schema生成。
- 回归测试：修复阶段增加双语doc/schema lint，逐项断言公开option被构造器消费；deadline实现后分别停在DNS、connect、TLS、header、body和redirect，验证同一预算。另覆盖未知字段、0/负数/边界值在资源创建前失败。当前只保存静态证据。

### DOC-014 — P3 — HTTP 文档把未实现且明确禁用的 HTTP/2 server push 宣称为已支持

- 状态：已确认；双语能力表/guide、H2 SETTINGS、frame dispatch与公开API逐项静态核对。本轮不发送PUSH_PROMISE。
- 位置：双语reference能力声明在`docs/src/en/reference/net/http.md:21-30`与`docs/src/reference/net/http.md:22-30`，中文guide明确“Silly支持”在`docs/src/guides/http-best-practices.md:65-71`；实现禁用/无API的证据在`lualib/silly/net/http/h2.lua:1499-1546,1651-1667`及全部公开`C/S/M`方法。
- 触发：用户依据1.0文档设计/preload资源、寻找push API或预期server可主动建立promised stream；也包括把Silly作为client连接会发送push的peer。
- 影响：server侧没有创建偶数push stream、PUSH_PROMISE编码或应用入口，功能无法使用；client握手明确发送`SETTINGS_ENABLE_PUSH=0`。文档会让架构、性能评估和兼容测试建立在不存在的能力上，且掩盖现有`H2-026`——peer违反禁用设置发送push时client还会错误地静默忽略而非协议拒绝。
- 证据：client initial SETTINGS固定包含`ENABLE_PUSH=0`；`frame_client`没有PUSH_PROMISE handler，`frame_server`收到PUSH_PROMISE直接GOAWAY。channel只允许client本地以奇数id `openstream`，server没有push/open方法，frame builder也没有PUSH_PROMISE。与此相反两份reference逐字列“supports server push”，中文最佳实践进一步标注“Silly 支持”。
- 根因：文档复制HTTP/2一般特性列表，未从当前实现的协商设置与公开API生成能力矩阵，也没有用unsupported feature负向测试约束发布声明。
- 建议解法：1.0若不实现，删除server push承诺并明确“禁用/不支持”，同时按`H2-026`正确拒绝违规peer；若以后实现，必须补偶数stream id、promised request验证、HPACK/state/flow-control/quota、缓存安全策略和application accept/cancel API后再更新能力表。不要把协议理论特性等同产品功能。
- 回归测试：最终文档CI应把能力声明映射到公开symbol、initial SETTINGS和正/负向conformance；当前版本断言广告push=0、无push API且违规PUSH_PROMISE得到connection PROTOCOL_ERROR。当前只保存静态证据。

### DOC-015 — P3 — 双语 HTTP 文档反称 H2 不支持 `write` 并指向不存在的 `close(body)`

- 状态：已确认；双语reference/guide、H2 stream API、flow-control实现和现有测试静态对照。本轮不调用stream方法。
- 位置：双语reference错误说明在`docs/src/en/reference/net/http.md:218-233`与`docs/src/reference/net/http.md:213-228`；双语最佳实践在`docs/src/{en/,}guides/http-best-practices.md:180-211`；真实实现位于`lualib/silly/net/http/h2.lua:805-838,896-1029`，覆盖见`test/testhttp2.lua:290-309,358-609`。
- 触发：用户按文档为H2 response/request做流式发送，看到“HTTP/2不支持write，使用close(body)”后把所有chunks先拼成一个大string，或直接调用文档所写的`stream:close(body)`。
- 影响：stream对象没有`close(body)`发送API（`close`用于资源取消/回收且不接body），照文档调用可能直接变成nil method错误或错误取消；为规避write而聚合大文件/SSE/log输出会丢失真正的流式与flow-control能力，增加峰值内存和首字节延迟。协议版本切换后应用还会维护两套不必要且错误的发送逻辑。
- 证据：`S.write`公开接受data并通过stream/connection window分片等待，`S.closewrite(data,trailer)`才是结束发送的方法；现有H2测试覆盖multiple writes、跨DATA读取及63KiB/connection flow control。文档API标题却限定“HTTP/1.1 only”，note和guide均称H2不支持并写`close(body)`；同页其他示例实际使用`closewrite`，内部自相矛盾。
- 根因：文档保留早期H2一次性发送限制和旧方法名，没有由共享stream接口/LuaLS及protocol-specific capability tests生成；示例按版本分支复制后长期漂移。
- 建议解法：把`stream:write(data)`和`stream:closewrite([data[,trailer]])`定义为H1/H2共同能力，分别说明H1 framing与H2 flow-control/并发约束；删除错误版本分支和`close(body)`，补充每次write返回值必须检查。若产品决定不公开H2 streaming，则实现必须一致拒绝而非文档单方面隐藏，但1.0更合理的是保留现有能力并修复其H2状态问题。
- 回归测试：将reference/guide示例纳入LuaLS/doc test；H1/H2同一handler执行多次write+closewrite，断言方法存在、返回契约一致且大body不先聚合。静态API lint禁止文档引用不存在的方法。当前只保存静态证据。

### DOC-016 — P3 — 中文 reference 与双语 guide 错称 HTTP client 不池化、每次请求新建连接

- 状态：已确认；双语能力说明、全局/专用client构造及H1/H2 pool收放路径静态核对。本轮不建立或复用连接。
- 位置：错误说明在`docs/src/reference/net/http.md:22-30`与`docs/src/{en/,}guides/http-best-practices.md:73-101`，正确英文reference对照在`docs/src/en/reference/net/http.md:21-30`；实现位于`lualib/silly/net/http.lua:6-67`及`lualib/silly/net/http/client.lua:75-204,211-280,417-443`。
- 触发：用户阅读中文reference或任一语言最佳实践，依据“每次请求创建新连接/不支持连接池”评估fd、TLS握手、DNS频率、负载均衡、服务端连接数或client shutdown；使用顶层`http.get/post`也同样被误导。
- 影响：实际顶层API共享模块级`httpc`，H1连接在response完整后归池，H2 channel也长期复用/多路复用。运维可能低估长寿命连接和idle fd、误判DNS/endpoint变化生效时间，或额外自建一层池造成资源与生命周期复杂化；测试/性能结论会与文档模型相反。已有pool泄漏、close竞态及GOAWAY问题也更容易因用户不知道池存在而难以诊断。
- 证据：`http.lua`加载时执行`local httpc=client.new()`，所有顶层get/post/request转发给同一对象；`find_conn`先查H2/H1 pool，H1 `releaseh1`回插、H2 channel创建即入pool，idle timer统一淘汰。`newclient`还公开max-idle/idle-timeout选项。英文reference明确承认两协议自动pool，证明其他文档不是有意描述另一API。
- 根因：中文/reference与guide保留旧transport模型，且同一能力事实在多个手写页面重复维护，没有由client option/schema和pool tests生成。
- 建议解法：统一声明顶层singleton与`newclient`都池化，并解释H1顺序复用、H2多路复用、idle/max配置、DNS/TLS identity key和`client:close()`责任；若顶层singleton无法显式close，也需说明进程级生命周期。删除“每次新建”示例注释，双语内容从同一能力表生成。
- 回归测试：文档契约测试以stub connector计数连续H1/H2请求的建立次数、完整/错误body后的复用与close淘汰，并静态比较中英文能力表；不把本库client/server互测当协议正确性证明。当前只保存静态证据。

### DOC-017 — P2 — 双语 HTTP/2“最佳实践”示例实际启动明文 HTTP/1.1

- 状态：已确认；双语示例、HTTP transport选择、TLS ALPN配置与H2 accept分派静态核对。本轮不启动示例listener或发起连接。
- 位置：错误示例与能力承诺在`docs/src/{en/,}guides/http-best-practices.md:33-72`；transport选择在`lualib/silly/net/http.lua:10-48`；TLS server ALPN仅按显式配置构造在`lualib/silly/net/tls.lua:326-365`。双语reference的正确警告可见`docs/src/{en/,}reference/net/http.md:41-56`。
- 触发：用户复制“配置HTTP/2（HTTPS）”示例，仅提供addr/certs/handler；或只意识到遗漏`tls=true`并补上它，却仍未配置服务端`alpnprotos`。
- 影响：原样示例因`conf.tls`为nil直接调用`tcp.listen`，证书完全不读取，8443端口实际提供明文HTTP/1.1。部署者可能在误以为HTTPS已启用时发送cookie、token和业务数据，形成真实的传输机密性/完整性暴露。只补`tls=true`后，server context仍没有ALPN列表，accept无法得到`"h2"`并落入H1，因此示例标题、打印的协议候选和性能结论仍不可达。
- 证据：`http.listen`唯一分支条件是`if not conf.tls then tcp.listen`；`certs`是否存在不影响选择。TLS分支原样传`conf.alpnprotos`，`new_server_ctx`仅在该table存在时构造wire ALPN，不提供H2默认值。accept也只在`conn:alpnproto()=="h2"`时调用`h2.httpd`。测试中的H2 server明确同时设置`tls=true`与`alpnprotos={"h2"}`，而双语指南两项均缺失；同仓reference已明确“certs必须配tls=true”，证明不是有意的隐式模式。
- 根因：安全/协议启用项是三个彼此独立的动态table字段，但指南把“给证书”误写为隐式启用TLS和ALPN；示例没有通过配置schema或断言实际协商协议的文档测试。
- 建议解法：示例至少显式加入`tls=true`与`alpnprotos={"h2","http/1.1"}`，检查listen返回值，并说明顺序/选择策略；所有双语说明统一声明certs本身不会启用TLS、未协商h2会回退H1。产品层可考虑在提供certs但`tls~=true`时fail closed，或为HTTP TLS server给出文档化安全ALPN默认，但不能静默明文。
- 回归测试：修复阶段把双语示例提取为配置契约测试，以stub断言选择tls.listen且certs/ALPN被转发；独立client验证协商h2并实际得到`stream.version=="HTTP/2"`。另覆盖certs无tls时参数错误、TLS无ALPN时明确H1/failure策略，防止安全示例再次漂移。当前只保存静态证据。

### DOC-018 — P2 — WebSocket 教程的消息大小检查发生在无界缓冲之后，不能防止其声称的内存耗尽

- 状态：已确认；双语安全建议与WebSocket frame/message读取数据流的确定性静态对照。本轮不发送大frame或无限fragments。
- 位置：双语教程把应用层检查描述为“防止恶意大消息”，见`docs/src/{en/,}tutorials/websocket-chat.md:1839-1864`；完整frame读取与fragment聚合在`lualib/silly/net/websocket.lua:51-95,139-176`，公开API没有size option，详见既有`WS-005`。
- 触发：部署者照教程在`local data,typ=sock:read()`成功返回后检查`#data > 10240`；恶意peer先声明巨大单帧长度并缓慢发送，或发送总量无界、最后才置FIN的fragment序列。
- 影响：10 KiB判断只会拒绝已经完整驻留Lua内存的结果。单帧路径在检查前要求底层收齐wire length，fragment路径在检查前保留每段并最终`table.concat`再分配完整消息；进程可在进入示例判断前已经OOM、长时间GC或被大量连接耗尽。教程将事后业务校验包装为资源防护，容易让1.0部署错误认为已设置协议输入预算。
- 证据：`read_frame`把未设上限的64-bit payload直接传给`conn:read(payload)`；`s.read`直到FIN才concat并返回。教程示例只能观察返回后的`data`，既不能在header后拒绝frame，也不能在每段累积前中止，而且`websocket.connect/upgrade/newsocket`均没有`max_frame_size`或`max_message_size`入口。连接数限制同样在upgrade已完成后执行，但本条只记录明确标为消息大小防护的错误承诺。
- 根因：文档把应用语义层的post-read长度校验误当成transport/protocol层的admission limit，没有核对异步API返回前的缓冲所有权与分配顺序。
- 建议解法：先按`WS-005`在WebSocket parser中提供有安全默认值、可配置的frame/message上限，并在读取payload及追加fragment之前检查；教程显式把这些选项配置在listener/upgrade或socket创建处。返回后的`#data`检查可以保留为房间业务上限，但必须说明它不承担内存DoS防护。
- 回归测试：修复阶段让文档示例使用真实size配置，并以注入式reader覆盖header声明超限但payload未到、许多小fragment累计越界及恰好边界；断言在分配/拼接超限内容前终止并释放stash。双语代码块做同一schema检查。本轮不执行示例或构造流量。

### DOC-019 — P3 — WebSocket 双语 reference 的 read/close 返回契约与实现不一致

- 状态：已确认；双语reference、LuaLS注解和所有公开return路径逐项静态对照。本轮不调用WebSocket API。
- 位置：错误契约位于`docs/src/{en/,}reference/net/websocket.md:160-224`；实现位于`lualib/silly/net/websocket.lua:51-95,139-223`，相关非法fragment行为另见`WS-004`、close状态另见`WS-007`。
- 触发：调用方按文档在read失败后使用第三返回值恢复partial frame/message、把`"continuation"`作为正常完整消息类型分派，或期望`close()`没有可检查的结果；封装层和LuaLS也会据此声明错误签名。
- 影响：reader的第三返回值在全部错误路径都固定为`""`，底层已经缓冲的partial header/payload不会交付，故应用无法实现文档暗示的恢复。合法fragment chain只会以首帧的`text/binary`类型完整返回；`continuation`仅因`WS-004`错误接受standalone continuation才可见，把它写入正常类型集合会固化协议偏离。反向上，`close()`真实返回底层`boolean,error`但文档写“无返回值”，调用方无法按契约观察close失败；它还会误以为与其他资源close的result API不同。
- 证据：`read_frame`每个短读/error只返回nil、error和空串，`s.read`又无条件返回`nil,op,""`，从没有返回已消费或底层缓存的partial bytes。正常FIN=0首帧保存`stashtype`，final continuation后返回该首类型；只有无stash的opcode 0被当前错误状态机直接映射为`continuation`。`s.close`有明确`---@return boolean,string?`并执行`return ok,err`，双语页面却都列Returns/返回值为None/无。
- 根因：reference按理想化frame API手写，未从真实LuaLS签名及状态机结果集合生成；协议层“frame type”和公开层“complete message type”也被混用。
- 建议解法：文档只声明真实且稳定的结果：read成功返回完整`text/binary`或明确的control event，错误返回`nil,error`，除非未来实现可证明partial归属的流式API；删除正常`continuation`类型。先决定`close`是否应返回result并与`WS-007`的幂等/handshake结果统一，再同步双语签名和LuaLS。
- 回归测试：修复阶段用API contract test枚举read的EOF、header/payload短读、合法fragment和非法standalone continuation，并检查返回值数量/类型；覆盖close成功、已关闭和底层失败。CI比较双语reference、LuaLS annotation与导出函数签名/枚举。本轮不执行调用。

### DOC-020 — P3 — WebSocket 双语教程的广播优化调用不存在的 channel `recv/send` 方法

- 状态：已确认；双语教程示例与`channel`完整导出面静态对照。本轮不运行教程代码。
- 位置：错误调用位于`docs/src/{en/,}tutorials/websocket-chat.md:1866-1889`；实际channel方法全集在`lualib/silly/sync/channel.lua:11-94`，正确用法也已出现在WebSocket reference较早的广播示例中。
- 触发：用户复制“广播优化/Broadcasting Optimization”代码，创建`channel.new()`，让fork task执行`broadcast_chan:recv()`，并在消息处理侧执行`broadcast_chan:send(...)`。
- 影响：channel对象既没有`recv`也没有`send`字段。consumer第一轮即抛`attempt to call a nil value (method 'recv')`并退出；producer首次投递也会独立抛同类`send`异常。教程声称的异步广播完全不工作，处理连接的业务task还会因投递异常中止。
- 证据：channel metatable的`__index`表只定义`new`以外的`push/pop/clear/close`，仓库没有任何`channel.recv/send`别名；WebSocket reference中的广播服务器正确使用`broadcast_chan:pop()`和`:push(...)`，证明教程末尾不是另一种受支持API。双语文件逐字复制了两个错误，且该教程没有`lua validate`代码块，现有doc检查无法发现unknown member。
- 根因：示例混用了其他channel库的`recv`命名，复制翻译后没有通过LuaLS或最小doc-test验证。
- 建议解法：两种语言统一改为consumer的`local msg,err=broadcast_chan:pop()`及producer的`local ok,err=broadcast_chan:push({...})`，两侧都处理channel关闭错误；同时检查`broadcast`参数与前文消息结构一致。将教程Lua块标为可抽取验证，启用LuaLS unknown-member检查。
- 回归测试：修复阶段提取双语该代码块，用stub producer push一条消息并关闭channel，断言consumer恰好调用一次broadcast后有限退出；静态检查不得再出现未导出的channel方法。本轮不执行示例。

### DOC-021 — P2 — WebSocket 教程用稀疏连接表的长度运算实施资源上限，断开后可无限低估在线数

- 状态：已确认；教程连接表生命周期与Lua 5.4 table length语义的确定性静态对照。本轮不建立连接或执行示例。
- 位置：`clients[next_id]`单调分配及断开删除在`docs/src/{en/,}tutorials/websocket-chat.md:150-202,225-304,574-878`；在线统计多次使用`#clients`，安全建议又在`:1839-1851`用同一表达式执行`MAX_CLIENTS` admission。
- 触发：至少一个非尾端client断开使整数key集合产生hole；由于`next_id`只递增且不复用，之后表长期不是1..n连续sequence。新连接继续用`if #clients >= MAX_CLIENTS`判断容量。
- 影响：Lua对带hole表的`#`只返回某个边界而非元素数量，结果可能远小于实际在线数；连接限制因而可持续放行超过1000个连接，不能实现教程声称的“防止资源耗尽”。欢迎消息、join/leave payload、server stats和日志也会报告错误人数，监控和管理判断失真。攻击者可通过反复连接/断开制造hole后扩大低估。
- 证据：教程把`clients`作为以永不回退`next_id`为key的map，并以`clients[id]=nil`删除；没有独立`client_count`。Lua sequence length不等于`pairs`可见元素数，尤其key 1断开后即不存在任何“当前人数等于#clients”的保证。安全段原样复用`#clients`，也没有遍历计数或原子admission counter；双语版本一致。
- 根因：把array sequence的长度运算用于稀疏ID map，并让展示统计与资源admission共享同一个不成立的派生值。
- 建议解法：维护显式`client_count`，只在成功注册时加一、所有幂等移除路径恰好减一；在upgrade/分配业务状态前以同一admission owner检查上限并拒绝。也可用独立slot allocator，但不能每次遍历或`#map`承担并发 admission。所有展示统一读取同一计数器。
- 回归测试：修复阶段按连接1/2/3、断开1/2、继续分配4..N的序列核对count与`pairs`元素数；在上限前后及重复cleanup/发送失败清理交错下断言从不超额、计数不负且统计一致。双语示例共用同一测试。本轮不运行连接场景。

### DOC-022 — P2 — WebSocket 完整聊天室把远端昵称写入 `innerHTML`，20 字节限制仍可形成跨用户脚本执行

- 状态：已确认；双语完整server/client数据流与DOM sink的确定性静态对照。本轮不打开浏览器或发送payload。
- 位置：server接受/广播昵称在`docs/src/{en/,}tutorials/websocket-chat.md:779-805`；完整HTML client把sender和user name拼入`innerHTML`在`:1429-1479`，已有escape helper仅用于content/system text在`:1439-1457,1512-1517`；图片练习另有未验证URL sink在`:1706-1727`。
- 触发：任一连接发送`set_name`，昵称为可执行HTML。server只要求非空且`#new_name <= 20`；例如ASCII字符串`<svg/onload=alert()>`恰好20字节。之后该用户出现在在线列表或发送message/private message，使其他browser client渲染昵称。
- 影响：受害者页面用HTML parser创建攻击者控制的元素和event handler，可执行任意同页JavaScript；在实际部署origin下可读取页面可访问的数据、冒用WebSocket会话发送消息、篡改UI或向外传输token。昵称是server保存并广播的状态，故一次设置可影响多名当前/后续用户，属于聊天室内的存储型跨用户XSS。20字符限制和正文转义会给读者造成已处理输入安全的错觉，但不阻止该payload。
- 证据：`addMessage`模板只对`${content}`调用`escapeHtml`，`${sender}`原样进入`<span>`；`updateUserList`把`${user.name.substring(...)}`和`${user.name}`两次原样插入`userDiv.innerHTML`。server的长度检查后直接保存name并通过user list/message metadata广播，没有HTML normalization。exercise的图片URL也原样拼进quoted `src`属性，说明DOM构造策略在扩展功能中继续重复。
- 根因：把远端业务字段和HTML模板字符串混合，并只对某个字段做黑盒式局部转义；server输入长度被错误当成输出上下文安全策略。
- 建议解法：client使用`createElement`并对所有远端text赋`textContent`，不把昵称/消息/错误拼入`innerHTML`；图片使用`URL`解析、限定`https:`/允许域并以DOM property赋值，必要时使用可信的CSP。server仍应按产品规则验证Unicode长度和昵称字符，但不能替代每个输出上下文的编码。教程显式加入安全说明。
- 回归测试：修复阶段将昵称、sender、message、error和image URL分别输入HTML标签、attribute quote、entity、SVG/event payload及普通Unicode；断言DOM只产生文本或允许的安全元素、无event attribute/脚本执行。双语完整示例与扩展代码纳入浏览器安全doc-test。本轮不执行payload。

### DOC-023 — P2 — WebSocket 教程把浏览器可选 Ping 当作自动心跳，server 没有主动探测或失联 deadline

- 状态：已确认；双语教程与WHATWG WebSockets Standard控制帧/API契约静态对照。本轮不启动浏览器或等待失联连接。
- 权威依据：[WHATWG WebSockets Standard §5](https://websockets.spec.whatwg.org/#ping-and-pong-frames)说明Ping/Pong不暴露给浏览器WebSocket API；user agent可以按自身需要发送，但不得用它帮助server，标准明确假定server在需要时自行solicit Pong。可选实现行为不能成为应用心跳保证。
- 位置：教程server只在收到ping后回pong，见`docs/src/{en/,}tutorials/websocket-chat.md:759-863`；随后在`:1642-1652`把它命名为心跳保活并断言浏览器会自动发送ping。公开WebSocket socket没有read deadline，既有连接/消息deadline缺口见`WS-005/010`。
- 触发：浏览器/user agent不主动发送protocol Ping，或只为自己的NAT/latency策略偶尔发送；网络发生half-open、客户端休眠/断网但TCP没有及时产生close event。教程server持续阻塞于`sock:read()`。
- 影响：所谓“心跳保活”没有周期、server-initiated challenge、Pong correlation或deadline，无法检测silent peer。失联连接继续留在`clients`表并占用socket、coroutine及广播遍历成本；连接数和在线列表均可能长期包含幽灵用户。不同浏览器/网络环境下表现不一致，部署者会错误依赖一个标准不保证的客户端行为。
- 证据：完整browser client只创建`new WebSocket`并收发JSON，没有application heartbeat；browser API也不能由页面发送protocol Ping。server循环只有在远端先发opcode 9时才回Pong，且从不主动`sock:write(...,"ping")`、记录nonce/time或使read有界。页面的自动重连只能在`onclose`触发后工作，不能检测未产生close event的half-open。
- 根因：混淆了协议要求“收到Ping必须回Pong”和应用为自身健康检查“主动发Ping并等待Pong”，又把user-agent MAY行为写成必然。
- 建议解法：教程改为server周期性发送带nonce/timestamp的Ping，记录last-pong并在absolute deadline后关闭/移除连接；或设计application-level heartbeat并让browser JS定期发送，同时说明它是text消息而非protocol Ping。心跳task、reader和close必须有单一owner，避免并发read；停止/异常时取消timer。删除浏览器自动Ping保证。
- 回归测试：修复阶段用可控clock覆盖及时Pong、错误payload、无Pong、只有业务data、browser tab休眠及close竞态；断言健康连接保留、silent连接在deadline后恰好清理、timer/task无泄漏。文档契约检查禁止再把user-agent MAY写成保证。本轮不运行时序场景。

### DOC-024 — P2 — WebSocket 完整server不验证 JSON schema，合法非对象输入可绕过连接清理并累积幽灵client

- 状态：已确认；双语完整server、JSON decoder返回域与HTTP handler异常收尾的确定性静态对照。本轮不发送JSON或建立连接。
- 位置：直接decode与字段访问在`docs/src/{en/,}tutorials/websocket-chat.md:759-863`，client登记/正常清理在`:727-736,865-878`，错误处理承诺在`:1635-1640`；JSON公开返回域/实现见`lualib/types/silly/encoding/json.lua:15-18`与`luaclib-src/encoding/ljson.c:409-455,540-591`；HTTP/1 handler保护边界在`lualib/silly/net/http/h1.lua:872-890`。
- 触发：已upgrade的远端发送合法JSON primitive，例如数字`1`或布尔值，随后代码求值`msg.type`；也可发送`{"type":{}}`走到错误字符串拼接，或`{"type":"set_name","name":1}`触发长度运算错误。输入无需畸形JSON。
- 影响：Lua抛类型异常并跳过教程handler尾部的`clients[client_id]=nil`、`sock:close()`、leave广播及计数收尾。HTTP/1外层pcall会关闭底层连接，却不知道教程业务registry，故`clients`永久保留引用已关闭socket的幽灵entry；攻击者重复新连接/单消息可持续增长map和错误在线列表，并放大`DOC-021`的失效admission。当前连接的业务task异常退出，教程所谓无效消息错误响应也不可达。
- 证据：`json.decode`成功可以返回number/string/boolean/table，LuaLS却错误收窄成table；教程只判断`if not msg or not msg.type`，在访问`.type`前没有`type(msg)=="table"`。各字段也没有schema/type验证。页面声称“JSON解析错误使用pcall捕获”，实际唯一pcall是`safe_json_encode`，两处decode都直接调用。H1外层捕获异常后只清理stream/transport并break，不会执行已经展开退出的业务handler清理。
- 根因：把JSON语法成功等同于应用message schema成功，并把业务资源cleanup放在可能抛异常的loop之后；文档又误报了不存在的decode保护。
- 建议解法：decode后同时检查`err`、顶层type及每种message的严格field schema/长度，再进入业务分支；所有拼接/格式化前约束string/number。用幂等`remove_client`和保护性finally/`<close>` owner保证任何decode、handler或send异常都清registry、socket和计数。文档只宣称实际存在的错误处理。
- 回归测试：修复阶段覆盖全部JSON primitive、array、null、缺type、type为table/number、每个字段错型及decoder error；断言返回受控error或关闭策略、handler不抛、registry/count恢复基线且leave只通知一次。再注入branch内部异常验证finally。本轮不执行输入。

### DOC-025 — P3 — WebSocket 双语入门示例记录不存在的 `sock.fd`，断线诊断恒为 nil

- 状态：已确认；双语教程代码、WebSocket socket公开字段与底层transport字段逐项静态对照。本轮不运行教程或建立连接。
- 位置：错误日志位于`docs/src/{en/,}tutorials/websocket-chat.md:94-99`；WebSocket socket构造与LuaLS字段在`lualib/silly/net/websocket.lua:123-134,261-277`，底层fd实际属于其package-private `conn`。
- 触发：用户复制第一个echo server；任意`read()`错误使代码执行`print("客户端断开:", sock.fd, typ)`。
- 影响：WebSocket socket从未定义或转发`fd`，Lua读取缺失字段只得到nil，因此每次断线日志都丢失其声称要输出的连接标识。并发连接发生EOF、reset或协议错误时，运维者无法把日志关联到具体连接；示例还会让调用者误以为`fd`是稳定的公开API，并在业务代码中依赖它。
- 证据：`newsocket`只设置`conn/stream/rmask/wmask/stashtype/stashbuf`，方法表也没有`fd` getter；唯一fd位于`sock.conn.fd`，但`conn`被标为package字段且close后被置nil，不适合作为公开身份契约。中英文教程在同一行复制了该访问，现有`testwebsocket.lua`没有执行教程代码或断言日志字段。
- 根因：教程沿用了TCP socket的直接字段习惯，没有按WebSocket wrapper的实际公开面更新，也没有经过unknown-field文档检查。
- 建议解法：不要暴露或打印裸OS fd作为应用身份；示例在accept/upgrade后生成并保存稳定的`client_id`或记录`stream.remoteaddr`，断线时输出该值。若产品确实需要连接标识，应设计明确、只读且close后仍稳定的公开字段，并同步LuaLS/reference，而不是让教程穿透`conn`。
- 回归测试：修复阶段提取最小教程代码做LuaLS unknown-field检查，并以stub socket触发read错误，断言日志包含显式client id/remote address且不访问package字段；双语代码块保持结构一致。本轮不执行示例。

### DOC-026 — P3 — gRPC 双语 reference 混用三种 streaming API，示例调用不存在的方法并取消上传

- 状态：已确认；双语reference全部streaming代码块、动态method constructor与H2 close语义逐项静态对照。本轮不运行文档示例或RPC。
- 位置：统一但错误的`StreamMethod/read/write/close`说明在`docs/src/{en/,}reference/net/grpc.md:397-638`，client-stream upload示例在`:461-519`，server-stream完整示例在`:1139-1211`；真实对象方法集合在`lualib/silly/net/grpc/client/service.lua:95-132,178-257`，server wrapper在`grpc/registrar.lua:116-154`。
- 触发：读者复制upload示例写完chunks后调用`stream:close()`；或复制server-stream示例，调用`client:Subscribe()`后再`stream:write(...)`，server handler以`return {event...}`提供输出。遗漏`service_name`的更早失败已由`DOC-004`记录，本条描述修正它后仍必现的独立错误。
- 影响：client-stream的`close()`走H2 RST CANCEL，不会发送正常request EOS，也不读取唯一response，server可能已消费部分chunks却只看到取消，文件/批处理留下部分副作用。server-stream client对象只有`read/close`，首次`write`即抛nil-method；它本应在method调用时传唯一request。server handler也必须通过第二参数stream逐条write，示例返回table却被wrapper当成error对象并最终发UNKNOWN。文档宣称四类streaming可用但关键示例不能完成一次调用。
- 证据：`cs`方法为`write/closewrite/read/close`，`ss`只有`read/close`，`bs`才同时read/write。`stream_close`直接调用H2 `close`，已发送header/data时该方法发CANCEL reset；它不等价于`closewrite`。`sstreaming(self,req,timeout)`立即编码并END_STREAM发送req，然后返回只读`ss`；示例省略req使helper用空table编码，再调用不存在的write。server `local ok,err=pcall(fn,req,s)`会把示例返回table放入err分支，而不是输出message。
- 根因：reference用一个理想化“全双工stream”模板描述client-stream/server-stream/bidi三种不同半边能力，并把连接销毁、request half-close与RPC final read混为同一close动作；代码块未按descriptor cardinality做静态检查。
- 建议解法：拆成三套精确签名和示例：server-stream=`Method(req,timeout?)→{read,close}`；client-stream=`Method()→{write,closewrite,read,close}`；bidi=`Method()→{write,closewrite,read,close}`。upload必须检查每次write、调用closewrite、读取唯一response/status再close；server-stream在构造时传req且只read，server handler用第二参数`out:write`并返回nil/error。同步说明read timeout实际限制，依赖`GRPC-012`修复。
- 回归测试：修复阶段抽取双语三类示例，按生成descriptor做LuaLS方法集合检查并以stub记录调用序列；断言无不存在的方法、正常路径产生request EOS而非RST、client-stream消费final response、server-stream逐条输出且status OK。当前不执行示例。

### DOC-027 — P1 — MySQL 指南对任意断线 SQL 自动重放，结果未知的写入可被重复提交

- 状态：已确认；指南代码、driver错误边界与MySQL官方重连警告静态核对。本轮不执行写SQL或注入断线。
- 权威依据：[MySQL Connector/J troubleshooting](https://dev.mysql.com/doc/connector-j/en/connector-j-usagenotes-troubleshooting.html)明确指出通信失败后没有安全的透明重连/重发方法，transaction和database state可能损坏；[MySQL C API automatic reconnect](https://dev.mysql.com/doc/c-api/8.0/en/c-api-auto-reconnect.html)也说明重连会丢失transaction、temporary table、prepared statement、session variable、lock等连接状态且该功能已弃用。
- 位置：双语连接池指南“重连机制/实现自动重连”的`DBPool:query`在`docs/src/guides/mysql-connection-pool.md:579-686`与`docs/src/en/guides/mysql-connection-pool.md:579-686`；双语通用错误处理指南又提供对2006/2013错误循环调用同一任意SQL的`safe_query`，见`docs/src/{en/,}guides/error-handling.md:500-550`。底层query在请求写出后任一response read失败只返回transport错误，见`lualib/silly/store/mysql.lua:876-945`。
- 触发：应用照抄wrapper执行INSERT/UPDATE/DELETE、DDL或调用procedure；server已执行/提交该statement，但OK/result在返回途中丢失，driver返回包含`Lost connection`或`MySQL server has gone away`的错误文本。
- 影响：示例关闭整个pool、重连并最多三次无条件重发相同SQL。非幂等写可重复扣款、发号、追加记录、触发器/outbox事件或DDL副作用；如果第一次仍在旧server session执行，新连接重放还可并发产生两份结果。与此同时session/temporary table/lock状态已丢失，重放即使只执行一次也未必保持原语义。指南把这种危险行为包装成通用自动恢复，属于1.0数据一致性release blocker。
- 证据：连接池guide的retry入口只按英文message substring分类连接错误，不区分SQL类别、packet是否写出、server是否已执行、autocommit/transaction状态或幂等键；`self:reconnect()`成功后loop直接再次`self.pool:query(sql,...)`。错误处理guide虽注释“这里可以重新创建连接池”，实际无论是否重建都会继续下一轮`db:query(sql,...)`，且`safe_query`同样接受所有SQL。两处都没有outcome-unknown结果、stable operation ID、transaction compare或read-only allowlist。driver本身没有自动重放，风险完全由官方指南新增。
- 根因：把“下一次新操作使用新连接”与“重放结果未知的上一操作”混成同一个retry loop，并假设transport failure等价于server未执行。
- 建议解法：删除通用SQL自动重放示例；连接失败后淘汰旧pool/connection只供**后续**操作使用，本次调用返回结构化`outcome_unknown`。只允许在可证明write前失败或调用方明确标记幂等read时自动重试；写操作必须由业务使用唯一请求ID/unique constraint、幂等表或可验证transaction设计，并显式处理session state丢失。
- 回归检查：文档测试建立read-only重试与unknown-write两条API示例，并扫描全部guide禁止通用SQL retry wrapper；修复阶段在write前、server execute前、commit后OK前分别断链，只有第一类可透明重试，后两类向调用方暴露不确定结果且数据库最多出现一次业务效果。当前不执行SQL或fault injection。

### DOC-028 — P3 — MySQL 双语示例广泛调用不存在的 runtime API，预热、监控和关闭首次运行即失败

- 状态：已确认；MySQL双语reference/guide与真实module export逐项静态核对。本轮不运行文档代码。
- 位置：reference健康检查与性能章节在`docs/src/{en/,}reference/store/mysql.md:732-785,1452-1647`；连接池guide的优雅关闭、预热、活跃连接、错误率、监控面板与慢查询在`docs/src/{en/,}guides/mysql-connection-pool.md:726-748,884-1120,1175-1200`；数据库教程性能监控在`docs/src/{en/,}tutorials/database-app.md:1187-1207`。六份文件合计60行使用不存在的`silly.wait`、`silly.sleep`或`silly.time.now`，多个standalone块还未导入`task/time`。真实顶层export在`lualib/silly.lua:1-39`，睡眠/时间API属于`silly.time`，并发join应使用`waitgroup`。
- 触发：读者复制reference的生产连接池健康检查，或guide中任一“预热连接池/监控指标”示例；这些块被作为可直接使用的完整代码展示。
- 影响：reference首次走到30秒暂停即抛`attempt to call a nil value (field 'sleep')`，后五个标记为`lua validate`的performance示例都在首次计时失败；guide预热在`task.fork`处就因全局task为nil失败，即使补import也在`silly.wait`失败。监控和tutorial示例同样在fork、time或首次sleep失败，无法建立文档承诺的连接、等待任务或采样。所谓优雅关闭还调用`signal.signal`，首次注册即因索引函数值失败；即使改成直接调用，`"INT"`也不是模块支持的`"SIGINT"`，handler不会安装。reference另在health task未join时由外层关闭pool，使修正函数名后仍会让后台task访问已关闭对象。
- 证据：`require "silly"`只导出pid/version/register/exit等runtime入口，没有`wait`、`sleep`或`time`字段；`task.fork`返回coroutine，但没有公开的thread join，正确组合原语是`waitgroup:fork/wait`。`require "silly.signal"`直接返回`signal(sig,fn)`函数而不是table，且signal map使用`SIGINT`。guide多个代码块未`require "silly.task"`/`silly.time`，并把local loop变量命名为`task`进一步混淆module；错误处理guide的MySQL连接/死锁块也分别遗漏`task`或`time`导入。中英文文件逐行复制大部分错误，因此不是单一翻译笔误。
- 根因：文档把多个module的API聚合到想象中的`silly` façade，并用裸thread list模拟join；代码围栏只做语法展示，没有unknown-member/standalone import或生命周期检查。
- 建议解法：所有示例显式`local task=require "silly.task"`、`local time=require "silly.time"`并调用`time.sleep/time.now`；预热改用`waitgroup:fork/wait`，健康检查保存stop/join owner并在pool close前结束；信号示例改为`local signal=require "silly.signal"; signal("SIGINT", fn)`并通过runtime退出流程完成有界shutdown。将所有`lua validate`块加入最小stub/LuaLS执行检查，禁止未声明global和不存在member。
- 回归检查：逐个提取双语MySQL代码块，在stub pool上推进一次fork/sleep/wakeup/signal/close，断言无unknown member/global、SIGINT handler实际安装且关闭发生在background task结束后；中英文调用序列保持一致。当前不执行示例。

### DOC-029 — P3 — MySQL 双语 reference 错称 row 列名会转小写，实际 alias 大小写原样保留

- 状态：已确认；公开row契约、column definition decoder与测试alias静态核对。本轮不执行查询。
- 位置：中英文row数据类型说明在`docs/src/reference/store/mysql.md:555-568`与`docs/src/en/reference/store/mysql.md:555-568`；column alias取值和row key写入在`luaclib-src/mysql/lmysql.c:217-257,431-471`；现有integration tests的alias几乎全为小写，见`test/testmysql.lua:438-1472`。
- 触发：SQL返回包含大写或混合大小写label，例如`SELECT 1 AS UserID`，调用方依据文档以`row.userid`访问。
- 影响：decoder实际创建`row.UserID`，文档所示的小写key不存在并返回nil；Lua读取缺失字段不报错，业务可把真实非NULL结果误当作缺失/NULL。ORM映射、JSON序列化和跨数据库代码若依赖文档的大小写规范会静默丢字段；重复alias的覆盖问题另由`MYSQLC-006`覆盖。
- 证据：`lparse_column_def`把wire上的column alias bytes直接保存到definition，没有`tolower`或collation处理；`lparse_row_data_binary`再原样取该string并`lua_settable`。Lua层没有后处理。双语文档唯一明确契约却写“列名（小写）/Column names (lowercase)”，测试未使用混合case来暴露偏差。
- 根因：文档把部分server/query常见的小写alias当作client归一化行为，而实现选择保留wire label且没有定义collision/case策略。
- 建议解法：优先修正文档为“key是server返回的column label，大小写原样保留”，建议业务显式稳定alias；若要提供lowercase模式，必须是显式option并处理两个label折叠到同一key的collision，不能静默覆盖。
- 回归检查：使用`lower`、`UPPER`、`MixedCase`及只按case不同的两个alias核对返回key集合；默认精确保真，任何可选归一化遇collision明确报错/返回ordinal values。当前不运行SQL。

### DOC-030 — P1 — MySQL 双语转账教程用非锁定读校验余额，且零行到账仍提交扣款

- 状态：已确认；双语教程、扩展错误处理示例、driver返回结构与InnoDB锁语义静态核对。本轮不执行转账或并发事务。
- 权威依据：[MySQL InnoDB locking reads](https://dev.mysql.com/doc/refman/26.7/en/innodb-locking-reads.html)说明读取后再更新的数据必须使用`SELECT ... FOR UPDATE/FOR SHARE`等锁定读；[consistent nonlocking reads](https://dev.mysql.com/doc/refman/26.7/en/innodb-consistent-read.html)说明普通`SELECT`是consistent nonlocking read，不会给读取记录加锁。
- 位置：中英文数据库教程把该段明确称为“需要保证一致性/operations requiring consistency guarantees”的事务示例，见`docs/src/{en/,}tutorials/database-app.md:909-970`；中文错误处理指南的扩展示例在`docs/src/guides/error-handling.md:1006-1076`重复相同的非锁定余额检查。OK packet公开包含`affected_rows`，教程其他CRUD示例也会检查它，但这里仅把非nil result当作成功。
- 触发：同一源账户余额100，并发开始两笔各80的转账；两事务的普通`SELECT`都可读到100并通过检查，之后各自执行原子减法并提交。另一路径是`to_id`在检查后被并发删除，或双语短例一开始就传不存在的收款账户；到账`UPDATE`返回成功OK但`affected_rows==0`。
- 影响：并发转账可共同花费同一份余额，使源账户变成负数或突破业务余额约束；收款目标消失时，事务仍会提交扣款而没有任何账户获得资金。示例正被描述为事务一致性的推荐写法，读者即使逐行检查所有`err`也无法发现这两种已成功提交的数据损坏，属于1.0发布阻断文档缺陷。
- 证据：两个教程的余额SQL都没有`FOR UPDATE`，随后基于旧snapshot中的Lua数值做条件判断；更新语句也没有把`balance >= amount`放进原子谓词。双语短例不预查收款账户，三个版本都不验证两次UPDATE的`affected_rows==1`。driver对合法OK返回table，因此零行更新不会进入`if not ok/res`错误分支。中文长例虽然预查目标存在，检查与UPDATE之间仍可变化，并且余额读取仍不锁定。
- 根因：把“语句处在同一事务中”误当作所有读后写业务条件自动串行化，同时混淆SQL执行成功与业务目标行确实存在。
- 建议解法：在确定的锁顺序中锁定两个账户（例如按id排序后`SELECT ... FOR UPDATE`），验证两行均存在且`from_id ~= to_id`、金额域有效；扣款最好用`UPDATE ... WHERE id=? AND balance>=?`并要求`affected_rows==1`，到账同样要求恰好一行，否则rollback。数据库层再以非负CHECK和账本/唯一业务操作ID作纵深保护，并明确commit失败的结果未知语义。
- 回归检查：修复阶段用barrier并发两笔共享源账户的超额转账，并覆盖目标在检查后删除、目标不存在、同账户、零/负金额、deadlock retry与commit结果未知；断言总额守恒、余额不为负、任一失败事务无部分效果，两个UPDATE都恰好影响一行。当前不执行SQL或并发barrier。

### DOC-031 — P3 — MySQL 双语监控把连续时间戳当连接等待，容量告警恒失真

- 状态：已确认；双语监控示例与pool checkout/query边界静态核对。本轮不运行计时或制造连接池拥塞。
- 位置：独立“查询等待时间”示例在`docs/src/{en/,}guides/mysql-connection-pool.md:968-1001`，完整监控面板重复同一算法在`:1054-1136`；真正可能等待连接的`conn_new`在`lualib/silly/store/mysql.lua:1020-1079`，公开`pool_query`把checkout和query合并在`:1173-1189`。
- 触发：连接池达到`max_open_conns`，新query在`conn_new`的`task.wait()`中等待数百毫秒或更久，然后执行一个很快的SQL；应用照抄指南输出slow-wait和slow-query指标。
- 影响：`wait_start`和`query_start`都在调用`pool:query`前连续采样，中间没有任何checkout，因此`wait_time`几乎恒为零，慢等待告警永远不会触发；真实pool等待被完整算进`query_time`并误报成数据库慢查询。上线时连接池容量不足、waiter饥饿或连接创建变慢会被错误归因给SQL/server，扩容和索引优化决策可能反向加重故障。
- 证据：两段代码都计算`query_start - wait_start`，两次`now()`之间只有注释；唯一yield发生在后面的`pool:query→conn_new`内部。当前公开pool API不暴露checkout token或阶段hook，因此外层wrapper不可能从一次总耗时中准确拆出等待与执行。完整面板把同样两个差值写入最近100条数组并标成平均等待/查询时间，使错误成为持续监控数据而非仅一条日志。
- 根因：文档假设调用方可以在单一同步`pool:query`入口前后测出其内部两个阶段，但没有对应的观测边界或driver指标。
- 建议解法：在driver内分别围绕connection checkout、connect/login、statement write/read埋点，并公开结构化metrics/hook；文档在该API落地前只报告端到端query latency，不虚构阶段拆分。等待直方图应同时记录成功、超时/close唤醒，并避免高基数SQL原文标签。
- 回归检查：修复阶段以可控clock和单连接pool覆盖立即命中idle、排队后唤醒、新建连接失败、query慢、pool close等路径；断言checkout+execution近似端到端耗时，慢等待只在真实排队时触发且不会被记成慢SQL。当前不运行计时或并发barrier。

### DOC-032 — P1 — MySQL 死锁重试示例丢弃 callback 返回错误并提交部分事务

- 状态：已确认；中文错误处理指南、`silly.pcall`多返回值、driver错误tuple与transaction状态静态核对。本轮不执行事务或制造死锁。
- 权威依据：[MySQL 8.4 deadlock handling](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks-handling.html)要求应用准备在事务因deadlock回滚时重新执行**整个事务**；这要求在事务任一语句返回deadlock时识别失败，而不是只检查COMMIT。
- 位置：`transaction_with_deadlock_retry`在`docs/src/guides/error-handling.md:921-978`；driver的`tx:query/commit`都以`result,nil`或`nil,err_packet`返回而不抛异常，见`lualib/silly/store/mysql.lua:872-983`；`silly.pcall`只是`xpcall`包装并保留callee多返回值，见`lualib/silly.lua:15-21`。英文guide在736行结束，没有对应数据库章节，另构成内容缺失但不改变本条触发。
- 触发：callback先成功执行一条UPDATE，再执行一条返回duplicate-key、constraint、deadlock或其他ERR的SQL，并按常见Lua约定`return nil,err`；wrapper用`local ok,result=silly.pcall(...)`调用它。callback含外部副作用后遇deadlock并被retry也是另一危险路径。
- 影响：`pcall`实际返回`true,nil,err`，wrapper只接前两项，因此把SQL失败当成“callback正常完成”，丢弃err并继续COMMIT。对只回滚当前statement的错误，之前成功的写会被部分提交；wrapper随后仅返回nil且没有error，调用方甚至不知道数据库已产生部分效果。对InnoDB deadlock，事务可能已由server整体回滚，但wrapper仍先COMMIT并且只在commit自身恰好返回1213时重试，所以典型语句阶段deadlock不会按文档承诺恢复。若callback含消息发送/文件写等外部副作用，真正重试又会重复它们。
- 证据：代码只以`if not ok`处理Lua异常，没有检查`result`或接收callback的第二返回值；driver所有合法server ERR均为普通返回tuple。deadlock errno判断仅位于`tx:commit()`失败分支，不包围`func(tx)`内每条query。示例也未约束callback必须无外部副作用、可安全重放或携带幂等operation id；缺失的`time`导入另已归入`DOC-028`，production commit失败归池问题另由`MYSQL-005`覆盖。
- 根因：把语言层“函数没有抛异常”和数据库层“事务业务成功”混成同一个boolean，并假设deadlock只会在commit暴露；retry API没有定义callback result和幂等契约。
- 建议解法：callback必须返回明确`value,nil`或`nil,err`，wrapper完整接收并在任一err时rollback；仅当结构化errno为1213/按策略包含1205时，确认旧transaction已安全丢弃后从BEGIN重跑整个**纯数据库且可重放**callback。其他错误原样返回。外部副作用放到成功commit后的outbox/幂等步骤；commit transport failure按`outcome_unknown`处理，绝不能自动重放。
- 回归检查：修复阶段覆盖callback抛异常、首/中/末statement返回普通ERR、语句阶段1213、commit阶段错误、rollback失败、callback外部副作用标记与重试上限；断言普通错误不提交任何先前写、deadlock重跑整个事务且业务效果至多一次、返回值始终包含真实error。当前不执行SQL或deadlock barrier。

### DOC-033 — P2 — MySQL 双语指南把 `max_idle_conns=0` 写成无限，实际默认禁用连接复用

- 状态：已确认；双语配置契约、pool return分支与test注释静态核对。本轮不连接数据库或测量握手次数。
- 位置：双语连接池指南配置总览明确写0为unlimited，见`docs/src/{en/,}guides/mysql-connection-pool.md:76-87`；双语reference又声明该字段默认0，见`docs/src/{en/,}reference/store/mysql.md:56-74`；实现默认和idle return在`lualib/silly/store/mysql.lua:985-1014,1138-1160`；tests明确把0注释为`no cache/Don't cache connections`，见`test/testmysql.lua:1047-1061,1405-1420`。
- 触发：用户按guide显式设置`max_idle_conns=0`希望不限制idle，或按reference省略该项使用默认0；顺序执行任意两次`pool:query/ping`。
- 影响：每次lease归还时`#conns_idle < 0`恒为false，driver发送COM_QUIT并关闭physical connection；下一操作重新TCP connect、handshake和authentication，per-connection prepared cache也全部丢失。正常流量会形成连接/auth/prepare风暴，增加延迟、CPU与数据库线程压力，容易碰到连接速率、防暴力认证和资源上限；文档名义上的默认“连接池”实际不复用连接。
- 证据：`pool_open`保存`opts.max_idle_conns or 0`；`conn_close`只有在`#conns_idle < pool.max_idle_conns`时入池，没有`<=0 means unlimited`分支。两个integration test专门以`max_idle_conns=0 -- no cache`验证/依赖现有含义，而reuse测试都显式设置1或更大，因此不是偶发实现偏差。双语guide同一配置表却把0与`max_open_conns`一样解释成unlimited。
- 根因：两个相邻pool limit沿用了相同的“0=unlimited”文档模板，但实现为idle上限选择了“0=disable idle”语义；reference只列默认值，未把关键语义说清。
- 建议解法：1.0前选定唯一兼容契约。基于tests和常见pool语义，优先保留`0=no idle`并修正双语guide/reference，给生产默认设置安全的正数或明确要求配置；若改成unlimited则必须设独立sentinel并评估无界idle fd风险，不能静默改变0。公开pool metrics方便发现连接 churn。
- 回归检查：修复阶段以connection id/handshake counter覆盖省略值、0、1、N及超过N并发归还；断言文档语义和保留/关闭数量一致，默认配置不会意外制造每query重连。当前不运行连接或性能测试。

### DOC-034 — P3 — MySQL inline LuaLS 把所有 row 值标成 string，并拼错 `sqlstate`

- 状态：已确认；MySQL全部类型入口、native返回字段、双语reference与测试静态核对。本轮不运行LuaLS或查询。
- 位置：唯一MySQL LuaLS声明位于`lualib/silly/store/mysql.lua:78-131`，其中err字段在`:97-107`、row index签名在`:129-131`；native ERR实际写入`sqlstate`见`luaclib-src/mysql/lmysql.c:198-206`，field decoder返回integer/number/string/nil见`:343-427`；双语数据契约在`docs/src/{en/,}reference/store/mysql.md:531-567`。`lualib/types/silly/`下没有MySQL补充类型文件。
- 触发：调用方在启用LuaLS的项目中访问`err.sqlstate`，或对`row.id/balance/flag`等MySQL数值列做比较、加减和传入要求number的函数。
- 影响：编辑器把真实存在的`sqlstate`报告为unknown field，却建议一个runtime永远不产生的`sql_stage`；所有row字段又被推断为string，正常数值业务持续产生type warning/错误补全。团队为消除告警可能加入错误的`tonumber`/string比较或改读`err.sql_stage`，前者掩盖NULL/精度契约，后者让错误分类在运行时恒为nil。1.0公开API的静态契约无法可信使用。
- 证据：C parser的upvalue key明确为`SQLSTATE`且unit test断言`t.sqlstate=="HY000"`；仓库没有任何写入`sql_stage`。row decoder对TINY到LONGLONG调用`lua_pushinteger`，FLOAT/DOUBLE调用`lua_pushnumber`，temporal/decimal/text调用string，NULL不设置key；inline却只有`---@field [string] string`。双语reference也明确列出这些多类型，与annotation自相矛盾。
- 根因：内部ERR注释沿用了“stage”命名且未与native key/test同步，row map为了简化写成单一string；文档、native与LuaLS没有共享schema或静态校验。
- 建议解法：把字段改为`sqlstate string?`；row index至少声明`integer|number|string|nil`，更理想是为query结果提供generic/用户可标注row shape，并为超范围uint、NULL和duplicate labels使用修复后稳定类型。将native exported key、LuaLS与双语reference纳入一致性检查。
- 回归检查：修复阶段用LuaLS fixture访问`err.sqlstate`及integer/double/string/NULL row，断言无unknown-field且不把numeric值固定推断为string；同时确保`sql_stage`被判为无效。当前不执行type checker。

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

### SOCK-006 — P1 — send length 在 `size_t→int→size_t` 转换后可越界读取

- 状态：已确认；公开Lua/C边界、确定性整数转换与send iovec路径推导。按用户要求不构造超大内存或越界发送复现。
- 位置：Lua buffer/length取得在 `luaclib-src/lnet.c:78-118,166-217,239-278`；public C API在 `src/silly.h:130-134`、`src/api.c:96-105`；op的窄字段在 `src/socket.c:317-330`，赋值/扩回在`:1614-1659,1663-1727`；TCP iovec消费在`:1118-1175`。
- 触发：调用公开`tcp_send/udp_send`的lightuserdata重载并提供负数或大于`INT_MAX`的Lua length；也可由超过`INT_MAX`的string/table总长度进入。lightuserdata路径不验证指针实际allocation大小，且`luaL_checkinteger`结果直接写入`size_t`。
- 影响：负数先按C unsigned转换成巨大`size_t`，再赋给op的`int size`发生实现定义窄化；socket线程把负int扩回巨大`size_t`。TCP wlist最终将原始小buffer与巨大`iov_len`交给`writev`，kernel可能在遇到fault前发送相邻heap内容，形成进程内存泄露；也可能EFAULT/断连/崩溃。`wlbytes`仅32-bit，还会同步回绕，破坏背压/关闭计数。UDP路径可产生巨大send length及错误状态异常。
- 证据：public签名全程声明`size_t`，但`struct op_tcpsend/op_udpsend.size`都是`int`且赋值无range check。`op_tcp_send`立刻以`size_t sz=op->size`扩回并保存到同为size_t的wlist；`drain_wlist_tcp`原样设置`iov[i].iov_len=w->size`。Lua lightuserdata helper执行`*size=luaL_checkinteger(...)`，没有`>=0`或实际allocation bound；类型注解也公开该重载。
- 根因：异步op wire struct沿用32-bit signed length，而API/owned buffer模型使用平台`size_t`；边界层又把“pointer+claimed length”当作可信组合。
- 建议解法：op size统一为`size_t`或明确的checked无符号宽度，并在所有入口先拒绝0、负值、超过`SSIZE_MAX`/实现单次发送与queue上限的长度；lightuserdata必须携带不可伪造的owned-buffer对象及真实capacity，不能接受裸pointer+任意length。`wlbytes/sendsize`升级到能表示queue上限的类型并做checked add。
- 回归测试：修复阶段不分配巨量内存地用测试专用owned buffer/length注入覆盖-1、INT_MAX、INT_MAX+1、UINT32_MAX、SIZE_MAX；断言超限在入队前失败并只释放一次，socket线程从不收到截断值，ASan/UBSan下无越界，正常边界发送与背压计数正确。

### SOCK-007 — P2 — stale send 可把 `wlbytes` 记入复用后的新 socket

- 状态：已确认；确定性并发交错与slot初始化路径推导，无独立动态复现。按用户要求不为命中窄窗口新增barrier代码。
- 位置：pool生命周期在 `src/socket.c:458-538,755-786`；worker send入口在`:1614-1639,1663-1686`；socket-thread stale op丢弃在`:1740-1767`。
- 触发：worker在old sid仍有效时执行`pool_get`并取得slot指针，随后socket线程close/free该slot；worker在free的`socket_default`清零之后才执行`atomic_add(&s->wlbytes, sz)`，且slot之后被new sid复用。TCP与UDP send入口都有同一窗口。
- 影响：旧send op稍后按old sid查找失败，只释放payload，不递减任何计数；先前加值因此永久留在free/new slot。新socket的`sendsize`无中生有地偏大，可让上层持续背压、等待不存在的发送数据或误判close drain状态；多次命中还会按32-bit模数累计。
- 证据：文件顶部契约明确`pool_get`返回的`struct socket *`不加锁。send入口验证sid后到`wlbytes`原子加之间没有generation重验或pin；`pool_free`先`socket_default`清零再加入free list，而`pool_alloc`设置fd/type/sid时不再次清零wlbytes，所以free后late add会被下一代继承。op只携带old sid，`op_process`失配分支不知道late add落在哪一代且只调用payload finalizer。
- 根因：将“请求已排队”的accounting提前放到worker并绑定可复用slot地址，而op的generation有效性只能由socket线程稍后判定；atomic只避免数据竞争，不能提供跨generation事务性。
- 建议解法：把wlbytes增加移到socket线程，在old sid验证成功并决定接纳op后执行；若worker必须立即看到backpressure，使用独立generation-tagged pending accounting并在入队/消费时校验同一tag，不能直接修改slot计数。close/reuse与send acceptance必须有单一线性化点。
- 回归测试：修复阶段用测试barrier停在pool_get后，依次执行close→free→可选reuse→恢复send；覆盖late add发生于free slot和new socket两种时序、TCP/UDP、stale op处理前后，断言new sendsize始终0且payload只释放一次。当前无独立动态复现。

### SOCK-008 — P1 — `worker_exit` 后的 socket flush error 会使用已释放的 worker

- 状态：已确认；确定性shutdown顺序与error call graph推导，无独立动态复现。按用户要求不新增退出故障注入。
- 位置：shutdown/join/析构顺序在 `src/engine.c:125-174`；worker释放在 `src/worker.c:517-522`；socket final flush在 `src/socket.c:1190-1209,1977-1996`；close message入队在`:680-743`与`src/worker.c:90-100`。
- 触发：shutdown时仍有TCP wlist留在dirty socket中；socket thread处理OP_EXIT后已停止，主线程先释放worker；随后`socket_exit→flush_dirty→drain_wlist_tcp`的sendv返回EPIPE/ECONNRESET等永久错误。peer在服务退出前reset/close且本端仍有待发数据即可影响该条件。
- 影响：error路径调用`report_close`分配message并进入`worker_push`，后者解引用已经`mem_free`的全局`W`及其已释放queue，构成heap use-after-free；可能崩溃、破坏allocator/相邻内存，或在退出阶段产生不可预测行为。
- 证据：`engine_shutdown`确实在worker仍运行时stop并join timer/socket，worker thread退出后`engine_run`依次执行`worker_exit()`再`socket_exit()`。`worker_exit`关闭Lua、`queue_free`并释放W；`socket_exit`第一句业务动作却是`flush_dirty(SM)`。该函数对任何negative drain无teardown guard地调用`report_close`，最终`queue_push(W->queue, msg)`。线程已join只消除并发，不恢复对象生命周期。
- 根因：退出流程把“停止producer thread”误当作“后续cleanup不会再生产worker消息”；final transport flush仍复用了运行期error-reporting路径。
- 建议解法：定义两阶段quiesce/cleanup：停止接收新发送并joinproducer后，socket abort-cleanup不得再向worker报告消息，只释放payload/关闭fd；或保持worker queue存活到socket cleanup结束并明确丢弃/释放其消息。不要仅交换两行而让无人dispatch的close message泄漏；加入teardown flag和专用no-report cleanup路径更清晰。
- 回归测试：修复阶段在退出final flush注入EPIPE/ECONNRESET/EAGAIN/partial write，覆盖有/无closewait和多个wlist；ASan断言无UAF，所有payload/message只释放一次，worker queue/socket manager/timer最终无泄漏。当前无独立动态复现。

### SOCK-009 — P1 — 已返回的 poll event 可误作用于复用后的新 socket generation

- 状态：已确认；确定性`eventwait→op_process→event consume`顺序与event payload推导，无独立动态复现。本轮不新增大规模slot复用测试。
- 位置：epoll/kqueue/wepoll event均只保存slot pointer，见 `src/unix/event_epoll.h`、`src/unix/event_kevent.h`、`src/win/event_iocp.h`；主循环在`src/socket.c:1807-1918`；pool generation在`:458-538,755-786`。
- 触发：`sp_wait`已把old socket的event写入`SM->eventbuf`；同批次包含control wakeup，随后`socket_poll`在消费event前先执行`op_process`，其中close/free old slot并在足够slot压力或后续listen/connect/accept中将其复用为new sid；之后才读取old event保存的slot pointer。
- 影响：event loop只检查slot当前`zombie/sid/type`，因此把old generation的READ/WRITE/EOF/ERROR flags应用到new fd。可能提前报告connect成功、错误读写/关闭新连接，或在new slot是listener而old event不是READ时触发`assert(SP_READ(e))`终止进程；属于跨连接generation混淆。
- 证据：三个backend的`SP_UD(e)`都返回注册时的`void *udata`，注册值是`struct socket *`，event数据没有sid/version。`socket_poll`明确先`eventwait`、再`op_process`、最后遍历已填充eventbuf；所以即使`sp_del`保证删除未来通知，也无法改写已经返回的用户态batch。消费时`sid(s)<0`只能过滤仍free的slot，一旦复用sid重新有效就通过，完全没有与event generation比较。
- 根因：poll registration identity绑定永久slot地址而非generation token，且主循环在event snapshot与消费之间执行可free/reuse slot的commands。
- 建议解法：event userdata应携带可验证generation（例如稳定registration对象含slot index+sid snapshot），消费前比较当前sid；或保证event batch完全消费前不把freed slot归还allocator，使用deferred-reuse epoch。仅把op_process移到event后不能覆盖event处理中close/accept复用和其他backend语义，generation check仍应存在。
- 回归测试：修复阶段用小pool/testbarrier让epoll_wait/kevent/wepoll返回old READ/WRITE/EOF后，在consume前执行close并复用为listener/connecting/connected socket；断言stale event全部丢弃，新socket不读写、不提前connect、不关闭且无assert。当前无独立动态复现。

### SOCK-010 — P2 — `sp_ctrl` 失败后软件状态与内核订阅永久分叉

- 状态：已确认；确定性state/syscall/error路径推导，无独立动态复现。本轮不新增multiplexer故障注入。
- 位置：`rw_enable`在 `src/socket.c:851-879`；调用点覆盖connect、TCP/UDP drain、closewait、EOF和公开readenable，见`:896-912,1087-1107,1118-1239,1480-1493,1601-1611,1714-1726,1874-1908`；backend在`src/unix/event_epoll.h:47-53`、`event_kevent.h:46-56`、`src/win/event_iocp.h:48-54`。
- 触发：epoll_ctl MOD、kevent enable/disable或wepoll MOD因ENOMEM、EBADF、ENOENT、lifecycle/backend错误等返回失败；既可能发生于开启write等待EAGAIN，也可能发生于queue清空/EOF/closewait时关闭read/write。
- 影响：enable-write失败时software已标WRITING，future calls因early-return不再重试，但kernel未订阅writable，wlist可永久卡住并阻塞close；disable-write失败时kernel持续报告通常level-triggered writable，event loop对空queue反复唤醒形成CPU spin。disable-read失败可重复收到EOF/error并重复report_close；上层既无错误通知也无法修复状态。
- 证据：`rw_enable`先用atomic set/clr修改state，再计算flags并调用`sp_ctrl`，完全丢弃int返回值。入口第一句`if(test_state(...)==enable)return`使失败后的logical state阻止下一次相同操作。三个backend都返回实际control syscall结果，证明错误原本可检测但被上层抛弃。
- 根因：subscription update不是事务：期望状态被提前提交，backend失败没有rollback、retry、close或report策略。
- 建议解法：先计算desired flags并调用backend，成功后再commit state；失败时保持旧state并按errno选择bounded retry或将socket以明确错误关闭。若多线程需要先发布intent，增加separate desired/applied state与socket-thread reconciliation，不能用一个bit同时表示两者。
- 回归测试：修复阶段分别让每次enable/disable read/write的sp_ctrl返回ENOMEM/ENOENT/EBADF，覆盖TCP/UDP、queue EAGAIN/empty、EOF/closewait；断言无永久stall或busy loop、状态可重试/关闭、错误只报告一次。当前无独立动态复现。

### SOCK-011 — P1 — 未校验的 sockaddr blob 可触发栈溢出或越界读取

- 状态：已确认；公开Lua/C API与确定性assert/NDEBUG路径推导。本阶段不传入破坏性address blob。
- 位置：UDP Lua入口在 `lualib/silly/net/udp.lua:194-204`、`luaclib-src/lnet.c:239-278`；stack op复制在`src/socket.c:1663-1686`；ntop Lua/C入口在`luaclib-src/lnet.c:280-288`、`src/api.c:84-87`、`src/socket.c:540-565,1060-1070`；sockaddr length helper在`src/sockaddr.h`。
- 触发：调用公开`udp_conn:sendto(data, addr)`或`silly.net.c.udp_send`并传入长度大于`union sockaddr_full`的任意string；或直接调用公开C module的`ntop`并传入少于sockaddr长度、family非法或内容截断的string。
- 影响：UDP send仅以assert保护fixed-size stack field；assert build直接终止进程，NDEBUG build继续`memcpy`并覆盖`op_udpsend`栈对象后的字段/栈内存。ntop没有长度参数，短blob会读取Lua string边界外；非法family在assert build终止，NDEBUG下进入IPv6分支、忽略`inet_ntop`失败并对未初始化buffer执行strlen，可能继续越界读取/写错误长度。
- 证据：`ludp_send`取得addrlen后不做任何格式/长度检查即调用`silly_udp_send`。`socket_udp_send`执行`assert(addrlen<=sizeof(op.addr)); memcpy(&op.addr,addr,addrlen)`，assert不是release安全边界。`lntop`用`luaL_checkstring`却不取得string length；`ntop`只有AF_INET/else+assert(AF_INET6)，同时忽略两次inet_ntop返回值。`sockaddr_len`也把任何非AF_INET family都当IPv6长度。
- 根因：内部OS生成的trusted sockaddr二进制表示被直接暴露成普通Lua string API，却没有携带variant/length验证；开发期assert被当作不可信输入校验。
- 建议解法：集中`parse_sockaddr_blob(ptr,len)`，只接受长度恰好匹配AF_INET/AF_INET6且family一致的值；所有public入口返回EINVAL而非assert。更优是使用opaque userdata保存validated sockaddr，sendto/ntop不接受任意string。始终检查inet_ntop返回并以已初始化buffer/显式error收尾。
- 回归测试：修复阶段覆盖长度0..sizeof(v6)+1、AF_UNSPEC/随机family、v4 family+v6 length及反向、截断/超长、inet_ntop失败；assert/NDEBUG两种build都只返回错误，无stack overwrite/OOB，合法recvfrom addr仍可round-trip。当前不新增动态触发。

### SOCK-012 — P1 — TCP/TLS/UDP 默认接收队列无上限，可被远端耗尽内存

- 状态：已确认；公开API默认值、数据事件和读取路径的确定性推导。本阶段不新增大流量/慢消费压力复现。
- 位置：TCP socket默认值、data append与可选limit在 `lualib/silly/net/tcp.lua:68-98,127-149,213-225`；TLS对应路径在`lualib/silly/net/tls.lua:105-137,250-278,398-407`；UDP stash在`lualib/silly/net/udp.lua:48-92,135-168`；C层每次收包复制并投递worker在`src/socket.c:997-1057`。
- 触发：建立TCP/TLS连接后持续发送而应用handler不调用/来不及调用read，或向UDP socket持续发送datagram而应用不调用/来不及调用recvfrom。TCP/TLS调用方未显式设置`conn:limit()`即可；UDP没有等价的limit、packet-count cap或drop policy API。
- 影响：TCP每个data event无条件`bappend`，TLS把全部ciphertext/plaintext推入SSL buffer，UDP则把每个报文复制成Lua string并排入`stash_packets`；三者都可随远端输入持续增长，最终造成进程内存耗尽、GC压力和服务不可用。UDP除payload外还按报文增长table/queue元数据，小包洪泛也可放大对象数量。
- 证据：TCP/TLS的`buflimit`初始化为nil，只有应用主动调用`limit`才会执行高水位`readenable(false)`；listener/connect配置没有安全默认值。UDP data callback在没有等待中的reader时始终`qpush`并增加`stash_bytes`，但该计数既不参与限流也不暴露为限制配置。C socket thread读取后为每个chunk/datagram分配独立payload并发送worker消息，未提供跨层全局或per-socket预算。
- 根因：接收背压被设计成可选的调用方责任，并且只覆盖TCP/TLS字节buffer；默认构造和UDP队列没有资源预算，worker消息生产也没有与consumer backlog联动。
- 建议解法：为listener/connect/bind提供安全且可配置的默认高/低水位与hard cap；TCP/TLS达到高水位暂停read、低水位恢复，超过hard cap明确关闭/报错。UDP同时限制stash bytes和packet count，配置drop-new/drop-old/error策略并暴露drop metrics；补充worker/per-socket在途消息预算，避免Lua层限流生效前已有大量payload排队。
- 回归测试：修复阶段分别覆盖TCP、TLS及UDP在handler阻塞/不读取时持续输入；断言内存与packet count有界、TCP/TLS能按水位恢复、UDP按配置丢弃并计数、close会释放stash。当前按要求不新增压力触发。

### SOCK-013 — P2 — 设置 nonblocking 失败只写日志，blocking fd 仍进入事件循环

- 状态：已确认；Unix/Windows wrapper与四类socket创建路径静态推导。本轮纯静态审查，不注入`fcntl/ioctlsocket`失败。
- 位置：Unix `nonblock`在`src/unix/unix.c:15-31`，Windows版本在`src/win/win.c:14-27`，共同声明为void在`src/unix/unix.h:31-33`、`src/win/win.h:69-73`；调用点在`src/socket.c:809-848,1279-1311,1356-1394,1456-1493`及UDP connect对应路径。
- 触发：`fcntl(F_GETFL/F_SETFL)`或`ioctlsocket(FIONBIO)`因EINTR、无效/已关闭descriptor、平台资源或driver错误而失败；macOS/Windows accept总走该wrapper，listen、UDP、outbound connect也依赖它。
- 影响：caller看不到失败并继续pool_alloc、poll registration或同步`connect`。blocking listener/connection/UDP fd在ready状态变化、竞争或部分数据场景下可让accept/recv/send/connect阻塞唯一socket thread；该线程一旦停住，所有连接的I/O、close和新操作都停止。对象状态仍宣称polling，Lua侧没有可见错误。
- 证据：两平台函数返回void，失败分支只`log_error`后return；所有调用点均无验证。`dolisten/socket_udp_bind`随后直接返回成功，`exec_accept`继续登记accepted fd，`op_tcp_connect`紧接着调用connect；底层syscall因此可能采用blocking语义。Linux accept4路径避免accepted-fd这一支，但listen、UDP和outbound socket仍受影响。
- 根因：nonblocking被当作best-effort性能选项，而事件驱动状态机实际上要求它是注册前不可违反的不变量。
- 建议解法：让wrapper返回0/-errno，并处理EINTR重试；每个创建/accept路径必须在失败时关闭fd、回滚pool/op状态并向对应caller报告明确错误，只有成功设置nonblocking后才能发布sid或加入poller。可优先使用`socket(...SOCK_NONBLOCK)`/`accept4`的原子创建形式并保留可靠fallback。
- 回归测试：修复阶段分别在Unix F_GETFL、F_SETFL及Windows FIONBIO失败点做可控注入，覆盖listen/accept/TCP connect/UDP bind/connect；断言fd关闭、slot/计数回滚、socket thread继续处理marker连接且无double-close。当前不运行注入。

### SOCK-014 — P2 — stale close 可把 `CLOSING` 状态写入复用后的新 socket

- 状态：已确认；slot发布/回收顺序与worker/socket线程交错静态推导。本轮不新增并发barrier或动态复现。
- 位置：并发契约与state操作在`src/socket.c:26-69,85-123`；pool发布/回收在`:458-538`；worker close入口在`:1562-1588`；connect/listen失败和其他socket-thread释放路径在`:1338-1353,1397-1412,1456-1493,1544-1559`。
- 触发：worker以old sid进入`socket_close`并通过`pool_get`，随后socket线程因pending connect/listen失败或已有操作而`free_socket/pool_free`同一slot；worker再执行`set_closing(s)`。最窄但确定的窗口是`socket_default`已经把state清零、尚未把sid写成-1时，或者slot已经以new sid复用、旧worker尚未写state时。
- 影响：旧close op携带old sid，socket线程稍后会正确丢弃它，但提前写入slot地址的`STATE_CLOSING`没有generation标签，不会被回滚。新generation可继承closing状态；`report_close`因此直接返回而不通知Lua，读路径也可把它当EOF，导致新连接被错误终止、close事件丢失或上层任务永久等待。若写入发生在回收的其他阶段，还会与生命周期状态变更形成未定义的跨代语义。
- 证据：文件顶部明确说明`pool_get`不锁定slot且socket线程可随时free/reuse；然而`socket_close`只在入口校验一次sid，随后直接读写共享state。`socket_default`按`state=0`、`sid=-1`顺序执行，`pool_alloc`设置fd/type并发布new sid但不会再次清空state。旧op在`op_process`的sid校验只能保护稍后的命令执行，保护不了入队前已经作用于slot的atomic state写。
- 根因：close acceptance被拆成两个线性化点：worker先无代际保护地修改可复用slot，socket线程再按sid验证命令；atomic state保证单次读写原子，却不保证它属于同一generation。
- 建议解法：worker入口只验证/复制sid并排队，不直接修改slot state；由socket线程在成功验证sid后原子设置closing并决定幂等close。若API必须同步返回`EXCLOSING`，使用独立的generation-tagged command/pending表，或为slot实现覆盖sid+state的锁/seqlock事务，且回收后不允许旧引用再写。
- 回归测试：修复阶段用小pool/barrier覆盖`pool_get → old free → state clear → sid invalid → new alloc → stale set_closing`各切点，并覆盖pending TCP connect、listen失败和重复close；断言new socket state为clean、其data/close事件正常交付、old close只返回确定错误。当前不创建或运行该复现。

### SOCK-015 — P2 — 合法 fd 0 的异步 TCP connect 完成会触发进程断言

- 状态：已确认；POSIX descriptor语义与connect completion调用链的确定性静态推导。本轮不关闭stdin或建立连接。
- 平台语义：POSIX `socket()`返回任何当前最小可用的非负descriptor，0同样合法；只有负数表示失败。事件循环和连接状态机必须接受fd 0，不能把它当未初始化值。
- 位置：TCP socket创建/pool发布在`src/socket.c:1415-1448`；异步connect、poll completion及SO_ERROR读取在`:881-913,1456-1493,1842-1873`；唯一错误断言是`:886`。其他创建路径已使用`fd >= 0`判断。
- 触发：进程启动时descriptor 0未被stdin或其他资源占用，首个outbound TCP `socket()`返回0；nonblocking `connect()`返回EINPROGRESS，随后poller报告连接可写并进入`checkconnected→get_sock_error`。
- 影响：`assert(s->fd > 0)`确定性失败并终止整个进程，而该fd和连接状态均合法。容器、supervisor、嵌入式启动器或应用主动关闭stdin后都可能出现；是否崩溃取决于connect同步完成还是EINPROGRESS，形成部署环境相关的启动/故障恢复不稳定。
- 证据：创建路径只以`fd < 0`判失败并会把0写入socket slot；`op_tcp_connect`也明确断言`fd >= 0`，说明0属于已接受状态。只有稍后的`get_sock_error`收紧成`>0`，且该函数是EINPROGRESS事件的必经路径。代码没有在初始化时保留0或把socket重新映射到大于0的descriptor。
- 根因：把传统stdio fd编号与socket有效性混淆；不同连接分支使用了不一致的descriptor不变量。
- 建议解法：改为`assert(s->fd >= 0)`并审查所有platform wrapper只以各平台的invalid sentinel判错；不要依赖stdio始终打开。若某平台socket类型的invalid值不是-1，集中使用`SP_INVALID/INVALID_SOCKET` helper，避免通用整数比较。
- 回归测试：修复阶段在独立子进程关闭fd 0后创建会EINPROGRESS的TCP连接，断言fd 0可以完成、读写、关闭并复用；同时覆盖同步成功、ECONNREFUSED、listener/UDP取得0和daemon stdio重定向。当前不改变进程descriptor。

### SOCK-016 — P2 — Windows 控制唤醒 socket 使用 CRT `close` 销毁

- 状态：已确认；Windows handle API 契约与初始化/销毁调用链的确定性静态推导。本轮不运行Windows构建或反复初始化。
- 平台语义：Windows的Winsock `SOCKET`必须由`closesocket()`释放；CRT `close()`接收的是另一套整数file descriptor。两种handle namespace不可互换，即使底层数值偶然相同也不建立所有权关系。
- 位置：Windows `pipe()`以`WSASocket/accept`创建控制通道两端并经`fd_t`返回，在`src/win/win.c:127-276`；`fd_t`是`intptr_t`且没有把`close`映射为`closesocket`，见`src/win/win.h:12-18,70-74`和`src/platform.h:32-37`；通用销毁却在`src/trigger.h:37-46`调用`close`。该销毁分别由`socket_init`错误回滚和正常`socket_exit`调用，见`src/socket.c:1929-1996`。
- 触发：任意Windows正常退出；或控制socket已创建后，`add_to_sp`等后续socket初始化步骤失败并进入回滚。
- 影响：两个Winsock控制socket不会被正确关闭，直到进程终止才由OS回收；初始化失败若上层重试会持续泄漏socket handle。更坏情况下，截断后的SOCKET数值恰好命中有效CRT descriptor，`close`会误关日志、配置或其他无关文件，随后仍泄漏原socket。64位`SOCKET`到CRT `int`参数的窄化还会进一步破坏目标标识。
- 证据：创建路径从未把Winsock handle包装成CRT fd；Windows `pipe_read/pipe_write`也显式把同一值作为`SOCKET`交给`recv/send`。项目其他socket关闭路径均使用`closesocket`，只有通用`trigger_destroy`使用`close`；非Windows平台才在`platform.h`定义`closesocket`为`close`，反向映射不存在。
- 根因：控制通道在Unix是pipe fd、在Windows是socket pair，但抽象层只统一了读写，没有统一close操作和invalid sentinel。
- 建议解法：增加平台级`closefd`/`trigger_close` helper，Unix调用`close`、Windows调用`closesocket`，并让初始化、错误回滚和正常销毁共用；字段初始化和有效性判断也使用平台invalid sentinel，避免把Windows handle缩成`int`。
- 回归测试：修复阶段在Windows统计进程handle/socket资源，覆盖正常启动退出和`sp_add`失败回滚，断言控制通道两端各关闭一次；同时预先打开多个CRT文件并验证销毁不会改变它们的可读写性。当前不做handle故障注入。

### SOCK-017 — P2 — Windows 的 accept 资源耗尽预留槽使用了错误的 handle 类型

- 状态：已确认；Windows CRT/Winsock资源模型与accept错误分支的确定性静态推导。本轮不耗尽系统socket或运行监听服务。
- 设计契约：reserve-fd技巧需要预先占用与耗尽资源同类的一个可关闭槽；`accept`返回`EMFILE/ENFILE`后先释放该槽，才能接受并立即关闭一条pending connection，再恢复reserve，避免level-triggered listener持续报告同一连接。Windows的`WSAEMFILE`表示无法再创建socket，必须释放Winsock `SOCKET`，CRT文件fd不满足该契约。
- 位置：`reservefd`被声明为`int`，见`src/socket.c:242-247`；初始化、accept耗尽处理和退出分别在`:809-829,1929-1949,1977-1985`。Windows平台的socket handle类型实际为`intptr_t fd_t`，见`src/win/win.h:12-18`。
- 触发：Windows监听进程达到Winsock socket/handle上限，`accept`返回映射后的`EMFILE`；正常退出也会执行错误的reserve清理路径。
- 影响：初始化使用Unix专用`open("/dev/null", O_RDONLY)`；在原生Windows路径语义下通常直接得到-1，即使环境中意外成功，结果也是CRT file descriptor而不是Winsock socket。耗尽分支随后以`closesocket(reservefd)`释放错误namespace，不能腾出socket槽；第二次`accept`仍失败，pending connection留在监听队列并可能让level-triggered poller持续唤醒、记录错误和占用唯一socket线程。退出时同样不能正确关闭CRT reserve fd；若数值碰撞还可能作用于无关socket。
- 证据：整个生命周期对`reservefd`只调用`open`和`closesocket`，没有任何`_close/close`；字段又从Windows指针宽度handle缩成`int`。与Unix上“打开文件→close文件→accept”成立的机制不同，Windows实现从未预留过一个Winsock socket，因此资源类别和close API都不匹配。
- 根因：Unix的file-descriptor统一namespace假设被直接带到Windows；platform abstraction只覆盖主连接API，没有覆盖资源耗尽reserve策略。
- 建议解法：按平台实现reserve对象：Unix保留`/dev/null` fd；Windows创建一个最小Winsock socket并以`fd_t/SOCKET`存储、用`closesocket`释放和重建。所有创建/释放均检查错误；若Windows无法可靠恢复，则从poller临时禁用listener并采用有界退避，避免热循环。
- 回归测试：修复阶段在Windows以可控socket配额或API stub命中首个`accept=WSAEMFILE`，断言确实释放一个Winsock slot、只drain一条pending连接、reserve重建成功且poller不热循环；同时核对初始化失败与正常退出没有CRT fd或socket handle泄漏。当前不做资源耗尽测试。

### SOCK-018 — P1 — Windows 控制 socket 路径长度可造成启动期栈越界写

- 状态：已确认；Win32返回值契约、无符号算术与固定数组寻址的确定性静态推导。本轮不修改环境变量或启动Windows进程。
- 平台契约：`GetTempPath`与`GetWindowsDirectory`在buffer不足时返回所需长度，该值可大于传入capacity；调用方必须在使用返回值作为offset前检查0、capacity和为后缀保留的空间。`snprintf`返回的是本来需要写入的长度，截断时也可能大于可用空间，不能无条件累加后继续寻址。
- 位置：Windows socket-pair替代实现的固定`a.unaddr.sun_path`、目录选择和文件名追加在`src/win/win.c:127-215`，尤其`:169-209`；`pipe()`由`trigger_init`在所有网络引擎启动时调用，见`src/trigger.h:20-34`和`src/socket.c:1929-1945`。
- 触发：`GetTempPath(UNIX_PATH_MAX, sun_path)`返回大于等于`UNIX_PATH_MAX`的required length；或Windows目录及追加的`"\\Temp\\"`使`n`达到/超过该上限。长`TEMP/TMP/USERPROFILE`配置、长系统目录或API返回截断均可在首次网络初始化命中。
- 影响：代码继续计算`a.unaddr.sun_path + n`，指针已经越过栈上union；`UNIX_PATH_MAX - n`因`n`为`DWORD`而无符号下溢成巨大size，再交给`snprintf`写入计时器/PID字符串。结果是确定的越界写风险，可破坏相邻局部变量、控制流元数据并导致启动崩溃；具体可利用性取决于编译器栈布局，因此本报告不宣称远程代码执行。
- 证据：两个Win32目录API的返回值均未与0或`UNIX_PATH_MAX`比较；第二个分支还把可能截断的`snprintf("\\Temp\\")`返回值累加到`n`，随后所有分支共用`:207-209`的unchecked pointer/length。fallback只在`bind`失败后发生，无法保护发生在`bind`之前的内存写。
- 根因：把Win32“buffer不足时返回required size”和C `snprintf`“返回未截断所需长度”的契约误当成“始终返回已写入且位于buffer内的长度”。
- 建议解法：用checked helper逐段构造路径：每次调用后要求`0 < n < capacity`，每次追加后要求返回值小于remaining，并预留NUL和唯一文件名最大长度；任何不满足都跳过该目录而不做指针运算。优先直接使用AF_INET loopback socket pair，或使用支持长路径且能可靠清理命名项的Windows专用实现。
- 回归测试：修复阶段用Win32 API stub覆盖返回0、恰好capacity、capacity+1、目录可容纳但后缀截断、文件名恰好满等边界；ASan/Windows Application Verifier下均只能安全fallback，不越界且不泄漏listener/client/accepted socket。当前不构造长环境路径。

### SOCK-019 — P2 — TCP 路径把 Windows 指针宽度 `SOCKET` 截成 `int`

- 状态：已确认；Windows socket类型契约与C隐式转换的确定性静态推导。本轮不制造高位handle或运行Windows服务。
- 平台契约：Win64的`SOCKET`是`UINT_PTR`，项目自己的`fd_t`也正确声明为`intptr_t`；只有`INVALID_SOCKET`表示失败，不能把socket handle存入32位`int`。一旦高32位非零，窄化后的值不再标识原socket。
- 位置：Windows类型定义在`src/win/win.h:12-18`；TCP listener helper却返回`int`，见`src/socket.c:1279-1311`；accepted socket局部变量是`int`，见`:809-848`；outbound TCP创建变量也是`int`，见`:1415-1453`。此外socket统计再次把`s->fd`复制到`int`并用于`getpeername`，见`:2019-2057`；公开统计结构的fd字段本身也是`int`，见`src/silly.h:59-69`。
- 触发：Win64进程收到或创建一个不能无损表示为32位`int`的合法Winsock handle；长运行、高句柄压力、嵌入其他大量handle的宿主进程会提高出现概率。
- 影响：listener可能在`dolisten`返回时即丢失高位，随后把错误handle发布到pool；connect和accept则在`socket()`/`accept()`返回的第一步窄化。后续`nonblock/setsockopt/epoll_ctl/send/recv/closesocket`作用于截断值：通常表现为合法连接随机失败并泄漏原socket；若截断值碰巧标识另一socket，则可能注册、读写或关闭错误连接。统计路径也可能查询无关连接或返回伪造地址。
- 证据：同文件的UDP bind/connect以及多数内部helper已经使用`fd_t`，说明跨平台预期类型明确；只有上述TCP/统计路径退化为`int`。编译器允许从`SOCKET/uintptr_t`到`int`的实现定义窄化，现有成功Windows CI不能证明所有合法handle值可表示。
- 根因：Unix fd 的`int`假设残留在部分公共路径，没有把平台socket类型贯穿返回值、局部变量和统计ABI。
- 建议解法：所有真实socket变量、helper返回值和内部统计快照统一使用`fd_t`/`SOCKET`，只与平台invalid sentinel比较；对外若必须暴露数值handle，使用`intptr_t`/`int64_t`或明确不公开原生handle。开启Win64 conversion warnings并禁止socket→int隐式赋值。
- 回归测试：修复阶段用Winsock wrapper返回带高32位的synthetic handle验证类型传递，另在真实Win64句柄压力下覆盖listen/connect/accept/stat/close；断言每个API收到的bit pattern完整一致，不泄漏原handle、不触碰低位碰撞对象。当前不施加handle压力。

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
- 位置：`lualib/silly/net/websocket.lua:30-34,226-289,339-347`；HTTP version/Host 来源为 `lualib/silly/net/http/h1.lua:818-869`；H2 stream对象/response sender在`lualib/silly/net/http/h2.lua:456-490,704-738,949-960,1549-1632`。
- 触发：调用 `websocket.upgrade(stream)` 时，请求只要 method 为 GET 且存在任意字符串的 `Sec-WebSocket-Key` 即可；`Upgrade`、`Connection`、`Sec-WebSocket-Version` 和 Host 可以缺失，HTTP version 可以是 1.0。`Connection: notupgrade` 也因子串命中而通过。反向地，合法大小写或 token-list 形式的 Upgrade 还可能被错误拒绝。跨协议后果是HTTP listener经ALPN把普通H2 GET交给同一handler，请求只带Key而不带H2禁止的Connection/Upgrade，handler仍调用`websocket.upgrade(stream)`。
- 影响：HTTP endpoint 会在没有完成 WebSocket opt-in/proof 的请求上发送 101并试图切换协议，破坏WebSocket防止跨协议混淆的握手边界。代理和origin对是否发生Upgrade可能得出不同结论；宽松接受与错误拒绝也破坏标准互操作。H2路径会发送HTTP/2禁止的101 response并返回`conn=nil`的WebSocket socket；常规handler第一次read/write即抛异常，还会进入`H2-027`已记录的stream/map/quota泄漏路径。
- 证据：`checklist` 包含三个必需字段，但循环用 `if verify then ... end`，缺失值直接跳过。Connection 仅执行 `lower():find("upgrade", ..., true)`，没有逗号 token 解析；其他字段用区分大小写的精确字符串比较。代码只检查 Key 非空并直接参与 Accept 哈希，从未验证 Base64 语法或解码长度；也不检查 `stream.version` 和 Host。底层 H1 server 只拒绝高于 1.1 的 version，不要求 Upgrade 必须是 HTTP/1.1。H2 admission会拒绝Connection/Upgrade，却允许普通GET携带Key；其stream有`version="HTTP/2"`和`channel`但没有`conn`。upgrade不检查version，调用通用`respond(101)`由H2编码`:status 101`，随后`newsocket`复制不存在的`stream.conn`为nil。
- 建议解法：建立严格的 server handshake validator：先要求 HTTP/1.1+ GET 和有效 Host；合并重复字段后按逗号 token、OWS 和 ASCII 大小写不敏感规则验证 Upgrade/Connection；严格解析单一 version 13；验证 Key 是合法 Base64 且解码恰为 16 bytes，再用原编码字符串计算 Accept。unsupported version 返回 426 并携带 `Sec-WebSocket-Version: 13`，其他错误返回 400 并关闭。
- 后续回归条件：修复阶段对每个必需项做缺失、重复、大小写、token-list、substring、非法 Base64、非 16-byte、HTTP/1.0 和缺失 Host 覆盖；合法 `Upgrade: WebSocket` 与 `Connection: keep-alive, Upgrade` 必须通过。另把H2 GET/CONNECT stream传入upgrade，断言同步返回unsupported且不生成101、不返回socket、不使handler异常或泄漏stream quota。本轮不新增测试代码。

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
- 影响：接收端会消费并向应用交付 RFC 要求使连接失败的帧，不同实现对同一 TCP 字节流产生接受/关闭差异；控制帧可能进入错误的 fragmentation 路径。64-bit最高位置1还有transport分叉：长度变为负Lua integer后，TCP把它当空payload成功并把真实payload留作后续frame header重新解释，TLS则把负读取登记成永不满足的waiter。发送端还会生成严格 peer 必须拒绝的非规范帧，造成稳定互操作失败。若其他非法header声明巨大正payload，当前实现会在opcode/control校验前尝试读取完整数据，资源风险另见`WS-005`。
- 证据：首字节只提取 FIN 与低 4-bit opcode，RSV 三位被丢弃；扩展长度 `unpack(">I8")` 后没有最短编码或最高位检查。内置Lua `unpackint`在size恰等于`sizeof(lua_Integer)`时不做unsigned overflow检查，最终把`lua_Unsigned`直接cast成有符号integer（`deps/lua/lstrlib.c:1746-1768`），故wire高位1得到负payload。TCP buffer对非正长度返回空串，TLS非正长度挂起路径见`TLS-009`。`read_frame` 在任何 opcode 下先读取payload，`s.read` 之后才查 `data_type`，且从未按 opcode 检查 FIN/125。mask 的 `needmask ~= mask` 校验是符合项。发送端使用 `len < 125` 与 `len < 0xffff`，导致合法直接编码的上界 125 和 16-bit 上界 65535 分别被提升一级。
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
- 位置：`lualib/silly/net/websocket.lua:139-223,268-271`；公开契约为 `docs/src/reference/net/websocket.md:160-224`。
- 触发：收到或发送长度为 1 的 Close、保留/越界 status、Close 后继续读写 data；或任一方调用 `sock:close()` 主动结束正常连接。另一个确定性本地路径是把socket保存为Lua 5.4 to-be-closed变量、又在作用域内显式调用`close()`，或任何cleanup重复调用close。
- 影响：非法 close data 被原样交付/发送，应用无法可靠获得 close code/reason；Close 后仍可发送应用数据，违反连接状态边界。主动关闭总是在写出 Close 后立即关闭 TCP，peer 的 Close response 无法被读取，因此正常关闭不能确认完成，容易表现为 abnormal/unclean closure，丢失对端状态并造成严格实现互操作失败。重复关闭不会稳定返回“已关闭”，而会在nil connection上抛Lua异常；当`__close`发生在异常展开期间，这个cleanup错误还可能替代或掩盖原业务错误。
- 证据：reader 对 opcode 8 与其他类型一样返回 raw `dat`，不解析长度/status，也不改变 socket 状态。`s.write(..., "close")` 只受控制帧 125-byte 检查，返回后仍可继续调用 write。`s.close` 调用 `sock:write("", "close")` 后立刻 `conn:close()` 并置 nil，没有等待 peer Close、角色区分或 deadline。metatable同时把同一函数注册为`__close`，但下次调用先进入`sock:write`，后者取得nil `sock.conn`并在`write_frame`执行`conn:write(...)`时抛异常，closed guard甚至晚于不可达。现有测试只做单次显式close，既未验证clean handshake，也未覆盖重复close/to-be-closed组合。
- 建议解法：为 socket 引入 OPEN/CLOSING/CLOSED 及 sent_close/received_close。集中编码/解析合法 status 与 reason；收到首个 Close 自动或由受控 API 回应，禁止后续 data write。`close()` 发起 handshake 后等待 peer Close，并按角色执行 TCP close；加入有限 deadline 防止对端不响应。CLOSED上的`close/__close`必须幂等且不抛异常，write/read返回稳定closed错误；协议错误使用适当 status，底层异常则标记 unclean。
- 后续回归条件：修复阶段覆盖空 payload、1 byte、合法 code/reason、1005/1006/1015 等禁止 code、未知合法范围、双方同时 close、Close 后 write/read、peer 不响应 timeout，以及 client/server 谁先 TCP close；另覆盖手动close两次、只用`<close>`、显式close后作用域退出及异常展开，断言资源只关闭一次且原异常不被cleanup覆盖。本轮不新增测试代码。

### WS-008 — P1 — client masking key 来自可预测的小空间弱随机源

- 状态：已确认；RFC 6455 明确安全要求与确定性随机源推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 6455 §5.3 要求 client 为每帧从允许的完整 32-bit 值中选择新的 masking key，必须来自强熵源，且当前 key 不能让 server/proxy 轻易预测后续 key；规范指出不可预测性是阻止恶意应用控制 wire bytes、实施 HTTP intermediary/cache poisoning 的必要条件。§4.1 的 16-byte Sec-WebSocket-Key 同样要求每连接随机选择。
- 位置：`lualib/silly/net/websocket.lua:104-127`、`:292-320`、`luaclib-src/crypto/lutils.c:15-23`、`src/engine.c:125-151`、`src/silly_conf.h:84`。
- 触发：任何 WebSocket client frame 与 opening handshake 都会调用 `utils.randomkey`；攻击者观察一个或多个 key，或推测进程启动秒数后预测 PRNG 序列。
- 影响：每个 mask byte 只可能是 `a`..`z`，单帧 key 空间仅 `26^4 = 456,976`，远小于 32-bit；PRNG 由进程启动时的秒级时间 seed，且不是密码学安全生成器。恶意 client-side 数据源与协作 server/proxy 可以恢复/预测 mask，使攻击者控制线上 masked bytes，削弱 WebSocket 为保护 HTTP intermediaries 设计的核心安全机制。握手 nonce 也只有约 75 bits 字母空间且可预测，直接违反随机 16-byte 要求。
- 证据：`lrandomkey` 对每个字节执行 `random() % 26 + 'a'`；engine 只调用 `srand(time(NULL))`。Windows 配置还把 `random()` 映射到 `rand()`。`write_frame` 每次直接取该函数的 4 bytes 作为 mask，connect 用同函数的 16 bytes 作为 Key，没有操作系统 CSPRNG/OpenSSL `RAND_bytes`。
- 建议解法：将 `randomkey` 改为操作系统 CSPRNG 或 OpenSSL `RAND_bytes`，返回任意 octet；失败必须显式传播，不能降级到 `rand/random`。mask 每帧独立读取 4 bytes，handshake 每连接独立读取 16 bytes。通用 crypto API 名称也应避免把弱随机实现暴露给其他安全用途。
- 后续回归条件：修复阶段用可注入 RNG 验证每帧都会请求新的 4 bytes、handshake 请求 16 bytes、失败停止发送；统计测试只作辅助，核心断言是调用 CSPRNG 且不做 `%26`/time seed。并检查 fork/Windows/macOS 的实现。本轮不新增测试代码。

### WS-009 — P2 — client hostname 固定单次 A lookup，缺少 IPv6 与多地址回退

- 状态：已确认；WebSocket 独立 connect 路径与 DNS 返回集合的确定性静态核对。本轮不执行 DNS 或连接。
- 位置：`lualib/silly/net/websocket.lua:292-323`，其中固定 `dns.lookup(u.host, dns.A)` 并只构造一个 endpoint；DNS `lookup` 只取首结果在 `lualib/silly/net/dns.lua:641-654`，`resolve` 可返回多条 A/AAAA 在 `:588-640`。
- 触发：`ws://` 或 `wss://` hostname 只有 AAAA，或有多个 A/AAAA 但首个 IPv4 地址不可达、后续地址健康；直接 IP literal 不走同一 DNS 分支。
- 影响：IPv6-only WebSocket 服务无法连接，多地址服务在单一地址故障时也没有故障转移；TLS/HTTP Upgrade 尚未开始就返回失败。长连接常依赖 DNS 负载均衡与滚动迁移，固定首 A 会把局部故障放大为完整会话不可用，重试仍可能反复选择同一答案首项。
- 证据：connect 只保存一个 `ip`，执行一次 `join_addr` 以及一次 `tcp.connect` 或 `tls.connect`，任一步失败立即 return。文件没有 AAAA 查询、`dns.resolve` 候选循环、family 排序或 Happy Eyeballs；与 HTTP client/cluster 是三份独立实现，不能由其修复自动覆盖。
- 根因：WebSocket transport 把 hostname 解析建模为单个 IPv4 字符串，而不是带共同 deadline 与取消的地址候选连接过程。
- 建议解法：抽取 HTTP/WS/gRPC/cluster 共用的 endpoint resolver+dialer：收集 A/AAAA，按 RFC 8305 排序/错峰或至少顺序尝试全部候选，共享 absolute deadline 并关闭输家。WSS 始终用原 hostname 做 SNI/证书验证，错误聚合保留各地址诊断；literal 保持单候选。
- 后续回归条件：修复阶段用注入式 resolver/connector 覆盖 AAAA-only、A-only、双栈/多 A 首地址失败后成功、全部失败、慢首/快次及 IPv4/IPv6 literal；断言候选共享 deadline、资源释放且 WSS hostname 不被 IP 替换。当前不执行 DNS 或连接。

### WS-010 — P1 — client opening handshake 没有端到端 deadline 或取消入口

- 状态：已确认；公开 API 与 DNS/TCP/TLS/H1 调用链的确定性静态核对。本轮不连接 silent peer，也不运行超时场景。
- 位置：`lualib/silly/net/websocket.lua:292-336`；底层可选 timeout 入口位于 `lualib/silly/net/dns.lua:585-654`、`lualib/silly/net/tcp.lua:190-210`、`lualib/silly/net/tls.lua:282-323`，无 response-header timeout 的 H1 wait 位于 `lualib/silly/net/http/h1.lua:512-553,604-629`；公开签名见 `docs/src/reference/net/websocket.md:111-145` 和英文同名文档。
- 触发：连接目标在 TCP connect、TLS handshake 或 HTTP Upgrade response 的任一阶段保持 silent/极慢；DNS 多个 CNAME/search 候选也可能重复消耗各自预算。调用方只能传 `url, header`，不能设置总 deadline、dial timeout 或 cancel token。
- 影响：`websocket.connect` 可长期占住调用协程及半建连 socket；在成功返回 `sock` 之前，调用方没有连接句柄可从另一个 task 关闭。面向不可信或故障 endpoint 的自动重连会累积挂起任务/连接，且上层无法给一次 opening handshake 建立确定的延迟和资源边界。
- 证据：DNS 调用不传可选 timeout；`tcp.connect(a)` 不传 opts，`tls.connect` 只传 hostname；发送 Upgrade 后 `stream:waitresponse()` 的 response-line/header reads 均不传 timeout。`M.connect` 没有 opts 参数或 timer/cancel 分支。底层 TCP/TLS 已实现 connect timeout，说明缺陷位于 WebSocket adapter 没有暴露和贯穿它；H1 的 `request` timeout 只用于 `Expect: 100-continue`，不覆盖这里的 GET response。
- 根因：opening handshake 被实现为若干同步等待的串联，而没有代表一次 logical connect 的 absolute deadline/context；各层可选 timeout 也没有统一预算或 cleanup owner。
- 建议解法：为 `connect` 增加向后兼容 opts（保留 header 的明确位置），至少提供 absolute deadline/cancel 与可选 dial/handshake timeout。入口计算 monotonic deadline，将剩余时间贯穿 DNS、所有地址尝试、TCP、TLS 和 Upgrade response header；到期/取消必须关闭当前 generation 的连接并返回明确错误。不要让每一阶段重新获得完整 timeout。
- 后续回归条件：修复阶段用注入式阶段阻塞分别覆盖 DNS、TCP、TLS 和 response-line/header，断言同一 absolute deadline 内返回、socket/timer/task 清理且取消不会关闭已被新连接复用的 generation；另覆盖正常成功、即时失败和接近 deadline 的竞态。当前不执行网络或时序测试。

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
- 触发：路径A：peer在没有收到足够stream WINDOW_UPDATE时，向同一open stream发送累计超过已广告65,535 octets的DATA；connection方向同样可超过当时有效credit。路径B：守规peer持续发送带padding的DATA，应用持续读取；最小化例子可让每个frame主要由Pad Length和padding构成，直到其合法发送窗口耗尽。
- 影响：路径A中Silly不会以stream/connection `FLOW_CONTROL_ERROR`拒绝超额数据，而继续append到`s.recvbuf`，恶意peer可绕过慢消费者内存边界。路径B中Silly只回补content bytes，Pad Length和padding消耗的credit永久丢失；即使应用已消费全部content，守规peer最终仍把两层window降到0并停止发送，形成确定性stream乃至整连接停顿。connection-level自动回补不能替代正确的完整payload记账。
- 证据：channel只有发送窗口`sendwindow`和待回补`recvwindebt`；stream同样没有receive-window remaining。`read_frame`先从payload删除1-byte Pad Length和全部padding，之后`frame_data`才以裁剪后的`#dat`调用`channel_windebt`、累计stream debt并append；规范要求计入的是裁剪前完整DATA payload。两层都不减remaining、不检查负值；stream debt又只有应用读取时由`stream_flush`回补。因而超额未读DATA被接受与合法padding永不完整返还两个路径都确定成立。
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

### HPACK-001 — P2 — encoder 改变 maximum table size 后不发送 wire update

- 状态：已确认；RFC 7541 与确定性 encoder 输出路径推导。本阶段只做静态 review，不新增复现代码。当前 HTTP/2 integration 因 `H2-004` 误改 decoder 而遮蔽此路径；修正方向后本问题立即成为必经路径。
- 规范：RFC 7541 §4.2 要求协议改变 encoder dynamic table maximum 后，必须在变化后的第一个 header block 开头发送 dynamic table size update；两次 header block 之间多次变化时，期间最小值和最终值都必须按规则表达。§6.3 定义 001xxxxx/5-bit prefix 的 wire representation，并要求 update 出现在任何 header field representation 之前。
- 位置：HPACK context/init 和 pack 在 `luaclib-src/lhttp.c:246-260,489-548`，decoder 已实现 size update 解析在 `:747-771`，`lhpack_hardlimit` 在 `:782-791`；调用契约在 `lualib/types/silly/http2/hpack.lua:7-25`。
- 触发：对 encoder context 调用 `hpack.hardlimit(ctx, new_size)` 后编码下一 header block；典型 HTTP/2 场景是收到 peer 的 `SETTINGS_HEADER_TABLE_SIZE=0`、缩小后恢复，或两个 header block 之间连续缩小/增大。
- 影响：peer decoder 不会获知 encoder 已选择的新 maximum，双方 dynamic table capacity/state 不按规范同步。缩小时 peer 无法按要求及时驱逐旧条目，恢复/后续变更时可能出现 index context 差异或严格 decoder 拒绝；更直接地，修复 `H2-004` 后仍无法满足 peer 对 table size 的 wire-level同步要求。
- 证据：`lhpack_hardlimit` 只覆盖 `hard_limit/soft_limit` 并立即 `try_evict`，context 没有 pending/current-advertised/min-pending 字段。`lhpack_pack` 初始化 buffer 后直接遍历 pseudo/普通 fields 并调用 `pack_field`，没有在首字段前调用 `write_varint(..., 0x01, size, 5)` 或任何等价 0x20-prefixed update。相反 decoder 端已有对 `(n & 0xe0)==0x20` 的解析，说明 wire format 只实现了一半。
- 根因：同一个 `hardlimit` API 混合 encoder/decoder 本地上限语义，却没有 encoder 所需的延迟 wire synchronization state；现有测试通过同时修改两端 context 或保留更大 decoder 上限，绕过了同步要求。
- 建议解法：区分 encoder maximum update 与 decoder hard limit API。encoder 记录 last-emitted、pending-final 和 interval-minimum；下一次 `pack` 在任何 field 前按 RFC 最多发送两个 size updates，再更新 emitted state。decoder hard limit 仍只约束接收的 size update。处理多次变化、0→恢复以及无字段 header block。
- 后续回归条件：修复阶段直接断言 header block 首字节/varint；覆盖单次减小、增大、连续减小→增大、连续增大→减小、0→恢复、empty headers，以及 update 出现在 field 后必须解码失败。使用独立 decoder，只通过 wire update 同步，禁止测试直接替 decoder 调 `hardlimit`。本轮不新增测试代码。

### H2-005 — P2 — server 用 client 的并发上限限制 client 自己的 request streams

- 状态：已确认；RFC 9113 与确定性 SETTINGS/stream-open 路径推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §5.1.2/§6.5.2 规定 `SETTINGS_MAX_CONCURRENT_STREAMS` 是有方向的：发送者声明自己允许接收者创建多少 concurrent streams。server 发送的值限制 client request streams；client 发送的值只限制 server-initiated streams（即 push），不能反向减少该 client 被 server 允许创建的 request streams。
- 位置：共享 channel limit 在 `lualib/silly/net/http/h2.lua:151-160,239-263`；client open 使用在 `:618-659`；SETTINGS 覆盖在 `:1211-1278`；server request 接收限制在 `:1555-1648`。
- 触发：client 在连接前言或后续 SETTINGS 中发送 `SETTINGS_MAX_CONCURRENT_STREAMS=0` 或任意小于 server 已广告额度的值，然后在合法 server limit 内创建新的奇数 request stream。
- 影响：server 错误地以 `REFUSED_STREAM` 拒绝规范允许的 client 请求；一个 client 能改变“server 允许该 client 创建”的额度方向，造成连接无请求可用、重试循环或显著互操作失败。当前 server 不实现 push，所以 client 的该 setting 对 server 实际应当没有可执行的 outbound stream 限制。
- 证据：client/server 共用 `frame_settings`，id 3 无条件执行 `ch.streammax = val`。同一字段在 client 的 `openstream/isfull` 中用于正确限制本端新请求，也在 server `frame_header_server` 中以 `stream_count >= stream_max` 限制收到的新请求；channel 没有分开的 local-advertised inbound limit 与 peer-advertised outbound limit。双方正常握手都发 100，数值相同掩盖了方向错误。
- 根因：用一个 `streammax` 表示两套独立的 directional limits，并让共享 SETTINGS handler 与 server inbound admission 共用它。
- 建议解法：拆成 `peer_max_concurrent`（限制本端发起 stream）与 `local_max_concurrent`（本端已广告、校验 peer 发起 stream）。client 收到 server setting 更新前者；server 收到 client setting 只影响 push/outbound server streams。server request admission 始终使用本端已广告 limit，若配置变化则按 RFC 处理既有 streams。
- 后续回归条件：修复阶段使用非对称 limit：server=3/client=0，断言 client 仍可开 3 个 request、server 不发 push；server=1/client=100，第二个并发 request 被正确拒绝。再覆盖运行时增减、0 的短期行为、已打开 stream 计数和 client open wait queue 唤醒。本轮不新增测试代码。

### H2-006 — P2 — malformed PRIORITY 被升级为 connection error

- 状态：已确认；RFC 9113 与确定性错误分支推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §6.3 要求长度不是 5 octets 的 PRIORITY frame 作为 `FRAME_SIZE_ERROR` stream error 处理。PRIORITY 的 stream-id 0 仍是 `PROTOCOL_ERROR` connection error；两种条件的错误作用域不能混同。
- 位置：`lualib/silly/net/http/h2.lua:1281-1310`，connection/stream error helper 在 `:548-617,882-894`。
- 触发：peer 在任意非零 stream id（包括 PRIORITY 允许出现的 idle/closed id）发送 payload 长度不等于 5 的 PRIORITY frame。
- 影响：实现发送 GOAWAY 并清除整条 HTTP/2 connection 上的所有 active streams，而规范只要求隔离所标识 stream。一个单流 malformed/deprecated priority signal 因而会中断其他无关并发请求，扩大可用性影响并破坏严格错误恢复语义。
- 证据：函数先正确拒绝 stream-id 0；随后 `if #dat ~= 5 then channel_goaway(ch, FRAME_SIZE_ERROR)`，明确走 connection error。项目已有 `stream_reset(id, ch, errorcode)` 可生成 RST_STREAM，但该长度分支未使用。PING/RST_STREAM/SETTINGS 等影响 connection state 的固定长度错误使用 GOAWAY 是不同规范规则，不并入本问题。
- 根因：将固定长度 frame 的 `FRAME_SIZE_ERROR` 统一理解为 connection error，遗漏 RFC 9113 对 PRIORITY 的显式 stream-error 例外。
- 建议解法：将非零 stream 的 PRIORITY 长度错误改为 `stream_reset(streamid, ch, FRAME_SIZE_ERROR)`，并确保该错误不会清除其他 streams；stream-id 0 的优先 `PROTOCOL_ERROR` connection 分支保持不变。还需按 stream state 验证 idle/closed PRIORITY 的允许规则。
- 后续回归条件：修复阶段覆盖长度 0/4/6、stream-id 0 与非零、idle/open/closed stream；断言只有 id 0 终止 connection，非零只产生对应 RST_STREAM，其他并发 stream 可继续。合法 5-byte PRIORITY 仍被忽略且不改变 stream state。本轮不新增测试代码。

### H2-007 — P2 — 过短 GOAWAY payload 被当作合法 shutdown 接受

- 状态：已确认；RFC 9113 与确定性 handler 推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §6.8 的 GOAWAY payload 必须至少包含 4-byte Last-Stream-ID 和 4-byte Error Code，之后才是可选 debug data；§4.2 要求小到无法包含 mandatory frame data 的 frame 发送 `FRAME_SIZE_ERROR`，stream-id 0 frame 的 size error 属于 connection error。
- 位置：`lualib/silly/net/http/h2.lua:1357-1367`；通用 dispatch 在 `:1425-1448`。
- 触发：peer 在 stream 0 发送 payload 长度 0..7 的 GOAWAY frame；空 payload 是最小触发。
- 影响：Silly 将 malformed control frame 当作合法 GOAWAY，设置 `ch.goaway=true` 而不发送 `FRAME_SIZE_ERROR`。client 会停止新建 stream，却无法得到 last-stream/error 语义；server 也接受无效关闭信号。畸形 peer 因而能以非规范 frame 改变连接状态并掩盖真实协议错误，造成挂起或错误诊断。
- 证据：`frame_goaway(ch, streamid, _, _)` 明确丢弃 flags 与 payload；除 `streamid ~= 0` 外没有任何长度检查或 `unpack`，随后直接置 `ch.goaway = true`。因此所有 0..7-byte payload 都走成功路径，8-byte mandatory structure 也未被验证/读取。
- 根因：GOAWAY 被简化为单一布尔通知，未实现其最小 wire structure。
- 建议解法：先检查 `#dat >= 8`，否则 `channel_goaway(ch, FRAME_SIZE_ERROR)`；再解析 reserved-masked Last-Stream-ID 与 Error Code，保留可选 debug data 的 opaque 语义。last-stream/error 对 active streams 的处理需要与 `H2-008` 的 retry/完成边界一起修复。
- 后续回归条件：修复阶段覆盖长度 0/7/8/9、非零 stream-id、reserved bit、任意 error code 与 debug bytes；断言过短为 connection `FRAME_SIZE_ERROR`，合法 8+ bytes 被完整解析且 debug data 不影响结构。本轮不新增测试代码。

### H2-008 — P1 — GOAWAY 不处理 Last-Stream-ID，未处理请求可无限等待

- 状态：已确认；RFC 9113 与确定性 stream/high-level wait 路径推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §6.8 要求 GOAWAY 的 Last-Stream-ID 表示发送者可能处理过的最高 peer-initiated stream。接收者不得再开新 stream；自己已发送但 id 高于该值的 streams 被保证未处理，可以在新连接重试；低于等于该值的在途 streams仍可能完成。实现必须保存并按此边界区分，而不能把所有 stream 当成同一种状态。
- 位置：GOAWAY handler 在 `lualib/silly/net/http/h2.lua:1357-1367`，dispatch/stream wait 在 `:790-864,1088-1123,1425-1448`；高层同步 request/readall 在 `lualib/silly/net/http/client.lua:318-390`。
- 触发：server 在 client 已创建多个请求后发送合法 GOAWAY，Last-Stream-ID 小于至少一个在途 stream id，并按规范继续处理低编号 streams、忽略高编号 streams且暂不关闭 TCP。
- 影响：高编号 stream 没有 response、END_STREAM 或 RST，本端也不主动结束/唤醒它；`stream:readall()` 默认 timeout 为 nil，高层 `httpc:get/request` 同样没有强制 deadline，因此调用可无限挂起。库还丢失“保证未处理”的 retryability 信息，无法安全自动重试；若粗暴等 TCP close，又会把可能已处理的低编号非幂等请求与确定未处理请求混淆。
- 证据：`frame_goaway` 的 payload 参数名为 `_` 且唯一动作是 `ch.goaway=true`。它不遍历 `ch.streams`，不调用 `stream_remoteend/writewakeup`，也不保存 last-stream/error。dispatch 继续在仍活跃的 TCP 上读 frame；只有底层连接最终关闭才由 `channel_clearstream` 唤醒全部 streams。高层 `do_with_redirects` 直接无 timeout 调用 `stream:readall()`，且没有 GOAWAY-aware retry 分支。
- 根因：将 GOAWAY 建模成“禁止新 stream”的布尔值，遗漏 graceful shutdown 的 per-stream processed boundary 与 retry contract。
- 建议解法：解析并单调收紧 peer Last-Stream-ID/error code；立即将本端发起且 id 大于边界的 streams 标记为明确未处理，解除 read/write wait，并向上返回结构化 retryable error。低编号 streams 保持可完成；连接池不再选该 channel 开新 stream。自动重试只能对确定未处理的 streams，且需要保留 body replayability/cancellation 规则，不能按 method 猜测后无条件重放。
- 后续回归条件：修复阶段并发创建 id 1/3/5，收到 last=3 的 NO_ERROR GOAWAY 后断言 id5 立即以 retryable-unprocessed 结束、id1/3 可继续完成、新请求走新连接；覆盖多次 GOAWAY 边界只能下降、非 NO_ERROR、非幂等 body、不可重放 body、peer 长时间不关 TCP和 connection close race。本轮不新增测试代码。

### H2-009 — P2 — client 不验证 response/trailer field section

- 状态：已确认；RFC 9113 与确定性 header mapping 路径推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §8.1.1/§8.2/§8.3 要求 uppercase/非法 field name/value、connection-specific fields、无效或位置错误/重复的 pseudo-header 都使 message malformed。response 只定义且必须恰有一个 `:status`，所有 pseudo 必须位于普通 fields 之前；trailer 不得包含任何 pseudo-header。HTTP status-code 语法是恰好三位数字，不能用通用数值语法替代。
- 位置：ordered HPACK list 到 map 的路径在 `lualib/silly/net/http/h2.lua:314-384`；client response/trailer handler 在 `:1441-1500`。server request 有独立 `check_req_header` 在 `:386-444`，不属于本条遗漏方向。
- 触发：server 返回例如普通 field 后的 `:status`、`:method`/未知 pseudo、uppercase `Content-Type`、`connection`/`transfer-encoding`，或 trailer 中的 `:status`；也可将 status 编成 `2e2`、`200.5`、`+200` 等 Lua `tonumber` 可接受的字符串。
- 影响：client 不把规范定义的 malformed response 限制在错误 stream，而是将无效 fields 交给应用并继续读取 body。应用、代理/转发层和缓存可能以不同规则解释这些字段，产生状态码、hop-by-hop 元数据或 trailer 语义混淆；非法 status 可被转换成 200/浮点数并驱动成功/重定向等上层分支。部分重复 `:status` 因变成 table 会偶然失败，但不能替代完整验证。
- 证据：`frame_header_client` 解压后立即 `map_header(hlist, header)`，没有调用与 `check_req_header` 对称的 response validator；仅取 `header[":status"]` 后执行 `tonumber(status)`。后续 HEADERS 直接 `map_header(hlist, s.trailer)`，同样无 lowercase/pseudo/forbidden 检查。`map_header` 会保留所有未知 key 并把重复值合成 table，不保留供验证 pseudo ordering 的额外状态。
- 根因：request-side field validator 没有抽象为按 context（request/response/trailer）复用的 ordered-list validator，client 依赖 map 后的弱类型检查。
- 建议解法：在 `map_header` 前验证 ordered hlist：严格 name/value 通用语法与 lowercase；initial response 只允许一个、位于最前部 pseudo 区的 `:status`，值匹配三位 status-code 且排除 HTTP/2 禁止的 101；trailer 禁止所有 pseudo；所有 section 拒绝 connection-specific fields。malformed response 按 §8.1.1 作为 stream error 处理，不应默认杀死无关 streams。
- 后续回归条件：修复阶段覆盖 request pseudo 出现在 response、unknown/duplicate/late `:status`、0/2/4 位与指数/小数 status、uppercase/非法 name/value、五种 connection-specific fields，以及 trailer pseudo；断言对应 stream 失败且并发 stream 保持可用。合法重复普通 fields 与 set-cookie 仍保序。本轮不新增测试代码。

### H2-010 — P2 — client 将 informational response 当成 final response

- 状态：已确认；RFC 9113 与确定性 response state 推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §8.1 允许 server 在 final response 前发送任意数量的 informational 1xx responses；response sequence 必须是零个或多个 interim HEADERS，随后恰好一个 non-informational final HEADERS。带 END_STREAM 的 informational HEADERS 是 malformed，101 在 HTTP/2 中禁止。client 只有收到 final response 才能进入最终 response/body/trailer 状态。
- 位置：client HEADERS handler 在 `lualib/silly/net/http/h2.lua:1441-1500`；`waitresponse/readall` 在 `:1075-1123`；高层读取路径在 `lualib/silly/net/http/client.lua:354-390`。
- 触发：server 对请求先发送合法 `:status=100`、`102` 或 `103` HEADERS（不带 END_STREAM），再发送正常 2xx/其他 final HEADERS 和可选 body。
- 影响：client 把第一个 1xx 写入 `s.status`、设置 `STATE_HEADER` 并唤醒 `waitresponse`；真正 final field section 被误分类为 trailer，`:status`/final headers 不会成为公开 response header。高层最终返回 1xx status 与错误 headers/body 组合，可能绕过按 final status 执行的重定向、成功/错误处理或 gRPC HTTP 状态判断。
- 证据：`frame_header_client` 仅以 `remotestate == STATE_NONE` 判断 initial response；解析出 `nstatus` 后不分 `nstatus // 100 == 1`，无条件 `s.status=nstatus`、`s.remotestate=STATE_HEADER` 并唤醒 header waiter。下一 HEADERS 因 state 非 NONE 直接进入 `else`，设置 `STATE_TRAILER` 并 `map_header(..., s.trailer)`。文件没有 interim response collection/state。
- 根因：response state machine 只有 NONE→HEADER→TRAILER，没有 INTERIM 循环与 FINAL 边界；把“第一个 field section”错误等同于“final response”。
- 建议解法：在严格 field validation 后解析 status：对合法 1xx（排除 101）保持等待 final，可通过独立回调/列表暴露 interim metadata，但不得覆盖 final header/status；拒绝 informational END_STREAM。收到首个非 1xx 才进入 final HEADER、设置公开 status/header 并唤醒 `waitresponse`，之后只允许 terminating trailer。
- 后续回归条件：修复阶段覆盖无 interim、单个 100/103、多个 1xx、101、1xx+END_STREAM、1xx 后连接关闭、1xx→204/200+body/final trailer；断言 `waitresponse` 只在 final 时完成，最终 status/header 不被 interim 污染。本轮不新增测试代码。

### H2-011 — P2 — client 接受不终止 stream 的 trailer 并允许其后 DATA

- 状态：已确认；RFC 9113 与确定性 response/stream state 推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §8.1 要求 trailer field section 由带 END_STREAM 的 HEADERS 开始，并因此终止 message/stream；收到 final response 后，任何不带 END_STREAM 的额外 HEADERS 都必须把 response 视为 malformed。trailer 之后不可能再有 DATA 或第二个 trailer section。
- 位置：client HEADERS handler 在 `lualib/silly/net/http/h2.lua:1441-1500`；DATA state check/transition在 `:1177-1204`。server request trailer 路径 `:1632-1648` 已显式要求 END_STREAM，不属于本条。
- 触发：server 先发送 final response HEADERS，随后发送第二个不带 END_STREAM 的 HEADERS，再发送 DATA、更多 HEADERS或最终 END_STREAM。
- 影响：client 接受规范定义的 malformed response，提前把额外字段公开为 trailer，却继续把后续 bytes 当 message body。应用看到的 body/trailer 边界与严格 HTTP/2 endpoint 不同；如果上层在见到 trailer 后认为校验/签名/status 已最终确定，后续 DATA 会破坏完整性假设。重复 trailer 也会继续合并。
- 证据：当 `remotestate ~= STATE_NONE` 时，`frame_header_client` 无条件执行 `s.remotestate=STATE_TRAILER` 和 `map_header`，只在 flag 恰有 END_STREAM 时调用 `stream_remoteend`，没有缺 flag 的 error 分支。随后 `frame_data` 仅拒绝 `remotestate >= STATE_CLOSE`；STATE_TRAILER=3 小于 STATE_CLOSE=0x10，所以接受 payload 并无条件改写为 STATE_DATA。
- 根因：自定义线性 state 常量没有强制单调转换，且 client trailer 分支遗漏 server 侧已有的 END_STREAM guard。
- 建议解法：final response 后第二个 HEADERS 必须同时满足 trailer field 规则与 END_STREAM，否则对该 stream 报 `PROTOCOL_ERROR`；成功 trailer 直接进入 END。DATA handler 只允许合法 open/half-closed local 且 message phase 为 pre-trailer body，禁止 TRAILER→DATA 回退；第三个 HEADERS 永远拒绝。
- 后续回归条件：修复阶段覆盖 final→trailer(END_STREAM)、final→trailer(no END_STREAM)、trailer 后 DATA/HEADERS、空 trailer、分片 CONTINUATION trailer，以及与 informational response 的组合；断言 malformed 只 reset 对应 stream，合法并发 stream不受影响。本轮不新增测试代码。

### H2-012 — P2 — 普通 CONNECT 的 pseudo-header 生成与校验均相反

- 状态：已确认；RFC 9113 与确定性 sender/recipient 路径推导。本阶段只做静态 review，不新增复现代码；RFC 8441 extended CONNECT 另行按是否宣称支持检查。
- 规范：RFC 9113 §8.5 规定普通 CONNECT 的 `:method` 必须为 CONNECT，`:authority` 必须包含目标 host:port，而 `:scheme` 和 `:path` 必须省略；不满足即 malformed。§8.3.1 的一般 method/scheme/path 必需集合明确对 CONNECT 例外。
- 位置：request pseudo mask/validator 在 `lualib/silly/net/http/h2.lua:126-133,386-444`；client header generation 在 `:700-738`；generic request API 在 `:939-956` 和 `lualib/silly/net/http/client.lua:302-341`。
- 触发：通过公开 generic request API 发送 method `CONNECT`，或外部规范 client 向 Silly HTTP/2 server 发送合法 CONNECT field section。
- 影响：Silly client 总是产生 peer 必须视为 malformed 的 CONNECT；Silly server 则会拒绝合法 CONNECT，并可能接受同时含 scheme/path、缺 authority 的非法变体。代理隧道、基于 CONNECT 的上层协议和兼容性因此不可用；若应用自行解释错误 pseudo 集合，还可能把空/错误 authority 当作目标。
- 证据：client `stream_writeheader` 对所有 active streams 无条件编码 `:authority/:method/:path/:scheme`。server 的 `pseudo_must_mask=0x07` 固定要求 method、scheme、path；`check_req_header` 不根据 `:method` 分支，最终只比较该 mask，且从不要求 authority。故发送端与接收端都没有 CONNECT 例外。
- 根因：用一套固定 request pseudo schema 处理所有 methods，没有在完整 ordered field list 验证后按 method 选择普通/CONNECT 控制数据规则。
- 建议解法：sender 对普通 CONNECT 只编码 method+authority，path API 参数不得落到 wire；recipient 先收集并验证唯一 pseudo，再按 method 检查：CONNECT 必须 authority、禁止 scheme/path，普通请求要求 method/scheme/path并按 URI 情况处理 authority。若实现 RFC 8441，则只有成功协商 `SETTINGS_ENABLE_CONNECT_PROTOCOL` 后才允许额外 `:protocol` 与 extended CONNECT 的不同集合。
- 后续回归条件：修复阶段覆盖合法 CONNECT、缺/空 authority、误带 scheme/path、普通 GET 缺 scheme/path、authority-form host:port，以及 client wire field 集合；另覆盖未协商 `:protocol` 必须拒绝，不把普通 CONNECT 与 RFC 8441 混为一类。本轮不新增测试代码。

### H2-013 — P1 — HPACK 解压后 field section 没有资源上限

- 状态：已确认；RFC 9113 安全要求与确定性解压/映射路径推导。本阶段只做静态 review，不新增复现代码。
- 规范：RFC 9113 §10.5 要求实现跟踪可能被滥用的 field compression 等特性并设置使用上限；§10.5.1 明确 uncompressed field block 可迫使 endpoint 承诺大量内存，可用 `SETTINGS_MAX_HEADER_LIST_SIZE` 提示 peer，但 setting 只是 advisory，receiver 仍需按自己可处理的大小拒绝/丢弃。其计算口径为每个 field 的 name length + value length + 32。
- 位置：唯一 wire cap 在 `lualib/silly/net/http/h2.lua:74-80,314-365`，解压后 list/map 在 `:331-384`；HPACK decoder 在 `luaclib-src/lhttp.c:696-780`。HTTP listener/client 配置均没有 HTTP/2 header limits。
- 触发：peer 用大量短 indexed representations、重复 fields 或 Huffman/literal fields 构造 compressed size 不超过 65,535 的 field block，使解压后字段数量/总尺寸远大于 wire size；对多个并发 streams 重复发送。server 侧还可利用 `H2-005` 先把错误使用的 `streammax` 调大。
- 影响：decoder 先把全部 key/value 放入 Lua `header_list`，随后 `map_header` 再为重复字段扩展数组并让 stream/header 持有结果，CPU、Lua table slots 和字符串内存可显著放大。并发请求可耗尽进程内存或长时间占用 worker；没有 per-connection/global budget、deadline 或配置让部署收紧。65,535 compressed-byte cap 只给单 block 一个较大的 wire 上限，不限制协议定义的 uncompressed cost。
- 证据：`max_header_wire_size` 只累计 HEADERS/CONTINUATION 的 `#d`。`hpack_unpack` 每解出一个 representation 就连续写入 `header_list`，没有 header-list-size 参数或累计值；`map_header` 再遍历全部结果。代码不发送 `SETTINGS_MAX_HEADER_LIST_SIZE`，收到 peer 的该 setting也只注释为 advisory 后忽略（发送约束也未实现）。
- 根因：把 compressed frame/block size 当成 header 资源预算，没有在 HPACK decoder 的增量解码点计算 uncompressed HTTP/2 field-section size，也没有把限制暴露到 server/client 配置。
- 建议解法：增加可配置的 per-field、field-count、uncompressed field-section 和 connection-level pending-header budgets；HPACK 解码时按 name+value+32 增量计数，超限时仍按 RFC 维护 compression state，但停止构造/保留应用列表，随后 server 返回 431 或 reset stream、client 丢弃 response。向 peer 广告合理 `SETTINGS_MAX_HEADER_LIST_SIZE`，但不能依赖 peer 遵守。
- 后续回归条件：修复阶段覆盖大量 1-byte indexes、单大 literal/Huffman、重复 fields、恰好 limit/limit+1、CONTINUATION、多并发 streams、超限后下一合法 block 的 HPACK state 仍同步，以及配置/setting 的方向性。本轮不新增测试代码。

### H2-014 — P2 — half-closed(remote) 上的 DATA 被升级为 connection error

- 状态：已确认；RFC 9113 stream state 与确定性 handler 分支推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §5.1 规定，endpoint 收到 END_STREAM 后，该 stream 对接收方向进入 `half-closed (remote)`；此后若再收到 DATA 等非 WINDOW_UPDATE/PRIORITY/RST_STREAM frame，必须只对该 stream 返回 `STREAM_CLOSED` stream error。已经完全 closed 的 stream 也至多允许按规范用 connection `STREAM_CLOSED` 处理，不能改报 `PROTOCOL_ERROR`。
- 位置：自定义 state 常量在 `lualib/silly/net/http/h2.lua:64-70`，END_STREAM transition 在 `:845-877,1202-1204`，DATA guard 在 `:1177-1186`。
- 触发：任一合法 stream 先收到带 END_STREAM 的 HEADERS 或 DATA，使 `s.remotestate=STATE_END`；peer 随后在同一 id 发送 DATA。连接上同时存在其他正常 streams 时可直接观察错误作用域。
- 影响：单个 stream 的 late/malformed DATA 会触发 GOAWAY、清空 channel 中所有 active streams 并关闭复用连接，而不是只 reset 违规 stream。恶意或有竞态的 peer 因而能用一个 stream 中断其他无关请求，客户端/服务端也无法按 HTTP/2 规定隔离错误。
- 证据：`frame_data` 将 `not s` 与 `s.remotestate >= STATE_CLOSE` 合并，统一调用 `channel_goaway(ch, PROTOCOL_ERROR)`。`STATE_END=STATE_CLOSE|1` 正好覆盖收到 END_STREAM 的 half-closed(remote)；项目已有 `stream_reset(id, ch, STREAM_CLOSED)`，但该分支未使用。`channel_goaway` 对非 NO_ERROR 会立即 `channel_clearstream`，所以影响确定扩散到整连接。
- 根因：内部 message-phase state 被直接代替 RFC 的双向 stream state，并把 idle、half-closed(remote) 与 closed 三种来源合并成一个 connection-error 分支。
- 建议解法：先按 stream id 历史和双向状态分类：idle DATA 保持 connection `PROTOCOL_ERROR`；half-closed(remote) DATA 使用 `stream_reset(id, ch, STREAM_CLOSED)`；closed stream 按 §5.1 的 race 例外和最小必要处理决定忽略或 connection `STREAM_CLOSED`。不要让 late DATA 覆盖既有 terminal state。
- 后续回归条件：修复阶段覆盖 HEADERS+END_STREAM 后 DATA、DATA+END_STREAM 后 DATA、open stream DATA、never-opened id DATA、RST 后在途 DATA，以及两个并发 streams；断言 half-closed(remote) 只产生该 id 的 RST_STREAM(STREAM_CLOSED)，idle 才产生 connection PROTOCOL_ERROR，其他 stream 可继续。本轮不新增测试代码。

### H2-015 — P1 — client 将 closed stream 的 WINDOW_UPDATE 误判为 idle 并断连接

- 状态：已确认；RFC 9113、client stream-id bookkeeping 与确定性 close/update 路径推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §5.1/§6.9 明确允许 peer 在发送 END_STREAM 后继续发送 WINDOW_UPDATE；receiver 可能在 stream 已 half-closed(remote) 或 closed 时收到该 frame，且 MUST NOT 将其视为错误。只有真正 idle（从未打开）的 stream 上的 WINDOW_UPDATE 才按 state rules 处理为 connection `PROTOCOL_ERROR`。
- 位置：`laststreamid` 初始化在 `lualib/silly/net/http/h2.lua:238-241`，stream 完成/移除在 `:1038-1080`，WINDOW_UPDATE 分类在 `:1366-1407`；该字段唯一更新位于 server request open 路径 `:1562-1648`。
- 触发：Silly client 的本端 request stream（例如 id 1）已双向 END_STREAM，`S.close` 因两侧 state 均 closed 立即从 `ch.streams` 删除；server 随后发送此前已排队或用于 request-body credit 的 stream-1 WINDOW_UPDATE。
- 影响：完全合法的在途 flow-control frame 使 client 发送 GOAWAY(PROTOCOL_ERROR)，整条 multiplexed connection 被标记不可用，其他并发请求随后被清除/失败。该竞态不要求恶意 frame，取决于完成、调度和网络到达顺序，因此可能表现为间歇性“对话废了”或 remote 断开。
- 证据：client-created id 只写入 `streamidx`，从不更新 `laststreamid`；`laststreamid` 初始且始终为 -1。stream 被删除后，`frame_winupdate` 得到 `s=nil`，再以 `if id > ch.laststreamid` 判断 idle；任意合法正 id 都满足 `id > -1`，遂 `channel_goaway(ch, PROTOCOL_ERROR)`。server 收 request 时才更新该字段，因此同一启发式在两个角色上方向不对称。
- 根因：用“对端曾打开的最大 id”同时判断本端发起 stream 的历史状态；没有按 initiator parity 分开维护最高已用 id/closed tombstone，也没有在允许的 race 窗口保留必要状态。
- 建议解法：分别跟踪 local-initiated 与 peer-initiated stream-id 历史，并按 parity/角色判断 idle；对已存在过但关闭的 stream，WINDOW_UPDATE 一律忽略。不能只用固定 100-entry queue 推断协议状态；若为其他 closed-frame race回收 tombstone，应使用 RFC 建议的已确认 closing signal，而不是数量或 timer。
- 后续回归条件：修复阶段在 client stream 1 双向完成并从 active map 删除后注入 WINDOW_UPDATE，断言忽略且并发 stream 3 继续；覆盖 half-closed(remote)、local RST 后在途 update、从未打开的 id、奇偶两方向、超过 100 个已关闭 streams，以及 server 角色。本轮不新增测试代码。

### H2-016 — P2 — 无已处理 stream 的 GOAWAY 写出非法/错误 Last-Stream-ID

- 状态：已确认；RFC 9113 wire format、Lua-to-C conversion 与确定性 builder 路径推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §4.1 要求保留位发送时为 0；§6.8 将 GOAWAY Last-Stream-ID 定义为 sender 可能处理过的最高 peer-initiated stream，并明确没有处理任何 stream 时可设为 0。该边界决定哪些操作能被安全重试，sender 不得以内部 sentinel 代替 wire value。
- 位置：`laststreamid` 初始化在 `lualib/silly/net/http/h2.lua:238-241`，GOAWAY 调用在 `:596-608`，唯一更新位于 server request path `:1562-1648`；C frame builder 在 `luaclib-src/lhttp.c:1049-1072`。
- 触发：client 因本地 close 或任一 protocol/flow-control error 发送 GOAWAY；或 server 在收到首个合法 request HEADERS 前发送 GOAWAY。此时 `ch.laststreamid` 仍为 -1。
- 影响：wire payload 的首 4 bytes 是 `ff ff ff ff`：reserved bit 违反 sender 规则，低 31 位又声明 2^31-1。规范 peer 虽会忽略 reserved bit，却会据此认为所有本端发起 streams 都可能已被处理，丢失本可确定安全重试的边界；诊断也无法分辨“零个已处理”和“最大 graceful drain sentinel”。
- 证据：Lua 初始化明确使用 `laststreamid=-1`；client 路径从不更新它。`channel_goaway` 无条件传给 `build_goaway`。C 函数以 `unsigned int last_stream_id = luaL_checkinteger(...)` 接收，-1 转为 `UINT_MAX`，再由 `write_int` 原样写四字节，既未验证 0..0x7fffffff 也未 mask reserved bit。
- 根因：将内部“尚无 id”sentinel 直接序列化到 unsigned 31-bit protocol field，且 builder 缺少范围/保留位保护。
- 建议解法：协议状态从 0 初始化（无 peer-initiated stream 即 last=0），按角色只在真正把 peer stream 交给上层时更新；GOAWAY builder 接受前验证范围并强制保留位为 0。若实现两阶段 graceful shutdown，2^31-1 必须是显式策略值，不能由 -1 偶然产生。
- 后续回归条件：修复阶段逐字节检查 client close、server pre-request error、server 处理 id1 后 error 和 graceful two-stage GOAWAY；断言 reserved bit 恒 0、无处理时 last=0、处理后为正确 peer id、多次 GOAWAY 不增加边界。本轮不新增测试代码。

### H2-017 — P2 — 完整响应后的 RST_STREAM 会覆盖响应或在回收后终止连接

- 状态：已确认；RFC 9113 明确规则与确定性 response/RST/read path 推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §8.1允许server在发送带END_STREAM的完整响应后，以`RST_STREAM(NO_ERROR)`请求client无错终止尚未完成的request transmission；client不得因此丢弃完成响应。§5.1还要求在closed race窗口忽略晚到RST_STREAM，而非把曾存在的id当idle。
- 位置：terminal state写入在`lualib/silly/net/http/h2.lua:845-877`，stream移除/readall在`:1038-1123`，RST handler在`:1336-1351`，client response END transition在`:1446-1499`。
- 触发：server发送完整response HEADERS（可直接END_STREAM）或DATA+END_STREAM，随后同stream发送合法4-byte RST_STREAM。时序A在应用close前到达；时序B在应用已读取并`S.close`移除stream后到达。
- 影响：时序A把成功response重新标记reset，空body的`readall`返回nil/“Graceful shutdown”；时序B因map lookup为nil而发送GOAWAY(PROTOCOL_ERROR)，清除同连接其他正常streams。标准的提前响应/停止request upload及普通网络重排都可造成结果丢失、不必要重试或整条multiplexed连接中断。
- 证据：对象尚存时`frame_rst`无视既有END/errorcode，直接`stream_remoteend(...STATE_RST...)`覆盖终态。对象已被`:1052-1054`删除时，`:1337-1341`在读取/判断error code前把任何nil lookup统一当idle并GOAWAY；没有本端stream id closed history或RST race窗口。
- 根因：application object存在性被误当作protocol stream历史，且terminal response state可逆；同一合法frame仅因应用cleanup调度不同走“丢响应”或“杀连接”两种错误结果。
- 建议解法：response completion保存为单调message状态；完成response后的NO_ERROR RST只终止pending request writer，不能覆盖可读结果。协议层另保留轻量closed history，先验证RST frame结构，再忽略race窗口内已closed id；真正idle id才是connection error。application对象回收不得删除判定所需的protocol状态。
- 后续回归条件：修复阶段覆盖空/有body response END后、应用close前后、RST(NO_ERROR/非零)、request仍上传、final前RST及并发stream；完成响应保持可读，late closed-id RST不GOAWAY，真正idle id仍按规范失败。当前不发送RST。

### H2-018 — P2 — request/response/trailer sender 不校验 field section

- 状态：已确认；RFC 9113 sender requirements 与确定性 API→HPACK path 推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §8.2.2 要求 endpoint MUST NOT 生成 connection-specific fields，TE 仅允许值 `trailers`；§8.3 禁止未定义、错误 context 或重复 pseudo-header，并要求 pseudo 位于普通 fields 前；§8.1.1 的 malformed message 条件也约束合法 field name/value。response 必须生成恰好一个三位 `:status`，trailer 不得含 pseudo-header。
- 位置：统一 header 写出在 `lualib/silly/net/http/h2.lua:700-738`，公开 request/respond/closewrite API 在 `:938-1025`，高层 client 仅小写化在 `lualib/silly/net/http/client.lua:318-365`；HPACK encoder 在 `luaclib-src/lhttp.c:357-556`。
- 触发：client header 传入 `connection`/`upgrade`/非法 `te`，或直接 stream API 传 uppercase/`:method`；server 调 `respond(200, {connection="close"})`、传 header 内 `:status`，或给 status 传非三位数；任一端 trailer table 含 pseudo/connection field。
- 影响：Silly 主动在 wire 上生成 peer 必须判为 malformed 的 request/response，严格 endpoint 会 reset stream，导致由本地输入即可触发互操作失败。若宽松 peer 接受，则 hop-by-hop metadata、重复控制数据或非法 field syntax 可能在代理/缓存链上产生不同解释。gRPC metadata 复用同一路径，也会继承该缺口。
- 证据：`stream_writeheader` 只临时移除 request `host`，随后把整个 caller table 与内部 pseudo 一起交给 `hpack_pack`；response 同样直接编码 caller table 和内部 `:status`。`closewrite` 对 trailer 直接 `hpack_pack(trailer)`。高层 client 只执行 `lower(k)`，没有 forbidden/TE/name/value过滤；C encoder 只把任意 Lua key/value转 string并压缩，不理解 HTTP context，因此 caller 可重复内部 pseudo 或生成非法 fields。
- 根因：把 HPACK serialization 误当成 HTTP field validation，且 recipient 侧的部分 validator 没有抽成 sender/receiver、request/response/trailer共用的语义层。
- 建议解法：在 HPACK 前构造并验证有序 field list：普通 API 禁止 caller 提供 pseudo；严格校验 lowercase field-name/value；剔除或拒绝 connection-specific fields并检查 TE；按 context 由库唯一生成 pseudo/status；trailer 使用独立禁止集合。不要依赖 peer 替本端验证，也不要静默发送被 lower 后仍禁止的字段。
- 后续回归条件：修复阶段逐字节解码 outbound request/response/trailer，覆盖 uppercase、五种 connection-specific fields、TE 多值/大小写、caller pseudo、重复 status、非法 status、NUL/CR/LF 与合法重复普通 fields；断言非法输入在写 frame 前稳定失败且 connection 仍可复用。本轮不新增测试代码。

### H2-019 — P1 — server request validator 缺少最低 field name/value 语法校验

- 状态：已确认；RFC 9113 明确 octet rules 与确定性 validator/application path 推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §8.2.1 要求最低限度拒绝 name 中 0x00-0x20、uppercase、0x7f-0xff，普通 name 中任何 colon，以及 value 任意位置的 NUL/LF/CR 和首尾 SP/HTAB；违规 request 必须视为 malformed。规范明确说明缺少这些检查可在转发到 HTTP/1.1 时形成 request smuggling。Content-Length 还必须按 RFC 9110 §8.6 的十进制语法和安全整数规则处理。
- 位置：HPACK list/map 在 `lualib/silly/net/http/h2.lua:331-384`，server `check_req_header/check_content_length` 在 `:386-447`，request 创建并交 application handler 在 `:1562-1648`。
- 触发：发送普通 field name `""`、`"a:b"`、包含 NUL/CTL/非 ASCII byte 的 name；或任意 field value 包含 NUL、CR、LF、首尾 SP/HTAB。另可令 `content-length` 为 Lua `tonumber` 接受但非 RFC decimal 的 `0x10`、`1e3`、带首尾空白等形式。
- 影响：malformed request fields 被原样放入 `s.header` 并交给 application。若应用日志、C binding、反向代理或 H2→H1 gateway 使用 NUL-terminated/CRLF-delimited 解释，验证层与使用层可能看到不同 name/value，产生 header injection、request smuggling 或路由/鉴权差异；宽松 Content-Length 还可能把 downstream 认为无效的 framing value解释成有效长度。
- 证据：`check_req_header` 对 name 只执行 `k:match("%u")` 和首 byte 是否 colon；普通 name 不检查空值、colon 或其他禁止范围。value 除 pseudo path empty、TE exact value 外不检查任何 byte。随后 `map_header` 保留这些 strings，`channel_newstream` 直接传给 handler。`check_content_length` 仅 `tonumber(clen)` 与非负判断，没有全串 `DIGIT+`、整数精度或上限检查。
- 根因：validator 只实现 HTTP/2 特有 pseudo/hop-by-hop 子集，遗漏 RFC 9113 自带的通用 octet firewall，并把语言通用数值解析器误用于 protocol ABNF。
- 建议解法：在任何 map/application access 前对 ordered field list做 byte-level validation；普通 name 要求非空且逐 byte 满足允许集合，pseudo 只允许单个 leading colon 和已知名字；value 拒绝规定 octets与边界空白。Content-Length 用 checked decimal parser，保留重复 field 顺序并按规范统一/拒绝；malformed 只 reset 对应 stream，HPACK state仍保持同步。
- 后续回归条件：修复阶段覆盖每个禁止 byte range 边界、普通 name 内 colon/空 name、value NUL/CR/LF/leading/trailing SP/HTAB、合法 obs-text policy，以及 Content-Length decimal/hex/exponent/溢出/相同列表；验证 handler 从不被调用且并发 stream 可继续。本轮不新增测试代码。

### H2-020 — P1 — fragmented field block 的最后一帧错误地再次发送 HEADERS

- 状态：已确认；RFC 9113 frame sequence 与确定性 C builder 控制流推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §4.3/§6.2/§6.10 要求未设置 END_HEADERS 的 HEADERS 后只能紧跟同一 stream 的一个或多个 CONTINUATION，直到最后一个 CONTINUATION 设置 END_HEADERS；期间出现任何其他 frame type（包括第二个 HEADERS）都必须作为 connection `PROTOCOL_ERROR`。
- 位置：C field-block frame builder 在 `luaclib-src/lhttp.c:883-949`；request/response 调用在 `lualib/silly/net/http/h2.lua:700-738`，trailer 调用在 `:1018-1024`。
- 触发：任一 outbound HPACK block 长度严格大于 `ch.sendframemaxsize`（默认 16,384，或 peer SETTINGS_MAX_FRAME_SIZE），例如大 request metadata、response headers 或 trailer。长度恰好等于 limit 不触发分片。
- 影响：wire 序列是 `HEADERS(no END_HEADERS)`，可选若干 `CONTINUATION(no END_HEADERS)`，最后却是 `HEADERS(END_HEADERS)`。规范 peer 必须终止整条 connection，所有并发 streams 一同失败；表现为 header 较小时正常、跨阈值后 remote 突然断开/对话废弃，且无法通过重试同一 payload 恢复。
- 证据：`lframe_build_header` 初始 `type=FRAME_HEADERS`，每次 while iteration 后改为 `FRAME_CONTINUATION`；但循环结束的 final call 明确写死 `write_frame_header(..., FRAME_HEADERS, flag | END_HEADERS, id)`，完全忽略变量 `type`。因此只要 while 至少执行一次，final type 必错。接收侧 `read_header` 反而正确要求后续 `t == FRAME_CONTINUATION`，说明发送/接收实现不对称。
- 根因：分片循环维护了当前 frame type，却在尾帧使用常量；现有 tests 只覆盖单帧 headers，未在 frame boundary 上解码完整 wire sequence。
- 建议解法：final frame 使用当前 `type`；首帧保留 HEADERS 与可能的 END_STREAM，后续所有 fragments 只能 CONTINUATION，只有 final fragment设置 END_HEADERS。抽出 sequence builder，避免 header/trailer路径分叉，并对 frame-size 做非零/范围保护。
- 后续回归条件：修复阶段覆盖 HPACK 长度 `limit-1/limit/limit+1/2*limit/2*limit+1`，逐帧断言 type、stream id、END_STREAM 只在首 HEADERS、END_HEADERS 只在末帧；request/response/trailer 三条路径及 peer 调大 frame size均覆盖。本轮不新增测试代码。

### H2-021 — P2 — SETTINGS initial-window overflow 被降成 stream error

- 状态：已确认；RFC 9113 明确错误作用域与确定性 SETTINGS/window 路径推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §6.9.2 要求收到 `SETTINGS_INITIAL_WINDOW_SIZE` 后，将新旧值差额应用于所有维护 active flow-control window 的 streams；如果该变化导致任何 flow-control window 超过 2^31-1，endpoint MUST 将其作为 connection `FLOW_CONTROL_ERROR`。减小后出现负 window 是合法状态，必须保留直到 credit 恢复。
- 位置：普通 connection/stream WINDOW_UPDATE helper 在 `lualib/silly/net/http/h2.lua:1131-1172`，SETTINGS initial-window 分支在 `:1211-1278`。
- 触发：先通过合法 stream WINDOW_UPDATE 将某 active stream 的 send window 提高到接近 2^31-1，再发送更大的 `SETTINGS_INITIAL_WINDOW_SIZE`，使 `current_stream_window + (new_initial-old_initial) > 2^31-1`。
- 影响：Silly 只 reset 发生 overflow 的 stream，继续使用本应终止的 connection，并可能继续遍历其他 streams、应用后续 SETTINGS values 和发送 ACK。双方对 connection validity 与 stream window state产生分歧；同一 peer 可重复制造局部 resets，而规范要求立即隔离整连接的失同步状态。
- 证据：SETTINGS 分支计算 delta 后对 `ch.streams` 每项调用 `stream_winupdate(s, delta)`。该 helper 检测 `nwindow > 0x7fffffff` 时调用 `stream_reset(..., FLOW_CONTROL_ERROR)` 并返回，永不调用 `channel_goaway`；`frame_settings` 也不接收失败结果，循环结束仍发送 SETTINGS ACK。普通 WINDOW_UPDATE overflow 使用 stream error是正确规则，但不能复用于 SETTINGS delta 的显式 connection-error 例外。
- 根因：将两种数值相同但 RFC 错误作用域不同的 window update 共用无 context helper，且 SETTINGS processing 没有原子预检查/失败传播。
- 建议解法：应用 setting 前先只遍历 active flow-control windows 计算所有新值并检查上限；任一 overflow 立即 `channel_goaway(FLOW_CONTROL_ERROR)`，不得应用 setting 或 ACK 后续值。全体通过后再原子提交 delta；负值保留，closed/tombstone streams 不调整。
- 后续回归条件：修复阶段覆盖单/多 stream 临界 `2^31-1`、加一 overflow、负 delta、负后恢复、closed stream 和同一 SETTINGS 中后续参数；断言 overflow 只发 GOAWAY(FLOW_CONTROL_ERROR)、无 SETTINGS ACK/RST fan-out，合法边界继续发送。本轮不新增测试代码。

### H2-022 — P2 — Content-Length mismatch 被升级为 connection error

- 状态：已确认；RFC 9113 malformed-message scope 与确定性 END_STREAM 路径推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §8.1.1 明确规定，含 message content 的 request/response 若 Content-Length 不等于组成 content 的 DATA payload 总长度，则 message malformed；检测到的 malformed request/response 必须作为对应 stream 的 `PROTOCOL_ERROR` 处理，而不是 connection error。
- 位置：共享 terminal validator 在 `lualib/silly/net/http/h2.lua:845-877`，DATA END_STREAM path 在 `:1177-1205`，client response HEADERS END 在 `:1446-1499`，server request HEADERS END 在 `:1562-1648`。
- 触发：任一 initial field section 声明 `content-length: 1`，随后以零 DATA bytes结束（可直接在 HEADERS 设置 END_STREAM），或发送与声明值不同的 DATA 总量后设置 END_STREAM。request 与有 content 的 response均可触发。
- 影响：单个 malformed message 导致 GOAWAY、清除同 connection 所有 active streams并关闭复用连接；攻击者或坏 upstream 可用一条 stream 中断其他用户/请求。调用方也看不到规范的 per-stream protocol failure，连接池被不必要销毁。
- 证据：`stream_remoteend` 在 `state==STATE_END` 时比较 `s.recvbytes ~= s.recvexpect`，mismatch 直接 `channel_goaway(s.channel, PROTOCOL_ERROR)`。该 helper被 request/response 及 HEADERS/DATA END 路径共用，没有调用 `stream_reset` 的分支。`channel_goaway` 对非 NO_ERROR 立即 `channel_clearstream`，确定扩大到整连接。
- 根因：message semantic validation 放在无错误作用域参数的共享 terminal helper 中，默认选择 connection-level helper；没有区分 HPACK/framing connection errors 与单消息 malformed stream errors。
- 建议解法：在确定 stream id 的上下文返回结构化 malformed result，并调用 `stream_reset(s.id, ch, PROTOCOL_ERROR)`；保留 connection flow-control/HPACK状态，停止该 stream 的 handler/read/write。对无 content 语义的 HEAD/204/304/成功 CONNECT 继续按既有例外不做长度一致性比较。
- 后续回归条件：修复阶段覆盖 declared 0/1、少发/多发、HEADERS 直接 END、多个 DATA、request/response/no-content methods/status，以及并发第二 stream；断言 mismatch 只产生对应 RST_STREAM(PROTOCOL_ERROR)，其他 stream和 connection继续工作。本轮不新增测试代码。

### H2-023 — P1 — rejected initial HEADERS 的 stream-id/quota bookkeeping 非事务

- 状态：已确认；RFC 9113 stream lifecycle 与确定性 admission/error branches 推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §5.1.1 规定 initial HEADERS 使 idle stream 离开 idle，stream identifier 一经使用不得复用；malformed request 按 §8.1.1 reset 后 stream 已 closed。§5.1.2 的 concurrent limit 只统计 open 或任一 half-closed streams，已经 reset/closed 或根本未建立的 stream 不得永久占用名额。
- 位置：stream object/count fields 在 `lualib/silly/net/http/h2.lua:453-495`，`stream_reset` 在 `:880-894`，正常 close decrement 在 `:1038-1080`，server initial HEADERS admission 在 `:1562-1648`。
- 触发：路径A：id 1 initial HEADERS含invalid pseudo/forbidden field，收到RST后在同一id再发送合法request。路径B：递增奇数id发送可通过field validator但`content-length`无法解析的HEADERS。路径C：合法数值`content-length: 1`与HEADERS END_STREAM并存，声明有1 byte但实际立即以0 byte结束。
- 影响：路径A允许已reset id再次进入application，违反不可复用并造成重放混淆。路径B每次无active object却永久增加`streamcount`，约100次后合法request均REFUSED_STREAM。路径C先GOAWAY/清空连接，却随后仍发布malformed stream并fork业务handler；handler收尾会在已归零计数上再减，可能得到负`streamcount`、在terminal channel排队response并留下map/object状态。
- 证据：`check_req_header`位于parity/history前，失败时`stream_reset`查不到object且不留history。通过后代码先`laststreamid=id; streamcount++`，再解析CL；失败不回滚。路径C创建`s`后在写入`ch.streams[id]`之前调用`stream_remoteend`；长度不符触发`channel_goaway→channel_clearstream`，因map尚无该对象只把count归0。helper不返回失败状态，caller继续执行`ch.streams[id]=s; task.fork(server_handler,s)`；其正常`S.close`又无条件`streamcount--`。
- 根因：stream protocol transition、semantic validation、quota reservation和 object publication分散在多个不可回滚步骤；`stream_reset` 又假定 object 已存在才能更新 bookkeeping。
- 建议解法：initial HEADERS admission采用单一transaction：先做connection级id/parity/history检查并记录id已使用，再完成message validation与END/length判定；只有确认交application时才publish object/commit quota。任何stream error写RST并保留closed history但不调用handler；任何connection error立即return且禁止后续publish。helper返回结构化状态，所有reservation都以统一rollback/finally收尾。
- 后续回归条件：修复阶段覆盖invalid pseudo→同id重用、invalid CL超过limit、CL1+HEADERS END、even id+malformed fields、HPACK error、concurrency边界及失败后更高合法id；断言id不复用、quota/map不泄漏或负数、malformed handler调用0次且错误作用域正确。当前不发送这些HEADERS。

### H2-024 — P1 — client 淘汰 RST tombstone 后不再 minimally process late HEADERS

- 状态：已确认；RFC 9113 closed-stream race 与确定性 cancel/queue/header path 推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §5.1/§5.4.2 要求 endpoint 发送 RST_STREAM 后仍准备接收 peer 在看到 reset 前已发送/排队的 frames；这些 frame须 minimally process 后丢弃。HEADERS 必须完成 field-section decompression以更新 connection-wide HPACK state，DATA 仍须计入 connection flow control。只有获得 peer 已看到 closing signal 的可靠证据后，才可把后续 frame 当 connection error，规范不建议仅用 timer。
- 位置：local close/reset tombstone queue 在 `lualib/silly/net/http/h2.lua:1038-1080`，client HEADERS lookup/decode 顺序在 `:1446-1499`，HPACK connection context在 `luaclib-src/lhttp.c:692-780`。
- 触发：client 依次打开并 cancel 超过 `CLOSED_STREAM_COUNT=100` 个已发送 request，使 closing queue淘汰最旧 stream object；server 此后送达那个最旧 id 在看到 RST 前已经排队的 response HEADERS，且 field block对 dynamic table有增删作用。
- 影响：client 在解压该合法在途 block 前发送 GOAWAY，整条 multiplexed connection及其他 streams失败。若未来只忽略而不 GOAWAY，则下一 header block 的 dynamic index会因本块未处理而解压失败；因此固定数量 tombstone既会制造间歇断连，也不能安全替换 RFC 所需的 connection-level compression processing。
- 证据：`S.close` 对已发送 stream调用 `stream_reset` 后 push 到 `closingq`，队列超过 100 就执行 `streams[s.id]=nil; s.channel=nil`，淘汰依据仅是数量、没有 SETTINGS/PING/更新 stream 等 peer-observation signal。`frame_header_client` 首行查 `ch.streams[id]`，nil 时立即 `channel_goaway(PROTOCOL_ERROR)`；`read_header/hpack_unpack` 位于该分支之后，明确未执行。
- 根因：把 application stream object 的回收策略同时当成 protocol closed-state history；client handler又在保持 connection-wide HPACK state之前依赖 object存在。
- 建议解法：将 frame-level minimal processing与 application stream lookup分离：完整收集/decode field block以更新 `recvhpack` 后，再按 closed-state决定丢弃。closed history回收应由能证明 peer 已观察 reset 的 signal驱动；即使不保留完整 stream object，也需保留轻量 state/parity/id 信息并始终维护 HPACK/connection flow control。
- 后续回归条件：修复阶段 cancel 101+ streams，延迟最旧 id 的 indexed/incremental HEADERS，再在 active stream发送引用其 dynamic entry 的 HEADERS；断言 late block被解压后丢弃、后续 block成功、无 GOAWAY。另覆盖 tombstone未淘汰、DATA/CONTINUATION和可靠 closing signal后行为。本轮不新增测试代码。

### H2-025 — P1 — handshake/frame/header-block 读取没有 progress deadline

- 状态：已确认；RFC 9113 denial-of-service guidance 与确定性配置/read call graph 推导。本阶段只做静态 review，不新增慢速连接复现。
- 规范：RFC 9113 §10.5 指出 HTTP/2 比 HTTP/1.1 承诺更多 connection state，small frames、SETTINGS 与 field compression均可被滥用；不监控这些 feature usage 会暴露 DoS 风险，实现 SHOULD 跟踪并设置限制。SETTINGS ACK timeout本身是 MAY，本条不是把它误作强制；结论来自整个 connection/frame progress 无任何部署上限。
- 位置：`read_frame/read_header` 在 `lualib/silly/net/http/h2.lua:268-365`，client handshake/dispatch在 `:1420-1547`，server handshake/dispatch在 `:1668-1738`；listener options在 `lualib/silly/net/http.lua:10-45`，client options在 `lualib/silly/net/http/client.lua:206-274`。
- 触发：peer 建连后慢速发送 24-byte client preface、只发部分 9-byte frame header/body、发送首 SETTINGS 后永不完成 ACK exchange，或以多个 CONTINUATION 每次慢速补少量 field-block bytes但不结束。client 方向可由 server 对称拖住 channel creation。
- 影响：每个连接长期保留 socket、Lua task/channel、两个 HPACK contexts、queues 与 TLS state；攻击者可用大量低带宽连接耗尽 fd/task/memory。已建立 connection上的半帧还会阻塞唯一 dispatch loop，使该 connection 的所有其他 multiplexed streams同时停顿。`idle_timeout` 只清连接池空闲项，不能终止正在等待 protocol bytes 的 read。
- 证据：所有上述路径调用 `conn:read(n)` 而不传其可选 timeout；`read_header` 循环的每个 `read_frame` 也没有累计时间/速率预算。server listen config只有 addr/TLS/certs/ALPN；client config只有 pool count、idle timeout和 ALPN。底层 TCP/TLS `read` 仅在显式 timeout参数存在时创建 timer，因此这里可以无限等待。
- 根因：把 transport 可选 timeout只暴露给 stream body read API，没有为 connection establishment、frame progress与 header assembly建立分层 deadlines/budgets。
- 建议解法：提供 server/client 可配置的 preface、SETTINGS/ACK、frame-progress、header-block-total 和 connection-idle deadlines；每个 deadline按整体阶段累计而非每次 byte重置，超时后关闭/GOAWAY并释放全部 state。再加每连接 small-frame/SETTINGS/PING rate budgets；默认值需兼顾高延迟网络并可关闭/调整。
- 后续回归条件：修复阶段用可控时钟覆盖 preface 23/24 bytes、frame header 8/9、partial body、无 ACK、无限 CONTINUATION、持续 small frames和正常高延迟完成；断言超时释放 fd/task/channel并唤醒所有 waiters，合法活动不会被 pool idle timer误杀。本轮不新增测试代码。

### H2-026 — P1 — client 在禁用 push 后仍静默忽略 PUSH_PROMISE

- 状态：已确认；RFC 9113 mandatory error rule 与确定性 dispatch table推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §6.6/§8.4 规定，client 将 `SETTINGS_ENABLE_PUSH=0` 发送且获 ACK 后，收到任何 PUSH_PROMISE 必须作为 connection `PROTOCOL_ERROR`；即使实现支持 push，也不能把 PUSH_PROMISE 当未知 frame丢弃，因为它同时更新 HPACK connection state并保留 promised stream。
- 位置：client frame dispatch table与 initial SETTINGS/ACK handshake在 `lualib/silly/net/http/h2.lua:1500-1547`；通用 dispatcher 对无 handler type不做任何处理在 `:1420-1440`。
- 触发：handshake 完成后，server 在任一 client-initiated open/half-closed stream 发送语法完整的 PUSH_PROMISE；field block可包含 incremental indexing，随后 server在普通 response HEADERS 中引用该 dynamic entry。
- 影响：Silly 既不按已协商禁用规则终止 connection，也完全不处理 promised id 与 HPACK block。下一普通 response可能因 dynamic table index不同步触发 COMPRESSION_ERROR/断连；若未立即引用，则协议违规被隐藏，client/server对 stream state仍不一致。恶意 server可选择延迟制造难诊断的后续失败。
- 证据：client 初始 setting明确包含 `SETTINGS_ENABLE_PUSH, 0`，handshake等到 SETTINGS ACK 后才启动正常 dispatch；但 `frame_client` 只有 HEADERS/DATA/PRIORITY/RST/SETTINGS/PING/GOAWAY/WINDOW_UPDATE/CONTINUATION，没有 type 5。`common_dispatch` 只在 `func` truthy时处理，因此 PUSH_PROMISE无条件静默丢弃。server table反而显式为 type 5调用 `channel_goaway(PROTOCOL_ERROR)`。
- 根因：把“功能未实现”误作 unknown extension frame处理，遗漏已定义 frame即使不支持其业务语义也有 mandatory validation和 connection-state副作用。
- 建议解法：client table显式处理 PUSH_PROMISE；在本实现始终广告/确认 push=0 的前提下直接 connection PROTOCOL_ERROR。若将来支持 push，则必须解析 promised id、保持 HPACK、校验 associated/promised stream state、authority/safe/cacheable fields和 concurrency，并为 application提供明确接受/拒绝机制。
- 后续回归条件：修复阶段在 ACK 前/后发送 PUSH_PROMISE，覆盖 stream id 0、invalid promised id、incremental HPACK 与后续 indexed response；当前 disabled模式断言 ACK 后统一 GOAWAY(PROTOCOL_ERROR)，绝不静默继续。本轮不新增测试代码。

### H2-027 — P1 — server handler 异常绕过 stream 收尾，永久泄漏并发配额

- 状态：已确认；handler task、异常框架与stream close bookkeeping的确定性静态核对。本轮不触发业务异常。
- 位置：server handler wrapper在`lualib/silly/net/http/h2.lua:1549-1558`，stream发布/fork在`:1621-1632`；唯一正常配额归还位于`S.close`的`:1042-1079`；task异常处理只记录并关闭coroutine在`lualib/silly/task.lua:47-64`。
- 触发：任意HTTP/2 request使业务handler抛Lua error，例如路由代码处理特定输入时异常；同一连接连续触发，默认本地并发额度为100。
- 影响：异常后的stream没有response END_STREAM或RST，peer request永久等待；对象继续被`ch.streams[id]`强引用，`ch.streamcount`不递减，request/body/header buffer与状态也无法释放。重复约100次后该连接永久达到并发上限，后续合法request被REFUSED_STREAM；大量连接可把应用级异常放大为持续内存/task/连接可用性问题。
- 证据：`server_handler`直接调用`ch.handler(s)`，其后的`s:closewrite()`和`s:close()`不是protected/finally。`task_resume`遇到error仅log、`coroutine.close`并删除task metadata，不认识H2 stream；参数`s`也不是Lua to-be-closed local，`stream_mt.__close`不会自动执行。stream仍在channel map中，唯一`streamcount--`位于未到达的`S.close`。
- 根因：协议资源所有权交给裸application callback，但cleanup依赖callback正常返回；task异常边界与H2 stream生命周期之间没有幂等的finally适配层。
- 建议解法：server wrapper以protected call执行handler，并在所有返回/异常路径进入单一finally：若尚未发送final response，可选择受控500或RST_STREAM(INTERNAL_ERROR)；终止pending read/write，随后幂等close并归还quota。记录错误时带stream/request context但限制日志；cleanup自身失败也不能跳过map/count释放。不要让一个stream异常升级为connection failure。
- 回归测试：修复阶段让handler在读body前后、respond后、write pending及closewrite中分别抛错，覆盖同连接超过并发上限次数；断言每次peer都收到明确终止、`streams/streamcount/buffer/waiter`回到基线、后续正常stream成功且每项资源只释放一次。当前不触发业务异常。

### H2-028 — P1 — remote GOAWAY/EOF 不结束 open-stream waiters，并可泄漏预留计数

- 状态：已确认；open wait queue、GOAWAY/dispatch teardown及reservation计数的确定性静态核对。本轮不建立满载连接。
- 位置：wait/pending reservation在`lualib/silly/net/http/h2.lua:613-675`；本地主动close唯一queue drain在`:679-696`；remote/error GOAWAY与clear在`:563-610,1351-1360`，dispatch EOF cleanup在`:1420-1440`；stream close唤醒在`:1042-1079`。
- 触发：channel达到peer的`SETTINGS_MAX_CONCURRENT_STREAMS`（也可为0），额外coroutine阻塞于`openstream`；随后peer发送GOAWAY、连接关闭/读取失败或本地因协议错误发送GOAWAY。优雅GOAWAY后已有stream正常close是第二条触发分支。
- 影响：error GOAWAY/EOF清理active streams却不唤醒`openwaitq`，所有等待者永久挂起；已收到remote GOAWAY时再调用`C.close`因`ch.goaway`提前return也无法补救。优雅GOAWAY后，active stream close会由`channel_wakeupopen`先增加reserved `streamcount`再唤醒；waiter发现`ch.goaway`直接返回错误但不回滚reservation，使channel即使没有真实stream也可能永远保持非零count、TCP和pool state不能回收。
- 证据：只有`C.close`显式pop/wakeup openwaitq；`channel_clearstream`仅遍历`ch.streams`并设`streamcount=0`。`frame_goaway`只置boolean。正常close的`channel_wakeupopen`在唤醒前执行`ch.streamcount += count`，而`openstream`醒后在goaway/id-exhausted两条return前没有decrement；且`C.close`首句在goaway时直接返回。
- 根因：并发slot reservation没有以waiter token建模，queue生命周期也没有纳入channel统一终止；“已收到GOAWAY”状态既阻止新stream，又意外阻止显式cleanup。
- 建议解法：建立幂等`fail_open_waiters(err)`并从remote/local GOAWAY、EOF、protocol error和close全部调用；waiter reservation以显式token在成功publish stream时commit，任何错误/cancel路径rollback。不要在唤醒前把匿名数量永久计入`streamcount`；channel close条件应基于实际published streams，已goaway也必须允许完成queue drain。
- 回归测试：修复阶段覆盖max=0/1、多个waiter、remote NO_ERROR/error GOAWAY、EOF、本地protocol error、GOAWAY后active stream完成及显式close；所有waiter必须恰好一次返回，`streamcount/queue/map`归零、连接释放且无重复slot。当前不建立满载连接。

### H2-029 — P1 — stream WINDOW_UPDATE 可把同一 blocked writer 无界重复压入 connection queue

- 状态：已确认；两级send window、queue引用语义与WINDOW_UPDATE dispatch的确定性静态核对。本轮不发送flow-control frame。
- 位置：blocked write首次排队在`lualib/silly/net/http/h2.lua:805-838`，重试再次排队在`:895-931`；stream/connection update在`:1131-1171,1362-1403`；queue每次push创建独立引用在`luaclib-src/adt/lqueue.c:65-84`。
- 触发：本端有大于剩余credit的pending DATA，connection send window已降到0；peer重复向该stream发送正数WINDOW_UPDATE，却始终不发送connection-level WINDOW_UPDATE。每次increment只需保持stream window总值不超过2^31-1。
- 影响：每个stream update都调用`stream_trysend`，看到connection window仍为0后再次把同一stream push进`writewaitq`。queue长度、C int buffer和Lua registry引用持续增长，而writer仍阻塞且没有数据前进；peer用9+4字节小frame即可造成远大于wire的持久内存/GC负担，直至queue容量/进程内存耗尽。stream后来reset/close也不主动从queue删除这些重复引用。
- 证据：stream没有`queued`标志。`:907-909`在每次调用都无条件`ch.writewaitq:push(s)`；`:1167-1169`让每个正increment重新调用它。queue `lpush`总是`id_pool_alloc`、把value写入uservalue table并追加ref，不检查对象是否已存在；只有未来connection WINDOW_UPDATE的pop循环才释放引用。
- 根因：connection credit waiter被实现为事件队列而不是成员集合/每stream一次的等待状态，stream-level credit事件在无法解决connection-level阻塞时仍重复登记。
- 建议解法：每个stream最多持有一个connection-wait membership，以`in_writewaitq`标志或intrusive set保证去重；pop/close/reset/goaway时原子清标志并移除/惰性跳过。stream WINDOW_UPDATE在connection window<=0时只更新数字，不重复排队；connection WINDOW_UPDATE按公平策略遍历唯一blocked streams。另保留small-frame rate budget作为纵深防御。
- 回归测试：修复阶段在connection window=0时对一个/多个blocked streams送大量合法stream updates，断言queue size不超过blocked stream数、内存有界；再补connection credit验证公平发送、无丢唤醒，并覆盖reset/close/GOAWAY清理。当前不发送flow-control frame。

### H2-030 — P2 — 异步 frame flush 丢弃 transport write failure，stream API 仍报告成功

- 状态：已确认；H2 batching task与TCP/TLS write返回契约的确定性静态核对。本轮不注入发送失败。
- 位置：唯一batch flush在`lualib/silly/net/http/h2.lua:498-519`，排队fork在`:521-530`；header/data/closewrite先更新状态并排队在`:704-738,805-838,938-1025`；TCP/TLS明确返回`boolean,error`在`lualib/silly/net/tcp.lua:306-315`与`lualib/silly/net/tls.lua:452-460`。
- 触发：底层socket已关闭/变成stale generation，TLS `SSL_write`或ciphertext flush失败，或任意transport writer返回false；此时H2已有待发request/response/DATA/END_STREAM/RST/WINDOW_UPDATE。
- 影响：所有frame从`sendbuf`删除，channel、stream state与flow-control credit却按已发送推进；`write/closewrite/respond`已返回成功或继续等待peer response/credit。peer永远没收到相应边界时，请求、response及blocked coroutine可悬挂，连接还可能被pool视作可用直到独立read路径碰巧发现失败；原始errno完全丢失，排障只能看到后续模糊goaway/EOF。
- 证据：`:514`裸调用`conn:write(sendbuf)`不保存两个返回值，`:516-518`无条件清buffer；没有设置`ch.goaway`、关闭conn、调用`channel_clearstream`或唤醒open/read/write waiters。上游`channel_write`只是fork flush且无completion，`stream_writewait`在credit充足时入队后立即返回true并扣减窗口。
- 根因：batching把“加入本地sendbuf”当作发送成功，却没有为异步transport completion建立channel-level failure latch与所有waiter的统一终止路径。
- 建议解法：flush检查`ok,err`；失败后原子标记channel terminal、禁止再排队、保留首个错误、关闭transport并通过统一teardown唤醒active/open/write waiters。若API继续采用fire-and-forget batching，应明确返回值只表示accepted，并保证任何后续wait/read立即观察失败；需要发送确认的closewrite/flush提供可等待结果。flow-control credit与local state要么在transport accepted后commit，要么失败时整channel终止，不能静默继续。
- 回归测试：修复阶段在header、partial DATA、END_STREAM、RST/GOAWAY及WINDOW_UPDATE batch分别注入TCP/TLS write失败，断言首个错误传播、所有waiter恰好结束、buffer/queue/stream清零且channel不归池；正常合并写仍只flush一次。当前不注入发送失败。

### H2-031 — P2 — HEAD/204/205/304 的禁止正文语义未约束 DATA 收发

- 状态：已确认；response semantics、DATA handler与sender API的确定性静态核对。本轮不发送no-content response。
- 规范：RFC 9110 §6.4.1规定HEAD response以及1xx、204、205、304 response不包含content；RFC 9113 §8.1.1要求违反message语义的response视为malformed，并按stream error处理。CONNECT成功后的DATA是tunnel，不属于本条禁止集合。
- 位置：client只跳过长度校验的predicate在`lualib/silly/net/http/h2.lua:1446-1497`；共享DATA接收在`:1177-1204`；server/public发送在`:938-1025`，其中没有method/status body permission。
- 触发：server在HEAD response或status 204/205/304的final HEADERS之后发送非空DATA；反向方向上，Silly handler对这些response调用`write(data)`或`closewrite(data)`。
- 影响：client接受规范定义的malformed response、持续flow-control并把禁止的bytes作为body交给应用；缓存、代理或业务代码若按HTTP语义忽略body，会与Silly读取结果分叉。Silly server也能主动生成严格peer应reset的response，造成互操作失败。H2 stream framing避免了H1式下一响应字节错位，但不能使消息语义违规变成合法。
- 证据：client predicate只决定是否设置`s.recvexpect`，没有保存`content_allowed=false`；随后`frame_data`对所有open stream无条件append并累计bytes。server `S.respond`只保存status/header，`S.write/closewrite`只检查localstate/credit，完全不读取`s.method/s.status`。205甚至不在现有predicate中。
- 根因：把“无需验证Content-Length”误当成完整的no-content处理，且response semantic state没有由HEADERS阶段传播到DATA sender/recipient。
- 建议解法：final response headers后计算不可变的message mode：normal-content、no-content或CONNECT-tunnel。no-content模式收到非空DATA时仅reset对应stream(PROTOCOL_ERROR)，sender在任何frame写出前拒绝非空data；205纳入集合。允许合法HEAD/304的表示元数据Content-Length但不把它当待收bytes，204/1xx按各自field限制处理；CONNECT tunnel保持DATA可用。
- 回归测试：修复阶段覆盖H1/H2角色矩阵中的HEAD、204、205、304、1xx与成功CONNECT，分别测试HEADERS END、空DATA END、非空DATA和Content-Length元数据；禁止content只失败对应stream，CONNECT tunnel仍双向传输。当前不发送no-content response。

### H2-032 — P1 — 同一 stream 的并发读取会覆盖唯一 waiter 并永久挂起协程

- 状态：已确认；公开stream API、单worker协程调度与唯一等待槽的确定性静态推导。本轮不新增并发barrier或运行复现。
- 位置：stream唯一的`readco/readtype/readneed`状态在`lualib/silly/net/http/h2.lua:456-493`；等待注册与timer在`:752-799`；`waitresponse/read/readall`三个公开入口在`:1028-1039,1084-1124`；DATA、END、RST及channel teardown的唤醒在`:563-590,858-892,1177-1204,1446-1497`。发送侧已有显式并发保护在`:805-808,992-998`，读取侧没有对应检查。
- 触发：同一HTTP/2 stream上，协程A在header/body尚未到齐时调用`waitresponse`、`read`或`readall`并进入`task.wait()`；在A恢复前，协程B再调用任一需要等待的读取方法。gRPC client/server streaming对象直接暴露由这些入口实现的`read`，同样继承该条件。
- 影响：B无条件把`s.readco/readtype/readneed`改成自己的等待信息。后续DATA、END_STREAM、RST_STREAM、connection关闭或stream close只会唤醒B，A失去所有可达引用而永久挂起。若两次读取带不同timeout，A的timer还会通过共享`s`错误地超时唤醒B；B的timer随后找不到waiter，A仍无法结束，造成返回值归属错乱、任务/请求泄漏以及上层RPC永不完成。
- 证据：`stream_readwait`在写`s.readco=task.running()`前不检查旧值，也没有队列或operation token；所有`stream_readwakeup`只取当前单个`s.readco`并立刻清空。timer只保存`s`而不保存注册时的coroutine/generation。与之相反，`stream_writewait`发现`s.writeco`会立即抛出race错误，`closewrite`也拒绝pending write，说明同一对象的并发所有权必须显式处理而非由单线程模型自动保证。
- 根因：异步读取状态被建模为可覆盖的单槽，但API既没有串行化多个reader，也没有在覆盖前fail fast；timeout callback又绑定可变stream状态而不是具体等待操作。
- 建议解法：选择并明确一种契约：若只支持single-reader，在任何状态写入前检测active read并同步返回稳定错误；更易用的方案是以FIFO/token串行化读取并保证buffer消费顺序。timer必须绑定不可变operation token，仅能取消/唤醒自己的waiter；close/reset/channel teardown应终止全部已登记操作且每个恰好一次。gRPC streaming层可再提供自己的read mutex或明确传播底层错误。
- 回归测试：修复阶段用channel/barrier覆盖`waitresponse+read`、`read+read`、`read+readall`，分别在DATA到达、END_STREAM、RST、GOAWAY/EOF及两个timeout先后触发；断言要么第二次调用立即失败，要么FIFO返回，所有协程有限时间结束、bytes不重复/丢失、timer无跨操作唤醒。当前不运行并发复现。

### H2-033 — P1 — 合法负 stream window 被当作 DATA length，下一次写触发 Lua 异常

- 状态：已确认；RFC 9113 flow-control window调整规则与Lua→C builder参数路径的确定性静态推导。本轮不发送SETTINGS或运行peer互操作。
- 规范：收到较小的`SETTINGS_INITIAL_WINDOW_SIZE`时，endpoint必须把差值应用到所有active stream；若先前已消耗credit，stream flow-control window可以合法变为负数。此时sender必须停止发送DATA，直到WINDOW_UPDATE使窗口转正，不能把负window解释为payload长度或协议错误。
- 位置：SETTINGS delta及已有stream更新在`lualib/silly/net/http/h2.lua:1211-1278`；允许保存负window的`stream_winupdate`在`:1156-1171`；新写的credit选择和DATA builder调用在`:805-838`；native builder拒绝负length在`luaclib-src/lhttp.c:950-985`。公开`write/closewrite`在`h2.lua:965-1025`。
- 触发：active stream已发送部分DATA，使其剩余sendwindow小于旧initial value；peer随后合法下调INITIAL_WINDOW_SIZE，delta令`s.sendwindow<0`。在尚未收到足够stream WINDOW_UPDATE前，应用对该stream调用`write(data)`或带data的`closewrite`。
- 影响：`stream_writewait`取`min(s.sendwindow,ch.sendwindow)`得到负`win`，把它作为builder的length参数；C层`len>=0`参数检查直接抛Lua exception，而不是异步等待credit或返回结构化错误。client RPC/request task可意外终止；server handler异常还会叠加`H2-027`，留下stream map和并发quota。header可能已在进入该函数前排队，peer看到半成品message而本地没有正常writer收尾。
- 证据：`frame_settings`按规范计算negative delta并对所有stream调用`stream_winupdate`，后者只拒绝上溢、会保存负值。`stream_writewait`没有`win=max(0,min(...))`或`swin<=0`分支，直接执行`build_body(...,0,win)`；native `lframe_build_body`把length读入int并以`len >= 0`做`luaL_argcheck`，因此该合法flow-control状态确定性进入异常。
- 根因：发送slow path假定两级window最小值永远非负；虽然SETTINGS接收侧部分实现了规范允许的负stream window，write admission与waiter模型没有同步扩展该状态。
- 建议解法：可发送credit计算下限为0；stream window<=0时不构造任何DATA，只登记一次stream-credit waiter并等待对应WINDOW_UPDATE。connection与stream两级blocked membership、close/reset清理和公平唤醒应与`H2-029`统一设计；SETTINGS delta应用后不得把合法负值升级为异常。
- 回归测试：修复阶段先消耗不同数量stream credit，再把initial window降到0/较小值，覆盖负值、恰好0及后续分段WINDOW_UPDATE；`write/closewrite`必须等待且不抛异常、不提前发DATA，credit转正后精确续发。client/server及多个并发stream均覆盖，当前不发送frame。

### H2-034 — P2 — client/server 均接受 ACK-only SETTINGS 作为对端连接前言

- 状态：已确认；RFC 9113 connection preface要求与握手分支的确定性静态核对。本轮不建立peer或发送frame。
- 规范：client与server的HTTP/2 connection preface都包含一个可能为空、但不带ACK的SETTINGS frame；SETTINGS ACK只确认此前收到的SETTINGS，不能作为对端的初始settings替代品。对端首个frame不是这种SETTINGS时应视为connection `PROTOCOL_ERROR`。
- 位置：通用SETTINGS ACK处理在`lualib/silly/net/http/h2.lua:1211-1278`；client首帧检查与ACK等待在`:1513-1546`；server对称路径在`:1669-1711`。
- 触发：peer在连接前言位置先发送stream 0、空payload、带ACK的SETTINGS；随后可以发送普通SETTINGS及对Silly初始SETTINGS的ACK，或保持连接不再完成握手。
- 影响：两端都把非法首帧当作有效连接前言继续握手，没有按协议拒绝。若peer继续补帧，连接可在从未收到合规初始SETTINGS的情况下进入可用状态；若不补帧，则叠加`H2-025`无限占用握手task/fd。严格peer与Silly对连接建立边界的判断不一致，协议错误也缺少明确诊断。
- 证据：两个`handshake_as_*`都只验证`t == FRAME_SETTINGS`，未验证`f & ACK == 0`；随后直接调用`frame_settings`。该helper对合法空ACK立即返回，不发送ACK也不报告失败；握手循环继续读取，直到看到任意SETTINGS ACK才结束。因此ACK-only首帧被确定性接受。
- 根因：通用SETTINGS处理正确处理运行期ACK，但握手层没有对“首个SETTINGS”施加比普通frame更强的前言约束，且handler没有返回可供握手判断的frame语义结果。
- 建议解法：client/server首帧路径显式要求type SETTINGS、stream 0且ACK未设置，再交给可返回成功/错误的SETTINGS validator；任何前言违规都发送/记录`PROTOCOL_ERROR`并关闭连接，不能继续等ACK。将初始SETTINGS已接收与本端SETTINGS已确认建模为两个独立状态。
- 回归测试：修复阶段覆盖首帧空/非空普通SETTINGS、空ACK、带payload ACK、非0 stream及非SETTINGS；client/server都应只接受前两种合规普通SETTINGS（包括空payload），其余有限时间内失败并释放资源。当前不运行握手复现。

### H2-035 — P2 — 空闲 channel close 在异步 GOAWAY flush 前关闭 transport，graceful shutdown wire 必然丢失

- 状态：已确认；task.fork调度顺序、channel GOAWAY/flush/close与client pool关闭链静态推导。本轮不建立或关闭H2连接。
- 规范/契约：HTTP/2 endpoint开始优雅关闭时应先发送GOAWAY，让peer获得不再建立新stream及已处理边界；双语HTTP reference还把`client:close()`描述为gracefully closing pooled connections。直接transport EOF只能表达异常/不确定终止，不能替代GOAWAY。
- 位置：异步frame queue/flush在`lualib/silly/net/http/h2.lua:499-530`；NO_ERROR GOAWAY与close判定在`:547-610`；公开channel close在`:679-699`；高层pool close在`lualib/silly/net/http/client.lua:417-443`；fork仅入wakeup queue、当前消息后才dispatch在`lualib/silly/task.lua:163-170,228-239`。
- 触发：对`streamcount==0`的H2 channel调用`close()`；最常见路径是HTTP client关闭其idle H2 pool，也包括新建后尚无stream或全部stream已经回收的channel。
- 影响：peer只观察TCP/TLS EOF，看不到GOAWAY和Last-Stream-ID，无法区分正常停机与连接故障，也无法使用协议边界判断请求是否可能处理；监控、重试分类和graceful drain语义失真。若sendbuf中还有其他异步control frame，它们也随同GOAWAY被清除。调用方看到close已完成，之后没有任何路径重新发送这些帧。
- 证据：`channel_goaway(NO_ERROR)`只调用`channel_write`，后者把GOAWAY放入`sendbuf`并`task.fork(channel_flushwrite)`，不会同步执行。`C.close`紧接着调用`channel_checkclose`；streamcount为0时它立即`conn:close(); ch.conn=nil`。当前业务函数不yield，故flush task之后运行时看到nil conn，只清空sendbuf而不写wire。error GOAWAY路径专门同步调用`channel_flushwrite`，反向证明NO_ERROR路径缺少相同发送保证。
- 根因：graceful close把“frame已排队”误当作“frame已交给transport”，connection lifetime没有等待/拥有异步writer completion；close条件只看streamcount，不看sendbuf/writeco。
- 建议解法：建立channel writer owner和closing状态。首次graceful close同步或可等待地写出GOAWAY，只有transport接受frame且send queue排空后才关闭；若要两阶段drain，则先发送max/processed boundary GOAWAY、拒绝新stream、等待active streams或deadline，再发送最终GOAWAY并关闭。所有write failure走`H2-030`统一终态；重复close幂等且不能跳过pending flush。
- 回归测试：修复阶段用记录transport覆盖idle close、active streams drain、已有pending PING/WINDOW_UPDATE、write failure、deadline与重复close；逐字节断言EOF前恰有合法GOAWAY且Last-Stream-ID符合`H2-016`修复，close返回时writer/sendbuf/conn均已终态。当前只保存静态证据。

### H2-036 — P2 — client 接受 final response HEADERS 之前的 DATA，高层可返回无 status 的成功对象

- 状态：已确认；client stream初态、DATA dispatch、readall waiter与高层response构造静态推导。本轮不发送header-less response。
- 规范：HTTP/2 response必须以包含恰好一个`:status`的initial HEADERS field section开始，之后才允许DATA；缺失initial response headers的消息是malformed，应以对应stream `PROTOCOL_ERROR`结束，不能把DATA当成有效response content。
- 位置：stream初始remote state在`lualib/silly/net/http/h2.lua:456-495`；DATA接收在`:1177-1205`；只有HEADERS handler验证status在`:1446-1510`；`readall`在`:1110-1124`；高层直接读取并组装response在`lualib/silly/net/http/client.lua:351-405`。
- 触发：server对已发送request的client stream不发送任何response HEADERS，直接发送一个或多个DATA，最后设置END_STREAM；单个`DATA(payload, END_STREAM)`即可。
- 影响：convenience `get/post`不先调用`waitresponse`，而是直接`stream:readall()`；它会取得payload并返回非nilresponse table，其中`status=nil`、headers为空、body为攻击者数据且error=nil。仅以`if response then`判断成功的调用方会把协议上根本不存在的HTTP响应当成功处理；状态码鉴权、redirect/error policy也被绕过。streaming调用若先`waitresponse`可能得到EOF，但同一底层对象因调用顺序不同产生不同安全语义。
- 证据：`frame_data`仅在`s==nil`或`remotestate>=STATE_CLOSE`时报错；`STATE_NONE`明确小于close，所以会append、累计并将state直接改为`STATE_DATA`。END_STREAM时`stream_remoteend`会把等待`STATE_CLOSE`的readall以完整buffer唤醒。唯一`:status`检查只存在于`frame_header_client`，该函数从未执行；高层随后无条件使用`stream.status/header`构造response，没有要求status存在。
- 根因：实现把RFC stream state与HTTP message phase混为一个宽松数值状态；DATA legality只验证frame-level stream存在性，没有验证response initial field section已经成功提交。
- 建议解法：为每个方向建立独立、单调的message phase（awaiting-initial、informational、final-headers、body、trailers、ended/reset）；client在final HEADERS前收到任何DATA都只reset该stream(PROTOCOL_ERROR)，唤醒所有waiter并禁止返回partial success。高层组装response前再防御性要求validated final status，以typed protocol error收尾。
- 回归测试：修复阶段覆盖DATA/空DATA在initial HEADERS前、带/不带END_STREAM、先informational再DATA、正常final→DATA及两个并发streams；`waitresponse/read/readall/get/post`都必须对malformed sequence返回错误且只reset目标stream，永不产生status=nil的成功对象。当前只保存静态证据。

### H2-037 — P2 — RST 后 `readall` 优先返回缓冲的 partial body 并吞掉 terminal error

- 状态：已确认；H2 DATA buffer、RST/terminal state、等待与延迟readall两条路径静态推导。本轮不发送DATA后RST。
- 位置：DATA append在`lualib/silly/net/http/h2.lua:1177-1205`；RST终态在`:858-892,1336-1352`；read/readall返回顺序在`:1088-1124`；channel teardown设置RST在`:563-590`。
- 触发：peer先在合法response/request stream发送一段DATA但不设END_STREAM，随后发送RST_STREAM；应用在RST之后才调用`readall()`，或原本正在`readall()`、首次收到reset error后再次调用以尝试收尾。connection GOAWAY/EOF把stream置RST且buffer已有数据时也相同。
- 影响：`readall()`返回残缺body和nil error，丢弃`Stream cancelled`、protocol error或`Channel goaway`等终态。应用可能把被peer明确取消/失败的request body当完整指令执行，或把不完整response当成功解析、缓存和验证；同一stream仅因读取调用发生在RST之前或之后就得到相反结果。reset仍留在对象但buffer被消费，后续调用才重新暴露error，通常已经晚于业务提交。
- 证据：当`remotestate>=STATE_CLOSE`时，`S.readall`第一步无条件`dat=s.recvbuf:readall()`，只要`#dat>0`就立刻`return dat,nil`；只有buffer为空才区分normal END与RST。若readall正在等待，RST会先以nil唤醒并返回`s.errstr`但不清buffer，第二次调用进入同一partial-success分支。`S.read`同样先消费足量buffer再看RST，说明终态与data交付没有显式组合契约。
- 根因：normal END与error/reset共享同一“closed后先drain buffer”分支，API又不能同时表达partial data和terminal error；实现默认任何非空数据都足以覆盖消息完整性失败。
- 建议解法：`readall`只在normal END时返回完整buffer成功；RST/GOAWAY/protocol error必须稳定返回terminal error并明确丢弃或通过structured incomplete result附带partial bytes，不能返回`data,nil`。若streaming `read(n)`保留“先交付已收bytes、下次报错”的语义，需文档化且每个byte/error只交付一次；gRPC/message层不得把partial frame视为EOS。
- 回归测试：修复阶段覆盖0/1/N个DATA后remote RST各error code、local reset、GOAWAY/EOF、readall在reset前等待与reset后调用、首次错误后重试，以及正常DATA+END；client/server两向均断言RST永不产生完整成功，partial策略可观察且一致。当前只保存静态证据。

### H2-038 — P2 — 收到 RST_STREAM 后新的 respond/write/closewrite 仍排帧并报告成功

- 状态：已确认；remote reset、blocked/new writer、server handler收尾与frame queue静态推导。本轮不发送RST或在closed stream写帧。
- 规范：收到RST_STREAM后该stream立即进入closed；除规范明确允许的优先级处理外，endpoint不得继续在该stream发送HEADERS/DATA。已阻塞的发送和之后的新发送都必须观察同一terminal error，不能把“peer已取消”仅当读取方向结束。
- 位置：RST只写remote state并唤醒当前writer在`lualib/silly/net/http/h2.lua:843-892,1336-1352`；`respond`只检查channel在`:953-966`；`write/closewrite`只检查local state在`:968-1029`；server handler返回后无条件closewrite在`:1550-1560`。
- 触发：client对server request发送RST_STREAM(CANCEL)后handler继续计算并调用`respond/write/closewrite`，或server reset client request/response stream后client再次写；也包括先前blocked writer已被RST唤醒返回error，调用方稍后重试写入同一对象。
- 影响：新调用返回true并把HEADERS/DATA/END_STREAM加入connection send queue，消耗flow-control credit和CPU，却永远不可能构成有效stream。peer在它发出的reset到达本端后仍收到这些frames，可忽略、再次reset或按closed-stream规则终止connection，因而一个普通取消可干扰同连接其他请求。server handler无法可靠观察client cancellation，可能继续序列化大response；API成功返回又掩盖了工作和wire均已失效。
- 证据：`stream_remoteend(...STATE_RST...)`只设`s.remotestate=STATE_RST`和`s.errstr`，不会同步关闭`s.localstate`；仅当某个write当前正等待credit时才通过`stream_writewakeup`返回error。之后`S.respond`只要`s.channel`存在便成功，`S.write/S.closewrite`只拒绝`localstate>=STATE_CLOSE`，完全不读remotestate/errstr，所以会经`stream_writeheader/build_body/channel_write`排帧。正常server wrapper也不会检查handler期间出现的remote reset。
- 根因：实现把HTTP/2 stream的双向half-state用于END_STREAM，却把RST错误地只落在remote half；没有不可逆的whole-stream reset latch供所有公开操作共同检查。
- 建议解法：RST建立单调的stream-terminal/reset状态，原子结束read/write waiters并让所有之后的respond/write/flush/closewrite返回原始typed error，且不得再排任何非必要frame或扣credit。handler可通过context/cancel信号尽早停止；wrapper最终close只回收map/quota，不再发送第二次RST/END。与`H2-017`结合保留已经完整收到的response结果，但必须停止尚未结束的request发送。
- 回归测试：修复阶段在respond前、headers后、partial DATA、blocked flow-control write和handler返回前分别注入各RST code；覆盖client/server和write retry，断言RST后零新HEADERS/DATA、所有调用稳定失败、quota/queue/credit收敛且其他streams继续。当前只保存静态证据。

### H2-039 — P2 — client 把仅本地预留、尚未发 HEADERS 的 stream ID 当作 wire-open

- 状态：已确认；openstream reservation、首次header发送/ID重排及client frame handlers静态推导。本轮不猜测或发送idle stream frame。
- 规范：本端仅创建application stream对象不会让HTTP/2 wire stream离开idle；只有发送initial HEADERS才打开stream。peer在真正idle id发送HEADERS/RST_STREAM/WINDOW_UPDATE必须按各frame state规则产生connection error，不能因本地恰有未发布对象就接受。
- 位置：reservation立即进map在`lualib/silly/net/http/h2.lua:649-676`；首次真正发送及可能重排id在`:704-738`；client HEADERS/RST/WINDOW_UPDATE仅查map在`:1336-1352,1366-1407,1446-1510`；IDLE close测试背景在`test/testhttp2.lua:1045-1110`。
- 触发：调用`ch:openstream()`后在`request/write/closewrite/flush`前yield；peer依据已见最高id猜测这个下一个奇数id并发送合法response HEADERS、RST_STREAM或WINDOW_UPDATE。多个本地reserved streams与乱序首次发送会扩大可猜id集合。
- 影响：client可接受一个从未发送request的response并让应用读取status/body，或把idle RST/window update当正常stream事件；之后真正发送请求时可能在peer看来使用已closed/非法id，引发reset/connection failure并影响其他复用streams。状态/错误仅取决于本地Lua对象是否提前分配，而不是双方可观察的wire历史，破坏stream-id安全边界。
- 证据：`C.openstream`立即递增`streamidx`、写`ch.streams[id]=stream`并增加count，但`S.request`只保存header，直到`stream_writeheader`才真正排HEADERS；该函数还会为乱序发送重新分配更高id，证明此前id只是reservation。三个接收handler却把`s~=nil`等同非idle，HEADERS可直接通过`:status`验证并进入response，RST直接terminal，WINDOW_UPDATE直接加credit；均不检查`localstate==STATE_NONE/writeheader`或“initial HEADERS已flush”标志。
- 根因：一个map同时保存application reservations、wire-active streams和closing tombstones，frame state判定以object existence替代独立的protocol stream history。
- 建议解法：分离reserved对象与wire stream registry，或为每个id维护严格`IDLE→OPEN/...`状态；首次HEADERS编码/排入有序writer时原子提交id和map，之前收到该id任何不允许的frame按真正idle规则处理。乱序发送的id分配应在commit时完成且不会与接收侧可见历史冲突；closed history继续独立保留。
- 回归测试：修复阶段覆盖open后在request前/request后但flush前yield，peer对reserved id发送HEADERS/RST/WINDOW_UPDATE/DATA/PRIORITY，以及两个reserved stream乱序发送；除PRIORITY规范例外外idle frame应正确终止connection，绝不向应用发布响应，正常commit后同类frame按open state处理。当前只保存静态证据。

### H2-040 — P2 — sender 不校验 Content-Length 与实际 DATA 总量

- 状态：已确认；request/response header保存、DATA分片、flow-control续写及三种END_STREAM路径静态推导。本轮不向独立peer发送长度失配消息。
- 规范：HTTP/2消息携带Content-Length时，其十进制值必须等于组成content的全部DATA frame payload长度；不相等即malformed。sender必须拒绝自相矛盾的调用，不能把检测责任留给peer。
- 位置：stream只维护接收计数在`lualib/silly/net/http/h2.lua:176-214,453-495`；request/respond保存header在`:938-966`；header、DATA和END_STREAM发送在`:700-738,805-838,896-930,968-1029`；仅接收方向执行长度检查在`:845-877,1177-1205,1446-1499,1562-1648`。
- 触发：client或server分别以`request/respond`声明Content-Length=N，随后通过任意次数`write`和`closewrite(data, trailer)`发送少于或多于N字节；也包括非零N却直接`closewrite()`、零N却发送正文，以及用trailer结束一个长度失配的消息。
- 影响：公开API全部可返回true并在wire上完成一个必定malformed的request或response。严格peer会在END_STREAM处以PROTOCOL_ERROR reset该stream；本端业务却已把发送视为成功，造成请求提交状态、响应日志和重试判断错误。经代理或异构gRPC/HTTP2实现时会出现稳定互操作失败；若不同hop对声明长度和DATA采用不同信任策略，还会放大消息完整性分歧。
- 证据：stream对象只有`recvbytes/recvexpect`，没有对应`sendbytes/sendexpect`。`S.request/S.respond`原样保存header；`S.write`只按flow-control切DATA，`S.closewrite`可由initial HEADERS、DATA或trailing HEADERS任一路设置END_STREAM，所有路径均未解析Content-Length或比较累计发送量。相反，recipient明确累计`recvbytes`并在remote END比较，证明发送侧状态缺口。现有HTTP/2测试中的Content-Length均恰好匹配正文，未覆盖mismatch。
- 根因：Content-Length完整性被实现成纯接收属性，没有抽象为HTTP message双向共同不变量；底层write API的成功只代表已排帧，未验证调用序列能形成合法消息。
- 建议解法：initial headers提交时严格解析单一规范十进制Content-Length并保存`sendexpect`；每次DATA发送前以checked arithmetic累计且立即拒绝超发，在任何END_STREAM排帧前要求累计值恰好匹配。失败应稳定终止/reset该stream、唤醒writer且不得发送矛盾的END_STREAM；HEAD/无content响应的规则与`H2-031`统一处理。
- 回归测试：修复阶段覆盖client request/server response的少发、多发、zero/nonzero、分片write、final data、trailer结束、flow-control阻塞后续写与合法精确匹配；断言失配调用返回typed error、wire上不完成malformed消息、其他并发stream不受影响。当前只保存静态证据。

### H2-041 — P2 — zero-length PADDED frame 绕过必需的 Pad Length 校验

- 状态：已确认；frame header/payload读取、padding预处理及DATA/HEADERS dispatch静态推导。本轮不发送畸形padding frame。
- 规范：DATA或HEADERS设置PADDED flag时，payload开头必须存在1-byte Pad Length；若该值等于或大于frame payload长度，recipient必须把它作为connection `PROTOCOL_ERROR`。因此payload length为0时不可能包含合法padding结构，不能按普通空frame继续处理。
- 位置：统一frame读取/裁剪在`lualib/silly/net/http/h2.lua:268-307`；DATA状态转换在`:1177-1205`；client/server HEADERS入口在`:1446-1499,1562-1648`。
- 触发：peer在open stream发送length=0、flag含PADDED的DATA，最明显是同时设置END_STREAM；HEADERS/PUSH_PROMISE上的同一结构也会跳过padding层，随后才由各自不完整的field/state校验偶然决定结果。
- 影响：zero-length PADDED DATA被当作普通空DATA接受，带END_STREAM时可正常结束request/response并让应用看到成功，而规范要求立即终止connection。严格proxy/peer与Silly对同一frame作出相反决定，形成协议合规和诊断分歧；malformed消息还能推进Content-Length、stream终态及业务handler生命周期，导致本应废弃连接继续承载其他streams。
- 证据：padding分支被包在`if n > 0 then`内部；当frame header声明`n=0`时直接走`dat=""`，PADDED bit从未检查。`frame_data`对空dat仍设置`remotestate=STATE_DATA`，若END_STREAM存在就调用normal `stream_remoteend(...STATE_END...)`。非空payload路径已有`pad_length >= #dat`的正确拒绝，说明缺口仅由零长度外层分支造成。现有测试未覆盖该边界。
- 根因：frame reader把“无需读取payload”和“payload内没有type-specific前缀”视为同一情况，在知道flags前提下仍先按长度短路；padding语法没有归属到DATA/HEADERS/PUSH_PROMISE各自parser。
- 建议解法：通用reader保留原始payload及其wire length；仅在允许PADDED的frame parser中，无条件按flag要求至少1 byte Pad Length，再以`pad_length < payload_length`验证并裁剪。其他frame type忽略0x08，配合`H2-002`一次性修正type-specific flag语义；flow control继续按裁剪前完整DATA payload计数。
- 回归测试：修复阶段分别对DATA、HEADERS、PUSH_PROMISE覆盖length 0+PADDED、仅1-byte padlen=0、padlen等于/大于payload、合法最大padding及未设置PADDED的空frame；断言畸形padding始终connection PROTOCOL_ERROR、合法空content仍可表达且并发stream不会在错误后继续。当前只保存静态证据。

### HPACK-002 — P1 — varint 溢出可进入 C 未定义行为和越界长度路径

- 状态：已确认；RFC 7541 与确定性 C 整数/指针语义推导。按用户要求，本阶段不构造恶意字节复现；修复阶段需在隔离 sanitizer 环境验证。
- 规范：RFC 7541 §5.1 明确 HPACK integer 可有任意长度，攻击者可用大量 octets 溢出实现整数；超过实现的 value 或 octet-length 限制必须作为 decoding error。所有 index、string length 和 dynamic table size update 都复用该整数格式。
- 位置：`read_varint` 在 `luaclib-src/lhttp.c:558-583`；string length 消费在 `:613-630`；index/table-size 调用在 `:632-771`。HTTP/2 可达入口为 `lualib/silly/net/http/h2.lua:314-365`。
- 触发：peer 在 HPACK field block 中提供 prefix 饱和后带过多 continuation octets 的整数，尤其作为 literal name/value 的 7-bit-prefixed string length；也可使用一直设置 continuation bit、到 block 末尾仍未终止的编码。
- 影响：`M` 每轮加 7 且没有上限，表达式 `(B & 0x7f) << M` 在 M 达到有符号 int 的符号位或位宽后构成 C 未定义行为。累加结果是 `unsigned int`，函数却返回 `int`；实现定义的负值/回绕长度进入 `uctx->p + len`，其本身可形成对象外指针，随后 raw string 分支把负 `int` 转成巨大 `size_t` 交给 `lua_pushlstring`，存在越界读取、异常巨额分配、崩溃或进程未定义行为风险。未终止 varint 也可能被当作已有值继续处理，而不是稳定返回 compression error。
- 证据：循环条件只有 `ctx->p < ctx->e`，没有 `M`、octet count、`UINT_MAX` 加法或 termination 检查；shift 左操作数经 integer promotion 为 signed `int`。`push_sv` 声明 `int len`，只用 `if (uctx->p + len > uctx->e)` 检查上界，没有先验证 len 非负/可表示和 remaining subtraction；raw 分支直接 `lua_pushlstring(..., len)`。65,535-byte compressed block 足以越过 32-bit shift 边界。
- 根因：照抄数学伪代码但未把“indefinite size”映射为显式的实现上限和 checked arithmetic，又混用 unsigned accumulator、signed return/length与指针加法。
- 建议解法：让 decoder 返回 `{ok, value}`，使用明确宽度无符号类型；在每个 octet 前检查 shift、乘法/加法和每用途 maximum，并要求遇到 continuation=0 才成功。string length 用 `size_t` 且以 `len <= (size_t)(e-p)` 做 subtraction-based bounds check，绝不先构造可能越界的 `p+len`；任何超值、超长或未终止编码返回 decoding error/HTTP2 `COMPRESSION_ERROR`。
- 后续回归条件：修复阶段覆盖各 prefix 的最大合法值、跨 32/64-bit 边界、过多零 continuation、过多 0xFF、未终止、non-minimal 但未溢出的合法整数，以及 string/index/table-size 三种用途；ASan/UBSan 下零告警并确认下一连接/stream 的错误作用域。本轮不新增测试代码。

### HPACK-004 — P1 — 32 位 table-size setting 窄化为 C `int` 后可触发 signed overflow

- 状态：已确认；SETTINGS无符号值、Lua integer、native context字段和eviction arithmetic静态推导。本轮不发送极值setting或运行UBSan。
- 规范：SETTINGS_HEADER_TABLE_SIZE是32位无符号值；HPACK实现必须在自身可表示/配置的资源上限内安全处理，不能让合法wire整数经窄化进入负容量或C未定义行为。无法支持的资源值应采用明确上限/安全策略，而非污染decoder状态。
- 位置：SETTINGS以`>I4`读取并无上界检查在`lualib/silly/net/http/h2.lua:1211-1278`；HPACK容量字段和构造在`luaclib-src/lhttp.c:22-30,246-260`；减法/eviction在`:289-318`；公开hardlimit赋值在`:782-791`。
- 触发：peer先发送可被索引的header让当前HPACK动态表`table_size>0`，再发送`SETTINGS_HEADER_TABLE_SIZE`取`0x80000000..0xffffffff`中的值。当前H2方向错误会把它传给receive context；即便以后按规范改传send context，只要该表已有条目，同一native缺陷仍可达。直接调用公开`hpack.hardlimit`传超出C int范围也相同。
- 影响：在项目支持的常见32位`int` ABI上，Lua正整数窄化为负`hard_limit/soft_limit`；紧接着`soft_limit - table_size`低于`INT_MIN`，构成C signed overflow/undefined behavior。结果可表现为错误eviction、动态表encoder/decoder失步、Lua异常、连接级COMPRESSION_ERROR、进程崩溃，优化构建下结果不可依赖。即使表为空暂未溢出，context也进入负容量，后续索引决策不再满足HPACK不变量。
- 证据：Lua `string.unpack('>I4')`保留0..2^32-1，Lua层只限制INITIAL_WINDOW/MAX_FRAME而不限制HEADER_TABLE_SIZE。`lhpack_hardlimit`把`luaL_checkinteger`结果直接赋给两个`int`字段并马上调用`try_evict`；后者以有符号表达式`soft_limit - table_size`比较剩余容量。构造函数也执行同样未经checked conversion的赋值。现有测试的唯一resize值为2048，无法覆盖位宽边界。
- 根因：wire/API容量域、Lua整数和内部C计数没有共同的可表示范围；setter不是transactional checked conversion，容量运算也未使用无符号宽类型或subtraction-safe比较。
- 建议解法：为实现定义明确且可配置的最大动态表预算（不超过`INT_MAX`及内存策略），在Lua/C边界先以`lua_Integer`验证非负和上限再窄化；内部容量/field size统一使用`size_t`或固定无符号宽度，并用`table_size <= limit && needed <= limit-table_size`避免overflow。H2层仍须另行修复`H2-004`的setting方向，并区分peer允许的最大值与当前encoder table size。
- 回归测试：修复阶段覆盖0、4096、INT_MAX附近、INT_MAX+1、UINT32_MAX以及动态表为空/非空两种状态；合法可支持值保持同步，超资源值采取文档化且无UB的策略。ASan/UBSan下验证后续header block、setting ACK和并发streams均稳定。本轮只保存静态证据。

### GRPC-001 — P1 — client 把所有请求的 `:authority` 编码为字面量 `nil`

- 状态：已确认；gRPC over HTTP/2 调用定义、RFC 9113 request pseudo-header 语义与确定性参数/转换路径推导。本阶段只做静态 review，不新增触发代码。
- 规范：gRPC Call-Definition 将 `:authority` 作为请求 pseudo-header；RFC 9113 §8.3.1 要求构造 HTTP/2 请求时在存在目标 URI authority 时生成 `:authority`，其值来自目标 URI 的 authority component。它不能被实现内部缺省值替换为另一个有效字符串。
- 位置：endpoint target/hostname 在 `lualib/silly/net/grpc/client/conn.lua:16-35,49-73`；HTTP/2 channel authority 初始化及 request sender 在 `lualib/silly/net/http/h2.lua:231-263,700-738,1718-1724`；HPACK Lua 值转换在 `luaclib-src/lhttp.c:489-548`。
- 触发：使用任意 gRPC client target 发起 RPC。HTTPS 与明文路径相同；HTTPS 只是另外把正确 hostname 传给 TLS SNI。
- 影响：所有 RPC 在 wire 上携带 `:authority: nil`，严格校验 Host/authority 或按 authority 选择虚拟服务的 server/proxy 会拒绝请求、误路由到默认虚拟主机，或应用错误的鉴权/策略；TLS SNI 与 HTTP authority 还会互相矛盾。
- 证据：`newchannel` 取出 `endpoint.hostname` 并用于 `tls.connect`，随后却调用只有两个实参的 `h2.newchannel(scheme, conn)`。后者把缺失的第三参数赋给 `ch.authority`；每次 `stream_writeheader` 又无条件把该值加入 HPACK field list。C encoder 对 value 使用 `luaL_tolstring`，Lua `nil` 因而成为长度 3 的字面量 `"nil"`，不是省略字段。Silly server 的 request validator 没有要求普通请求存在 authority，所以同库自测互相掩盖该偏离。
- 根因：连接层分别维护 network address 与 logical hostname，但创建 HTTP/2 channel 时没有把 logical authority 穿过 API 边界；底层 sender 又对 nil 做宽松字符串化，未 fail closed。
- 建议解法：将规范化的 target authority（含非默认端口时的端口）显式传给 `h2.newchannel(scheme, conn, authority)`；HTTP/2 sender 在缺失/非法 authority 时应在写 wire 前返回错误，不应依赖 Lua 通用字符串转换。TLS SNI 仍只使用不含端口的 hostname。
- 后续回归条件：修复阶段用捕获 peer 分别验证 DNS target、IPv4、bracketed IPv6、默认/非默认端口和 TLS SNI：`:authority` 与 target 一致且绝不为 `nil`；再以两个 virtual hosts 证明请求只路由到目标服务。本轮不新增测试代码。

### GRPC-002 — P2 — 四种 client 调用都缺少 `te: trailers`

- 状态：已确认；gRPC over HTTP/2 Call-Definition 与确定性 request 构造路径推导。本阶段只做静态 review，不新增触发代码。
- 规范：gRPC HTTP/2 protocol 的 Request-Headers grammar 把 `TE → "te" "trailers"` 列入 Call-Definition，并说明它用于探测不兼容的 proxy。RFC 9113 允许 HTTP/2 request 中的 `te` 仅取值 `trailers`。
- 位置：四种调用分别在 `lualib/silly/net/grpc/client/service.lua:134-176,178-213,215-235,237-257` 构造 request headers；最终 HTTP/2 sender 在 `lualib/silly/net/http/h2.lua:700-738`。
- 触发：通过任意检查 gRPC Call-Definition、或需要确认下游支持 trailers 的 proxy/server 发起 unary、client-streaming、server-streaming 或 bidi RPC。
- 影响：请求不能声明客户端理解 HTTP trailers；中间层可将其判定为不兼容客户端并拒绝、降级或错误处理尾部 `grpc-status`，造成跨实现调用失败。即使直连 server 接受，缺字段仍使 wire request 不满足 gRPC 调用定义。
- 证据：四个 constructor 都传入仅含 `['content-type']='application/grpc'` 的 Lua table；HTTP/2 request sender只补 pseudo headers，不会自动补 `te`。仓库内 gRPC server 也不校验 TE，因此同库测试无法发现。
- 根因：gRPC 层把 HTTP/2 transport 能力视为隐式已知，没有把 gRPC 要求的代理兼容性信号写入调用模板；四条调用路径又复制了同一个不完整 header literal。
- 建议解法：集中定义并复用 gRPC request header builder，所有 RPC 固定加入 `te = 'trailers'`，同时承载 authority、timeout、metadata 与 content subtype；继续由 HTTP/2 层拒绝其他 TE 值。
- 后续回归条件：修复阶段捕获四种 RPC 的首个 HEADERS，逐一断言只有一个小写 `te: trailers`；再经会拒绝缺失 TE 的独立 gRPC-aware proxy 验证正常转发。本轮不新增测试代码。

### GRPC-003 — P2 — server 只按 path 路由，不验证 gRPC Call-Definition

- 状态：已确认；gRPC over HTTP/2 Request-Headers grammar、Content-Type handling 要求与确定性 dispatch 路径推导。本阶段只做静态 review，不新增触发代码。
- 规范：gRPC Call-Definition 要求请求使用 `:method POST`、合法 scheme/path、`te: trailers` 和以 `application/grpc` 开头的 Content-Type。协议特别建议 server 在 Content-Type 不是 `application/grpc` 前缀时返回 HTTP 415，以免普通 HTTP/2 client 把 gRPC error 当成成功响应。
- 位置：gRPC listener/dispatch 全部位于 `lualib/silly/net/grpc/server.lua:8-55`；底层 HTTP/2 只执行通用 request validation，在 `lualib/silly/net/http/h2.lua:386-444,1555-1648`，不会替 gRPC 校验这些语义。
- 触发：向已注册 RPC path 发送 GET、非 gRPC Content-Type、缺失/非法 TE 的 HTTP/2 request；向未知 path 发送普通 HTTP/2 request也会得到 gRPC-style 200。
- 影响：非 gRPC 流量被错误送进 protobuf envelope parser并可能调用业务错误路径；Content-Type 不匹配仍返回 HTTP 200/application-grpc，而不是明确的 415。代理误路由、探测请求或普通 HTTP client 因此得到误导响应，也削弱了 TE 用来识别不兼容中间层的作用。
- 证据：`dispatch` 只读取 `stream.header[':path']` 并查 `handlers[path]`；命中后立即安排 `200 application/grpc` 并调用 handler，未读取 method/content-type/te。未知 path 同样固定返回 HTTP 200 的 Trailers-Only gRPC error。仓库自测输入来自同库 client，只覆盖 POST 与 application/grpc，且该 client 自身漏发 TE。
- 根因：gRPC listener 被实现成 path router，没有位于 router 前的 protocol admission 层；通用 HTTP/2 parser 成功被误当成 gRPC request 已合法。
- 建议解法：dispatch 前集中校验 method、scheme/path、Content-Type prefix 与 TE token；Content-Type 不匹配返回 HTTP 415，其他 malformed gRPC call 按协议定义选择 HTTP/gRPC error且不得调用业务 handler。只有完整通过 admission 才按 path 路由。
- 后续回归条件：修复阶段以已知 path 覆盖 GET、缺 Content-Type、`application/json`、合法 `application/grpc+proto`、缺失/错误/正确 TE；断言无效请求不调用 handler、非 gRPC Content-Type 为 415、合法 subtype 可调用。本轮不新增测试代码。

### GRPC-004 — P2 — compressed flag 与 `grpc-encoding` 关系未校验

- 状态：已确认；gRPC length-prefixed message grammar、compression specification 与确定性 envelope reader 路径推导。本阶段只做静态 review，不新增触发代码。
- 规范：Compressed-Flag 是单个 byte，但合法值只有 0 或 1；值 1 表示按本方向 `grpc-encoding` 声明的算法压缩。未声明 encoding 时 flag 必须为 0；flag 已设置却缺少非 identity encoding 的畸形消息必须得到 `INTERNAL`。server 收到真正不支持的 client compression 才应返回 `UNIMPLEMENTED`，并用 `grpc-accept-encoding` 告知支持集合；client 收到不支持的 server compression 应产生 `INTERNAL`。
- 位置：共用 envelope reader 在 `lualib/silly/net/grpc/helper.lua:16-50`；server status 发出路径在 `:23-40` 和 `lualib/silly/net/grpc/registrar.lua:80-228`；client error/status 消费在 `lualib/silly/net/grpc/client/service.lua:38-81,134-176`。
- 触发：message compressed flag 为 1、但对应方向没有 `grpc-encoding` 或值为 identity；flag 为 2..255；或 peer 使用实现不支持的已声明算法。
- 影响：畸形消息与能力不匹配被混为一谈，server 把应为 `INTERNAL` 的 protocol invariant violation报告为可被理解成“方法/能力未实现”的 `UNIMPLEMENTED`；client 对不支持的压缩响应只返回普通字符串，streaming 路径甚至可随后从 trailer 记录 OK。上层无法按标准 status 分类，压缩协商也无法互操作。
- 证据：reader 解出 flag 后只有 `compress ~= 0` 一个分支，不读取 stream headers 的 `grpc-encoding`，也不区分 1 与其他值。server 固定写 `grpc-status=UNIMPLEMENTED` 且不写 `grpc-accept-encoding`；client 共用同一分支直接返回 `"Compression not supported yet"`，之后的 status 仍由 peer trailer 决定。
- 根因：wire bit 被当作实现 feature toggle，而不是由 per-direction metadata 决定语义的协议字段；压缩协商与 envelope decoding 没有共享 call state。
- 建议解法：在 call admission 保存双方 encoding/accept-encoding 状态；先严格拒绝 flag 不在 {0,1}，再按 flag、declared encoding 与支持集合三者决定解压或标准 status。unsupported request algorithm 返回 UNIMPLEMENTED及接受集合；invalid flag/identity mismatch 和 unsupported response algorithm映射 INTERNAL。
- 后续回归条件：修复阶段对 client/server 双向覆盖 flag 0/1/2、缺失/identity/supported/unsupported encoding，断言 payload 是否解压、status code 和 `grpc-accept-encoding`；每条 message 独立建立压缩 context。本轮不新增测试代码。

### GRPC-005 — P1 — client response message 没有大小上限

- 状态：已确认；gRPC 32-bit message length、远端资源控制要求与确定性 read/buffer/window 路径推导。本阶段只做静态 review，不发送大 payload。
- 规范：gRPC message length 是 4-byte unsigned integer，因此 wire format 本身允许接近 4 GiB；实现必须在分配/缓存前应用本地最大接收消息配置，否则不可信 peer 可用合法 framing耗尽资源。gRPC status 定义也明确把超过配置最大值归为 `RESOURCE_EXHAUSTED`；常见默认值不是 wire protocol 的隐含保护。
- 位置：唯一的 `REQ_MAX_LEN=4*1024*1024` 与 envelope reader 在 `lualib/silly/net/grpc/helper.lua:6-50`；HTTP/2 exact-size read 与 DATA buffering/window update 在 `lualib/silly/net/http/h2.lua:779-799,1084-1105,1177-1204`；client 四种 response 路径在 `lualib/silly/net/grpc/client/service.lua:38-81,134-257`。
- 触发：恶意或配置不匹配的 server 发送 flag byte 后声明超大 32-bit message length，再持续发送 DATA；所有 unary/streaming response reader均以 `isreq=false` 调用共用 helper。
- 影响：client 在 protobuf decode 前把整个声明长度积入 stream buffer。DATA handler 在 exact-size read 尚未满足时逐帧发送 WINDOW_UPDATE，使 peer 可以持续灌入，接近 4 GiB 的单消息可导致巨额内存占用、OOM或进程不可用；只声明长度不完成还可结合缺省无 deadline长期占用 call。
- 证据：大小检查条件明确是 `if isreq and frame_size > REQ_MAX_LEN`，client 路径因此全部绕过。随后无条件调用 `h2stream:read(frame_size)`；底层不足时设置 `readneed=frame_size`，每个 DATA fragment 在 total 仍小于 readneed 时 append 后立即回补 stream credit，直到累计完整长度才唤醒 reader。仓库没有 client max-receive-message 配置或第二层限制。
- 根因：request 防护被硬编码在共享 decoder 中并以角色布尔值开关，而不是每个 channel/call 都有明确的 send/receive limit；transport exact-read 自动 flow-control 又放大了无界应用长度。
- 建议解法：为 client/server channel 和可选 per-call 设置 max receive message size，在读完 5-byte envelope 后、读取 payload 前检查；超限立即终止该 RPC并映射 RESOURCE_EXHAUSTED，且不要继续为未消费 payload回补窗口。用 chunked/limited reader避免一次性复制，压缩后还需独立限制解压后大小。
- 后续回归条件：修复阶段覆盖刚好 limit、limit+1、0xffffffff、只发 header、慢速 DATA，以及 unary/三种 streaming；断言超限在 payload缓存前失败、连接上其他 streams 仍可用、内存有界。本轮不新增测试代码。

### GRPC-006 — P2 — 单消息 RPC 不验证恰好一个 envelope

- 状态：已确认；protobuf method streaming cardinality 与确定性 read/drain 路径推导。本阶段只做静态 review，不新增触发代码。
- 规范：protobuf service method 的 `client_streaming=false` 表示 request side 恰好一条 message，`server_streaming=false` 表示 response side 恰好一条 message；零条或多条是 RPC framing/cardinality error，不能静默选第一条并报告 OK。EOS/最终 trailers 才能证明不会再出现第二条。
- 位置：server unary 与 server-streaming wrappers 在 `lualib/silly/net/grpc/registrar.lua:80-154`；client unary 与 client-streaming final response 在 `lualib/silly/net/grpc/client/service.lua:56-63,134-176`；单条 envelope decoder 在 `lualib/silly/net/grpc/helper.lua:16-50`。
- 触发：对 unary 或 server-streaming method 发送零/两个完整 request envelopes，第一条后保持 request side open；server 对 unary/client-streaming method 返回零/两个 response envelopes再以 `grpc-status: 0` 结束；或Silly handler正常返回`nil,nil`。
- 影响：server 会以第一条 request 调用业务逻辑并忽略额外输入，client 会以第一条 response返回成功并丢弃额外输出；反向的零响应又可被server明确标OK。两端对同一 wire call 的语义产生歧义，业务副作用可能在本应拒绝的请求上发生，也掩盖 peer 的 method descriptor/version 配置错误。
- 证据：server 两个单-request wrapper都只调用一次`readbody`，成功后立刻进入用户函数，不读EOS或第二条envelope；两个单-response wrapper仅在`output` truthy时调用`writebody`，随后无条件发OK，故`nil,nil`生成零响应。client两个单-response path只调用一次`readbody`，随后`readall()`把剩余DATA作为raw string排空且不验证为空；零响应时也没有生成cardinality status。
- 根因：共用 helper 只提供“读取下一条 message”，wrapper 没有提供“读取唯一 message 并确认 EOS”的组合操作；raw drain 被误用为完整性校验。
- 建议解法：实现 cardinality-aware reader。单消息 request/response在解码第一条后必须继续解析到EOS/trailer并确认没有第二个envelope；零条/多条按gRPC runtime cardinality规则生成UNIMPLEMENTED，截断余字节按解析错误处理，均不得返回业务成功。server应在调用unary handler前完成request-side cardinality验证，并拒绝把nil output以OK结束。
- 后续回归条件：修复阶段对 unary、server-streaming request side及 unary、client-streaming response side分别覆盖 0/1/2 条、第二条截断、第一条后延迟 EOS；只允许恰好一条进入/返回业务成功。本轮不新增测试代码。

### GRPC-007 — P1 — server 解析失败会缺失 status 或被覆盖成 OK

- 状态：已确认；gRPC response/trailer status 要求与确定性 wrapper/control-flow 推导。本阶段只做静态 review，不新增畸形 payload。
- 规范：RPC runtime/application error 必须通过 trailers 中的 `grpc-status`（通常 INTERNAL 等非 OK）传播；正常 response 的最终 Status 也始终必需。截断 envelope、protobuf decode failure或 streaming read error不能以无 status 的 HTTP/2 END_STREAM结束，更不能报告 `grpc-status: 0`。
- 位置：envelope/protobuf reader 在 `lualib/silly/net/grpc/helper.lua:16-50`；server stream reader 与四种 wrapper 在 `lualib/silly/net/grpc/registrar.lua:17-31,80-228`；通用 server handler 的无条件收尾在 `lualib/silly/net/http/h2.lua:1549-1559`。
- 触发：unary/server-streaming request 的5-byte header或payload在END_STREAM前截断；protobuf payload具有known field wire-type mismatch、坏field value等会令native decoder抛错的内容；或client-streaming/bidi handler循环读取时遇到同类错误。decoder静默接受截断tag/unknown field的另一根因见`GRPC-025`。
- 影响：返回nil的前两类会以HTTP 200/application-grpc但无grpc-status结束，client只能合成UNKNOWN；native decode抛错则越过unary/server-streaming wrapper和H2 `server_handler`全部收尾，使stream map与并发配额按`H2-027`永久滞留，可被远端重复消耗。client-streaming/bidi的decode异常恰好落入包围整个业务handler的pcall，被混同为application exception；其他stream read错误仍可被wrapper覆盖成OK。应用、监控和retry policy因而看到缺status、错误分类或成功，handler还可能基于错误前已读消息提交副作用。
- 证据：`pb.decode`并非helper假定的nil-on-error API：native known-field varint/type/length失败在`luaclib-src/pb.c:1853-1899`调用`luaL_error`，直接跳过`if not resp then "Decode error"`。unary/sstream在`readbody`外没有pcall，异常沿`dispatch→fn→H2 server_handler`展开，后两步不会再执行`closewrite/close`。普通readbody nil路径仍只log后return；stream reader虽设置`s.status=INTERNAL`，cstream/bstream wrapper却不读取并固定发OK。若partial envelope后EOS，`h2stream:eof()`还会把截断标为OK。
- 根因：message reader既没有统一protected decode，也只返回松散字符串错误，无法区分clean message-boundary EOS、mid-envelope EOF、protobuf parse exception与transport error；stream status又不是wrapper终局状态机的权威输入。
- 建议解法：用protected decoder返回结构化结果`message/clean_eos/protocol_error/transport_error`并跟踪envelope offset；所有wrappers通过唯一finalize函数选择最终status，已有runtime error不可被用户函数正常return覆盖。能够发送trailer时用INTERNAL等非OK，无法继续framing时按gRPC transport mapping reset；H2 handler仍应以finally保证stream/quota释放。
- 后续回归条件：修复阶段覆盖0..4-byte header截断、payload少1 byte、known-field invalid protobuf、错误发生于第1/第N条streaming message；断言异常不逃出gRPC wrapper、始终只有一个非OK final status、handler副作用边界明确且stream/quota释放。本轮不新增测试代码。

### GRPC-008 — P1 — streaming client 丢失 Trailers-Only 的真实 status

- 状态：已确认；gRPC response grammar 与确定性 HTTP/2 header mapping/status helper 路径推导。本阶段只做静态 review，不新增触发代码。
- 规范：gRPC response 可以是 `Response-Headers *Message Trailers`，也可以对立即失败使用 `Trailers-Only`；后者在一个带 END_STREAM 的 initial HEADERS field section 中同时携带 HTTP status、Content-Type 和必需的 grpc-status。所有四种 method cardinality 都必须等价消费它。
- 位置：streaming 共用 `check_trailer`、read/final-read 在 `lualib/silly/net/grpc/client/service.lua:38-81`；unary 的独立 fallback 在 `:164-173`；HTTP/2 client 首个 HEADERS mapping 在 `lualib/silly/net/http/h2.lua:1441-1500`。
- 触发：server 在任何 server-streaming、client-streaming 或 bidi call 上不发送 DATA，直接以 initial HEADERS+END_STREAM 返回 UNIMPLEMENTED、UNAUTHENTICATED、RESOURCE_EXHAUSTED 等 Trailers-Only response。Silly 自己的 unknown-method路径正会生成这种响应。
- 影响：streaming API 把 peer 的具体标准错误全部改写成 UNKNOWN/`No status in trailer`，上层无法进行正确鉴权提示、重试、限流或故障统计；同一 status 在 unary 与 streaming API 上得到不同结果。
- 证据：底层把首个 HEADERS字段写入 `h2stream.header`，即使它同时 END_STREAM；只有后续 HEADERS才进入 `h2stream.trailer`。unary 明确使用 `trailer['grpc-status'] or h2stream.header['grpc-status']`，证明实现已意识到该布局；streaming 的唯一 helper却只读取 `h2stream.trailer`，缺失时无条件合成 UNKNOWN。
- 根因：unary 与 streaming 各自实现终局 status 解析，Trailers-Only fallback 没有抽成共享逻辑。
- 建议解法：建立单一 response finalizer，识别 initial headers 是否 END_STREAM/是否含 grpc-status，并从正确 field section读取 Trailers-Only；普通 response仍要求最终 trailer status。四种 RPC API复用相同的 status/message/HTTP fallback 规则。
- 后续回归条件：修复阶段对三种 streaming 分别返回每个代表性非 OK Trailers-Only status及 OK/非法组合，断言 status/message 与 unary 完全一致；覆盖同库 unknown method和独立 gRPC server。本轮不新增测试代码。

### GRPC-009 — P1 — client 不执行 HTTP status/Content-Type 的 gRPC fallback

- 状态：已确认；gRPC response handling 与官方 HTTP→gRPC status mapping、确定性 client finalizer 路径推导。本阶段只做静态 review，不新增 proxy 响应。
- 规范：client 必须能处理 intermediary 返回的非 200、非 gRPC Content-Type或缺失 grpc-status 的 response，并向应用合成 gRPC status/message。缺 grpc-status 时官方映射至少规定：400→INTERNAL，401→UNAUTHENTICATED，403→PERMISSION_DENIED，404→UNIMPLEMENTED，429/502/503/504→UNAVAILABLE，其他（包括 200）→UNKNOWN；若有 grpc-status则优先使用它。
- 位置：HTTP/2 已保存 status/header 在 `lualib/silly/net/http/h2.lua:1463-1487`；gRPC status consumers 在 `lualib/silly/net/grpc/client/service.lua:38-81,134-176`。
- 触发：proxy、load balancer或非 gRPC upstream返回 401/403/404/429/502/503/504 等 HTTP response，缺少 grpc-status；或返回非 `application/grpc` Content-Type 的 body。
- 影响：认证/授权/未实现/临时不可用全部退化为 UNKNOWN或一个无结构的 `No status in trailer` 字符串。尤其 429/502/503/504 的 UNAVAILABLE语义丢失后，上层 retry/load-balancing policy 无法做标准决策；client还可能把 HTML/JSON body 前 5 bytes当作 gRPC envelope length，叠加无界 response read。
- 证据：底层解析后将 numeric HTTP status 放入 `h2stream.status`，并保留 content-type；gRPC service 文件从未读取这两个值。`check_trailer` 缺 grpc-status时固定 UNKNOWN；unary则直接返回 read error或固定文本，没有任何 mapping table或 Content-Type prefix检查。
- 根因：gRPC response finalization只围绕 trailer map实现，没有把 HTTP response admission与 intermediary fallback 纳入同一状态机。
- 建议解法：在读取任何 message envelope 前验证 response HTTP status和 gRPC Content-Type；终局若缺 grpc-status，按官方单向 mapping合成 code/message。若 status存在则优先，但仍记录/处理不合规 Content-Type；四种 RPC返回统一的结构化 status。
- 后续回归条件：修复阶段覆盖 mapping 表每个 HTTP code、其他 code、200 无 grpc-status、合法/非法 Content-Type、存在 grpc-status优先；断言非 gRPC body不进入 envelope decoder，UNAVAILABLE等 code准确传给上层。本轮不新增测试代码。

### GRPC-010 — P1 — 非法 `grpc-status` 文本可被 client 接受为 OK

- 状态：已确认；gRPC Status ABNF、status-code error mapping 与确定性 Lua numeric conversion 推导。本阶段只做静态 review，不新增伪造 response。
- 规范：`grpc-status` 必须是至少一位十进制数字的 ASCII string，且不能有前导零；解析 status 出错时 client runtime应产生 UNKNOWN。定义范围外的整数可以直接传播或转成 UNKNOWN，但语法非法的文本不能先按 Lua number grammar解释，更不能成为 OK。
- 位置：streaming finalizer 在 `lualib/silly/net/grpc/client/service.lua:38-53`；unary 独立解析在 `:164-174`；canonical code table 在 `lualib/silly/net/grpc/code.lua`。
- 触发：peer 在普通 trailers或 Trailers-Only发送 `grpc-status: " 0 "`、`+0`、`0x0`、`0e0`、`00`、小数等 Lua `tonumber` 可接受但 gRPC grammar禁止的值；或发送完全不可转换文本。
- 影响：多种 malformed status可被解释为 numeric 0，client把本应 UNKNOWN 的损坏 response报告成功，可能提交调用结果或触发成功侧业务流程。不可转换文本在 streaming helper中则产生 `status=nil`，破坏 API宣称的 integer status invariant并导致调用方分支异常。
- 证据：两处都直接调用通用 `tonumber(grpc_status)`，没有先以 canonical decimal grammar验证。unary只比较 `n ~= code.OK`，所以任何可转为 0 的非法文本通过成功判断；streaming直接返回转换结果，nil不替换成 UNKNOWN。没有 leading-zero、范围或整数字符检查。
- 根因：把通用编程语言数字 parser 当作 wire-level canonical integer parser，并且 unary/streaming继续各自处理失败分支。
- 建议解法：只接受 `"0"` 或首位 1..9 后跟 DIGIT 的完整字节串，使用 checked decimal accumulation；语法/溢出失败统一合成 UNKNOWN。再按 code table决定已知、未知整数的传播策略，四种 RPC共用 parser且永不返回 nil status。
- 后续回归条件：修复阶段覆盖 0..16、17/大整数、空串、00/01、空白、正负号、hex、指数、小数、非 ASCII digit与溢出；只有 canonical decimal可达对应 code，所有非法文本均为 UNKNOWN且不得成功。本轮不新增测试代码。

### GRPC-011 — P2 — `grpc-message` 未 percent-encode/decode

- 状态：已确认；gRPC Status-Message wire grammar 与确定性 server/client header path 推导。本阶段只做静态 review，不新增错误字符串触发。
- 规范：grpc-message 在语义上是 Unicode description，wire 上必须先编码为 UTF-8，再按 gRPC 的允许字节集合进行 percent-encoding（`%` 本身必须编码）。client应解码合法 `%HH`；遇到非法编码不得抛错或丢弃整个 message，可以保留原文或部分解码。
- 位置：unknown method message 在 `lualib/silly/net/grpc/server.lua:8-20`；应用/异常 error trailers 在 `lualib/silly/net/grpc/registrar.lua:80-228`；client message 读取在 `lualib/silly/net/grpc/client/service.lua:38-53,164-173`。
- 触发：unknown method path或业务/pcall error包含 `%`、Unicode、控制字符、换行；或独立 server 返回 percent-encoded message，例如 `permission%20denied`，包括 Trailers-Only response。
- 影响：Silly server 生成不符合 gRPC message grammar 的字段；多行异常还会利用 HTTP/2 sender校验缺口直接生成非法 field-value，严格 peer可能 reset stream/connection。Silly client则把 percent文本原样暴露给应用，且 unary Trailers-Only即使读到 status也丢失位于 initial header的 message，导致错误信息损坏或缺失。
- 证据：所有 server分支直接把 Lua error/path字符串赋给 `['grpc-message']`，仓库无 percent encoder；所有 client分支直接取 map value，仓库无 percent decoder。unary的 status使用 `trailer[...] or header[...]`，但 message只读取 `trailer['grpc-message']`，Trailers-Only message不会回退到 header。
- 根因：status message 被当作普通 header string，未实现 gRPC 独立于 URI/form encoding的 wire codec；终局 field-section选择同样未集中。
- 建议解法：实现共享的 gRPC percent encoder/decoder：server验证/编码 UTF-8 bytes并至少转义 `%`、控制及非允许字节；client容错解码有效 `%HH`且保留非法片段。message与status必须从同一个最终 field section读取，避免混配。
- 后续回归条件：修复阶段覆盖空格、`%`、ASCII边界、中文/emoji、CR/LF/NUL、合法大小写 hex、孤立/短/非 hex `%`，以及普通 trailer/Trailers-Only；严格 peer接受 server输出，client不因坏编码抛错。本轮不新增测试代码。

### GRPC-012 — P1 — deadline 不覆盖建连，streaming timeout 无效且 server 不执行

- 状态：已确认；公开 API 文档、gRPC timeout grammar/deadline 行为与确定性 timer/header/handler 路径推导。本阶段只做静态 review，不新增慢调用测试。
- 规范：未配置 deadline 时无限等待是允许的；但应用显式设置后，client应在期限到达时以 DEADLINE_EXCEEDED结束 call，server应收到剩余 timeout并在到期时取消 call。wire 上用最多 8 位正整数加单位的 `grpc-timeout` 表达。Silly 文档也承诺 unary/stream method timeout及 `stream:read([timeout])`。
- 位置：target解析与lazy channel建立在 `lualib/silly/net/grpc/client/conn.lua:49-79,127-155`；timer及四种 client constructor在 `lualib/silly/net/grpc/client/service.lua:12-32,134-257`；server没有 deadline逻辑，见 `lualib/silly/net/grpc/server.lua` 与 `registrar.lua`；承诺的 API在 `docs/src/en/reference/net/grpc.md:343-397,521-530,1426-1455`。
- 触发：首次unary call带timeout但TCP/TLS/H2 handshake保持silent；为server-streaming call传timeout后在已返回stream上等待慢响应；为client/bidi streaming method或其`stream:read(timeout)`设置timeout；或让unary server handler在client本地timeout/RST后继续执行。
- 影响：显式unary timeout也无法约束连接建立，可能尚未发出RPC就无限等待；streaming call可越过调用方期限持续占用资源。server不知道deadline且handler没有cancellation context，会在client已经DEADLINE_EXCEEDED后继续产生副作用；跨服务调用无法扣除已耗时并传播剩余期限。
- 证据：`conn.new`在service/call存在前同步DNS；每次首次channel的`openstream`可等待TCP、TLS与H2 handshake。unary先执行`self._conn:openstream()`，成功返回后才`time.after(timeout,...)`，因此timer不覆盖dial。随后它只覆盖readbody/readall且从不把timeout加入request headers。server-streaming同样在openstream后建timer，并在返回stream对象前删除/cancel，后续read不受保护。client/bidi constructors不接受timeout；所有`stream_read`只调用无timeout的`readbody`。server从未读取`grpc-timeout`，wrapper也不向handler暴露deadline/cancel状态。
- 根因：timeout作为围绕同步 unary调用的临时 coroutine timer实现，没有成为 call state；stream对象、wire metadata与server context之间没有deadline所有权。
- 建议解法：在call入口、任何openstream/dial之前计算统一absolute deadline并创建call context，把剩余预算贯穿resolver、所有地址尝试、TCP、TLS、H2 handshake、写入与最终status；首次HEADERS发送前编码canonical grpc-timeout，streaming对象持有/cancel同一timer。server严格解析timeout、计算本地deadline、到期取消stream并向handler暴露可查询cancellation；下游传播时扣除elapsed time。另提供独立default dial timeout，但总call deadline始终取更早者。
- 后续回归条件：修复阶段覆盖所有四种RPC、header各单位/8位边界/非法值、deadline在DNS/TCP/TLS/H2 handshake/写/首响应/中途消息/最终trailer前到期，以及client cancel后server停止工作；断言同一absolute预算不按阶段重置，文档示例与实际签名一致。本轮不新增测试代码。

### GRPC-013 — P1 — RST_STREAM 与连接失败不映射为标准 gRPC status

- 状态：已确认；gRPC HTTP/2 transport mapping 与确定性 error-information loss/client finalizer 路径推导。本阶段只做静态 review，不新增故障注入。
- 规范：收到 RST_STREAM 时 runtime必须立即结束 RPC并按 HTTP/2 code映射：NO_ERROR及大多数 protocol errors→INTERNAL，REFUSED_STREAM→UNAVAILABLE，server发送 CANCEL→CANCELLED，ENHANCE_YOUR_CALM→RESOURCE_EXHAUSTED，INADEQUATE_SECURITY→PERMISSION_DENIED；可检测连接失败时 client outstanding calls应为 UNAVAILABLE。
- 位置：HTTP/2 error string table、RST handler与connection cleanup在 `lualib/silly/net/http/h2.lua:103-124,563-590,1333-1349,1420-1440`；gRPC finalizers在 `lualib/silly/net/grpc/client/service.lua:38-81,134-176`。
- 触发：server/proxy以任何标准 RST_STREAM code终止 call，或 TCP/TLS/HTTP2连接在 RPC未收到 final grpc-status前断开。
- 影响：client把可重试的 REFUSED_STREAM/连接失败丢成 UNKNOWN或 raw `"Stream not processed"`/`"Channel goaway"`，把明确 CANCELLED、RESOURCE_EXHAUSTED、PERMISSION_DENIED也丢失。上层无法安全区分 retry、取消、容量和安全错误，行为与其他 gRPC实现不一致。
- 证据：H2 `frame_rst` 在 unpack error code后立即通过 `err_str[...]`降成普通字符串交给 stream；connection cleanup同样只写固定字符串，数值 code/原因不可再取。gRPC `check_trailer`在缺 status时固定 UNKNOWN，unary只返回该字符串；仓库没有 transport→gRPC mapping table。
- 根因：HTTP/2 API只暴露人类可读 error text，过早丢弃机器可判定的 transport error类型；gRPC层因此无法实现协议要求的单向映射。
- 建议解法：让 H2 stream终局错误携带结构化 kind/code/retry boundary；gRPC统一 finalizer在缺显式 grpc-status时按官方表映射。连接失败和GOAWAY Last-Stream-ID还应标识 call是否可能未被处理，不能仅靠字符串猜测或无条件重放。
- 后续回归条件：修复阶段逐个注入全部标准 RST code、未知 code、TCP EOF/TLS error/GOAWAY，断言映射、retryable信息及四种 RPC一致；已有显式 grpc-status时不得被 transport fallback覆盖。本轮不新增测试代码。

### GRPC-014 — P1 — 无 package 的 protobuf service 生成错误 method path

- 状态：已确认；gRPC for Protobuf service-name mapping、protoc默认值与确定性 string conversion 推导。本阶段只做静态 review，不新增 proto。
- 规范：protobuf method path 是 `/(package ".")?Service/Method`；package segment及其点只在 proto实际声明 package时出现。无 package的合法 service必须使用 `/Service/Method`。
- 位置：client lazy method path在 `lualib/silly/net/grpc/client/service.lua:259-279`；server registrar path在 `lualib/silly/net/grpc/registrar.lua:264-290`；parser只在遇到 package声明时设置字段，见 `lualib/protoc.lua:498-505,827`；本项目 Lua `%s`转换在 `deps/lua/lstrlib.c:1353-1368`。
- 触发：加载不含 `package ...;` 的合法 proto3/proto2 service，向独立 gRPC实现调用或让独立 client调用 Silly server。
- 影响：Silly client请求不存在的 `/nil.Service/Method`，独立 server返回 UNIMPLEMENTED；Silly server只注册同一错误路径，独立 client的规范 `/Service/Method`找不到。只有两端都使用Silly时错误路径恰好自洽，掩盖互操作失败。
- 证据：parser创建 file info时没有默认 package，缺声明即 `proto.package=nil`。两端无条件执行 `format("/%s.%s/%s", package, ...)`；内置 Lua `%s`使用 `luaL_tolstring`，nil成为字面量 `"nil"`，最终 wire/registration path为 `/nil.Service/Method`。
- 根因：path builder假定所有 proto都有非空 package，并在 client/server各复制一次同样逻辑。
- 建议解法：集中构造 fully-qualified service name：package非空时 `package .. "." .. service`，否则仅 service；method segment按 descriptor原名追加。注册与调用复用同一 helper，但仍必须以独立peer测试，避免镜像bug再次互相掩盖。
- 后续回归条件：修复阶段覆盖无 package、单段/多段 package、service/method大小写，并分别做 Silly↔独立 client/server双向调用；捕获 `:path`精确等于规范值。本轮不新增测试代码。

### GRPC-015 — P1 — client response parse error 可被 peer 的 OK status 覆盖

- 状态：已确认；gRPC runtime status mapping与确定性 decoder/finalizer dataflow推导。本阶段只做静态 review，不新增畸形 response。
- 规范：response protobuf解析失败应由 client runtime产生 INTERNAL；截断或损坏的 length-prefixed message同样不能因 peer随后宣称 grpc-status OK而成为成功。runtime已观察到的本地解析错误必须优先于不可信 peer的 OK trailer。
- 位置：envelope/protobuf decoder在 `lualib/silly/net/grpc/helper.lua:16-50`；streaming read/finalizer在 `lualib/silly/net/grpc/client/service.lua:38-81`；unary在 `:134-176`。
- 触发：server发送完整envelope但known-field payload具有wire-type mismatch/坏value而使native protobuf decoder抛错，或5-byte header/payload在END_STREAM前截断，然后发送/已发送`grpc-status: 0`。decoder静默接受部分非法尾部的路径另见`GRPC-025`。
- 影响：截断envelope会让server-streaming、client-streaming和bidi对象最终记录`status=OK`，调用方把损坏响应当正常结束；protobuf decode exception则直接从公开`stream:read()`或unary调用抛出，绕过文档化的`nil,error/status`契约。若调用方捕获后再次read，已消费的坏envelope不再可见，下一次EOF仍可由peer OK trailer把stream标为成功。数据损坏、版本不匹配与恶意peer行为无法按标准code稳定监控/处置。
- 证据：native decoder对known-field type/varint/length错误调用`luaL_error`，因此helper的`if not resp then "Decode error"`不是保护边界。unary只有H2 stream的`<close>`资源收尾，没有protected decode/status转换；streaming read也不pcall。对readbody实际返回的EOF/transport错误，`check_trailer`只要看到grpc-status就仍无条件以该数值覆盖local err；unary在n==OK时也直接`return resp,err`而不构造INTERNAL。
- 根因：finalizer把peer status当成唯一权威，没有维护不可被成功status覆盖的local runtime error；API又没有统一的结构化status对象。
- 建议解法：call state保存首个本地 protocol/decode/runtime failure；最终peer non-OK可提供额外上下文，但peer OK不得覆盖本地失败。invalid response proto统一映射INTERNAL，截断按transport/protocol性质映射，并让四种API返回同一status模型。
- 后续回归条件：修复阶段覆盖known-field invalid protobuf、0..4-byte header、短payload、第二条streaming message损坏，分别配OK/non-OK/missing status，并验证捕获异常后重复read；公开API不得抛native parse exception，本地损坏永不产生OK且invalid proto稳定为INTERNAL。本轮不新增测试代码。

### GRPC-016 — P2 — application handler 异常被错误映射为 INTERNAL

- 状态：已确认；gRPC library-generated status mapping与确定性 `pcall` error branches推导。本阶段只做静态 review，不新增抛错 handler。
- 规范：gRPC status code guide明确把“server side application throws an exception，或以未返回 Status的方式终止RPC”映射为 UNKNOWN；INTERNAL用于runtime自身不变量破坏、protobuf解析/解压等内部错误。框架必须区分应用异常与runtime protocol failure。
- 位置：unary、server-streaming、client-streaming、bidi四个 `pcall` failure branch在 `lualib/silly/net/grpc/registrar.lua:80-228`。
- 触发：任一注册的业务 handler直接 `error(...)`，或执行中产生未捕获Lua异常。
- 影响：client收到 INTERNAL而非UNKNOWN，监控与告警会把应用代码异常误归因于gRPC runtime/协议内部故障；依赖status分类的故障处置、SLO统计与调试方向错误。
- 证据：四个wrapper都以`local ok,...=pcall(fn,...)`调用handler，`if not ok`分支完全相同地写`['grpc-status']=code.INTERNAL`。没有异常类别判断，也没有UNKNOWN分支；这与同文件code table中UNKNOWN的定义及官方runtime mapping相反。
- 根因：实现把“未捕获异常”按一般编程语言术语视为internal error，没有采用gRPC对application space与library space的特定划分。
- 建议解法：普通application exception统一返回UNKNOWN并用安全编码的message/日志保留诊断；只有wrapper/decoder/transport自身的invariant failure使用INTERNAL。若要让应用选择其他code，必须通过校验后的显式status返回对象，而不是抛异常。
- 后续回归条件：修复阶段让四种handler分别抛string/table error，断言wire status均UNKNOWN且message codec合法；另用protobuf parse/runtime invariant测试确认仍为INTERNAL。本轮不新增测试代码。

### GRPC-017 — P2 — server 原样发送未校验的 application status code

- 状态：已确认；gRPC canonical Status wire grammar、应用status集合与确定性 Lua→HPACK转换路径推导。本阶段只做静态 review，不新增恶意handler。
- 规范：sender必须把grpc-status编码为无前导零的十进制整数文本；应用只应使用gRPC定义的status values。框架收到非法显式status时应拒绝或安全转换为UNKNOWN，且“返回error”不能同时以OK终止。
- 位置：四种application error branch在 `lualib/silly/net/grpc/registrar.lua:80-228`；最终通用字符串化在 `luaclib-src/lhttp.c:489-548`。
- 触发：handler返回`nil,{code=-1}`、float、`"00"`、`"0x0"`、table/boolean或`code.OK`等；Lua是动态语言，现有API只用注解声明integer且运行时不执行约束。
- 影响：Silly server可生成语法非法的grpc-status，独立client应把它映射UNKNOWN；部分宽松client又可能像Silly一样把某些形式解释成其他code或OK。有error+OK时业务失败被wire声明成功，造成跨实现语义分裂。
- 证据：所有branch使用`err.code or code.UNKNOWN`，Lua中负数、0、字符串、float、table都可到达（0也truthy）。没有`type`、integer、range或OK-with-error检查；HPACK encoder对任何值使用`luaL_tolstring`，所以非法对象不会被拒绝而是转成wire文本。
- 根因：把application error table当作已验证的wire representation，且底层通用header sender采取宽松字符串化。
- 建议解法：在gRPC层构造不可伪造/集中校验的Status：code必须为定义的integer non-OK值（success走独立分支），否则转UNKNOWN并记录server-side诊断；wire encoder只从validated integer生成canonical decimal，拒绝字符串/其他类型。
- 后续回归条件：修复阶段覆盖所有定义code、0 error、负数、17+、float、numeric/non-numeric string、boolean/table/nil，断言wire永远canonical且error绝不变OK；独立client得到一致status。本轮不新增测试代码。

### GRPC-018 — P2 — 零消息 streaming request 用 HEADERS 而非空 DATA 表示 EOS

- 状态：已确认；gRPC request EOS mapping与确定性 pending-header/closewrite路径推导。本阶段只做静态 review，不新增抓包。
- 规范：gRPC request side的EOS由最后一个DATA frame上的END_STREAM表示；当需要关闭request stream且没有data可发送时，implementation仍必须发送一个空DATA frame并设置END_STREAM。不能只在initial request HEADERS上结束。
- 位置：client/bidi stream构造与closewrite在 `lualib/silly/net/grpc/client/service.lua:65-70,215-257`；HTTP/2 pending header收尾在 `lualib/silly/net/http/h2.lua:992-1025`。
- 触发：创建client-streaming或bidi call后不调用`stream:write`，直接调用`stream:closewrite()`，即合法的零request-message streaming call。
- 影响：wire sequence不符合gRPC transport mapping；严格实现、proxy或协议一致性测试可拒绝/误分类该call。Silly server基于通用HTTP/2 END_STREAM仍会接受，所以同库测试（且现有测试总先写消息）掩盖偏离。
- 证据：constructor只调用`h2stream:request`设置`writeheader`，不立即flush。零消息closewrite进入S.closewrite时`header`存在且`nopayload=true`，函数调用`stream_writeheader(..., true)`后直接return；只有header已flush的路径才把nil data改为空string并通过`stream_writewait(..., true)`生成空DATA。
- 根因：gRPC层直接复用通用HTTP/2 closewrite最短收尾优化，没有表达gRPC对request EOS frame type的额外约束。
- 建议解法：streaming call建立时先发送不带END_STREAM的request HEADERS，或提供gRPC-specific close-request API，确保即使零messages也发送empty DATA+END_STREAM；不要改变普通HTTP/2 API对HEADERS END_STREAM的合法优化。
- 后续回归条件：修复阶段抓取client-stream/bidi的0/1/N消息frame序列：initial HEADERS永不END_STREAM，最后必为DATA+END_STREAM（零消息时length 0）；独立server正常完成零消息call。本轮不新增测试代码。

### GRPC-019 — P2 — plaintext server 把应用 stream 的 scheme 错标为 `https`

- 状态：已确认；listener transport 分支、H2 channel 初始化与 stream 字段传播的确定性静态核对。本轮不启动明文 server。
- 位置：gRPC 明文/TLS 分支在 `lualib/silly/net/grpc/server.lua:38-55`；H2 server 固定 scheme 在 `lualib/silly/net/http/h2.lua:1730-1739`，channel 与 stream 传播在 `:231-262,456-467`；公开的可选 `tls` 配置见 `docs/src/en/reference/net/grpc.md:146-190` 和中文同名文档。
- 触发：使用默认或显式 `tls=false` 的 `grpc.listen` 接收正常 cleartext HTTP/2 gRPC request；本库 plaintext client会正确发送 `:scheme: http`。
- 影响：业务 handler/middleware 观察到 `stream.scheme == "https"`，可把未经TLS保护的请求误判为安全连接，进而生成错误的 `https://` absolute URL、设置仅安全通道应有的属性，或绕过依赖 transport scheme 的重定向/鉴权策略。同时 header 中 peer 提供的 `:scheme` 仍是 `http`，一个 stream 内出现两个互相矛盾的 scheme 来源。
- 证据：`grpc.listen` 在 `not conf.tls` 时明确调用 `tcp.listen`，但 TCP/TLS 两条 accept path 都无参数调用 `h2.httpd(handler, conn)`。`h2.httpd` 无条件执行 `newchannel("https", conn, "")`，`channel_newstream` 再赋值 `scheme = ch.scheme`。相反，plaintext client 以 `opts.tls and "https" or "http"` 建 channel 并由 H2 sender生成对应 `:scheme`，所以默认 client/server组合即可确定产生 `header[":scheme"]="http"` 与 `stream.scheme="https"` 的矛盾。
- 根因：H2 server helper 假定所有调用都来自 TLS ALPN，没有从 listener transport 接收 scheme；gRPC 又复用了它来承载 prior-knowledge cleartext HTTP/2。
- 建议解法：让 `h2.httpd(handler, conn, scheme)` 显式接收由 listener 确定的 transport scheme，gRPC plaintext传 `http`、TLS传 `https`；避免信任 peer `:scheme` 来推断实际安全属性。通用 HTTP listener的H2 TLS分支也应显式传值，去掉 helper 内硬编码。
- 后续回归条件：修复阶段分别建立明文与TLS listener，向两者发送匹配的 `:scheme`，断言handler看到的transport scheme为 `http`/`https` 且与连接类型一致；另覆盖peer伪造相反`:scheme`时的validation/应用可见值，不允许伪造字段提升安全属性。当前不启动server或发送请求。

### GRPC-020 — P2 — client target 固定单次 A lookup，缺少 IPv6 与同名多地址回退

- 状态：已确认；gRPC client 自有 target resolver/channel dial 路径与 DNS API 的确定性静态核对。本轮不执行 DNS 或连接。
- 位置：target parse、DNS 与 endpoint 固化在 `lualib/silly/net/grpc/client/conn.lua:16-29,127-155`，单 endpoint dial在 `:49-79`；`dns.lookup` 只返回首项、`resolve` 可返回集合，见 `lualib/silly/net/dns.lua:588-654`。
- 触发：`dns:///host:port` 或 passthrough hostname 只有 AAAA，或同名有多个 A/AAAA 而首个 IPv4 地址不可达、其余候选健康；直接 IPv4/IPv6 literal 是单候选，不受 hostname 查询分支影响。
- 影响：IPv6-only gRPC 服务完全无法创建 client；多地址服务遇单机故障、滚动迁移或 DNS 负载均衡时，没有在任何 RPC bytes 发出前尝试安全的备用地址。endpoint 一经构造只保存首个解析 IP，后续 channel 重连仍持续拨同一地址，局部故障可长期表现为整个 target 不可用。
- 证据：`conn.new` 对每个 target 固定调用一次 `dns.lookup(host, dns.A)`，随后只保存一个 `addr = join_addr(ip, port)`，丢弃 hostname 的地址集合。`newchannel` 对选中 endpoint 只执行一次 `tcp.connect` 或 `tls.connect`，失败立即返回；没有 AAAA、`dns.resolve`、候选列表、family排序/错峰或逐候选拨号。TLS hostname另存用于SNI，但不改变地址选择。
- 根因：target resolver 把 hostname 映射为构造时冻结的单个 IPv4 socket address，而不是可刷新、可返回多个地址的 gRPC resolver result；channel dialer也只接受单 endpoint。
- 建议解法：使用与 HTTP/WS/cluster 共用的双栈 resolver+dialer，保留 logical authority/hostname与地址候选集合；按 RFC 8305错峰或至少顺序尝试所有候选，并以同一 absolute dial deadline限制。TLS SNI/证书验证继续使用原hostname，不能被候选IP替换；连接成功后记录chosen address但不得永久丢弃其他候选。
- 后续回归条件：修复阶段注入AAAA-only、A-only、双栈/多A首地址失败后成功、全部失败、慢首/快次和IPv4/IPv6 literal；断言fallback发生在发送RPC前、候选共享deadline、输家关闭且authority/SNI保持logical target。当前不解析或连接外部endpoint。

### GRPC-021 — P1 — `close()` 可与在途建连交错并在返回后复活 orphan channel

- 状态：已确认；endpoint mutex、连接发布和 close 顺序的确定性静态时序。按用户要求不新增并发 barrier 或运行连接复现。
- 位置：`lualib/silly/net/grpc/client/conn.lua:44-117`，尤其 `newchannel` 的 endpoint lock/发布在 `:49-79`、`openstream` 的 closed check在 `:84-100`、未取锁的 `close` 在 `:104-117`。
- 触发时序：task A 的 `openstream` 读到 `closed=false`，进入 `newchannel` 并在 TCP/TLS/H2 handshake yield；task B 调用 `conn:close()`，设 `closed=true`、把所有 `self[k]` 置 nil，但此刻该 endpoint 尚无已发布 channel，随后 close 返回；task A 恢复后执行 `endpoint.channel=ch` 并返回 `ch:openstream()`。
- 影响：调用方已观察到 close 完成后仍可获得并使用新 stream/RPC；新 channel 挂在已从 conn 数组摘除、仅由在途局部变量持有的 endpoint 上，后续 `conn:close()` 因 closed 标志直接返回，无法再遍历并关闭它。由此造成底层连接/dispatch task 生命周期泄漏，也破坏 shutdown 后不再接收新工作这一基本资源所有权边界。
- 证据：`newchannel` 只用全局 `connlock:lock(endpoint)` 串行同 endpoint 的建连，但 `conn.close` 完全不获取这些锁，也没有 generation/cancel token。`openstream` 只在进入时检查一次 `self.closed`，从 yield 恢复后没有二次检查；`newchannel` 发布前同样不检查 owner 是否关闭。close 还先删除 `self[k]`，所以迟到发布的 endpoint 不再能从 owner 找回。
- 根因：pool close与endpoint connection publication没有共同的事务边界；boolean closed只保护新入口，没有使已开始的异步dial失效。
- 建议解法：为 conn 引入 generation/cancellation context，并让 endpoint 建连的提交阶段在同一锁下核对 owner仍开放且generation未变；close先标记closed/递增generation并取消在途dial，再按endpoint lock收集和关闭所有已发布/刚完成channel。迟到成功必须由建连task自己关闭，绝不发布或返回stream。
- 后续回归条件：修复阶段用可控 connector 在 TCP、TLS、H2 handshake和发布前分别暂停，与 close 交错；断言close返回后所有openstream均失败、迟到socket/channel关闭、endpoint不可重新发布且无dispatch task遗留。另覆盖多个caller共享一次dial与重复close。当前仅记录静态时序。

### GRPC-022 — P2 — TLS client/server 不验证 ALPN 最终选择为 `h2`

- 状态：已确认；gRPC TLS accept/dial、TLS握手结果与HTTP/2入口的确定性静态核对。本轮不建立TLS会话。
- 规范：gRPC over TLS 的HTTP/2连接通过ALPN协商 `h2`；没有协商出 `h2` 时不能假定对端使用HTTP/2并继续发送client preface或把收到字节交给H2 parser。仅在ClientHello/ServerHello配置协议列表不等于已验证negotiated protocol。
- 位置：client dial在 `lualib/silly/net/grpc/client/conn.lua:49-79`，server accept在 `lualib/silly/net/grpc/server.lua:38-55`；TLS层保存/暴露选择结果在 `lualib/silly/net/tls.lua:198-204,250-258,464-466`；正确读取ALPN后分流的HTTP client对照在 `lualib/silly/net/http/client.lua:243-279`。
- 触发：TLS gRPC client连接到不支持ALPN、忽略client ALPN或没有选择`h2`的server；或gRPC TLS listener被不发送ALPN/未协商`h2`的client连接。TLS本身仍可能成功。
- 影响：client在未确认协议后立即发送HTTP/2 connection preface，server则立即等待同一preface/SETTINGS；legacy或配置错误peer看到意外明文协议字节，Silly侧可能长时间等待、产生模糊handshake错误或把其他应用协议字节作为H2处理。严格gRPC互操作要求的TLS协议选择边界没有执行，诊断也无法明确指出ALPN mismatch。
- 证据：两端都把 `ALPN_PROTOS={"h2"}` 传给TLS，但成功返回后从不调用现有 `conn:alpnproto()`。client无条件 `h2.newchannel(scheme, conn)`，server两种transport的共用accept无条件 `h2.httpd(handler, conn)`。TLS握手代码会把协商结果保存为 `s.alpn` 并公开getter；HTTP client正是用该getter只有在等于`h2`时进入H2，否则选择H1，说明gRPC遗漏的是调用层校验。
- 根因：把“本端只advertise h2”误当成“握手一定select h2”，没有在TLS transport与H2状态机之间建立显式admission check。
- 建议解法：TLS client成功后要求 `conn:alpnproto()=="h2"`，否则立即关闭并返回结构化ALPN错误；TLS server accept同样在调用H2前检查并关闭未协商h2的连接。明文prior-knowledge路径不做ALPN检查。将检查封装为gRPC TLS transport helper，避免client/server再次分叉。
- 后续回归条件：修复阶段覆盖协商h2、无ALPN、server不选择、选择非h2和TLS握手失败；client/server两侧均断言只有h2进入H2 parser，其他情况立即关闭且无channel/stream/task残留。当前不运行TLS互操作。

### GRPC-023 — P2 — `grpc.listen` 静默丢弃公开的 `ciphers`、`backlog` 与 `alpnprotos` 配置

- 状态：已确认；gRPC listen adapter、TCP/TLS listener options与中英文公开配置表的确定性静态核对。本轮不创建listener或TLS context。
- 位置：gRPC server配置注解与下传在 `lualib/silly/net/grpc/server.lua:29-55`；TLS消费 `ciphers/backlog` 在 `lualib/silly/net/tls.lua:326-365`，TCP消费backlog在 `lualib/silly/net/tcp.lua:152-175`；公开配置见 `docs/src/en/reference/net/grpc.md:146-166` 与中文同名文档。
- 触发：为明文或TLS gRPC listener设置 `backlog`；或TLS listener设置显式 `ciphers` 安全策略/`alpnprotos`列表。调用成功且没有unknown-option警告。
- 影响：实际listen queue仍使用底层默认值，容量/突发连接行为与部署配置不符。更重要的是，自定义cipher policy从未进入TLS context，安全管理员可能依据一个静默无效的设置错误判断已禁用某些套件或满足组织基线；`alpnprotos`也无论传什么都固定成`{"h2"}`，公开配置与实际握手不一致。问题不会从成功返回值或日志中显现；gRPC正确设计应直接不公开ALPN override，而非接受后忽略。
- 证据：`server.lua` 的conf注解列出 `ciphers`，reference另列出 `backlog`，但明文调用table只有 `addr,accept`，TLS调用table只有 `addr,certs,alpnprotos,accept`。底层API明确读取 `conf.backlog` 传给 `net.tcplisten`，并由 `new_server_ctx` 读取 `conf.ciphers` 传给 `ctx.server`；adapter没有传入时它们不可能生效。reference还列出可配`alpnprotos`，实现正确地固定为h2但没有说明该字段被忽略。
- 根因：wrapper手工重建了listener option table而非受控转发支持字段；文档配置schema与server.lua注解/实际下传三者没有单一来源或unknown-option校验。
- 建议解法：显式把 `backlog` 传入两种listener、把 `ciphers` 传入TLS listener，并在入口验证TLS专用字段只用于 `tls=true`。gRPC的ALPN应固定为h2并删除公开override，而不是接受任意值；所有未知/不适用配置fail fast。最好以共享schema生成LuaLS注解与双语文档表。
- 后续回归条件：修复阶段用stub listener捕获下传table，覆盖明文/TLS的backlog、TLS ciphers、alpnprotos显式拒绝/移除、未知字段和不适用组合；TLS集成阶段再检查实际ctx cipher policy与固定h2协商。当前只做静态配置数据流核对。

### GRPC-024 — P2 — request runtime error 通过第二个 `:status` HEADERS 冒充 trailers

- 状态：已确认；gRPC response sequence、HTTP/2 trailer规则与确定性server调用链推导。本轮不发送超限或压缩消息。
- 规范：gRPC server可先发送Response-Headers，再以Trailers结束RPC；后一个field section必须包含`grpc-status`且遵守HTTP/2 trailers规则，不能再含任何pseudo-header。HTTP/2规定pseudo-header只能出现在initial field section，出现在trailer会使message malformed并作为stream error处理。
- 位置：dispatch预置initial response在`lualib/silly/net/grpc/server.lua:8-26`；request envelope reader及超限/压缩分支在`lualib/silly/net/grpc/helper.lua:16-50`；HTTP/2 read会flush pending header在`lualib/silly/net/http/h2.lua:757-799,1088-1105`；`respond`与`closewrite`对pending header的发送在`:704-738,953-960,992-1025`。
- 触发：client向任一已注册method发送声明长度大于4 MiB的request message，或发送任意非零compressed flag。两条路径都会先通过`h2stream:read(5)`，随后helper调用`h2stream:respond(200,{grpc-status=...})`表达runtime error。
- 影响：严格client会把final HEADERS中的`:status`视为malformed response并RST_STREAM，收不到预期的RESOURCE_EXHAUSTED或UNIMPLEMENTED gRPC status，最终通常退化为INTERNAL/UNKNOWN transport error。本库client因`H2-009`不验证response trailers而可能接受同一违规输出，使同库测试假绿并造成跨实现互操作分裂。
- 证据：server dispatch先调用`stream:respond(200,{content-type=application/grpc})`。无论5 bytes已在buffer还是需要等待，HTTP/2 `read`都会调用`stream_flush`，因此initial `:status=200`已确定发送。helper错误分支再次调用`respond`，而该方法不检查`s.localstate`，只重设`s.status/writeheader`；外层server wrapper随后`closewrite()`，`stream_writeheader`对server stream无条件再次编码`:status`并以END_STREAM发出。正确的final status应使用不含pseudo-header的trailer path。
- 根因：gRPC helper把“发送initial HTTP response”和“结束RPC status”混用同一个`respond` API；HTTP/2 sender又没有以local state阻止重复initial response，宽松的本库recipient进一步遮蔽错误。
- 建议解法：dispatch只发送一次Response-Headers；所有读取/解码/runtime失败都由统一gRPC finalizer生成合法trailers，并保证恰好一个canonical grpc-status。helper返回结构化错误而不直接写response；wrapper根据错误类别选择RESOURCE_EXHAUSTED、UNIMPLEMENTED或INTERNAL并调用trailer-only终止路径。H2 `respond`还应在initial header已提交后fail fast，形成纵深保护。
- 回归测试：修复阶段覆盖request length limit±1、compressed flag 1/2及支持/不支持encoding，捕获完整field-section序列；断言仅首个HEADERS含`:status`，final trailers无pseudo且含准确grpc-status。分别以本库和独立严格client验证，不以本库宽松parser通过作为充分条件。本轮不构造这些消息。

### GRPC-025 — P1 — protobuf decoder 把截断 tag/unknown field 当作正常消息结束并交给业务

- 状态：已确认；gRPC envelope、native protobuf decode循环与官方wire grammar的确定性静态核对。本轮不构造或发送畸形payload。
- 规范：[Protocol Buffers Encoding](https://protobuf.dev/programming-guides/encoding/)把message定义为完整`tag value`记录序列：tag本身是varint，且每个tag必须有其wire type规定的完整value；field number 0不合法。截断tag、缺失value或无法跳过的unknown field都不是正常message边界。gRPC收到无法解析的request/response message时也不能把它当作成功业务消息。
- 位置：gRPC在`lualib/silly/net/grpc/helper.lua:16-50`直接信任`pb.decode`结果；native map-entry循环在`luaclib-src/pb.c:1902-1924`，顶层/嵌套message循环在`:1943-1988`，varint失败回滚在`luaclib-src/pb.h:410-492`，unknown wire value跳过及失败回滚在`:533-607`。
- 触发：一个完整5-byte gRPC envelope声明的payload以未终止varint tag结尾（例如孤立continuation byte），包含field number 0，或在合法字段后追加unknown tag但省略/截断其VARINT、I32、I64或LEN value；map-entry内部的截断tag/unknown field也命中，且合法完整unknown map field的value会被错误当作下一tag。server request与client response共享同一decoder。
- 影响：decoder返回普通table，gRPC看不到任何错误。server会用缺省字段或已解析前缀调用真实handler并可能执行写入、授权或计费副作用，随后返回OK；client会把被截断的response当作可信对象。严格peer会拒绝的同一protobuf在Silly中成功，形成数据完整性、业务语义和跨实现行为分裂；`GRPC-007/015`的错误finalizer完全没有机会介入。
- 证据：`lpbD_message`以`while (pb_readvarint32(...))`驱动；0同时表示干净EOF与非法/截断varint，循环退出后无条件返回成功table，也不检查slice是否耗尽。unknown field分支调用`pb_skipvalue(s,tag)`却忽略返回值；skip失败会恢复payload pointer，若已经到envelope末尾，下一轮tag read返回0并再次被视为正常结束。`lpbD_map`复制了同样的while-success循环，且只处理field 1/2，没有else调用`pb_skipvalue`：unknown field只消费tag，value字节被下一轮解释为tag，最终仍可产出map entry。两处都不拒绝field 0。`helper.readbody`的`if not resp then "Decode error"`无法捕获这些成功返回。
- 根因：low-level reader用同一个0返回值表示clean EOF与malformed/truncated，并在message循环丢弃skip结果；API没有“成功且恰好消费完整slice”的不变量，gRPC层又只按Lua返回值真假判断。
- 建议解法：protobuf decoder显式区分EOF和parse error：只有cursor恰好位于message边界时允许结束；tag varint失败、field number 0、非法wire type、known/unknown value读取或skip失败都抛受控parse error/返回结构化failure，嵌套slice也执行同一完整消费检查。gRPC用protected decode捕获失败并经统一finalizer映射INTERNAL，绝不调用handler或接受response。
- 回归测试：修复阶段在protobuf单元层覆盖0..10字节截断tag、tag 0、每种wire type的缺失/短value、unknown field、嵌套message，以及map-entry内合法unknown field与截断tag/value；断言非法输入失败、合法unknown完整跳过且前缀不泄漏为成功对象。再对四类RPC双向覆盖第1/第N条坏message，server不调用业务且client不产生OK。本轮不运行这些输入。

### GRPC-026 — P2 — 多 target “round-robin” 不隔离坏 endpoint，单点故障会阻断建池或周期性打失败请求

- 状态：已确认；client resolver、endpoint选择、公开负载均衡承诺与官方round_robin模型的确定性静态核对。本轮不解析域名、连接endpoint或运行故障切换。
- 依据：[gRPC Custom Load Balancing Policies](https://grpc.io/docs/guides/custom-load-balancing/)说明round_robin会连接resolver给出的每个地址，并在已连接backends间轮转；picker管理subchannel状态，而不是每次机械选择一个可能未连接的地址并把该次dial失败直接交给应用。Silly双语reference也明确承诺多个target使用round-robin。
- 位置：构造时逐target DNS与全有或全无返回在`lualib/silly/net/grpc/client/conn.lua:127-155`；每次RPC先推进robin、只拨单一endpoint并立即返回失败在`:49-100`；文档承诺位于`docs/src/{en/,}reference/net/grpc.md:266-278,786-868,1499-1537`。
- 触发：配置至少两个target，其中任一hostname当前DNS失败；或所有target可解析，但轮到的endpoint TCP/TLS/H2建连失败而其他target健康。无需所有后端故障。
- 影响：第一种情况让`grpc.newclient`整体返回nil，健康target完全不可用；第二种情况下每逢robin选择坏endpoint，该RPC直接失败，下一健康endpoint从未作为本次安全建连fallback。一个坏实例因此把本应容错的pool变成固定比例失败发生器；滚动发布、扩缩容、局部DNS/网络故障会直接暴露给业务，且文档示例会误导部署者认为已有可用性负载均衡。
- 证据：constructor在for循环内调用`dns.lookup`，任一nil立即return并丢弃此前已解析endpoint。`openstream`把robin推进后只取`self[robin]`；`newchannel`仅拨该endpoint，任何connect/newchannel错误原样返回，既不扫描其他endpoint也不维护READY/TRANSIENT_FAILURE状态。只有下一次独立调用才选下标+1。现有`testgrpc.lua`只配置单target，并单测“唯一target DNS失败则构造失败”，没有一坏一好或恢复场景。
- 根因：targets被建模为同步、全量成功的数组和无状态下标，而不是各自拥有解析/连接状态的subchannel集合；picker与dialer耦合，无法只在ready集合中轮询或在共同deadline内尝试其他候选。
- 建议解法：构造client时只校验target语法并建立独立resolver/subchannel状态，不因单target暂时解析失败丢弃健康成员；后台或按需解析/连接每个subchannel，round_robin picker只选READY channels。无READY时按明确fail-fast/wait-for-ready与absolute call deadline策略等待或返回聚合错误；一次call是否重选尚未发送bytes的备用endpoint也必须区分于已发送后的RPC retry，避免重复副作用。与`GRPC-020`共享双栈resolver结果，但保持target级与address级两层故障隔离。
- 回归测试：修复阶段用可控resolver/connector覆盖`bad DNS + healthy`、`refused + healthy`、TLS/H2失败+healthy、全部失败、故障恢复、两健康轮询及close交错；断言单坏target不阻断建池、不接收新RPC，恢复后重新进入轮询，所有等待受同一deadline约束且未自动重放已发送的非幂等RPC。本轮不执行这些场景。

### GRPC-027 — P1 — protobuf 嵌套 message 收发均无递归深度限制，可耗尽 C stack

- 状态：已确认；gRPC消息预算、native protobuf递归调用和官方parser安全边界的确定性静态核对。本轮不生成深层schema/payload或触发stack exhaustion。
- 依据：[Protocol Buffers C++ CodedInputStream Recursion Limit](https://protobuf.dev/reference/cpp/api-docs/google.protobuf.io.coded_stream/)明确说明解析embedded messages/groups必须跟踪递归深度，以防损坏或恶意message造成stack overflow，官方默认上限为100。总字节上限不能替代结构深度上限。
- 位置：gRPC server仅有4 MiB frame length上限、client无响应上限，见`lualib/silly/net/grpc/helper.lua:6-50`；encode message递归在`luaclib-src/pb.c:1595-1660,1737-1777`，decode递归在`:1853-1876,1943-1988`，环境只保存Lua state/buffer/slice且没有depth字段，见`:1588-1593`。
- 触发：合法service schema含递归message，例如`Node { Node child = 1; }`，peer发送许多层紧凑LEN子消息；也可通过静态但很深的嵌套type链。server request只需总payload不超过4 MiB，恶意server response连该限制也没有。反向sender给同一递归schema传入深层或自引用Lua table时，client request及server response encode也会无限递归。
- 影响：每个embedded message都增加真实native C调用栈帧，远早于4 MiB预算即可达到数千层并耗尽线程stack，导致stack overflow、进程崩溃或不可预测内存破坏。server decode路径可由未认证远端请求触发并终止承载所有连接的进程；client连接不可信/受劫持peer时同样可崩溃。encode路径使业务返回值或本地请求对象也能崩溃进程，并会越过`GRPC-032`所需finalizer。`luaL_checkstack`只保证Lua value stack有空间，不能给C call stack建立安全上限。
- 证据：decoder的`lpbD_rawfield`遇`PB_Tmessage`后建立subslice并直接调用`lpbD_message`，后者可再次走同一路径；encoder的`lpbE_field`也直接调用`lpbE_encode`，自引用table不会被检测。`lpb_Env`没有depth/budget，两条递归入口唯一相关检查都是`luaL_checkstack(L,5,...)`。没有默认100、可配置limit、cycle detection或到达阈值后的受控error。gRPC只在读取server request envelope时检查flat byte length，且4 MiB足以编码远超常见C stack承受范围的嵌套LEN记录。
- 根因：binding把Lua栈容量检查误当成结构递归保护，protobuf encoder/decoder和gRPC call配置之间没有共享复杂度预算。
- 建议解法：在每次encode/decode进入embedded message/group前以codec context递增depth，超过安全默认值（可参考100）即返回受控error，并用finally式路径保证所有退出递减；encode另检测当前递归路径上的table identity以拒绝cycle。limit必须非负、可配置且同时应用顶层/嵌套/map/group与hooks。gRPC decode失败映射INTERNAL且不调用业务，encode错误按`GRPC-032`完整收尾；同时按`GRPC-005`补client大小预算，但不要用size代替depth。
- 回归测试：修复阶段以生成式builder覆盖limit-1/limit/limit+1、递归message、静态嵌套、自引用table、repeated/map/group及hook抛错，断言收发边界稳定、depth不串到下一call且无C stack增长失控；四类RPC双向确认超限只终止当前call并返回非OK。ASan/UBSan和小stack线程下验证，当前不执行。

### GRPC-028 — P2 — protobuf `string` 与 `bytes` 共用裸字节路径，收发均不验证 UTF-8

- 状态：已确认；protobuf field type、native scalar codec与gRPC双向调用链的确定性静态核对。本轮不编码或发送非法UTF-8。
- 规范：[Protocol Buffers Encoding](https://protobuf.dev/programming-guides/encoding/)的wire reference明确`string`必须是有效UTF-8，而`bytes`才允许任意8-bit序列。parser/serializer不能把两种schema类型无差别当作裸字节，否则同一descriptor在不同实现间具有不同接受域。
- 位置：native encoder把`PB_Tbytes/PB_Tstring`合并在`luaclib-src/pb.c:406-483`，decoder再把`PB_Tbytes/PB_Tstring/PB_Tmessage`合并push为Lua string在`:486-533`；gRPC统一调用入口在`lualib/silly/net/grpc/helper.lua:16-68`。
- 触发：peer在任一protobuf `string` field的LEN payload中放入非法UTF-8字节序列；反向上，Silly handler或client request table把任意Lua byte string赋给schema的`string`字段。`bytes`字段是合法任意数据，不应受影响。
- 影响：server把其他规范实现应拒绝的message交给业务并可回OK，client接受非法response；Silly sender也能主动产生严格peer拒绝的protobuf，造成跨语言gRPC互操作失败。业务若把schema `string`直接交给Unicode normalization、JSON、日志、数据库或UI，非法序列还会触发替换、截断或不同层解释分裂，破坏校验和审计一致性。
- 证据：encode的两个case都只执行`lpb_toslice`和`pb_addbytes`，decode的三个case只读LEN slice并`lua_pushlstring`，没有UTF-8 DFA、过长编码/surrogate/range检查或按`type_id`分支。`pb_Field`保留`type_id`，因此并非缺少schema信息，而是明确合并路径。`testgrpc.lua`消息只使用ASCII文本，未覆盖多字节合法边界或非法序列。
- 根因：Lua字符串可承载任意bytes，binding把宿主表示相同误当成protobuf wire语义相同，没有在schema边界执行`string`不变量。
- 建议解法：仅对`PB_Tstring`在encode和decode时执行完整、无替换的UTF-8 validation；非法入站由protected decoder返回parse failure并映射INTERNAL，非法本地对象在写任何gRPC bytes前返回受控encode error。`PB_Tbytes`保持透明；嵌套/repeated/map string key/value使用相同validator，并提供明确的错误field path。
- 回归测试：修复阶段覆盖ASCII、1–4字节合法码点、NUL、截断序列、孤立continuation、overlong、surrogate与大于U+10FFFF，分别用于普通/repeated/map/nested string以及bytes对照；四类RPC双向断言非法string不调用业务/不上wire，bytes逐字节保持。当前不执行输入。

### GRPC-029 — P2 — protobuf descriptor 丢弃 proto2 `required` label，缺字段消息仍被收发为成功

- 状态：已确认；protoc descriptor、native field representation、encode/decode完整性与gRPC调用路径的确定性静态核对。本轮不加载proto2 schema或发送空message。
- 规范：[Protocol Buffers Style Guide — Required Fields](https://protobuf.dev/programming-guides/style/#required-fields)说明required字段的不变量在解析wire bytes时执行，缺少required字段的message必须拒绝解析；虽然required已强烈不推荐，但合法proto2 schema及现有服务仍依赖该兼容契约。serializer也不能把未初始化message正常交给严格peer。
- 位置：Lua protoc把required编码为descriptor label 2在`lualib/protoc.lua:354,474-493`；native descriptor loader只转换成`f->repeated = label == 3`在`luaclib-src/pb.c:1388-1405,1691-1701`，而`pb_Field`只保留repeated bit、没有required/presence位，见`luaclib-src/pb.h:322-333`；gRPC codec入口在`lualib/silly/net/grpc/helper.lua:16-68`。
- 触发：gRPC service使用包含任意proto2 required字段的request或response type；peer发送缺少该字段的空/部分payload，或本地request/handler response table不设置它。嵌套required message字段同样受影响。
- 影响：server会把严格protobuf实现拒绝的未初始化request交给业务并可能返回OK，字段在Lua中表现为nil/default而非明确parse failure；client也会接受缺required的response。反向sender能生成严格peer拒绝的消息，导致跨语言调用失败。业务若把required当作身份、版本、操作类型或幂等键的schema保证，缺值可越过预期的协议层admission并把错误推迟到任意业务分支。
- 证据：descriptor解析阶段除`label==3`设置repeated外不保存label 1/2差异；后续`lpbD_message`只循环处理实际出现字段后无条件成功，encoder只遍历Lua table中存在的keys，二者都无法知道哪些字段required。源码没有`IsInitialized`、required count/bitmap或递归presence检查。`testgrpc.lua`只使用proto3，双语文档也只推荐proto3但没有声明proto2不受支持。
- 根因：内部descriptor为节省状态把三值label压缩成单个repeated布尔值，丢失了之后执行初始化完整性验证所需的信息；gRPC把通用pb codec成功直接等同于schema有效。
- 建议解法：在`pb_Field`保留完整label/required bit，并在decode完成每个顶层/嵌套message前递归验证所有required presence；encode在生成gRPC envelope前执行同一初始化检查并返回可定位field path的受控错误。若1.0明确不支持proto2，应在protoc/service注册阶段fail fast并同步文档，而不是静默接受后偏离wire语义。
- 回归测试：修复阶段覆盖顶层/嵌套required scalar/message、多个required只缺一个、显式默认值、合法全字段、encode/decode及四类RPC双向；缺字段不调用handler、不发送成功message且映射INTERNAL/本地参数错误，proto3 optional不被误判。当前不运行。

### GRPC-030 — P2 — 四类 RPC 没有公开 metadata/context API，认证与 `-bin` metadata 无法互操作

- 状态：已确认；gRPC HTTP/2 metadata grammar、四类client/server公开签名与header/trailer构造的确定性静态核对。本轮不调用带metadata的独立服务。
- 规范：[gRPC over HTTP/2](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)把Custom-Metadata纳入Request-Headers、Response-Headers和Trailers，并规定以`-bin`结尾的Binary-Header使用Base64编码；authorization、trace和应用metadata都依赖这条标准通道。实现可以暂不提供高级拦截器，但若声称通用gRPC client/server，必须有办法逐call收发合法metadata或明确拒绝/声明限制。
- 位置：client四类方法签名/header literal在`lualib/silly/net/grpc/client/service.lua:134-257`；server只按path传`req`或薄stream对象在`lualib/silly/net/grpc/server.lua:8-26`与`grpc/registrar.lua:80-228`；双语公开API位于`docs/src/{en/,}reference/net/grpc.md:266-638`。
- 触发：调用要求`authorization`、traceparent、tenant id或任意custom request metadata的标准gRPC服务；server业务需要读取client metadata、发送initial metadata或在最终status附加trailing metadata；或任一方向使用`foo-bin`。
- 影响：Silly client没有参数可加入任何自定义header，因而无法调用大量需要credential/tenant/routing metadata的实际服务；server unary handler只收到protobuf table，stream对象也未公开metadata/context，正常业务无法可靠读取。server response/trailer由wrapper固定构造，应用错误对象只能给code/message，无法发送initial/trailing metadata。即使穿透package-private H2 table，`-bin`也不会按gRPC规则Base64 encode/decode，跨语言值会错误。
- 证据：所有client constructors都传同一个只含`content-type`的table，公开动态method签名最多只有request/timeout；没有metadata/options/credentials/interceptor参数。server dispatch读取header仅用于`:path`，wrappers不构造call context；application只获得req或含package-private `h2stream`的stream。所有final trailers都是固定`grpc-status/grpc-message` literal。仓库没有gRPC metadata key validator、reserved namespace规则或binary codec，双语reference全文也没有对应API。
- 根因：实现把gRPC call抽象成protobuf message+status，未建模initial metadata、message stream、status metadata组成的完整双向call state；直接暴露/复用H2内部table又不足以承担binary与reserved-key语义。
- 建议解法：引入per-call options/context：client接受并校验request metadata，server context公开decoded request/initial metadata与cancellation/deadline；server可在首message前发送一次initial metadata并在唯一finalizer附加trailing metadata。统一ASCII key/value、重复值、顺序、`-bin` Base64、`grpc-`保留key与size budget；credentials/interceptor在写HEADERS前注入。若1.0延期，应把公开能力标为不支持并对误传选项fail fast。
- 回归测试：修复阶段四类RPC双向覆盖ASCII/重复/空值/多值metadata、合法/非法key、`-bin` padded/unpadded Base64、initial与trailing位置、authorization和超预算；与独立gRPC client/server互通并断言应用不需访问H2私有字段。当前不建立peer。

### GRPC-031 — P1 — `server:close()` 只关闭 listener，既有 H2 连接可无限创建新 RPC

- 状态：已确认；gRPC listener返回对象、TCP/TLS ownership、H2 server channel可达性与官方shutdown生命周期的确定性静态核对。本轮不建立长连接或执行关闭竞态。
- 依据：[gRPC Graceful Shutdown](https://grpc.io/docs/guides/server-graceful-stop/)要求shutdown开始后立即通知client停止发送新RPC、拒绝新RPC，并让已在途调用在deadline内完成；forceful shutdown则关闭全部连接。Silly可以选择暴露其中一种或两种，但“关闭server”不能只停止新TCP accept而让既有HTTP/2连接继续永久接单。
- 位置：`grpc.listen`直接返回底层listener且accept后不保存channel在`lualib/silly/net/grpc/server.lua:30-55`；TCP/TLS listener close只删除listener pool并`net.close(fd)`在`lualib/silly/net/tcp.lua:152-188`、`tls.lua:339-375`；H2 server channel是`httpd`局部对象并持续dispatch在`lualib/silly/net/http/h2.lua:1668-1740`；双语close承诺在`docs/src/{en/,}reference/net/grpc.md:214-261`。
- 触发：任一client在server close前已建立HTTP/2连接；应用随后调用文档化`server:close()`并观察成功，再由该client在相同channel上发起新stream/RPC。滚动发布、停机、配置撤销或测试teardown都会遇到。
- 影响：close返回后旧client仍可无限调用业务handler并产生数据库写入、计费或其他副作用，服务无法形成“不再接收新工作”的shutdown barrier。旧进程/配置可能长期存活，socket、dispatch task和业务资源无法由server owner回收；部署者无法实现graceful drain或force stop，只有等待每个client自行断开/进程退出。安全策略或证书撤换后旧channel也继续使用旧上下文。
- 证据：返回对象就是`tcp.listener/tls.listener`，只拥有listen fd与accept callback；accepted conn立即交给`h2.httpd`，生成的`ch`没有写入server registry。listener close不遍历accepted conns。`common_dispatch`只依赖channel/conn且frame_header_server仍会为后续HEADERS创建stream和fork handler，没有server-closed检查或本端GOAWAY。`testgrpc.lua`先`conn:close()`再`server:close()`，恰好避开既有channel继续请求。
- 根因：server生命周期被建模为监听socket生命周期，没有一个gRPC server owner追踪channels、active calls和shutdown generation；HTTP/2多路复用使“停止accept”不等于“停止RPC”。
- 建议解法：返回专用gRPC server对象，accept时登记每个H2 channel并在dispatch退出时摘除。graceful close原子标记draining、先关listener、向全部channel发送正确Last-Stream-ID的GOAWAY并拒绝新stream，等待active calls到0或absolute deadline；超时/force close终止channel并让call得到UNAVAILABLE/CANCELLED。close返回必须保证registry为空且迟到accept/channel发布受generation阻断，并与`H2-016/028/035`修复联动。
- 回归测试：修复阶段用可控channel覆盖idle/active/streaming RPC、close前已连接但未发call、close与accept/HEADERS并发、deadline/force、重复close及handler异常；断言close开始后无新handler，in-flight按策略完成，client收到GOAWAY/标准status，所有conn/channel/task/quota归零。当前不运行并发场景。

### GRPC-032 — P2 — protobuf encode 异常越过公开错误契约并遗留 timer/H2 active stream

- 状态：已确认；native encoder异常语义、四类client/server wrapper与timer/stream ownership的确定性静态核对。本轮不编码错误对象或建立RPC。
- 契约：公开 unary 调用承诺失败返回`nil, string`，`stream:write`承诺`false, string`；server在handler完成后仍必须用唯一final status结束RPC。serialization failure无论源于本地请求还是业务输出，都必须在写出不完整message前转成受控错误，并恰好取消timer、结束/重置stream和释放HTTP/2并发配额。
- 位置：无保护的codec入口在`lualib/silly/net/grpc/helper.lua:53-67`；client unary/server-streaming的timer与request encode在`grpc/client/service.lua:12-23,134-213`，stream write在`:84-88`；server unary/client-streaming的response encode在`grpc/registrar.lua:83-114,156-191`；native抛错点在`luaclib-src/pb.c:1597-1601,1616-1668,1737-1777`；双语返回契约在`docs/src/{en/,}reference/net/grpc.md:343-352,461-470`。
- 触发：client request table给已知field传错误Lua类型、未知enum名或非table embedded message；或server unary/client-streaming handler返回同类不可编码response。server-streaming client带或不带timeout时在建流后编码错误request也命中。
- 影响：调用者得到Lua异常而不是文档化错误tuple。client unary虽由`<close>`最终关闭H2 stream，但已登记的`waiting_stream[timer]`不会清除/取消，继续强引用关闭对象直到deadline；server-streaming client没有to-be-closed guard，无timeout时异常后stream仍留在channel map并永久占用active stream/quota，有timeout时也至少滞留到timer触发。server unary/client-streaming的response encode位于handler `pcall`之外，异常越过grpc-status finalizer与H2 `server_handler`回收，形成无status响应及`H2-027`同类永久stream/quota泄漏。请求派生的错误业务输出可让远端重复触发该资源耗尽路径。
- 证据：`helper.writebody`直接调用`pb.encode`，没有`pcall`或nil/error分支；native对字段类型、enum及message table用`argcheck/luaL_error`长跳转。unary timer在encode前写入全局table，只有encode/read正常返回后的`:157-163`才删除；sstreaming局部`h2stream`既没有`<close>`也尚未封装进带`__close`对象。server unary/cstream先结束业务`pcall`再调用`writebody`，外层H2 handler没有异常finalizer。现有gRPC测试所有对象都符合schema，且没有异常后的timer、stream map或quota断言。
- 根因：codec采用exception API，但gRPC wrapper按`boolean,error` API编排清理；timer、stream和final status没有统一call owner或finally边界，导致每个调用形态各自遗漏不同清理步骤。
- 建议解法：在写任何envelope前以统一protected encode返回`nil,error`；为每个RPC建立单一call finalizer，负责timer摘除/取消、唯一status、half-close或RST、stream map/quota回收，正常返回和任意Lua/C异常都走它。client本地请求编码失败应在发送request HEADERS前完成并返回参数错误；server输出失败映射INTERNAL且不得再发送部分message。`stream:write`维持文档化`false,error`，不能要求用户自行pcall后猜测stream状态。
- 回归测试：修复阶段对四类RPC分别覆盖错误scalar/enum/nested/repeated请求及response，含有/无timeout；断言不抛出公开边界、handler调用次数正确、只出现一个final status、timer table/stream map/quota立即归零且连接上其他RPC可继续。当前不执行编码或网络路径。

### GRPC-033 — P2 — protobuf scalar encoder 不校验类型/范围并静默改变字段值

- 状态：已确认；protobuf scalar schema、native转换和gRPC sender统一入口的确定性静态核对。本轮不编码边界外数值。
- 规范：[Protocol Buffers scalar value types](https://protobuf.dev/programming-guides/editions/#scalar)把`int32/sint32/sfixed32`映射为有符号32位、`uint32/fixed32`映射为无符号32位，64位类型同理，`bool`映射为boolean；enum number也限定在32位整数范围。typed serializer必须拒绝宿主值域之外的对象，不能通过截断、补码重解释或truthiness生成另一个业务值。
- 位置：Lua integer/string转换在`luaclib-src/pb.c:316-359`；scalar encode switch在`:406-470`；enum转换在`:1616-1641`；字段分发在`:1644-1668`；所有gRPC request/response统一经`lualib/silly/net/grpc/helper.lua:53-67`。
- 触发：给`int32/sint32/sfixed32`传大于`INT32_MAX`或小于`INT32_MIN`，给`uint32/fixed32`传负数或大于`UINT32_MAX`；给signed 64位传`#`字符串表示的`UINT64_MAX`、给unsigned 64位传负Lua integer；给enum传1.5等非整数number；或给bool传字符串`"false"`、空table等非boolean truthy值。普通/repeated/map/nested field都共用这些路径。
- 影响：encoder不报错却在wire上发送与调用者对象不同的值。例如`uint32=-1`变成4294967295，`int32=4294967297`变成1，signed 64位的大正数字符串可在接收端变成负数，字符串`"false"`变成boolean true。ID、金额、revision、权限开关和enum操作类型会在RPC边界静默改变；Silly自身encode→decode也不保持值，严格peer只能看到已经损坏但wire层合法的数据，无法识别原始调用错误。
- 证据：32位case先把结果写入union的`u64`后直接读取`u32`或显式cast`(uint32_t)`，没有上下界比较；64位signed/unsigned共享同一个无符号parser且不按field类型检查符号/range。enum number分支用`lua_tonumber`后直接cast为`uint64_t`，既不要求Lua integer也不验证int32范围；bool只执行`lua_toboolean`，任意非nil/false对象都变1。仅无法转换的部分类型才走`argcheck`，因此上述输入都被当成功编码。
- 根因：binding把wire位宽转换当成schema validation，并利用C cast/Lua truthiness做便利强制转换；但protobuf wire兼容中的截断规则适用于跨schema解析，不授权serializer悄悄改变typed API输入。
- 建议解法：按`type_id`在写tag/body前验证宿主类型和闭区间；32/64位signed、unsigned分别处理，并为Lua不能直接表达的uint64保留严格十进制/十六进制字符串通道。enum只接受整数且验证32位范围（是否允许未声明proto3值可按edition决定），bool只接受Lua boolean。错误通过`GRPC-032`建议的protected encode返回field path和受控错误，不发送HEADERS/envelope。
- 回归测试：修复阶段对每个整数scalar覆盖min-1/min/min+1、-1/0/1、max-1/max/max+1及Lua integer/`#`字符串；enum覆盖fractional、边界和未知整数，bool覆盖true/false/0/1/string/table；普通/repeated/map/nested与四类RPC sender均断言合法值round-trip等值、非法值不上wire且资源立即收尾。当前不执行encode。

### GRPC-034 — P1 — streaming client 不通过返回值交付最终非 OK status，失败可被当作正常 EOF/response

- 状态：已确认；官方call completion语义、三种stream对象的read返回值、公开文档与现有测试的确定性静态核对。本轮不建立stream或发送错误status。
- 规范：[gRPC error handling](https://grpc.io/docs/guides/error/)说明RPC失败时client必须获得非OK error status及可选message；[core call lifecycle](https://grpc.io/docs/what-is-grpc/core-concepts/)明确client-streaming的单response只在最终status OK时构成成功，server/bidi streaming则在消息序列后以最终status完成call。公开文档也承诺`stream:read()`失败返回`nil, string`，不能把非OK completion降成与正常EOS相同的裸nil。
- 位置：status parser在`lualib/silly/net/grpc/client/service.lua:38-53`；client-streaming final read在`:56-63`，server/bidi read在`:72-81`，三种对象在`:95-132`；双语返回契约在`docs/src/{en/,}reference/net/grpc.md:521-530`；现有OK字段断言在`test/testgrpc.lua:156-174,198-222`。
- 触发：server-streaming或bidi先发送零/多条message，最终以`PERMISSION_DENIED`、`INVALID_ARGUMENT`、`ABORTED`等非OK trailer结束；或client-streaming peer返回一条response message再带非OK status。普通transport/read错误、缺status也走同一返回形态；Trailers-Only status位置另见`GRPC-008`。
- 影响：server/bidi的最后一次`read()`总是只返回nil，没有第二返回值，和`grpc-status: OK`正常EOS不可区分；client-streaming `read()`在成功解出object后无条件返回该object，即使最终status非OK，调用方按文档把它当成功response。真实的code/message只写进文档未声明且LuaLS未说明读取时机的`stream.status/message`字段。权限拒绝、乐观并发失败、事务abort或服务不可用因此可能被当成“流正常结束/提交成功”，错误监控、retry和补偿逻辑均不会运行。
- 证据：`stream_read`在obj为nil时调用`check_trailer`后固定`return nil`；`stream_readfinal`先读一条、raw drain并设置字段后固定`return obj`，从未根据`s.status`选择success/error，也没有第二返回值。类注解只列status/message字段，却把`read`方法挂到未注明错误tuple的本地table；reference明确写失败为`nil,string`。现有test只在正常server/bidi EOS后直接访问`stream.status==OK`，client-streaming甚至不检查status，完全没有非OK streaming case。
- 根因：实现把最终Status当成stream对象的旁路诊断属性，而不是决定RPC成功/失败的终态；message reader、final status和公开返回契约没有统一成一个call completion API。
- 建议解法：区分`read next message`与`finish/close_and_recv/status`。client-streaming提供`close_and_recv()`或让final read只在status OK时返回response，否则`nil, typed_status/error`；server/bidi可让EOS read返回`nil, typed_status`，其中OK使用可区分的clean-EOS结果，或提供必须调用的`finish()`。文档和LuaLS公开code/message/trailers，所有transport/protocol/status错误归一，不能只给字符串导致code丢失。
- 回归测试：修复阶段三种streaming分别覆盖0/N message后OK及每类代表性非OK、response+nonOK、Trailers-Only、缺/非法status、RST/断连；断言调用方只用公开返回值即可区分clean EOS与失败，非OK client-streaming永不返回成功对象，status/message只交付一次。当前不运行RPC。

### GRPC-035 — P1 — protobuf oneof decoder 保留已失效成员，sender 也会同时编码多个成员

- 状态：已确认；descriptor oneof索引、native encode/decode与官方last-one-wins规则的确定性静态核对。本轮不加载oneof schema或构造多member message。
- 规范：[Protocol Buffers oneof](https://protobuf.dev/programming-guides/editions/#oneof)要求设置任一member自动清除同组其他member；parser在wire上遇到多个members时只保留最后一个，处理新member前必须清除先前member。oneof是API层“至多一个case”不变量，而不是只额外保存一个case名称。
- 位置：descriptor能正确暴露oneof name/index在`luaclib-src/pb.c:1304-1307`；encoder按table字段独立遍历在`:1728-1757`；decoder的oneof分支在`:1943-1973`；gRPC双向codec入口在`lualib/silly/net/grpc/helper.lua:16-67`。
- 触发：合法peer在同一message依次发送oneof成员`a`和`b`，或重复交替发送它们；反向上，本地request/handler response table同时含`a`与`b`。两者都是动态binding必须确定处理的输入，普通/repeated外层及嵌套message均可命中。
- 影响：decode结果的oneof case字段指向最后的`b`，但Lua table仍同时保留旧`a`及新`b`。业务若直接检查`if msg.a then`、合并table或重新编码，会使用规范上已经清除的数据；当oneof表示credential、selector、operation、payload variant或条件时，可造成校验对象与执行对象分裂。sender则根据`pairs`或descriptor顺序把多个members都写上wire，独立peer只保留最后一个，其选择可能与本地调用者预期不同，且Silly round-trip仍残留双方字段。
- 证据：decoder遇到`f->oneof_idx`只执行`table[oneof_name]=current_field_name`，随后写`table[current_field_name]=value`，没有读取上一case或把`table[previous_name]`设nil。encoder只看每个字段是否存在，`lpb_encode_onefield`不查询同组case；默认`pairs`顺序不构成稳定优先级，`encode_order`也只是descriptor顺序。descriptor已保存oneof索引/name，所以不是缺少schema信息。`testgrpc.lua`的所有messages都没有oneof。
- 根因：binding把oneof实现成“case标签+普通独立字段”，没有让case标签成为字段有效性的唯一owner；encode/decode两边都未执行mutual exclusion。
- 建议解法：decode新member前读取同组上一case，若不同则清除旧字段，再设置新case和值；同一message member重复应按scalar overwrite/message merge规则处理。encode要求每组零或一个member：优先使用显式case并验证对应值，或扫描后发现多个立即返回受控schema error，不能依赖table遍历顺序。与`GRPC-032`统一错误/资源收尾。
- 回归测试：修复阶段覆盖`a→b`、`b→a`、`a→a`、三个members、scalar/message混合、nested及外层repeated；断言decode table只有最终有效member、case一致，message同member正确merge。encode覆盖零/一个/多个、显式case不一致及不同遍历模式；四类RPC双向确认业务永远看不到失效member。当前不构造payload。

### GRPC-036 — P2 — protobuf decoder 覆盖而非合并重复 singular embedded message

- 状态：已确认；protobuf duplicate-field merge规则与native embedded-message对象复用路径的确定性静态核对。本轮不构造重复field payload。
- 规范：[Protocol Buffers Encoding — Last One Wins](https://protobuf.dev/programming-guides/encoding/#last-one-wins)要求重复singular scalar/string取最后值，但重复embedded message按`MergeFrom`语义递归合并：后一个片段的singular scalar覆盖已有值，nested message继续merge，repeated字段追加。合法sender可把同一submessage拆成多个field records，parser不能整块丢弃先前片段。
- 位置：embedded message decode每次新建type table在`luaclib-src/pb.c:1869-1876`；outer field写入在`:1943-1973`；gRPC request/response decode统一经`lualib/silly/net/grpc/helper.lua:16-50`。
- 触发：peer为同一singular message field发送两次，例如第一段只含`user.id`，第二段只含`user.role`；更深层nested、repeated子字段或同一oneof message member重复也可命中。该wire输入符合protobuf兼容规则，不需要畸形frame。
- 影响：Silly最终只保留第二段table，静默丢失第一段的id等字段；严格实现则得到`{id,role}`合并对象。同一gRPC request在不同语言server上产生不同业务输入，身份、mask、condition或patch message可被误解释；client同样接受残缺response。对同一oneof message member的重复还叠加`GRPC-035`，case虽相同但内容仍未merge。
- 证据：`lpbD_rawfield(PB_Tmessage)`无条件调用`lpb_pushtypetable`创建新table，再递归decode当前LEN slice；返回后outer `lua_rawset`直接覆盖同名key。代码从不查现有`table[field]`、不把它作为decode target，也没有message merge函数。scalar overwrite和repeated append各自存在，但不能补偿singular message整块替换。现有gRPC schema有message nesting的文档例子，却无duplicate field测试。
- 根因：通用decoder把所有non-repeated fields统一为Lua table赋值的last-write-wins，忽略protobuf对message类型特有的merge规则。
- 建议解法：singular message首次出现时创建typed table，后续出现复用现有table作为decode target并递归应用同一merge规则；scalar最后值覆盖、repeated追加、map key最后值及oneof切换清理分别保持规范语义。decode hook必须在merge边界只执行定义明确的次数，避免把已有对象替换回旧状态。
- 回归测试：修复阶段覆盖两个片段不同/相同scalar、nested message、repeated追加、map重复key、同一oneof message member和不同member切换；与官方protobuf实现对同一bytes比较结构，四类RPC双向断言业务看到完整merge结果。当前不构造bytes。

### GRPC-037 — P2 — protobuf parser 拒绝 packed=false repeated numeric 的合法 packed 表示

- 状态：已确认；descriptor packed默认值、repeated decoder分支与protobuf parser兼容规则的确定性静态核对。本轮不加载proto2 schema或构造packed payload。
- 规范：[Protocol Buffers Encoding](https://protobuf.dev/programming-guides/encoding/#repeated-elements)要求parser对packable repeated primitive同时接受packed和unpacked wire表示，不论schema中的`packed`选项如何；这保证给既有字段切换`[packed=true]`仍保持wire兼容。选项控制serializer首选格式，不能缩小parser接受域。
- 位置：descriptor把proto2未指定/显式false保存为`f->packed=0`在`luaclib-src/pb.h:1697-1701`；wire type校验和repeated分支在`luaclib-src/pb.c:1884-1899,1926-1941`；gRPC decode入口在`lualib/silly/net/grpc/helper.lua:16-50`。
- 触发：service message含proto2 repeated int/enum/bool/fixed/float等packable字段且descriptor为默认`packed=false`或显式false；独立peer以LEN packed形式发送其值。schema演进中peer切换packed选项、代理或其他runtime规范化输出时都可出现。
- 影响：规范上兼容的request会在Silly server抛type mismatch，继而按`GRPC-007`缺status/泄漏；client遇到合法response也会按`GRPC-015`抛异常。相同schema与bytes在官方runtime成功，在Silly失败，使proto2及跨版本rolling upgrade无法互操作。反向`packed=true` descriptor接收unpacked值当前能够工作，偏离是单向的。
- 证据：当incoming wire type是BYTES时，`lpbD_repeated`只有`f->packed=true`才进入packed slice循环；若`f->packed=false`且元素原生wire type不是BYTES，条件直接调用`lpbD_field`，随后`lpbD_checktype`以元素VARINT/32BIT/64BIT对LEN tag报错。descriptor loader明确只对proto3默认设packed。现有`testgrpc.lua`没有repeated numeric字段，更没有descriptor选项与相反wire表示组合。
- 根因：decoder错误复用serializer的preferred packed flag决定接收语法，而不是按“字段可打包类型 + incoming wire type”选择两种合法解析路径。
- 建议解法：为每个packable repeated scalar始终接受原生wire type和LEN packed type；string/bytes/message等不可打包类型仍只接受其合法LEN单值记录。descriptor `packed`只决定encode格式。错误packed payload必须完整消费并验证元素边界，异常按统一gRPC parse finalizer收尾。
- 回归测试：修复阶段对每个packable type、proto2 default/true/false与proto3 default/false做packed/unpacked交叉矩阵，混合两种记录也应按顺序append；不可打包类型的伪packed仍拒绝。与官方encoder bytes互通，并在四类RPC双向断言status和资源归零。当前不构造wire。

### GRPC-038 — P2 — bundled protobuf parser/native codec 无法收发合法 proto2 group field

- 状态：已确认；proto2 grammar、bundled protoc parser、descriptor type与native codec switch的确定性静态核对。本轮不加载group schema或构造SGROUP/EGROUP wire。
- 规范：[Protocol Buffers proto2 groups](https://protobuf.dev/programming-guides/proto2/#groups)虽明确标为deprecated并建议新schema改用nested message，但仍是合法proto2 schema与独立wire格式；现存服务及迁移期runtime必须能够解析，不能因为“弃用”把合法field静默变成不可调用。若1.0只支持proto3，应在入口与文档明确fail-fast范围，而当前parser默认syntax恰是proto2。
- 位置：protoc type表列出group却把com type当字段名错误在`lualib/protoc.lua:363-394,444-495`，message body没有group parser在`:637-650`；native wire/type enum包含`PB_Tgroup`在`luaclib-src/pb.h:82-109`，但scalar encode/decode switch没有对应case在`luaclib-src/pb.c:406-483,486-535`，field dispatch仅特判message/enum在`:1644-1668`；gRPC统一codec入口在`lualib/silly/net/grpc/helper.lua:16-67`。
- 触发：用bundled protoc加载含`optional/repeated group`的合法proto2 service schema；或绕过parser加载外部FileDescriptorSet，其中RPC request/response包含TYPE_GROUP field，再进行任一方向encode/decode。
- 影响：第一条路径在服务启动/加载schema时直接报`invalid type name: group`；第二条路径descriptor可保留type 10，但client/server编码或解析首个known group field时抛`unknown type group`，RPC无法互操作并可能按`GRPC-007/015/032`错误收尾或泄漏。旧proto2 gRPC服务、历史descriptor及向Editions DELIMITED迁移的wire兼容路径均不可使用，而公开文档只笼统宣称标准Protocol Buffers、未声明限制。
- 证据：`types/com_types`都含group，但`type_info`明确对所有com type报invalid type name，且`msgbody`只有oneof/option等、没有proto2 group grammar。native的`lpb_addtype/lpb_readtype`覆盖全部scalar/message bytes路径却没有`PB_Tgroup`，最终default抛unknown；`lpbE_field/lpbD_rawfield`只把`PB_Tmessage`递归处理，故外部descriptor也不能绕过。底层`pb_readgroup/pb_skipvalue`只支持跳过unknown group，不能解析known group。
- 根因：wire helper保留了group skip能力，但schema parser和typed codec从未实现known group，且没有在gRPC能力声明中将proto2/legacy feature范围收窄。
- 建议解法：若保留proto2支持，在protoc实现group grammar/descriptor nested type，并在native codec用匹配field number的SGROUP/EGROUP递归收发、执行depth/required/merge规则；错误end tag必须拒绝。若1.0决定不支持group，应在schema load阶段返回明确unsupported feature、文档声明proto3-only/受限proto2，不能让外部descriptor直到RPC时才抛generic unknown type。
- 回归测试：修复阶段覆盖optional/repeated group、nested group、unknown group skip、错误/missing/mismatched EGROUP、required子字段和跨官方runtime收发；四类RPC验证合法group或明确的注册期拒绝，均不得在调用中抛裸异常/泄漏。当前不加载schema。

## 5. 候选问题收口

两轮静态审计没有遗留的未归档候选。原`CAND-SOCK-002`已由完整sid/check/accounting调用链升级为`SOCK-007`；因用户要求停止新增并发barrier，它明确标注为“确定性静态时序、无独立动态复现”。其余依赖外部版本、畸形peer或故障注入的工作都列为对应已确认问题的“修复阶段回归条件”，不再混入候选计数。这里的“收口”表示计划内源码、协议与文档路径均已静态复核并完成归档，不表示数学上证明不存在其他bug；未执行的独立peer、版本矩阵、sanitizer定向回归与故障注入仍可能在修复阶段发现新问题。

## 6. 已排除项

### REJECT-SOCK-001 — 固定接收 buffer 导致合法 UDP 报文截断

- 原候选：`CAND-SOCK-004`。
- 位置：`src/socket.c:1028-1057`、`src/silly_conf.h:49-50`。
- 结论：当前不构成缺陷。`recvfrom` 的固定 buffer 为 2 MiB，显著大于 IPv4/IPv6 可承载的最大合法 UDP datagram（约 64 KiB）；因此合法 UDP 报文不会因该 buffer 大小而被截断。
- 保留条件：若未来将 buffer 缩小到 UDP 上限以下，或加入平台特定的非标准超大 UDP/GSO 接收接口，必须重新检查 `MSG_TRUNC` 和报文边界语义。

## 7. TSAN 动态证据摘要

隔离构建参数：`-DSILLY_TEST -O1 -fsanitize=thread -fno-omit-frame-pointer`，运行完整 `testtcp2`。业务断言30组全部通过，但进程以TSAN告警状态退出；基线报告5组竞争，后续定向`socket_stat`检查又报告2组，共7组：

1. `engine.c:76` 写 `workerstatus` vs `engine.c:45` 读。
2. `queue.c:91` 读 `size` vs `queue.c:67` 写。
3. `queue.c:75` 读 `head` vs `queue.c:65` 写。
4. `worker.c:94` 读 `maxmsg` vs `worker.c:193` 写。
5. `engine.c:168` 写 `running` vs `engine.c:94` 读。
6. `socket.c:763` 写 `fd` vs `socket.c:2028` 的 `socket_stat` 读。
7. `socket.c:461` 写 `type` vs `socket.c:2029` 的 `socket_stat` 读。

因此“普通测试通过”与“并发实现没有 UB”是两个不同结论；后续并发模块将继续同时看功能结果和 sanitizer 结果。

## 8. 最终统计与修复路线

当前滚动统计为302项：P0为0，P1为108，P2为164，P3为30。模块分布：CORE 7、NET 6、SOCK 19、UDP 1、TLS 18、DNS 18、CLUSTER 15、ADDR 2、URL 3、HTTPC 9、HTTP1 23、COMP 1、WS 10、H2 41、HPACK 3、GRPC 38、REDIS 10、MYSQLC 8、MYSQL 20、ETCD 16、DOC 34。

建议按依赖关系分五批修复：

1. 内存安全和generation所有权：优先`SOCK-006/008/009/011`、`MYSQLC-001/005`、`HPACK-002`、`TLS-002`、`CLUSTER-005`；任何上层互操作测试都应在这些路径稳定后进行。
2. 安全身份与输入边界：`TLS-001/005/006`、`DNS-002/003`、`CLUSTER-001`、`HTTP1-007/008/009`、`WS-001/002/005/008`、`H2-003/013/019/025`、`GRPC-005`、`ETCD-005/009`。
3. transport状态机和取消：统一socket/engine同步后处理HTTP/1 framing、HTTP/2 stream/flow-control/GOAWAY、TLS shutdown、gRPC status/deadline，以及Redis/MySQL/etcd贯穿DNS→connect→handshake→request→body的absolute deadline。
4. driver数据正确性：Redis parser/null与connection generation；MySQL pool lease/transaction/multi-result/packet codec；etcd mutation ambiguity、watch revision checkpoint和lease scheduler。
5. 互操作与文档：用Go/OpenSSL/Redis/MySQL 8/MariaDB/etcd官方client-server矩阵验证，执行RFC畸形输入与sanitizer；最后同步LuaLS、中英文reference和所有示例。

修复阶段的最低门槛是：每项有独立回归、ASan/UBSan/TSAN适用项清零、资源上限可配置且有安全默认、跨连接/stream错误不污染其他请求；协议项必须至少与一个独立实现双向互操作。

## 9. 审计日志

- 2026-08-06：建立独立最新工作副本，拉取官方 origin，确认 HEAD `d1aef7ff`。
- 2026-08-06：完成 ASan/UBSan 基线；TCP、HTTP/1、HTTP/2、WebSocket、gRPC、Redis、MariaDB 10.3 测试通过。
- 2026-08-06：完成第一轮 engine/queue/worker/socket 静态审阅，并用 TSAN 确认 5 组真实竞争。
- 2026-08-06：用 `sendv_cap=1` 的确定性复现确认退出路径泄漏全部待发 payload；LSan 报告 32768 bytes/8 objects。
- 2026-08-06：确认立即失败的 TCP connect 泄漏 fd；8 次失败令 open fd 从 8 增至 16。
- 2026-08-13：1.0封板平台审计确认Windows控制唤醒通道以Winsock socket创建，却由CRT `close`销毁；归档为`SOCK-016`。
- 2026-08-13：确认Windows accept资源耗尽路径以CRT `/dev/null` fd冒充Winsock reserve socket，无法释放对应资源槽；归档为`SOCK-017`。
- 2026-08-13：确认Windows控制socket路径拼接未检查Win32 required length和`snprintf`截断，长目录可在启动期形成栈越界写；归档为`SOCK-018`。
- 2026-08-13：确认TCP listen/connect/accept及stat将Win64指针宽度`SOCKET`存入`int`，合法高位handle会被截断；归档为`SOCK-019`。
- 2026-08-13：确认`addr.parse`处理无端口bracket地址时构造`se+1`指针并比较，公开正常输入落入C未定义行为；归档为`ADDR-002`。
- 2026-08-13：确认低层net在socket成功发布后才assert事件回调，缺字段配置会遗留不可达fd；文档允许无accept listener又可被远端重复触发；归档为`NET-004`。
- 2026-08-13：确认TCP/TLS双语reference、guide与benchmark共10处使用底层明确拒绝的多字节`"\\r\\n"` delimiter；归档为`DOC-007`。
- 2026-08-13：确认TCP/TLS single-reader门禁位于buffer fast path之后，并发reader可按分片时序偷走旧operation字节并使其永久等待；归档为`NET-005`。
- 2026-08-13：确认TCP/TLS buffer limit会在当前定长/分隔符read满足前暂停transport，唯一reader无法消费或恢复，形成永久自锁；归档为`NET-006`。
- 2026-08-13：确认TLS native把`read(0)`编码为未满足，Lua登记值为0的唯一waiter后所有data callback都无法完成；归档为`TLS-009`。
- 2026-08-13：确认DNS query encoder处理普通名字最后一个label后构造`end+1`指针，所有无尾随点查询落入C未定义行为；归档为`DNS-009`。
- 2026-08-13：确认DNS RR循环把结构/RDATA parse failure降格为break或skip，仍以成功提交已解析前缀并完成请求；归档为`DNS-010`。
- 2026-08-13：确认DNS caller在timer创建前已发布singleflight waiter，超范围timeout抛错会留下dead task并使共享finish再次异常；归档为`DNS-011`。
- 2026-08-13：确认`dns.conf`在任何新配置校验前已结束inflight并关闭旧resolver，后续异常会留下空/半配置全局状态；归档为`DNS-012`。
- 2026-08-13：按RFC 6891确认DNS主动发送OPT却跳过response OPT，extended RCODE/version丢失并会把扩展错误当成功空答案；归档为`DNS-013`。
- 2026-08-13：按RFC 2181确认DNS cache只采用RRset首条TTL，未将异TTL组收紧到最低值，缓存寿命受wire顺序控制；归档为`DNS-014`。
- 2026-08-13：确认DNS为每个查询名字永久intern cache节点，expired/TTL0/timeout/send failure均无逐项删除或容量预算；归档为`DNS-015`。
- 2026-08-13：确认Windows DNS bootstrap在`GetNetworkParams`要求扩容后不检查`malloc`结果，OOM时仍把NULL作为输出buffer传回系统API；归档为`DNS-016`。
- 2026-08-13：确认Windows hosts路径只验证system directory本身能装入MAX_PATH，追加固定后缀后可静默截断并忽略hosts配置；归档为`DNS-017`。
- 2026-08-13：确认系统resolver配置读取失败或显式空列表会自动改用公共8.8.8.8，绕过本机DNS策略并可能泄漏内部查询；归档为`DNS-018`。
- 2026-08-13：排除DNS共享TCP recv task覆盖新连接的候选；close只将reader排入wakeup queue，worker在下一条消息前完成旧task收尾，期间没有可发布新连接的yield点。
- 2026-08-13：确认DNS双语reference声明的`sys.dns.resolv_conf`/`sys.dns.hosts`环境变量没有任何实现consumer，设置后仍读取固定系统路径；归档为`DOC-008`。
- 2026-08-13：按OpenSSL契约确认TLS `ciphers`只调用旧cipher-list API，TLS1.3 suites仍使用库默认；双语安全指南的混合列表会静默假成功；归档为`TLS-010`。
- 2026-08-13：确认TLS plaintext buffer以signed int累计并做无检查加法/倍增，远端长期输入接近表示上限时可回绕并污染SSL_read写地址/长度；归档为`TLS-011`。
- 2026-08-13：确认TLS client在TCP已注册后才编码ALPN/创建SSL，配置或native构造异常发生在conn owner发布前且无cleanup guard；归档为`TLS-012`。
- 2026-08-13：确认TLS native将可由`__len`提供的Lua证书数量直接窄化为int并以int计算flexible-array大小，可形成零entry ctx或越界写；归档为`TLS-013`。
- 2026-08-13：确认TLS vectored write逐段进入SSL后才校验后续元素，后段异常/错误会把已生成prefix ciphertext留在out BIO并由未来write迟发；归档为`TLS-014`。
- 2026-08-13：确认TLS certificate loader先创建SSL_CTX再调用可longjmp的Lua字段类型检查，异常绕过cleanup且指针尚未提交给userdata owner；归档为`TLS-015`。
- 2026-08-13：确认OpenSSL未协商ALPN的零长度结果被binding转换为空字符串而非文档承诺的nil，Lua truthiness可误判为已协商；归档为`TLS-016`。
- 2026-08-13：补强`TLS-001/004/006`：双语文档虚构默认certificate verification和cipher-string版本控制，testssl又把raw TCP close误注释成SSL_shutdown；不重复计数。
- 2026-08-13：确认低层TLS ctx/ssl显式free后仍由同一strict函数执行GC，meta tombstone会被当作类型错误并在finalizer中抛出；归档为`TLS-017`。
- 2026-08-13：确认TLS双语reference的validate示例一处漏必填listener addr、另一处把hostname直接传给numeric-only connect并静默退出；归档为`DOC-009`。
- 2026-08-13：确认TLS底层LuaLS仍声明文件路径ctx与boolean handshake，真实C ABI却要求PEM表并返回`1/0/-1`三态整数；归档为`DOC-010`。
- 2026-08-13：确认TLS双语指南把OpenSSL能力误写为Silly自动session resumption/0-RTT收益，而binding没有client session复用或early-data API；归档为`DOC-011`。
- 2026-08-13：确认ALPN encoder允许零长度协议，client又忽略OpenSSL反向返回约定，非法配置被静默清空并可降级；归档为`TLS-018`。
- 2026-08-13：TLS/OpenSSL阶段收口：完整覆盖`tls.lua`、`ltls.c`、`testssl.lua`、native LuaLS、双语reference/guide及构建开关；排除“同hostname多算法证书选择”（公开契约仅承诺多域SNI）和“close后TLS data callback泄漏”（通用net同步撤销callback并接管迟到payload）候选，转入HTTP common/H1。
- 2026-08-13：确认H1 fixed-length增量读取每批把`recvbytes`累计两次，可提前通过close完整性检查并把带残留body的连接归池；归档为`HTTP1-018`。
- 2026-08-13：确认H1 chunked普通空写会编码协议last-chunk却保持stream可写，closewrite空串还会生成双终止块并污染下一消息；归档为`HTTP1-019`。
- 2026-08-13：确认H1 sender/client/server均以Lua `tonumber`解释Content-Length，符号/hex/指数/小数等非法wire值可与严格peer形成消息边界分叉；归档为`HTTP1-020`。
- 2026-08-13：确认HTTP redirect把301/302/303的所有method一律改GET，且删除body时残留Expect/TE等entity fields，破坏方法与下一跳消息语义；归档为`HTTPC-006`。
- 2026-08-13：确认HTTP双语reference公开listen backlog，而http.lua明文/TLS adapter都未转发到底层，任何配置均静默落回默认；归档为`DOC-012`。
- 2026-08-13：确认H1 sender只按精确小写Lua key识别Host/CL/TE等控制字段，常规Title-Case输入可被重复并由库自动形成TE+CL歧义wire；归档为`HTTP1-021`。
- 2026-08-13：确认H1 server把HEAD/304与1xx/204共用bodyless分支并无差别删除CL/TE，丢失规范允许的representation元数据；归档为`HTTP1-022`。
- 2026-08-13：确认中文HTTP reference声明`http.newclient.read_timeout`默认5秒，但实现/schema完全不接收该字段且请求仍无限等待；归档为`DOC-013`。
- 2026-08-13：确认H1/H2 parser把重复字段提升为array，而redirect/gzip仍将Location/Content-Encoding当string，远端响应可触发未捕获Lua类型异常；归档为`HTTPC-007`。
- 2026-08-13：确认H1读取失败会保留已缓冲正文，而后续readall只要缓冲非空便返回`data,nil`并吞掉cached error；归档为`HTTP1-023`。
- 2026-08-13：确认idle H2 channel close只异步排队GOAWAY后即同步关闭transport，flush task随后因conn=nil丢弃graceful shutdown wire；归档为`H2-035`。
- 2026-08-13：确认H2 client允许DATA在任何final response HEADERS前进入body/readall，高层可返回status=nil、body非空且无error的response对象；归档为`H2-036`。
- 2026-08-13：确认H2 stream进入RST/GOAWAY error终态后，readall只要buffer非空就返回partial data,nil并吞掉终态错误；归档为`H2-037`。
- 2026-08-13：确认remote RST只终止当前waiter/remote half，之后respond/write/closewrite仍排HEADERS/DATA并报告成功；归档为`H2-038`。
- 2026-08-13：确认HTTP双语reference/中文guide把server push列为Silly已支持，但H2无push API且client SETTINGS明确禁用；归档为`DOC-014`。
- 2026-08-13：确认HTTP双语reference/guide反称H2不支持实际已实现的write，并让用户调用不存在的close(body)；归档为`DOC-015`。
- 2026-08-13：确认中文HTTP reference与双语guide错称client不池化/每次新建连接，实际顶层singleton与专用client均复用H1/H2；归档为`DOC-016`。
- 2026-08-13：确认H2 client把openstream的本地reservation立即放入wire map，peer可在request HEADERS发送前让idle id被当作open接受；归档为`H2-039`。
- 2026-08-13：确认H2 sender不累计实际DATA长度，request/response可在Content-Length失配时仍排END_STREAM并报告成功；归档为`H2-040`。
- 2026-08-13：确认32位HPACK table-size setting未经checked conversion窄化进C int，动态表非空时容量减法可触发signed overflow；归档为`HPACK-004`。
- 2026-08-13：确认zero-length H2 frame会在检查PADDED前按空payload短路，缺失Pad Length的DATA仍可正常END_STREAM；归档为`H2-041`。
- 2026-08-13：补强`H2-003`：padding在flow-control记账前已被剥离，守规peer发送padded DATA也会因Pad Length/padding credit永不回补而停顿；不重复计数。
- 2026-08-13：确认双语HTTP/2最佳实践示例遗漏tls开关和server ALPN，原样实际启动明文H1且证书不生效；归档为`DOC-017`并按安全误导定为P2。
- 2026-08-13：确认双语WebSocket教程在`sock:read()`完整缓冲后才检查10 KiB并错误声称可防恶意大消息；归档为`DOC-018`，实现侧根因仍由`WS-005`覆盖。
- 2026-08-13：补强`TLS-009`：WebSocket frame reader对零payload仍调用`read(0)`，故WSS收到合法空Close/Ping/Pong/data frame会永久等待；现有WSS测试只读非空消息，未覆盖该分叉。不重复计数。
- 2026-08-13：补强`WS-007`：WebSocket把非幂等close直接注册为`__close`，显式close后作用域退出或重复cleanup会在nil connection上抛异常并可能掩盖原错误。不重复计数。
- 2026-08-13：确认WebSocket双语reference虚构partial read data、把非法standalone continuation列为正常消息类型，并把有result的close写成无返回值；归档为`DOC-019`。
- 2026-08-13：确认WebSocket双语教程的广播优化调用channel不存在的`recv/send`方法，consumer与producer首次调用均会异常；归档为`DOC-020`。
- 2026-08-13：确认WebSocket教程对单调ID稀疏`clients`表使用`#clients`做在线统计和连接资源上限，断开产生hole后可持续低估并放行超额连接；归档为`DOC-021`。
- 2026-08-13：确认WebSocket完整聊天室把远端昵称原样拼入浏览器`innerHTML`，20字节server限制仍允许可执行SVG payload并形成跨用户XSS；归档为`DOC-022`。
- 2026-08-13：依据WHATWG确认browser Ping是不可依赖的user-agent可选行为；教程只被动回Pong却宣称自动心跳，没有主动探测或失联deadline，归档为`DOC-023`。
- 2026-08-13：确认WebSocket完整server把JSON语法成功等同schema成功，合法primitive/错型字段可抛异常并跳过clients registry清理，重复连接累积幽灵对象；归档为`DOC-024`。
- 2026-08-13：确认WebSocket双语入门示例读取wrapper不存在的`sock.fd`，所有断线日志都丢失连接标识并误导公开API；归档为`DOC-025`。
- 2026-08-13：WebSocket 1.0封板审计收口：完整复核源码、RFC 6455双角色矩阵、H1/H2交界、双语reference/tutorial和`testwebsocket.lua`全部7组顶层场景；未实现的RFC 8441/permessage-deflate按可选能力记录，并发reader等共享根因已与`NET-005`去重，当前无未归档候选。
- 2026-08-13：补强`WS-003`：127-length最高位置1经Lua `>I8`转为负integer；TCP按空payload成功导致wire重新分帧，TLS进入`TLS-009`挂起。不重复计数。
- 2026-08-13：补强`WS-001`：缺失Upgrade/Connection的H2 GET也可通过handshake，生成H2禁止的101并返回`conn=nil` socket，常规使用异常后叠加`H2-027`泄漏；严格补齐必需H1字段即可阻断，故不另立WS编号。
- 2026-08-13：确认H2 pool entry以lastfree=0发布且stream close无release时间，首次扫描会把刚空闲channel当超时；归档为`HTTPC-008`。
- 2026-08-13：确认HTTP pool以浮点除法派生timer周期，奇数idle_timeout在入池后抛类型异常，非正值可形成0ms扫描循环；归档为`HTTPC-009`。
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
- 2026-08-06：确认 HPACK encoder 的 `hardlimit` 仅本地改表，下一 header block 不会发送强制 dynamic table size update，记录为 `HPACK-001`。
- 2026-08-06：确认 server 把 client 的 MAX_CONCURRENT_STREAMS 反向用于限制该 client 的 request streams，记录为 `H2-005`。
- 2026-08-06：确认非 5-byte PRIORITY 被错误升级为 connection GOAWAY，而 RFC 9113 要求 stream `FRAME_SIZE_ERROR`，记录为 `H2-006`。
- 2026-08-06：确认 GOAWAY handler 完全忽略 payload，0..7-byte frame 未触发强制 connection `FRAME_SIZE_ERROR`，记录为 `H2-007`。
- 2026-08-06：确认合法 GOAWAY 的 Last-Stream-ID/error 被丢弃，高编号未处理请求无法结束或标记 retryable，高层默认可无限等待，记录为 `H2-008`。
- 2026-08-06：确认 client 没有 response/trailer field validator，非法 pseudo/uppercase/connection fields 和非三位 status 可被接受，记录为 `H2-009`。
- 2026-08-06：确认 client 把首个合法 1xx informational response 当 final，真正 final HEADERS 被误分类为 trailer，记录为 `H2-010`。
- 2026-08-06：确认 client 接受不带 END_STREAM 的 trailer HEADERS，之后仍允许 DATA 并发生 TRAILER→DATA 状态回退，记录为 `H2-011`。
- 2026-08-06：确认 client 固定为 CONNECT 发送 scheme/path，server 又固定要求 scheme/path且不要求 authority，普通 CONNECT 双向不符合，记录为 `H2-012`。
- 2026-08-06：确认 HPACK 只限制 compressed wire block，没有 uncompressed field-section/字段数/单字段预算或配置，记录为 `H2-013`。
- 2026-08-06：确认 HPACK varint 无 value/octet 上限，存在 signed shift UB、unsigned→int 回绕和 string pointer/length 越界路径，记录为 `HPACK-002`；按要求未新增触发代码。
- 2026-08-06：确认 Huffman EOS=256 被 `uint8_t` 截断为 0，decoder 无 EOS guard并输出 NUL，记录为 `HPACK-003`。
- 2026-08-06：完成gRPC over HTTP/2首轮静态矩阵，确认`GRPC-001`至`GRPC-018`；按用户要求未新增畸形输入/独立peer复现。基础length-prefix重组、正常response trailer和“不自动重放”路径符合；custom metadata/user-agent等保留为可选能力/API缺口。
- 2026-08-06：确认public send length经`size_t→int→size_t`截断，裸pointer+claimed length可形成巨大TCP iovec，记录为`SOCK-006`；按要求未构造越界发送。
- 2026-08-06：通过确定性generation交错确认late send accounting可污染复用slot，记录为`SOCK-007`；没有为窄窗口新增barrier复现。
- 2026-08-06：确认`worker_exit`释放W后`socket_exit` final flush仍可经report_close调用worker_push，记录为`SOCK-008`；没有新增退出send-error复现。
- 2026-08-06：确认poll batch先snapshot、后处理close/reuse op，裸slot userdata缺generation校验，记录为`SOCK-009`；没有新增跨平台动态复现。
- 2026-08-06：确认`rw_enable`在backend MOD前提交state且忽略失败，导致永久stall/busy-loop，记录为`SOCK-010`；没有新增multiplexer fault injection。
- 2026-08-06：确认公开UDP/ntop把任意Lua string当trusted sockaddr，assert/NDEBUG分别可abort/stack overflow或OOB，记录为`SOCK-011`；未新增破坏性blob测试。
- 2026-08-06：确认TCP/TLS默认buffer及UDP packet stash均无资源上限，慢消费/不读取时远端输入可持续占用内存，记录为`SOCK-012`；未新增流量压力复现。
- 2026-08-06：确认timer把64位毫秒delta窄化为int，大于约24.8天的暂停/时钟跳变可触发assert、无符号巨大跳变或长期错时，记录为`CORE-006`；未新增长期暂停复现。`queue_push`返回int只在超过INT_MAX条消息时影响过载诊断，降为构建卫生，不单列缺陷。
- 2026-08-06：确认listener close同步删除Lua callback而已排队ACCEPT已拥有独立C socket，late event只assert且不close accepted fd，记录为`NET-001`；未新增accept/close barrier复现。
- 2026-08-06：确认TCP/UDP message在Lua callback前清空C owner，而callback异常路径既不释放payload也不关闭socket，记录为`NET-002`；未新增故意抛错复现。
- 2026-08-06：确认TLS client保持OpenSSL默认VERIFY_NONE且hostname只用于SNI，没有trust store、链或hostname验证，记录为`TLS-001`；未新增MITM/伪证书复现。
- 2026-08-06：确认accepted TLS userdata未强引用SNI callback arg所属ctx，reload/close+GC后在途ClientHello可访问失效userdata，记录为`TLS-002`；未新增GC/reload竞态复现。
- 2026-08-06：确认TLS record input丢弃所有SSL_read非正结果且不flush控制输出，close_notify/fatal error不会唤醒reader，记录为`TLS-003`；未新增alert输入。
- 2026-08-06：确认TLS close只断开TCP且native模块完全没有SSL_shutdown，peer永远收不到authenticated close_notify，记录为`TLS-004`；未新增strict-peer互操作。
- 2026-08-06：确认TLS server在应用accept前以nil timeout等待ClientHello，listener无握手deadline配置，空连接可永久占用fd/SSL/task，记录为`TLS-005`；未新增slow-handshake压力复现。
- 2026-08-06：确认TLS server显式minimum为TLS1.1、client不设置minimum，安全基线依赖环境且可偏离RFC8996，记录为`TLS-006`；未启用legacy cipher互操作。
- 2026-08-06：确认DNS CNAME/SRV/SOA name decoder使用整条message边界且A/AAAA只校验最小长度，typed RDATA可跨越声明RDLENGTH，记录为`DNS-001`；未新增畸形packet。
- 2026-08-06：确认DNS parser抹平answer/authority/additional并丢弃CLASS，cache无条件按owner清除/写入，低trust无关记录可覆盖任意名字，记录为`DNS-002`；未新增恶意上游互操作。
- 2026-08-06：确认DNS新name TXID恒为1且按name独立递增，同时每个server长期复用单一UDP source port，偏离RFC5452防伪entropy要求，记录为`DNS-003`；未发送伪造response。
- 2026-08-06：确认cluster response虽携带fd但Lua只按全局31-bit session匹配waiter，任意peer/late wrap ACK可跨连接完成其他RPC，记录为`CLUSTER-001`；未构造伪ACK。
- 2026-08-06：确认cluster pending只存coroutine且两个close路径都没有peer反向索引/finish，断线后RPC只能保留到timeout，记录为`CLUSTER-002`；未新增断线timing复现。
- 2026-08-06：确认cluster unknown/late/duplicate ACK取到nil waiter后仍task.wakeup，且连接保持可重复制造异常与日志，记录为`CLUSTER-003`；未发送ACK flood。
- 2026-08-06：确认cluster主动close不调用C parser clear且net已移除close callback，partial frame allocation永久挂在全局ctx，记录为`CLUSTER-004`；未发送大partial frame。
- 2026-08-06：确认cluster接受UINT32_MAX hardlimit，但receive的psize+1与send的4+body会32-bit回绕后小分配/大copy，记录为`CLUSTER-005`；未构造越界包。
- 2026-08-06：确认cluster把native整数/struct直接memcpy上wire且文档长度/顺序也与实现不符，跨端序节点无法互操作，记录为`CLUSTER-006`；未运行big-endian peer。
- 2026-08-06：确认addr IP分类把Lua string按首个NUL截断，而中间层仍保留/返回完整值、socket再次截断，形成验证与实际endpoint混淆，记录为`ADDR-001`；未新增NUL连接复现。
- 2026-08-06：确认HTTP URL model把fragment留在u.path并直接用于HTTP/1 request-target/HTTP/2 :path，客户端私有fragment会上wire，记录为`URL-001`；未发送敏感fragment。
- 2026-08-06：确认URL scheme只在缺省port时校验，显式port可让任意scheme通过且HTTP/WS consumer回落明文TCP，记录为`URL-002`；未对非HTTP服务发请求。
- 2026-08-06：确认URL relative resolver不拆path/query、不移除dot-segments且错误处理empty ref，redirect可生成错误target，记录为`URL-003`；未新增redirect server复现。
- 2026-08-06：确认HTTP convenience client自动readall与gzip解压均无wire/decoded大小或ratio预算，恶意响应可耗尽内存，记录为`HTTPC-001`；未生成gzip bomb/大响应。
- 2026-08-06：确认HTTP client没有端到端deadline/cancel，pool idle timeout不覆盖DNS/connect/TLS或在途H1/H2 reads，记录为`HTTPC-002`；未运行slow peer。
- 2026-08-06：确认HTTP/1 server不要求唯一合法Host，也不解析absolute-form effective authority，歧义请求会进入handler，记录为`HTTP1-008`；未新增Host报文。
- 2026-08-06：确认HTTP/1 receiver用%S+代替token/value octet校验，sender把header原样拼接，CRLF可注入控制字段/空行，记录为`HTTP1-009`；未构造injection报文。
- 2026-08-06：确认HTTP/1 request/status-line parser未锚定、版本字符类含`|`且status不限3位，method白名单又先于语法/能力判断，记录为`HTTP1-010`；未构造畸形start-line。
- 2026-08-06：确认gzip inflate以output buffer是否填满代替`Z_STREAM_END`，截断、尾随或multi-member输入可被部分成功接受，记录为`COMP-001`；未生成压缩样本。
- 2026-08-06：确认Redis RESP未知type/非法length等会抛出未清理异常，reader token与wait queue因此永久卡死，记录为`REDIS-001`；未发送畸形RESP。
- 2026-08-06：确认Redis command在获取reader token前的write failure会调用reader-only cleanup并assert，pipeline又遗留坏socket，记录为`REDIS-002`；未注入send failure。
- 2026-08-06：确认Redis connect、AUTH/SELECT、command/pipeline与reader queue均无deadline/cancel，一个slow peer可挂住整个client，记录为`REDIS-003`；未运行slow peer。
- 2026-08-06：确认Redis RESP line/bulk/array count与递归深度均无预算，peer可耗尽内存、CPU或stack，记录为`REDIS-004`；未生成大/深RESP。
- 2026-08-06：确认Redis close看不到局部in-flight socket且connect/handshake完成后不复查closed，关闭对象可被复活，记录为`REDIS-005`；并发问题仅作时序说明。
- 2026-08-06：确认RESP array/pipeline把wire null直接赋为Lua nil，槽位与尾部长度消失，合法响应不能无损表示，记录为`REDIS-006`。
- 2026-08-06：确认MySQL binary row在确认NULL bitmap完整前保存裸pointer并逐bit访问，截断packet可造成C越界读，记录为`MYSQLC-001`；未生成packet。
- 2026-08-09：确认MySQL BIGINT UNSIGNED通过signed lua_Integer返回，合法高半区值wrap为负数，记录为`MYSQLC-002`。
- 2026-08-09：确认MySQL temporal codec遇非法length会返回硬编码2017时间且不推进cursor，记录为`MYSQLC-003`；未生成非法row。
- 2026-08-09：确认MySQL未协商SESSION_TRACK时OK info应为EOF string，但codec无条件按lenenc解析，记录为`MYSQLC-004`。
- 2026-08-09：确认MySQL prepared encoder跨luaL_Buffer扩容持有null/type裸pointer，后续参数会写旧内存并损坏wire，记录为`MYSQLC-005`；未生成大execute。
- 2026-08-09：确认MySQL row只按alias建表且丢弃qualifier/ordinal，duplicate columns静默覆盖，compact_arrays选项未实现，记录为`MYSQLC-006`。
- 2026-08-06：确认MySQL idle/lifetime两条淘汰路径关闭fd却不递减open_count，max-open pool可永久假满并挂住请求，记录为`MYSQL-001`。
- 2026-08-06：确认MySQL仅用明文TCP且full-auth接受未认证peer临时RSA key，MITM可读改流量并取得密码，记录为`MYSQL-002`；未搭建MITM。
- 2026-08-06：确认MySQL connect/auth/query/pool wait均无deadline/cancel且测试传入的connect_timeout被静默忽略，记录为`MYSQL-003`；未运行slow peer。
- 2026-08-09：确认MySQL conn close归池后原Lua对象仍能操作同一fd且close不幂等，旧/新borrower可共享stream，记录为`MYSQL-004`。
- 2026-08-09：确认MySQL COMMIT/ROLLBACK在server确认前清除本地transaction flag，ERR后仍归池，记录为`MYSQL-005`；未注入transaction failure。
- 2026-08-09：确认MySQL conn_new从不检查closed：close后ping/begin可确定性新建连接，capacity waiter/in-flight connect也会继续，记录为`MYSQL-006`；并发部分仅作时序说明。
- 2026-08-09：确认MySQL把physical packet当完整message、拒绝zero terminator且不校验sequence，≥0xffffff payload会反同步，记录为`MYSQL-007`；未生成大payload。
- 2026-08-09：确认MySQL global/per-connection prepared caches均无界且从不COM_STMT_CLOSE，高基数SQL可耗尽client/server资源，记录为`MYSQL-008`；未生成高基数SQL。
- 2026-08-09：确认MySQL max_packet_size仅写握手、接收与全量result rows/columns没有累计预算，记录为`MYSQL-009`；未生成大result。
- 2026-08-09：确认MySQL对MORE_RESULTS的OK直接返回、EOF则继续旧row parser，剩余response可污染归池连接，记录为`MYSQL-010`；未创建stored procedure。
- 2026-08-09：确认MySQL codec/unpack异常不进入统一fatal cleanup，login泄漏open_count、query把反同步连接归池，记录为`MYSQL-011`；未发送畸形packet。
- 2026-08-09：确认MySQL handshake用CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA决定server seed part 2且固定12 bytes，记录为`MYSQL-012`。
- 2026-08-06：确认 half-closed(remote) stream 上的 late DATA 被升级为 connection PROTOCOL_ERROR，而不是该 stream 的 STREAM_CLOSED，记录为 `H2-014`。
- 2026-08-06：确认 client 不记录本端已用 stream-id，完成后合法 late WINDOW_UPDATE 会被误判 idle 并触发 GOAWAY，记录为 `H2-015`。
- 2026-08-06：确认无已处理 peer stream 时 `laststreamid=-1` 被 GOAWAY builder 序列化为 0xffffffff，记录为 `H2-016`。
- 2026-08-06：确认完整响应后的 RST_STREAM(NO_ERROR) 会把 client END 覆盖为 RST，使尚未读取的空响应被丢弃，记录为 `H2-017`。
- 2026-08-06：确认 request/response/trailer sender 在 HPACK 前无 HTTP/2 field validation，可生成 connection-specific/非法或重复控制 fields，记录为 `H2-018`。
- 2026-08-06：确认 server request validator 未执行 RFC 9113 最低 name/value octet 规则，且用宽松 `tonumber` 解析 Content-Length，记录为 `H2-019`。
- 2026-08-06：确认 outbound HPACK block 跨 frame 时 final fragment 被硬编码成第二个 HEADERS，而非 CONTINUATION，记录为 `H2-020`。
- 2026-08-06：确认 SETTINGS initial-window delta 造成 stream window overflow 时仅 reset stream，未按规范终止 connection，记录为 `H2-021`。
- 2026-08-06：确认 Content-Length 与 DATA 总量不一致时被升级为 connection GOAWAY，而非对应 stream PROTOCOL_ERROR，记录为 `H2-022`。
- 2026-08-06：确认 initial HEADERS admission 顺序使部分 rejected id 可复用、invalid Content-Length 又永久泄漏 streamcount，合并记录为 `H2-023`。
- 2026-08-06：确认 client 的 local-RST tombstone 超过 100 被淘汰后，late HEADERS 在 HPACK 解码前直接 GOAWAY，记录为 `H2-024`。
- 2026-08-06：确认 HTTP/2 preface/SETTINGS/ACK/frame/header-block reads 全部无 progress deadline且配置无入口，记录为 `H2-025`。
- 2026-08-06：确认 client 在 ENABLE_PUSH=0 获 ACK 后仍因缺少 handler 静默忽略 PUSH_PROMISE并跳过 HPACK，记录为 `H2-026`。
- 2026-08-09：完成etcd v3静态审查，确认mutation模糊重试、watch revision/重连/背压、lease单位、timeout、range option、unknown watch ID与安全连接共9项；另记录中英文API文档契约偏差1项。
- 2026-08-09：按用户要求未新增或运行重现、畸形输入和故障注入；首轮全量静态审计收口为141项（P1 68、P2 70、P3 3），无遗留候选，形成五批修复路线。
- 2026-08-09：开始第二轮纯静态查漏；平台层确认nonblocking设置失败不回传、blocking fd仍会进入事件循环，记录为`SOCK-013`。本轮不注入syscall失败。
- 2026-08-09：确认socket/timer共用flip buffer以signed 32-bit计数并无检查倍增，积压接近表示上限时可进入UB、错误realloc或越界copy，记录为`CORE-007`；未制造大队列或运行内存压力复现。
- 2026-08-09：确认worker在sid校验后直接设置slot closing，旧close可跨越socket-thread free/reuse把状态写入新generation，记录为`SOCK-014`；未新增并发barrier。
- 2026-08-09：确认UDP对象不保存bind/connect模式，bound缺destination仍返回成功后静默丢包，connected显式destination又被忽略，记录为`UDP-001`；未发送datagram。
- 2026-08-09：确认TLS listen先发布TCP listener再构造ctx，证书/key/cipher失败会泄漏listener并留下解引用nil的accept回调，记录为`TLS-007`；未加载损坏证书。
- 2026-08-09：确认DNS无条件先查absolute且用ndots决定是否完全跳过search，低点数顺序、高点数fallback和trailing-dot语义均偏离系统resolver，记录为`DNS-004`；未发查询。
- 2026-08-09：确认DNS每项request固定单一server，全部attempt不会遍历nameserver列表，健康备用resolver只能影响后续查询，记录为`DNS-005`；未制造超时或发查询。
- 2026-08-09：确认DNS的TCP fallback connect未继承request deadline，request超时后connect task/socket仍可滞留并发布迟到连接，记录为`DNS-006`；未制造TCP黑洞或TC响应。
- 2026-08-09：确认DNS公开timeout会在每个CNAME hop及search候选重新计时，不能限制整次lookup/resolve耗时，记录为`DNS-007`；未构造慢resolver。
- 2026-08-09：确认DNS parser丢弃negative kind并把NXDOMAIN/NODATA均存为qtype entry，name error无法跨type命中，记录为`DNS-008`；未构造negative响应。
- 2026-08-09：确认DNS中英文reference仍宣称默认三次递增重试，与实现默认两次固定5秒及同页配置表冲突，记录为`DOC-002`；未运行doc示例。
- 2026-08-09：确认cluster accept adapter少接listener id参数，导致incoming peer.remoteaddr保存listener sid并丢弃真实endpoint，记录为`CLUSTER-007`；未建立连接。
- 2026-08-09：确认cluster timeout只覆盖send后的response wait，lazy DNS/TCP connect不继承预算且TCP无timer，记录为`CLUSTER-008`；未连接黑洞endpoint。
- 2026-08-09：确认cluster.send发送普通request且wire无one-way标志，正常handler response会变成unmatched ACK，记录为`CLUSTER-009`；未发送消息。
- 2026-08-09：确认cluster hostname路径硬编码单次A lookup，无AAAA或多地址connect fallback，记录为`CLUSTER-010`；未执行解析或连接。
- 2026-08-09：确认cluster完整帧ring与handler并发无count/byte/admission上限，单个2MiB read可放大为约十万排队帧/慢task，记录为`CLUSTER-011`；未发送burst。
- 2026-08-09：确认cluster收到4-byte合法length即按完整body预分配，默认每连接可占128MiB且无partial deadline/global budget，记录为`CLUSTER-012`；未发送partial frame。
- 2026-08-09：确认HTTP/1 sender把未验证method/path直接格式化进request-line，literal CRLF可注入字段或第二请求，记录为`HTTP1-011`；未发送注入内容。
- 2026-08-09：确认HTTP/1把101仅视为final bodyless response，client可把升级连接归池且server继续HTTP parse loop，记录为`HTTP1-012`；未执行Upgrade。
- 2026-08-09：确认HTTP/1 Connection只做精确close字符串判断且忽略version，token list/大小写/重复及HTTP/1.0默认关闭均失效，记录为`HTTP1-013`；未运行复用连接。
- 2026-08-09：确认HTTP/1 closewrite吞掉write失败且不在response wait前验证fixed-length完整，已知不完整request可造成双方永久等待，记录为`HTTP1-014`；未发送长度不一致消息。
- 2026-08-09：确认HTTP/1 server无interim response状态，Expect双方可互等；client又把首个102/103误作final，记录为`HTTP1-015`；未运行100-continue交互。
- 2026-08-09：确认HTTP client pool lookup会为每个origin写入H1/H2空表，DNS/connect失败不回滚且无timer清理，记录为`HTTPC-003`；未发起高基数请求。
- 2026-08-09：确认HTTP client只取单个A记录且没有AAAA/多地址connect fallback，IPv6-only与首地址故障origin不可用，记录为`HTTPC-004`；未执行DNS或连接。
- 2026-08-09：确认HTTP/1 sender会原样发送TE+CL并因CL优先而直写未分块正文，形成wire framing歧义，记录为`HTTP1-016`；未生成或发送歧义报文。
- 2026-08-09：确认HTTP/1 bodyless response集合遗漏205，client可在合法keepalive 205上等待EOF且server可发送违规content，记录为`HTTP1-017`；未发送205响应。
- 2026-08-09：确认HTTP中英文文档承诺不存在的respond close参数，且H1/H2实际返回契约不一致，记录为`DOC-003`；未调用HTTP API。
- 2026-08-09：确认HTTP/2 server handler异常会绕过closewrite/close，stream map与并发配额永久滞留，记录为`H2-027`；未触发业务异常。
- 2026-08-09：确认HTTP/2 remote GOAWAY/EOF不结束openwaitq，优雅GOAWAY后唤醒还会泄漏reserved streamcount，记录为`H2-028`；未建立满载连接。
- 2026-08-09：确认HTTP/2在connection window为0时，每个stream WINDOW_UPDATE都会重复入队同一blocked writer并永久增持引用，记录为`H2-029`；未发送flow-control frame。
- 2026-08-09：确认HTTP/2 batch flush丢弃TCP/TLS write失败并清空frames，stream API仍按成功推进状态，记录为`H2-030`；未注入发送失败。
- 2026-08-09：确认HTTP/2未限制HEAD/204/205/304的DATA content，client接受并交付且server可主动生成malformed response，记录为`H2-031`；未发送no-content response。
- 2026-08-09：撤回`HPACK-003`：当前`http2_table.h`的code/length数组均只有256项，不含EOS leaf，`i=256`截断前提不存在；原证据误读表规模，统计相应减一。
- 2026-08-09：扩充`H2-017`：完整响应后RST若在对象回收前到达会覆盖成功结果，回收后到达则因nil lookup被误判idle并GOAWAY；未新增计数或发送frame。
- 2026-08-09：扩充`H2-023`：server处理CL1+HEADERS END时会在未发布对象上GOAWAY/清count，随后仍发布并fork handler，收尾可使streamcount为负；未新增计数或发送frame。
- 2026-08-09：确认WebSocket client独立连接路径只取单个A记录且没有AAAA/多地址fallback，记录为`WS-009`；未执行DNS或连接。
- 2026-08-09：确认WebSocket client的DNS/TCP/TLS/Upgrade opening handshake没有端到端deadline或取消入口，记录为`WS-010`；未连接silent peer。
- 2026-08-09：确认plaintext gRPC listener仍把H2 channel与应用stream scheme固定标成https，记录为`GRPC-019`；未启动server。
- 2026-08-09：确认gRPC client对每个target只取单个A记录并永久固定首个IPv4 endpoint，没有AAAA或同名多地址fallback，记录为`GRPC-020`；未执行DNS或连接。
- 2026-08-09：确认gRPC client close不与in-flight newchannel共同串行，close返回后迟到建连仍可发布orphan channel并返回stream，记录为`GRPC-021`；未新增并发barrier。
- 2026-08-09：确认gRPC TLS client/server只配置h2 ALPN却不校验最终协商结果，无ALPN或非h2会话仍进入H2状态机，记录为`GRPC-022`；未建立TLS会话。
- 2026-08-09：确认gRPC中英文reference的API签名及每份14个registrar示例都遗漏必需service_name，照抄无法注册服务，记录为`DOC-004`；未运行文档示例。
- 2026-08-09：确认grpc.listen公开的ciphers/backlog配置在adapter重建option table时被静默丢弃，记录为`GRPC-023`；未创建listener或TLS context。
- 2026-08-09：扩充`GRPC-012`：unary timer在openstream之后才创建，故显式timeout不覆盖DNS/TCP/TLS/H2 handshake；未连接silent endpoint。
- 2026-08-09：确认Redis SUBSCRIBE后没有push reader/subscription state，后续message会与命令response错配且文档示例未实际订阅，记录为`REDIS-007`；未运行Pub/Sub交互。
- 2026-08-09：确认Redis共享连接不隔离MULTI/WATCH会话，其他协程命令可被排入错误事务并改变EXEC结果，记录为`REDIS-008`；未执行事务或并发barrier。
- 2026-08-09：确认Redis中英文pipeline示例使用实现不存在的out参数且select提示写成恒失败无message的assert，记录为`DOC-005`；未运行文档示例。
- 2026-08-09：确认MySQL COM_PING response无条件进入OK decoder，合法ERR可被误报为健康或触发codec异常，记录为`MYSQL-013`；未发送PING。
- 2026-08-09：确认MySQL BEGIN/COMMIT/ROLLBACK把任意非ERR packet当成功并提交本地transaction状态，记录为`MYSQL-014`；未发送transaction命令。
- 2026-08-09：确认MySQL native lenenc把unsigned64长度塞入signed Lua integer且consumer使用可wrap的pos+len/unchecked advance，可绕过边界进入OOB read，记录为`MYSQLC-007`；未构造packet。
- 2026-08-09：确认MySQL metadata/row loops只识别EOF而不识别ERR，native row decoder又不验证0x00 header，错误包可被解析成列或业务row，记录为`MYSQL-015`；未构造packet。
- 2026-08-09：扩充`MYSQLC-003`：binary TIME未限定0/8/12长度，非法值会跨列读取或留下尾字节；未构造row。
- 2026-08-09：确认MySQL broken connection释放open_count后不唤醒capacity waiter，受限pool已有请求可永久等待，记录为`MYSQL-016`；未注入I/O失败或运行barrier。
- 2026-08-09：扩充`MYSQL-001`：checked-out conn的GC只关闭fd、不递减pool.open_count，与idle/lifetime淘汰同样制造幽灵容量。
- 2026-08-09：确认etcd LeaseKeepAlive读失败重连时不关闭旧stream或取消旧sender，每轮会再fork发送task且close只覆盖最新stream，记录为`ETCD-010`；未执行断链或并发测试。
- 2026-08-09：确认etcd watch公开注解中的wait/limit不属于WatchCreateRequest且实现从不消费，编码时被静默丢弃，记录为`ETCD-011`；未建立watch stream。
- 2026-08-09：确认etcd retry按总attempt而非文档所述额外重试实现，retry=0会跳过RPC并返回nil,nil且最终失败后仍sleep，记录为`ETCD-012`；未调用RPC。
- 2026-08-09：确认etcd client关闭后watch仍忽略control-channel push失败并返回成功对象，其read channel没有producer或close路径而永久等待，记录为`ETCD-013`；未执行生命周期交错。
- 2026-08-09：确认旧etcd watch recv在新stream发布后仍可发送无generation的迟到EOS，manager会误关当前健康stream并再次重连，记录为`ETCD-014`；未注入write failure或调度barrier。
- 2026-08-09：扩充`ETCD-012`：LeaseTimeToLive与LeaseLeases完全绕过client retry，和六个手写loop共同形成不一致的重试契约；未调用RPC。
- 2026-08-09：扩充`DOC-001`：双语文档错误宣称grant/revoke自动管理keepalive且newclient失败抛异常，中文还把持续keepalive注册误写成单次发送；未运行文档示例。
- 2026-08-09：确认etcd双语“事务性操作”示例只执行独立get/put且wrapper没有txn方法，无法提供标题承诺的原子多键更新，记录为`DOC-006`；未运行示例或并发writer。
- 2026-08-09：确认HTTP client close可与在途DNS/TCP/TLS/H2建连交错，返回后迟到连接仍发布到H1/H2 pool并继续request，记录为`HTTPC-005`；未建立连接或运行barrier。
- 2026-08-09：确认TLS reload先原地污染保存配置再构造ctx，失败会assert且留下旧ctx与新坏conf的混合状态，记录为`TLS-008`；未加载损坏配置。
- 2026-08-09：第二轮纯静态查漏收口；主报告与HANDOFF自动核对均为196项（P1 83、P2 105、P3 8），编号唯一、索引与模块统计一致，当前范围无未归档候选。
- 2026-08-09：继续审阅远端`cluster`分支时确认`testcluster.lua`随机分片完整性断言从未执行相等比较，且同一缺口也存在于`master`，记录为`CLUSTER-013`；仍未运行测试或新增重现代码。
- 2026-08-09：完成`origin/cluster@0f2c8773`专项复核；确认eager `cluster.connect`没有deadline/cancel入口且未转发底层已有connect timeout，作为分支独有`CLUSTER-B001`归档，不计入master基线统计。
- 2026-08-12：继续复核cluster配置与timer边界，确认timeout直到request发出后才由`time.after`验证，非法值可形成远端已执行、本地抛错及重试歧义，记录为`CLUSTER-014`；未发送请求。
- 2026-08-12：确认`cluster`分支raw-string API迁移遗漏logging/trace/errno的中英文示例，记录为分支独有`CLUSTER-B002`；未执行文档示例。
- 2026-08-12：确认同一data batch中先完成frame再遇解析错误时，Lua关闭分支不会dispatch或清除已入全局ring的完整frame，记录为`CLUSTER-015`；未构造混合frame。
- 2026-08-12：确认`cluster`分支的send已无yield路径，但中英文reference仍声明必须由`task.fork`调用，记录为分支独有`CLUSTER-B003`。
- 2026-08-12：确认分支新增late-response测试不观察task异常，旧nil-wakeup缺陷可在测试仍通过时只留下错误日志，记录为`CLUSTER-B004`。
- 2026-08-12：完成cluster分支第三轮静态收口；远端尖端仍为`0f2c8773`，落后的3个master提交不含共享运行时修复，当前专项范围无未归档候选。
- 2026-08-12：继续第三轮重点模块查漏，确认HTTP/2同一stream的并发读取会覆盖唯一waiter，且旧timer可误唤醒新reader，记录为`H2-032`；未运行并发barrier或协议流量。
- 2026-08-12：确认gRPC request超限/压缩错误在initial metadata发送后再次调用respond，生成含`:status`的非法final HEADERS，记录为`GRPC-024`；未发送超限或压缩消息。
- 2026-08-13：确认native protobuf message循环把截断tag、field 0和unknown value skip失败当作正常EOF，gRPC会把非法request交给业务或接受非法response；归档为`GRPC-025`，未构造畸形payload。
- 2026-08-13：修正并补强`GRPC-007/015`的protobuf证据：known-field decode失败会抛Lua异常而非返回nil；server unary/sstream因此叠加`H2-027`配额泄漏，client公开read则越过status契约直接抛错。不重复计数。
- 2026-08-13：确认多target client在任一DNS失败时整体拒绝构造，运行期也机械选择未连接endpoint并在其dial失败后终止本次RPC，不在READY backends间轮询；归档为`GRPC-026`。
- 2026-08-13：确认native protobuf embedded-message解析直接C递归且没有depth budget，4 MiB request内即可形成远超安全stack的层数；归档为`GRPC-027`，未生成深层payload。
- 2026-08-13：确认native protobuf codec把schema `string`与`bytes`合并为同一裸字节路径，收发均不验证UTF-8；归档为`GRPC-028`，未编码非法序列。
- 2026-08-13：确认native descriptor把proto2 required/optional共同折叠为非repeated，codec无法执行required presence检查，缺字段message仍可进入业务/上wire；归档为`GRPC-029`。
- 2026-08-13：确认四类RPC均无公开metadata/call-context入口，server也无法正常读取request或发送initial/trailing metadata，`-bin`没有Base64语义；归档为`GRPC-030`。
- 2026-08-13：确认gRPC双语reference把client/server/bidi streaming混成统一API，server-stream调用不存在的write，client-stream upload以RST close代替EOS/final response；归档为`DOC-026`。
- 2026-08-13：确认`grpc.listen`直接返回只拥有listen fd的底层listener，accepted H2 channels无server owner；close返回后既有连接仍可无限创建新RPC，归档为`GRPC-031`。
- 2026-08-13：确认protobuf encode类型/schema错误直接抛异常，多个gRPC wrapper因此越过公开错误tuple、timer取消、final status与H2 stream回收；归档为`GRPC-032`，未编码错误对象或建立RPC。
- 2026-08-13：确认native protobuf scalar encoder对32/64位整数、enum与bool缺少schema域校验，边界外/错误类型输入会被静默截断或改义；归档为`GRPC-033`，未编码这些输入。
- 2026-08-13：确认三种streaming client不通过公开read返回值交付最终非OK status，失败会表现为普通EOF，client-streaming还可返回成功对象；归档为`GRPC-034`，未建立错误stream。
- 2026-08-13：确认native protobuf oneof decoder只更新case而不清除旧member，sender也会编码table中的多个members，破坏last-one-wins不变量；归档为`GRPC-035`，未加载oneof schema。
- 2026-08-13：确认native protobuf decoder对重复singular embedded message整块覆盖而非递归merge，合法拆分字段会静默丢数据；归档为`GRPC-036`，未构造重复field payload。
- 2026-08-13：确认native protobuf parser用descriptor packed flag限制接收格式，`packed=false` repeated numeric会拒绝规范要求兼容的packed wire；归档为`GRPC-037`，未构造payload。
- 2026-08-13：补强`GRPC-025`的map-entry证据：其循环同样接受截断tag，且unknown field不skip value、会把value误作后续tag；不重复计数。
- 2026-08-13：补强`GRPC-023`：双语配置表还公开`alpnprotos`，adapter同样忽略并固定h2；建议删除override而不是静默接受，不重复计数。
- 2026-08-13：补强`GRPC-027`：native encoder也对递归schema的深层/自引用Lua table做无界C递归；与decoder共享depth budget根因，不重复计数。
- 2026-08-13：确认bundled protoc拒绝合法proto2 group语法，外部descriptor即便加载后native codec也对known group收发抛unknown type；归档为`GRPC-038`，未加载schema或构造wire。
- 2026-08-13：完成gRPC封板审计：7个Lua模块、native protobuf收发/descriptor、四类RPC、9组测试、LuaLS及双语1758行reference全部映射；新增`GRPC-025`至`GRPC-038`与`DOC-026`，health/reflection/keepalive/automatic retry因无公开承诺列为可选能力而非缺陷，阶段无未归档候选。
- 2026-08-13：确认RESP aggregate把嵌套error降为普通string并只保留整组AND状态，EXEC/nested结果无法定位错误或区分同文正常值；归档为`REDIS-010`，未执行事务。
- 2026-08-13：完成Redis封板审计：`redis.lua`全部353行、18组`testredis.lua`、134行fake server及双语各851行reference均已逐项映射；`MONITOR`/RESP3 push并入`REDIS-007/001`而不重复计数，阻塞命令、pipeline写序、断线后不重放已排除为新问题，阶段无未归档候选。
- 2026-08-13：确认initial handshake宣告`sha256_password`时driver仍生成mysql_native SHA-1 token，只有auth-switch分支实现RSA exchange，合法账号可确定性认证失败；归档为`MYSQL-020`，未创建账号或连接server。
- 2026-08-13：确认capability协商前initial ERR没有SQLSTATE，但native parser无条件消费一个marker byte且不回退，message首字节丢失、空message抛异常；归档为`MYSQLC-008`，未构造packet。
- 2026-08-13：确认MySQL双语连接池指南在Lost connection后重连并无条件重放任意SQL，commit后丢回包可重复执行非幂等写并丢失session状态；归档为`DOC-027`，未执行SQL或断线。
- 2026-08-13：确认MySQL双语reference/连接池guide的健康检查、预热和监控调用不存在的`silly.wait/sleep/time`并遗漏task import，首次运行即失败；归档为`DOC-028`，未执行示例。
- 2026-08-13：确认MySQL双语reference声明row key为小写，但native codec原样使用server column alias，混合case字段按文档访问会静默得到nil；归档为`DOC-029`，未执行查询。
- 2026-08-13：确认MySQL双语事务教程用普通非锁定SELECT校验余额，并把零行UPDATE当成功；并发转账可透支，收款账户缺失可只扣不加，归档为`DOC-030`，未执行SQL或并发barrier。
- 2026-08-13：扩展`DOC-027`证据：双语通用错误处理指南还有第二个接受任意SQL的2006/2013自动重试wrapper，即使注释未实现重建，也会在结果未知后重新调用原statement；不重复计数。
- 2026-08-13：扩展`DOC-028`到全部MySQL文档调用面：六份双语文件共60行不存在的`silly.wait/sleep/time`，另有把signal函数当object及错误`INT`名称、standalone block缺task/time import；不重复计数。
- 2026-08-13：确认MySQL双语监控在调用pool query前连续采集wait/query时间戳，所谓等待几乎恒为零，真实checkout排队全被误算成SQL执行；归档为`DOC-031`，未运行计时或并发barrier。
- 2026-08-13：补强`MYSQL-012`：AuthSwitch的plugin data按规范是EOF opaque bytes，代码却无条件删除末byte；initial response多数capability也未取server交集，未知plugin名与native token可不一致；不重复计数。
- 2026-08-13：补强`MYSQLC-002`：OK packet的affected_rows和last_insert_id同样是unsigned lenenc，超过Lua signed范围也会wrap为负，影响业务行数/主键判断；不重复计数。
- 2026-08-13：补强`MYSQL-015`：prepare非OK首包一律按ERR解码，metadata reader完全忽略已声明param/field count而读到EOF，少/多definition均可跨phase反同步；不重复计数。
- 2026-08-13：补强`MYSQL-010`：握手无条件宣告MULTI_STATEMENTS/MULTI_RESULTS，名为multi support的Test 27却明确只测单条SELECT，无法覆盖stored-program多结果与response drain；不重复计数。
- 2026-08-13：确认MySQL死锁重试示例只捕获Lua异常，丢弃driver按正常返回值交付的callback SQL错误并继续commit，可部分提交事务且语句阶段1213不会重试；归档为`DOC-032`，未执行事务。
- 2026-08-13：确认MySQL双语连接池指南声称max_idle_conns=0为无限，实际return条件与两组test都明确把0当作no cache；默认配置每次query重连，归档为`DOC-033`，未建立连接。
- 2026-08-13：确认MySQL唯一inline LuaLS把row全部值标为string，并把native/test/reference实际公开的err.sqlstate拼成不存在的sql_stage；归档为`DOC-034`，未运行type checker。
- 2026-08-12：确认etcd client关闭后keepalive仍静默写registry但没有存活owner，lease可在调用“成功”后到期，记录为`ETCD-015`；未等待lease或运行close竞态。
- 2026-08-12：确认MySQL transaction conn没有command并发门禁，第二协程可先写命令再触发single-reader断言并留下错配response，记录为`MYSQL-017`；未运行并发barrier或数据库请求。
- 2026-08-12：确认MySQL pool以array尾部pop实现waiter handoff，持续新请求可让最旧waiter无限饥饿，记录为`MYSQL-018`；未运行连接池压力或barrier。
- 2026-08-12：确认Redis client固定明文TCP，非空AUTH credential与全部command/data无法通过TLS保护，也不能接入TLS-only部署，记录为`REDIS-009`；未建立TLS或发送credential。
- 2026-08-12：确认MySQL checkout用returned_at而非created_at判断max_lifetime，持续繁忙连接可无限超过轮换上限，记录为`MYSQL-019`；未运行计时或数据库连接测试。
- 2026-08-12：确认HTTP/2合法SETTINGS下调可使stream window为负，下一次write把负值作为DATA length交给builder并抛异常，记录为`H2-033`；未发送frame或运行互操作。
- 2026-08-12：确认HTTP/2 client/server都接受ACK-only SETTINGS作为对端连接前言，记录为`H2-034`；未建立peer或发送frame。
- 2026-08-12：确认etcd watch compaction取消会丢弃完整WatchResponse及`compact_revision/cancel_reason`，记录为`ETCD-016`；未建立watch或请求compaction。
- 2026-08-12：第三轮HTTP/2、gRPC、etcd、MySQL、Redis纯静态查漏收口；再次核对协议状态机、并发waiter、close/reconnect、事务/连接池及未处理I/O返回路径，当前范围无未归档的高置信独立候选。动态互操作、并发barrier和故障注入仍按用户要求留到修复阶段。
- 2026-08-13：1.0封板审计确认`multipack/tcpmulticast`以调用方声明的未来finalizer次数管理裸pointer，send失败后重试或fanout偏小可提前free仍在异步发送的buffer，记录为`NET-003`；未调用multicast或制造失效socket。
- 2026-08-13：确认POSIX合法fd 0在异步TCP connect完成读取SO_ERROR时命中`assert(fd>0)`并终止进程，记录为`SOCK-015`；未关闭stdin或建立连接。
