# Hermes Agent 调研 11：通用能力后端（Terminal / File / Browser / MCP）

## 1. 这篇文档关注什么

前面的第 04 篇已经从 Tool Runtime 角度解释了：

- 工具如何注册
- toolset 如何控制能力面
- dispatch 如何把 tool call 路由到具体实现

但如果停在这一步，仍然会漏掉 Hermes 最像“Agent 能力操作系统”的一层：

- 这些工具背后的真实执行环境是怎么组织的
- 为什么 file tools 不只是几个文件读写函数
- 为什么 browser 能力拆成了浏览器运行时，而不是一个单纯的 web fetch
- 为什么 MCP 被做成一个长期连接、动态注册、可重连的子系统

换句话说，这一篇要研究的不是：

- “工具如何被模型看见”

而是：

- “工具背后的世界如何被 Agent 稳定、安全地接上来”

这篇文档重点回答六个问题：

1. Hermes 为什么把终端后端当成很多能力的基础底座。
2. 文件工具为什么不是直接 Python `open()`，而是建立在 shell/backends 之上。
3. patch / fuzzy match / output budget 这些“补层”为何必要。
4. 浏览器能力为什么要有自己的 provider、session、supervisor。
5. MCP 为什么不是一次性调用，而是长期连接的运行时。
6. Hermes 为了把 LLM 接到真实后端，额外补了哪些运行时层。

---

## 2. 关键文件

核心文件：

- `tools/terminal_tool.py`
- `tools/environments/`
- `tools/file_tools.py`
- `tools/file_operations.py`
- `tools/browser_tool.py`
- `tools/browser_supervisor.py`
- `tools/mcp_tool.py`

辅助但重要的文件：

- `tools/patch_parser.py`
- `tools/fuzzy_match.py`
- `tools/tool_result_storage.py`
- `tools/tool_output_limits.py`
- `website/docs/developer-guide/tools-runtime.md`
- `website/docs/developer-guide/browser-supervisor.md`

---

## 3. Hermes 的一个核心判断：能力后端不是 schema，而是 runtime

Hermes 明显不把 tool 当成“给模型暴露几个函数名”。

从这批工具的实现看，它真正关心的是下面几件事：

- 命令在哪里执行
- 文件从哪里读写
- 浏览器 session 如何保持
- 大输出怎样不把上下文打爆
- 不同 transport / backend 如何统一成同一种工具语义

这意味着 Hermes 的能力系统至少分成了三层：

1. schema 层：模型看到哪些工具
2. dispatch 层：tool call 如何路由
3. backend runtime 层：这些工具在真实环境里怎么活

而这一篇关注的就是第三层。

---

## 4. Terminal backend 是很多能力的共同底座

### 4.1 `terminal_tool.py` 不只是 shell wrapper

`tools/terminal_tool.py` 一开头就把自己定位得很清楚：

- 支持本地、容器、远程、云 sandbox
- 支持后台任务
- 支持 VM / container 生命周期管理
- 支持自动清理

这说明 Hermes 的 terminal tool 从一开始就不是：

- “把 command 丢给 subprocess.run()”

而是一个 execution backend manager。

### 4.2 它统一了多种执行后端

Hermes 当前支持的终端后端包括：

- `local`
- `docker`
- `ssh`
- `singularity`
- `modal`
- `daytona`
- `vercel_sandbox`

这个抽象的意义很大，因为对 Agent 来说：

- “运行一条命令”

只是表面一致，背后却可能有完全不同的语义：

- 本地进程
- 容器
- 远程主机
- 云临时沙箱

Hermes 通过 `tools/environments/` 把这些差异统一到了同一类执行接口上。

### 4.3 它不只执行命令，还要管环境生命周期

`terminal_tool.py` 明显承担了很多通常不会出现在“普通 shell tool”里的职责：

- per-task environment 复用
- sandbox 创建锁
- 后台进程管理
- inactive env cleanup
- atexit cleanup
- cwd 解析与映射

这说明 Hermes 处理的是：

- “会话化的执行环境”

而不是：

- “一次性命令调用”

这对于 Agent 很关键，因为同一个任务往往需要：

- 连续进入同一环境
- 在前一次副作用基础上继续工作
- 保留工作目录与中间状态

### 4.4 终端后端本身也带配置与兼容层

