# 24. Hermes Agent 插件机制模块梳理与 Python 实现

## 1. 结论摘要

Hermes 不是只有一套统一插件框架，而是几条并行的扩展链路叠加在一起：

1. **通用 `PluginManager`**  
   负责扫描 `plugins/`、`~/.hermes/plugins/`、`./.hermes/plugins/` 和 pip entry points，支持注册工具、hook、CLI 子命令、会话内 slash command、平台适配器、技能，以及若干 backend。

2. **`memory` 专用插件发现器**  
   `plugins/memory/__init__.py` 单独负责 long-term memory provider，按 `memory.provider` 激活，且一次只允许一个外部 provider 生效。

3. **`model provider` 专用注册表**  
   `providers/__init__.py` 懒加载 `plugins/model-providers/<name>/`，通过 `register_provider(ProviderProfile(...))` 自注册，不走通用 `PluginManager`。

4. **若干 backend registry**  
   图片生成、视频生成、Web 搜索/提取/抓取、平台适配器，虽然很多是通过通用插件注册进来的，但最终消费时依赖各自的 registry/selector，而不是直接由 `PluginManager` 调度业务逻辑。

5. **`context engine` 是半独立机制**  
   `run_agent.py` 会先尝试 `plugins/context_engine/<name>/`，再回退到通用插件里通过 `register_context_engine()` 注册的 engine。当前仓库里只有这套发现器，没有实际内置的 `plugins/context_engine/<name>/` 引擎目录。

因此，“用了 plugin 机制的功能模块”不能只看 `plugins/` 目录，而要按**发现路径、注册方式、运行时消费点**三个维度来理解。

---

## 2. 哪些功能模块用了 plugin 机制

### 2.1 通用插件系统覆盖的功能面

通用插件系统的注册入口在 [hermes_cli/plugins.py](D:\dev\opensource\hermes-agent\hermes_cli\plugins.py)，`PluginContext` 暴露了这些扩展点：

| 扩展点 | 注册方法 | 运行时消费方 |
| --- | --- | --- |
| 工具 | `register_tool()` | `tools.registry` / `model_tools.py` / `run_agent.py` |
| CLI 子命令 | `register_cli_command()` | `hermes_cli/main.py` / `cli.py` |
| 会话内 slash command | `register_command()` | `cli.py` / `gateway/run.py` |
| 生命周期 hook | `register_hook()` | `model_tools.py`、`run_agent.py`、`gateway/run.py`、`cli.py` |
| 平台适配器 | `register_platform()` | `gateway/platform_registry.py` / `gateway/run.py` |
| 图片生成 backend | `register_image_gen_provider()` | `agent/image_gen_registry.py` / `tools/image_generation_tool.py` |
| 视频生成 backend | `register_video_gen_provider()` | `agent/video_gen_registry.py` / `tools/video_generation_tool.py` |
| Web 搜索 backend | `register_web_search_provider()` | `agent/web_search_registry.py` / `tools/web_tools.py` |
| Context engine | `register_context_engine()` | `run_agent.py` |
| 插件技能 | `register_skill()` | `tools/skills_tool.py` / `agent.skill_utils` |
| 会话消息注入 | `inject_message()` | 交互式 CLI 会话 |
| 插件内部用宿主 LLM | `ctx.llm` | `agent/plugin_llm.py` |

### 2.2 当前仓库内实际使用通用插件机制的模块类别

按 `plugins/` 目录看，当前仓库中的插件化功能主要分为这些类别：

