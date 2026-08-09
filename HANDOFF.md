# Silly `net` 全量审计交接文档

> 更新时间：2026-08-06（Asia/Shanghai）
> 用途：让新的 Codex 会话无需重新摸索，直接从第 4 阶段继续审计。
> 当前结论：审计尚未完成；20 个阶段中已完成 1–3，阶段 4（核心 engine/worker/queue/timer/socket）进行中。

## 1. 用户目标与工作方式

用户要求：进入 `silly`，先制定长计划，然后逐个 review `net` 相关模块，特别是 HTTP、WebSocket、gRPC、Redis driver、MySQL driver；除现有测试外，还要按 RFC/官方协议逐项检查 HTTP、WebSocket、gRPC 的规范符合性；全部问题和解法必须持续记录。允许读取、运行、拉取最新代码，必要时可以重新 clone。

用户希望会话自主持续工作，不要在发完进度后停住。新会话应遵循：

1. 先读本交接文档和主报告，但不要重做已经完成的基线。
2. 立即执行下一项检查；进度说明之后必须紧跟实际工具调用。
3. 持续更新 `SILLY_NET_REVIEW.md`，确认一条记一条，疑点不得冒充已确认问题。
4. 当前任务是审计和记录，不要未经用户另行授权直接修改 Silly 源码。
5. 每个模块至少覆盖静态调用链、状态机、所有权、失败路径、并发、资源限制、现有测试缺口和针对性动态验证。
6. HTTP/WebSocket/gRPC 的普通测试通过不代表规范符合；必须建立逐条 MUST/MUST NOT 证据表。

## 2. 路径、Git 与工作区状态

- 工作区绝对路径：`/home/findstrx/Documents/Codex/2026-08-06-remote`
- Silly 源码绝对路径：`/home/findstrx/Documents/Codex/2026-08-06-remote/silly`
- 主审计报告：`/home/findstrx/Documents/Codex/2026-08-06-remote/silly/SILLY_NET_REVIEW.md`
- 复现脚本目录：`/home/findstrx/Documents/Codex/2026-08-06-remote/silly/review-repros`
- 上游：`https://github.com/findstr/silly.git`
- 分支：`master`，跟踪 `origin/master`
- 当前 HEAD：`d1aef7ffd8439340dfd957a49fccba3fbf133055`
- 提交时间：`2026-07-19 16:09:32 +0800`
- 提交标题：`ci: fix lcov 2.5 coverage capture`
- 上次执行 `git pull --ff-only` 的结果：`Already up to date`
- Silly 仓库上次检查为干净：`## master...origin/master`

新会话开始时先做只读核对，再联网拉取：

```bash
cd /home/findstrx/Documents/Codex/2026-08-06-remote/silly
git -C silly status --short --branch
git -C silly log -1 --format='%H%n%ci%n%s'
git -C silly pull --ff-only
```

如果拉取后 HEAD 改变，必须在报告中记录旧/新提交，判断已确认问题是否仍存在，再继续；不要把用户已有变更覆盖掉。

环境里登录 shell 找不到普通 `rg` 时可使用：

```text
/home/findstrx/.codex/packages/standalone/releases/0.146.1-x86_64-unknown-linux-musl/codex-path/rg
```

## 3. 已建立的长计划

主报告第 2 节给出了 20 个阶段和各阶段完成标准。当前进度如下：

| 阶段 | 范围 | 状态 |
|---:|---|---|
| 1 | 上游提交、仓库状态、构建参数、模块清单 | 已完成 |
| 2 | ASan/UBSan/coverage 与 TSAN 基线 | 已完成 |
| 3 | 全部现有网络相关基线测试 | 已完成 |
| 4 | engine/worker/message/queue/timer/socket C 核心 | 进行中 |
| 5 | `net.lua` 与 C/Lua 边界 | 待做 |
| 6 | TCP | 待做 |
| 7 | UDP | 待做 |
| 8 | TLS | 待做 |
| 9 | addr/DNS/cluster | 待做 |
| 10 | HTTP 公共层 | 待做 |
| 11 | HTTP/1 + RFC 9110/9112/3986 | 待做 |
| 12 | HTTP/2 + HPACK + RFC 9113/7541 | 待做 |
| 13 | HTTP client/server 聚合与 Go 互操作 | 待做 |
| 14 | WebSocket + RFC 6455/8441 | 待做 |
| 15 | gRPC over HTTP/2 | 首轮静态协议审查完成；修复阶段待独立peer互操作 |
| 16 | Redis driver | 待做 |
| 17 | MySQL C codec | 待做 |
| 18 | MySQL Lua driver | 待做 |
| 19 | etcd、跨模块取消/超时、故障注入/sanitizer | 待做 |
| 20 | 文档/API 契约与最终优先级报告 | 待做 |

