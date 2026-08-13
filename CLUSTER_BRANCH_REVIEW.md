# Silly `cluster` 分支静态审计

> 状态：1.0封板纯静态复核进行中；确认4项分支独有问题及17项master共同问题
> 审计日期：2026-08-09 至 2026-08-12
> 审计方式：只读源码、文档、类型与测试；未切换工作树，未运行服务、测试、重现、故障注入或网络输入

## 1. 基线与分支关系

- 审计对象：远端 `origin/cluster`。
- 分支尖端：`0f2c8773842edb818c1aac74ade3f975d1cbd068`（`cluster: simplify protocol and harden response handling`）。
- `master` 尖端：`d1aef7ffd8439340dfd957a49fccba3fbf133055`。
- 共同祖先：`295f30b879e5c29e12ab2ac1325d8b80abe8fb53`。
- 拓扑：相对共同祖先，`cluster`有1个独有提交；相对`master...cluster`计数为`3 1`，不能把`master..cluster`简单视为线性补丁。
- 审计工作树仍为`codex/silly-net-review`，没有checkout或修改`origin/cluster`的生产源码；远端分支已保存为本地remote-tracking ref。

分支独有提交修改：

```text
CHANGELOG.md
docs/src/en/reference/net/cluster.md
docs/src/reference/net/cluster.md
luaclib-src/lcluster.c
lualib/silly/net/cluster.lua
lualib/types/silly/net/cluster/c.lua
test/testcluster.lua
```

## 2. 分支设计变化

- `cluster.connect`由lazy connect/自动重连改为eager connect；失败直接返回`nil, err`，断线后由应用重新连接。
- `cluster.call`、`cluster.send`和server `call`回调改为传递raw string，不再内置`marshal`、`unmarshal`与`cmd`。
- session由32位扩为64位，最高位继续作为response ACK bit。
- request header固定为`session(8) + traceid(8)`；response header为`session(8)`。
- unknown/late response增加nil guard，只记录debug日志，不再唤醒不存在的coroutine。
- 中英文文档、类型stub、CHANGELOG和正常路径测试随API变化同步修改。

这次改造明确声明wire breaking change，要求所有peer一起升级；本报告不把有声明的旧协议不兼容本身记为缺陷。

## 3. 既有 cluster 问题状态矩阵

| 编号 | cluster分支状态 | 结论 |
|---|---|---|
| CLUSTER-001 | 仍存在 | session扩为64位使自然wrap近乎不可达，但response dispatch仍只查全局`wait_pool[session]`并忽略`fd`；错误peer仍可用观察到的session跨连接完成其他RPC。 |
| CLUSTER-002 | 仍存在 | `wait_pool`仍不记录peer/fd，remote close与active close都不会结束该连接上的pending RPC。 |
| CLUSTER-003 | 已修复 | response分支新增`if co then ... else logger.debug(...) end`，unknown/late/duplicate ACK不再对nil执行`task.wakeup`。 |
| CLUSTER-004 | 仍存在 | passive close走`close_fd`并调用`c.clear(ctx,fd)`；active `close_peer`仍只清map/关socket，不清per-fd incomplete parser state。 |
| CLUSTER-005 | 仍存在 | `hardlimit`仍可超过`INT_MAX`，完整frame会窄化成负`packet.size`；`UINT32_MAX`的`psize+1`与send total回绕也仍存在。 |
| CLUSTER-006 | 部分改善、核心仍存在 | 文档已与8/16-byte新header尺寸一致，但length/session/traceid仍以native整数`memcpy`上wire，跨端序互操作仍失败。 |
| CLUSTER-007 | 仍存在 | 底层accept ABI为`(fd,listenid,addr)`，cluster仍声明`function(fd,addr)`，incoming `peer.remoteaddr`保存listener id。 |
| CLUSTER-008 | 原触发路径已消除 | call不再隐式DNS/dial；eager `connect`在call之前单独完成，因此“RPC timer在lazy connect后才开始”的原问题不再适用。connect自身的deadline另见第4节。 |
| CLUSTER-009 | 仍存在、影响降低 | `send`仍调用`c.request`并发送普通request frame，receiver无法辨认one-way而可能返回ACK；本分支因CLUSTER-003修复只丢弃并debug，不再触发nil-wakeup异常。 |
| CLUSTER-010 | 仍存在 | eager connect仍只执行单次`dns.lookup(name,dns.A)`并连接一个IPv4结果，没有AAAA或多地址fallback。 |
| CLUSTER-011 | 仍存在 | C complete-frame ring仍无count/byte cap，Lua仍在处理当前request前`task.fork(process)`，慢handler下并发task无上限。 |
| CLUSTER-012 | 仍存在 | 收满4-byte length后仍立即`malloc(psize + 1)`，没有partial-frame deadline、per-peer/global reservation budget或增量buffer。 |
| CLUSTER-013 | 仍存在 | `testcluster.lua`仍写成`assert(table.concat(buf), pk)`，没有比较重组packet；已在主报告与提交`f61e68400`归档。 |
| CLUSTER-014 | 仍存在 | `serve`不验证timeout；call先send再由`time.after`拒绝超范围/非整数值，可形成远端已执行、本地抛错。 |
| CLUSTER-015 | 仍存在 | 同批次先入ring的合法frame在后续解析错误时不回滚；Lua关闭后不process，`c.clear`又只清half frame，形成跨连接滞留。 |
| CLUSTER-016 | 仍存在 | 分支仍固定明文TCP，raw-string wire无TLS、节点认证、MAC或防重放；任意可达主机可调用handler，链路方可读写payload。 |
| CLUSTER-017 | 不适用 | 该问题属于master的32-bit `cmd`字段；raw-string改造已删除marshal/cmd及对应wire字段，不存在command窄化路径。 |
| CLUSTER-018 | 仍存在 | `serve`仍无条件替换所有listener/peer共享的global handler/timeout/native ctx；raw-string只删除codec/cmd，没有建立实例或generation。 |