| 类别 | 目录 | 说明 |
| --- | --- | --- |
| 独立功能插件 | `plugins/google_meet`、`plugins/disk-cleanup`、`plugins/teams_pipeline`、`plugins/observability/langfuse` | 通过工具、hook、CLI 等方式扩展 Hermes 本体能力 |
| Web backend | `plugins/web/*` | `web_search` / `web_extract` / `web_crawl` 的 provider |
| Image backend | `plugins/image_gen/*` | `image_generate` 的 provider |
| Video backend | `plugins/video_gen/*` | `video_generate` 的 provider |
| Gateway 平台插件 | `plugins/platforms/*` | 如 IRC、LINE、Google Chat、SimpleX、Teams |
| 工具型 backend 插件 | `plugins/spotify` | 以 backend 形式给现有工具面追加外部能力 |
| Dashboard/UI 伴生插件 | `plugins/example-dashboard`、`plugins/kanban/dashboard`、`plugins/hermes-achievements/dashboard` | 主要是前端/仪表盘资源，不是核心运行时调度面 |

### 2.3 独立发现器覆盖的功能模块

这些功能模块也用了插件机制，但不由通用 `PluginManager` 主导：

| 功能模块 | 目录/核心文件 | 说明 |
| --- | --- | --- |
| Memory providers | `plugins/memory/*` + `plugins/memory/__init__.py` | 单独发现、单独加载、单独激活 |
| Model providers | `plugins/model-providers/*` + `providers/__init__.py` | provider profile 懒加载注册 |
| Context engines | `plugins/context_engine/*` + `plugins/context_engine/__init__.py` | 目前仓库只保留机制，未见内置具体 engine |

### 2.4 从“产品能力”角度看，哪些模块已经插件化

如果按 Hermes 的功能模块而不是目录来归类，已经明显插件化的有：

1. **模型提供方层**：OpenRouter、Anthropic、Gemini、xAI、Bedrock、OpenAI Codex 等都以 model-provider plugin 形式存在。  
2. **长期记忆层**：Honcho、Mem0、Supermemory、Hindsight、OpenViking、RetainDB、Holographic、ByteRover。  
3. **上下文管理层**：预留 context engine plugin 面，允许运行时替换内置 `ContextCompressor`。  
4. **Web 检索层**：Tavily、Firecrawl、Parallel、Exa、SearXNG、Brave、DDGS。  
5. **图片生成层**：OpenAI、OpenAI Codex、xAI 等 provider。  
6. **视频生成层**：FAL、xAI provider。  
7. **Gateway 平台层**：IRC、LINE、Google Chat、SimpleX、Teams 等消息平台适配器。  
8. **宿主工具/命令层**：Google Meet、Spotify、disk cleanup、Langfuse observability、Teams pipeline。  
9. **技能层**：插件可附带只读 `SKILL.md`，通过 `plugin_name:skill_name` 命名空间暴露。

---

## 3. Python 层面的实现总图

可以把插件运行时抽象为四段：

1. **发现**：扫描目录 / pip entry points / 读取 `plugin.yaml`  
2. **加载**：导入 `__init__.py` 或专用 provider 模块  
3. **注册**：调用 `register(ctx)` 或 `register_provider(profile)`，把能力登记到 registry  
4. **消费**：`run_agent.py`、`model_tools.py`、`gateway/run.py`、具体工具模块按配置取 active provider 并执行

区别在于，不同类别的插件，这四段所在的文件不同。

---

## 4. 通用 `PluginManager` 机制

### 4.1 发现来源与优先级

[hermes_cli/plugins.py](D:\dev\opensource\hermes-agent\hermes_cli\plugins.py) 的 `PluginManager.discover_and_load()` 会扫描四个来源：

1. 仓库内 `plugins/`
2. 用户目录 `~/.hermes/plugins/`
3. 项目目录 `./.hermes/plugins/`  
   需要 `HERMES_ENABLE_PROJECT_PLUGINS=1`
4. pip entry points：`hermes_agent.plugins`

优先级是**后者覆盖前者**。实现上先收集所有 manifest，再以 `manifest.key or manifest.name` 做 winner 覆盖。

### 4.2 manifest 与 kind

`plugin.yaml` 由 `PluginManifest` 表示，核心字段有：

- `name`
- `version`
- `description`
- `kind`
- `requires_env`
- `provides_tools`
- `provides_hooks`
- `source`
- `path`
- `key`

