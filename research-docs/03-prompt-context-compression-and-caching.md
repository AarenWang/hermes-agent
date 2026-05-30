# Hermes Agent 调研 03：Prompt 组装、上下文压缩与缓存

## 1. 这篇文档关注什么

这一篇研究 Hermes 如何回答一个很关键的问题：

- 在一个长期运行、会调工具、会跨会话记忆的 Agent 里，系统 Prompt 到底该怎么组织？

Hermes 在这方面的设计非常值得学习，因为它不是简单拼接几段字符串，而是把 Prompt 当作一个“受缓存、上下文窗口、记忆一致性、安全边界约束的运行时系统”。

---

## 2. 关键文件

最重要的文件：

- `agent/prompt_builder.py`
- `agent/prompt_caching.py`
- `agent/context_compressor.py`
- `agent/context_engine.py`
- `run_agent.py`
- `gateway/run.py`
- `website/docs/developer-guide/prompt-assembly.md`
- `website/docs/developer-guide/context-compression-and-caching.md`

---

## 3. Hermes 的核心设计原则

Hermes 在 Prompt 侧最重要的设计原则是：

- 把稳定层和临时层分开。

也就是开发者文档里说的两部分：

- cached system prompt state
- ephemeral API-call-time additions

这不是实现细节，而是架构核心。

### 为什么必须这么分

因为一个成熟 Agent 同时受到四种约束：

- token 成本
- prefix caching 命中率
- 会话连续性
- memory 正确性

如果每一轮都把所有东西重新拼成一个大 system prompt：

- 缓存会失效。
- 一些模型的前缀复用收益会丢掉。
- 用户刚写进 memory 的内容可能被错误地“再次注入”。
- session 恢复时的 prompt 也会发生漂移。

Hermes 的做法是：系统 Prompt 尽量稳定，变化的东西尽量只在 API 调用时临时注入。

---

## 4. 系统 Prompt 的组成层次

根据 `prompt-assembly.md`，Hermes 的 cached system prompt 大致按以下顺序组装：

1. `SOUL.md` 或默认 agent identity
2. 工具行为指导
3. Honcho static block（如果启用）
4. 可选 system message
5. MEMORY snapshot
6. USER profile snapshot
7. skills index
8. 项目上下文文件
9. 时间戳 / session 信息
10. platform hint

### 4.1 这是“分层 prompt”，不是平铺 prompt

这套顺序有明显设计意图：

- identity 最前，定义 Agent 的长期角色。
- memory 和 user profile 在中间，作为稳定个人化上下文。
- skills 和 project context 再往后，作为任务与环境层。
- 时间与平台提示最后，作为动态但仍相对稳定的运行提示。

这比“把所有内容揉成一个 system block”更容易维护。

---

## 5. `SOUL.md` 的定位

`SOUL.md` 是 Hermes 的人格与长期行为定义槽位。

### 5.1 为什么它被放在最前

因为在 Hermes 设计里，`SOUL.md` 不是普通上下文文件，而是 identity slot。

源码里的 `load_soul_md()` 做了三件事：

- 从 `HERMES_HOME/SOUL.md` 读取
- 做安全扫描
- 做长度截断

如果读取成功，它会替代 `DEFAULT_AGENT_IDENTITY`。

### 5.2 为什么还要 `skip_soul`

`build_context_files_prompt(skip_soul=True)` 的存在说明 Hermes 明确避免 SOUL 在 Prompt 里出现两次：

- 一次作为身份
- 一次作为上下文文件

这是很细但很重要的一点，说明 Prompt 组装是被认真建模过的。

---

## 6. 项目上下文文件的注入策略

Hermes 并不是把所有可能的上下文文件都读进来，而是有优先级。

根据文档和 `build_context_files_prompt()`，优先级大致是：

1. `.hermes.md` / `HERMES.md`
2. `AGENTS.md`
3. `CLAUDE.md`
4. `.cursorrules` / `.cursor/rules/*.mdc`

并且是“first match wins”。

### 6.1 这体现了两个判断