矩阵结论：18项master问题中，17项在分支仍有对应路径；其中1项已修复（CLUSTER-003），1项原触发路径已消除（CLUSTER-008），1项仅文档/自然wrap风险改善但核心仍在（CLUSTER-006），其余14项仍存在；`CLUSTER-017`因cmd字段删除而不适用。该计数按“问题编号”互斥归类；CLUSTER-009的影响降低但仍计入“仍存在”。

## 4. 分支独有问题

分支独有问题使用`CLUSTER-Bxxx`编号，不计入以`master d1aef7ff`为基线的主报告199项统计。

### CLUSTER-B001 — P2 — eager `cluster.connect`没有deadline参数，黑洞dial可长期挂起

- 状态：已确认；公开签名、DNS/TCP调用链与底层connect timer入口的确定性静态核对。未连接黑洞地址或运行时序测试。
- 位置：分支`lualib/silly/net/cluster.lua:161-187`的`M.connect`；底层可选connect timer在`lualib/silly/net.lua:89-140`；公开文档在`docs/src/en/reference/net/cluster.md:120-159,312-329`及中文对应位置。
- 触发：应用调用`cluster.connect("host:port")`，DNS解析后目标TCP SYN被防火墙静默丢弃、路由设备不返回错误，或connect completion长期不投递。直接IP endpoint无需依赖DNS即可进入该路径。
- 影响：`cluster.connect`协程、`socket_pending[fd]`和底层socket会保留到操作系统连接超时；API没有timeout/cancel handle，应用无法用`serve.timeout`约束dial阶段，也不能先得到peer再主动close。故障切换、启动、shutdown和请求SLA可被单个黑洞endpoint拖延；并发connect会按调用数累积pending资源。
- 证据：分支公开函数只有`M.connect(addr)`，hostname路径调用`dns.lookup(name,dns.A)`后直接执行`tcp_connect(resolved, EVENT)`。底层`connect_wrap`的第四实参才是timeout；仅当该值非nil时才注册`time_after(timeout, connect_timer, fd)`，否则直接`task_wait()`。分支文档要求connect在coroutine中调用，但没有timeout配置或取消返回值；`serve.timeout`只在`waitfor(session)`中创建response timer，且connect发生在call之前。
- 根因：从lazy connection迁移到eager connection时消除了原`CLUSTER-008`的call-before-timer路径，但没有把dial生命周期建模为独立、可配置且可取消的operation；已有底层timeout能力没有向cluster API传递。
- 建议解法：为`cluster.connect`增加向后兼容的options/timeout参数，在入口计算monotonic absolute deadline，并把remaining budget同时传给DNS和每个TCP候选；dial timeout/取消必须关闭对应generation的pending socket且不能让late CONNECT发布peer。若以后实现多地址fallback，所有候选共享同一总deadline而不是逐候选重置。
- 回归测试：修复阶段用可控connector覆盖直接IP黑洞、DNS接近deadline后再dial、CONNECT恰在timeout前后完成、并发不同deadline、取消/close与late CONNECT；断言总耗时受单一预算约束、返回后`socket_pending`/fd/task/timer清零且不发布迟到peer。本轮不创建或运行这些场景。

