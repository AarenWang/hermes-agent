# Hermes Context Runtime 与压缩机制

这篇文档讨论的不是“Prompt 怎么写得更像人”，而是 Hermes 在运行时到底如何管理上下文：哪些信息常驻、哪些是会话快照、哪些按需加载、哪些被压缩、哪些沉到持久化存储里供后续检索。

这里的结论以当前仓库实现为准，重点对应这些入口：

- `run_agent.py`
- `agent/prompt_builder.py`
- `agent/context_engine.py`
- `agent/context_compressor.py`
- `agent/prompt_caching.py`
- `agent/subdirectory_hints.py`
- `hermes_state.py`
- `gateway/run.py`
- `website/docs/developer-guide/prompt-assembly.md`
- `website/docs/developer-guide/context-compression-and-caching.md`
- `website/docs/developer-guide/session-storage.md`
- `website/docs/user-guide/features/context-files.md`

## 1. Hermes 管理的不是单一 Context，而是一组分层上下文

可以把 Hermes 的 active context 粗略理解为：

```text
active context
  = cached system prompt
  + current conversation messages
  + tool results
  + ephemeral overlays
  + on-demand recalled context
```

当前实现里，最重要的几层是：

| 层 | 作用 | 主要载体 |
|---|---|---|
| Agent identity / system layer | 定义 Hermes 身份、工具纪律、长期行为边界 | `SOUL.md`、默认 identity、prompt assembly |
| Session snapshot layer | 在会话开始时冻结的记忆和用户信息 | `MEMORY.md`、`USER.md`、部分 memory provider 数据 |
| Project context layer | 仓库约定、目录规则、编码规范 | `.hermes.md` / `HERMES.md` / `AGENTS.md` / `CLAUDE.md` / `.cursorrules` |
| Skills layer | 可复用流程、脚本、参考材料入口 | skills index，后续再用 `skill_view()` 深入 |
| Conversation layer | 当前轮次的 user / assistant / tool 往返 | OpenAI-style `messages` |
| Archive / recall layer | 不常驻 prompt，但可检索的历史会话 | `state.db` + FTS |

核心思想不是“把所有信息都塞进 system prompt”，而是明确区分：

- 哪些内容适合做稳定前缀，便于缓存
- 哪些内容只在 session 启动时快照一次
- 哪些内容应该按需召回，而不是常驻
- 哪些内容应该优先裁剪或压缩

## 2. 运行时主干是统一的 message list

Hermes 的会话主循环围绕统一的内部消息格式工作。无论外部 provider 是 Chat Completions、Codex Responses，还是 Anthropic Messages，内部都会回到统一的 message list，再由 adapter 做协议转换。

抽象形态大致是：

```python
messages = [
    {"role": "system", "content": "...assembled system prompt..."},
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": None, "tool_calls": [...]},
    {"role": "tool", "tool_call_id": "...", "name": "read_file", "content": "..."},
    {"role": "assistant", "content": "...final answer..."},
]
```

这个列表是 Hermes 的运行时主干。上下文压缩、tool pair 修复、provider 转换、token 统计、prompt caching 都围绕它展开。

## 3. System prompt 不是 `prompt_builder.py` 单独完成的

`agent/prompt_builder.py` 很重要，但不能把“最终执行时的 system prompt”简单归因到这一处。

更准确的说法是：

1. `prompt_builder.py` 负责加载和整理一批稳定输入
   - `SOUL.md`
   - project context files
   - skills index
   - 默认 identity 文本
2. `run_agent.py` 在实际运行时继续组装系统层
   - 可选 system message
   - frozen memory snapshot
   - frozen user snapshot
   - 平台提示
   - timestamp / session 信息
   - 某些 provider / mode 相关行为约束
3. 最终生成 cached system prompt，并在每轮请求时和当前 `messages` 一起发给模型

因此更接近仓库现实的表述是：

> Hermes 的 system prompt 是由 `run_agent.py` 主导装配、`prompt_builder.py` 提供关键输入层的运行时产物，而不是单文件模板。

## 4. Cached system prompt 与 ephemeral overlays 是刻意分开的

仓库文档里强调了一条非常关键的设计：Hermes 把“可缓存的系统前缀”和“仅本次 API 调用生效的临时叠加层”分开处理。

稳定的 cached system prompt 里，通常会包含：

1. agent identity
2. tool-aware behavior guidance
3. 可选的静态 personality / provider block
4. frozen memory snapshot
5. frozen user profile snapshot
6. skills index
7. project context files
8. time / session / platform hint

而这些内容不应该被持久化进稳定 system prompt：

- `ephemeral_system_prompt`
- prefill messages
- gateway 派生的本轮临时 overlay
- 后续 turn 才召回的某些动态记忆

这么拆的直接收益是：

- 提高 provider 侧 prompt cache 命中率
- 避免中途频繁改 system prompt 破坏缓存
- 让 memory / gateway / skill 的语义边界更清晰

