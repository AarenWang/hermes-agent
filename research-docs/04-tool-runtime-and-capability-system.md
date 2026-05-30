# Hermes Agent 调研 04：Tool Runtime 与能力系统

## 1. 这篇文档关注什么

Hermes 的工具系统是整个项目最像“Agent 平台底座”的部分。

这一篇要回答的是：

- 工具如何被发现、注册、筛选和调度。
- Toolset 在系统里扮演什么角色。
- 为什么 Hermes 的工具不是几个普通函数，而是一套运行时系统。

---

## 2. 关键文件

核心文件：

- `tools/registry.py`
- `model_tools.py`
- `toolsets.py`
- `tools/terminal_tool.py`
- `tools/file_tools.py`
- `tools/browser_tool.py`
- `tools/mcp_tool.py`
- `tools/approval.py`
- `tools/environments/`
- `website/docs/developer-guide/tools-runtime.md`

辅助但重要的文件：

- `tools/path_security.py`
- `tools/code_execution_tool.py`
- `tools/delegate_tool.py`
- `tools/kanban_tools.py`

---

## 3. Hermes 对工具系统的定位

Hermes 的工具系统不是“给模型加几个 callable”。

它实际承担了五层职责：

- schema surface：告诉模型有哪些能力
- dispatch layer：把模型调用转到具体实现
- capability filtering：按配置和环境控制哪些工具可见
- environment binding：把工具绑到终端、浏览器、文件系统、MCP 等后端
- safety boundary：在危险命令、路径访问、交互型工具上加保护

所以它更像一个 capability runtime，而不是简单工具库。

---

## 4. 自注册机制：为什么很重要

Hermes 的一个核心设计是：工具模块在 import 时就通过 `registry.register(...)` 自注册。

### 4.1 这带来的直接效果

- 工具定义和实现放在同一个模块里。
- 新增一个工具，不需要维护一个巨大的中央 import 列表。
- schema、handler、availability check、emoji、toolset 归属等信息天然绑定。

### 4.2 `discover_builtin_tools()` 的意义

`tools/registry.py` 中的 `discover_builtin_tools()` 会扫描 `tools/*.py`，通过 AST 检测是否有顶层 `registry.register()`，再决定是否导入。

这一步很关键：

- 只导入真正会注册工具的模块。
- 避免把 `tools/` 目录里的辅助模块全都当成工具模块。

它说明 Hermes 在“自动发现”上不是随便 `import *`，而是做了最基本的结构约束。

---

## 5. 注册表是什么角色

`ToolRegistry` 是工具系统的核心注册中心。

### 5.1 它保存的不是只有 schema

从 `registry.register()` 的参数可以看出，一个工具条目至少包含：

- `name`
- `toolset`
- `schema`
- `handler`
- `check_fn`
- `requires_env`
- `is_async`
- `description`
- `emoji`

这意味着注册表同时承载了：

- 模型接口定义
- 运行时可用性
- 实际执行入口
- UI 展示辅助信息

### 5.2 `_generation` 说明它还考虑了动态变化

`tools/registry.py` 里有 `_generation` 计数。

这通常用于：

- 缓存失效
- 动态 schema 更新
- 插件注册后刷新状态

这说明注册表被当成“会变化的系统状态”，而不只是启动时一次性构建的静态对象。

---

## 6. Toolset 的作用不是分类，而是能力面控制

`toolsets.py` 很容易被误解成“工具分类文件”，但它的真正作用更接近 capability surface 设计。

### 6.1 `_HERMES_CORE_TOOLS`

AGENTS 文档明确指出 `_HERMES_CORE_TOOLS` 不是死代码。

它表示 Hermes 默认向 CLI 和消息平台暴露的一组核心能力。

### 6.2 Toolset 是场景化能力打包

Hermes 里有很多 toolset：

- `web`
- `terminal`
- `file`
- `browser`
- `memory`
- `session_search`
- `delegation`
- `kanban`
- `homeassistant`

这不是为了目录好看，而是为了：