不要把阶段 4 标记完成，至少还需完成下面第 8 节列出的 socket 核心候选验证。

## 4. 已跑测试和动态基线

主工作副本使用：

```bash
make -j4 TEST=ON MALLOC=glibc SNAPPY=OFF all
```

该测试构建启用了 AddressSanitizer、UndefinedBehaviorSanitizer、`float-cast-overflow` 和 coverage。已通过：

- TCP `testtcp2`：30 组。
- HTTP/1 `testhttp`：全部现有用例。
- HTTP/2 `testhttp2`：36 组。
- WebSocket `testwebsocket`：7 组，含 WSS、压力、DNS 失败。
- gRPC `testgrpc --test.grpc.timeout=10000`：9 组，含 unary/client-stream/server-stream/bidi、deadline、并发和 1 MiB 消息。
- Redis：临时 Redis 6.0.16，18 组。
- MySQL：临时 MariaDB 10.3，41 组。

这些运行均未报告 ASan/UBSan 错误，最终 `netstat=0`、`leak memory size=0`。临时 Redis/MariaDB 容器已停止并移除；不要误删环境中不属于本任务的 Docker 资源。

仍需补：MySQL 8、MariaDB 10.6、Go HTTP 互操作/畸形输入、协议 fuzz/fault injection、Windows/macOS 行为。

### TSAN

隔离 TSAN clone 上次位于：

```text
/tmp/silly-tsan-review.HHFlk0/silly
```

它使用 `-DSILLY_TEST -O1 -fsanitize=thread -fno-omit-frame-pointer` 构建。`testtcp2` 的 30 组业务断言全部完成，但进程因 5 组 TSAN 告警以 66 退出：

1. `engine.c:76` 的 `workerstatus` 写 vs `engine.c:45` 读。
2. `queue.c:91` 的 `size` 读 vs `queue.c:67` 写。
3. `queue.c:75` 的 `head` 读 vs `queue.c:65` 写。
4. `worker.c:94` 的 `maxmsg` 读 vs `worker.c:193` 写。
5. `engine.c:168` 的 `running` 写 vs `engine.c:94` 读。

`/tmp` 内容可能被清理；若路径不存在，应从当前 `silly` 新建隔离 clone/build，不能直接把 TSAN flags 混进主 ASan 工作副本。

## 5. 已确认问题（120 条）

以下是索引；完整触发条件、影响、根因、建议和回归测试都在主报告第 4 节。

