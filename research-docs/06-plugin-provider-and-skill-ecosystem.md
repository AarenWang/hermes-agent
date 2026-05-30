# Hermes Agent 调研 06：Plugin、Provider 与 Skill 生态

## 1. 这篇文档关注什么

这一篇研究 Hermes 的扩展体系。

Hermes 最有平台气质的地方，不只在工具多，而在于它把多种可扩展面分开建模了：

- 普通插件
- model provider
- memory provider
- context engine
- skills

这说明 Hermes 不是只想维护一组固定能力，而是希望形成一个可扩展的 Agent 平台。

---

## 2. 关键文件

核心文件：

- `hermes_cli/plugins.py`
- `agent/memory_provider.py`
- `agent/memory_manager.py`
- `agent/context_engine.py`
- `agent/skill_commands.py`
- `tools/skills_tool.py`
- `plugins/model-providers/`
- `plugins/memory/`
- `plugins/context_engine/`

文档侧：

- `website/docs/developer-guide/model-provider-plugin.md`
- `website/docs/developer-guide/memory-provider-plugin.md`
- `website/docs/developer-guide/context-engine-plugin.md`
- `AGENTS.md` 中 Plugins / Skills 相关部分

---

## 3. Hermes 的扩展体系不是一个机制，而是多层机制

这是最值得先建立的认识。

Hermes 至少有三类扩展：

### 3.1 普通插件

由 `hermes_cli/plugins.py` 管理，可注册：

- hooks
- tools
- CLI commands
- slash commands
- context engine

### 3.2 专用 provider 插件

这些是更系统级的扩展：

- model provider
- memory provider
- context engine

它们不完全走普通插件装载路径，而有各自 discovery 规则。

### 3.3 Skills

Skills 不是 Python 插件，而是“结构化任务知识包”。

它们扩展的是 Agent 的工作知识和操作流程，而不是 Python 运行时能力。

---

## 4. 普通插件系统：为什么值得学

`hermes_cli/plugins.py` 定义了 Hermes 的普通插件管理器。

### 4.1 PluginContext 的意义

插件不是直接乱改全局状态，而是通过 `PluginContext` 这层 facade 注册能力。

它至少能做：

- `register_tool`
- `register_cli_command`
- `register_context_engine`

这是一种比较健康的扩展 API 设计：

- 平台给插件有限的官方能力面。
- 插件不需要硬耦合内部细节。

### 4.2 Hook 体系说明它支持横切扩展

`VALID_HOOKS` 中可以看到很多 hook：

- `pre_tool_call`
- `post_tool_call`
- `pre_llm_call`
- `post_llm_call`
- `on_session_start`
- `on_session_end`
- `pre_gateway_dispatch`
- approval lifecycle hooks

这意味着 Hermes 支持的不只是“加新功能”，还支持对现有流程做横切增强。

例如：

- 观测
- 日志
- 风格转换
- 安全策略
- 平台预处理

---

## 5. 普通插件的发现与启用策略

Hermes 的普通插件来源不止一个：

- bundled plugins
- user plugins
- project plugins
- pip entry points

### 5.1 为什么这很有平台味

因为这允许三种典型扩展场景：

- 官方随仓库分发的能力
- 用户自己装到 `~/.hermes/plugins/`
- 项目级 `.hermes/plugins/` 自定义扩展

### 5.2 插件默认是 opt-in

源码里 `_get_enabled_plugins()` 说明普通插件是 opt-in 模式，只有出现在 `plugins.enabled` 里的才会启用。

这点很重要：

- 扩展灵活
- 但默认不无条件执行不受信任代码

这是对平台安全和可控性的现实考量。

---

## 6. 为什么 model provider 要单独建系统

`model-provider-plugin.md` 很清楚地说明，模型提供方插件不只是普通 plugin 的一种。

### 6.1 原因

model provider 影响的是全局推理运行时：

- base_url
- auth_type
- api_mode
- models_url
- default headers
- auxiliary model

它不仅是“增加一个工具”，而是在定义 Hermes 怎么跟模型服务说话。

### 6.2 所以它单独走 provider profile 机制

Hermes 的 model provider 插件通过 `ProviderProfile` 注册。

这能带来一个很大的好处：

- provider 选择、setup、doctor、model picker、runtime resolver 都能自动连起来。

这是一种把“推理后端”做成正式平台扩展点的设计。

---

## 7. 为什么 memory provider 也单独建系统

memory provider 的角色和 model provider 类似，都是系统级组件，而不是局部增强。

### 7.1 它影响哪些地方

- 系统 Prompt
- turn 前 prefetch
- turn 后 sync
- 可选工具注入
- session end cleanup

这已经超出了普通插件 hook 的范畴。

### 7.2 Hermes 的做法

Hermes 用 `MemoryProvider` ABC 和 `MemoryManager` 统一管理它。

并且明确规定：

- 内置 provider 总在
- 外部 provider 最多一个

这体现了一个非常实用的原则：

- 记忆是系统级状态，不宜同时装多个互相竞争的外部后端。

---

## 8. context engine 为什么也被做成 provider

context engine 不是增加功能，而是替换上下文管理策略。

### 8.1 这和普通插件的区别

普通插件是：

- 在现有流程中加东西

context engine 是：

- 替换现有流程中的一个核心组件

### 8.2 这说明 Hermes 的扩展观

Hermes 把扩展分成了两类：