- 不同入口可以暴露不同能力面。
- 子代理可以拿到受限工具集。
- ACP 可以有专门的工具面。
- 某些 profile 可以启用特定工作流能力。

### 6.3 `get_tool_definitions()` 是总闸门

`model_tools.get_tool_definitions()` 是模型最终看到哪些工具的关键入口。

它会综合：

- enabled toolsets
- disabled toolsets
- registry 中已有工具
- `check_fn` 结果
- 动态 schema patching

也就是说，模型看到的工具列表并不是“所有注册工具”，而是 runtime 过滤后的结果。

---

## 7. `check_fn`：Hermes 的能力可见性是运行时判定的

每个工具可以有一个 `check_fn`。

它的作用是：

- 在工具 schema 暴露给模型前，先判断这个工具当前是否真的可用。

### 7.1 这点非常重要

因为一个 Agent 系统里经常会出现：

- API key 没配
- 某个服务没起来
- 本地二进制没安装
- 当前平台不支持某能力

Hermes 的策略不是“照样把工具暴露出去，等调用时报错”，而是：

- 尽量在 schema 层就把不可用工具隐藏掉。

这能减少模型幻觉式调用，也降低运行时噪音。

---

## 8. Dispatch 是怎么走的

在运行时，工具调度主链大致如下：

```text
model tool_call
  ↓
run_agent.py
  ↓
model_tools.handle_function_call()
  ↓
agent-level tool? → 直接由 AIAgent 处理
  ↓
plugin pre_tool_call hook
  ↓
registry.dispatch()
  ↓
sync call / async bridge
  ↓
plugin post_tool_call hook
```

### 8.1 这条链很成熟

它把工具执行拆成了几个层次：

- Agent 自身是否要接管
- 插件是否要介入前后处理
- 注册表是否能找到 handler
- 异步 handler 如何桥接
- 错误如何包装成 JSON 返回模型

这不是简单的 `tool_name -> function()` 映射，而是一个可插拔的执行流水线。

---

## 9. 为什么部分工具被 AIAgent 拦截

Hermes 明确把四类工具列为 agent-loop tools：

- `todo`
- `memory`
- `session_search`
- `delegate_task`

### 9.1 原因

因为这些工具本身就是 Agent 执行机制的一部分，而不只是外部 side effect：

- `todo`：改的是 agent 内部任务规划状态
- `memory`：改的是长期记忆
- `session_search`：读的是会话数据库
- `delegate_task`：会生成新的子 Agent

这说明 Hermes 有很明确的边界意识：

- 有些能力适合做普通工具。
- 有些能力必须是“编排层一级公民”。

这是设计 Agent 框架时非常重要的判断。

---

## 10. 异步桥接策略体现了什么

`model_tools.py` 中有 `_run_async()` 和持久 event loop 管理逻辑。

### 10.1 为什么需要这个桥接层

因为 Hermes 的主循环是同步的，但：

- 某些工具 handler 是 async
- 某些环境本身已有 event loop
- 并行工具又跑在线程池 worker 中

如果每次都粗暴 `asyncio.run()`，会触发常见问题：

- event loop 已关闭
- cached async client 绑定失效
- gateway 内部 loop 冲突

### 10.2 Hermes 的做法

- CLI 主线程：用持久 loop
- gateway 异步环境：起新线程处理
- worker thread：线程局部持久 loop

这是一种很现实的 sync/async bridge 设计。

---

## 11. 终端工具为什么是工具系统中的“核心后端”

`terminal_tool.py` 在 Hermes 里地位非常高，因为很多真实 Agent 任务最终都要落到终端。

### 11.1 它不是简单 shell wrapper

终端系统还包含：

- 多后端环境抽象
- 背景进程管理
- approval callback
- cwd 管理
- PTY 支持

### 11.2 `tools/environments/` 说明了什么

Hermes 把终端后端抽象成多种执行环境：

- local
- docker
- ssh
- singularity
- modal
- daytona
- vercel sandbox

这说明 Hermes 不是把“运行 shell 命令”看作固定本地行为，而是把它作为一个可切换的 execution backend。

