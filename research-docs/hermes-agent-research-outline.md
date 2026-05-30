# Hermes Agent 调研大纲

## 1. 调研目标

将 `hermes-agent` 作为“通用 AI Agent 工程案例”来学习，重点不是只看它“能做什么”，而是理解它如何把以下几个难题工程化：

- Agent 主循环如何稳定运行。
- Prompt、工具、记忆、上下文如何协同。
- 多入口形态如何复用同一套 Agent 核心。
- 插件、技能、Provider、工具后端如何做可扩展设计。
- 安全、持久化、调度、可观测性如何落到代码里。

---

## 2. 项目功能扫描

从仓库结构、README、开发者文档和核心源码来看，Hermes 已经不是“单一聊天 Agent”，而是一套比较完整的 Agent 平台，主要能力包括：

- 交互入口：CLI、TUI、消息网关、ACP/IDE、Python Library、Batch Runner、API Server。
- 模型接入：支持多 Provider，并兼容多种 API 模式，包括 OpenAI Chat Completions、OpenAI Responses/Codex、Anthropic Messages。
- 工具系统：内置大量工具，覆盖终端、文件、浏览器、Web 检索、图像、语音、MCP、子代理委托、计划管理、Session Search 等。
- 上下文系统：支持 `SOUL.md`、`AGENTS.md`、`.hermes.md`、技能、记忆、用户画像、平台提示等多层 Prompt 组装。
- 记忆与会话：SQLite 持久化、FTS5 全文检索、跨 Session 检索、用户画像和长期记忆。
- 插件系统：支持普通插件、Memory Provider、Context Engine、Model Provider、Image/Video Provider 等多类扩展。
- 技能系统：内置技能、可选技能、技能安装/管理、运行时按任务加载技能。
- 多平台消息网关：Telegram、Discord、Slack、WhatsApp、Signal、Email、SMS、Feishu、DingTalk 等。
- 调度与自动化：内置 Cron/Scheduler，可以把“Agent 任务”定时投递到不同平台。
- 多 Agent 协作：委托子代理、Kanban 协作、批量轨迹生成。
- 训练与研究支持：trajectory 保存、压缩、batch 任务，适合作为训练数据生成基础设施。
- Dashboard / Web：有独立 Web 与 TUI bridge，不只是命令行脚本。

---

## 3. 技术实现扫描

当前能明显看到的关键技术选型如下：

- 语言与运行时：Python 3.11+ 为主，局部配合 Node/TypeScript（`ui-tui/`）。
- LLM SDK：以 `openai` SDK 为核心兼容层，外加 Anthropic 适配层。
- 数据存储：SQLite + FTS5，承担会话存储与检索。
- 终端与 CLI：`rich`、`prompt_toolkit`。
- TUI：React Ink + Python JSON-RPC 网关。
- Web：FastAPI / Uvicorn。
- 调度：`croniter`。
- 配置：YAML + `.env` 分层。
- 插件与扩展：目录扫描 + manifest + 注册表 + provider profile。
- 工具发现：`tools/registry.py` 自注册机制，工具模块导入即注册。
- 安全控制：危险命令审批、路径安全、Prompt 注入扫描、平台授权/配对。
- 工程治理：依赖强 pin、supply-chain 审计、较完整的 docs 与测试矩阵。

---

## 4. 最值得调研学习的专题

下面这些专题最值得系统学习，建议按优先级逐步展开。

### A. Agent 主循环与执行编排

为什么值得学：
Hermes 的核心价值首先体现在 `AIAgent`，这里集中体现了一个通用 Agent 在真实工程里如何处理“模型调用 + 工具调用 + 中断 + 回退 + 压缩 + 持久化”。

重点问题：
- 一个同步 Agent 主循环如何兼容多 API 模式。
- 如何处理中断、超时、重试、fallback model。
- Tool call 返回后如何安全回填对话历史。
- 如何控制 iteration budget 与子代理预算。

关键文件：
- `run_agent.py`
- `agent/retry_utils.py`
- `agent/error_classifier.py`
- `agent/model_metadata.py`
- `website/docs/developer-guide/agent-loop.md`

### B. Prompt 组装与上下文治理

为什么值得学：
很多 Agent 项目只有“拼 system prompt”，Hermes 已经把 Prompt 组装拆成稳定层与临时层，这是比较成熟的 Agent Prompt 工程设计。

重点问题：
- `SOUL.md`、记忆、技能、项目上下文如何分层注入。
- 为什么要保持 cached prompt 稳定。
- 为什么中途写 memory 不直接重建整段 system prompt。
- 项目上下文文件如何做优先级和安全扫描。

