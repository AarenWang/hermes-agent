# Hermes Agent 调研 12：Provider Runtime 与多模型兼容

## 1. 这篇文档关注什么

前面的几篇已经分别讨论了：

- Agent 主循环如何运转
- 工具运行时如何接到真实后端
- 安全、治理、能力后端如何组织

但如果只停在这些层面，仍然会低估 Hermes 里另一块非常“厚”的系统：

- Provider Runtime
- 多模型协议兼容层
- 辅助模型路由
- fallback provider / model 链

表面上看，这像是在做“多接几家模型服务商”。
但从代码结构看，Hermes 真正解决的问题不是：

- “如何把很多 provider 名字挂到配置里”

而是：

- “如何把不同协议、不同认证方式、不同推理字段、不同工具调用语义的模型接口，稳定压进同一个 Agent 主循环”

这篇文档重点回答七个问题：

1. Hermes 为什么把 provider 支持做成一个单独 runtime，而不是散落在 CLI / Agent / Gateway 里
2. `ProviderProfile`、runtime resolver、adapter、主循环各自负责什么
3. `chat_completions`、`codex_responses`、`anthropic_messages`、`bedrock_converse` 这些 API 形状差在哪
4. 为什么 `Responses API` 和 `Anthropic Messages` 都需要专门适配层
5. auxiliary model routing 和主聊天模型路由是什么关系
6. fallback chain 在系统设计上说明了什么
7. Hermes 这套多模型兼容架构最值得学习的点和代价分别是什么

---

## 2. 关键文件

核心入口：

- `website/docs/developer-guide/provider-runtime.md`
- `hermes_cli/runtime_provider.py`
- `hermes_cli/auth.py`
- `hermes_cli/model_switch.py`
- `hermes_cli/providers.py`
- `run_agent.py`

协议适配层：

- `agent/codex_responses_adapter.py`
- `agent/anthropic_adapter.py`
- `agent/auxiliary_client.py`

Provider 注册面：

- `providers/`
- `plugins/model-providers/`

---

## 3. Hermes 的核心判断：多模型问题本质上是协议兼容问题，不是供应商枚举问题

如果只从 README 或配置项看，Hermes 像是在支持很多 provider：

- OpenRouter
- Anthropic
- OpenAI Codex
- Gemini
- Bedrock
- Azure Foundry
- xAI
- MiniMax
- DeepSeek
- 各类 custom / gateway / OAuth provider

但真正关键的不是“数量多”，而是这些 provider 背后并不共享同一种语义接口。

Hermes 至少同时面对四类差异：

1. 认证差异  
   有的走普通 API key，有的走 OAuth，有的要 refreshable credential，有的还要优先选本地 credential store。

2. 传输协议差异  
   有的是 OpenAI 风格 `chat_completions`，有的是 `Responses API`，有的是 `Anthropic Messages`，有的是 `Bedrock Converse`。

3. 消息语义差异  
   有的接受单一 `content` 字符串，有的接受 block 列表，有的把 reasoning 放在 `reasoning`，有的放在 `reasoning_content`，有的要求 replay 时必须原样回传 thinking 块。

4. 工具调用差异  
   不同协议对 tool schema、tool call id、assistant/tool 消息回放顺序、流式 delta 结构都不一致。

所以 Hermes 的 provider 运行时并不是一个“配置中心”，而更像一个：

- 认证解析器
- 传输协议选择器
- 语义兼容层分发器
- 故障切换入口

这也是为什么相关逻辑既不只在 CLI，也不只在 `run_agent.py`，而是被拆成独立 runtime。

---

## 4. 它实际上分成了四层：Profile、Resolver、Adapter、Agent Loop

从代码结构看，Hermes 对 provider 做了明显分层。

### 4.1 ProviderProfile 层：声明 provider“是什么”

`plugins/model-providers/<name>/` 里的插件主要声明 provider 的静态画像，例如：

- `provider` 名称
- 默认 `base_url`
- `api_mode`
- 认证方式
- 环境变量优先级
- fallback models

这一层解决的是：

- “这个 provider 理论上该怎么连”

它不直接处理当前会话到底要用哪个 key、哪个 URL、哪个模型。

### 4.2 Runtime Resolver 层：决定这次运行“实际怎么连”

