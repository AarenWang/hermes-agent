# Hermes Agent 调研 07：产品化入口与平台层（Gateway / TUI / ACP / Cron / Kanban）

## 1. 这篇文档关注什么

这一篇看的是 Hermes 从“Agent 内核”走向“产品与平台”的那一层。

主要关注：

- Gateway：多消息平台接入
- TUI：终端界面产品化
- ACP：编辑器接入
- Cron：定时 Agent 任务
- Kanban / Delegation：向多 Agent 工作流扩展

这一层很重要，因为它回答的是：

- 一个通用 Agent 内核如何变成多入口产品。

---

## 2. 关键文件

最关键的文件：

- `gateway/run.py`
- `gateway/session.py`
- `gateway/platforms/`
- `tui_gateway/server.py`
- `ui-tui/`
- `acp_adapter/server.py`
- `acp_adapter/session.py`
- `cron/jobs.py`
- `cron/scheduler.py`
- `tools/delegate_tool.py`
- `tools/kanban_tools.py`
- `hermes_cli/kanban.py`

文档侧：

- `website/docs/developer-guide/gateway-internals.md`
- `website/docs/developer-guide/acp-internals.md`
- `website/docs/developer-guide/cron-internals.md`
- `website/docs/developer-guide/architecture.md`

---

## 3. 这层的总体判断

Hermes 在这一层最值得学习的，不是“支持的平台多”，而是它在做一件很难的事情：

- 让不同交互面共享同一个 Agent 核心，但各自保留适合自己的交互壳。

这意味着：

- 核心逻辑尽量集中在 `AIAgent`
- 入口层做自己的会话路由、UI、授权和协议适配

这是很有代表性的 Agent 产品架构思路。

---

## 4. Gateway：为什么它不是简单 webhook 适配器

`gateway/run.py` 是 Hermes 的常驻消息网关核心。

### 4.1 它做的不只是“收消息然后调模型”

GatewayRunner 至少负责：

- 多平台 adapter 生命周期
- 用户授权与配对
- session key 解析
- slash command 分发
- 活跃会话 / 运行中 agent 管理
- 消息排队与中断
- cron ticking
- session expiry 与后台维护

所以它更像一个“多平台 Agent runtime host”。

### 4.2 统一 `MessageEvent` 很关键

不同平台的原始事件会被 adapter 归一成 `MessageEvent`，再交给 `GatewayRunner._handle_message()`。

这说明 Hermes 在网关层做了非常标准的平台抽象：

- 平台特异性留在 adapter
- 核心路由逻辑走统一消息模型

---

## 5. Gateway 的 session routing 很值得学

Hermes 在 gateway 中不是随便拿 chat_id 当 session，而是构造结构化 session key：

```text
agent:main:{platform}:{chat_type}:{chat_id}
```

### 5.1 这有什么价值

- 支持多平台隔离
- 支持私聊 / 群聊 / 线程区别
- 让同一个 state store 可以承接多来源会话

这比“一个平台一个 session 文件”成熟得多。

---

## 6. Gateway 的双重保护机制

文档里提到两层 guard：

- base adapter guard
- gateway runner guard

### 6.1 为什么需要两层

因为常驻消息 Agent 最大的问题之一是：

- 当 Agent 正在工作时，又来新消息怎么办？

Hermes 的处理是：

- 有些消息进入 pending queue 并触发 interrupt
- 某些命令如 `/approve`、`/stop` 可以 inline bypass

这说明它已经认真处理了“长任务期间新的控制消息如何插队”这个问题。

这不是 demo 级聊天 bot 会考虑的细节。

---

## 7. 平台适配器体系体现了什么

`gateway/platforms/` 下有大量 adapter：

- Telegram
- Discord
- Slack
- WhatsApp
- Signal
- Matrix
- Mattermost
- Email
- SMS
- DingTalk
- Feishu
- WeCom
- Weixin
- webhook
- api_server
- homeassistant
- qqbot
- yuanbao

### 7.1 说明 Hermes 是“入口平台化”而不是“单平台外挂”