`kind` 的有效值包括：

- `standalone`
- `backend`
- `exclusive`
- `platform`
- `model-provider`

其中最关键的装配语义是：

- `backend`：仓库内 bundled backend 自动加载
- `platform`：仓库内 bundled 平台插件自动加载
- `standalone`：默认不自动加载，依赖 `plugins.enabled`
- `exclusive`：交给专用发现器，通用加载器只记录 manifest，不 import
- `model-provider`：交给 `providers/__init__.py` 懒发现

### 4.3 自动识别的启发式

`PluginManager._parse_manifest_file()` 还有两个重要启发式：

1. 如果插件没写 `kind`，但 `__init__.py` 里出现 `register_memory_provider` 或 `MemoryProvider`，会被自动视为 `exclusive`。
2. 如果没写 `kind`，但 `__init__.py` 里出现 `register_provider` 和 `ProviderProfile`，会被自动视为 `model-provider`。

这解释了为什么 `plugins/memory/*` 的 `plugin.yaml` 大多没有显式 `kind`，但系统仍然能把它们分流到独立发现器。

### 4.4 加载方式

对目录型插件，`_load_plugin()` 会：

1. 构造 `PluginContext`
2. import 插件目录下的 `__init__.py`
3. 调用 `register(ctx)`
4. 记录该插件注册过的 tools / hooks / commands

通用插件的真实入口约定是：

```python
def register(ctx) -> None:
    ...
```

例如：

- [plugins/google_meet/__init__.py](D:\dev\opensource\hermes-agent\plugins\google_meet\__init__.py)
- [plugins/web/tavily/__init__.py](D:\dev\opensource\hermes-agent\plugins\web\tavily\__init__.py)
- [plugins/image_gen/openai/__init__.py](D:\dev\opensource\hermes-agent\plugins\image_gen\openai\__init__.py)

### 4.5 启用策略

并不是所有插件都自动加载：

- **自动加载**：bundled `backend`、bundled `platform`
- **按 `plugins.enabled` 启用**：`standalone`、用户自装 backend、entry-point plugin
- **永不通过通用路径激活**：`exclusive`（memory）、`model-provider`

这意味着 Hermes 里“插件已存在”与“插件在当前进程已启用”是两回事。

---

## 5. `PluginContext` 提供了哪些 Python 扩展接口

`PluginContext` 是通用插件真正的宿主 API。它不是抽象协议文档，而是运行时注入给 `register(ctx)` 的具体对象。

### 5.1 注册工具

`ctx.register_tool(...)` 最终调用 `tools.registry.register(...)`。  
因此插件工具和内置工具在模型看来是同一层工具面，只是来源不同。

关键后果：

- `model_tools.get_tool_definitions()` 能看到插件工具
- `run_agent.py` 初始化工具列表时能把插件工具一起塞给模型
- 可以通过 `override=True` 覆盖同名内置工具

### 5.2 注册 hook

`ctx.register_hook(hook_name, callback)` 将回调挂到 `_hooks` 字典。  
`VALID_HOOKS` 里已经定义了 Hermes 核心支持的 hook 名称，包括：

- `pre_tool_call`
- `post_tool_call`
- `transform_terminal_output`
- `transform_tool_result`
- `transform_llm_output`
- `pre_llm_call`
- `post_llm_call`
- `pre_api_request`
- `post_api_request`
- `on_session_start`
- `on_session_end`
- `on_session_finalize`
- `on_session_reset`
- `subagent_stop`
- `pre_gateway_dispatch`
- `pre_approval_request`
- `post_approval_response`

这些 hook 最终由 `invoke_hook()` 顺序执行，单个插件异常会被吞掉并记录 warning，不允许破坏主流程。

### 5.3 注册 CLI / slash command

- `register_cli_command()` 对应 `hermes <plugin> ...`
- `register_command()` 对应会话中的 `/xxx`

消费点：

