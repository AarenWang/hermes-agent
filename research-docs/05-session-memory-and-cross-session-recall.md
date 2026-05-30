# Hermes Agent 调研 05：Session、Memory 与跨会话检索

## 1. 这篇文档关注什么

Hermes 之所以不像一个一次性对话机器人，很大程度上取决于它的状态层设计。

这一篇关注三件事：

- 会话如何持久化。
- memory 如何组织。
- 跨会话检索如何接回 Agent 主循环。

---

## 2. 关键文件

核心文件：

- `hermes_state.py`
- `agent/memory_manager.py`
- `agent/memory_provider.py`
- `tools/memory_tool.py`
- `tools/session_search_tool.py`
- `website/docs/developer-guide/session-storage.md`
- `website/docs/developer-guide/memory-provider-plugin.md`

相关但次核心：

- `gateway/session.py`
- `run_agent.py`
- `agent/prompt_builder.py`

---

## 3. Hermes 的状态层不是一个点，而是两层

Hermes 的长期状态可以分成两种：

- 会话状态：保存在 SQLite `state.db` 中
- 记忆状态：保存在内置 memory 文件和可选外部 memory provider 中

### 3.1 会话状态解决什么

会话状态更关注：

- 发生过什么
- 哪一轮说了什么
- 工具怎么调用过
- 某个 session 的 lineage 是什么

### 3.2 记忆状态解决什么

记忆状态更关注：

- 哪些信息值得长期保留
- 用户是谁
- 用户有哪些稳定偏好
- 跨 session 应提前带入哪些 durable facts

这两层状态功能相关，但职责不同。

---

## 4. 为什么选择 SQLite + FTS5

`hermes_state.py` 明确把 SQLite 作为 Hermes 的 session store。

### 4.1 这比 JSONL 更适合什么场景

开发者文档直接说它替代了早期的 per-session JSONL 方案。

这么做的价值在于：

- 方便多入口共享同一状态库。
- 方便做全文检索。
- 方便做 session lineage 和 metadata 查询。
- 方便 gateway 长期运行。

### 4.2 FTS5 说明 Hermes 重视“能找回来”

Hermes 不只是保存对话，而是要支持：

- 搜某个关键词在哪些会话出现过
- 搜特定工具调用痕迹
- 搜用户以前提过的项目、配置、偏好

这也是 `session_search` 工具存在的基础。

---

## 5. SessionDB 的结构

从 `session-storage.md` 和 `hermes_state.py` 看，数据库里最关键的表有：

- `sessions`
- `messages`
- `messages_fts`
- `messages_fts_trigram`
- `state_meta`
- `schema_version`

### 5.1 `sessions`

保存 session 级元数据，例如：

- source
- model
- started_at / ended_at
- token / billing 统计
- title
- `parent_session_id`

### 5.2 `messages`

保存完整消息历史，包括：

- role
- content
- tool_call_id
- tool_calls
- tool_name
- reasoning
- codex reasoning/message items

这说明 Hermes 保存的不只是“人类可见对话文本”，还保存 Provider/Tool Runtime 所需的结构化 replay 数据。

### 5.3 `messages_fts` 与 `messages_fts_trigram`

这是检索层：

- 普通 FTS5 走 unicode61 tokenizer
- trigram 索引用于 CJK / substring 搜索

这很值得注意，因为 Hermes 不只是“支持搜索”，而是连 CJK 这类检索行为差异都考虑到了。

---

## 6. 为什么有 `messages_fts_trigram`

这是一处很能体现 Hermes 工程成熟度的细节。

### 6.1 普通 FTS5 的限制

对中文、日文、韩文等，默认 tokenizer 往往不适合 phrase / substring 搜索。

### 6.2 Hermes 的做法

为此额外维护 trigram FTS5 表，在需要时走另一条检索路径。

这说明 Hermes 把 session search 当成真实功能，而不是 demo 级“搜索一下英文关键词”。

---

## 7. WAL + contention handling 说明它面向多进程共享

`hermes_state.py` 中一个重要设计点是写竞争处理。

### 7.1 为什么需要它

因为 Hermes 典型运行形态可能包括：

- gateway 常驻进程
- CLI 会话
- worktree agent
- batch / cron

它们都可能同时访问 `state.db`。

### 7.2 Hermes 的措施

- WAL 模式
- 短 SQLite timeout
- 应用层 retry + jitter
- 定期 checkpoint
- NFS/SMB/FUSE 上的 WAL fallback

这说明 Hermes 把状态库当成“共享运行时基础设施”，而不是单进程私有文件。

---

## 8. Session lineage 为什么重要

Hermes 在 `sessions` 表里显式保存 `parent_session_id`。

### 8.1 它解决什么问题

主要是为上下文压缩后 session 分裂服务。

当一段长会话被压缩成新的、更短的上下文后：

- 原 session 不一定直接消失。
- 新 session 可能作为子 session 继续。

### 8.2 这样做的价值

- 可以保留压缩前后的历史链条。
- `/resume` 和 search 可以理解 lineage。
- session title 也可以沿 lineage 演进。

这比“直接覆盖旧历史”更适合长期会话。

---

## 9. `get_messages_as_conversation()` 说明持久化不是只为检索

SessionDB 不只是“保存存档”，还要支持 replay。

`get_messages_as_conversation()` 的存在说明数据库中的消息记录会被重新转成 OpenAI-style conversation，供后续模型调用继续使用。

这也是为什么 Hermes 要存：

- tool_calls
- reasoning fields
- codex message items
- finish_reason

