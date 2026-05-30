# Hermes Agent 调研 14：Observability、Usage、Cost 与 Rate Limit

## 1. 这篇文档关注什么

前面的几篇主要解释 Hermes 如何：

- 跑 agent
- 调工具
- 保存 trajectory
- 组织 provider runtime

但一个真正长期运行的 agent 系统，光“能跑”远远不够。
它还必须回答这些运营层问题：

- 这次会话到底烧了多少 token
- 钱大概花了多少
- 当前 provider 的限流离打满还有多远
- 当前账号套餐或 credits 还剩多少
- 这些运行信息能不能被外部 observability 系统接住

Hermes 在这块已经不是“顺手打印一下 token 数”。
从代码结构看，它已经把这块拆成了相对完整的一套观测与计量层。

这篇文档重点回答七个问题：

1. Hermes 为什么把 usage / cost / limit 当成运行时一等能力
2. session 级 token / cost 统计是怎么挂进主循环的
3. `usage_pricing.py` 真正在统一什么
4. `rate_limit_tracker.py` 和 `account_usage.py` 分别解决哪两类限制
5. `/usage` 命令背后暴露的是怎样的数据面
6. `observability/langfuse` 插件说明了怎样的可插拔观测思路
7. 这套设计最值得学习的点和代价分别是什么

---

## 2. 关键文件

核心文件：

- `run_agent.py`
- `agent/usage_pricing.py`
- `agent/rate_limit_tracker.py`
- `agent/account_usage.py`
- `plugins/observability/langfuse/__init__.py`
- `plugins/observability/langfuse/README.md`

直接消费这些信息的入口：

- `cli.py`
- `gateway/run.py`

---

## 3. Hermes 的一个核心判断：运营指标不是外围功能，而是 agent runtime 的一部分

很多项目对 usage / cost 的处理停留在：

- 调完 API 后打印一个 token count

Hermes 明显不是这个级别。
从 `run_agent.py` 初始化时就能看出，它把这些量直接挂在 session 生命周期里：

- `session_input_tokens`
- `session_output_tokens`
- `session_cache_read_tokens`
- `session_cache_write_tokens`
- `session_reasoning_tokens`
- `session_total_tokens`
- `session_estimated_cost_usd`
- `session_cost_status`
- `session_cost_source`
- `_rate_limit_state`

这说明 Hermes 把 usage / cost / rate-limit 视作：

- 每轮请求都要被更新的运行时状态

而不是：

- 事后查账的附带日志

这个判断很重要，因为一旦把它们当成运行时状态，后面很多能力才会自然出现：

- `/usage`
- gateway 里的 usage 回显
- rate-limit 预警
- session 级成本累计
- observability 插件对 usage/cost 的结构化上报

---

## 4. 会话级 usage 统计是主循环内建能力，不是 CLI 侧附加逻辑

`run_agent.py` 初始化时就为每个 session 建好了累计计数器，后续每次 API 调用都往上累加。

这件事的意义在于：

- 统计逻辑和实际调用逻辑在同一条执行链上

这样 CLI、gateway、dashboard 只需要读 agent 当前状态，而不需要各自重新推导。

### 4.1 统计粒度不只是 prompt/completion

Hermes 统计的桶明显比很多项目更细：

- input tokens
- output tokens
- cache read tokens
- cache write tokens
- reasoning tokens

这说明它已经承认一件现实：

- 现代 provider 的 token 账单不再只有“输入 / 输出”两栏

尤其在 prompt caching、thinking tokens、provider 自带 cache 读写折扣这些能力出现后，粗粒度统计已经不够用了。

### 4.2 cost status / source 是显式建模的

Hermes 不只保存一个美元数，还保存：

- `cost_status`
- `cost_source`

这意味着系统不仅关心“多少钱”，还关心：

- 这个钱是精确还是估算
- 估算依据来自哪

这是很成熟的做法，因为很多 provider 根本不给统一的实时账单接口。
如果不把“精度来源”显式建模，用户很容易把估算当真值。

---

## 5. `usage_pricing.py` 解决的不是加减乘除，而是“不同 provider 的计量语义统一”

如果只看名字，`usage_pricing.py` 像个简单工具模块。
但实际上它承担的是 Hermes 在计量层最关键的兼容工作。