## 5. Project Context 采用优先级加载，不是全量拼接

Hermes 的 project context 文件不是“看到什么都加载”，而是有明确优先级。

当前文档描述的顺序是：

1. `.hermes.md` / `HERMES.md`
2. `AGENTS.md`
3. `CLAUDE.md`
4. `.cursorrules` / `.cursor/rules/*.mdc`

规则是 first match wins，只选择一种 project context 类型进入启动时的 system prompt。`SOUL.md` 则独立于 project context，从 `HERMES_HOME` 读取，用于 agent identity 槽位。

另外要注意两点：

- 这些内容会先经过安全扫描，再截断后注入 prompt
- 路径解析是 profile-aware 的，`SOUL.md` 不来自工作目录，而来自当前 `HERMES_HOME`

## 6. 子目录 Context 不是改写 system prompt，而是按需发现

Hermes 还有一层很关键的渐进式上下文发现机制：`SubdirectoryHintTracker`。

工作方式是：

1. 启动时只把当前工作目录命中的 context file 加入 system prompt
2. 会话过程中，agent 通过 `read_file`、`search_files`、`terminal` 等工具访问某个子目录
3. `SubdirectoryHintTracker` 从工具参数里抽取路径
4. 它向上查找相关目录中的 `AGENTS.md`、`CLAUDE.md`、`.cursorrules`
5. 发现结果作为 hint 附加到 tool result，而不是去重建 system prompt

这套设计的重点是：

- 避免 system prompt 无限膨胀
- 保持稳定前缀不被局部目录规则频繁污染
- 让上下文 discovery 和真实文件访问行为耦合

## 7. Memory 不是单一 Markdown 文件，而是多层组合

Hermes 的 memory context 不是只有 `MEMORY.md` 和 `USER.md`。

更准确地说，它是几层东西叠加：

- 本地 `MEMORY.md`
- 本地 `USER.md`
- memory provider 插件提供的外部长期记忆能力
- 必要时通过 `session_search` 召回的历史消息
- skills 带来的程序化操作记忆

其中一个很重要的实现细节是：

> 本地 memory 和 user profile 在 session 启动时会作为 frozen snapshot 注入；会话中间写盘不会自动改写已经构建好的 cached system prompt。

这是一种明确的 trade-off：

- 优点：system prompt 稳定，利于缓存和语义可预测
- 代价：mid-session memory update 不会立刻反映到已构建的稳定 prompt 上

## 8. Session Archive 是 SQLite，不应写死为单一路径

Hermes 的历史会话不是简单写 JSONL，而是落到 SQLite `state.db` 中，并通过 FTS 支持检索。

从结构上看，最重要的表包括：

- `sessions`
- `messages`
- `messages_fts`
- `messages_fts_trigram`
- `state_meta`
- `schema_version`

这层更适合被理解为：

```text
active messages = 当前工作内存
state.db + FTS = 可搜索的持久化会话归档
```

这里需要特别避免一个常见误写：虽然默认位置通常是 `~/.hermes/state.db`，但仓库当前实现是 profile-aware 的。更准确的表述应该是：

> 默认数据库位于当前 `HERMES_HOME/state.db`，`~/.hermes/state.db` 只是默认 home 下的具体展开结果。

## 9. Context 压缩被抽象成可插拔 ContextEngine

Hermes 没把压缩逻辑写死成一个函数，而是抽象成 `ContextEngine`。

内置默认实现是 `ContextCompressor`，但配置入口是：

```yaml
context:
  engine: "compressor"
```

这意味着“上下文管理”在架构上不是只能做摘要压缩，也允许以后替换成别的 engine，例如更偏 lossless 的策略。

从职责上看，`ContextEngine` 主要负责：

- 判断是否需要压缩
- 执行压缩
- 在需要时暴露辅助工具
- 跟踪 token usage

这说明 Hermes 把 context management 视为一个 runtime subsystem，而不是单点技巧。

## 10. 双层压缩：Gateway Hygiene + Agent Compressor

Hermes 当前有两层独立压缩机制：

### 1. Gateway Session Hygiene

- 运行位置：`gateway/run.py`
- 触发时机：agent 处理消息前
- 作用：给长寿命 gateway session 做安全网
- token 来源：优先用上轮 API 报告的 token，用不到时才粗估

### 2. Agent ContextCompressor

- 运行位置：`agent/context_compressor.py` + `run_agent.py`
- 触发时机：agent tool loop 内
- 作用：正常的主压缩路径
- token 来源：更接近真实 API usage

两层关系可以概括为：

```text
gateway hygiene = pre-agent safety net
agent compressor = main context compaction path
```

## 11. 不要把某一组压缩参数写成“全局不变事实”

Hermes 文档里常见的压缩参数示例包括：

```yaml
compression:
  enabled: true
  threshold: 0.50
  target_ratio: 0.20
  protect_last_n: 20
```

但这类参数应理解为：