关键文件：
- `agent/prompt_builder.py`
- `agent/prompt_caching.py`
- `agent/context_compressor.py`
- `website/docs/developer-guide/prompt-assembly.md`
- `website/docs/developer-guide/context-compression-and-caching.md`

### C. 工具注册表与 Tool Runtime

为什么值得学：
这是 Hermes 最像“通用 Agent 操作系统”的部分。它不是把工具硬编码到 Agent 里，而是通过注册表、toolset、availability check、动态 schema 形成完整运行时。

重点问题：
- 工具如何自注册。
- Toolset 如何控制不同场景暴露哪些工具。
- 异步工具如何桥接到同步 Agent 主循环。
- MCP 工具、插件工具如何并入统一工具面。

关键文件：
- `tools/registry.py`
- `model_tools.py`
- `toolsets.py`
- `website/docs/developer-guide/tools-runtime.md`

### D. 终端 / 文件 / 浏览器 / MCP 等通用能力后端

为什么值得学：
Hermes 很适合研究“LLM 工具层怎么落地”。不仅有 schema，还有实际执行环境、进程管理、权限审批和多后端抽象。

重点问题：
- 终端工具如何抽象本地、Docker、SSH、Modal、Daytona 等后端。
- 文件编辑如何做 patch/fuzzy match/path safety。
- 浏览器能力如何拆成多个工具而不是一个超大工具。
- MCP 工具如何动态接入。

关键文件：
- `tools/terminal_tool.py`
- `tools/environments/`
- `tools/file_tools.py`
- `tools/browser_tool.py`
- `tools/mcp_tool.py`
- `tools/path_security.py`
- `tools/approval.py`

### E. 会话持久化、记忆与跨会话检索

为什么值得学：
很多 Agent Demo 都是无状态的；Hermes 已经进入“长期使用的 Agent 产品”范畴，所以状态管理做得比较重。

重点问题：
- 为什么用 SQLite + FTS5。
- Session lineage 如何支持压缩后的 parent/child 链路。
- `memory` 与 `session_search` 在职责上如何区分。
- Session Store 与 Memory Provider 的边界是什么。

关键文件：
- `gateway/session.py`
- `hermes_state.py`
- `agent/memory_manager.py`
- `agent/memory_provider.py`
- `tools/memory_tool.py`
- `tools/session_search_tool.py`
- `website/docs/developer-guide/session-storage.md`
- `website/docs/developer-guide/memory-provider-plugin.md`

相关文档：
- [21-session-concepts-and-architecture.md](./21-session-concepts-and-architecture.md) - Session 概念与架构详解
- [05-session-memory-and-cross-session-recall.md](./05-session-memory-and-cross-session-recall.md) - Session 存储和记忆管理

### F. 插件架构与 Provider 扩展机制

为什么值得学：
Hermes 的扩展面非常丰富，而且不是单一种类插件。这对学习“可插拔 Agent 平台”很有价值。

重点问题：
- 普通插件如何注册 hooks / tools / CLI commands。
- Memory Provider、Context Engine、Model Provider 为什么分成不同 discovery 路径。
- “通用插件系统”与“专用 provider 系统”各自解决什么问题。
- 如何避免插件逻辑侵入核心代码。

关键文件：
- `hermes_cli/plugins.py`
- `plugins/memory/`
- `plugins/context_engine/`
- `plugins/model-providers/`
- `agent/context_engine.py`
- `website/docs/developer-guide/model-provider-plugin.md`
- `website/docs/developer-guide/context-engine-plugin.md`
- `website/docs/developer-guide/memory-provider-plugin.md`

### G. 技能系统与“自改进 Agent”思路

为什么值得学：
Hermes 的独特点之一是把技能视为一等对象，而不只是 Prompt 模板。这很适合研究“可演化 Agent”。

重点问题：
- 技能与普通 Prompt 模板有何不同。
- 运行时如何发现、展示、调用技能。
- 可选技能与内置技能为什么分开。
- Curator / skills sync 是否构成“自进化”闭环的基础设施。

关键文件：
- `skills/`
- `optional-skills/`
- `agent/skill_commands.py`
- `agent/skill_utils.py`
- `tools/skills_tool.py`
- `tools/skill_manager_tool.py`
- `hermes_cli/skills_hub.py`
- `agent/curator.py`

### H. 多入口交互层复用

为什么值得学：
Hermes 不只是一个 CLI 程序，而是多个 UI / 接入层共享一个 Agent 核心。这是架构设计的亮点。

重点问题：
- CLI、Gateway、ACP、Batch、TUI 如何复用 `AIAgent`。
- 哪些逻辑在交互层，哪些逻辑沉到核心层。
- 为什么 TUI 用 Ink + Python 网关，而不是完全重写。