这里至少有三件事情。

### 5.1 usage 归一化

`normalize_usage()` 会把不同 API 形状的 usage 字段统一成 `CanonicalUsage`：

- `input_tokens`
- `output_tokens`
- `cache_read_tokens`
- `cache_write_tokens`
- `reasoning_tokens`

而它兼容的 shape 至少包括：

- Anthropic 风格
- Codex Responses 风格
- OpenAI Chat Completions 风格

这一步很关键，因为不同 API 对 cache token 的记法并不一致：

- 有的把 cache token 混在 prompt/input total 里
- 有的在 details 结构里单列
- 有的甚至走 Anthropic 风格顶层字段

Hermes 把这些差异统一后，后面的 session 计数、CLI 展示、Langfuse 上报才能复用同一套逻辑。

### 5.2 billing route 解析

`resolve_billing_route()` 很能说明这块的成熟度。

它不是只问：

- provider 叫什么

还要问：

- 这条路由的 billing mode 是什么

当前能看到的模式至少有：

- `subscription_included`
- `official_models_api`
- `official_docs_snapshot`
- `unknown`

这说明 Hermes 已经承认：

- 同样一次调用，不同 provider 的“成本含义”不同

例如：

- `openai-codex` 可能属于订阅内含成本
- `openrouter` 更适合从 models API 取价
- 官方 Anthropic / OpenAI 路由可以走内置 docs snapshot
- 本地或 custom endpoint 可能根本无已知价格

所以 cost 计算前，先要解析“计费路径”。

### 5.3 pricing source 显式分层

`PricingEntry` 和 `CostSource` 里能看到 Hermes 区分了多类价格来源：

- `provider_models_api`
- `official_docs_snapshot`
- `provider_cost_api`
- `provider_generation_api`
- `user_override`
- `custom_contract`
- `none`

这非常重要，因为它避免了一个常见问题：

- 系统算出了价格
- 但没人知道这个价格来自哪里

Hermes 的做法更像一个小型计费解释器，而不是单一 hardcode 表。

---

## 6. 它甚至显式建模了“included cost”和“unknown cost”

`CostStatus` 里不只有：

- `actual`
- `estimated`

还有：

- `included`
- `unknown`

这两个状态非常关键。

### 6.1 `included`

有些路由不是按 token 付费，而是：

- 订阅内包含
- 或至少对终端用户表现为不单独计费

这类路由如果硬要显示一个 `$0.0000`，语义其实是模糊的。
Hermes 把它显式标成 `included`，比“看起来免费”更准确。

### 6.2 `unknown`

对 custom / local / 定价接口不可得的 endpoint，Hermes 也不会假装能算。
它会明确给出：

- `unknown`

这体现的是非常健康的系统边界感：

- 有些成本能估
- 有些不能
- 不能估时就承认不知道

---

## 7. `rate_limit_tracker.py` 处理的是“本次 API 通道”的瞬时容量

`rate_limit_tracker.py` 的职责非常清晰：

- 解析响应头里的 `x-ratelimit-*`
- 把它转成结构化 `RateLimitState`
- 再渲染成 CLI / gateway 能展示的格式

这里最值得注意的是，它关注的是：

- 请求窗口
- token 窗口
- 分钟级
- 小时级

也就是“当前 API 通道还能不能继续打”的问题。

### 7.1 它不是纯 provider 特化代码，而是通用 bucket 模型

内部建模非常干净：

- `RateLimitBucket`
- `RateLimitState`

每个 bucket 都有：

- `limit`
- `remaining`
- `reset_seconds`
- `captured_at`

这意味着它把 rate-limit 看成一个标准化资源桶问题，而不是某家 provider 的字符串格式问题。

### 7.2 它还会考虑时间流逝后的“剩余 reset 时间”

`remaining_seconds_now` 不是静态值，而会根据 `captured_at` 动态扣减。

这让 `/usage` 读出来的状态不是“抓到头时的快照”，而是：

- 一个带时间衰减的近实时状态

这虽然是小细节，但体现了这块不是只为了 debug，而是为了用户实际决策。

---

## 8. `account_usage.py` 处理的是“账号层配额”，不是单次 API 速率

