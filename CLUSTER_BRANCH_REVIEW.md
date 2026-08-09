# Silly `cluster` 分支静态审计

> 状态：两轮纯静态复核完成；确认1项分支独有问题，当前范围无未归档候选
> 审计日期：2026-08-09
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
| CLUSTER-005 | 仍存在 | `hardlimit`仍允许`UINT32_MAX`，receive仍计算`psize + 1`，send仍把`HEADER_SIZE + body`窄化为`uint32_t total`，checked-add缺口未变。 |
| CLUSTER-006 | 部分改善、核心仍存在 | 文档已与8/16-byte新header尺寸一致，但length/session/traceid仍以native整数`memcpy`上wire，跨端序互操作仍失败。 |
| CLUSTER-007 | 仍存在 | 底层accept ABI为`(fd,listenid,addr)`，cluster仍声明`function(fd,addr)`，incoming `peer.remoteaddr`保存listener id。 |
| CLUSTER-008 | 原触发路径已消除 | call不再隐式DNS/dial；eager `connect`在call之前单独完成，因此“RPC timer在lazy connect后才开始”的原问题不再适用。connect自身的deadline另见第4节。 |
| CLUSTER-009 | 仍存在、影响降低 | `send`仍调用`c.request`并发送普通request frame，receiver无法辨认one-way而可能返回ACK；本分支因CLUSTER-003修复只丢弃并debug，不再触发nil-wakeup异常。 |
| CLUSTER-010 | 仍存在 | eager connect仍只执行单次`dns.lookup(name,dns.A)`并连接一个IPv4结果，没有AAAA或多地址fallback。 |
| CLUSTER-011 | 仍存在 | C complete-frame ring仍无count/byte cap，Lua仍在处理当前request前`task.fork(process)`，慢handler下并发task无上限。 |
| CLUSTER-012 | 仍存在 | 收满4-byte length后仍立即`malloc(psize + 1)`，没有partial-frame deadline、per-peer/global reservation budget或增量buffer。 |
| CLUSTER-013 | 仍存在 | `testcluster.lua`仍写成`assert(table.concat(buf), pk)`，没有比较重组packet；已在主报告与提交`f61e68400`归档。 |

矩阵结论：13项既有问题中，1项已修复（CLUSTER-003），1项原触发路径已消除（CLUSTER-008），1项仅文档/自然wrap风险改善但核心仍在（CLUSTER-006），其余10项仍存在。该计数按“问题编号”互斥归类；CLUSTER-009的影响降低但仍计入“仍存在”。

## 4. 分支独有问题

分支独有问题使用`CLUSTER-Bxxx`编号，不计入以`master d1aef7ff`为基线的主报告197项统计。

### CLUSTER-B001 — P2 — eager `cluster.connect`没有deadline参数，黑洞dial可长期挂起

- 状态：已确认；公开签名、DNS/TCP调用链与底层connect timer入口的确定性静态核对。未连接黑洞地址或运行时序测试。
- 位置：分支`lualib/silly/net/cluster.lua:161-187`的`M.connect`；底层可选connect timer在`lualib/silly/net.lua:89-140`；公开文档在`docs/src/en/reference/net/cluster.md:120-159,312-329`及中文对应位置。
- 触发：应用调用`cluster.connect("host:port")`，DNS解析后目标TCP SYN被防火墙静默丢弃、路由设备不返回错误，或connect completion长期不投递。直接IP endpoint无需依赖DNS即可进入该路径。
- 影响：`cluster.connect`协程、`socket_pending[fd]`和底层socket会保留到操作系统连接超时；API没有timeout/cancel handle，应用无法用`serve.timeout`约束dial阶段，也不能先得到peer再主动close。故障切换、启动、shutdown和请求SLA可被单个黑洞endpoint拖延；并发connect会按调用数累积pending资源。
- 证据：分支公开函数只有`M.connect(addr)`，hostname路径调用`dns.lookup(name,dns.A)`后直接执行`tcp_connect(resolved, EVENT)`。底层`connect_wrap`的第四实参才是timeout；仅当该值非nil时才注册`time_after(timeout, connect_timer, fd)`，否则直接`task_wait()`。分支文档要求connect在coroutine中调用，但没有timeout配置或取消返回值；`serve.timeout`只在`waitfor(session)`中创建response timer，且connect发生在call之前。
- 根因：从lazy connection迁移到eager connection时消除了原`CLUSTER-008`的call-before-timer路径，但没有把dial生命周期建模为独立、可配置且可取消的operation；已有底层timeout能力没有向cluster API传递。
- 建议解法：为`cluster.connect`增加向后兼容的options/timeout参数，在入口计算monotonic absolute deadline，并把remaining budget同时传给DNS和每个TCP候选；dial timeout/取消必须关闭对应generation的pending socket且不能让late CONNECT发布peer。若以后实现多地址fallback，所有候选共享同一总deadline而不是逐候选重置。
- 回归测试：修复阶段用可控connector覆盖直接IP黑洞、DNS接近deadline后再dial、CONNECT恰在timeout前后完成、并发不同deadline、取消/close与late CONNECT；断言总耗时受单一预算约束、返回后`socket_pending`/fd/task/timer清零且不发布迟到peer。本轮不创建或运行这些场景。

分支独有统计：1项（P2 1）。

## 5. 静态审计边界

- 已逐行读取分支的Lua状态机、C frame parser/encoder、C类型stub、中英文参考文档、CHANGELOG和完整cluster测试改动。
- 已与共同祖先比较，而非把分叉后的3个master提交误算为cluster改动。
- 已核对底层`net` accept/connect callback ABI、connect timeout入口、task唤醒顺序和trace attach/restore语义。
- 未运行任何代码；因此大端peer、黑洞dial、partial frame、跨peer ACK、断链竞态和资源上限仍只保留确定性静态证据，动态验证继续延期到修复阶段。
- “未发现更多分支独有问题”只表示上述提交与调用链在当前静态范围内没有剩余可确认候选，不表示cluster或整个仓库绝对无bug。

## 6. 审计记录

- 2026-08-09：定位远端分支、共同祖先与7个修改文件，逐行核对Lua/C/类型/中英文文档/测试，未切换工作树。
- 2026-08-09：完成`CLUSTER-001`至`CLUSTER-013`分支状态矩阵；确认`CLUSTER-003`修复、`CLUSTER-008`原lazy-connect路径消除。
- 2026-08-09：确认eager `cluster.connect`没有暴露或转发底层connect timeout，记录为`CLUSTER-B001`；第二遍静态查漏后当前范围无未归档候选。