| 编号 | 严重度 | 结论 |
|---|---:|---|
| CORE-001 | P2 | worker 条件变量谓词未由同一 mutex 保护，存在真实数据竞争和丢唤醒窗口；TSAN 实证。 |
| CORE-002 | P2 | queue 的 `head`/`size` 在锁外并发读写；TSAN 实证。 |
| CORE-003 | P2 | `volatile running` 不是线程同步，退出状态有数据竞争；TSAN 实证。 |
| CORE-004 | P1 | `pthread_create` 只检查 `err < 0`，漏掉 POSIX 的正错误码，失败回滚不可靠。 |
| CORE-005 | P3 | `worker.maxmsg` 诊断阈值跨线程普通读写；TSAN 实证。 |
| CORE-006 | P2 | timer把64位毫秒delta窄化为int，长暂停/时钟跳变可崩溃、错时或产生巨量catch-up循环。 |
| NET-001 | P2 | listener close与已排队ACCEPT竞态时只assert，不关闭已注册的accepted fd，形成孤儿连接。 |
| NET-002 | P2 | raw data callback异常时C message已放弃payload ownership，task错误路径不会释放，形成可重复内存泄漏。 |
| TLS-001 | P1 | TLS client保持OpenSSL默认VERIFY_NONE，既不验证证书链也不验证hostname，HTTPS/WSS/gRPC可被MITM。 |
| TLS-002 | P1 | accepted TLS不保活SNI callback ctx，reload/close+GC后在途ClientHello可访问失效userdata。 |
| TLS-003 | P1 | SSL_read的close/fatal/WANT_WRITE状态全被吞掉，TLS reader可永久挂起且alert不flush。 |
| TLS-004 | P2 | TLS正常close只断TCP、从不发送close_notify，peer无法获得authenticated EOF。 |
| TLS-005 | P1 | TLS server在业务accept前无期限等待ClientHello，空连接可永久占用fd/SSL/task。 |
| TLS-006 | P2 | TLS server显式允许TLS1.1、client不设minimum，版本安全基线依赖环境并偏离RFC8996。 |
| DNS-001 | P2 | CNAME/SRV/SOA解析可跨越声明RDLENGTH借用后续字节，A/AAAA也接受非精确长度。 |
| DNS-002 | P1 | DNS response三section被抹平且CLASS丢失，无关低trust记录可覆盖任意名字的既有cache。 |
| DNS-003 | P1 | DNS新名字TXID恒从1递增且每server长期复用单一UDP source port，伪响应entropy显著不足。 |
| CLUSTER-001 | P1 | cluster response只按全局session匹配，任一peer或wrap后的late ACK可跨连接完成其他RPC。 |
| CLUSTER-002 | P2 | cluster peer断线/主动close不结束其pending RPC，waiter与timer只能保留到全局timeout。 |
| CLUSTER-003 | P2 | unknown/late/duplicate ACK会对nil coroutine执行wakeup，连接保持并可持续制造异常/日志。 |
| CLUSTER-004 | P2 | cluster主动close不清C parser的per-fd incomplete buffer，默认单块可滞留至128MiB。 |
| CLUSTER-005 | P1 | 合法UINT32_MAX hardlimit使receive psize+1及send 4+body回绕，进入小分配/大copy内存破坏。 |
| CLUSTER-006 | P2 | cluster wire直接复制native整数/struct，大小端不同节点无法互操作且文档格式也与实现不符。 |
| ADDR-001 | P2 | IP分类忽略Lua string的embedded-NUL后缀，校验/日志中的地址可与socket实际endpoint不同。 |
| URL-001 | P1 | URL fragment未从HTTP target剥离，OAuth token等client-side secret可进入request-line/:path与服务端日志。 |
| URL-002 | P2 | URL显式port绕过supported-scheme校验，HTTP/WS consumer对未知scheme回落明文TCP并发起连接。 |
| URL-003 | P2 | relative URL resolver不拆path/query、不移除dot-segments且错误处理empty ref，redirect target偏离RFC3986。 |
| HTTPC-001 | P1 | convenience client无响应body上限且自动gzip解压无output/ratio budget，恶意响应可耗尽内存。 |
| HTTPC-002 | P1 | HTTP client无端到端deadline/cancel，DNS/connect/TLS/headers/body任一阶段都可永久挂住调用。 |
| COMP-001 | P2 | gzip inflate不要求`Z_STREAM_END`或完整消费输入，截断/拼接流可被部分成功接受。 |
| REDIS-001 | P1 | 畸形RESP会抛出未清理异常并永久占住reader token，使后续请求全部挂起。 |
| REDIS-002 | P2 | command write失败调用reader-only清理并assert，pipeline则遗留坏socket。 |
| REDIS-003 | P1 | connect/handshake/command/pipeline和reader queue均无deadline/cancel，一个slow peer可挂住整个client。 |
| REDIS-004 | P1 | RESP line/bulk/aggregate没有大小、元素数、总量或递归深度预算，可耗尽内存/CPU/stack。 |
| REDIS-005 | P2 | close无法看到in-flight connect/handshake，晚到连接可在对象关闭后重新发布并泄漏。 |
| REDIS-006 | P2 | RESP null映射为Lua nil后aggregate/pipeline槽位消失，合法响应无法保留长度和位置。 |
| MYSQLC-001 | P1 | binary result row未验证NULL bitmap长度即直接索引，截断packet可造成C越界读。 |
| MYSQL-001 | P1 | idle/lifetime淘汰连接不递减open_count，受限pool可永久假满并挂住请求。 |
| MYSQL-002 | P1 | driver无TLS/server identity且full-auth信任peer临时RSA key，MITM可读取流量并取得密码。 |
| MYSQL-003 | P1 | connect/auth/query/pool wait均无deadline/cancel，现有connect_timeout选项被静默忽略。 |
| MYSQL-004 | P1 | conn归池后旧对象仍可操作且close不幂等，可让多个borrower并发共享同一MySQL stream。 |
| MYSQL-005 | P1 | COMMIT/ROLLBACK失败仍清除transaction flag并归池，后续borrower可继承未知事务状态。 |
| MYSQL-006 | P2 | pool close唤醒的waiter会fall through新建连接，关闭后仍可认证并执行SQL。 |
| SOCK-001 | P2 | 已排队 UDP datagram 永久发送失败后，节点释放但 `wlbytes/sendsize` 不递减。 |
| SOCK-002 | P3 | UDP connect 失败日志以 `%d` 打印 `const char *port`，构成 varargs 未定义行为。 |
| SOCK-003 | P2 | 退出时未清理各 slot 的待发 `wlist` payload；LSan 确认 32768 bytes/8 objects。 |
| SOCK-004 | P2 | TCP connect 在加入 multiplexer 前立即失败会泄漏 fd；8 次失败令 open fd 从 8 增至 16。 |
| SOCK-005 | P2 | `socket_stat` 与 close 并发时数据竞争，可读取失效 fd 并触发进程断言。 |
| SOCK-006 | P1 | send length经`size_t→int→size_t`窄化，裸pointer可形成巨大iov并越界读取/泄露内存。 |
| SOCK-007 | P2 | stale send在sid校验后close/reuse，可把wlbytes永久记入新generation socket。 |
| SOCK-008 | P1 | worker已释放后socket final flush error仍调用worker_push，形成shutdown heap UAF。 |
| SOCK-009 | P1 | poll batch中的裸slot pointer缺generation，close/reuse后old event可误作用于new socket。 |
| SOCK-010 | P2 | rw_enable先改state再忽略sp_ctrl失败，可使发送永久stall或残留事件CPU busy-loop。 |
| SOCK-011 | P1 | 任意sockaddr string仅靠assert进入fixed stack op/ntop，可导致abort、stack overflow或OOB read。 |
| SOCK-012 | P1 | TCP/TLS默认buffer与UDP packet stash无资源上限，慢消费时远端输入可持续耗尽内存。 |
| HTTP1-001 | P2 | 接受同时包含 TE 与 CL 的请求后未按 RFC 9112 强制关闭连接。 |
| HTTP1-002 | P2 | client/server 拒绝 RFC 9112 允许的相同 `Content-Length` 列表。 |
| HTTP1-003 | P1 | `Transfer-Encoding` 未按大小写不敏感的列表及 final coding 决定 framing。 |
| HTTP1-004 | P2 | chunk reader 忽略 size 后的全部尾缀，静默接受非法 chunk extension/垃圾。 |
| HTTP1-005 | P1 | 超大 chunk-size 在内置 Lua 中整数回绕，可被误判为 last-chunk。 |
| HTTP1-006 | P2 | trailer 发送 API 可生成禁止字段，且无法根据 trailer 参数自动声明字段名。 |
| HTTP1-007 | P1 | HTTP/1 行和字段集合没有上限或解析 deadline，未认证连接可耗尽内存。 |
| HTTP1-008 | P1 | HTTP/1 server不要求唯一合法Host，也不解析absolute-form authority，歧义请求直接进入handler。 |
| HTTP1-009 | P1 | HTTP/1收发均无field octet校验，sender可由header key/value直接生成CRLF injection。 |
| HTTP1-010 | P2 | HTTP/1起始行parser未锚定且版本/status grammar错误，固定方法白名单也破坏method扩展语义。 |
| WS-001 | P1 | server 接受缺失/无效的 WebSocket opening handshake，并切换到 frame parser。 |
| WS-002 | P1 | client 仅凭 101 status 接受握手，不验证 Accept 或 Upgrade/Connection。 |
| WS-003 | P2 | frame parser 缺少 RSV/长度/control 校验，writer 的 125/65535 边界非规范。 |
| WS-004 | P2 | fragmentation 状态机接受 standalone continuation 和进行中插入的新 data message。 |
| WS-005 | P1 | frame 与 fragmented message 没有大小上限或 deadline，可被远端耗尽内存。 |
| WS-006 | P2 | text message 与 Close reason 的收发均不验证 UTF-8。 |
| WS-007 | P2 | Close payload/status 与 CLOSING handshake 没有状态机，主动 close 立即断 TCP。 |
| WS-008 | P1 | client masking key 与 handshake nonce 使用 time-seeded、小空间弱随机源。 |
| H2-001 | P2 | HTTP/2 client 接受 server 非法发送的 `SETTINGS_ENABLE_PUSH=1`，未触发 `PROTOCOL_ERROR`。 |
| H2-002 | P2 | 通用 frame reader 把非 padding frame 的 unused 0x08 当成 PADDED，改写 payload 或错误断连。 |
| H2-003 | P1 | HTTP/2 接收方不维护 connection/stream receive window，超额 DATA 仍被缓存。 |
| H2-004 | P2 | peer 的 HEADER_TABLE_SIZE 被应用到本端 decoder，而非约束本端 encoder。 |
| HPACK-001 | P2 | encoder 改变 maximum table size 后不在下一 header block 开头发送 dynamic table size update。 |
| H2-005 | P2 | server 用 client 广告的并发上限反向限制该 client 自己的 request streams。 |
| H2-006 | P2 | 非 5-byte PRIORITY 被升级为 connection GOAWAY，而非 stream `FRAME_SIZE_ERROR`。 |
| H2-007 | P2 | GOAWAY handler 忽略 payload，少于 mandatory 8 bytes 的 frame 也被接受。 |
| H2-008 | P1 | GOAWAY 丢弃 Last-Stream-ID；高编号未处理请求不结束/不标 retryable，可无限等待。 |
| H2-009 | P2 | client 不验证 response/trailer pseudo、field syntax、connection fields 或严格 status 语法。 |
| H2-010 | P2 | client 将首个 1xx informational response 当 final，真正 final HEADERS 被当 trailer。 |
| H2-011 | P2 | client 接受无 END_STREAM trailer，之后仍接受 DATA 并发生状态回退。 |
| H2-012 | P2 | 普通 CONNECT 的 pseudo-header 生成/校验与 mandatory/omitted 规则相反。 |
| H2-013 | P1 | HPACK 解压后无 uncompressed field-section/字段数/单字段资源上限。 |
| H2-014 | P2 | half-closed(remote) 上的 DATA 被升级为整连接 PROTOCOL_ERROR。 |
| H2-015 | P1 | client 将已完成 stream 的合法 late WINDOW_UPDATE 误判 idle 并触发 GOAWAY。 |
| H2-016 | P2 | 无已处理 stream 时 GOAWAY 将 -1 写成 0xffffffff Last-Stream-ID。 |
| H2-017 | P2 | 完整响应后的 RST_STREAM(NO_ERROR) 会覆盖 END 并丢弃空响应。 |
| H2-018 | P2 | request/response/trailer sender 无 field validation，可主动生成 malformed message。 |
| H2-019 | P1 | server request validator 缺少最低 field name/value octet 校验。 |
| H2-020 | P1 | outbound field block 跨 frame 时末帧错误地再次发送 HEADERS。 |
| H2-021 | P2 | SETTINGS initial-window overflow 被错误降级为 stream reset。 |
| H2-022 | P2 | Content-Length mismatch 被错误升级为整连接 GOAWAY。 |
| H2-023 | P1 | rejected initial HEADERS 可复用 stream id 或永久泄漏并发 quota。 |
| H2-024 | P1 | client 淘汰 local-RST tombstone 后不 minimally process late HEADERS/HPACK。 |
| H2-025 | P1 | handshake/frame/header-block reads 无 progress deadline 或配置入口。 |
| H2-026 | P1 | client 禁用 push 后仍静默忽略 PUSH_PROMISE并跳过 HPACK。 |
| HPACK-002 | P1 | HPACK varint 无溢出/长度限制，可进入 signed-shift UB 与越界 string length 路径。 |
| HPACK-003 | P2 | Huffman EOS symbol 256 被截断为 0 并作为 NUL 输出，而非 decoding error。 |
| GRPC-001 | P1 | client 创建 HTTP/2 channel 时漏传 target authority，所有请求把 `:authority` 编码成字面量 `nil`。 |
| GRPC-002 | P2 | unary 与三种 streaming client request 都缺少 gRPC Call-Definition 要求的 `te: trailers`。 |
| GRPC-003 | P2 | server 只按 path 路由，不校验 POST、gRPC Content-Type 或 TE，非 gRPC请求也不返回 HTTP 415。 |
| GRPC-004 | P2 | compressed flag 未按 0/1 与 `grpc-encoding` 组合校验，server/client 的标准 status 映射错误。 |
| GRPC-005 | P1 | client response message 无大小上限；可按 32-bit length 持续回补窗口并缓存接近 4 GiB。 |
| GRPC-006 | P2 | unary 的单 request/response 基数未验证，零/多余 envelope 均可被忽略或仍报告 OK。 |
| GRPC-007 | P1 | server parse/stream-read error 会缺失 grpc-status、被覆盖为 OK，或把截断 envelope 当 clean EOF。 |
| GRPC-008 | P1 | 三种 streaming client 不读取 Trailers-Only initial header，丢失真实 grpc-status并改报 UNKNOWN。 |
| GRPC-009 | P1 | client 忽略 HTTP status/Content-Type，缺 grpc-status 时不执行标准 HTTP→gRPC status mapping。 |
| GRPC-010 | P1 | client 用通用 `tonumber` 解析 grpc-status，非法数字文本可被接受成 OK或返回 nil status。 |
| GRPC-011 | P2 | grpc-message 未做 UTF-8 percent codec，server可发非法字段且 client返回编码文本/丢失 Trailers-Only message。 |
| GRPC-012 | P1 | streaming timeout 实际无效，deadline 不写 grpc-timeout、不由 server执行或暴露给 handler。 |
| GRPC-013 | P1 | RST_STREAM/连接失败只保留文本，client不按标准映射 CANCELLED/INTERNAL/UNAVAILABLE等 status。 |
| GRPC-014 | P1 | 无 package proto的 method path 被拼成 `/nil.Service/Method`，无法与独立 gRPC peer互操作。 |
| GRPC-015 | P1 | client response protobuf/envelope解析错误可被 peer的 OK trailer覆盖，stream最终错误地报告成功。 |
| GRPC-016 | P2 | 四种 server handler异常均被错误映射为 INTERNAL，而非 gRPC规定的 UNKNOWN。 |
| GRPC-017 | P2 | server不校验application status code，可发送非法grpc-status文本或error+OK。 |
| GRPC-018 | P2 | client/bidi零消息request用HEADERS+END_STREAM结束，而非gRPC要求的空DATA+END_STREAM。 |

