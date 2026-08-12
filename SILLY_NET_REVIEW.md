# Silly `net` 全量审计记录

> 状态：两轮全量纯静态审计已完成；当前范围无未归档候选
> 审计日期：2026-08-06 至 2026-08-09
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

WebSocket 审计清单（状态：首轮静态核对完成；修复阶段补独立peer与畸形输入）：

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
| RFC9113-5.2/6.9-RECV-FLOW-CONTROL | MUST/security | `lualib/silly/net/http/h2.lua:151-207,239-263,479-482,502-542,1177-1204` | client/server recipient | 偏离 | channel/stream 没有剩余 receive-window 状态；DATA 无条件 append，仅累计将来回补的 debt，超过已广告 credit 也不会报 `FLOW_CONTROL_ERROR` | 现有测试只覆盖守规发送方和正常 1 MiB 消息，没有超 window DATA | H2-003 |
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
| RFC9113-5.1.1/5.1.2/8.1.1-REQUEST-ADMISSION | MUST | `lualib/silly/net/http/h2.lua:453-495,845-894,1038-1080,1562-1648` | server recipient | 偏离 | initial HEADERS admission非事务：拒绝可复用id/泄漏quota；early END长度不符在teardown后仍发布并调用handler | 现有malformed tests未检查id/quota/handler隔离 | H2-023 |
| RFC9113-5.1/5.4.2-CLOSED-HPACK | MUST | `lualib/silly/net/http/h2.lua:1038-1080,1446-1499`; `luaclib-src/lhttp.c:692-780` | client recipient | 偏离 | local RST tombstone 固定只留 100 个；淘汰后 late HEADERS 在 HPACK 前直接 GOAWAY，未 minimally process compression state | 现有测试没有 >100 cancel 后 delayed response headers | H2-024 |
| RFC9113-10.5-PROGRESS-LIMITS | SHOULD/security | `lualib/silly/net/http/h2.lua:268-365,1420-1547,1668-1738`; `lualib/silly/net/http.lua:10-45`; `lualib/silly/net/http/client.lua:206-274` | client/server | 偏离 | preface/SETTINGS/ACK/frame body/CONTINUATION 所有 read 均无 progress deadline，配置也无入口 | 现有测试不覆盖 slow preface/frame/header block | H2-025 |
| RFC9113-6.6/8.4-PUSH-DISABLED | MUST | `lualib/silly/net/http/h2.lua:1500-1547` | client recipient | 偏离 | client 广告 ENABLE_PUSH=0 并获 ACK 后仍静默忽略 PUSH_PROMISE；未报 PROTOCOL_ERROR且未处理 HPACK/stream state | 现有测试没有 disabled-push violation | H2-026 |
| RFC7541-5.1-INTEGER-LIMITS | MUST/safety | `luaclib-src/lhttp.c:558-583,613-630,696-771` | HPACK decoder | 偏离 | varint continuation/value 无上限，移位可有符号溢出或超过位宽；unsigned 结果缩成 int 后作为 string pointer/length，未按 decoding error 拒绝 | 现有测试没有超长/溢出/未终止 varint；本轮按要求不新增复现 | HPACK-002 |
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
| GRPC-HANDLER-EXCEPTION-STATUS | MUST/interoperability | `lualib/silly/net/grpc/registrar.lua:80-228` | server | 偏离 | 四种 wrapper将 application handler抛出异常统一映射 INTERNAL；gRPC library-generated mapping要求 UNKNOWN | 无 handler throw status-code assertion | GRPC-016 |
| GRPC-STATUS-SENDER | MUST | `lualib/silly/net/grpc/registrar.lua:80-228`; `luaclib-src/lhttp.c:489-548` | server sender | 偏离 | application `err.code` 无类型/range/canonical校验，truthy值直接经通用字符串化写 grpc-status；可发送非法文本或error+OK | 自测仅覆盖0与合法常量 | GRPC-017 |
| GRPC-REQUEST-EOS-DATA | MUST | `lualib/silly/net/grpc/client/service.lua:65-70,215-257`; `lualib/silly/net/http/h2.lua:992-1025` | streaming client sender | 偏离 | client/bidi零消息closewrite时pending request header直接带END_STREAM；未发送gRPC要求的空DATA+END_STREAM | tests的client/bidi均先write至少一条 | GRPC-018 |
| GRPC-CLEARTEXT-SCHEME | transport/API | `lualib/silly/net/grpc/server.lua:38-55`; `lualib/silly/net/http/h2.lua:231-262,456-467,1730-1739` | plaintext server | 偏离 | cleartext gRPC listener仍把H2 channel/stream scheme写死为https，与收到的`:scheme: http`及实际TCP安全属性矛盾 | 现有handler不检查stream.scheme，明文自测无法暴露 | GRPC-019 |
| RFC8305-3/4-CONNECT-RACING | SHOULD | `lualib/silly/net/grpc/client/conn.lua:16-29,49-79,127-155`; `lualib/silly/net/dns.lua:588-654` | client | 偏离 | 每个target固定单次A lookup并永久只保存首个IPv4 endpoint，无AAAA或同名多地址fallback | 单地址/IPv4本机自测不能覆盖AAAA-only或首地址故障 | GRPC-020 |
| GRPC-CLIENT-CLOSE-LIFECYCLE | safety/concurrency | `lualib/silly/net/grpc/client/conn.lua:44-117` | client | 偏离 | close不与in-flight newchannel共锁；close返回后迟到建连仍可向已摘除endpoint发布channel并返回stream | 普通串行close无法覆盖connect yield窗口 | GRPC-021 |
| GRPC-TLS-ALPN-H2 | MUST/interoperability | `lualib/silly/net/grpc/client/conn.lua:49-79`; `lualib/silly/net/grpc/server.lua:38-55`; `lualib/silly/net/tls.lua:198-204,250-258,464-466`; `lualib/silly/net/http/client.lua:243-279` | TLS client/server | 偏离 | 双方只配置h2 ALPN但不核对最终选择；无ALPN/非h2会话仍直接进入H2 handshake/parser | 同库双方总提议h2，不能覆盖legacy/misconfigured TLS peer | GRPC-022 |
| GRPC-LISTEN-CONFIG | API/security | `lualib/silly/net/grpc/server.lua:29-55`; `lualib/silly/net/tls.lua:326-365`; `lualib/silly/net/tcp.lua:152-175`; `docs/src/en/reference/net/grpc.md:146-166` | server | 偏离 | 公开ciphers/backlog配置被adapter静默丢弃，TLS policy与listen queue不按调用方设置生效 | 默认配置自测不会检查实际ctx/listener option | GRPC-023 |
| GRPC-LENGTH-PREFIXED-MESSAGE | MUST | `lualib/silly/net/grpc/helper.lua:6-67`; `lualib/silly/net/http/h2.lua:1084-1105,1177-1204` | client/server | 基础格式符合 | writer使用1-byte flag+4-byte big-endian length；reader exact-size读取可跨任意DATA边界重组。压缩语义、上限、parse status另见GRPC-004/005/007/015 | 正常测试覆盖unary/三种streaming与1 MiB message | — |
| GRPC-NORMAL-RESPONSE-TRAILERS | MUST | `lualib/silly/net/grpc/registrar.lua:80-228`; `lualib/silly/net/http/h2.lua:992-1025` | server sender | 正常路径符合 | normal success/application error在initial response headers后以最终HEADERS+END_STREAM发送grpc-status；parse/exception/status-code偏离另行编号 | 现有正常与application error用例覆盖 | — |
| GRPC-CUSTOM-METADATA | optional/API | `lualib/silly/net/grpc/client/service.lua`; `lualib/silly/net/grpc/registrar.lua` | client/server | 未公开支持 | API没有传入/取出initial/trailing metadata的参数或context；因此也未实现`-bin` base64 codec。协议允许零metadata，不单独记MUST偏离，但属于跨实现功能缺口 | 无metadata tests | — |
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
- 位置：全局client context创建在`luaclib-src/ltls.c:217-230`；TLS对象/SNI设置在`:458-496`；Lua公开connect options在`lualib/silly/net/tls.lua:284-330`；文档示例在`docs/src/reference/net/tls.md:176-233,350-382`。
- 触发：任何`silly.net.tls.connect`（以及使用它的HTTPS/WSS/gRPC client）连接到攻击者、错误配置或被DNS/路由劫持的endpoint；peer提供任意自签名、过期、不受信任或hostname不匹配的证书。即使调用方传入正确`hostname`也会触发，因为该参数只用于SNI。
- 影响：链路虽然加密但没有服务端身份认证；主动中间人可终止并重新建立TLS，读取或篡改HTTP凭据、cookies、gRPC metadata及应用数据。API/文档把该连接描述为TLS/HTTPS且没有“不安全模式”警告，调用方也没有可用选项自行开启验证。
- 证据：`lctx_client`只调用`SSL_CTX_new(TLS_method())`，从未调用`SSL_CTX_set_verify(...SSL_VERIFY_PEER...)`、`SSL_CTX_set_default_verify_paths`或加载CA。`ltls_open`对hostname只调用`SSL_set_tlsext_host_name`，没有`SSL_set1_host/SSL_set1_ipaddr`，握手成功路径也不检查`SSL_get_verify_result`。整个Lua conf没有CA、verify或expected-name字段。
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
- 证据：`conn.close`立即清Lua状态后调用`net.close(fd)`，从不访问`s.ssl`；native模块全文没有`SSL_shutdown`。GC只`SSL_free`内存对象，既不drain out BIO也不发送alert。OpenSSL quiet-shutdown也未配置，因此不是一个显式、受约束的兼容模式。
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
- 影响：成功协商已被BCP禁止的旧TLS版本，继承其过时算法/协议风险；同一应用在不同OpenSSL版本或系统配置上安全基线漂移。配置API也无法把minimum提升到TLS 1.3或为受控legacy场景显式声明例外。
- 证据：server唯一版本调用是`SSL_CTX_set_min_proto_version(ptr,TLS1_1_VERSION)`且忽略返回值；client context没有任何min/max调用。`TLS_method()`本身是version-flexible method，不等价于TLS 1.2 minimum。Lua conf只暴露cipher/cert/ALPN。
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