`rate_limit_tracker.py` 和 `account_usage.py` 很容易被混为一谈，但它们处理的是两种完全不同的限制。

### 8.1 rate limit

它回答的是：

- 这一分钟还能打多少请求
- 这一小时还能打多少 token

### 8.2 account usage

它回答的是：

- 当前套餐 / credits 还剩多少
- 本周 / 本 session / 本月还剩多少
- reset 时间是什么

这两者对应的是：

- API 通道限流
- 账号层额度与账单限制

Hermes 把它们分成两个模块，是很正确的设计。

### 8.3 `account_usage.py` 体现了 provider-specific account API 的现实差异

当前实现能明显看到至少覆盖了：

- `openai-codex`
- `anthropic`
- `openrouter`

但每家数据来源都不一样：

- Codex 走自己的 usage endpoint
- Anthropic OAuth 账号有单独 usage API
- OpenRouter 走 credits / key 相关接口

而且 Hermes 还会区分：

- 是否是 OAuth-backed account
- 是否有 account id
- 某些 provider 是否根本不支持 account-limit 查询

这再次说明它不是在做统一接口幻想，而是在认真处理 provider 现实差异。

---

## 9. `/usage` 背后暴露的是一个多层状态面板，而不是单一统计值

从 `cli.py::_show_usage()` 和 `gateway/run.py::_handle_usage_command()` 看，Hermes 暴露给用户的 `/usage` 实际上是多层信息的组合：

1. 当前 rate limits
2. 当前 session token breakdown
3. session API calls
4. session duration
5. estimated / included / unknown cost
6. account usage snapshot

这说明 `/usage` 在 Hermes 里并不是：

- “看本轮 token 数”

而更像：

- “看这个 session 当前的资源与成本状态”

### 9.1 CLI 更偏细节

CLI 版会展示更完整的细粒度字段，例如：

- input / output / cache read / cache write / reasoning
- prompt / completion / total
- context compressor 当前压力
- cost status / source

这适合本地重度使用者。

### 9.2 gateway 更偏摘要

gateway 版则会优先考虑消息平台输出长度和异步性：

- account usage 查询会放到线程里跑，避免阻塞事件循环
- 展示更紧凑
- 但仍然尽量保留 account + session 两层视图

这说明 Hermes 在观测能力上也考虑了多前端消费，而不是把 CLI 打印直接搬过去。

---

## 10. `observability/langfuse` 插件说明 Hermes 采用的是“内建状态 + 可插拔外送”

Hermes 在 observability 上的思路很清楚：

- 核心 runtime 内建 usage / cost / tool / message 状态
- 外部 tracing/analytics 通过插件接出

当前 repo 里 bundled 的 observability 插件是：

- `plugins/observability/langfuse`

### 10.1 它是显式 opt-in，而不是强绑定

README 和实现都很明确：

- 插件默认不启用
- 只有显式 enable 且装了 SDK、配好凭据才会工作

这说明 Hermes 不把外部观测平台当成核心依赖，而是：

- 一个可选出口

### 10.2 它采用 fail-open 策略

无论是 SDK 缺失、凭据没配、还是 client 初始化失败，插件都会：

- no-op
- 不阻断主 agent 流程

这对 observability 系统非常重要，因为观测系统不应该把主执行链拖死。

### 10.3 它 hook 的是 agent 生命周期，而不是简单包一层 HTTP client

从 `register(ctx)` 看，这个插件挂接的 hook 包括：

- `post_api_request`
- `pre_llm_call`
- `post_llm_call`
- `pre_tool_call`
- `post_tool_call`

这意味着它观测的不是“HTTP 请求”这么低的一层，而是：

- 一次 Hermes turn
- 一次 LLM generation
- 一次 tool invocation

这让 Langfuse 看到的是 agent 语义，而不是裸 API 事件。

---

## 11. Langfuse 插件最有意思的地方：它在“可观测性”和“敏感载荷控制”之间做了平衡

这个插件并不是一股脑把所有 payload 全量上送。
相反，它做了很多很现实的裁剪和归一化。

### 11.1 大字段会被截断

插件里有：

- `HERMES_LANGFUSE_MAX_CHARS`
- `_truncate_text()`
- `_safe_value()`

