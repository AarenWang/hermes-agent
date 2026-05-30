# Hermes Agent 调研 02：AIAgent 主循环与执行编排

## 1. 这篇文档关注什么

这一篇聚焦 Hermes 的执行核心，也就是 `run_agent.py` 里的 `AIAgent`。

如果把 Hermes 看成一个通用 Agent 框架，那么 `AIAgent` 解决的是最核心的问题：

- 一次用户请求如何进入 Agent。
- Prompt 和工具 schema 如何准备好。
- 模型如何被调用。
- tool call 如何循环执行。
- 中断、重试、fallback、压缩、持久化如何插入这条主链。

一句话说，`AIAgent` 是 Hermes 的“任务编排内核”。

---

## 2. 主循环在整个架构中的位置

从整体结构看，`AIAgent` 处在所有入口之后、所有子系统之前：

```text
CLI / Gateway / TUI / ACP / Cron / Batch
    ↓
AIAgent.run_conversation()
    ↓
Prompt Assembly
Provider Runtime
Tool Runtime
Session / Memory / Compression
```

这意味着 Hermes 并不是每个入口各自实现一套 Agent 逻辑，而是尽量通过不同入口去驱动同一个执行内核。

这也是它最值得学习的架构点之一。

---

## 3. 关键源码位置

最关键的文件：

- `run_agent.py`
- `agent/retry_utils.py`
- `agent/error_classifier.py`
- `agent/model_metadata.py`
- `agent/auxiliary_client.py`
- `model_tools.py`
- `website/docs/developer-guide/agent-loop.md`

在 `run_agent.py` 里，值得优先定位的对象和方法：

- `class IterationBudget`
- `class AIAgent`
- `AIAgent.__init__`
- `AIAgent.run_conversation`
- `AIAgent.chat`
- `_interruptible_api_call`
- `_compress_context`

---

## 4. AIAgent 负责哪些职责

从开发者文档和源码看，`AIAgent` 不是单纯做 API 调用，而是承接了几乎整条执行链：

- 解析配置并初始化运行时状态。
- 选择模型 Provider 和 API 模式。
- 组装或复用系统 Prompt。
- 装载工具 schema。
- 构造消息历史并发起模型请求。
- 处理模型返回的 tool call。
- 将工具结果回写消息历史。
- 在合适时机做上下文压缩。
- 维护 session、memory、cost、usage、trajectory。
- 对外通过 callback 推送 thinking、tool progress、reasoning、streaming。

从设计上看，Hermes 采取的是“大 orchestration core + 若干外部辅助模块”的组织方式：

- 复杂但统一。
- 复用性强。
- 也意味着 `run_agent.py` 会比较重。

---

## 5. 初始化阶段：AIAgent 是怎样搭起来的

### 5.1 初始化参数非常多

`AIAgent.__init__` 的参数非常多，AGENTS 文档里也明确提示真实签名大约有 60 个参数。

这说明它不是一个轻量 wrapper，而是一个“带完整运行时上下文的执行对象”，初始化阶段就会绑定：

- provider / model / api_mode
- session_id / platform / task_id
- callbacks
- toolsets
- session_db
- memory / plugin memory provider
- context engine
- credential pool
- fallback model chain

### 5.2 初始化阶段就装配多个子系统

从源码可见，`__init__` 里至少会装配这些关键对象：

- `IterationBudget`
- TodoStore
- 本地 memory store
- 外部 memory provider manager
- context engine / compressor
- 工具列表与工具 schema
- session DB 引用

所以 `AIAgent` 不是“每次 run_conversation 临时拼一堆状态”，而是先把这次会话的执行环境装好，再反复处理 turn。

### 5.3 工具面会在初始化时确定

工具 schema 由 `model_tools.get_tool_definitions()` 生成，而不是在模型调用前临时扫目录。

这带来两个好处：

- tool surface 在一个 session 内是相对稳定的。
- callback、memory tools、context engine tools 都可以在初始化阶段一起并入。

---

## 6. 三种 API 模式

Hermes 在 Agent 主循环里原生支持三种 API 模式：

- `chat_completions`
- `codex_responses`
- `anthropic_messages`

这意味着 Hermes 并不是假设“所有 Provider 都是 OpenAI Chat Completions”。

### 6.1 为什么这很重要

很多 Agent 项目在抽象 Provider 时只处理：

- endpoint 地址
- api key
- model name

Hermes 则更进一步，把“协议模式”也纳入运行时决策，这使它能兼容：

- OpenAI 兼容接口
- OpenAI Responses/Codex 风格接口
- Anthropic 原生消息接口

### 6.2 模式分流但内部消息格式尽量统一

开发者文档明确提到，不同 API 模式在进入和返回时最终都尽量汇聚到统一的内部消息格式：