### REDIS-007 — P2 — Pub/Sub push 没有专用 reader，后续消息会与命令响应错配

- 状态：已确认；RESP2 subscribed-mode语义、单response command wrapper与公开文档的确定性静态核对。本轮不连接Redis或发布消息。
- 规范：Redis RESP2在`SUBSCRIBE/PSUBSCRIBE`后进入subscribed mode：首次返回订阅确认，之后server可在没有对应request的情况下持续推送`message/pmessage/subscribe/...`数组；client必须以独立push reader交付这些消息，并只允许该模式规定的命令，不能继续按严格request→one response配对。
- 位置：所有命令共用的一次write/一次`read_response` wrapper在`lualib/silly/store/redis.lua:266-303`，reader token队列在`:238-264`；对象没有push/read subscription API，文件到`:351`结束。中英文文档宣称所有标准命令并给出Pub/Sub章节，见`docs/src/reference/store/redis.md:49-57,224-232,665-701`与英文同名文档。
- 触发：调用`subscriber:subscribe("news")`取得确认后，server推送一条message；应用随后调用订阅态允许的`PING`、`UNSUBSCRIBE`或再次`SUBSCRIBE`，或错误地尝试普通命令以读取下一结果。
- 影响：第一条SUBSCRIBE只消费确认并执行`wakeup_next_reader`，后续push留在socket buffer且没有公开读取入口。下一命令的`read_response`会消费最早push并把它作为该命令结果返回，真实command response继续滞后，之后每次调用都可能错一拍；消息无法可靠交付，unsubscribe count/state也无法跟踪。若应用从不再调用命令，push则在无上限TCP buffer路径持续积累。
- 证据：动态method对任何命令完全相同：write一次、取得reader ownership、read一个RESP value、立即释放ownership。代码没有subscribe mode flag、后台read loop、push callback/channel、allowed-command gate或reconnect后的resubscribe逻辑。reference的“发布订阅”示例创建subscriber但从未调用subscribe或读取message，只用另一连接publish，因此无法验证所宣称能力。
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

