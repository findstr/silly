# Silly `net` 全量审计交接文档

> 更新时间：2026-08-13（Asia/Shanghai）
> 用途：保存三轮审计结论，让后续会话直接按优先级进入修复与回归。
> 当前结论：1.0 `net` 完成性反证审计进行中；当前确认master基线371项（P1 113、P2 202、P3 56）及4项cluster分支独有问题。审计完成不代表允许发布：P1及协议/数据一致性/无限等待等P2仍默认阻断1.0。按用户要求，本轮未新增或运行重现/故障注入/独立peer互操作。

## 1. 用户目标与工作方式

用户要求：进入`silly`逐个review网络栈，特别是HTTP、WebSocket、gRPC、Redis、MySQL与etcd；按RFC/官方协议检查兼容性；全部问题、解法和后续回归持续记录。审计过程中用户进一步要求停止新增重现代码和故障注入，改为先完成静态review。

用户希望会话自主持续工作，不要在发完进度后停住。新会话应遵循：

1. 先读本交接文档和主报告，不重做已完成的首轮审计。
2. 当前分支只含报告与既有重现资产，没有Silly源码修复；开始修复前由用户选择issue/批次。
3. 每项修复独立提交，补对应回归并更新主报告状态；保留所有用户改动。
4. HTTP/WebSocket/gRPC的普通测试通过不代表规范符合，回归必须同时检查wire与独立peer。
5. 未经用户重新授权，不新增高风险畸形输入、并发barrier或故障注入。

## 2. 路径、Git 与工作区状态

- 工作区绝对路径：`/home/findstrx/Documents/Codex/2026-08-06-remote`
- Silly 源码绝对路径：`/home/findstrx/Documents/Codex/2026-08-06-remote/silly`
- 主审计报告：`/home/findstrx/Documents/Codex/2026-08-06-remote/silly/SILLY_NET_REVIEW.md`
- 复现脚本目录：`/home/findstrx/Documents/Codex/2026-08-06-remote/silly/review-repros`
- 上游：`https://github.com/findstr/silly.git`
- 审计分支：`codex/silly-net-review`
- 审计基线（`master`）：`d1aef7ffd8439340dfd957a49fccba3fbf133055`
- 提交时间：`2026-07-19 16:09:32 +0800`
- 提交标题：`ci: fix lcov 2.5 coverage capture`
- 上次执行 `git pull --ff-only` 的结果：`Already up to date`
- Silly仓库最终收口检查为干净；当前HEAD以`git log -1`为准。

新会话开始时先做只读核对；不要在审计分支直接pull/merge新master：

```bash
cd /home/findstrx/Documents/Codex/2026-08-06-remote/silly
git status --short --branch
git log -1 --format='%H%n%ci%n%s'
git merge-base HEAD master
```

若用户要求同步新master，应先只读fetch/比较并在独立分支rebase或merge；记录新基线后重新核对受影响issue，不覆盖用户改动。

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
| 4 | engine/worker/message/queue/timer/socket C 核心 | 两轮静态复核完成 |
| 5 | `net.lua` 与 C/Lua 边界 | 两轮静态复核完成 |
| 6 | TCP | 两轮静态复核完成 |
| 7 | UDP | 两轮静态复核完成 |
| 8 | TLS | 两轮静态复核完成 |
| 9 | addr/DNS/cluster | 两轮静态复核完成 |
| 10 | HTTP 公共层 | 两轮静态复核完成 |
| 11 | HTTP/1 + RFC 9110/9112/3986 | 两轮静态复核完成 |
| 12 | HTTP/2 + HPACK + RFC 9113/7541 | 两轮静态复核完成 |
| 13 | HTTP client/server 聚合与互操作设计 | 静态完成；独立peer回归待修复阶段 |
| 14 | WebSocket + RFC 6455/8441 | 两轮静态复核完成 |
| 15 | gRPC over HTTP/2 | 两轮静态复核完成；独立peer回归待修复阶段 |
| 16 | Redis driver | 封板静态复核完成；10项均已归档 |
| 17 | MySQL C codec | 两轮静态复核完成 |
| 18 | MySQL Lua driver | 两轮静态复核完成 |
| 19 | etcd、跨模块取消/超时 | 静态完成；故障注入按用户要求延期 |
| 20 | 文档/API 契约与最终优先级报告 | 已完成 |

原socket候选均已收口：`CAND-SOCK-002`升级为`SOCK-007`，`CAND-SOCK-003`升级为`SOCK-005`，UDP截断候选排除为`REJECT-SOCK-001`。主报告第5节没有遗留候选。

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

修复阶段验证矩阵：MySQL 8、MariaDB 10.6、Go/OpenSSL/官方etcd独立peer、协议畸形输入、fuzz/fault injection及Windows/macOS行为。按用户要求，本轮收口时没有新增或运行这些重现。

### TSAN

隔离 TSAN clone 上次位于：

```text
/tmp/silly-tsan-review.HHFlk0/silly
```

它使用`-DSILLY_TEST -O1 -fsanitize=thread -fno-omit-frame-pointer`构建。`testtcp2`的30组业务断言全部完成，但进程因5组TSAN告警以66退出；后续定向`socket_stat`检查另确认fd/type两组竞争（主报告第7节共列7组）：

1. `engine.c:76` 的 `workerstatus` 写 vs `engine.c:45` 读。
2. `queue.c:91` 的 `size` 读 vs `queue.c:67` 写。
3. `queue.c:75` 的 `head` 读 vs `queue.c:65` 写。
4. `worker.c:94` 的 `maxmsg` 读 vs `worker.c:193` 写。
5. `engine.c:168` 的 `running` 写 vs `engine.c:94` 读。

`/tmp` 内容可能被清理；若路径不存在，应从当前 `silly` 新建隔离 clone/build，不能直接把 TSAN flags 混进主 ASan 工作副本。

### 4.1 `cluster` 分支专项复核

- 远端分支已只读抓取为`origin/cluster`，尖端为`0f2c8773842edb818c1aac74ade3f975d1cbd068`；未checkout或修改分支源码。
- 2026-08-12再次只读查询远端，尖端未变化。
- 与`master`共同祖先为`295f30b879e5c29e12ab2ac1325d8b80abe8fb53`；分支有1个独有提交并落后master 3个提交。
- 既有19项master cluster结论（其中17项在分支仍有对应路径）的状态矩阵及专项审计边界保存在[`CLUSTER_BRANCH_REVIEW.md`](CLUSTER_BRANCH_REVIEW.md)。
- 专项另确认4项分支独有问题：`CLUSTER-B001`（P2，eager connect无deadline）以及`CLUSTER-B002`至`B004`三项P3文档/测试回归；不计入master滚动基线371项统计。
- 本专项仍为纯静态审计，没有运行测试、服务、重现、黑洞连接、partial frame或伪ACK。

## 5. 已确认问题（371 条，完成性反证审计中的滚动基线）

以下是索引；完整触发条件、影响、根因、建议和回归测试都在主报告第 4 节。