第一，Hermes 认为项目上下文应该有一个主入口，而不是无节制叠加。

第二，它兼容多种生态：

- Hermes 自己的 `.hermes.md`
- 通用 agent 项目的 `AGENTS.md`
- Claude 生态的 `CLAUDE.md`
- Cursor 生态的 rules

这是一种很务实的 Prompt 兼容策略。

### 6.2 上下文文件是带安全处理的

这些文件都会经过：

- prompt injection pattern 扫描
- 长度截断
- 前置 YAML frontmatter 处理

这说明 Hermes 认识到“项目上下文文件本身就是 Prompt 注入入口”。

---

## 7. Memory 为什么是 snapshot 而不是实时重建

Hermes 将 memory 与 user profile 作为 frozen snapshot 注入新 session。

### 7.1 这解决了什么问题

如果每次 memory 写入后都立即重建 system prompt，会带来两个问题：

- 已经知道这段信息的模型，会在下一轮又看到一个变化后的 system prompt。
- prefix cache 会被频繁打碎。

Hermes 的做法是：

- mid-session 的 memory write 先落盘。
- 当前会话中的 system prompt 不因此立刻整体变形。
- 新 session 或显式重建时再更新 snapshot。

### 7.2 这是一种“memory correctness 优先”的策略

它默认认为：

- Agent 在本轮中刚刚写入的 memory，模型不必立刻通过 system prompt 再被喂一次。
- 否则容易造成重复信息注入和缓存失稳。

这非常适合长期对话 Agent。

---

## 8. skills index 为什么放进 Prompt，而不是直接加载所有技能

Hermes 不会把所有技能的全文都塞进 system prompt。

它更常见的做法是：

- 在 Prompt 中放一个紧凑的 skills index。
- 真正需要时再通过 `skill_view()` 或 skill slash command 去加载具体技能。

### 8.1 这是一种 progressive disclosure 思路

这和 `tools/skills_tool.py` 的设计一致：

- `skills_list` 给元数据。
- `skill_view` 再加载正文和 supporting files。

也就是说，技能系统在 Prompt 里体现的是“可发现性”，而不是“全量预加载”。

### 8.2 这样做的好处

- 降低默认 Prompt 大小。
- 保留大规模技能库的可扩展性。
- 需要时再下钻，符合 Agent 的工具化工作流。

---

## 9. Tool-use guidance 与 model-specific guidance

`prompt_builder.py` 中有几类很重要的常量：

- `MEMORY_GUIDANCE`
- `SESSION_SEARCH_GUIDANCE`
- `TOOL_USE_ENFORCEMENT_GUIDANCE`
- `GOOGLE_MODEL_OPERATIONAL_GUIDANCE`

### 9.1 这说明 Hermes 把 Prompt builder 当成“策略装配层”

它不是只拼用户内容，而是在这里灌入运行策略：

- 什么时候该用 memory。
- 什么时候该用 session_search。
- 对某些模型要更强制地要求“说到做到，用工具执行”。
- 某些模型需要额外 operational rule。

这让 Hermes 的 Prompt 层不只是描述角色，还描述“Agent 应该如何工作”。

---

## 10. 临时层为什么不持久化

Hermes 明确区分 API-call-time-only layers，例如：

- ephemeral_system_prompt
- prefill messages
- gateway-derived session overlays
- 后续 turn 的某些 Honcho recall 注入

### 10.1 这背后的关键思想

有些信息应该影响当前调用，但不应该变成长久的系统前缀。

例如：

- 当前 turn 的预算告警
- 当前 turn 的 memory prefetch
- 当前入口的临时平台上下文

如果把这些写回 cached prompt，会污染后续所有调用。

所以 Hermes 把它们放在 API-call-time 注入层，而不是 system prompt 常驻层。

---

## 11. 上下文压缩是怎么设计的

Hermes 的上下文治理有双层结构：

- Gateway Session Hygiene
- Agent ContextCompressor

### 11.1 Gateway hygiene：85% 安全网

在 `gateway/run.py` 中，存在一个更高阈值的会话卫生压缩逻辑，主要作用是：