- 当前默认配置或文档示例
- 以及部分实现中的默认值

而不是“本项目永远固定不变的协议常量”。

更稳妥的文档写法应该是：

- 先说明 `compression` 是配置项
- 再说明内置 compressor 有自己的实现默认值
- 最后说明实际行为由 `config.yaml` 和 active context engine 共同决定

这样才符合当前仓库的可配置设计。

## 12. 内置 ContextCompressor 的核心策略

内置压缩器的设计思路可以概括成四步。

### 1. 先清理旧的高成本 tool output

对不在受保护尾部、而且内容过长的旧 tool result，优先做 cheap pre-pass 清理，避免把大量文件内容或终端输出原样带进摘要阶段。

### 2. 划分 head / middle / tail

- `head`：保护 system prompt 和最早的关键交换
- `middle`：压缩主对象
- `tail`：保护最近消息，优先保留最新工作上下文

边界还会考虑 tool_call / tool_result 配对完整性，避免把一对消息硬拆开。

### 3. 用辅助模型生成结构化摘要

摘要不是自由散文，而是偏结构化的工作摘要，通常围绕：

- Goal
- Constraints / Preferences
- Progress
- Key Decisions
- Relevant Files
- Next Steps
- Critical Context

### 4. 重新组装消息列表

压缩后消息通常变成：

1. 受保护 head
2. summary message
3. 保留 tail

同时还会清理孤立的 tool pair，避免 message list 结构失真。

## 13. 压缩是迭代式的，不是每次从零开始

内置 compressor 有 `_previous_summary` 这类状态，用于在后续压缩时增量更新之前的摘要，而不是每次把历史从零重新总结一遍。

这点很重要，因为它说明 Hermes 的压缩更像：

```text
rolling summary maintenance
```

而不是：

```text
one-shot summarization
```

这样可以更平滑地保留进度迁移，例如：

- `In Progress` 变成 `Done`
- 旧 blocker 被移除
- 新文件和新决策被补进摘要

## 14. Prompt Caching 反过来约束了 Context 设计

Hermes 对 Anthropic 模型使用 prompt caching。仓库文档里给出的策略是 `system_and_3`：

- system prompt
- 倒数第 3 条 non-system message
- 倒数第 2 条 non-system message
- 最后一条 non-system message

这带来一个很直接的架构约束：

- system prompt 应尽量稳定
- 不要轻易中途重写稳定前缀
- 子目录 hints 更适合挂在 tool result，而不是 system prompt
- memory 写盘后不立即重建 prompt，是一个有意识的缓存友好选择

因此，prompt caching 不是压缩系统之外的附属优化，而是 Hermes 上下文设计的重要约束条件。

## 15. 一次消息从进入到发给模型的典型流程

可以把主路径抽象成下面这条链：

```text
用户消息进入
  -> gateway 读取或恢复 session
  -> 必要时做 gateway hygiene
  -> AIAgent.run_conversation()
  -> 追加当前 user message
  -> 组装或复用 cached system prompt
  -> ContextEngine 判断是否需要压缩
  -> 必要时压缩 message list
  -> provider adapter 转换请求格式
  -> 调用模型
  -> 解析 assistant response / tool calls
  -> 执行工具
  -> 将 tool result 回写到 messages
  -> SubdirectoryHintTracker 从工具路径中发现局部 context
  -> 持久化 session 和 messages 到 state.db
```

如果只看这个流程，Hermes 的 context management 本质上已经很接近一个 runtime：

- 有稳定层
- 有动态层
- 有缓存层
- 有压缩层
- 有归档层
- 有按需召回层

## 16. 当前实现最值得关注的工程取舍

基于仓库文档和代码，实现上最值得关注的几个取舍是：

1. 稳定前缀优先
   - 为了 prompt cache，不轻易改 system prompt
2. 大体量上下文不常驻
   - 通过 `skill_view()`、`session_search`、subdirectory hints 按需加载
3. 旧 tool output 优先裁剪
   - 先省最便宜的 token
4. 历史细节沉到可检索归档
   - 不要求所有历史都持续停留在 active prompt 中
5. 压缩系统是可替换 runtime
   - `ContextEngine` 允许未来替换成别的管理策略

## 17. 一句话总结

Hermes 的 Context 管理更适合被定义为：

> 一个以统一 message list 为运行时主干、以 `run_agent.py` + `prompt_builder.py` 组装稳定系统层、以 `ContextEngine` / `ContextCompressor` 管理上下文压力、以 `state.db` 提供持久化检索归档、并以 prompt caching 约束整体设计边界的 Context Runtime。

如果后续还要继续研究，这条线最值得继续深挖的不是“有没有压缩”，而是：

- 哪些上下文应该常驻
- 哪些应该快照
- 哪些应该按需加载
- 哪些应该进 archive 而不是 prompt
- 压缩后如何可恢复地找回细节
- 如何把 context 生命周期做成更可观测、可调度、可验证的 runtime