`hermes_cli/runtime_provider.py` 负责把多种来源合成一次真实运行时决议。

文档里明确给了一个优先级：

1. 显式运行时请求
2. `config.yaml`
3. 环境变量
4. provider 默认值或自动推断

这层输出的不是抽象概念，而是一份可运行参数：

- `provider`
- `api_mode`
- `base_url`
- `api_key`
- `source`

这一步非常关键，因为 Hermes 要让下面这些入口共享一套结果：

- CLI
- gateway
- cron
- ACP
- auxiliary model calls

如果没有这个共享 resolver，同一份配置在不同入口下很容易解析成不同行为。

### 4.3 Adapter 层：把非 OpenAI 协议压成主循环能理解的结构

`agent/codex_responses_adapter.py` 和 `agent/anthropic_adapter.py` 都属于这一层。

它们解决的问题不是“帮忙发请求”，而是：

- 消息如何变形
- reasoning 如何保留
- tool calls 如何回放
- multimodal 内容如何转换
- 哪些 provider-specific 字段必须补写回去

### 4.4 Agent Loop 层：统一消费这些兼容结果

最终一切还是汇到 `run_agent.py`。

主循环只想维护一件事：

- 用户消息
- assistant 消息
- tool calls
- tool results
- reasoning / usage / retries / streaming

但为了让这条循环同时吃下多种协议，`run_agent.py` 里才会出现大量：

- `api_mode` 分支
- reasoning replay 逻辑
- fallback activation
- provider-specific retry / auth rebuild

这说明 Hermes 的主循环虽然统一，但并不是“天然统一”，而是被前面几层硬压平的。

---

## 5. `api_mode` 才是真正的协议分水岭

Hermes 在多个地方都把 `api_mode` 作为核心运行时维度。

当前能明显看到的主路径至少包括：

- `chat_completions`
- `codex_responses`
- `anthropic_messages`
- `bedrock_converse`
- 某些特化路径如 `codex_app_server`

这意味着 Hermes 的“provider”概念并不等价于“协议”。
同一个 provider 家族里，甚至可能因为 model 或 base URL 不同，落到不同 `api_mode`。

这点在 `runtime_provider.py` 和 `providers.py` 里非常明显：

- 有些 provider 是按 provider name 决定 `api_mode`
- 有些 provider 是按 `base_url` 推断 `api_mode`
- 有些 provider 需要按目标 model 再次推断 `api_mode`

这背后反映的是一个很现实的问题：

- 现代模型服务商越来越像“协议聚合器”
- 一个品牌名下面可能同时挂 OpenAI 风格接口、Anthropic 风格接口、Codex 风格接口

所以 Hermes 不能只问“你选了谁”，还必须继续问：

- “你选的这个 provider 在这次会话里到底说哪种协议”

---

## 6. `Responses API` 兼容层真正难的不是格式，而是回放语义

`agent/codex_responses_adapter.py` 很能说明 Hermes 的兼容难点。

如果只看表层，会以为 Responses API 适配只是：

- 字段名改一下
- content 结构改一下

但代码里真正厚的是下面几件事：

### 6.1 多种消息项需要被标准化

Responses API 不只是简单的 chat message 列表，它可能带着：

- text 输出项
- reasoning 项
- tool call 项
- replayed item
- 多模态 content item

Hermes 必须把这些东西折算成主循环可复用的统一消息形状。

### 6.2 tool-call replay 需要稳定 id 和稳定顺序

Agent 不是一次调用就结束，它会反复：

1. 模型输出 tool calls
2. Hermes 执行工具
3. 把结果喂回模型
4. 继续下一轮推理

这要求 Hermes 对 replay item 的处理足够稳定，否则：

- call id 变了
- assistant/tool 对应关系断了
- 某些 provider 认不出上轮 thinking / tool chain

那么多轮对话就会崩。

### 6.3 Responses API 会把“推理过程是状态的一部分”暴露得更明显

普通 `chat_completions` 路径下，很多 provider 仍然允许你把推理内容当成“可选附加信息”。

但在 `codex_responses` 路径下，Hermes 明显更重视：

- structured reasoning item
- 中间状态回放
- 对前序 assistant 产物的精确复现

这说明 Responses API 兼容层处理的不是“消息格式转换”，而是：