很多项目是先做一个 Telegram bot，再硬扩几个平台。

Hermes 则已经形成了一个较统一的 adapter 体系。

这很适合作为“多入口 Agent 平台”案例来研究。

---

## 8. TUI：前后端分离但不分裂

`ui-tui/` + `tui_gateway/` 是 Hermes 很值得学习的一组设计。

### 8.1 架构

- `ui-tui/`：Node / TypeScript / React Ink 渲染界面
- `tui_gateway/`：Python 通过 stdio JSON-RPC 驱动会话和 Agent

### 8.2 为什么这种设计很聪明

它没有把 Agent 内核迁移到前端，而是：

- 界面归前端技术栈
- Agent 执行留在 Python

这样能保留：

- 统一的 Agent / Tool / Session 逻辑
- 更现代的终端 UI

同时避免做两套执行系统。

### 8.3 `tui_gateway/server.py` 暗示了什么

从源码能看到：

- stdout 保留给 JSON-RPC
- 崩溃日志专门落文件
- 长任务 RPC 走线程池
- slash worker 是持久子进程

这说明 TUI 后端也已经是一个成熟服务，而不只是临时桥接脚本。

---

## 9. Dashboard 复用 TUI，而不是重写聊天界面

AGENTS 文档里专门强调：

- `hermes dashboard` 的聊天面不是重写版 React Chat，而是嵌入真实 `hermes --tui`

### 9.1 这说明 Hermes 在防止“第二套前端逻辑”

很多项目在 Web、CLI、TUI 各写一套交互层，最后行为漂移很严重。

Hermes 试图避免这个问题：

- 主聊天体验只维护一套 TUI 逻辑
- dashboard 通过 PTY bridge 复用它

这是一种非常实际的产品一致性策略。

---

## 10. ACP：为什么它值得单独研究

ACP 是 Hermes 接入编辑器生态的方式。

### 10.1 它不是把 CLI 嵌进编辑器

`acp_adapter/` 做的是：

- 把同步 `AIAgent` 包成异步 JSON-RPC stdio server
- 适配 editor 客户端的 session / approval / tool rendering 语义

### 10.2 SessionManager 的角色

ACP session 会保存：

- session_id
- agent
- cwd
- model
- history
- cancel_event

这说明 ACP 入口不是“每次 editor 请求都新建一个短生命周期 agent”，而是维护 editor-facing live session。

### 10.3 为什么 tool rendering helper 很重要

`acp_adapter/tools.py` 会把 Hermes 工具结果映射成 editor 更适合显示的内容，如：

- file diffs
- shell command text
- truncated previews

也就是说，ACP 层不仅复用执行核心，还对 UI 呈现做了 editor-aware 适配。

---

## 11. Cron：Hermes 调度的是 Agent 任务，而不是 shell 脚本

`cron/` 这一层特别值得注意。

### 11.1 关键区别

Hermes 的 cron 不是传统：

- 到时间跑个命令

而是：

- 到时间新建一个 fresh `AIAgent`
- 加载技能
- 跑 prompt
- 把结果投递到某个平台

### 11.2 为什么这很重要

这意味着 Hermes 把“调度”定义成了 Agent orchestration 的延伸，而不是外部系统任务。

所以 cron job 支持：

- 技能注入
- model/provider 配置
- 投递目标
- repeat 管理
- agent fallback / credential pool

这比 shell cron 强太多，也更贴近 Agent 产品需求。

---

## 12. Cron 的 fresh session 策略体现了什么

文档明确说每个 cron job 都跑在 fresh session 中：

- 没有上次对话历史
- 不依赖持续会话
- prompt 必须自包含
- cronjob toolset 被禁用，防止递归

这很能体现 Hermes 的工程判断：

- 定时任务要可重复、可预测、可隔离。

而不是复用某个脏会话继续跑。

---

## 13. `delegate_task`：单 Agent 向多 Agent 迈进的第一步

`tools/delegate_tool.py` 很清楚地说明了 Hermes 的子代理策略。

### 13.1 子代理是什么

每个 child subagent 都有：