统计口径为 78 条：5 个 CORE + 11 个 SOCK + 7 个 HTTP/1 + 8 个 WebSocket + 26 个 HTTP/2 + 3 个 HPACK + 18 个 gRPC；以主报告中的编号和证据为准。

## 6. 可直接复现的两个问题

### SOCK-003：退出时待发 payload 泄漏

脚本：`review-repros/socket_exit_pending_wlist.lua`

从 `silly` 目录执行：

```bash
timeout 20s ./silly ../review-repros/socket_exit_pending_wlist.lua
```

关键结果：测试把 `sendv_cap` 固定为 1 字节，排入 8 个 4096-byte 节点后立即退出；Silly 报告 `leak memory size:32768`，LeakSanitizer 报告 8 个直接泄漏，共 32768 bytes，退出码 1。

### SOCK-004：立即 connect 失败泄漏 fd

脚本：`review-repros/tcp_immediate_connect_fd_leak.lua`

```bash
timeout 20s ./silly ../review-repros/tcp_immediate_connect_fd_leak.lua
```

关键结果：连续 8 次连接 `255.255.255.255:9`，均立即 errno 101 (`ENETUNREACH`)；`metrics.openfds()` 从 8 增到 16，delta=8。复现脚本以 exit 0 表示成功观察到泄漏。