因为它不仅是日志，还是运行时恢复材料。

---

## 10. 内置 memory 与 session history 的边界

Hermes 里同时存在：

- 会话历史
- `MEMORY.md`
- `USER.md`

### 10.1 会话历史保留“发生过什么”

例如：

- 用户让 Agent 改了哪个文件
- 某次测试失败时的错误信息
- 某段对话里出现过的具体内容

### 10.2 memory 保留“以后仍然重要的事实”

例如：

- 用户偏好 Python 3.12
- 用户喜欢什么输出风格
- 某个工作目录是长期默认项目

也就是说，memory 不是 session 的缩写版，而是 durable fact store。

---

## 11. MemoryManager 的位置

`agent/memory_manager.py` 是 Hermes 记忆层的协调器。

### 11.1 它协调哪些对象

至少包括：

- 内置 memory provider
- 最多一个外部 memory provider

开发者文档明确写到：

- builtin provider 总是优先
- 外部 provider 最多一个

### 11.2 它负责哪些动作

从源码能看到：

- `prefetch_all()`
- `queue_prefetch_all()`
- `sync_turn()`
- `get_all_tool_schemas()`
- `handle_tool_call()`

这说明 MemoryManager 不是只在结束时“存一下记忆”，而是贯穿整个 turn 生命周期：

- 调用前 prefetch
- 调用后 sync
- 工具面注入

---

## 12. 外部 memory provider 如何接入

Hermes 支持 memory provider 插件。

### 12.1 为什么设计成 provider，而不是普通 plugin tool

因为 memory 是一类系统级职责：

- 会影响 prompt
- 可能要暴露工具
- 要参与 prefetch
- 要参与 post-turn sync
- 要有自己的初始化和 shutdown 生命周期

所以它被建模成 provider，而不是普通工具。

### 12.2 这说明 Hermes 的扩展边界比较清晰

普通插件适合加局部功能。

memory provider 适合替换或增强“记忆子系统”。

这是一种更健康的扩展分层。

---

## 13. `session_search` 的意义

Hermes 的 `session_search` 工具非常关键，因为它把“数据库里存在历史”真正转化成“Agent 能主动回忆历史”。

### 13.1 这和 memory 不同

`session_search` 是按需检索历史证据。

它适合：

- 用户说“上次我们聊过那个配置”
- Agent 怀疑过去对话里有相关上下文
- 想找某个错误信息或文件名到底在哪里出现过

### 13.2 为什么它值得单独存在

如果没有 `session_search`，Agent 只能依赖：

- 当前上下文窗口
- 已经被压缩进 memory 的少量长期信息

有了它，Agent 才真正具备“跨会话 recall”能力。

---

## 14. 内置 memory 写入为什么是 agent-level tool

`memory` 工具在 Hermes 里不是普通 registry-dispatched tool，而是 agent-level tool。

原因非常直接：

- 它会修改共享的 `MEMORY.md` / `USER.md`
- 它需要限制长度、控制写入语义
- 它要与 Prompt snapshot 一致性协同

这也是为什么 memory 在 Hermes 里更像“状态子系统接口”，而不是一个外部能力调用。

---

## 15. Prefetch 机制为什么重要

在 `run_agent.py` 中，外部 memory provider 会在 tool loop 前做 prefetch，并把结果作为当前 turn 的临时上下文注入。

### 15.1 这意味着什么

意味着 memory 不是只能“被动写入”，还可以“主动提供当前回合需要的上下文”。

这很像 retrieval augmented memory，但比简单 RAG 更系统，因为它和 turn lifecycle 紧密耦合。

### 15.2 为什么它不直接改 cached system prompt

因为 Hermes 仍然坚持：

- prefetch 结果是本轮调用所需的动态上下文。
- 不应该永久写回稳定 system prompt。

这和前一篇讲的 prompt layering 是一致的。

---

## 16. 从状态层看 Hermes 的产品目标

仅从这部分就能看出，Hermes 追求的不是一次性回答器，而是：

- 可恢复
- 可长期使用
- 可跨入口共享
- 可跨会话回忆
- 可带稳定用户画像

这也是它比很多 demo 式 Agent 项目更像“长期陪伴型 Agent 产品”的原因。

---

## 17. 对学习通用 Agent 的启发

Hermes 的状态层给出几个关键经验：

- 会话历史和长期记忆要分层，不要混成一个存储。
- 状态库应该支持检索，不只是归档。
- replay 所需的结构化消息字段要保存完整。
- 记忆 provider 最好当系统组件看待，而不是普通工具。
- 动态 recall 最好通过独立工具或 prefetch 机制接回 Agent。

---

## 18. 建议阅读顺序

建议按这个顺序读：

1. `website/docs/developer-guide/session-storage.md`
2. `hermes_state.py`
3. `agent/memory_provider.py`
4. `agent/memory_manager.py`
5. `tools/memory_tool.py`
6. `tools/session_search_tool.py`
7. `run_agent.py` 中 memory manager / session db 相关部分

---

## 19. 本篇结论

Hermes 的 Session / Memory / Search 设计说明，它已经把“状态化 Agent”当成第一等问题来处理了。

它不是只保存对话记录，而是建立了一套比较清晰的状态分层：

- SQLite 会话库保存结构化历史
- FTS5 / trigram 提供检索能力
- MEMORY / USER 保存 durable facts
- MemoryManager 协调内置与外部 provider
- `session_search` 把历史检索重新变成 Agent 可调用能力

这部分是 Hermes 从“会调工具的模型”进化为“长期运行的 Agent 系统”的关键基础。