| 编号 | 严重度 | 结论 |
|---|---:|---|
| CORE-001 | P2 | worker 条件变量谓词未由同一 mutex 保护，存在真实数据竞争和丢唤醒窗口；TSAN 实证。 |
| CORE-002 | P2 | queue 的 `head`/`size` 在锁外并发读写；TSAN 实证。 |
| CORE-003 | P2 | `volatile running` 不是线程同步，退出状态有数据竞争；TSAN 实证。 |
| CORE-004 | P1 | `pthread_create` 只检查 `err < 0`，漏掉 POSIX 的正错误码，失败回滚不可靠。 |
| CORE-005 | P3 | `worker.maxmsg` 诊断阈值跨线程普通读写；TSAN 实证。 |
| CORE-006 | P2 | timer把64位毫秒delta窄化为int，长暂停/时钟跳变可崩溃、错时或产生巨量catch-up循环。 |
| CORE-007 | P2 | socket/timer命令flip buffer以signed 32-bit扩容且无溢出/总量检查，极端积压可触发UB、错误realloc或越界copy。 |
| CORE-008 | P2 | macOS/Windows openfds恒0且RSS退化成heap，运行时资源监控错误并让TCP fd泄漏回归0→0假通过。 |
| CORE-009 | P2 | time.now仅在启动时采样墙钟，系统校时后持续偏离其承诺的当前Unix时间戳。 |
| CORE-010 | P2 | trace root只有16-bit秒与sequence，突发或约18.2小时常规长运行会复用ID并合并无关调用链。 |
| CORE-011 | P2 | silly.genid是重启归零的32-bit进程计数器，却承诺全局唯一并被JWT指南用于唯一用户/JTI。 |
| CORE-012 | P2 | patch.collectupval把module所有字段当函数，VERSION/config等普通常量使热更新立即崩溃。 |
| CORE-013 | P1 | TCP console零认证开放INJECT/DEBUG，custom command认证又无法拦截优先分发的内置敏感命令。 |
| METRIC-001 | P2 | Prometheus label value未转义quote/backslash/LF，网络字段可破坏整次scrape或注入伪造exposition行。 |
| METRIC-002 | P1 | Prometheus Histogram导出非累计bucket且+Inf不是总样本数，分位数、SLO与告警稳定失真。 |
| METRIC-003 | P2 | jemalloc native按allocated-first返回，但Prometheus与console按resident-first解包，两个内存指标互换。 |
| METRIC-004 | P2 | registry只按对象引用去重；不同对象同名会导出重复HELP/TYPE/sample并使Prometheus scrape失败。 |
| METRIC-005 | P2 | 内置network sent bytes在payload排队时计满，partial、失败或close未发送字节也永久算作已发送。 |
| METRIC-006 | P2 | metric/label name和HELP未校验或转义，公开descriptor可破坏/注入scrape并与Histogram保留le冲突。 |
| METRIC-007 | P2 | Histogram不校验bucket集合；空数组部分更新后崩溃，重复边界导出重复series。 |
| METRIC-008 | P2 | 非空Vector调用零参数labels()绕过arity校验，静默导出缺失全部声明标签的series。 |
| METRIC-009 | P2 | gather格式化异常不清共享buffer，一次坏Gauge/custom metric值可永久毒化全部后续scrape。 |
| METRIC-010 | P2 | Registry采集期间注销会使live数组左移，跳过collector并最终调用nil:collect()。 |
| METRIC-011 | P2 | Histogram bucket格式字符串进入无界全局强缓存，动态边界跨注销/GC永久泄漏。 |
| NET-001 | P2 | listener close与已排队ACCEPT竞态时只assert，不关闭已注册的accepted fd，形成孤儿连接。 |
| NET-002 | P2 | raw data callback异常时C message已放弃payload ownership，task错误路径不会释放，形成可重复内存泄漏。 |
| NET-003 | P1 | multipack裸refcount在send失败重试或fanout偏小时可提前释放仍由异步send引用的共享buffer。 |
| NET-004 | P2 | 低层listen/connect在socket发布后才校验event回调；缺字段异常会遗留不可达fd，无accept listener还可被远端重复触发。 |
| NET-005 | P1 | TCP/TLS单reader门禁晚于缓存fast path，并发read可偷走旧operation字节并令其永久挂起。 |
| NET-006 | P1 | TCP/TLS buffer limit可在当前read满足前暂停transport，唯一reader无法降水位而永久自锁。 |
| NET-007 | P2 | 大于UINT32_MAX的合法Lua整数timeout在fd/waiter发布后令native timer抛错，可毒化TCP/TLS/UDP/H2对象并遗留connect/gRPC资源。 |
| NET-008 | P1 | TCP native buffer以signed int累计无界backlog，超过INT_MAX触发UB并可令read永久nil或readall断言终止。 |
| UDP-001 | P2 | bound socket缺destination仍返回成功后静默丢包，connected socket的显式destination又被C层忽略。 |
| TLS-001 | P1 | TLS client保持OpenSSL默认VERIFY_NONE，既不验证证书链也不验证hostname，HTTPS/WSS/gRPC可被MITM。 |
| TLS-002 | P1 | accepted TLS不保活SNI callback ctx，reload/close+GC后在途ClientHello可访问失效userdata。 |
| TLS-003 | P1 | SSL_read的close/fatal/WANT_WRITE状态全被吞掉，TLS reader可永久挂起且alert不flush。 |
| TLS-004 | P2 | TLS正常close只断TCP、从不发送close_notify，peer无法获得authenticated EOF。 |
| TLS-005 | P1 | TLS server在业务accept前无期限等待ClientHello，空连接可永久占用fd/SSL/task。 |
| TLS-006 | P2 | TLS server显式允许TLS1.1、client不设minimum，版本安全基线依赖环境并偏离RFC8996。 |
| TLS-007 | P2 | TLS listener先于ctx发布，证书/key/cipher配置失败会泄漏listener并留下失效accept回调。 |
| TLS-008 | P2 | TLS reload先污染保存配置再构造ctx，失败会抛异常并留下旧ctx/坏conf混合状态。 |
| TLS-009 | P2 | TLS read(0)被当作未满足并登记唯一waiter；WSS收到合法空Close/Ping/Pong/data frame也会永久挂起。 |
| TLS-010 | P2 | ciphers只限制TLS1.2及以下，TLS1.3仍使用OpenSSL默认套件且混合配置静默假成功。 |
| TLS-011 | P1 | plaintext buffer以signed int无检查扩容，累计远端数据可溢出并污染SSL_read写地址/长度。 |
| TLS-012 | P2 | client在TCP发布后才编码ALPN/创建SSL，初始化异常发生在owner发布前并遗留不可达连接。 |
| TLS-013 | P2 | certificate table长度由Lua integer窄化为int，伪造__len可破坏native flexible-array ctx布局。 |
| TLS-014 | P2 | vectored write后段失败会把已生成prefix ciphertext留在out BIO，并由未来无关write迟发。 |
| TLS-015 | P2 | certificate字段类型错误以Lua longjmp绕过native cleanup，未提交给userdata的SSL_CTX永久泄漏。 |
| TLS-016 | P2 | 未协商ALPN被返回为空字符串而非nil，Lua truthiness会把absence误判为已协商。 |
| TLS-017 | P3 | native ctx/tls显式free后GC再次进入同一strict finalizer，会对正常tombstone抛类型错误。 |
| TLS-018 | P2 | ALPN编码允许零长度协议且client忽略OpenSSL校验返回，配置被静默清空并可协议降级。 |
| DNS-001 | P2 | CNAME/SRV/SOA解析可跨越声明RDLENGTH借用后续字节，A/AAAA也接受非精确长度。 |
| DNS-002 | P1 | DNS response三section被抹平且CLASS丢失，无关低trust记录可覆盖任意名字的既有cache。 |
| DNS-003 | P1 | DNS新名字TXID恒从1递增且每server长期复用单一UDP source port，伪响应entropy显著不足。 |
| DNS-004 | P2 | ndots被误作是否search的开关，低/高点数候选顺序与trailing-dot absolute语义均错误。 |
| DNS-005 | P2 | 单次查询的全部retry固定在同一nameserver，健康备用服务器只能影响后续查询而不能接管当前请求。 |
| DNS-006 | P2 | TC fallback的TCP connect没有deadline，请求已超时后task/socket仍可滞留并发布迟到连接。 |
| DNS-007 | P2 | public timeout在每个CNAME hop/search候选重新计时，无法约束整次lookup/resolve耗时。 |
| DNS-008 | P2 | parser抹平NXDOMAIN/NODATA，name error被按qtype缓存，无法跨type命中并允许冲突状态。 |
| DNS-009 | P2 | 普通非尾随点域名的query encoder在最后label后构造end+1指针，正常查询进入C未定义行为。 |
| DNS-010 | P2 | RR结构/RDATA解析失败只break或skip，malformed response的有效前缀仍按成功提交cache并完成请求。 |
| DNS-011 | P2 | caller timer晚于singleflight waiter发布，超范围timeout抛错会遗留dead task并打断其他waiter完成。 |
| DNS-012 | P2 | dns.conf在验证新配置前先销毁旧resolver，任意后续异常会留下空或半配置的全局DNS状态。 |
| DNS-013 | P2 | 主动发送EDNS0 OPT却跳过response OPT，extended RCODE/version丢失并把扩展错误误报为空答案。 |
| DNS-014 | P2 | RRset cache只采用wire首条TTL，未按RFC 2181取组内最低值，缓存寿命受记录顺序控制。 |
| DNS-015 | P1 | 每个查询名字永久intern到server cache，expired/TTL0/timeout/send failure均不删除且无容量预算。 |
| DNS-016 | P2 | Windows resolver配置扩容不检查malloc结果，OOM时仍把NULL输出buffer传给GetNetworkParams。 |
| DNS-017 | P3 | Windows hosts路径只验证system directory自身长度，追加后缀后可截断并静默忽略hosts配置。 |
| DNS-018 | P1 | 系统resolver配置读取失败或显式空列表时自动改用公共8.8.8.8，绕过本机DNS策略并泄漏查询。 |
| CLUSTER-001 | P1 | cluster response只按全局session匹配，任一peer或wrap后的late ACK可跨连接完成其他RPC。 |
| CLUSTER-002 | P2 | cluster peer断线/主动close不结束其pending RPC，waiter与timer只能保留到全局timeout。 |
| CLUSTER-003 | P2 | unknown/late/duplicate ACK会对nil coroutine执行wakeup，连接保持并可持续制造异常/日志。 |
| CLUSTER-004 | P2 | cluster主动close不清C parser的per-fd incomplete buffer，默认单块可滞留至128MiB。 |
| CLUSTER-005 | P1 | hardlimit允许超过INT_MAX，frame长度可先变负并以巨大Lua string pop，最大值还会使allocation/total回绕。 |
| CLUSTER-006 | P2 | cluster wire直接复制native整数/struct，大小端不同节点无法互操作且文档格式也与实现不符。 |
| CLUSTER-007 | P2 | accept adapter参数错位，incoming peer.remoteaddr实际保存listener sid而非客户端endpoint。 |
| CLUSTER-008 | P1 | RPC timeout在lazy DNS/TCP connect之后才启动，黑洞endpoint可使call无限等待并阻塞同peer callers。 |
| CLUSTER-009 | P2 | send与call使用相同request frame，正常handler response会成为unmatched ACK并触发本地异常。 |
| CLUSTER-010 | P2 | hostname硬编码单次A lookup，无AAAA或多地址connect fallback，IPv6-only/首地址故障时不可用。 |
| CLUSTER-011 | P1 | 完整frame ring与handler并发无count/byte上限，单个2MiB read可放大为约十万排队帧/慢task。 |
| CLUSTER-012 | P1 | 仅收4-byte length便预分配完整body，默认每连接可占128MiB且无partial deadline/global budget。 |
| CLUSTER-013 | P3 | cluster随机分片测试把期望值当作`assert`错误消息，从未比较重组packet，完整性检查恒通过。 |
| CLUSTER-014 | P2 | RPC timeout直到request发出后才验证，非法配置会造成远端已执行而本地抛错及重试歧义。 |
| CLUSTER-015 | P1 | 同批次合法frame后的解析错误会把已完成frame留在全局ring，跨错误连接累积并可能迟延分发ACK。 |
| CLUSTER-016 | P1 | master与raw-string分支均固定明文TCP且无节点认证/消息完整性，可达主机即可调用RPC或篡改重放。 |
| CLUSTER-017 | P2 | master允许任意Lua integer命令ID并静默窄化为uint32，低32位相同的不同命令会在远端碰撞错投。 |
| CLUSTER-018 | P2 | 重复serve会静默替换所有listener/peer共享的parser与handler；官方多节点示例因此全部使用最后配置，活跃重配还会错接在途状态。 |
| CLUSTER-019 | P2 | master codec异常越过call/send错误tuple；server marshal/unmarshal throw只留task日志并让远端等到timeout。 |
| ADDR-001 | P2 | IP分类忽略Lua string的embedded-NUL后缀，校验/日志中的地址可与socket实际endpoint不同。 |
| ADDR-002 | P2 | `addr.parse("[::1]")`等无端口bracket输入构造`se+1`指针并比较，公开正常路径触发C未定义行为。 |
| URL-001 | P1 | URL fragment未从HTTP target剥离，OAuth token等client-side secret可进入request-line/:path与服务端日志。 |
| URL-002 | P2 | URL显式port绕过supported-scheme校验，HTTP/WS consumer对未知scheme回落明文TCP并发起连接。 |
| URL-003 | P2 | relative URL resolver不拆path/query、不移除dot-segments且错误处理empty ref，redirect target偏离RFC3986。 |
| HTTPC-001 | P1 | convenience client无响应body上限且自动gzip解压无output/ratio budget，恶意响应可耗尽内存。 |
| HTTPC-002 | P1 | HTTP client无端到端deadline/cancel，DNS/connect/TLS/headers/body任一阶段都可永久挂住调用。 |
| HTTPC-003 | P2 | pool lookup为每个失败origin永久创建H1/H2空表，高基数host可使client内存无界增长。 |
| HTTPC-004 | P2 | hostname固定单次A lookup且只连接首地址，IPv6-only或首地址故障origin不可用。 |
| HTTPC-005 | P1 | close可与在途建连交错，返回后迟到H1/H2 transport仍重新入池并继续请求。 |
| HTTPC-006 | P2 | redirect把301/302/303的所有方法改成GET且只清两项body header，破坏PUT/PATCH/DELETE/HEAD语义。 |
| HTTPC-007 | P2 | H1/H2重复Location/Content-Encoding变array，高层redirect/gzip按string调用并抛未捕获Lua类型异常。 |
| HTTPC-008 | P2 | H2 pool entry以lastfree=0发布且stream close不记录idle起点，新channel在首次扫描被提前淘汰。 |
| HTTPC-009 | P2 | pool用浮点除法派生timer周期，奇数idle_timeout在资源入池后抛异常，非正值可形成0ms循环。 |
| COMP-001 | P2 | gzip inflate不要求`Z_STREAM_END`或完整消费输入，截断/拼接流可被部分成功接受。 |
| REDIS-001 | P1 | 畸形RESP会抛出未清理异常并永久占住reader token，使后续请求全部挂起。 |
| REDIS-002 | P2 | command write失败调用reader-only清理并assert，pipeline则遗留坏socket。 |
| REDIS-003 | P1 | connect/handshake/command/pipeline和reader queue均无deadline/cancel，一个slow peer可挂住整个client。 |
| REDIS-004 | P1 | RESP line/bulk/aggregate没有大小、元素数、总量或递归深度预算，可耗尽内存/CPU/stack。 |
| REDIS-005 | P2 | close无法看到in-flight connect/handshake，晚到连接可在对象关闭后重新发布并泄漏。 |
| REDIS-006 | P2 | RESP null映射为Lua nil后aggregate/pipeline槽位消失，合法响应无法保留长度和位置。 |
| REDIS-007 | P2 | SUBSCRIBE后无push reader/subscription state，异步message会与后续命令response错配并无API交付。 |
| REDIS-008 | P1 | 共享连接不隔离MULTI/WATCH会话，其他协程命令可被并入错误事务并改变EXEC结果。 |
| REDIS-009 | P1 | client固定明文TCP，AUTH credential及全部数据无法用TLS保护，也不能连接TLS-only Redis。 |
| REDIS-010 | P2 | RESP aggregate丢失嵌套error的type与位置，EXEC结果无法按命令可靠归因。 |
| MYSQLC-001 | P1 | binary result row未验证NULL bitmap长度即直接索引，截断packet可造成C越界读。 |
| MYSQLC-002 | P2 | BIGINT UNSIGNED高半区经signed lua_Integer返回为负值，合法数据发生静默wrap。 |
| MYSQLC-003 | P2 | DATE/TIMESTAMP/TIME非法length可返回硬编码时间、跨列消费或留下字节，整行错位。 |
| MYSQLC-004 | P2 | 未协商SESSION_TRACK时仍把OK info按lenenc解析，正常成功响应可抛错或失真。 |
| MYSQLC-005 | P1 | prepared encoder跨luaL_Buffer扩容持有旧null/type pointer，合法大参数可损坏wire/内存。 |
| MYSQLC-006 | P2 | row只按column alias建表且无ordinal模式，duplicate columns会静默覆盖。 |
| MYSQLC-007 | P1 | unsigned64 lenenc经signed/可wrap cursor运算可绕过边界并进入native OOB read。 |
| MYSQLC-008 | P3 | pre-handshake ERR无SQLSTATE时parser仍吞一个marker byte，连接错误message首字节丢失。 |
| MYSQLC-009 | P2 | native codec错误把整个MySQL packet hex写入异常，泄漏敏感row并将大包至少放大两倍。 |
| MYSQL-001 | P1 | idle/lifetime淘汰及leaked lease GC均不递减open_count，受限pool可永久假满。 |
| MYSQL-002 | P1 | driver无TLS/server identity且full-auth信任peer临时RSA key，MITM可读取流量并取得密码。 |
| MYSQL-003 | P1 | connect/auth/query/pool wait均无deadline/cancel，现有connect_timeout选项被静默忽略。 |
| MYSQL-004 | P1 | conn归池后旧对象仍可操作且close不幂等，可让多个borrower并发共享同一MySQL stream。 |
| MYSQL-005 | P1 | COMMIT/ROLLBACK失败仍清除transaction flag并归池，后续borrower可继承未知事务状态。 |
| MYSQL-006 | P2 | conn_new不执行closed状态，close后ping/begin及被唤醒waiter仍可新建连接并执行SQL。 |
| MYSQL-007 | P2 | MySQL packet fragmentation/sequence未实现，≥0xffffff payload与zero terminator会反同步。 |
| MYSQL-008 | P1 | global/per-connection prepared caches无界且从不COM_STMT_CLOSE，可耗尽client/server资源。 |
| MYSQL-009 | P1 | max_packet_size只写入握手且result全量累计无总预算，大响应可耗尽内存。 |
| MYSQL-010 | P1 | multi-result状态机不读取新header/metadata，剩余response可污染pool并与下一请求串线。 |
| MYSQL-011 | P1 | codec/unpack异常绕过fatal cleanup，login泄漏pool容量、query把反同步连接归池。 |
| MYSQL-012 | P2 | HandshakeV10 auth seed用错capability且固定12-byte part2，合法server/plugin可认证失败。 |
| MYSQL-013 | P2 | COM_PING response无条件按OK解码，合法server ERR可被误报为健康或触发codec异常。 |
| MYSQL-014 | P2 | BEGIN/COMMIT/ROLLBACK把任意非ERR packet当成功并提交本地transaction状态。 |
| MYSQL-015 | P1 | result metadata/row loops不识别ERR且row decoder不验0x00 header，错误包可变成列或业务row。 |
| MYSQL-016 | P1 | broken connection释放capacity后不唤醒waiter，受限pool已有请求可永久停在task.wait。 |
| MYSQL-017 | P1 | transaction conn无command并发门禁，第二协程可先写命令再触发single-reader断言并错配响应。 |
| MYSQL-018 | P2 | pool waiter按LIFO handoff，持续新请求可让最早排队的调用无限饥饿。 |
| MYSQL-019 | P2 | checkout用returned_at而非created_at判断max_lifetime，繁忙连接可永不轮换。 |
| MYSQL-020 | P2 | initial sha256_password握手仍发送mysql_native SHA-1 token，合法MySQL账号无法认证。 |
| ETCD-001 | P1 | mutation RPC在结果未知的transport失败后无条件重放，可产生重复revision/watch事件和孤儿lease。 |
| ETCD-002 | P1 | watch公开revision参数未映射到start_revision，承诺的历史事件回放被静默忽略。 |
| ETCD-003 | P1 | watch重连不记录created/progress revision且忽略fragment边界，可静默漏掉断线窗口事件。 |
| ETCD-004 | P1 | lease TTL秒值直接进入毫秒scheduler且send后不推进状态，可将长TTL续租放大成每500ms一次。 |
| ETCD-005 | P1 | watch response进入无界channel且弃用watcher仍被client强引用，高频事件可持续耗尽内存。 |
| ETCD-006 | P1 | dialtimeout只被存储、未传入gRPC/TCP/TLS或RPC，故障endpoint可让调用无限挂起。 |
| ETCD-007 | P2 | range option适配器漏设空fromkey的range_end，并丢弃非KEY排序的order。 |
| ETCD-008 | P2 | unknown或late watch_id会nil dereference，recv异常又不触发EOS，整条watch manager永久停止。 |
| ETCD-009 | P1 | etcd wrapper无TLS、CA/client cert或token认证入口，只能连接明文未授权集群。 |
| ETCD-010 | P2 | lease keepalive重连不关闭旧stream或取消旧sender，可累积重复发送循环与资源。 |
| ETCD-011 | P2 | watch公开签名中的wait/limit不属于wire schema且实现不消费，编码时被静默丢弃。 |
| ETCD-012 | P2 | retry被当作总attempt数、零值跳过RPC，ttl/leases又完全绕过该client级配置。 |
| ETCD-013 | P2 | client关闭后watch仍返回成功对象，其control enqueue已失败且read channel会永久等待。 |
| ETCD-014 | P2 | 旧watch recv的无generation迟到EOS可关闭已发布的新stream并触发额外重连。 |
| ETCD-015 | P2 | client关闭后keepalive仍静默登记但无存活owner，lease会在调用“成功”后过期。 |
| ETCD-016 | P2 | watch compaction取消丢弃完整响应、恢复revision与server cancel reason。 |
| ETCD-017 | P1 | watch长期借用并改写caller table，复用或后改会污染watch ID、观察范围与重连请求。 |
| DOC-001 | P3 | etcd双语文档的构造返回、timeout、自动keepalive、失联处理和watch close均偏离API。 |
| DOC-002 | P3 | DNS中英文文档宣称默认三次递增重试，与实现默认两次固定5秒及同页配置表冲突。 |
| DOC-003 | P3 | HTTP中英文文档虚构respond close参数，且统一返回承诺与H1 nil/H2 boolean实现不符。 |
| DOC-004 | P3 | gRPC中英文reference的签名和每份14个registrar示例均遗漏必需service_name，照抄无法注册服务。 |
| DOC-005 | P3 | Redis中英文pipeline示例使用不存在的out参数，select也未产生文档承诺的迁移提示。 |
| DOC-006 | P3 | etcd双语“事务性操作”示例只做独立get/put，wrapper也没有txn方法，无法提供原子性。 |
| DOC-007 | P3 | TCP/TLS双语reference、guide与benchmark使用底层拒绝的多字节CRLF delimiter，示例会立即抛错。 |
| DOC-008 | P3 | DNS双语reference声明不存在的环境变量路径覆盖，设置后仍读取固定系统resolver与hosts。 |
| DOC-009 | P3 | TLS双语reference的validate示例漏listener addr，或把hostname直接传给numeric-only connect。 |
| DOC-010 | P3 | TLS底层LuaLS声明仍描述文件路径ctx和boolean handshake，与真实PEM表及三态整数ABI相反。 |
| DOC-011 | P3 | TLS双语指南宣称Silly自动获得session resumption/0-RTT，binding却未保存复用session或开放early-data。 |
| DOC-012 | P3 | HTTP双语reference公开listen.backlog，但http.lua的TCP/TLS分支均未转发，配置静默无效。 |
| DOC-013 | P3 | 中文HTTP reference虚构默认5秒的newclient.read_timeout，实际字段被静默忽略且请求仍可无限等待。 |
| DOC-014 | P3 | HTTP双语reference/中文guide宣称支持server push，实际无push API且client SETTINGS明确禁用。 |
| DOC-015 | P3 | HTTP双语文档反称H2不支持已实现的write，并指向不存在的close(body)发送API。 |
| DOC-016 | P3 | 中文HTTP reference与双语guide错称不支持连接池，实际顶层/专用client均复用H1/H2。 |
| DOC-017 | P2 | 双语HTTP/2最佳实践遗漏tls开关和server ALPN，原样启动明文H1且证书不生效。 |
| DOC-018 | P2 | 双语WebSocket教程在完整缓冲后才检查消息大小，不能防止其声称的恶意大消息内存耗尽。 |
| DOC-019 | P3 | WebSocket双语reference虚构partial read/正常continuation结果，并把实际返回result的close写成无返回值。 |
| DOC-020 | P3 | WebSocket双语教程的广播优化调用不存在的channel `recv/send`方法，两侧首次调用均异常。 |
| DOC-021 | P2 | WebSocket双语教程用稀疏clients map的`#`做统计和连接上限，断开后可低估并放行超额连接。 |
| DOC-022 | P2 | WebSocket完整聊天室把远端昵称写入`innerHTML`，20字节限制仍可形成存储型跨用户XSS。 |
| DOC-023 | P2 | WebSocket教程把浏览器可选Ping当作自动心跳，server无主动探测/Pong deadline，silent连接可长期残留。 |
| DOC-024 | P2 | WebSocket完整server不验证JSON schema；合法primitive/错型字段可抛异常并跳过clients registry清理。 |
| DOC-025 | P3 | WebSocket双语入门示例记录wrapper不存在的`sock.fd`，断线连接标识恒为nil。 |
| DOC-026 | P3 | gRPC双语reference混用三类streaming API；示例调用不存在的方法并以RST取消上传。 |
| DOC-027 | P1 | MySQL连接池指南断线后重放任意SQL，结果未知的非幂等写可被重复提交。 |
| DOC-028 | P3 | MySQL双语健康检查/预热/监控/关闭示例广泛调用不存在的silly wait/time/signal接口并遗漏导入。 |
| DOC-029 | P3 | MySQL双语reference错称row key转为小写，实际server column alias大小写原样保留。 |
| DOC-030 | P1 | MySQL双语转账教程用非锁定读校验余额且不验证UPDATE影响行数，可并发透支或只扣不加。 |
| DOC-031 | P3 | MySQL双语监控在pool query前连续取时间戳，等待指标恒近零而真实排队被误算成慢SQL。 |
| DOC-032 | P1 | MySQL死锁重试示例只捕获Lua异常并丢弃callback返回ERR，可提交此前成功的部分事务。 |
| DOC-033 | P2 | MySQL双语指南称max_idle_conns=0为无限，实际实现和测试都把0当作禁用idle复用。 |
| DOC-034 | P3 | MySQL inline LuaLS把row值全标string且把真实err.sqlstate拼成不存在的sql_stage。 |
| DOC-035 | P3 | etcd把int64删除数量标成boolean，Lua中0仍为truthy会让照文档判断的调用方误报成功。 |
| DOC-036 | P3 | etcd Event.type标成integer，但默认codec、真实测试与双语示例都使用PUT/DELETE字符串。 |
| DOC-037 | P3 | etcd双语reference共32处示例调用不存在的silly.sleep，等待后的watch/lease/清理流程不会执行。 |
| DOC-038 | P3 | cluster双语reference称listen backlog默认128，master与raw-string分支实际都继承通用默认256。 |
| DOC-039 | P3 | master cluster reference一处称connect是无yield的同步handle构造，另一处又称直接调用报错且必须task.fork。 |
| DOC-040 | P3 | cluster文档一处承诺silly.errno/errno.TIMEDOUT，另一处又把全部错误定义为禁止比较的opaque string。 |
| DOC-041 | P3 | master cluster双语reference遗漏实现/LuaLS已支持的hardlimit与softlimit，用户无法发现唯一frame预算入口。 |
| DOC-042 | P3 | cluster LuaLS把master可选timeout标必填、numeric cmd标string-only，并把两版空队列pop错误标成必有tuple。 |
| DOC-043 | P3 | etcd generated LuaLS把可缺失Event.prev_kv标必有、给空WatchProgressRequest虚构字段，双语watch表还漏真实prev_kv选项。 |
| DOC-044 | P3 | net/DNS native LuaLS把multipack返回、multicast参数、errno和answer nil分支标反，并漏掉真实multifree/ntop导出。 |
| DOC-045 | P3 | protobuf/protoc LuaLS把option setter、bit conversion、iterator/slice多返回及path API标成错误契约。 |
| DOC-046 | P2 | 低层net双语reference统一用只复制不释放的silly.tostring消费payload，官方正常示例逐包泄漏且错误禁止callback yield。 |
| DOC-047 | P3 | 英文已发布完整silly.net.http.url reference并加入索引，中文页面和导航均完全缺失。 |
| DOC-048 | P2 | HTTP server双语教程的恶意大上传防护只信单值Content-Length，可被chunked、TE+CL或重复CL绕过。 |
| DOC-049 | P3 | HTTP双语最佳实践的gzip、流式sleep、协程timeout和健康检查示例调用不存在模块、顶层方法或未导入local。 |
| DOC-050 | P2 | HTTP最佳实践的请求timeout只停止外层等待，fork中的正文/下游/业务操作仍继续、残留或二次响应。 |
| DOC-051 | P2 | 多组官方HTTP监控示例把任意原始path作为永久Prometheus label，唯一404 URL可线性增加series与heap。 |
| DOC-052 | P2 | HTTP限流示例以首冒号截断IPv6并把one-shot timer当周期cleanup，导致配额串扰和client key永久积累。 |
| DOC-053 | P3 | 双语core reference把silly.tostring写成单参数pointer hex formatter，实际是必需size且不释放的内存复制。 |
| DOC-054 | P2 | 双语监控示例用进程CPU时钟测异步HTTP/DB/cache等端到端耗时，等待被漏计且并发CPU混入SLO。 |
| DOC-055 | P2 | 双语“生产级”HTTP示例把真实404/500记为200且漏掉413/429，错误率、总量与SLO假健康。 |
| DOC-056 | P2 | 双语反向代理示例监听全接口却无条件信任X-Real-IP/XFF，直连或代理链可伪造客户端身份。 |
| DOC-057 | P2 | 双语logging指南对只支持%s的logger.*f使用%d/%.3f，完整HTTP示例每个请求收尾都会抛错。 |
| DOC-058 | P2 | logging/logger双语示例用SIGUSR1切日志级别，覆盖logger内置reopen并使轮转静默失效。 |
| DOC-059 | P3 | logging双语指南把trace.spawn返回的旧上下文当成新trace ID，后续传播会关联错误链路。 |
| DOC-060 | P3 | logging双语跨服务示例把stream:readall第二返回的error当HTTP status，成功状态恒为nil。 |
| DOC-061 | P2 | logging双语生产示例异常时不递减in-flight、不记录duration且可能在已响应后再发500。 |
| DOC-062 | P3 | logging双语独立示例require不存在的json模块，告警循环又调用未导入的task.fork。 |
| DOC-063 | P2 | logger双语reference错称禁用级别不会求值实参，昂贵序列化和副作用仍在热路径执行。 |
| DOC-064 | P3 | logging双语Grafana查询引用不存在的process_cpu_seconds_total，默认CPU面板恒为No data。 |
| DOC-065 | P3 | Gauge双语reference仍宣称add(v)只加1并给出错误输出，当前实现已按v增加。 |
| DOC-066 | P3 | 英文Gauge reference在示例中途截断并保留模型“后续另发”占位文本，缺失后半页。 |
| DOC-067 | P3 | Histogram双语完整示例调用不存在的silly.time，首个请求在记录指标前异常。 |
| DOC-068 | P3 | 双语文档漏写gather(registry)，隔离Registry教程转而手写不支持Histogram的exporter。 |
| DOC-069 | P2 | Gauge活跃连接示例按HTTP stream计数且异常不回滚，H1/H2连接容量指标持续失真。 |
| DOC-070 | P3 | Collector必需字段在LuaLS与Collector/Prometheus/Registry双语reference间互相冲突。 |
| DOC-071 | P2 | 热更新循环timer不返回handle，cancel/restart无效且每次hotfix叠加永久周期任务。 |
| DOC-072 | P3 | 热更新流程只复制function，却断言VERSION/BUILD_TIME等普通导出字段已经同步到新版本。 |
| DOC-073 | P2 | 热更新加载失败没有finally恢复package.loaded，后续require可产生另一份module/singleton状态。 |
| DOC-074 | P3 | 热更新HTTP route示例调用不存在的res:status/res:send，真实server只传单个stream。 |
| DOC-075 | P2 | Echo教程把tcp.listen普通失败写成抛异常，全部server示例又丢弃真实nil/errno而静默无服务。 |
| DOC-076 | P2 | Echo教程声称accept callback正常返回自动close，runtime只立即关闭异常路径，正常返回依赖不确定GC。 |
| DOC-077 | P3 | Echo性能示例把最后创建的client误作完成屏障，并用秒级os.time产生部分或无穷吞吐。 |
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
| SOCK-013 | P2 | nonblocking设置失败只写日志，blocking fd仍进入poller并可能挂死唯一socket线程。 |
| SOCK-014 | P2 | stale close在sid校验后可跨越free/reuse，把CLOSING状态写入新generation并抑制其事件。 |
| SOCK-015 | P2 | 合法fd 0的异步TCP connect完成路径错误断言fd必须大于0，可终止进程。 |
| SOCK-016 | P2 | Windows控制唤醒通道是Winsock socket，却用CRT close销毁，导致handle泄漏并可能误关无关CRT fd。 |
| SOCK-017 | P2 | Windows accept耗尽恢复以CRT `/dev/null` fd充当Winsock reserve，释放不了socket槽并可能让listener热循环。 |
| SOCK-018 | P1 | Windows控制socket路径未检查目录API required length，长路径使`sun_path+n`越界并以巨大size写栈。 |
| SOCK-019 | P2 | TCP listen/connect/accept/stat把Win64指针宽度SOCKET截成int，可泄漏、误注册、误读写或误关连接。 |
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
| HTTP1-011 | P1 | outbound method/target未校验便进入request-line，literal CRLF可注入字段、空行或第二请求。 |
| HTTP1-012 | P2 | 101后client仍可把升级连接归H1 pool，server也继续HTTP parse loop，造成协议状态混淆。 |
| HTTP1-013 | P2 | Connection只精确比较close且忽略HTTP版本，token list/大小写及HTTP/1.0默认关闭均失效。 |
| HTTP1-014 | P2 | closewrite吞掉write/长度错误且不验证fixed-length完成，可发送不完整message后永久等待。 |
| HTTP1-015 | P2 | server无interim response状态使Expect双方互等，client又把102/103首个1xx误作final。 |
| HTTP1-016 | P1 | sender可原样生成TE+CL，并因CL优先而用固定长度直写正文，与chunked声明形成边界歧义。 |
| HTTP1-017 | P2 | bodyless status遗漏205，client可等待EOF至永久且server可生成规范禁止的content。 |
| HTTP1-018 | P1 | fixed-length body每次成功读取将recvbytes累计两遍，可提前判完整并把残留body连接归池。 |
| HTTP1-019 | P1 | chunked write空字符串会提前生成last-chunk但保持可写，closewrite空串还会生成双终止块污染下一消息。 |
| HTTP1-020 | P1 | Content-Length用Lua tonumber宽松解析，符号/hex/指数/小数可制造与严格peer不同的消息边界。 |
| HTTP1-021 | P1 | sender按Lua key大小写识别控制字段，常规Content-Length/Host拼写可被重复并自动生成TE+CL歧义wire。 |
| HTTP1-022 | P2 | server把HEAD/304与1xx/204一刀切删除CL/TE，丢失规范允许且常用的representation长度元数据。 |
| HTTP1-023 | P2 | 读取失败后若stream buffer有部分正文，第二次readall会返回残缺data,nil并吞掉cached error。 |
| WS-001 | P1 | server接受缺失/无效opening handshake；H2 GET也可收到非法101并返回`conn=nil` socket，继发异常/泄漏。 |
| WS-002 | P1 | client 仅凭 101 status 接受握手，不验证 Accept 或 Upgrade/Connection。 |
| WS-003 | P2 | parser缺少RSV/长度/control校验；64-bit高位转负后TCP重新分帧、TLS挂起，writer边界也非规范。 |
| WS-004 | P2 | fragmentation 状态机接受 standalone continuation 和进行中插入的新 data message。 |
| WS-005 | P1 | frame 与 fragmented message 没有大小上限或 deadline，可被远端耗尽内存。 |
| WS-006 | P2 | text message 与 Close reason 的收发均不验证 UTF-8。 |
| WS-007 | P2 | Close payload/status 与 CLOSING/CLOSED状态机缺失；主动close立即断TCP，重复close/`__close`会抛异常。 |
| WS-008 | P1 | client masking key 与 handshake nonce 使用 time-seeded、小空间弱随机源。 |
| WS-009 | P2 | client hostname固定单次A lookup且只连首地址，IPv6-only或首地址故障服务不可用。 |
| WS-010 | P1 | client opening handshake没有端到端deadline/cancel，silent peer可长期占住task和socket。 |
| H2-001 | P2 | HTTP/2 client 接受 server 非法发送的 `SETTINGS_ENABLE_PUSH=1`，未触发 `PROTOCOL_ERROR`。 |
| H2-002 | P2 | 通用 frame reader 把非 padding frame 的 unused 0x08 当成 PADDED，改写 payload 或错误断连。 |
| H2-003 | P1 | HTTP/2不维护receive window且按剥离padding后的长度回补；超额DATA被缓存，合法padded DATA也会永久耗尽credit。 |
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
| H2-017 | P2 | 完整响应后的RST在对象尚存时覆盖结果，对象回收后又被误判idle并GOAWAY。 |
| H2-018 | P2 | request/response/trailer sender 无 field validation，可主动生成 malformed message。 |
| H2-019 | P1 | server request validator 缺少最低 field name/value octet 校验。 |
| H2-020 | P1 | outbound field block 跨 frame 时末帧错误地再次发送 HEADERS。 |
| H2-021 | P2 | SETTINGS initial-window overflow 被错误降级为 stream reset。 |
| H2-022 | P2 | Content-Length mismatch 被错误升级为整连接 GOAWAY。 |
| H2-023 | P1 | initial HEADERS拒绝可复用id/泄漏quota，early-END长度失败还会在teardown后发布并调用handler。 |
| H2-024 | P1 | client 淘汰 local-RST tombstone 后不 minimally process late HEADERS/HPACK。 |
| H2-025 | P1 | handshake/frame/header-block reads 无 progress deadline 或配置入口。 |
| H2-026 | P1 | client 禁用 push 后仍静默忽略 PUSH_PROMISE并跳过 HPACK。 |
| H2-027 | P1 | server handler异常绕过stream收尾，map/并发配额永久泄漏并让peer请求无限等待。 |
| H2-028 | P1 | remote GOAWAY/EOF不结束openstream waiters，优雅GOAWAY后还会泄漏预留streamcount。 |
| H2-029 | P1 | connection window为0时stream WINDOW_UPDATE可把同一blocked writer无界重复压入queue。 |
| H2-030 | P2 | batch frame flush丢弃TCP/TLS write失败并清空buffer，stream API仍按成功推进状态。 |
| H2-031 | P2 | HEAD/204/205/304的DATA content未被禁止，client接受交付且server可主动生成malformed response。 |
| H2-032 | P1 | 同一stream并发读取会覆盖唯一waiter，旧reader永久挂起且timer可唤醒错误操作。 |
| H2-033 | P1 | SETTINGS合法下调可产生负stream window，下一次write把负值当DATA length并抛Lua异常。 |
| H2-034 | P2 | client/server均接受ACK-only SETTINGS作为对端连接前言，未按协议拒绝。 |
| H2-035 | P2 | idle channel close异步排GOAWAY后立即关transport，flush稍后只清buffer，graceful shutdown wire必然丢失。 |
| H2-036 | P2 | client在final HEADERS前接受DATA，convenience readall可返回status=nil、body非空且无error的成功对象。 |
| H2-037 | P2 | RST/GOAWAY错误终态后若recvbuf非空，readall优先返回partial body,nil并吞掉terminal error。 |
| H2-038 | P2 | remote RST后新的respond/write/closewrite仍排HEADERS/DATA并成功返回，取消可污染复用连接。 |
| H2-039 | P2 | client把尚未发送HEADERS的本地reserved id当wire-open，peer可向真正idle stream注入响应/状态帧。 |
| H2-040 | P2 | sender不校验Content-Length与实际DATA总量，request/response可成功完成malformed消息。 |
| H2-041 | P2 | zero-length PADDED frame跳过强制Pad Length校验，畸形DATA可被当作正常空DATA并结束消息。 |
| HPACK-002 | P1 | HPACK varint 无溢出/长度限制，可进入 signed-shift UB 与越界 string length 路径。 |
| HPACK-004 | P1 | 32位HPACK table-size setting窄化为C int，动态表非空时容量减法可触发signed overflow/UB。 |
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
| GRPC-012 | P1 | unary timeout不覆盖DNS/dial/H2 handshake，streaming timeout无效，deadline也不传播或由server执行。 |
| GRPC-013 | P1 | RST_STREAM/连接失败只保留文本，client不按标准映射 CANCELLED/INTERNAL/UNAVAILABLE等 status。 |
| GRPC-014 | P1 | 无 package proto的 method path 被拼成 `/nil.Service/Method`，无法与独立 gRPC peer互操作。 |
| GRPC-015 | P1 | client response protobuf/envelope解析错误可被 peer的 OK trailer覆盖，stream最终错误地报告成功。 |
| GRPC-016 | P2 | 四种 server handler异常均被错误映射为 INTERNAL，而非 gRPC规定的 UNKNOWN。 |
| GRPC-017 | P2 | server不校验application status code，可发送非法grpc-status文本或error+OK。 |
| GRPC-018 | P2 | client/bidi零消息request用HEADERS+END_STREAM结束，而非gRPC要求的空DATA+END_STREAM。 |
| GRPC-019 | P2 | plaintext server仍把H2 channel/application stream scheme标成https，与实际TCP及`:scheme: http`矛盾。 |
| GRPC-020 | P2 | client target只取单个A记录并固定首个IPv4地址，IPv6-only或首地址故障服务不可用。 |
| GRPC-021 | P1 | close不与in-flight newchannel共同串行，返回后仍可复活orphan channel并继续RPC。 |
| GRPC-022 | P2 | TLS client/server不验证ALPN最终选择h2，无ALPN或非h2会话仍直接进入H2状态机。 |
| GRPC-023 | P2 | grpc.listen静默丢弃公开ciphers/backlog/alpnprotos配置，TLS策略、listen queue与声明override不生效。 |
| GRPC-024 | P2 | request超限/压缩错误在initial metadata后再次respond，生成含`:status`的非法final HEADERS。 |
| GRPC-025 | P1 | protobuf message/map decoder把截断tag/unknown value当正常EOF，map unknown field还不skip value。 |
| GRPC-026 | P2 | 多target round-robin不隔离坏endpoint，单点DNS/dial故障会阻断建池或周期性打失败RPC。 |
| GRPC-027 | P1 | protobuf embedded-message收发均无递归深度/cycle限制，可在消息预算内耗尽C stack。 |
| GRPC-028 | P2 | protobuf string与bytes共用裸字节codec，gRPC收发均不验证schema要求的UTF-8。 |
| GRPC-029 | P2 | protobuf descriptor丢弃proto2 required label，缺字段request/response仍可被收发为成功。 |
| GRPC-030 | P2 | 四类RPC无metadata/context API，认证、trace及`-bin` initial/trailing metadata无法互操作。 |
| GRPC-031 | P1 | server close只关闭listener，既有H2连接可在close返回后无限创建新RPC。 |
| GRPC-032 | P2 | protobuf encode异常越过公开错误契约，并可遗留timer或永久占用H2 stream/quota。 |
| GRPC-033 | P2 | protobuf scalar encoder不校验整数/enum/bool类型和值域，静默截断或改变业务值。 |
| GRPC-034 | P1 | streaming client不通过read返回值交付最终非OK status，失败可被当作正常EOF或成功response。 |
| GRPC-035 | P1 | protobuf oneof decoder保留已失效member，sender也会同时编码多个members。 |
| GRPC-036 | P2 | protobuf decoder覆盖而非merge重复singular embedded message，合法拆分字段会丢数据。 |
| GRPC-037 | P2 | protobuf parser拒绝packed=false repeated numeric的合法packed wire，破坏schema演进兼容。 |
| GRPC-038 | P2 | bundled protoc拒绝proto2 group，外部descriptor的known group在native codec中也无法收发。 |
| GRPC-039 | P2 | protobuf默认把高位uint64/fixed64解码成负Lua integer，合法ID/counter语义翻转。 |