- 一种更接近状态机的对话协议

---

## 7. `Anthropic Messages` 兼容层真正难的是 thinking 语义和兼容端点

`agent/anthropic_adapter.py` 体量非常大，这本身就说明它不是一个轻量 wrapper。

这里至少有三层复杂性。

### 7.1 Native Anthropic 并不是唯一目标

从代码和文档都能看出，`anthropic_messages` 这条路径不只服务 Anthropic 官方。
很多第三方 endpoint 也在复用或模拟这套协议。

这导致 Hermes 不能只兼容：

- “Anthropic 官方 SDK 能接受什么”

还得兼容：

- “Anthropic-compatible provider 实际上接受什么”

也就是说，这条 adapter 同时面对“规范”和“方言”。

### 7.2 thinking / reasoning replay 比 OpenAI 风格接口更严格

Anthropic 风格消息不是简单的 role + string。
它更强调 block 级结构，例如：

- text block
- thinking block
- tool_use
- tool_result

一旦 Hermes 在 replay 时丢掉了某些 thinking 信息，或者把 block 组合错了，后续轮次就可能失真。

从 `run_agent.py` 和 adapter 里的大量注释也能看出，Hermes 很在意：

- 哪些 `reasoning_content` 必须回传
- 哪些 thinking block 可以合成
- 哪些 replay 消息不能重复注入

这类逻辑说明 Hermes 已经从“调用一次 API”进入了“维护跨轮推理状态一致性”阶段。

### 7.3 认证与 endpoint 行为也被卷进来了

Anthropic 这条路径还有一个额外复杂点：

- 认证策略并不总是普通静态 key

文档里已经点明：

- 会优先考虑 refreshable Claude Code credentials
- 会在 401 后尝试重建 client 再试一次

这说明 provider 兼容在 Hermes 里不是纯协议问题，它直接牵涉：

- credential lifecycle
- client rebuild
- runtime retry policy

---

## 8. `reasoning_content` 是这套系统复杂度暴露得最明显的地方

如果要找一个最能代表 Hermes 多模型兼容难度的细节，`reasoning_content` 很可能就是那个点。

在 `run_agent.py` 里，相关逻辑密度非常高，原因很直接：

- 有的 provider 把推理内容放在 `reasoning`
- 有的放在 `reasoning_content`
- 有的要求 tool-call 消息也带上 reasoning replay
- 有的 provider 对空字符串和缺字段的行为还不一样

也就是说，推理内容在 Hermes 里不是“调试信息”，而是很多 provider 语义正确性的组成部分。

这件事非常重要，因为它改变了消息存储与回放的设计目标：

- 如果 reasoning 只是可选注释，存不存都行
- 如果 reasoning 是 replay 契约的一部分，那么消息归档、压缩、恢复、重试都会被它影响

Hermes 显然已经接受了后者。

---

## 9. Auxiliary Routing 说明 Hermes 把“模型调用”拆成了多条业务通道

`agent/auxiliary_client.py` 代表了另一个成熟信号：

- Hermes 不再把“模型”理解成单一主聊天模型

辅助任务例如：

- vision
- web extraction summarization
- context compression
- session search summarization
- skills hub / MCP helper 任务
- memory flush

都可能走和主聊天不同的 provider / model。

这很像基础设施系统里的“sidecar routing”：

- 主模型追求总体交互质量
- 辅助模型追求成本、速度、特化能力或供应稳定性

值得注意的是，auxiliary routing 并不是另起炉灶。
它仍然复用 shared runtime resolution，并支持：

- `main` 作为别名回指主模型
- provider alias 归一化
- 特定 provider 的参数清洗与特殊分支

所以 Hermes 这里做的不是“额外开几个模型配置项”，而是：

- 把模型路由提升成系统级能力

---

## 10. fallback chain 说明 Hermes 处理的是生产不稳定性，不只是开发体验

`fallback_model` / `fallback_providers` 相关逻辑非常值得单独注意。

它表达的不是：

- “用户可以手动切模型”

而是：

- “当当前 provider 在真实运行里失败时，系统能否自动恢复”

从主循环里的逻辑可以看出，fallback 会在多类失败点触发，例如：

- 非重试型 client error
- 多次无效响应
- 达到重试上限的瞬时错误