- extension：加能力
- substitution：换系统组件

context engine 显然属于后者。

这也是为什么它通过 `ContextEngine` ABC 和单选配置来管理。

---

## 9. 普通插件系统与专用 provider 系统的边界

这是 Hermes 扩展架构里最值得学习的点之一。

### 9.1 普通插件适合什么

- 增加 hooks
- 增加工具
- 增加 CLI 指令
- 对运行流程做横切增强

### 9.2 专用 provider 适合什么

- 替换模型接入后端
- 替换记忆后端
- 替换上下文管理后端

### 9.3 为什么要这样分

因为系统级组件有：

- 生命周期要求
- 配置约束
- 单选或互斥关系
- 与核心运行时的深度耦合

如果都塞进一个普通插件系统里，会很快变乱。

Hermes 在这点上的结构划分相当清楚。

---

## 10. Skills 为什么和 Plugins 完全不是一回事

很多人第一次看 Hermes 会把 Skill 理解成“非代码插件”，但更准确的理解是：

- Skill 是结构化任务知识包。

### 10.1 Skill 扩展的是“怎么做事”

它主要包含：

- `SKILL.md`
- `references/`
- `templates/`
- `scripts/`
- `assets/`

所以它本质上是：

- 一段 workflow 指南
- 加上一些 supporting materials

### 10.2 Plugin 扩展的是“系统能做什么”

Plugin 通常改变运行时能力。

Skill 通常改变任务执行知识。

这两者边界很关键：

- Plugin 更像系统扩展。
- Skill 更像操作手册和任务包。

---

## 11. Skills 的 progressive disclosure 设计

`tools/skills_tool.py` 中的设计很值得学。

### 11.1 默认只暴露技能元数据

`skills_list` 只给：

- name
- description
- category

### 11.2 真正用到时才 `skill_view`

`skill_view` 再按需加载：

- `SKILL.md`
- linked files
- references / templates / scripts / assets

这是一种非常好的大规模技能库设计：

- 默认轻量
- 需要时再精读

避免把所有技能正文都塞进 prompt。

---

## 12. Skill slash command 说明技能已深度接入产品层

`agent/skill_commands.py` 表明 skill 不只是工具可调用资源，还是产品级一等入口。

### 12.1 主要行为

- 扫描技能目录，生成 `/skill-name` 命令
- 解析 frontmatter
- 处理平台禁用、OS 兼容
- 构造 skill invocation message
- 把技能内容注入为用户消息，而不是 system prompt

### 12.2 为什么作为用户消息注入

AGENTS 文档明确解释过：

- 这样能保住 prompt caching

这再次说明 Hermes 连 skill 接入方式都在围绕 prompt 稳定性设计。

---

## 13. Skills 的安全处理说明它不是简单读文件

`tools/skills_tool.py` 中能看到很多安全相关逻辑：

- injection pattern 检测
- 受信目录校验
- path traversal 防护
- 平台兼容性检查
- prerequisite / env var readiness 检查

这说明 Hermes 认为 skill 文件本身也是不受完全信任的输入面。

这非常合理，因为 skill 可能来自：

- 仓库内置
- 用户安装
- 外部目录
- 插件技能

---

## 14. Plugin skill 与本地 skill 的共存

`tools/skills_tool.py` 里还有 plugin skill serving 逻辑，说明技能不只来自 `~/.hermes/skills/`。

这意味着 Hermes 的 Skill 生态也开始和 Plugin 生态发生结合：

- 技能可以由插件提供
- 但使用方式仍尽量保持统一

这是一个很有平台潜力的方向。

---

## 15. Curator 与“自进化 Agent”思路

虽然这一轮不深入 `agent/curator.py`，但从代码和 AGENTS 文档可以看出，Hermes 的技能系统不是静态知识库，而在尝试形成自维护闭环：

- skill usage 被追踪
- background review 可以触发 memory/skill 更新
- curator 负责技能生命周期管理

这说明 Hermes 的目标不只是“可加载技能”，而是“技能能随着使用逐步演化”。

这是它区别于普通 Prompt 库的地方。

---

## 16. 对学习通用 Agent 框架的启发

Hermes 的扩展体系给出了几个很好的经验：

- 普通插件和系统级 provider 要分开设计。
- 系统级 provider 最好有清晰 ABC 和单选配置。
- Skill 不该和 Python 插件混为一谈。
- 大技能库要用 progressive disclosure，而不是一次性预加载。
- 扩展面越多，越需要显式边界和启用策略。

---

## 17. 建议阅读顺序

建议按这个顺序读：

1. `hermes_cli/plugins.py`
2. `website/docs/developer-guide/model-provider-plugin.md`
3. `website/docs/developer-guide/memory-provider-plugin.md`
4. `website/docs/developer-guide/context-engine-plugin.md`
5. `agent/memory_provider.py`
6. `agent/context_engine.py`
7. `tools/skills_tool.py`
8. `agent/skill_commands.py`
9. `agent/curator.py`

---

## 18. 本篇结论

Hermes 的扩展体系之所以值得研究，不只是因为它支持插件，而是因为它把不同层级的扩展面区分清楚了：

- 普通插件扩展运行流程
- provider 插件替换系统组件
- skills 扩展任务知识

这种分层让 Hermes 不会很快陷入“一切都是插件”的混乱状态，而是逐步形成一个结构清楚的 Agent 平台生态。

