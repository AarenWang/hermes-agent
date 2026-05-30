# Hermes Agent 调研 08：第二轮调研大纲

## 1. 这篇文档回答什么问题

第一轮调研已经覆盖了 Hermes 的主干结构：

- 整体架构与目录结构
- `AIAgent` 主循环与执行编排
- Prompt 组装、上下文压缩与缓存
- Tool Runtime 与能力系统
- Session / Memory / Cross-session recall
- Plugin / Provider / Skill 生态
- Gateway / TUI / ACP / Cron / Kanban 等产品入口

所以第二轮不应该再横向扫目录，而应该挑“还没单独成篇、但代码里明显很厚”的主题继续下钻。

这篇文档的目的就是回答三个问题：

1. 第一轮之后，还剩哪些主题最值得继续研究。
2. 这些主题为什么值得优先研究。
3. 每个主题应该从哪些源码入口切入，以及最后产出什么。

---

## 2. 第一轮之后还缺什么

如果对照 `research-docs/hermes-agent-research-outline.md` 里的专题列表，当前已经系统覆盖的主要是：

- A. Agent 主循环与执行编排
- B. Prompt 组装与上下文治理
- C. 工具注册表与 Tool Runtime
- E. 会话持久化、记忆与跨会话检索
- F. 插件架构与 Provider 扩展机制
- H/I/J. 多入口复用、消息网关、多 Agent / 调度

还没有被单独展开、或者只被顺手提到但没有写透的，主要有下面几块：

- K. 安全与边界控制
- L. 工程化质量：测试、文档、发布、治理
- D. 通用能力后端的实现细节
- Provider Runtime 与多模型兼容细节
- Trajectory / Batch Runner / 数据生成链路
- Observability / usage / cost / rate limit
- 配置解析、profile、多环境行为

其中前六个最值得优先做成第二轮专题。

---

## 3. 第二轮选题原则

第二轮调研建议按下面三个标准筛题：

- 这块是否直接体现 Hermes 的工程难点，而不是功能清单。
- 这块是否有明显的“系统设计 trade-off”，值得总结成可复用经验。
- 这块是否已经在代码中形成独立子系统，而不只是零散辅助代码。

按这个标准看，下面六个主题优先级最高。

---

## 4. 建议优先级

建议第二轮按这个顺序推进：

1. 安全与边界控制
2. 工程化质量与治理
3. 通用能力后端深挖
4. Provider Runtime 与多模型兼容
5. Trajectory / Batch / 研究数据链路
6. Observability / 使用量 / 成本 / 限流

原因很简单：

- 前两项回答的是“这个 Agent 为什么能安全、长期地活在真实环境里”。
- 中间两项回答的是“这个 Agent 的能力后端和模型后端为什么能跑得起来”。
- 后两项回答的是“这个仓库为什么不只是产品，还像研究与运营基础设施”。

---

## 5. 主题一：安全与边界控制

### 5.1 为什么优先级最高

第一轮文档已经多次提到 approval、path safety、prompt injection、gateway trust model，但这些内容还没有单独成篇。

而且 Hermes 的安全明显不是外围补丁，而是内嵌在多个运行时层里：

- 终端执行前的危险命令审批
- 文件访问前的路径约束
- URL 与浏览器访问限制
- skills / context 文件的 prompt injection 检测
- 外部 surface 的授权、审批、输出隔离
- plugin trust model 与 OS-level isolation 的边界说明

这意味着它很适合研究“可执行 Agent 的安全边界到底怎么落地”。

### 5.2 重点问题

- Hermes 把哪些风险视为“内核级问题”，哪些交给外部 sandbox。
- dangerous command approval 是如何工作的，规则粒度在哪一层。
- path security、URL safety、file safety 各解决什么问题，边界如何划分。
- prompt injection 防护出现在什么地方，是输入扫描、技能扫描还是运行时 guardrail。
- Gateway / dashboard / ACP 这些外部入口各自承担哪些信任责任。
- `SECURITY.md` 里宣称的 trust model，和代码是否一致。

### 5.3 建议源码入口

- `SECURITY.md`
- `tools/approval.py`
- `tools/path_security.py`
- `tools/url_safety.py`
- `agent/file_safety.py`
- `agent/tool_guardrails.py`
- `tools/skills_tool.py`
- `tools/cronjob_tools.py`
- `tools/terminal_tool.py`

### 5.4 最终产出建议

建议输出一篇《Hermes Agent 调研 09：安全与边界控制》，固定写成五段：

1. 信任模型
2. 运行前防护
3. 运行时防护
4. 外部入口的授权与审批
5. 边界、盲区与改进点

---

## 6. 主题二：工程化质量与治理

### 6.1 为什么值得单独研究

Hermes 已经不是“概念验证仓库”，而是一个持续演化的大项目。

