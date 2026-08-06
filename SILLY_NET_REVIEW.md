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
| RFC9113-8.1-RST-NO-ERROR-RESPONSE | MUST NOT | `lualib/silly/net/http/h2.lua:845-877,1088-1123,1336-1351,1446-1499` | client recipient | 偏离 | 完整响应后的 RST_STREAM(NO_ERROR) 覆盖 END 为 RST；尚未读取的空响应会被丢弃为错误 | 现有测试没有 response END 后 RST(NO_ERROR) | H2-017 |
| RFC9113-8.1.1/8.2.2/8.3-SENDER-FIELDS | MUST/MUST NOT | `lualib/silly/net/http/h2.lua:700-738,938-1025`; `lualib/silly/net/http/client.lua:318-365`; `luaclib-src/lhttp.c:357-556` | client/server sender | 偏离 | request/response/trailer 在 HPACK 前无 sender validation；可生成 connection-specific/uppercase/非法或重复 pseudo/status fields | 现有测试只验证正常 fields，未检查 outbound malformed block | H2-018 |
| RFC9113-8.1.1/8.2.1-FIELD-VALIDITY | MUST/security | `lualib/silly/net/http/h2.lua:331-447,1562-1648` | server recipient | 偏离 | request validator 未拒绝非法 name bytes/冒号及 value 中 NUL/CR/LF/首尾空白；Content-Length 又用宽松 tonumber | 现有测试没有 generic invalid field octets 或非十进制 length | H2-019 |
| RFC9113-4.3/6.2/6.10-FRAGMENT-SEQUENCE | MUST | `luaclib-src/lhttp.c:883-949`; `lualib/silly/net/http/h2.lua:700-738,1018-1024` | client/server sender | 偏离 | 大于 frame size 的 field block 最后一帧被硬编码为 HEADERS，而非 CONTINUATION+END_HEADERS | 现有测试没有 outbound header block 跨 frame | H2-020 |
| RFC9113-6.9.2-INITIAL-WINDOW-OVERFLOW | MUST | `lualib/silly/net/http/h2.lua:1131-1172,1211-1278` | client/server recipient | 偏离 | SETTINGS initial-window delta 使任一 stream window 超过 2^31-1 时只 RST stream；规范要求 connection FLOW_CONTROL_ERROR | 现有测试没有高 window 后再增 initial setting | H2-021 |
| RFC9113-8.1.1-CONTENT-LENGTH-SCOPE | MUST | `lualib/silly/net/http/h2.lua:845-877,1177-1205,1446-1499,1562-1648` | client/server recipient | 偏离 | DATA 总量与 Content-Length 不符时发送 connection GOAWAY；规范要求对应 stream PROTOCOL_ERROR | 现有测试未验证 mismatch 与并发 stream 隔离 | H2-022 |
| RFC7541-5.1-INTEGER-LIMITS | MUST/safety | `luaclib-src/lhttp.c:558-583,613-630,696-771` | HPACK decoder | 偏离 | varint continuation/value 无上限，移位可有符号溢出或超过位宽；unsigned 结果缩成 int 后作为 string pointer/length，未按 decoding error 拒绝 | 现有测试没有超长/溢出/未终止 varint；本轮按要求不新增复现 | HPACK-002 |
| RFC7541-5.2-HUFFMAN-EOS | MUST | `luaclib-src/lhttp.c:33-43,62-94,135-172,215-225`; `luaclib-src/http2_table.h` | HPACK decoder | 偏离 | EOS symbol 256 经 `uint8_t sym` 截断为 0，decoder 命中 leaf 后无 EOS guard并输出 NUL；本应 decoding error | 现有 Huffman tests 没有 literal 中显式 EOS | HPACK-003 |

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

### H2-017 — P2 — 完整响应后的 RST_STREAM(NO_ERROR) 会覆盖并丢弃响应

- 状态：已确认；RFC 9113 明确规则与确定性 response/RST/read path 推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 9113 §8.1 允许 server 在发送带 END_STREAM 的完整响应后，以 `RST_STREAM(NO_ERROR)` 请求 client 无错终止尚未完成的 request transmission；client MUST NOT 因收到该 RST_STREAM 而丢弃已经完成的响应。
- 位置：terminal state 写入在 `lualib/silly/net/http/h2.lua:845-877`，`readall` terminal 分支在 `:1088-1123`，RST handler 在 `:1336-1351`，client response END transition 在 `:1446-1499`。
- 触发：server 发送完整 response HEADERS（可直接 END_STREAM，空 body）或 response DATA+END_STREAM，随后在同一 stream 发送合法 4-byte error code 0 的 RST_STREAM；应用在两个 frames 都已处理后调用 `stream:readall()`。
- 影响：已经成功完成的 response 被重新标记为 reset。空 body 没有 buffered bytes 可兜底，`readall` 返回 nil 与 “Graceful shutdown”；使用 waitresponse 后再读取、事件驱动消费或调度较慢的调用方会把合法响应当失败。该标准序列常用于 server 提前响应并停止大 request body，故会造成真实互操作故障和不必要重试。
- 证据：response END 调用 `stream_remoteend(s, STATE_END, EEOF)`；紧随的 `frame_rst` 不检查既有 terminal state或 errorcode，直接再次调用 `stream_remoteend(s, STATE_RST, err_str[0])`，覆盖 `remotestate` 和 `errstr`。之后 `readall` 在 buffer 为空时只有 state 恰为 END 才返回 `""`，RST 则返回 nil/error。实现没有保存“response already complete”事实。
- 根因：RST handler 将所有 error codes 和到达阶段统一建模为远端失败，terminal state 可逆；遗漏 `NO_ERROR after complete response` 的 HTTP message-level 例外。
- 建议解法：terminal response completion 必须单调且独立保存；client 若已收到完整 response，再收到 RST_STREAM(NO_ERROR) 只能终止本端 request write/wake writer，不能覆盖 response END、status/header/body/trailer。其他 code 或响应完成前的 RST 仍按 reset 处理，并正确停止双向 stream。
- 后续回归条件：修复阶段覆盖空 response HEADERS+END_STREAM→RST(NO_ERROR)、带 body END→RST(NO_ERROR)、RST 在 final/END 前、非零 error code、client 仍在上传 body，以及 waitresponse→延迟 readall；断言完成响应保持可读，pending writer被停止，其他 stream 不受影响。本轮不新增测试代码。

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