激活后会重新解析：

- provider
- model
- `api_mode`
- client
- auth / transport

然后把当前 Agent 实例原地切过去。

这说明 Hermes 默认假设的一件事是：

- 模型后端是不稳定的
- provider 不是抽象常量，而是会在运行中失效的外部依赖

这就是典型的生产系统思维，而不是 demo 型 agent 思维。

---

## 11. 这套架构最值得学习的点

### 11.1 把“接入 provider”从“写 if/else”升级成运行时体系

Hermes 并没有把 provider 兼容散落在：

- CLI 切模型逻辑
- Agent 初始化
- Gateway 启动

而是用 shared runtime resolver 把它们收敛到同一个决策面。

### 11.2 明确承认协议差异不可被完全抽象掉

Hermes 并没有执着于“所有 provider 都伪装成完全一样”。
相反，它保留了 `api_mode` 这一中间层，承认：

- 有些协议差异必须显式建模

这是很务实的做法。

### 11.3 把 reasoning / replay / tool-calling 当成一等问题

很多项目的多模型支持只停在“文本能回就行”。
Hermes 已经把注意力推进到：

- 多轮 tool-calling 是否稳定
- 推理字段是否可回放
- streaming / retry / compression 是否还能保持语义

这才是 agent 系统真正难的部分。

### 11.4 auxiliary routing 和 fallback 让它更像真实平台

一旦一个系统同时具备：

- 主模型路由
- 辅助模型路由
- 自动 fallback

它讨论的就不只是“选哪个模型更聪明”，而是：

- 成本
- 延迟
- 稳定性
- 特化任务分流

这说明 Hermes 的模型层已经有平台化倾向。

---

## 12. 代价与复杂性

这套设计很强，但代价也明显。

### 12.1 主循环不可避免地变厚

即使 adapter 已经拆出去，`run_agent.py` 里仍然要显式处理大量：

- `api_mode` 分支
- replay 修复
- provider-specific retry
- reasoning 字段桥接

因为最终状态一致性问题只能在主循环落锤。

### 12.2 “兼容端点”会不断侵蚀抽象边界

一旦系统支持很多 “Anthropic-compatible” 或 “OpenAI-compatible” endpoint，就会不断遇到：

- 名义上一样
- 实际上细节不一样

这会让 adapter 越来越像“协议方言收容所”。

### 12.3 测试负担很重

只要牵涉：

- 流式输出
- tool replay
- reasoning replay
- fallback activation
- auth refresh

兼容层就很难靠简单单测覆盖完全。

这也是为什么这一块如果继续深挖，后面很值得专门看：

- `tests/test_fallback_model.py`
- provider / adapter 相关测试

---

## 13. 建议阅读顺序

如果后续要继续调研这块，推荐阅读顺序是：

1. `website/docs/developer-guide/provider-runtime.md`  
   先建立整体心智模型。

2. `hermes_cli/runtime_provider.py`  
   看运行时解析到底从哪些来源做决策。

3. `plugins/model-providers/*/__init__.py`  
   看 provider profile 是如何声明的。

4. `agent/auxiliary_client.py`  
   看辅助模型路由如何复用主 runtime。

5. `agent/codex_responses_adapter.py`
6. `agent/anthropic_adapter.py`  
   这两步重点看协议兼容的真实工作量。

7. `run_agent.py`  
   最后回到主循环，看这些兼容层最终如何影响执行路径。

---

## 14. 本篇结论

Hermes 在 provider 这一层最有价值的地方，不是“支持的模型很多”，而是它已经明确把多模型系统当成一个：

- 运行时解析问题
- 协议兼容问题
- 推理状态回放问题
- 生产故障切换问题

这和很多 agent 项目只做“模型名切换器”完全不是一个层级。

如果说前几篇文档说明 Hermes 像一个：

- Agent runtime
- tool runtime
- capability backend orchestrator

那么这一篇说明的则是：

- 它同时也是一个多协议 LLM runtime

而且这个 runtime 的成熟度，主要体现在它如何处理那些最不体面的细节：

- `api_mode`
- `reasoning_content`
- tool replay
- auth refresh
- fallback activation

这些细节不 glamorous，但它们决定了一个 agent 系统在真实世界里能不能长时间跑稳。