当前统计为371条：P1 113、P2 202、P3 56。模块分布为CORE 13、METRIC 11、NET 8、SOCK 19、UDP 1、TLS 18、DNS 18、CLUSTER 19、ADDR 2、URL 3、HTTPC 9、HTTP1 23、COMP 1、WS 10、H2 41、HPACK 3、GRPC 39、REDIS 10、MYSQLC 9、MYSQL 20、ETCD 17、DOC 77；以主报告中的编号和证据为准。

## 6. 已保存的三个重现资产

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

### SOCK-005：`socket_stat` close/reuse 竞争

脚本：`review-repros/socket_stat_close_race.lua`。普通ASan/UBSan轮次可能正常退出；已有TSAN轮次确认fd/type两条竞争并触发`ntop`断言，详见主报告`SOCK-005`。按用户要求，本轮收口不再重跑。

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

## 8. 下一步：进入修复阶段

完成性反证审计尚未收口，应继续逐文件review，无需用户重复提醒。真正封板后再按以下依赖顺序进入修复：

1. engine同步、内存安全与生命周期：`CORE-001`至`004`、`CORE-007`、`NET-003/005/006`、`SOCK-006/008/009/011/015/018/019`、`MYSQLC-001/005/007`、`HPACK-002/004`、`TLS-002`、`CLUSTER-005`。
2. 身份认证与资源边界：`TLS-001/005/006`、`DNS-002/003`、`CLUSTER-001`、HTTP/WS/H2/gRPC输入上限、`ETCD-005/009`。
3. transport状态机与deadline：engine/queue同步、HTTP framing/HTTP2流控、TLS shutdown、gRPC status/deadline，以及Redis/MySQL/etcd统一absolute deadline。
4. driver正确性：Redis parser/null/generation，MySQL pool/transaction/multi-result/codec，etcd mutation ambiguity/watch checkpoint/lease scheduler。
5. 修正`CORE-008/009`、`NET-007/008`的跨平台/跨层语义，完成独立peer互操作、版本矩阵、sanitizer，并同步当前全部`DOC-*`、LuaLS和中英文文档。