这对通用 Agent 平台非常关键。

---

## 12. 审批与安全不是外围功能，而是 Tool Runtime 的一部分

`tools/approval.py` 和 `DANGEROUS_PATTERNS` 机制是 Hermes 工具系统里非常重要的一环。

### 12.1 运行前检测而不是运行后补救

在终端命令执行前，Hermes 会匹配危险模式，例如：

- `rm -rf`
- `mkfs`
- `DROP TABLE`
- `curl | sh`
- service kill / destructive overwrite

然后通过：

- CLI prompt
- gateway approval callback
- smart approval

来决定是否继续。

### 12.2 为什么这说明工具系统比较成熟

因为它意味着 Hermes 把工具调用当作潜在高风险执行，而不是把安全问题留给外层产品自己解决。

---

## 13. 文件、浏览器、MCP 这些工具体现了什么思路

### 13.1 文件工具

`file_tools.py` 不只是读写文件，还和：

- `path_security.py`
- fuzzy patch
- search

配合工作。

说明 Hermes 把“文件操作”做成了比较完整的一套能力，而不是单个写文件函数。

### 13.2 浏览器工具

`browser_tool.py` 把浏览器拆成多个原子工具：

- navigate
- snapshot
- click
- type
- scroll
- back
- press
- console
- cdp

这比“一个 browser tool 收所有动作参数”更适合 function-calling 模型理解。

### 13.3 MCP 工具

`mcp_tool.py` 说明 Hermes 试图把外部 MCP server 也纳入统一工具面。

这非常关键，因为它使 Hermes 的能力系统可以跨出 repo 内置代码，接入外部生态。

---

## 14. `execute_code` 与 `delegate_task` 反映的两种扩展思路

Hermes 在高阶能力上提供了两个非常值得研究的工具：

- `execute_code`
- `delegate_task`

### 14.1 `execute_code`

它代表的是：

- 用程序化脚本压缩多轮工具调用成本。

也就是说，Agent 不必每一步都由 LLM 主导，也可以通过一段代码来调工具。

### 14.2 `delegate_task`

它代表的是：

- 用子代理隔离复杂上下文，把结果摘要回父代理。

这两个工具从不同方向扩展了 Agent 的能力边界：

- 一个偏程序化执行。
- 一个偏多 Agent 并行。

它们都已经不只是“普通工具”了，而是在改写 Agent 的工作方式。

---

## 15. Kanban 工具说明 Hermes 正在走向 workflow system

`tools/kanban_tools.py` 是一个非常有意思的信号。

它说明 Hermes 不仅支持单次工具调用，还在探索更结构化的任务生命周期工具：

- `kanban_show`
- `kanban_list`
- `kanban_complete`
- `kanban_block`
- `kanban_heartbeat`
- `kanban_comment`
- `kanban_create`
- `kanban_unblock`
- `kanban_link`

### 15.1 为什么这很值得学

因为它体现了工具系统从“调用外部能力”向“驱动工作流对象”演进：

- 工具不只是操作文件和终端。
- 也可以操作任务、依赖和协作状态。

这意味着 Hermes 的 Tool Runtime 正在承担 workflow kernel 的一部分职责。

---

## 16. 对学习通用 Agent 框架的启发

Hermes 的工具系统给出几个很有价值的经验：

- 工具定义要和执行元数据绑定在一起。
- 工具可见性应该是运行时判定的。
- Toolset 应该作为 capability surface 控制层。
- Agent 级工具和普通工具要分层。
- 安全审批和路径保护应内建在 Tool Runtime。
- 执行环境要抽象，不能默认只有本地 shell。

---

## 17. 建议阅读顺序

建议按这个顺序读：

1. `website/docs/developer-guide/tools-runtime.md`
2. `tools/registry.py`
3. `model_tools.py`
4. `toolsets.py`
5. `tools/terminal_tool.py`
6. `tools/file_tools.py`
7. `tools/browser_tool.py`
8. `tools/mcp_tool.py`
9. `tools/approval.py`
10. `tools/delegate_tool.py`