### MYSQLC-002 — P2 — BIGINT UNSIGNED 经 signed lua_Integer 返回为负值

- 状态：已确认；C integer conversion与Lua数值范围静态核对。不需要网络复现。
- 规范：MySQL binary protocol的`MYSQL_TYPE_LONGLONG`配合UNSIGNED flag表示完整64-bit unsigned范围；client不能把`2^63..2^64-1`静默解释为负的signed值，无法原生表示时应返回decimal string/typed value或显式范围错误。
- 位置：`binary_read_uint64le`在`luaclib-src/mysql/binary.h:107-119`；unsigned LONGLONG dispatch在`luaclib-src/mysql/lmysql.c:343-383`；现有边界测试在`test/testmysql.lua:9-23,128-365`。
- 触发：prepared SELECT返回值大于`9223372036854775807`的`BIGINT UNSIGNED`，包括常见id/bitmask/counter最大值。
- 影响：值发生模2^64符号wrap，例如`18446744073709551615`返回`-1`；应用可能进行错误的排序、权限bit判断、游标/主键续查和账务计算，写回时又作为signed LONGLONG发送，造成不可逆数据错误。
- 证据：reader构造`uint64_t`后以`lua_Integer`返回；parse_field在UNSIGNED分支直接`lua_pushinteger`。64-bit Lua integer只有signed范围，代码没有range check或alternate representation。测试中的`0xFFFFFFFFFFFFFFFF`在Lua同样解释为`-1`，未比较真实decimal语义。
- 根因：wire unsigned domain被强制映射到较窄的signed native domain，类型签名隐藏了不可表示区间。
- 建议解法：若值<=LUA_MAXINTEGER可返回integer；否则默认返回精确decimal string或`mysql.uint64` typed userdata/table，并在文档稳定约定。提供显式lossy-number opt-in也必须标注；parameter side增加相同typed value编码能力。
- 回归测试：修复阶段覆盖`2^63-1/2^63/2^64-1`及round-trip parameter，分别验证signed与unsigned column；测试用decimal string/byte pattern建立期望，不能再用会wrap的Lua hex literal。

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
- 位置：capability flags在`lualib/silly/store/mysql.lua:152-167,414-436`；execute response与result loop在`:898-945`；OK/EOF parsers在`luaclib-src/mysql/lmysql.c:64-135`。
- 触发：prepared `CALL`、stored procedure/OUT parameter或其他server response产生多个result/closing OK；第一个response本身为带MORE flag的OK也可触发。
- 影响：首个OK路径立即return且不检查`server_status`，剩余packet留在socket；row EOF带MORE时则继续用旧`cols`把下一result的column-count/OK当binary row解析。异常路径未必标broken，to-be-closed lease会把反同步connection归池，下一无关query读取上一调用的packet，造成跨请求结果错配、数据泄露和业务误提交。
- 证据：`:910-912`只`parse_ok_packet`后return；EOF分支仅在MORE flag为0时break，为1时不重新进入“read result header/metadata”状态。返回类型也只能表达一个`ok_packet|row[]`，没有results collection/iterator。driver还宣告multi capability却没有完整consumer。
- 根因：把MORE理解为“当前rows继续”而不是“当前logical result结束、另一个result开始”；connection归池前没有统一的response-drained invariant。
- 建议解法：实现外层results loop，每轮解析OK/ERR或完整binary result，检查其终态status后决定继续；API返回result list/iterator，并提供显式drain。若暂不支持，不能宣告相关capability，且遇MORE必须完整discard或关闭连接。任何parser exception/未消费结果标broken。
- 回归测试：修复阶段覆盖`CALL`返回0/1/2 result、OUT params、result+closing OK、首个OK+more及中途ERR；随后立即在同一pool发marker query，断言结果不串线。当前不创建procedure。