每个issue建议一个修复提交；提交前先把主报告对应条目标为“修复中”，实现后补测试和验证结果，再标为“已修复”。不要一次性改完整层级，否则回归和回滚难以定位。

仍保留的动态资产只有第6节三个既有重现。其余每条主报告末尾已经写明修复阶段回归条件；用户重新授权前不要创建/运行畸形输入、并发barrier或fault injection。

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
Silly net 1.0完成性反证审计仍在进行；当前滚动基线为master 371项及cluster分支4项，逐文件覆盖账本尚未收口，P1/P2 blocker也尚未修复。先完整读取HANDOFF.md、SILLY_NET_REVIEW.md、NET_1_0_RELEASE_AUDIT_PLAN.md和NET_AUDIT_FILE_LEDGER.md，核对当前分支与工作树，继续按仓库真实文件清单补齐零引用文件、测试、LuaLS及双语文档；每个新问题独立记录和提交。保留用户改动；当前只做静态审阅，不修改产品源码，不新增或运行重现、协议流量、畸形输入、并发barrier和fault injection。
```

## 12. 当前文件清单

```text
SILLY_NET_REVIEW.md
HANDOFF.md
NET_1_0_RELEASE_AUDIT_PLAN.md
NET_AUDIT_FILE_LEDGER.md
review-repros/socket_exit_pending_wlist.lua
review-repros/socket_stat_close_race.lua
review-repros/tcp_immediate_connect_fd_leak.lua
silly/  # 最新审计源码工作副本
```

审计分支：`codex/silly-net-review`；基线master：`d1aef7ffd8439340dfd957a49fccba3fbf133055`。首轮只提交报告与既有重现资产，没有修改Silly生产源码，也没有push远端。