---

## 18. 本篇结论

Hermes 的 Tool Runtime 之所以值得研究，不是因为“工具多”，而是因为它已经具备一个成熟能力系统的主要组成：

- 注册表
- 自动发现
- capability filtering
- dispatch pipeline
- async bridge
- 安全审批
- 多后端环境
- workflow-oriented 高阶工具

从通用 AI Agent 案例的角度，这部分几乎就是 Hermes 的“系统调用层”。

---

## 19. 截至当前代码的工具类型与支持清单（2026-05-21）

这一节补一份更实用的结论：**Hermes 现在到底有多少类工具、支持哪些工具名。**

### 19.1 统计口径要分开看

Hermes 里的“工具数量”至少有三种口径：

1. **toolset 数量**
   - `toolsets.py` 当前有 **56 个命名 toolset**
   - 其中很多是平台/场景打包，例如 `hermes-cli`、`hermes-telegram`、`hermes-discord`
   - 它们不是新的底层工具，而是对已有工具的组合暴露

2. **静态工具名数量**
   - 只看 `toolsets.py` 当前列出的唯一工具名，共 **71 个**
   - 这能反映“系统设计上准备支持哪些工具”

3. **运行时实际可见工具数量**
   - 真正发给模型的工具，取决于：
     - `enabled_toolsets` / `disabled_toolsets`
     - `check_fn`
     - 环境依赖是否安装
     - API key / provider 是否配置
     - 插件是否启用
     - MCP 是否连上并刷新进 registry
   - 所以**运行时数量通常不等于静态 71**

除此之外，还要补一个事实：

- 仓库里有些工具是 **plugin-only**
- 当前能明确点出的额外工具是 `google_meet` 插件注册的 5 个工具

因此，按“当前仓库里静态能点名的工具名”来算：

- `toolsets.py` 中：**71 个**
- 再加 `google_meet` 插件额外注册的 5 个：
  - `meet_join`
  - `meet_status`
  - `meet_transcript`
  - `meet_leave`
  - `meet_say`
- 合计可明确列举的静态工具名：**76 个**

> 注意：这个 76 **不包含** MCP 动态工具、memory provider 运行时注入工具，也不保证当前环境都可用。

### 19.2 如果按“能力类型”算，有多少类工具

如果把平台打包 toolset 去掉，只看真正的能力类型，当前可以粗分为 **16 大类**：

1. Web / Search
2. Vision / Media
3. Browser Automation
4. Terminal / Process / Code Execution
5. File
6. Planning / Agent Runtime
7. Skills
8. Scheduling
9. Messaging
10. Computer Use
11. Home Assistant
12. Kanban / Workflow
13. Discord
14. Feishu / Lark
15. Yuanbao
16. Spotify

如果把 `google_meet` 单独算成一个独立业务能力面，那就是 **17 类**。

### 19.3 当前支持的工具清单（按能力类型）

#### 1. Web / Search

- `web_search`
- `web_extract`
- `x_search`

#### 2. Vision / Media

- `vision_analyze`
- `video_analyze`
- `image_generate`
- `video_generate`

#### 3. Browser Automation

- `browser_navigate`
- `browser_snapshot`
- `browser_click`
- `browser_type`
- `browser_scroll`
- `browser_back`
- `browser_press`
- `browser_get_images`
- `browser_vision`
- `browser_console`
- `browser_cdp`
- `browser_dialog`

#### 4. Terminal / Process / Code Execution

- `terminal`
- `process`
- `execute_code`

#### 5. File

- `read_file`
- `write_file`
- `patch`
- `search_files`

#### 6. Planning / Agent Runtime

- `todo`
- `memory`
- `session_search`
- `clarify`
- `delegate_task`
- `mixture_of_agents`

#### 7. Skills

- `skills_list`
- `skill_view`
- `skill_manage`

#### 8. Scheduling

- `cronjob`

#### 9. Messaging

- `send_message`

#### 10. Computer Use

- `computer_use`

#### 11. Home Assistant

- `ha_list_entities`
- `ha_get_state`
- `ha_list_services`
- `ha_call_service`