```python
{"role": "system", "content": "..."}
{"role": "user", "content": "..."}
{"role": "assistant", "content": "...", "tool_calls": [...]}
{"role": "tool", "tool_call_id": "...", "content": "..."}
```

这是一个很关键的工程点：

- 对外兼容多协议。
- 对内尽量统一消息模型。

这样工具执行、持久化、压缩、session replay 才不会被 provider-specific 细节污染得太严重。

---

## 7. 一次 turn 是怎么跑起来的

从 `website/docs/developer-guide/agent-loop.md` 和 `run_agent.py` 的结构看，一次 `run_conversation()` 大体上按下面顺序执行：

```text
1. 确定 task_id / session 上下文
2. 恢复必要状态（例如 todo / memory cadence）
3. 构建或复用 system prompt
4. 检查是否需要 preflight compression
5. 根据 api_mode 构建请求消息
6. 注入当前 turn 的临时层上下文
7. 发起 interruptible API call
8. 解析模型输出
9. 若有 tool_calls，则执行工具并追加 tool messages
10. 回到模型继续循环
11. 若是最终文本响应，则持久化、同步 memory、返回结果
```

可以把它理解成一个“同步的 agent event loop”，只是事件来自：

- 用户输入
- 模型响应
- 工具结果
- 中断信号

---

## 8. 为什么它是“同步主循环”

Hermes 当前主循环的核心风格是同步 orchestration，而不是全异步 Actor 模型。

### 8.1 同步的好处

- 更容易保证消息历史一致性。
- tool call 追加顺序更容易控制。
- 对 CLI / gateway / ACP 这些不同入口更容易复用。
- 与 SQLite 会话持久化、memory flush、cost tracking 等副作用更容易串起来。

### 8.2 同步的代价

- `run_agent.py` 自己会变得很大。
- 异步工具、异步 Provider 需要桥接层。
- 并发能力要通过局部线程池来补，而不是天然来自 event loop。

Hermes 的解决方案是：

- 主循环保持同步。
- 局部使用线程池和 async bridge 处理并发工具与可中断请求。

这是一个很现实的工程折中。

---

## 9. 工具调用循环是怎样嵌进来的

### 9.1 tool call 是主循环的核心分叉

模型响应到达后，Hermes 会判断：

- 如果返回普通文本：进入收尾与持久化。
- 如果返回 tool calls：转入工具执行逻辑，再把 tool 结果追加回消息历史。

这意味着 Hermes 的“Agent 性”主要体现在这里：

- 不是只会生成文本。
- 而是能在文本与动作之间来回循环。

### 9.2 单工具与多工具的处理不同

开发者文档说明：

- 单个 tool call 直接主线程执行。
- 多个 tool call 可以通过 `ThreadPoolExecutor` 并行执行。
- 交互型工具如 `clarify` 会强制顺序执行。

这说明 Hermes 不只是支持 function calling，而是在认真处理“多工具回合”的执行策略。

### 9.3 部分工具并不走普通 registry dispatch

`run_agent.py` 中有一部分工具是 agent-level tools，会在 registry 之前被拦截：

- `todo`
- `memory`
- `session_search`
- `delegate_task`
- memory provider tools

这样设计的原因很直接：

- 这些工具不仅是“调用外部函数”。
- 它们本身会改动 agent 的内部状态或会话状态。

这也是 Hermes 工具系统里一个很值得学的分层：

- 普通工具：注册表调度。
- agent 级工具：由 `AIAgent` 直接掌控。

---

## 10. 中断机制为什么重要

Hermes 的开发者文档反复强调 “interruptible”。

### 10.1 `_interruptible_api_call` 的意义

Hermes 并不是盲等模型请求返回，而是把实际 HTTP 请求放到后台线程，同时主线程监控：

- response ready
- interrupt event
- timeout

这使 Hermes 可以在这些场景里更好地工作：

- 用户在 CLI 中打断当前任务。
- 网关上用户发来新的消息要求停止。
- 长调用卡住时及时返回控制权。

### 10.2 为什么这比简单 timeout 更高级

简单 timeout 只能解决“等太久”的问题。

Hermes 的中断机制则解决“用户交互控制权”问题：

- 当前响应即使没完成，也可以被丢弃。
- conversation history 不会被部分污染。
- 父 Agent / 子 Agent / gateway queue 可以协调停止。

如果要做长期可交互 Agent，这种机制几乎是必需的。

---

## 11. budget、fallback 与容错

### 11.1 IterationBudget

源码里有显式的 `IterationBudget` 类。

其作用不是 token budget，而是“工具回合预算”：

- 限制一次 Agent turn 里 tool-calling 的迭代次数。
- 父 Agent 和子 Agent 的预算相互独立。
- 通过最大迭代次数防止 tool loop 无限循环。

这比简单地“while model returns tool calls”要安全得多。

### 11.2 fallback chain