- `cli.py` 会检查 plugin commands 并在 CLI 会话内派发
- `gateway/run.py` 会对消息平台里的 slash command 做相同检查

### 5.4 注册 backend/provider

这类方法不是直接执行业务，而是把 provider 放进专用 registry：

- `register_image_gen_provider()` -> `agent.image_gen_registry.register_provider()`
- `register_video_gen_provider()` -> `agent.video_gen_registry.register_provider()`
- `register_web_search_provider()` -> `agent.web_search_registry.register_provider()`
- `register_platform()` -> `gateway.platform_registry.register()`

所以 `PluginManager` 只负责“装配”，真正路由和执行发生在各自工具模块里。

### 5.5 注册技能

`register_skill()` 会把 `SKILL.md` 记录到 `_plugin_skills`。  
这类 skill：

- 通过 `plugin_name:skill_name` 访问
- 不会被复制进 `~/.hermes/skills/`
- 不会自动进入系统 prompt 的技能索引

本质上是**显式命名空间技能**，不是默认曝光技能。

---

## 6. 通用插件 hook 在运行时的落点

### 6.1 工具调用阶段

[model_tools.py](D:\dev\opensource\hermes-agent\model_tools.py) 会在工具调用链上接入插件 hook：

- 工具发现前触发 `discover_plugins()`
- 工具执行前检查 `pre_tool_call`
- 工具执行后触发 `post_tool_call`
- 工具结果规范化阶段触发 `transform_tool_result`

因此像安全拦截、审计、结果二次加工，都能通过插件实现。

### 6.2 Agent 对话阶段

[run_agent.py](D:\dev\opensource\hermes-agent\run_agent.py) 是 hook 的第二个核心消费点，覆盖：

- `pre_llm_call`
- `post_llm_call`
- `pre_api_request`
- `post_api_request`
- `transform_llm_output`
- `on_session_start`
- `on_session_end`
- `on_session_finalize`
- `on_session_reset`
- `subagent_stop`

一个重要设计是：`pre_llm_call` 返回的上下文会被注入到**用户消息**而不是 system prompt，以避免破坏 prompt cache 前缀。

### 6.3 Gateway 消息入口

[gateway/run.py](D:\dev\opensource\hermes-agent\gateway\run.py) 在启动时主动调用 `discover_plugins()`，随后会消费：

- `pre_gateway_dispatch`
- 会话边界 hook
- plugin-registered slash commands
- plugin platform adapters

因此插件既能改消息入口行为，也能把全新的消息平台接入 Hermes gateway。

---

## 7. Memory provider 插件机制

### 7.1 为什么 memory 是独立机制

Memory provider 不通过通用 `PluginContext` 注册。原因很直接：

1. 一次只允许一个外部 provider 激活
2. 需要跟 `MemoryManager` 的生命周期深度耦合
3. 需要在 agent 初始化阶段显式选型，而不是“扫描到就装进去”

### 7.2 发现与加载

[plugins/memory/__init__.py](D:\dev\opensource\hermes-agent\plugins\memory\__init__.py) 提供：

- `discover_memory_providers()`
- `load_memory_provider(name)`
- `discover_plugin_cli_commands()`

发现来源：

1. 仓库内 `plugins/memory/<name>/`
2. 用户目录 `~/.hermes/plugins/<name>/`

注意这里的用户路径是**平铺在 `~/.hermes/plugins/` 下**，不是 `~/.hermes/plugins/memory/`。  
它通过 `_is_memory_provider_dir()` 读取 `__init__.py` 文本，靠 `MemoryProvider` / `register_memory_provider` 关键字做启发式识别。

### 7.3 注册方式

memory plugin 支持两种写法：

1. `register(ctx)` 里调用 `ctx.register_memory_provider(...)`
2. 模块中直接定义 `MemoryProvider` 子类，加载器自己反射实例化

加载器内部会构造 `_ProviderCollector` 假上下文，只截获 `register_memory_provider()`。