它在工程治理上有几件很值得研究的事情：

- 大规模测试矩阵
- docs 作为架构说明的一部分，而不是附属品
- supply-chain hardening 进入贡献规范
- lockfile / osv / docs-site / skills-index 等 CI 检查比较完整
- 依赖上界、SHA pinning、风险事件反哺开发规范

这部分很适合作为“Agent 项目怎么从能跑变成可维护”的案例。

### 6.2 重点问题

- Hermes 的测试是按哪几种维度组织的。
- 哪些开发者文档真正承担了“架构文档”的职责。
- 供应链治理为什么会进入贡献指南和 CI。
- dependency pinning policy 是怎样形成并被执行的。
- 文档、测试、workflow、发布之间的关系是什么。

### 6.3 建议源码入口

- `CONTRIBUTING.md`
- `pyproject.toml`
- `.github/workflows/`
- `scripts/run_tests.sh`
- `website/docs/developer-guide/`
- `tests/`

### 6.4 最终产出建议

建议输出一篇《Hermes Agent 调研 10：工程化质量与治理》，重点不要写成流水账，而要回答：

- 它如何维持大仓库可演化。
- 它如何把安全事件转成制度。
- 它如何让文档、测试、CI 一起约束架构。

---

## 7. 主题三：通用能力后端深挖

### 7.1 为什么第一轮还不够

第一轮的第 04 篇主要站在 Tool Runtime 视角看工具系统，但还没有把“终端 / 文件 / 浏览器 / MCP 后端本身”拆开研究。

而这一层恰恰是 Hermes 最像“Agent 能力操作系统”的地方：

- 不只是暴露 schema
- 还要解决执行环境
- 进程生命周期
- 后端抽象
- 持久化输出
- sandbox 行为差异
- 与审批、安全、路径限制的耦合

### 7.2 重点问题

- terminal backend 如何统一 local、docker、ssh、modal、daytona 等环境。
- 为什么文件编辑要做 patch parser、fuzzy match、path safety。
- 浏览器能力为什么拆成多个工具而不是一个巨无霸工具。
- MCP 工具接入和普通内建工具接入有哪些共同点与不同点。
- tool result storage / output limits 为什么是运行时的一部分。

### 7.3 建议源码入口

- `tools/terminal_tool.py`
- `tools/environments/`
- `tools/file_tools.py`
- `tools/file_operations.py`
- `tools/patch_parser.py`
- `tools/fuzzy_match.py`
- `tools/browser_tool.py`
- `tools/browser_supervisor.py`
- `tools/mcp_tool.py`
- `tools/tool_result_storage.py`
- `tools/tool_output_limits.py`

### 7.4 最终产出建议

建议这一篇不要再写“工具注册表怎么发现工具”，而是只回答一句话：

“一个 LLM 想稳定、安全地碰到真实世界后端，需要补哪些运行时层？”

---

## 8. 主题四：Provider Runtime 与多模型兼容

### 8.1 为什么这是隐藏的大头

从目录上看，Provider 体系容易被误读为“多接几个模型插件”。

但实际代码说明，Hermes 的困难在于：

- 同时兼容多种 API 形状
- 处理 reasoning replay 语义差异
- 处理 tool schema 差异
- 处理 OAuth / API key / gateway / base_url 的差异
- 处理 fallback model、auxiliary model、provider-specific quirk

也就是说，这部分研究的不是“支持了哪些模型”，而是“多模型运行时如何不崩”。

### 8.2 重点问题

- provider runtime resolution 的优先级是什么。
- Chat Completions、Responses API、Anthropic Messages 三条路径怎样统一到同一主循环。
- reasoning / reasoning_content / reasoning_details 的兼容为什么这么复杂。
- fallback model 机制的边界是什么，哪些能力支持 fallback，哪些不支持。
- provider profile、runtime provider、adapter 各自承担什么角色。

### 8.3 建议源码入口

- `website/docs/developer-guide/provider-runtime.md`
- `run_agent.py`
- `agent/codex_responses_adapter.py`
- `agent/anthropic_adapter.py`
- `agent/model_metadata.py`
- `agent/auxiliary_client.py`
- `plugins/model-providers/`

### 8.4 最终产出建议

建议输出一篇偏“兼容性工程”的专题，而不是 provider 插件介绍。最佳标题类似：

《Hermes Agent 调研 11：Provider Runtime 与多模型兼容层》

---

## 9. 主题五：Trajectory / Batch / 研究数据链路

### 9.1 为什么值得研究

很多 Agent 项目只把“对话能跑完”当目标。

Hermes 还额外解决了：

- 如何保存 trajectory
- 如何批量跑数据集
- 如何压缩轨迹
- 如何保持数据 schema 稳定
- 如何把 reasoning、tool calls、结果统一成可训练格式

这使它不只是一个产品仓库，也是一套研究与数据生成基础设施。