### MYSQL-011 — P1 — codec/unpack 异常绕过 broken cleanup，login 泄漏容量、query 归池坏连接

- 状态：已确认；Lua exception unwinding与connection lifecycle静态推导。本阶段不发送畸形handshake/result。
- 位置：`read_packet/_mysql_login`与大量`strunpack`在`lualib/silly/store/mysql.lua:313-774`；C codec调用在`:776-945`；`conn_close`归池条件在`:985-1014`；`conn_new` login在`:1048-1079`；pool query的`<close>`在`:1173-1189`。
- 触发：peer发送截断handshake/auth/prepare metadata、非法lenenc/column/binary row或任何令C codec/`string.unpack`抛Lua error的packet，而不是底层read返回nil。
- 影响：login阶段异常从`_mysql_login`直接穿出，`conn_new`已增加open_count且创建fd，但不会执行`conn_close`；最终`__gc`至多关闭fd、不递减open_count，受限pool可永久假满。query阶段异常触发lease的`__close`，但codec没有设置`conn.is_broken`，所以反同步socket被交给waiter/idle，下一请求读取残余旧response，造成结果串线和重复异常。
- 证据：parser APIs以`luaL_error/error`报告bounds/format问题，调用点无`pcall/xpcall`或finally标broken。只有`read_packet` I/O nil和write failure显式设置broken；`cmt.__gc`只close fd，不更新pool counter。`conn_close`默认把`is_broken=false`连接复用。
- 根因：error model混用return-value与exception，但资源/health transition只覆盖前者；缺少“开始解析peer response后，任意非成功退出都fatal”的统一guard。
- 建议解法：在connect/login/query最外层使用protected cleanup guard：创建后立即登记connecting资源，任意异常原子标broken、物理关闭、递减capacity并转换成structured ERR；只有完整消费且验证终态后commit健康状态。C codec可改为`nil,error`，但仍需finally防守应用/runtime异常。
- 回归测试：修复阶段在每个handshake/prepare/column/row字段边界截断并触发各codec error，断言无异常越出public API、fd/open_count恢复、连接不入idle，后续query新建干净连接。当前不生成畸形packet。