### HPACK-003 — P2 — Huffman EOS symbol 被截断并解码成 NUL

- 状态：已确认；RFC 7541、生成表规模与确定性 C 类型转换推导。本阶段只做静态 review，不新增触发代码。
- 规范：RFC 7541 §5.2 要求 Huffman string 中出现 EOS symbol 必须作为 decoding error；只有末尾不超过 7 bits、且为 EOS code 最高位前缀的残余 bits 才能作为 padding 丢弃。EOS 不能作为普通 octet 输出。
- 位置：Huffman node/root 类型在 `luaclib-src/lhttp.c:33-43`，建树在 `:62-94,215-225`，decode 在 `:135-172`；257-entry code/length 表在 `luaclib-src/http2_table.h`。
- 触发：peer 在 HPACK Huffman-encoded field name/value 中编码完整 EOS code（symbol index 256），并提供合法的剩余 byte padding使 string 到 octet boundary。
- 影响：decoder 不返回 compression error，而是向 Lua header string 追加 byte `0x00`。结合 HTTP/2 field validator 对通用 name/value syntax 的缺口，NUL 可进入 path、metadata或应用 header map；Lua 长度感知字符串与下游 C API/日志/代理若采用 NUL-terminated 解释，可能产生截断和验证/使用差异。即使没有下游利用，也明确接受了 HPACK 必须拒绝的压缩输入。
- 证据：规范 Huffman table 包含 257 entries，最后一个是 EOS；`create_huffman_tree` 遍历整个数组并把 index `i` 传给 `add_node(..., uint8_t sym, ...)`。当 i=256 时 C 转换得到 0，存入同为 `uint8_t` 的 `node.sym`。`huffman_decode` 命中任何 leaf 都无条件 `luaL_addchar(buf, n->sym)`，没有 EOS 标志或 symbol==256 分支，因此输出 NUL。末尾 `sbits/mask` 只检查 padding，不能识别已经消费的 EOS leaf。
- 根因：node representation 只为 byte alphabet 预留 8 bits，未为 HPACK 的第 257 个 sentinel symbol建模；decoder 又把所有 leaf 统一当作可输出 byte。
- 建议解法：将 symbol 类型扩为至少 9-bit/`uint16_t`，保留 EOS=256；decoder 命中 EOS leaf 立即返回 decoding error，不输出字符。padding 继续只通过残余 bit 长度≤7且全为 EOS 前缀来接受，不能把完整 EOS 与 padding合并处理。
- 后续回归条件：修复阶段覆盖完整 EOS 位于开头/中间/末尾、EOS 后更多 symbol、1..7-bit 合法全 1 padding、8+bit padding、非全 1 padding，以及全部 RFC Huffman examples；断言 EOS 统一导致 HTTP/2 `COMPRESSION_ERROR` 且无 NUL 输出。本轮不新增测试代码。

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
- 2026-08-06：确认 half-closed(remote) stream 上的 late DATA 被升级为 connection PROTOCOL_ERROR，而不是该 stream 的 STREAM_CLOSED，记录为 `H2-014`。
- 2026-08-06：确认 client 不记录本端已用 stream-id，完成后合法 late WINDOW_UPDATE 会被误判 idle 并触发 GOAWAY，记录为 `H2-015`。
- 2026-08-06：确认无已处理 peer stream 时 `laststreamid=-1` 被 GOAWAY builder 序列化为 0xffffffff，记录为 `H2-016`。
- 2026-08-06：确认完整响应后的 RST_STREAM(NO_ERROR) 会把 client END 覆盖为 RST，使尚未读取的空响应被丢弃，记录为 `H2-017`。
- 2026-08-06：确认 request/response/trailer sender 在 HPACK 前无 HTTP/2 field validation，可生成 connection-specific/非法或重复控制 fields，记录为 `H2-018`。
- 2026-08-06：确认 server request validator 未执行 RFC 9113 最低 name/value octet 规则，且用宽松 `tonumber` 解析 Content-Length，记录为 `H2-019`。
- 2026-08-06：确认 outbound HPACK block 跨 frame 时 final fragment 被硬编码成第二个 HEADERS，而非 CONTINUATION，记录为 `H2-020`。
- 2026-08-06：确认 SETTINGS initial-window delta 造成 stream window overflow 时仅 reset stream，未按规范终止 connection，记录为 `H2-021`。
- 2026-08-06：确认 Content-Length 与 DATA 总量不一致时被升级为 connection GOAWAY，而非对应 stream PROTOCOL_ERROR，记录为 `H2-022`。