### 9.2 重点问题

- trajectory format 为什么要特地约束成稳定 schema。
- batch runner 为什么要关闭部分在线能力，例如 persistent memory。
- reasoning、tool calls、tool results 是怎样被归一化进轨迹的。
- trajectory compressor 的保护策略和压缩策略是什么。
- 这套链路更偏训练数据生成，还是更偏调试审计。

### 9.3 建议源码入口

- `website/docs/developer-guide/trajectory-format.md`
- `agent/trajectory.py`
- `run_agent.py` 中 `_convert_to_trajectory_format` / `_save_trajectory`
- `batch_runner.py`
- `trajectory_compressor.py`

### 9.4 最终产出建议

建议把这篇专题写成“研究基础设施视角”，而不是“某个脚本怎么用”。重点回答：

- Hermes 怎样把 agent run 变成数据资产。
- 这套数据结构为什么适合训练、评估和审计。

---

## 10. 主题六：Observability / 使用量 / 成本 / 限流

### 10.1 为什么这块容易被忽视

这部分没有主循环、工具系统那么显眼，但代码里已经有比较成体系的实现：

- `usage_pricing.py`
- `rate_limit_tracker.py`
- `account_usage.py`
- logging / redaction
- Langfuse observability plugin

这说明 Hermes 已经开始处理一个真实平台迟早要面对的问题：

- 模型调用花了多少钱
- 哪些 provider 快到限额
- 日志怎么留、怎么脱敏
- 运行数据如何被外部观测系统消费

### 10.2 重点问题

- token / reasoning token / cost 是怎样被归一化和统计的。
- account usage 对哪些 provider 可用，为什么。
- rate limit guard 是怎么参与调度决策的。
- observability 为什么做成 opt-in plugin，而不是 core hard dependency。
- logging 为什么要和 redaction、session 维度一起设计。

### 10.3 建议源码入口

- `agent/usage_pricing.py`
- `agent/rate_limit_tracker.py`
- `agent/account_usage.py`
- `hermes_logging.py`
- `agent/redact.py`
- `plugins/observability/langfuse/`
- `agent/nous_rate_guard.py`

### 10.4 最终产出建议

建议输出一篇“运营运行时”视角的专题，回答：

- Hermes 如何知道自己用了多少、花了多少、还能跑多久。

---

## 11. 可选补充主题

如果第二轮做完还要继续，下一批可以考虑这两个主题：

### 11.1 配置解析、profile 与多环境行为

建议入口：

- `hermes_cli/config.py`
- `cli.py` 里的 `load_cli_config()`
- `gateway/run.py`
- `hermes_constants.py`
- `hermes_logging.py`

值得研究的原因：

- 同一个系统在 CLI、Gateway、TUI、profile 模式下如何共享配置但不互相污染。

### 11.2 Curator / skills sync / 自改进闭环

建议入口：

- `agent/curator.py`
- `agent/curator_backup.py`
- `tools/skills_sync.py`
- `tools/skill_manager_tool.py`

值得研究的原因：

- 这部分更接近“Agent 如何维护自己的技能生态”，偏演化机制而不是普通技能加载。

---

## 12. 第二轮文档建议模板

为了避免后续文档风格继续发散，建议第二轮每篇都固定用同一套结构：

1. 这篇文档关注什么
2. 为什么这一层值得研究
3. 关键文件
4. 设计目标
5. 关键实现
6. trade-off 与代价
7. 对通用 Agent 框架的启发
8. 建议阅读顺序
9. 本篇结论

如果主题偏“治理”而不是“运行时”，可以把第 4 到第 6 节替换成：

4. 制度设计
5. 实际执行机制
6. 对架构演化的约束作用

---

## 13. 建议的实际执行顺序

如果准备继续写第二轮调研文档，我建议直接按下面的编号推进：

1. `09-security-and-boundary-control.md`
2. `10-engineering-quality-and-governance.md`
3. `11-capability-backends-terminal-file-browser-mcp.md`
4. `12-provider-runtime-and-multi-model-compatibility.md`
5. `13-trajectory-batch-and-research-data-pipeline.md`
6. `14-observability-usage-cost-and-rate-limits.md`

这样做有两个好处：

- 编号和第一轮文档连续。
- 第二轮主题的层次关系也比较清楚。

---

## 14. 本篇结论

第一轮调研已经把 Hermes 的主干说明白了，第二轮最值得做的不是继续扫广度，而是补齐那些真正体现工程深度的“厚层”：

- 安全与边界
- 工程化治理
- 通用能力后端
- Provider 兼容层
- 研究数据链路
- 观测与运营运行时

如果把第一轮理解为“这个系统由什么组成”，那么第二轮最值得回答的问题就是：

“这个系统为什么在真实世界里能长期、可控、可演化地运行。”