### MYSQL-012 — P2 — handshake auth seed 用错 capability 且固定读取 12 bytes

- 状态：已确认；HandshakeV10 layout与parser静态核对。
- 规范：[MySQL HandshakeV10](https://dev.mysql.com/doc/dev/mysql-server/8.0.46/page_protocol_connection_phase_packets_protocol_handshake_v10.html)按`auth_plugin_data_len`定义part-2长度；[MariaDB connection protocol](https://mariadb.com/docs/server/reference/clientserver-protocol/1-connecting/connection)明确part 2由`CLIENT_SECURE_CONNECTION`控制，而`PLUGIN_AUTH_LENENC_CLIENT_DATA`控制的是client handshake response中auth data的长度编码。
- 位置：capability constants在`lualib/silly/store/mysql.lua:152-167`；initial handshake解析在`:359-403`；client response flag/format在`:414-465`。
- 触发：server支持SECURE_CONNECTION/PLUGIN_AUTH但不支持PLUGIN_AUTH_LENENC_CLIENT_DATA，或auth plugin data长度不是代码假定的20-byte seed/12-byte part 2；合法旧版、代理或其他auth plugin可出现。
- 影响：driver遗漏part 2而用8-byte seed计算native/caching token，或从seed中间解析plugin name，导致合法server认证失败；固定offset还可能把NUL/plugin name切错并触发unpack异常。对未知plugin代码又默认计算mysql_native token却宣告原plugin，进一步制造不一致握手。
- 证据：`:373`以`CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA`决定是否读取server seed part 2；内部`local len = 12`完全忽略已解析的`auth_plugin_data_len`和SECURE_CONNECTION。之后若PLUGIN_AUTH存在便从该假定offset读取NUL string。
- 根因：把server handshake字段presence、client response encoding和具体plugin seed长度合并成一个MySQL-8特例。
- 建议解法：按negotiated capability逐字段、remaining length和advertised auth length解析HandshakeV10；part 2长度使用规范公式并安全处理terminating NUL，再把完整plugin data交给plugin-specific handler。client flags取双方intersection，未知plugin明确拒绝或走实现的auth-switch机制。
- 回归测试：修复阶段构造SECURE/PLUGIN_AUTH/LENENC三flag组合及auth length 0/9/20/21/其他plugin，分别与MySQL 5.7/8和MariaDB代理互操作；当前不新增handshake fixture。

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

### MYSQL-015 — P1 — result metadata/row loops 不识别 ERR，错误包可被解析为列或业务数据

- 状态：已确认；prepared-result packet phase、Lua discriminator与native row header处理的确定性静态核对。本轮不构造result/ERR packet。
- 规范：MySQL command/resultset各阶段允许的packet类型必须按phase和首字节分派；ERR(`0xff`)表示当前command失败并终止结果，不能进入ColumnDefinition或Binary Protocol Resultset Row decoder。binary row还必须验证首字节header为`0x00`，而不是盲目跳过任意byte。
- 位置：column-definition循环在`lualib/silly/store/mysql.lua:776-797`，execute首响应与row循环在`:898-945`；native binary row入口在`luaclib-src/mysql/lmysql.c:430-470`，column decoder在`:216-257`。
- 触发：server/proxy在metadata或row phase返回ERR；或连接已因MYSQL-010等未排空response而让当前loop读到上一command的ERR/其他packet。恶意peer也可构造以0xff开头、后续字节恰能满足当前columns的payload。
- 影响：metadata ERR被送进column parser并通常抛异常，随后触发MYSQL-011的坏连接清理问题；row-phase ERR则被当binary row，decoder跳过0xff后把errno/SQLSTATE/message字节解释成NULL bitmap和字段，可能向应用返回伪造业务row。若解析后遇EOF，query甚至可报告成功并把connection归池；否则异常/残余packet造成跨请求结果串线。
- 证据：`recv_col_def_packet`只有`if first==EOF then break`，其余一律`parse_column_def(data)`；row loop同样只有EOF分支，其余一律`parse_row_data_binary(data,cols)`。C row decoder在`:439-444`仅`chk.pos += 1`，从不检查被跳过的byte是0x00。只有execute的第一个packet在进入resultset前检查ERR，后续phase没有同样dispatcher。
- 根因：result consumer把“非terminator”视作目标数据packet，没有为每个phase声明完整allowlist；native typed decoders也不验证discriminator，无法防守调用层遗漏。
- 建议解法：实现显式result state machine：每个read先统一识别ERR并终止，metadata只接受合法ColumnDefinition和规定terminator，row phase只接受0x00 binary row及合法terminator/ERR；未知type标protocol-fatal并关闭。所有native parser验证header/type，完整response验证后才允许lease归池。
- 回归测试：修复阶段在首response、每个column位置、metadata terminator前后、首/中/末row注入合法ERR及未知type；断言ERR结构化返回、绝不生成row、连接按同步状态关闭/不归池，随后marker query不串线。当前不注入packet。

### MYSQL-016 — P1 — broken connection 释放 capacity 后不唤醒 waiter，受限 pool 可永久停住

- 状态：已确认；max-open acquire queue、broken return与capacity accounting的确定性静态时序。本轮不注入I/O失败或运行并发barrier。
- 位置：capacity wait在`lualib/silly/store/mysql.lua:1016-1055`；healthy handoff与broken physical close在`:985-1014`；query lease自动归还在`:1173-1189`。
- 触发时序：配置`max_open_conns=1`；task A取得唯一connection执行query，task B进入`waiting_for_conn`并`task.wait()`；A发生read/write failure使`conn.is_broken=true`，scope收尾调用`conn_close(A)`。
- 影响：broken fd和`open_count`被正确释放到0，但B永远没有被唤醒去创建替代connection；若没有第三个新请求，B永久挂起。即使第三个请求C后来看到count=0并成功建连，B也要等C归还后才可能取得connection，形成违反队列顺序的饥饿和无谓延迟。单次连接故障可令已有业务请求停滞。
- 证据：`conn_close`只有在`not pool.is_closed and not conn.is_broken`的healthy分支才检查`waiting_for_conn`并wake一个coroutine；broken/closed分支直接`open_count=open_count-1`、关闭fd后return，没有把“可创建一个新连接”的permit交给waiter。`conn_new` waiter没有timer或其他自唤醒机制，pool_clear也只处理idle数组。
- 根因：wait queue只支持把现成healthy connection直接handoff，不支持capacity释放事件；计数递减、fd销毁和waiter调度没有由统一pool state transition维护。
- 建议解法：任何物理销毁导致`open_count`下降后，若pool仍开放且有waiter，应以structured capacity permit唤醒最早waiter，让其在generation/closed复查后创建connection；或由pool内单一acquire scheduler统一决定handoff/新建。使用FIFO、可取消waiter，并避免多次释放同一permit造成超max。
- 回归测试：修复阶段以max_open=1/2覆盖唯一checked-out连接在write/read/login/expiry时销毁且已有1/N waiters；断言最早waiter立即获得create permit、open_count不超限、其余队列可继续推进，并覆盖pool close竞态。当前仅记录时序。

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
- 触发：unary/server-streaming request 的 5-byte header或 payload 在 END_STREAM 前截断，或 payload 不是目标 protobuf；client-streaming/bidi handler 循环读取时遇到同类错误后按 nil 结束并正常 return。
- 影响：前两类返回 HTTP 200/application-grpc 但完全没有 grpc-status，client只能合成 UNKNOWN；后两类可明确把 malformed request报告成 OK。应用、监控、retry policy 和审计日志会把协议损坏误判成成功或不可分类错误，client-streaming handler 还可能基于错误前已读消息产生并提交副作用。
- 证据：unary/sstream wrapper 在 `readbody` 返回 nil 时只 `logger.warnf` 后 return，没有 `closewrite` trailer；外层 `server_handler` 随后调用无参数 `s:closewrite()`，把预置 content-type header以 END_STREAM发送。stream reader虽设置 `s.status=INTERNAL`，但 cstream/bstream wrapper在用户函数正常返回后从不检查它，固定发 `grpc-status=OK`。若 partial bytes 后收到 EOS，底层 exact read返回 EOF且 `h2stream:eof()` 为真，reader还会把截断误标 OK。
- 根因：message reader 只返回松散字符串错误，没有区分 clean message-boundary EOS 与 mid-envelope EOF；stream object status 也没有成为 wrapper 终局状态机的权威输入。
- 建议解法：让 decoder 返回结构化结果 `message/clean_eos/protocol_error/transport_error` 并跟踪当前 envelope offset；所有 wrappers通过一个唯一 finalize 函数选择最终 status，已有 runtime error不可被用户函数正常 return覆盖。能够发送 trailer时用 INTERNAL等非 OK，无法继续 framing 时按 gRPC transport mapping reset stream。
- 后续回归条件：修复阶段覆盖 0..4-byte header截断、payload 少 1 byte、invalid protobuf、错误发生于第 1/第 N 条 streaming message；断言始终只有一个非 OK final status、handler副作用边界明确、永不缺 status或回 OK。本轮不新增测试代码。

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
- 触发：server发送完整 envelope但 payload不是声明的 protobuf type，或5-byte header/payload在END_STREAM前截断，然后发送/已发送 `grpc-status: 0`（普通 trailer；部分场景也可由Trailers-Only状态路径组合）。
- 影响：server-streaming、client-streaming和bidi对象最终记录 `status=OK`，调用方把损坏响应当成正常流结束；unary只返回无结构的 decode/EOF字符串而不是 INTERNAL。数据损坏、版本不匹配与恶意peer行为因此无法按标准 code监控/处置。
- 证据：`readbody`正确返回 `"Decode error"`或底层EOF，但 `check_trailer`只要看到grpc-status就无条件以该数值覆盖本地err，err仅在status缺失时才用作message。streaming两条路径随后返回nil且暴露OK；unary在n==OK时直接`return resp, err`，没有构造INTERNAL status。
- 根因：finalizer把peer status当成唯一权威，没有维护不可被成功status覆盖的local runtime error；API又没有统一的结构化status对象。
- 建议解法：call state保存首个本地 protocol/decode/runtime failure；最终peer non-OK可提供额外上下文，但peer OK不得覆盖本地失败。invalid response proto统一映射INTERNAL，截断按transport/protocol性质映射，并让四种API返回同一status模型。
- 后续回归条件：修复阶段覆盖invalid protobuf、0..4-byte header、短payload、第二条streaming message损坏，分别配OK/non-OK/missing status；本地损坏永不产生OK，invalid proto稳定为INTERNAL。本轮不新增测试代码。

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

### GRPC-023 — P2 — `grpc.listen` 静默丢弃公开的 `ciphers` 与 `backlog` 配置

- 状态：已确认；gRPC listen adapter、TCP/TLS listener options与中英文公开配置表的确定性静态核对。本轮不创建listener或TLS context。
- 位置：gRPC server配置注解与下传在 `lualib/silly/net/grpc/server.lua:29-55`；TLS消费 `ciphers/backlog` 在 `lualib/silly/net/tls.lua:326-365`，TCP消费backlog在 `lualib/silly/net/tcp.lua:152-175`；公开配置见 `docs/src/en/reference/net/grpc.md:146-166` 与中文同名文档。
- 触发：为明文或TLS gRPC listener设置 `backlog`；或TLS listener设置显式 `ciphers` 安全策略。调用成功且没有unknown-option警告。
- 影响：实际listen queue仍使用底层默认值，容量/突发连接行为与部署配置不符。更重要的是，自定义cipher policy从未进入TLS context，安全管理员可能依据一个静默无效的设置错误判断已禁用某些套件或满足组织基线；问题不会从成功返回值或日志中显现。
- 证据：`server.lua` 的conf注解列出 `ciphers`，reference另列出 `backlog`，但明文调用table只有 `addr,accept`，TLS调用table只有 `addr,certs,alpnprotos,accept`。底层API明确读取 `conf.backlog` 传给 `net.tcplisten`，并由 `new_server_ctx` 读取 `conf.ciphers` 传给 `ctx.server`；adapter没有传入时它们不可能生效。reference还列出可配`alpnprotos`，实现正确地固定为h2但没有说明该字段被忽略。
- 根因：wrapper手工重建了listener option table而非受控转发支持字段；文档配置schema与server.lua注解/实际下传三者没有单一来源或unknown-option校验。
- 建议解法：显式把 `backlog` 传入两种listener、把 `ciphers` 传入TLS listener，并在入口验证TLS专用字段只用于 `tls=true`。gRPC的ALPN应固定为h2并删除公开override，而不是接受任意值；所有未知/不适用配置fail fast。最好以共享schema生成LuaLS注解与双语文档表。
- 后续回归条件：修复阶段用stub listener捕获下传table，覆盖明文/TLS的backlog、TLS ciphers、未知字段和不适用组合；TLS集成阶段再检查实际ctx cipher policy。当前只做静态配置数据流核对。

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

当前滚动统计为199项：P0为0，P1为84，P2为106，P3为9。模块分布：CORE 7、NET 2、SOCK 14、UDP 1、TLS 8、DNS 8、CLUSTER 15、ADDR 1、URL 3、HTTPC 5、HTTP1 17、COMP 1、WS 10、H2 31、HPACK 2、GRPC 23、REDIS 8、MYSQLC 7、MYSQL 16、ETCD 14、DOC 6。

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