`AIAgent` 会把 fallback model/provider 解析成 `_fallback_chain`。

当主 Provider 出现：

- 429
- 5xx
- 401/403

等情况时，可以尝试切换到下一个 fallback。

这体现了 Hermes 的一个成熟思路：

- 模型调用不应该是“只有主线路径，没有退路”。

### 11.3 辅助任务也有独立 fallback

文档还提到，压缩、vision、web extraction、session search 等 auxiliary task 也可走独立 fallback。

这说明 Hermes 不只是给主聊天模型做容错，而是把整套 Agent 运行时都看成需要容灾的系统。

---

## 12. 压缩与持久化插在什么位置

### 12.1 压缩不是独立子进程，而是主循环内策略

上下文压缩通过 `_compress_context` 插入主循环。

触发点至少有两类：

- preflight compression：模型请求前先检查。
- 运行时压缩：回合中在上下文压力变大时触发。

这意味着 Hermes 的上下文治理不是“会话结束后再整理”，而是实时纳入编排逻辑。

### 12.2 会话持久化是 turn 级别的

最终响应产生后，会写入：

- SessionDB / SQLite
- MEMORY.md / USER.md
- memory provider
- trajectory（如果开启）

这也是 Hermes 能支持 `/resume`、跨会话检索、gateway 长对话的重要基础。

---

## 13. callback 设计体现了什么

`AIAgent` 提供很多 callback 面：

- `tool_progress_callback`
- `thinking_callback`
- `reasoning_callback`
- `clarify_callback`
- `step_callback`
- `stream_delta_callback`
- `tool_gen_callback`
- `status_callback`

这说明 `AIAgent` 并不是只为一个纯后端调用场景设计的，它从一开始就要适配：

- CLI spinner
- gateway 的进度消息
- ACP 的 editor event
- TUI 的分块展示

也就是说，Hermes 把“执行核心”和“观察面”清晰地解耦了：

- 核心只负责在关键节点发 callback。
- 不同入口各自把 callback 映射到各自的 UI。

这是很好的平台级设计。

---

## 14. 委托子代理如何纳入主循环

`delegate_task` 在 Hermes 里不是外围工作流，而是主循环中的一级能力。

从 `tools/delegate_tool.py` 和 `run_agent.py` 可见：

- 子代理是新的 `AIAgent` 实例。
- 有自己的 task_id、终端 session、toolset、context。
- 父 Agent 只接收摘要结果，不接收子代理的全部中间轨迹。

这件事的重要性在于：

- Hermes 把“多 Agent 协作”纳入同一编排框架，而不是完全另起一套系统。
- 但又通过上下文隔离控制主 Agent 的 context 爆炸。

这是一种很实用的 delegation 设计。

---

## 15. 值得学习的设计点

从通用 AI Agent 框架角度看，`AIAgent` 最值得学的地方有六个：

- 单一执行核心：多入口复用同一 orchestration core。
- 内部消息统一：对外兼容多协议，对内尽量统一消息结构。
- 工具循环一等化：tool call 是主流程的一部分，不是外挂。
- 中断可控：Agent 能被用户及时打断。
- 预算与 fallback 显式建模：防止死循环与单点失败。
- 执行与展示解耦：通过 callback 接给 CLI、gateway、ACP、TUI。

---

## 16. 这部分的局限与代价

从工程角度，这种设计也有明显代价：

- `run_agent.py` 非常大，阅读和局部修改门槛高。
- 许多横切逻辑都汇聚在一个文件里。
- 对新人来说，初始化路径和 turn 执行路径都比较长。

但换来的好处是：

- 核心行为集中。
- 多入口一致性更强。
- 复杂运行时更容易在一个地方统一控制。

这是典型的“集中式 orchestration core”架构权衡。

---

## 17. 建议阅读顺序

如果你准备真正读源码，建议按这个顺序：

1. `website/docs/developer-guide/agent-loop.md`
2. `run_agent.py` 中的 `IterationBudget`
3. `AIAgent.__init__`
4. `AIAgent.run_conversation`
5. `_interruptible_api_call`
6. `model_tools.py`
7. `tools/delegate_tool.py`
8. `agent/error_classifier.py` 与 `agent/retry_utils.py`

这样能先抓住主路径，再补异常分支和扩展能力。

---

## 18. 本篇结论

Hermes 的 `AIAgent` 本质上不是“聊天接口封装器”，而是一个比较完整的 Agent orchestration engine。

它最重要的价值在于把下面这些原本容易分散在各处的事情统一起来了：

- Prompt 组装
- Provider 分流
- 工具调用
- 中断控制
- 上下文压缩
- 会话持久化
- memory 同步
- 子代理委托

如果后续继续深入 Hermes，这一层是最应该先吃透的，因为后面几乎所有子系统最终都要回到这条主循环上来。