### CLUSTER-B002 — P3 — raw-string API迁移遗漏跨模块文档，多个示例仍调用已删除接口

- 状态：已确认；分支API变更与全仓中英文文档调用点的确定性静态核对。本轮不执行文档示例。
- 位置：旧`marshal/unmarshal/cmd`示例位于`docs/src/en/guides/logging-monitoring.md:574-602`及中文对应位置；旧三参数call另位于`docs/src/en/reference/trace.md:235-254`、`docs/src/en/reference/errno.md:54-69`及各自中文对应位置。分支只更新了中英文`reference/net/cluster.md`。
- 触发：用户按这些仍在官方文档树中的示例，为新分支配置`marshal/unmarshal`、定义`call(peer,cmd,body)`，或调用`cluster.call(peer,cmd,obj)`。
- 影响：`serve`会静默忽略已经删除的`marshal/unmarshal`字段；Lua又会静默忽略`cluster.call`的第三实参。远端只收到第二实参字符串，server handler则把它放入`data`位置，旧handler中的`cmd/body`发生错位，可能将nil交给业务处理或按错误命令执行。trace/errno页面的示例即使不立即报错，也没有发送示例声称的对象；这是一项由breaking API迁移不完整造成的确定性文档回归。
- 证据：新实现公开路径为`callx(...)->function(peer,data)`，server callback为`call(peer,buf)`，没有读取第三实参或配置中的marshal字段。全仓检索仍命中上述6个中英文文件位置；分支独有commit的7文件清单不包含logging/trace/errno文档，因此这些旧调用没有随reference更新。
- 根因：breaking API变更只同步了cluster专属reference、CHANGELOG、stub和测试，没有对整个文档树做符号/调用形状检索；Lua对多余参数和未知table字段的宽松行为又掩盖了迁移遗漏。
- 建议解法：将所有示例改为业务层显式encode/decode后调用二参数`cluster.call(peer,data)`，server callback只接收`peer,data`；connect示例统一检查`peer,err`。为文档构建增加cluster API片段的可执行/类型检查，至少用静态规则禁止`marshal =`、`unmarshal =`以及三实参`cluster.call`重新出现。
- 回归测试：修复阶段对整个`docs/src`执行旧API零命中检查，并让中英文raw-string tracing/error示例通过文档validator；另断言传入对象必须先显式序列化。本轮不修改上游文档或运行validator。

### CLUSTER-B003 — P3 — eager改造后`cluster.send`已不yield，文档仍强制要求`task.fork`