从 `terminal_tool.py` 能看出 Hermes 还补了不少环境兼容逻辑，例如：

- 对 env var 的防御式解析
- 不同 sandbox 的 cwd 语义差异
- Vercel sandbox 的运行时与认证检查
- sudo 密码缓存与线程隔离
- interrupt 与 timeout 行为

这说明“terminal backend”不是单个后端，而是一个带有：

- config normalization
- environment policy
- interactive fallback

的运行时层。

---

## 5. 文件工具为什么建立在 terminal backend 之上

### 5.1 `file_operations.py` 的核心思想很直接

`tools/file_operations.py` 的文档写得非常直白：

- 所有文件操作都可以表达成 shell 命令
- 所以用 terminal backend 的 `execute()` 接口包出统一文件 API

这和很多项目“本地文件用 Python，远程文件另写一套”完全不同。

Hermes 的选择是：

- 把文件操作视为 terminal backend 的派生能力

好处是：

- local / docker / ssh / modal / daytona / vercel_sandbox 下的文件语义尽量统一
- 文件工具天然继承 terminal backend 的 cwd、sandbox、权限边界

代价是：

- 文件 API 不再是最短路径
- 需要补很多 read/write/search/patch 的适配层

### 5.2 `file_tools.py` 是“模型友好层”，不是底层实现

`tools/file_tools.py` 主要在做几类事情：

- 路径解析与 live cwd 对齐
- device path block
- sensitive path write 拒绝
- read-size guard
- read 去重与循环检测
- 对结果做 redaction / summarization / warning

这说明它的定位不是：

- 真正去操作文件系统

而是：

- 把底层 file operations 包装成更适合 LLM 使用的接口

### 5.3 读取文件不只是“把内容给模型”

`file_tools.py` 里可以看到 Hermes 对 read_file 做了很多额外限制：

- 最大字符数上限
- 大文件提示引导 targeted read
- 阻止读取会卡死的设备路径
- 对重复读取做 dedup
- 记录 mtime，帮助后续写入时判断是否发生外部修改

这说明 Hermes 已经意识到：

- read_file 不是纯粹的 I/O
- 它还是上下文预算管理、并发编辑风险管理的一部分

### 5.4 写文件也不是“有权限就写”

无论是 `file_tools.py` 还是 `file_operations.py`，都显式补了：

- denylist
- safe root
- 敏感路径拒绝
- lint / LSP diagnostics 返回

这意味着 Hermes 希望文件写入除了“成功/失败”之外，还能反馈：

- 改动后是否引入语义问题
- 是否命中了高风险区域

所以这里的 file backend 已经半只脚跨进了“编辑运行时”，而不是单纯文件 I/O。

---

## 6. Patch / fuzzy match / output budget 是三层关键补层

Hermes 的文件后端之所以比较成熟，一个很重要的原因是它没有把“模型生成的编辑意图”直接生硬落盘，而是补了几层缓冲。

### 6.1 `patch_parser.py`：把 agent patch 语言先变成结构化操作

`tools/patch_parser.py` 负责解析 V4A patch 格式，支持：

- add
- update
- delete
- move

它的价值不在于“能解析 patch”，而在于：

- 在真正改文件前，先把模型输出变成结构化变更操作

这给后续执行层提供了空间去做：

- 校验
- 匹配
- 回退
- 诊断

### 6.2 `fuzzy_match.py`：承认模型生成的文本匹配经常不精确

`tools/fuzzy_match.py` 的意义非常大，因为它相当于把一个现实问题产品化了：

- LLM 生成的 old_string / new_string 经常会有缩进、空白、转义、Unicode 形式上的漂移

Hermes 没有把这种情况简单当作“模型失败”，而是实现了多策略匹配链：

- exact
- line-trimmed
- whitespace normalized
- indentation flexible
- escape normalized
- trimmed boundary
- unicode normalized
- block anchor
- context aware

这说明它在用运行时层吸收一部分模型输出的不稳定性。

### 6.3 `tool_output_limits.py` + `tool_result_storage.py`：把大输出从“报错”变成“可恢复状态”

这两层一起解决的是另一个很典型的问题：

- 真实后端输出可能极大
- 但上下文窗口有限

Hermes 的做法不是简单截断，而是三层防线：