关键文件：
- `cli.py`
- `gateway/run.py`
- `acp_adapter/`
- `ui-tui/`
- `tui_gateway/`
- `website/docs/developer-guide/architecture.md`
- `website/docs/developer-guide/acp-internals.md`
- `website/docs/developer-guide/gateway-internals.md`

### I. 消息网关与平台适配器设计

为什么值得学：
如果你想做“能在 IM 平台长期运行的 Agent”，Hermes 的网关层非常有参考价值。

重点问题：
- 多平台 adapter 如何统一抽象。
- 用户配对、授权、会话路由如何实现。
- 平台 slash command 如何与 CLI command 体系对齐。
- Gateway 中如何管理长生命周期 Agent cache。

关键文件：
- `gateway/run.py`
- `gateway/session.py`
- `gateway/platform_registry.py`
- `gateway/platforms/`
- `hermes_cli/commands.py`
- `website/docs/developer-guide/gateway-internals.md`

### J. 多 Agent 协作、委托与调度

为什么值得学：
这部分体现 Hermes 从“单 Agent 助手”走向“Agent 工作流系统”。

重点问题：
- 子代理委托如何隔离上下文。
- Kanban 插件如何承担任务编排。
- Cron 为什么调度的是 Agent 任务而不是 shell job。
- Batch Runner 如何用于轨迹生成和研究实验。

关键文件：
- `tools/delegate_tool.py`
- `plugins/kanban/`
- `cron/jobs.py`
- `cron/scheduler.py`
- `batch_runner.py`
- `trajectory_compressor.py`
- `website/docs/developer-guide/cron-internals.md`
- `website/docs/developer-guide/trajectory-format.md`

### K. 安全与边界控制

为什么值得学：
真正可用的 Agent 不可能只讨论“能力”，必须讨论“边界”。Hermes 在这方面已有不少工程实践。

重点问题：
- 危险命令审批如何设计。
- Prompt 注入、上下文文件污染、路径越权如何防御。
- 插件、工具、平台接入点各有哪些安全面。
- 依赖 pinning 和供应链治理如何进入开发规范。

关键文件：
- `tools/approval.py`
- `tools/path_security.py`
- `tools/url_safety.py`
- `agent/file_safety.py`
- `agent/tool_guardrails.py`
- `pyproject.toml`
- `SECURITY.md`

### L. 工程化质量：测试、文档、发布、治理

为什么值得学：
Hermes 不是“概念工程”，而是持续演化的大仓库，适合学习一个 Agent 项目如何保持可维护性。

重点问题：
- 文档如何覆盖架构、扩展、运行时。
- 测试如何组织到大量功能面。
- CI 如何处理 lockfile、supply-chain、docs、发布。
- 依赖策略如何从安全事件中反推出来。

关键文件：
- `tests/`
- `.github/workflows/`
- `website/docs/developer-guide/`
- `CONTRIBUTING.md`
- `pyproject.toml`

---

## 5. 建议的调研顺序

如果以“通用 AI Agent 开发案例”来系统学习，建议按下面顺序推进：

1. 先看整体架构图与目录结构。
2. 再啃 `AIAgent` 主循环，理解 Agent 的最小闭环。
3. 接着看 Prompt 组装、上下文压缩、缓存策略。
4. 再看 Tool Runtime，因为这是 Agent 能力落地的关键。
5. 然后看 Session / Memory / Search，理解状态化 Agent。
6. 再看 Plugin / Provider / Skill，理解平台扩展性。
7. 最后看 Gateway / TUI / ACP / Cron / Kanban，理解“产品化和平台化”部分。

---

## 6. 第一阶段建议优先研究的 6 个主题

如果只做第一轮高价值调研，我建议优先：

- `AIAgent` 主循环
- Prompt 组装与上下文压缩
- Tool Registry 与 Toolset 设计
- Terminal/File/Browser/MCP 工具后端
- Session Storage + Memory + Session Search
- Plugin / Provider / Skill 扩展体系

这 6 个主题基本覆盖了“一个通用 Agent 框架为什么能成立”的主干。

---

## 7. 本次扫描后的结论

Hermes 最值得学习的，不是“又接了多少模型、多少平台”，而是它已经把通用 AI Agent 的几个核心难题拆成了相对清晰的子系统：

- 一个稳定的 Agent orchestration 核心。
- 一个可扩展的工具运行时。
- 一个状态化的会话与记忆体系。
- 一套可插拔的 Provider / Plugin / Skill 扩展机制。
- 多入口复用同一核心的产品化架构。

如果后续继续调研，最适合的方法不是横向扫所有目录，而是按专题逐个下钻，并把每个专题再拆成“设计目标、关键实现、优缺点、可复用经验、可改进点”五部分。