这里有一个细节：通用 `PluginContext` 本身**没有**公开的 `register_memory_provider()` 方法，所以 memory 必须走独立发现器，不能复用通用 `PluginManager`。

### 7.4 运行时如何接入 agent

[run_agent.py](D:\dev\opensource\hermes-agent\run_agent.py) 初始化 `AIAgent` 时：

1. 读取 `memory.provider`
2. `load_memory_provider(name)`
3. 创建 `MemoryManager`
4. `add_provider(provider)`
5. `initialize_all(...)`
6. 把 memory provider 暴露的 tool schemas 注入到 agent 的工具列表

因此 memory plugin 不是“旁路能力”，而是 agent 初始化的一部分。

---

## 8. Model provider 插件机制

### 8.1 为什么 model provider 也是独立机制

模型提供方是 Hermes 最底层的推理后端配置，不适合跟普通工具插件放在一起加载。  
它们的对象模型是 `ProviderProfile`，而不是某个工具 handler。

### 8.2 发现与注册

[providers/__init__.py](D:\dev\opensource\hermes-agent\providers\__init__.py) 负责：

- `_discover_providers()`
- `register_provider(profile)`
- `get_provider_profile(name)`
- `list_providers()`

发现来源：

1. `plugins/model-providers/<name>/`
2. `$HERMES_HOME/plugins/model-providers/<name>/`
3. 旧式 `providers/<name>.py`

每个 provider 插件在 import 时执行：

```python
from providers import register_provider
register_provider(profile)
```

例如 [plugins/model-providers/openrouter/__init__.py](D:\dev\opensource\hermes-agent\plugins\model-providers\openrouter\__init__.py)。

### 8.3 运行时消费方

消费方主要包括：

- `run_agent.py`
- `hermes_cli/models.py`
- `hermes_cli/main.py`
- 若干 provider 解析/切换逻辑

也就是说 model-provider plugin 最终影响的是：

- 模型列表
- 认证方式
- base URL / headers / extra body
- reasoning 配置
- provider-specific 特性

### 8.4 与通用插件系统的关系

通用 `PluginManager` 会把 `kind == model-provider` 的 manifest 记录下来用于展示，但**不会 import 模块**。  
否则同一个 provider 会被 import 两次，生成两份 `ProviderProfile` 实例，破坏覆盖关系。

---

## 9. Context engine 插件机制

### 9.1 选择逻辑

[run_agent.py](D:\dev\opensource\hermes-agent\run_agent.py) 中 context engine 的选择顺序是：

1. 读取 `context.engine`
2. 如果不是 `compressor`，先尝试 `plugins.context_engine.load_context_engine(name)`
3. 再尝试 `hermes_cli.plugins.get_plugin_context_engine()`
4. 都失败则回退到内置 `ContextCompressor`

### 9.2 独立发现器

[plugins/context_engine/__init__.py](D:\dev\opensource\hermes-agent\plugins\context_engine\__init__.py) 的工作方式与 memory 很像：

- 扫描 `plugins/context_engine/<name>/`
- 允许 `register(ctx)` 或直接定义 `ContextEngine` 子类
- 用 `_EngineCollector` 捕获 `register_context_engine()`

### 9.3 当前仓库状态

当前仓库里 `plugins/context_engine/` 下只有加载器本身，没有内置具体引擎目录。  
所以这条链路目前更像是**机制预留**，而不是已经大量落地的插件类别。

### 9.4 运行时接入点

一旦选中插件 context engine：

- `run_agent.py` 用它替换 `self.context_compressor`
- 调用 `update_model(...)`
- 把 `get_tool_schemas()` 返回的工具注入到 agent 工具列表
- 在会话开始/结束时触发 `on_session_start()` / `on_session_end()`

这说明 context engine 可以同时扩展：

1. 上下文压缩策略
2. 会话级状态管理
3. 专属工具面

---

## 10. Image / Video / Web backend 插件机制

这三类插件的结构非常相似。