- 在 agent 真正开始处理消息前，先防止 session 膨胀到危险程度。

它更像保险丝。

### 11.2 Agent compressor：50% 主压缩机制

在 `agent/context_compressor.py` 中，压缩是 Agent 主循环内的正式机制。

开发者文档明确说明默认阈值大约是上下文窗口的 50%。

这说明 Hermes 的思路是：

- 不等到快炸掉才压。
- 而是在还有余量时就开始做主动治理。

---

## 12. 内置压缩算法怎么做

根据 `context-compression-and-caching.md`，内置压缩大致分四步：

1. 清理旧的大 tool outputs
2. 确定 head / middle / tail 边界
3. 用辅助模型总结 middle 区域
4. 用 head + summary + tail 重新组装消息

### 12.1 为什么先清旧 tool output

这是非常实用的策略。

很多 Agent 对话膨胀不是因为自然语言，而是因为：

- 文件内容
- 测试输出
- 终端长日志
- 搜索结果正文

先把旧的大 tool outputs 替换成占位提示，可以不花 LLM 调用就节省大量 token。

### 12.2 为什么保护 tail

Hermes 会保护最近的一段 tail，并且尽量保持 tool call / tool result 成组。

这解决的是上下文压缩里最常见的两个坑：

- 刚发生的上下文被过早吃掉。
- 工具调用链被切断，导致后续消息不合法或难以理解。

---

## 13. 为什么压缩是 ContextEngine 抽象，而不是写死

`agent/context_engine.py` 定义了 ContextEngine 抽象，默认实现是 `ContextCompressor`。

这说明 Hermes 认为“上下文管理策略”本身是可替换的。

### 13.1 这有什么架构价值

因为不同 Agent 项目可能想要不同的上下文策略：

- lossy summarization
- lossless context management
- DAG / memory graph
- retrieval-driven replay

Hermes 的选择是：

- 先提供一个默认压缩器。
- 再把接口抽象成插件点。

这是一种很好的可演进设计。

---

## 14. Prompt caching 的重点不在“有没有缓存”，而在“怎么保住缓存”

Hermes 这里最值得学的，不是它支持 Anthropic prompt caching，而是它的很多 Prompt 设计都在服务“缓存稳定”：

- system prompt 不轻易重建
- memory snapshot 不实时覆写
- skill index 不全量膨胀
- 临时层不回写
- session 恢复尽量复用存量 prompt

### 14.1 这是一种“以 cache boundary 为中心”的 Prompt 工程

这比普通“优化 prompt 词句”的层面更高级。

在长期对话 Agent 中，这种工程思想往往比单次 prompt 写得多漂亮更重要。

---

## 15. 对学习通用 Agent 的启发

从 Hermes 的 Prompt / Context 设计里，可以提炼出五个通用经验：

- Prompt 需要分层，不应该只有一个大模板。
- 稳定层和动态层必须区分。
- memory 应该以一致性和 cache 稳定性为前提设计。
- 上下文压缩要考虑工具回合结构，而不只是文本长度。
- 上下文治理最好是可替换策略，而不是写死实现。

---

## 16. 建议阅读顺序

建议按这个顺序阅读：

1. `website/docs/developer-guide/prompt-assembly.md`
2. `agent/prompt_builder.py`
3. `website/docs/developer-guide/context-compression-and-caching.md`
4. `agent/context_engine.py`
5. `agent/context_compressor.py`
6. `agent/prompt_caching.py`
7. `run_agent.py` 中与 `_cached_system_prompt`、`_compress_context` 相关的部分

---

## 17. 本篇结论

Hermes 的 Prompt 系统最值得学习的，不是“写了哪些提示词”，而是它把 Prompt 视为一个运行时架构问题：

- 什么应该稳定。
- 什么应该临时注入。
- 什么应该快照化。
- 什么应该压缩。
- 什么应该由插件替换。

这让 Hermes 的 Prompt 层不只是“提示模板”，而是 Agent 稳定运行的重要基础设施。