- 自己的 `AIAgent`
- 自己的 task_id
- 自己的工具集
- 自己的终端 session
- 聚焦任务目标的子 prompt

### 13.2 父子关系怎么控制

Hermes 对子代理做了很多限制：

- 默认禁止递归 delegation
- 禁止 `clarify`
- 禁止直接改共享 memory
- 禁止某些高副作用工具
- 控制并发 child 数量
- 控制最大 delegation 深度

这说明 Hermes 把 delegation 当成强能力，但也深知它很危险，所以边界很明确。

---

## 14. `delegate_task` 的设计哲学

开发者注释里写得很清楚：

- 子代理的中间过程不会回流到父代理上下文。
- 父代理只拿摘要。

### 14.1 这解决了什么问题

主要是 context explosion。

如果父代理直接保留所有子代理中间轨迹，委托就失去意义了。

### 14.2 这也带来什么代价

子代理总结本质上是 self-report。

所以文档里还专门强调：

- 对外部 side effect 要求父代理自己验证。

这是一种很负责任的多 Agent 设计态度。

---

## 15. Kanban：从子代理工具升级到工作流系统

`tools/kanban_tools.py` 和 `hermes_cli/kanban.py` 说明 Hermes 已经开始尝试更结构化的多 Agent 协作。

### 15.1 Kanban 在系统里的位置

它不是普通 CLI feature，而是：

- task board
- worker lifecycle
- orchestrator routing
- dependency graph
- dispatcher integration

### 15.2 worker 与 orchestrator 工具面不同

源码里很明确：

- dispatcher-spawned worker 只看到任务生命周期相关工具
- orchestrator profile 才能看到 board-routing 类工具，如 `kanban_list`、`kanban_unblock`

这说明 Hermes 已经开始给不同 Agent 角色分配不同 capability surface。

这是非常先进的 Agent workflow 设计。

---

## 16. Kanban 与 Cron / Gateway 的关系

Kanban 不是完全独立系统，它和 Hermes 其他产品层结合得很紧：

- gateway 默认可承载 dispatcher
- `hermes kanban` 提供 CLI board 操作面
- worker 通过 Kanban tools 回写任务状态
- 新任务可以挂技能、指定 assignee、指定 workspace

这意味着 Hermes 正在把：

- 对话式 Agent
- 定时 Agent
- 多 Agent 协作

逐步纳入同一平台。

---

## 17. 这一层最值得学习的点

从产品化与平台化角度，这一层最值得学习的地方有：

- 不同入口共享同一执行核心。
- adapter 层负责协议与 UI 差异，核心层负责推理与工具。
- 常驻 gateway 对会话、中断、授权做了专门处理。
- TUI 和 dashboard 通过复用而不是重写保持一致性。
- ACP 把 Agent 内核接入 editor，而不是复制一套 agent。
- Cron 将调度建模为 Agent 任务。
- Kanban / Delegation 正把 Hermes 推向 workflow platform。

---

## 18. 建议阅读顺序

建议按这个顺序读：

1. `website/docs/developer-guide/gateway-internals.md`
2. `gateway/run.py`
3. `gateway/session.py`
4. `tui_gateway/server.py`
5. `ui-tui/README.md` 与 `ui-tui/src/`
6. `website/docs/developer-guide/acp-internals.md`
7. `acp_adapter/server.py`
8. `website/docs/developer-guide/cron-internals.md`
9. `cron/scheduler.py`
10. `tools/delegate_tool.py`
11. `tools/kanban_tools.py`
12. `hermes_cli/kanban.py`

---

## 19. 本篇结论

Hermes 在产品层最值得学习的，不是它接了多少个平台，而是它已经形成了一套比较清楚的“多入口共享单核心”的架构：

- Gateway 负责外部消息平台
- TUI 负责现代终端体验
- ACP 负责编辑器生态
- Cron 负责定时 Agent 任务
- Delegation / Kanban 负责向多 Agent 工作流扩展

这使 Hermes 不再只是一个会调用工具的 CLI，而更像一个通用 Agent 平台的雏形。