### 10.1 共同模式

1. 插件通过通用 `register(ctx)` 被加载
2. 在 `register()` 里调用 `ctx.register_*_provider(...)`
3. provider 进入专用 registry
4. 工具模块按配置选择 active provider 并调用

### 10.2 Image generation

核心链路：

- ABC: [agent/image_gen_provider.py](D:\dev\opensource\hermes-agent\agent\image_gen_provider.py)
- Registry: [agent/image_gen_registry.py](D:\dev\opensource\hermes-agent\agent\image_gen_registry.py)
- Tool wrapper: [tools/image_generation_tool.py](D:\dev\opensource\hermes-agent\tools\image_generation_tool.py)

要点：

- `image_gen.provider` 决定 active plugin provider
- tool wrapper 会先检查是否显式配置了 plugin provider
- 没配置时，仍保留老的 in-tree FAL 路径

所以 image generation 目前是**插件 provider + 历史内置实现并存**。

### 10.3 Video generation

核心链路：

- ABC: [agent/video_gen_provider.py](D:\dev\opensource\hermes-agent\agent\video_gen_provider.py)
- Registry: [agent/video_gen_registry.py](D:\dev\opensource\hermes-agent\agent\video_gen_registry.py)
- Tool wrapper: [tools/video_generation_tool.py](D:\dev\opensource\hermes-agent\tools\video_generation_tool.py)

要点：

- `video_gen.provider` 选 provider
- registry 只做 provider map，不做业务逻辑
- wrapper 决定错误提示、fallback、参数兼容

### 10.4 Web search / extract / crawl

核心链路：

- ABC: `agent/web_search_provider.py`
- Registry: [agent/web_search_registry.py](D:\dev\opensource\hermes-agent\agent\web_search_registry.py)
- Tool wrapper: [tools/web_tools.py](D:\dev\opensource\hermes-agent\tools\web_tools.py)

要点：

- `web.search_backend` / `web.extract_backend` / `web.crawl_backend` / `web.backend` 控制路由
- registry 区分 capability：`supports_search()` / `supports_extract()` / `supports_crawl()`
- wrapper 会根据 capability 和 availability 决定 fallback

这是 Hermes 里插件 backend 路由实现得最成熟的一块。

---

## 11. Gateway 平台插件机制

### 11.1 注册接口

平台插件通过 `ctx.register_platform(...)` 把 `PlatformEntry` 注册进 [gateway/platform_registry.py](D:\dev\opensource\hermes-agent\gateway\platform_registry.py)。

`PlatformEntry` 描述的内容很多，除了工厂函数，还有：

- `validate_config`
- `is_connected`
- `required_env`
- `setup_fn`
- `allowed_users_env`
- `allow_all_env`
- `emoji`
- `platform_hint`
- `env_enablement_fn`
- `apply_yaml_config_fn`
- `standalone_sender_fn`

这说明平台插件不只是“多一个 adapter 类”，而是把 gateway 配置、鉴权、cron 发送、展示元数据也一起插件化了。

### 11.2 运行时消费

[gateway/run.py](D:\dev\opensource\hermes-agent\gateway\run.py) 会：

1. 启动时 `discover_plugins()`
2. 从 `platform_registry` 收集 plugin entries
3. 读取平台级 allowlist env 变量
4. 创建 adapter 时先查 `platform_registry`
5. 创建失败时再回退到 legacy 内置平台逻辑

因此平台插件真正替代的是原来 gateway 里硬编码的分支判断。

---

## 12. 当前仓库内的插件类别现状

结合 `plugins/` 目录，当前仓库大致可分为：

### 12.1 已大量落地的插件类别

- `model-providers/*`
- `memory/*`
- `web/*`
- `image_gen/*`
- `video_gen/*`
- `platforms/*`

这些已经不只是“支持插件”，而是核心产品能力本身就依赖插件化目录组织。

### 12.2 有实际业务功能的独立插件