## 7. 已定位的重要实现位置

以当前 HEAD 为基线：

- `src/engine.c:45-46,60-61,73-80`：workerstatus/cond 协议。
- `src/engine.c:103-111`：`pthread_create` 错误判断。
- `src/engine.c:23,74,94,128,168`：`volatile running`。
- `src/queue.c:65-67,75,84,91`：head/size 锁外访问。
- `src/worker.c:53,90-99,193`：maxmsg 竞争。
- `src/socket.c:26-69`：文件自己声明只有 sid 可由 worker lock-free 读取。
- `src/socket.c:755-772`：`remove_from_sp/free_socket`；未 polling 时不会 close fd。
- `src/socket.c:841-844`：accept 的 `sp_add` 失败也有同类 fd 泄漏风险。
- `src/socket.c:1211-1238`：UDP queued-send 永久错误不扣 `wlbytes`。
- `src/socket.c:1456-1477`：TCP immediate-connect-error fd 泄漏。
- `src/socket.c:1504,1540`：UDP connect 错误日志格式类型不匹配。
- `src/socket.c:1552-1556`：UDP connect 的 `sp_add` 失败同类 fd 风险。
- `src/socket.c:1614-1686`：worker 侧 send op 和 `wlbytes` accounting。
- `src/socket.c:1730-1804`：op 处理，`OP_EXIT` 在本轮 flush 前 return。
- `src/socket.c:1977-1996`：`socket_exit` 只尝试 flush/close，不遍历释放活跃 `wlist`。
- `src/socket.c:2019-2064`：`socket_stat` 直接跨线程读 fd/type，并忽略 name syscall 错误。
- `src/silly_conf.h:49-50`：`TCP_READ_BUF_SIZE` 为 2 MiB。