说明它很清楚 tracing 不是归档系统，不能无限塞上下文。

### 11.2 特定 payload 会被结构化归一化

例如 `read_file` 这类 payload，会被改写成：

- 返回了哪些行
- head / tail preview
- 是否 binary / image
- base64 content 是否被省略

这非常务实，因为原始文件内容或大 blob 直接塞进 trace，价值往往不高，噪声却很大。

### 11.3 usage / cost 会被转成 Langfuse 能消费的细分键

插件不会只上报一个“总 token 数”，而会按 Langfuse 的 usage/cost 约定映射：

- `input`
- `output`
- `cache_read_input_tokens`
- `cache_creation_input_tokens`
- `reasoning_tokens`

并尝试给出对应 cost breakdown。

这说明 Hermes 并不是“把 usage 打到 trace metadata 里”，而是尽量适配 observability 平台自己的语义模型。

---

## 12. 这套设计最值得学习的点

### 12.1 把成本、限流、额度拆成不同层级

Hermes 明确区分了：

- request/session usage
- API rate limit
- account quota / credits
- external observability trace

这比把它们全塞进一个 `/usage` 函数里清晰得多。

### 12.2 “不确定性”被显式表达出来

`estimated`、`included`、`unknown`，以及 `cost_source` 的存在，让系统可以诚实地告诉用户：

- 这里不是精确账单
- 这里只是估算
- 这里完全未知

这比假装精确更可信。

### 12.3 运行时状态和外部观测解耦

核心 agent 不依赖 Langfuse 才能工作，但 Langfuse 又能拿到结构化 usage/tool/turn 数据。

这是一种很健康的分层：

- 内部先把状态建好
- 外部插件按需消费

### 12.4 observability payload 经过裁剪和归一化

这说明 Hermes 在做的是“有用的 trace”，而不是“把所有东西都 dump 出去”。

---

## 13. 代价与复杂性

这套方案也有明显代价。

### 13.1 价格表和账单语义天然是时变的

`official_docs_snapshot` 这种机制虽然实用，但也意味着：

- repo 里内置的价格快照会过时

这就要求维护者持续更新，或者接受部分估算失真。

### 13.2 OpenAI-compatible / aggregator 路由会持续制造歧义

同一个模型可能：

- 通过官方 API 走
- 通过 OpenRouter 走
- 通过 custom endpoint 走

它们的 usage shape、cache 语义、账单来源都可能不同。
这会不断侵蚀统一抽象。

### 13.3 account usage 查询高度 provider-specific

`account_usage.py` 现在能支持几家主流 provider，但这类代码天然难做成真正通用层，因为：

- 不是每家都开放账号额度接口
- 有的还依赖 OAuth 身份
- 有的接口稳定性本身也不高

所以这块会一直带着 provider 分支色彩。

---

## 14. 建议阅读顺序

如果后续要继续深挖这一层，建议顺序是：

1. `run_agent.py`  
   先看 session counters、rate-limit capture、cost 累计怎么接到主循环。

2. `agent/usage_pricing.py`  
   这是最关键的计量兼容层。

3. `agent/rate_limit_tracker.py`  
   看 API 通道级限流如何被结构化。

4. `agent/account_usage.py`  
   再看账号层额度接口如何适配。

5. `cli.py` 与 `gateway/run.py`  
   看 `/usage` 如何消费这些状态。

6. `plugins/observability/langfuse/__init__.py`  
   最后看外部观测系统如何接住这些结构化信息。

---

## 15. 本篇结论

Hermes 在 observability 这一层最值得注意的，不是“有个 Langfuse 插件”，而是它已经把：

- token usage
- cache usage
- reasoning usage
- cost estimation
- rate-limit state
- account quota
- trace export

拆成了不同层次、不同精度、不同消费面的系统能力。

这说明 Hermes 对“agent 运行成本和可观测性”的理解，已经明显超出了 demo 工具阶段。

它真正成熟的地方在于两点：

- 一方面，愿意在 runtime 内部认真维护这些状态
- 另一方面，又愿意诚实承认这些状态有的只是估算、有的不可得、有的只能 provider-specific 地去抓

这比单纯做一个 `/usage` 命令要深得多，也更接近真实 agent 平台需要面对的运营现实。