- 状态：已确认；分支send调用链与仓库协程/yield规则的确定性静态核对。本轮不执行send。
- 位置：分支`lualib/silly/net/cluster.lua:229-255`的`callx(true)`；中英文reference在`docs/src/en/reference/net/cluster.md:187-205,310-329`及中文对应位置；非yield transport send在`lualib/silly/net.lua:47`、`luaclib-src/lnet.c:166-197`，仓库架构规则见`CLAUDE.md:74-87`。
- 触发：用户阅读新分支文档并调用已经连接peer的`cluster.send(peer,data)`。文档把它称为“asynchronous operation”，在API条目和统一coroutine requirements中反复要求必须由`task.fork()`创建的协程调用。
- 影响：实际send路径只检查`peer.fd`、同步构造frame、调用不yield的`tcp_send`并返回；它既不等待response，也不会再lazy connect。错误的强制fork建议让调用者失去直接的`ok,err`控制流，容易把发送失败留在无人观察的子任务中，同时增加无必要的task调度和生命周期管理。bootstrap task、accept callback等并非由`task.fork()`创建但同样是合法运行上下文，文档的更强限制也与runtime不符。
- 证据：`callx`唯一可能进入`task.wait`的路径是末尾`return waitfor(session)`，而`is_send`分支在它之前直接`return true,nil`。`trace_propagate`、`c.request`和`tcp_send`均不yield；`CLAUDE.md`明确将send列在“Does NOT yield”。该描述是分支移除lazy connect后遗留的旧契约，master上首次send仍可能在connect中yield，不能直接沿用。
- 根因：eager/no-reconnect改造更新了connect返回值和peer行为，却没有重新按实际yield boundary审阅send的reference文本；“网络操作”被笼统等同于“必须异步协程等待”。
- 建议解法：中英文文档明确`cluster.send`为同步排队、不会yield，并建议直接检查返回值；只有`connect`和`call`需要可yield的task上下文。若产品意图让send支持背压等待，则应显式设计async admission/deadline，而不是只保留错误文案。
- 回归测试：修复阶段增加静态yield-contract检查/文档断言，并在bootstrap task与accept callback中直接调用send、同步检查失败返回；确认调用前后没有`task.wait`或调度切换。本轮不运行这些场景。

### CLUSTER-B004 — P3 — 新增late-response测试不观察task异常，旧nil-wakeup缺陷仍可通过

- 状态：已确认；测试时序、旧response分支与task异常边界的确定性静态核对。本轮不回退实现或运行测试。
- 位置：分支新增用例在`test/testcluster.lua:379-405`；修复后的guard在`lualib/silly/net/cluster.lua:81-89`，共同祖先旧分支为无guard的`wait_pool[session]=nil; task.wakeup(co,buf)`；dispatcher预先fork在两版`process`的约`:55-61`；task异常只记录并关闭子协程在`lualib/silly/task.lua:47-64`。
- 触发：把late-response nil guard回退到旧实现，运行分支新增Test 18。请求先按预期timeout，server随后释放并返回late ACK，旧response路径对nil执行`task.wakeup`而抛错。
- 影响：该异常不会传播到`testaux.case`或使断言直接失败，而由任务调度器记录日志后关闭当前data callback协程。`process`在触碰ACK前已经`task.fork(process)`，因此后继dispatcher仍可处理测试紧接着发起的正常call；Test 18的四个断言全部仍可能成功。也就是说声称覆盖本次核心修复的回归用例无法阻止nil guard被删除，CI会给出假绿结果。
- 证据：Test 18只断言原call返回timeout及下一次call成功，没有task error hook、日志计数或unknown-response metric断言。旧代码的异常发生在timeout结果已经交给`completed`之后；`task_resume`对业务协程错误执行`log_error`并返回，不调用`testaux.error`。预先fork的successor隔离了后续处理能力，正好使最后的liveness断言无法检测这次异常。
- 根因：测试只观察外部“超时后还能继续调用”，没有观察修复目标“late ACK不得触发task异常”；框架的协程异常隔离机制让负向路径被日志吞掉。
- 建议解法：在测试期间安装可恢复的task error/log capture或暴露bounded unknown-response metric，发送late ACK后断言异常计数不增加且late计数准确增加；也可把response dispatch提取为可直接断言返回状态的纯函数。测试结束必须恢复hook，避免污染其他case。
- 回归测试：修复阶段先临时移除guard确认新测试必然失败，再恢复guard确认通过；同时覆盖unknown、duplicate、timeout-late和错误fd ACK，并断言无task traceback、active waiter不变。本轮不修改或执行测试。

分支独有统计：4项（P2 1、P3 3）。

## 5. 静态审计边界