## 8. 下一步：从这里立即继续

> 2026-08-06 当前工作方式更新：用户要求暂停新增复现代码和动态故障注入，先完成 HTTP、WebSocket、gRPC 的 RFC/协议静态 review。并发候选若没有现成精确 barrier，只记录静态时序和“无独立动态复现”，不要为了复现而修改源码。

### 8.0 已完成：gRPC protocol 首轮静态 review

HTTP/1 framing 首轮已确认 `HTTP1-001` 至 `HTTP1-007`；WebSocket 首轮已确认 `WS-001` 至 `WS-008`；HTTP/2 已确认 `H2-001` 至 `H2-026`，HPACK 已确认 `HPACK-001` 至 `HPACK-003`；gRPC 首轮已确认 `GRPC-001` 至 `GRPC-018`。gRPC基础length-prefix重组与正常response trailer符合；custom metadata记为可选能力/API缺口。按用户要求本阶段没有新增畸形输入或独立peer复现。

当前立即转回阶段4 socket core候选，以静态所有权/并发时序为主；没有精确barrier的竞争明确标注“无独立动态复现”。

### 8.1 第一优先：验证 `socket_stat` close/reuse 竞争

候选 `CAND-SOCK-003`：`socket_stat` 违反 `socket.c` 自身的并发规则。它从 worker 线程读取普通 `fd/type`，第二次 sid 校验不能形成生命周期保护；然后对可能已经关闭或复用的 fd 调用 `getsockname/getpeername`，并忽略返回值。