1. 各工具自己先做输出上限
2. 单个超大结果写入 sandbox 并返回 preview + path
3. 单轮 aggregate budget 超限时，再把最大结果逐步 spill 到磁盘

这个设计非常像操作系统或数据库里的 spill-to-disk 思维。

它的好处是：

- 结果没有丢
- 模型仍然能继续工作
- 只是被迫通过 `read_file` 按需读取

这比“超过长度就报错”成熟很多。

---

## 7. Browser 不是一个工具，而是一整套会话化运行时

### 7.1 `browser_tool.py` 的定位是统一多种浏览器 provider

浏览器能力在 Hermes 里不是单一抓网页工具，而是支持多后端：

- Browser Use
- Browserbase
- local Chromium
- 可选 camofox 模式

并且 agent-facing 行为尽量保持一致。

这说明浏览器工具的核心问题不是：

- “如何请求一个网页”

而是：

- “如何让不同浏览器执行后端对 Agent 暴露同一种交互语义”

### 7.2 浏览器工具是会话化的，不是 stateless fetch

从 `browser_tool.py` 能看出来，Hermes 的浏览器后端有这些特征：

- session isolation per task id
- accessibility tree snapshot
- element ref selector
- 自动清理 browser session
- vision / extraction model 配合

这已经明显不是传统意义上的网页抓取了，而是：

- 持续浏览会话
- 带页面状态
- 带交互动作

### 7.3 `browser_supervisor.py` 说明浏览器状态需要被持续监听

`tools/browser_supervisor.py` 更进一步，说明浏览器后端里还要有后台 supervisor：

- 持久 CDP websocket
- 订阅 page/runtime/target 事件
- 跟踪 pending dialogs
- 跟踪 frame tree
- 以 thread-safe snapshot 形式暴露给同步工具调用

这很关键，因为浏览器世界里很多重要状态不是“你调用时才存在”，而是异步发生的：

- dialog 弹出
- frame 变化
- target attach/detach

Hermes 没有让每个 browser tool 临时去问一遍浏览器，而是引入了一个持续观察者。

这是一种典型的“事件世界转同步工具世界”的桥接层。

### 7.4 Browser 能力还和安全 / policy 层耦合

`browser_tool.py` 里还直接引用了：

- `website_policy`
- `url_safety`

这说明浏览器后端不是孤立的体验层，而是和：

- 访问控制
- URL floor
- extraction model

一起组成完整运行时。

---

## 8. MCP 是长期连接的能力接入层

### 8.1 `mcp_tool.py` 不是“发个请求调下服务器”

MCP 工具在 Hermes 里的实现非常明确地走了 runtime 设计，而不是简单 RPC。

它支持：

- stdio transport
- HTTP / streamable HTTP
- SSE
- sampling
- 动态工具发现
- 自动重连
- dedicated background event loop

这意味着 Hermes 把 MCP server 视为：

- 长期连接的外部能力节点

而不是：

- 一次性 API endpoint

### 8.2 它补了很多连接管理层

`mcp_tool.py` 里可以看到不少典型 runtime 责任：

- 可选依赖 graceful import
- 每 server 的 timeout / connect_timeout
- reconnection backoff
- stderr 重定向到日志
- 线程安全 server state
- sampling / message handler 支持探测

这些都不是“调用 MCP 协议”本身必需的，而是“让 MCP 能长期挂在 agent 里不扰乱主系统”必需的。

### 8.3 MCP 工具被注册成内建工具形态，但生命周期完全不同

从模型视角看，MCP 工具和内建工具没什么区别：

- 都会出现在 schema 里
- 都能被 tool call

但从运行时视角看，它们背后完全不同：

- 内建工具多半是进程内 handler
- MCP 工具背后是外部 server、连接状态、transport 生命周期

Hermes 通过 `mcp_tool.py` 把这个差异屏蔽掉了。

这正是平台层很有价值的地方：

- 给模型统一抽象
- 把复杂性留在运行时

---

## 9. 这些能力后端一共补了哪些运行时层

如果把这一篇压缩成一句架构判断，可以说：

Hermes 为了把 LLM 接到真实世界后端，至少额外补了七层运行时。

### 9.1 Backend abstraction

- local / container / remote / cloud
- browser providers
- MCP transports

### 9.2 Session and lifecycle management