- `google_meet`
- `disk-cleanup`
- `teams_pipeline`
- `observability/langfuse`
- `spotify`

这些更接近“在 Hermes 主体上外挂业务能力”。

### 12.3 机制在，但当前仓库内落地较少

- `context_engine`

这是最典型的“框架已留好口，但当前树内还没有 bundled engine 实现”的类别。

---

## 13. 关键设计特点与注意事项

### 13.1 Hermes 的插件机制是“多中心”的

不要把 `hermes_cli/plugins.py` 理解成唯一真相。  
它负责的是**通用扩展点**，但 memory、model provider、context engine 都有自己的 loader。

### 13.2 “注册”与“激活”是两层概念

例如：

- backend 可能已经被自动加载进 registry
- 但实际生效还要看 `image_gen.provider` / `video_gen.provider` / `web.*_backend`
- memory provider 还要看 `memory.provider`
- context engine 还要看 `context.engine`

### 13.3 通用插件不直接执行业务

除工具/hook 以外，很多插件只是“把 provider 注册到 registry”。  
真正的业务逻辑在 tool wrapper 和 runtime selector 里。

### 13.4 当前体系允许 override / monkey-patch

- 用户插件可以覆盖 bundled 插件
- platform registry 支持同名重注册
- provider registry 也是 last-writer-wins

这给扩展带来灵活性，但也意味着调试时必须同时看：

1. 发现顺序
2. manifest key
3. 当前配置
4. 最终 registry 里留下的是谁

---

## 14. 建议的阅读顺序

如果后续要继续深入 Hermes 的插件架构，建议按这个顺序看代码：

1. [hermes_cli/plugins.py](D:\dev\opensource\hermes-agent\hermes_cli\plugins.py)  
   先理解通用 `PluginManager` 和 `PluginContext`
2. [providers/__init__.py](D:\dev\opensource\hermes-agent\providers\__init__.py)  
   看 model-provider 的懒发现
3. [plugins/memory/__init__.py](D:\dev\opensource\hermes-agent\plugins\memory\__init__.py)  
   看 memory provider 的独立装配
4. [plugins/context_engine/__init__.py](D:\dev\opensource\hermes-agent\plugins\context_engine\__init__.py)  
   看 context engine 的独立装配
5. [run_agent.py](D:\dev\opensource\hermes-agent\run_agent.py)  
   看 memory/context engine 如何进入 agent 初始化和会话生命周期
6. [agent/image_gen_registry.py](D:\dev\opensource\hermes-agent\agent\image_gen_registry.py)、[agent/video_gen_registry.py](D:\dev\opensource\hermes-agent\agent\video_gen_registry.py)、[agent/web_search_registry.py](D:\dev\opensource\hermes-agent\agent\web_search_registry.py)  
   看 backend registry 的选择逻辑
7. [tools/image_generation_tool.py](D:\dev\opensource\hermes-agent\tools\image_generation_tool.py)、[tools/video_generation_tool.py](D:\dev\opensource\hermes-agent\tools\video_generation_tool.py)、[tools/web_tools.py](D:\dev\opensource\hermes-agent\tools\web_tools.py)  
   看最终业务路由
8. [gateway/platform_registry.py](D:\dev\opensource\hermes-agent\gateway\platform_registry.py) 和 [gateway/run.py](D:\dev\opensource\hermes-agent\gateway\run.py)  
   看平台插件如何接入 gateway

---

## 15. 一句话总结

Hermes 的插件机制本质上是一个**分层扩展体系**：

- 顶层用 `PluginManager` 管普通插件能力
- 中层用若干 registry 管 backend/provider
- 底层用独立 loader 处理 memory、model provider、context engine 这类与核心运行时强耦合的扩展点

所以要调研某个“插件模块”，必须同时回答三个问题：

1. 它由谁发现？
2. 它注册到哪里？
3. 最终由谁消费？

只看 `plugins/` 目录结构本身，不足以理解 Hermes 的插件架构。