下一动作应是用 `apply_patch` 在工作区（不要放进 Silly repo）新建：

```text
review-repros/socket_stat_close_race.lua
```

测试思路：循环创建 `127.0.0.1:0` listener；使用测试 debug control 延迟 socket op；排入 close；恢复并 kick socket thread；同时对旧 sid 高频调用 `metrics.socketstat(sid)`；快速创建新 listener 促使 slot/fd 复用。先跑主 ASan build，再跑隔离 TSAN build。若 TSAN 报告 fd/type/sid 竞争或 ASan/断言/错误地址，即升级为已确认问题并记录原始堆栈。

推荐预期解法：让 socket thread 通过 command/message 生成一致 snapshot，或者实现真正的 per-slot lock/seqlock + generation protocol；所有 `getsockname/getpeername` 必须检查返回值。

### 8.2 已纠正的误报

原 `CAND-SOCK-004 — UDP 大报文可能被静默截断` 已在主报告改记为 `REJECT-SOCK-001`：当前固定接收 buffer 为 2 MiB，而合法 IPv4/IPv6 UDP datagram 最大尺寸小于约 64 KiB，因此不会因该 buffer 截断。除非未来缩小 buffer 或加入平台特定的非标准超大 UDP/GSO 接收接口，否则无需继续追查。

### 8.3 后续 socket 核心候选（尚未确认）

本轮conversion候选已完成：timer delta窄化是可达可靠性缺陷，记录为`CORE-006`；`queue_push`的`size_t→int`只有在超过`INT_MAX`条在途消息后影响过载诊断，现实中通常先耗尽内存，暂列构建卫生而不单列问题。API仍应改回`size_t`以消除不必要的截断。