- per-task env
- browser session
- MCP server task
- cleanup / idle reaping

### 9.3 Safety and policy

- dangerous command guard
- sensitive path protection
- URL safety
- website access policy

### 9.4 Output budgeting

- per-tool cap
- aggregate turn budget
- spill to sandbox

### 9.5 Intent normalization

- patch parsing
- fuzzy matching
- cwd normalization
- config normalization

### 9.6 Async-to-sync bridging

- async browser / MCP / background events
- 同步 tool dispatch
- supervisor snapshot 暴露

### 9.7 Observability and diagnostics

- stderr log
- lint / LSP diagnostics
- persisted output path
- environment warnings

这些层如果缺失，LLM 工具系统就很容易退化成：

- demo 能跑
- 真实任务很脆

---

## 10. 这套设计最值得学习的点

### 10.1 把“真实世界副作用”当成一级架构问题

Hermes 的一个优点是，它没有把副作用后端当附庸功能。

terminal、file、browser、MCP 都明显被视为：

- Agent runtime 的核心组成部分

### 10.2 用统一抽象屏蔽后端差异

无论是 terminal environments，还是 browser providers，还是 MCP transports，Hermes 都在做同一件事：

- 给模型一个稳定能力面
- 把差异吸收在后端 runtime

这非常适合做平台。

### 10.3 用恢复机制替代简单失败

patch parser、fuzzy match、persisted output 都体现出一个共同思路：

- 遇到不完美输入或超大输出时，不急着失败
- 先尽量把状态转化成“可继续工作的形式”

这对 LLM 系统尤其重要，因为模型并不擅长一次就给出完全精确的结构化操作。

---

## 11. 这套设计的代价

### 11.1 复杂度明显上升

这些运行时层一旦补齐，工具系统就不再是“几个 handler”，而会变成：

- 环境管理
- 并发管理
- 清理逻辑
- 预算逻辑
- 诊断逻辑

这会显著提高维护成本。

### 11.2 能力越统一，底层妥协越多

例如文件工具建立在 shell 契约之上，带来统一性，但也意味着：

- 实现路径更长
- 需要更多适配
- 某些平台特性无法完全暴露

这是一种典型的平台 trade-off。

### 11.3 会话化能力天然更难测试和调试

browser supervisor、persistent MCP connection、sandbox lifecycle 这些路径，本来就比 stateless API 更难测、更容易有边缘状态。

所以这一层强大，也意味着这一层最需要长期治理。

---

## 12. 对通用 Agent 框架的启发

从通用 Agent 框架角度，这篇最重要的结论不是“用了哪些工具”，而是：

一个能碰真实世界的 Agent，真正难的往往不是工具 schema，而是工具后端运行时。

尤其要补的通常有三类：

1. 环境与连接生命周期
2. 大输出与不精确编辑的恢复层
3. 异步世界到同步工具接口的桥接层

如果这些层没有补上，系统很容易停留在：

- 能演示
- 但不够稳

---

## 13. 建议阅读顺序

建议按这个顺序读：

1. `tools/terminal_tool.py`
2. `tools/environments/`
3. `tools/file_operations.py`
4. `tools/file_tools.py`
5. `tools/patch_parser.py`
6. `tools/fuzzy_match.py`
7. `tools/tool_result_storage.py`
8. `tools/browser_tool.py`
9. `tools/browser_supervisor.py`
10. `tools/mcp_tool.py`
11. `website/docs/developer-guide/tools-runtime.md`
12. `website/docs/developer-guide/browser-supervisor.md`

这样读会比较顺，因为它刚好对应：

- execution substrate
- file layer
- edit recovery layer
- browser runtime
- MCP runtime

---

## 14. 本篇结论

Hermes 的通用能力后端最值得学习的地方，不是它支持了多少种后端，而是它把“把 LLM 接到真实世界后端”当成了完整运行时工程来做：

- terminal 有执行环境与生命周期
- file 有路径、安全、编辑恢复与上下文预算
- browser 有 provider、session、supervisor 与 policy
- MCP 有 transport、连接、重连与动态注册

如果把第 04 篇看成“工具系统如何被组织”，那么这一篇的结论就是：

Hermes 真正成熟的地方，在于它已经把工具背后的执行世界也做成了一层系统，而不只是若干函数调用。