- 已逐行读取分支的Lua状态机、C frame parser/encoder、C类型stub、中英文参考文档、CHANGELOG和完整cluster测试改动。
- 已与共同祖先比较，而非把分叉后的3个master提交误算为cluster改动。
- 已核对底层`net` accept/connect callback ABI、connect timeout入口、task唤醒顺序和trace attach/restore语义。
- 第三轮补查了同批次parser部分提交/回滚、timeout配置边界、全仓旧API文档调用点、新增测试能否在旧实现上失败，以及分支落后的3个master提交。
- 分支缺少的3个master提交仅为lcov 2.5参数修正、VuePress版本更新和undici依赖升级，没有cluster依赖的共享运行时修复。
- 未运行任何代码；因此大端peer、黑洞dial、partial frame、跨peer ACK、断链竞态和资源上限仍只保留确定性静态证据，动态验证继续延期到修复阶段。
- “未发现更多分支独有问题”只表示上述提交与调用链在当前静态范围内没有剩余可确认候选，不表示cluster或整个仓库绝对无bug。
- 共同文档问题另在主报告归档：`DOC-038`确认两版cluster reference均把默认backlog写成128，而共享TCP listener实际使用256；它不是raw-string迁移独有问题。
- master文档问题`DOC-039`不适用于本分支：master的connect专节与文末对“lazy handle是否yield”自相矛盾，而本分支eager connect确实需要yieldable task。
- `DOC-040`适用于两版文档：API/timeout段把错误写成`silly.errno`并点名`errno.TIMEDOUT`，Error Handling又禁止把cluster错误与errno比较；分支改造未统一这项契约。

第三轮明确排除、未另立问题的路径：

- `tcp_send`到`wait_pool`登记之间不存在response抢跑：send、`time.after`和table写均不yield，worker会在当前消息后的wakeup阶段跑完caller才分发下一条网络消息；timeout配置的“验证太晚”已单列`CLUSTER-014`。
- request `traceid=0`不会被误判为response，因为Lua中的数字0为truthy；C只对response返回nil traceid。
- eager connect完成后、peer map建立前的close/data事件不会插入执行：CONNECT消息唤醒的caller在下一消息前完成map写入。无deadline/取消能力仍见`CLUSTER-B001`。
- 多个`process` task在单Lua worker中串行调用`c.pop`，不会重复消费同一queue slot；无界fork/queue与parse-error滞留分别由`CLUSTER-011`和`CLUSTER-015`覆盖。

## 6. 审计记录

- 2026-08-09：定位远端分支、共同祖先与7个修改文件，逐行核对Lua/C/类型/中英文文档/测试，未切换工作树。
- 2026-08-09：完成`CLUSTER-001`至`CLUSTER-013`分支状态矩阵；确认`CLUSTER-003`修复、`CLUSTER-008`原lazy-connect路径消除。
- 2026-08-09：确认eager `cluster.connect`没有暴露或转发底层connect timeout，记录为`CLUSTER-B001`；第二遍静态查漏后当前范围无未归档候选。
- 2026-08-12：第三轮复核确认timeout配置延迟到request发送后验证，主报告新增`CLUSTER-014`，并在本矩阵标记为仍存在。
- 2026-08-12：确认raw-string breaking API只更新cluster reference，logging/trace/errno中英文文档仍使用旧接口，记录为`CLUSTER-B002`。
- 2026-08-12：确认同批次合法frame后的解析错误不会回滚或清除已入ring的完整frame，主报告新增`CLUSTER-015`并在本矩阵标记为仍存在。
- 2026-08-12：确认eager改造后的`cluster.send`已无任何yield路径，但中英文reference仍强制要求`task.fork`，记录为`CLUSTER-B003`。
- 2026-08-12：确认新增late-response用例不观察task异常，旧nil-wakeup路径被框架日志隔离后测试仍可假绿，记录为`CLUSTER-B004`。
- 2026-08-12：只读确认远端`cluster`仍指向`0f2c8773`；核对落后的3个master提交与第三轮排除项后收口，当前静态范围无未归档候选。
- 2026-08-13：1.0封板复核确认master与分支都没有TLS、节点认证、消息完整性或防重放，新增共同问题`CLUSTER-016`；未建立peer或发送frame。
- 2026-08-13：master的marshal command无范围检查并窄化为uint32，新增`CLUSTER-017`；raw-string分支已删除cmd字段，矩阵标记不适用。
- 2026-08-13：确认两版serve均可无保护替换所有listener共享的global context/handler，官方多节点示例确定由最后配置接管全部端口；新增共同问题`CLUSTER-018`。