#### 12. Kanban / Workflow

- `kanban_show`
- `kanban_list`
- `kanban_complete`
- `kanban_block`
- `kanban_heartbeat`
- `kanban_comment`
- `kanban_create`
- `kanban_link`
- `kanban_unblock`

#### 13. Discord

- `discord`
- `discord_admin`

#### 14. Feishu / Lark

- `feishu_doc_read`
- `feishu_drive_list_comments`
- `feishu_drive_list_comment_replies`
- `feishu_drive_reply_comment`
- `feishu_drive_add_comment`

#### 15. Yuanbao

- `yb_query_group_info`
- `yb_query_group_members`
- `yb_send_dm`
- `yb_search_sticker`
- `yb_send_sticker`

#### 16. Spotify

- `spotify_playback`
- `spotify_devices`
- `spotify_queue`
- `spotify_search`
- `spotify_playlists`
- `spotify_albums`
- `spotify_library`

#### 17. Google Meet（插件额外工具）

- `meet_join`
- `meet_status`
- `meet_transcript`
- `meet_leave`
- `meet_say`

### 19.4 默认核心工具面 vs 可选工具面

不是所有工具都默认暴露给每个入口。

`toolsets.py` 里的 `_HERMES_CORE_TOOLS` 当前包含的是 Hermes 默认核心工具面，主要包括：

- Web：`web_search`, `web_extract`
- Terminal / Process：`terminal`, `process`
- File：`read_file`, `write_file`, `patch`, `search_files`
- Vision / Image：`vision_analyze`, `image_generate`
- Skills：`skills_list`, `skill_view`, `skill_manage`
- Browser：`browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_scroll`, `browser_back`, `browser_press`, `browser_get_images`, `browser_vision`, `browser_console`, `browser_cdp`, `browser_dialog`
- Planning / Memory：`todo`, `memory`, `session_search`, `clarify`
- Execution / Delegation：`execute_code`, `delegate_task`
- Scheduling：`cronjob`
- Messaging：`send_message`
- Home Assistant：`ha_list_entities`, `ha_get_state`, `ha_list_services`, `ha_call_service`
- Kanban：`kanban_show`, `kanban_list`, `kanban_complete`, `kanban_block`, `kanban_heartbeat`, `kanban_comment`, `kanban_create`, `kanban_link`, `kanban_unblock`
- Computer Use：`computer_use`

而这些通常是**可选或按条件出现**的：

- `x_search`
- `video_analyze`
- `video_generate`
- `mixture_of_agents`
- `discord`, `discord_admin`
- `feishu_*`
- `yb_*`
- `spotify_*`
- `meet_*`

### 19.5 为什么“我看到的工具数”和文档数可能不一致

这是 Hermes 工具系统最容易让人困惑的地方。几个典型原因：

1. **依赖没装**
   - 例如 browser、web、vision、tts 等工具可能因为缺少 `requests`、`httpx`、`yaml`、`websockets` 等依赖而导入失败

2. **check_fn 拦掉了**
   - 工具注册了，但当前环境不可用，所以不会出现在最终 schema 里

3. **插件未启用**
   - 一些插件工具只有在插件启用后才会进入 registry

4. **MCP 动态刷新**
   - MCP server 工具不是静态写死在 `toolsets.py` 里的

5. **memory provider / plugin provider 运行时注入**
   - 这类工具会在 agent 初始化时追加到工具列表中

### 19.6 这一节的结论

如果你只是想快速把握当前 Hermes 的工具规模，可以记这几个数字：

- **56 个 toolset**
- **16~17 类能力工具**
- **71 个 `toolsets.py` 静态工具名**
- **76 个可明确点名的静态工具名（含 `google_meet` 插件工具）**

如果你想知道“当前某个进程里模型实际能看到哪些工具”，那就不能只看这篇文档，必须继续看：

1. `tools/registry.py`
2. `model_tools.py:get_tool_definitions()`
3. `toolsets.py`
4. 插件加载情况
5. 当前环境依赖与配置