原send-length与late-accounting两项已由静态完整调用链确认并记录为`SOCK-006`/`SOCK-007`；本阶段不新增大长度或并发barrier动态复现。
默认TCP/TLS/UDP接收stash已确认无上限并记录为`SOCK-012`；本阶段不新增流量压力复现。

阶段 4 完成前，再审阅 `src/socket_poll_*`、pool/flipbuf、所有 `free_socket` 调用点和 stop/exit ownership table，跑一次严格 warnings 静态检查并把结论入报告。

## 9. RFC/协议审计基线

主报告第 2.1 节已经写好完整 checklist。权威来源：

- HTTP semantics：RFC 9110 — https://www.rfc-editor.org/rfc/rfc9110.html
- HTTP/1.1 messaging：RFC 9112 — https://www.rfc-editor.org/rfc/rfc9112.html
- HTTP/2：RFC 9113 — https://www.rfc-editor.org/rfc/rfc9113.html
- HPACK：RFC 7541 — https://www.rfc-editor.org/rfc/rfc7541.html
- URI：RFC 3986 — https://www.rfc-editor.org/rfc/rfc3986.html
- WebSocket：RFC 6455 — https://www.rfc-editor.org/rfc/rfc6455.html
- WebSocket over HTTP/2：RFC 8441 — https://www.rfc-editor.org/rfc/rfc8441.html
- gRPC over HTTP/2 官方协议 — https://grpc.github.io/grpc/core/md_doc__p_r_o_t_o_c_o_l-_h_t_t_p2.html

技术规范检索只用 RFC Editor 或协议官方文档等第一方来源。最终表格格式固定为：

```text
SPEC-ID | MUST/SHOULD | 实现位置 | client/server | 符合/偏离/不适用 | 证据 | 互操作测试 | 问题编号
```

重点不是只找 parser 崩溃；必须分别检查接收端拒绝规则和发送端生成规则，并覆盖 request smuggling、HTTP/2 状态/流控、HPACK 解压放大、WebSocket mask/fragment/UTF-8/close、gRPC envelope/metadata/trailers/deadline/cancel。

## 10. 记录与验证纪律

- 每个新问题写入主报告时必须包含严重度、状态、位置、触发、影响、证据、根因、建议解法和回归测试。
- 动态证据要保存精简后的命令、退出码、sanitizer 栈、FD/内存计数或协议字节序列。
- 只靠静态推导但路径确定的可以标“已确认；确定性代码推导”；存在前置假设的保留为候选。
- 修复建议要考虑回滚、double-free/double-close、generation reuse 和关闭顺序，不能只修表面分支。
- Silly repo 中现有或新出现的用户改动都要保留；审计用脚本和报告继续放在外层工作区。
- 测试可能留下被 gitignore 的 `.gcda`，不要为“清理”运行破坏性命令。
- 长时间命令用会话轮询，每 60 秒内给用户一次简短、带实际发现的更新，但不要因此中断审计。

## 11. 给新会话的可复制启动指令

```text
继续 Silly net 全量审计。先完整读取工作区 HANDOFF.md 和 SILLY_NET_REVIEW.md；核对 silly 仓库状态并 git pull --ff-only。不要重跑已完成的普通基线，直接从阶段 4 的 socket_stat close/reuse 竞争复现开始。确认一项就把问题、证据、解法和回归测试追加到 SILLY_NET_REVIEW.md。阶段 4 完成后按计划依次 review net.lua、TCP、UDP、TLS、DNS/cluster、HTTP 公共层、HTTP/1、HTTP/2/HPACK、HTTP 聚合与互操作、WebSocket、gRPC、Redis、MySQL C、MySQL Lua、etcd/故障注入、文档/API。HTTP/WebSocket/gRPC 必须逐条对照 RFC/官方协议。除非真正需要用户授权或遇到无法绕过的阻塞，不要在状态回复后暂停；持续执行并持续记录。当前任务只审计和记录，不修改 Silly 源码。
```

## 12. 当前文件清单

```text
SILLY_NET_REVIEW.md
HANDOFF.md
review-repros/socket_exit_pending_wlist.lua
review-repros/tcp_immediate_connect_fd_leak.lua
silly/  # 最新审计源码工作副本
```
