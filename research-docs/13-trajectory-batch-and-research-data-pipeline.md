# Hermes Agent 调研 13：Trajectory、Batch Runner 与研究数据流水线

## 1. 这篇文档关注什么

前面的文档基本都在解释 Hermes 如何“运行一个 agent”。
但如果只看到这里，仍然会漏掉这个仓库另一条非常重要的主线：

- Hermes 不只是一个运行时
- 它也在把自己的运行过程持续转成研究数据

这条线在代码里主要表现为三件事：

1. 单次对话如何被保存成 trajectory
2. 多条 prompt 如何被并行跑成一个可恢复、可统计、可合并的数据生产任务
3. 已生成的轨迹如何被采样、压缩、整理成更适合训练和发布的数据集

所以这篇文档关注的不是“怎么跑 batch”这么简单，而是：

- Hermes 如何把 agent execution 变成 dataset production pipeline

这篇文档重点回答八个问题：

1. trajectory 在 Hermes 里到底是什么格式
2. 为什么轨迹转换没有直接 dump 原始消息，而是做了显式重编码
3. batch runner 为什么不是普通并行脚本，而是带 checkpoint / resume / schema normalization 的生产器
4. reasoning coverage 为什么会被当成筛选指标
5. 为什么 batch 跑数时会主动跳过 memory 和 context files
6. trajectory compressor 解决的是什么问题
7. `sample_and_compress.py` 暗示了怎样的数据飞轮
8. 这套数据流水线最值得学习的设计点和代价分别是什么

---

## 2. 关键文件

核心文件：

- `run_agent.py`
- `agent/trajectory.py`
- `batch_runner.py`
- `trajectory_compressor.py`
- `scripts/sample_and_compress.py`

辅助但重要的文件：

- `toolset_distributions.py`
- `agent/auxiliary_client.py`
- `tests/test_trajectory_compressor.py`
- `tests/test_trajectory_compressor_async.py`

---

## 3. Hermes 的一个关键判断：轨迹不是日志副本，而是训练样本

很多系统保存对话时，做法是：

- 直接把 message list 序列化

Hermes 明显不是这个思路。
从 `run_agent.py::_convert_to_trajectory_format()` 和 `agent/trajectory.py` 看，它把 trajectory 当成一种专门面向训练或后处理的样本格式，而不是原始运行日志。

这个判断很关键，因为它会直接改变保存策略：

- 日志关心“忠实记录运行时状态”
- 训练样本关心“是否能稳定表达任务、推理、工具调用和结果”

Hermes 在这里明显偏向后者。

所以 trajectory 不是原始 `messages` 的一比一镜像，而是一次重编码。

---

## 4. trajectory 格式本质上是 ShareGPT 风格的 agentic sample

`agent/trajectory.py` 里把 trajectory 明确称作：

- `ShareGPT-format conversation list`

它最终产出的核心结构非常简单：

- `{"from": "system"|"human"|"gpt"|"tool", "value": ...}`

但 `value` 里面承载的语义并不简单。

### 4.1 system turn 不是原始 system prompt，而是“工具调用协议说明”

在 `_convert_to_trajectory_format()` 里，第一条 system 消息会被重写成一段稳定模板，里面包含：

- 工具定义
- `<tools>...</tools>`
- `<tool_call>...</tool_call>`
- `<tool_response>...</tool_response>`

这说明 Hermes 保存 trajectory 时，优先保证的是：

- 下游读取者能明确知道这是一个 function-calling 任务样本

而不是：

- 精确保留当次运行时所有 system prompt 拼装细节

### 4.2 user turn 会被显式拉成第一条 human 消息

轨迹里第一条 `human` 是原始 query。
这一步看似普通，其实是在固定样本起点：

- 每条 trajectory 都从“任务是什么”开始

这对训练数据很重要，因为后面的 tool / reasoning / answer 都围绕这个入口解释。

### 4.3 assistant turn 会被重写成包含 `<think>` 和 `<tool_call>` 的统一文本

Hermes 不直接保留 assistant 的内部结构，而是把它改写成统一文本协议：

- 有 reasoning 时，前置成 `<think>...</think>`
- 有工具调用时，包成 `<tool_call>...</tool_call>`

这说明 trajectory 存储的目标不是“保真重放 SDK 结构”，而是：

- 把推理和工具调用转成稳定、可训练、可压缩的中间表达

### 4.4 tool turn 会被合并成单条 `tool` 消息

连续 tool results 会被收拢成一个 `tool` turn，内部包多个 `<tool_response>`。

这和运行时消息结构并不完全相同，但对训练样本更紧凑，也更符合“模型一轮发起若干工具调用，然后收到一批结果”的抽象。

---

## 5. 这套重编码最关键的细节是：把 reasoning 明确变成样本的一部分

Hermes 在 trajectory 转换时做了一个很明确的决定：

- reasoning 不是旁路信息
- reasoning 是训练样本内容的一部分

这体现在几个细节上。

### 5.1 原生 reasoning 会被放进 `<think>`

如果 assistant 消息里有原生 `reasoning` 字段，就会被包成：

- `<think>...</think>`

这意味着 Hermes 默认希望下游样本保留思考过程，而不是只保留答案。

### 5.2 XML scratchpad 也会统一映射成 `<think>`

`agent/trajectory.py` 里有一个很直白的辅助函数：

- `convert_scratchpad_to_think()`

它会把：

- `<REASONING_SCRATCHPAD>...</REASONING_SCRATCHPAD>`

转换成：

- `<think>...</think>`

这说明 Hermes 不希望 reasoning 来源影响下游格式。
无论 reasoning 是原生 thinking token，还是普通文本里的 scratchpad，它最后都被统一到同一语义槽位。

### 5.3 即使没有 reasoning，也会补一个空 `<think>`

转换逻辑里甚至会强制：

- 每个 `gpt` turn 都带一个 `<think>` block

哪怕是空的。

这是很强的格式约束，说明 Hermes 在为训练和后处理换取结构一致性：

- 下游不需要猜这一轮有没有思考字段
- 每个 assistant turn 都能按同一模式解析

---

## 6. trajectory 保存时还主动做了“去运行时噪声”处理

Hermes 在存数据时，不只是加结构，也在减噪声。

### 6.1 多模态大 blob 会被清掉

`_trajectory_normalize_msg()` 会把图片型 tool results 转成 text summary，避免把 base64 blob 直接写进轨迹。

这说明 trajectory 的第一原则不是“全保留”，而是：

- 保留训练信号
- 去掉会污染样本体积和上下文预算的载荷

### 6.2 `ephemeral_system_prompt` 故意不写入 trajectory

`run_agent.py` 和 `batch_runner.py` 都反复强调：

- `ephemeral_system_prompt` 只参与执行
- 不进入保存结果

这是一个很值得注意的边界设计。
它说明 Hermes 已经意识到：

- 运行时为了控制 agent 行为而加入的 prompt
- 和希望沉淀成长期训练样本的 prompt

不一定应该是同一份东西。

### 6.3 batch 模式下主动跳过 `SOUL.md` / `AGENTS.md` / memory

`batch_runner.py` 初始化 agent 时显式设置：

- `skip_context_files=True`
- `skip_memory=True`

原因写得很直接：

- 不要把工作目录里的上下文文件污染进轨迹
- 不要让持久 memory 影响批量数据生成

这说明 Hermes 在 batch 跑数时追求的是：

- 可重复
- 样本边界干净
- 尽量少混入操作者本地环境特征

这已经很像数据工程而不是普通脚本工程。

---

## 7. `batch_runner.py` 的价值不在并行，而在“可恢复的数据生产”

`batch_runner.py` 表面上是并发跑 prompt。
但它真正重要的地方是：它把一组 prompt 的执行变成了一个长期运行、可中断、可恢复、可统计的生产作业。

### 7.1 它的输出目录本身就是一个作业工件集

每个 run 会落到：

- `data/<run_name>/`

里面至少包括：

- `batch_*.jsonl`
- `trajectories.jsonl`
- `checkpoint.json`
- `statistics.json`

这不是“执行完吐一个文件”，而是：

- 中间批次文件
- 最终合并文件
- 恢复状态
- 聚合统计

全部都被建模成产物。

### 7.2 checkpoint 不是按批次位置恢复，而是按 prompt 内容恢复

`_scan_completed_prompts_by_content()` 和 `_filter_dataset_by_completed()` 很值得注意。

它不是简单记住：

- batch 3 跑完了
- prompt 42 跑完了

而是会扫描已有轨迹文件里的第一条 human message，用 prompt 文本做 resume 匹配。

这有很强的工程价值，因为它允许：

- 数据集重排后继续恢复
- 部分 batch 文件仍然有效
- checkpoint index 不完全可信时仍然尽量复用结果

这比简单的“按索引续跑”稳健很多。

### 7.3 增量 checkpoint 写入说明它假设任务会中途挂掉

父进程会在每个 batch 完成后增量更新 checkpoint。

这说明 Hermes 默认面对的是：

- 长时间批量任务
- worker 可能失败
- 中途 crash 是需要正面处理的常态

这依旧是非常典型的生产流水线思维。

---

## 8. 它在收集样本时顺手做了“可训练性统计”

`batch_runner.py` 不只保存 trajectory，也同步抽取统计信息。

主要有两类。

### 8.1 tool statistics

它会从消息历史里抽出：

- 每个 tool 的调用次数
- success / failure 次数
- failure count 映射

更重要的是，它还会把 tool schema 归一化到“全量工具全集”，给所有没出现的工具补零。

这个设计很容易被忽略，但很重要，因为它说明 Hermes 已经在考虑：

- Arrow / Parquet / HuggingFace datasets 的 schema 一致性

也就是说，它不是只想“先存成 JSONL 再说”，而是提前为后续数据分析和数据集加载做了结构约束。

### 8.2 reasoning coverage

`_extract_reasoning_stats()` 会统计：

- assistant turn 总数
- 有 reasoning 的 turn 数
- 没 reasoning 的 turn 数
- 是否存在任何 reasoning

这说明 Hermes 对 trajectory 的判断标准不只是“任务做没做完”，还包括：

- 这条样本有没有足够的 thinking signal

而且这不只是统计。

---

## 9. “零 reasoning 样本丢弃”暴露了非常明确的数据偏好

在 batch 逻辑里，如果某条成功样本：

- 所有 assistant turn 都没有 reasoning

它会被直接丢弃，不写入 batch 文件。

这是一个非常强的偏好信号。

它说明 Hermes 当前的数据生产目标，并不是普通 instruction/chat 数据，而更接近：

- 带推理痕迹的 agentic trajectory 数据

换句话说，这个 batch runner 在做的不是“把任何成功对话都收进来”，而是：

- 筛 reasoning-rich 样本

如果把这点和前面 trajectory 里强制写 `<think>` 结合起来看，会更明显：

- reasoning 是这条数据管线的核心目标之一

---

## 10. 它甚至考虑到了“坏样本清洗”和“模型幻觉污染”

batch 完成后合并 `batch_*.jsonl` 时，Hermes 还会再做一次过滤。

过滤对象包括：

- invalid JSON entry
- `tool_stats` 里出现不在已知工具集合中的 hallucinated tool name

这一步很值得注意，因为它表明 Hermes 已经见过一种典型脏数据：

- 模型生成了不合法工具名
- 下游样本结构被污染

所以最终 `trajectories.jsonl` 不是简单拼接，而是：

- 带最后一道校验的合并产物

这也是典型的数据生产线特征。

---

## 11. `trajectory_compressor.py` 说明 Hermes 不只关心“收集数据”，也关心“把长轨迹变得可用”

长 agent trajectory 有一个天然问题：

- 信息多
- token 也非常多

如果完全原样保留，很多样本会：

- 超出训练目标长度
- 不适合再投喂给下游模型
- 难以做统一预算的数据整理

`trajectory_compressor.py` 就是在解决这个问题。

### 11.1 它压缩的不是整条轨迹，而是中间区域

压缩策略非常明确：

1. 保护最前面的关键 turn
2. 保护最后 `N` 个 turn
3. 只压缩中间区域
4. 只压缩到足够满足 token budget 为止

这个设计背后的假设很合理：

- 开头包含任务定义和初始动作
- 结尾包含最终结论和关键收束
- 真正最容易冗长的是中间长链路探索

### 11.2 被压缩的中间区域会被替换成单条 human summary message

这不是简单删掉，而是：

- 提取被压缩 turn 内容
- 调用 summarizer 生成 `[CONTEXT SUMMARY]: ...`
- 用一个 summary turn 替换原区域

这说明 Hermes 在压缩时想保留的是：

- 行动脉络
- 关键信息
- 决策和结果

而不是逐 turn 细节。

### 11.3 它把 summary 视为“继续推理的上下文桥梁”

压缩器的注释写得很清楚：

- 保留后面的 tool calls intact
- 让模型在摘要之后还能继续工作

也就是说，这种压缩并不是纯离线归档压缩，而更像：

- 为继续 agent 推理准备的上下文压缩格式

这和单纯做训练集摘要又不完全一样。

---

## 12. 压缩器本身也是一个小型运行时

`trajectory_compressor.py` 不是一个静态文本处理器，它自己也带运行时能力。

### 12.1 它有 token budget、protected turns、summary budget 配置

`CompressionConfig` 里配置了：

- tokenizer
- `target_max_tokens`
- `summary_target_tokens`
- protect first / last turn 策略
- summarization model
- concurrency / timeout / retry

这说明压缩不是一个固定规则，而是一个可调数据加工阶段。

### 12.2 它会通过 shared provider routing 选择 summarizer

压缩器初始化 summarizer 时会尽量复用 Hermes 的 provider routing，而不是另起一套临时客户端约定。

这点很关键，因为它让：

- 主 agent runtime
- 数据后处理 runtime

共享同一套 provider / auth / endpoint 判断逻辑。

### 12.3 它有自己的 metrics 系统

压缩器不只输出结果，还跟踪：

- 原始 token / 压缩后 token
- 保存的 token 数
- 移除的 turn 数
- summarization API call / error
- still over limit 的轨迹数

所以它不是“黑箱压一下”，而是可分析、可审计的加工阶段。

---

## 13. `sample_and_compress.py` 暗示了 Hermes 的研究数据飞轮

如果说 `batch_runner.py` 是“原始数据生产”，那么 `scripts/sample_and_compress.py` 展示的就是更完整的数据飞轮。

它做的事情是：

1. 从多个 HuggingFace 数据集下载已有 trajectories
2. 用 tokenizer 统计 token 数
3. 过滤掉过短样本
4. 从联合池里随机采样
5. 分批落盘
6. 跑 trajectory compression
7. 再合并成最终 JSONL
8. 准备上传回 HuggingFace

这里最值得注意的，不是脚本本身，而是它反映出的工作流：

- Hermes 生成数据
- 数据进入 HuggingFace
- 之后又被重新抽样、压缩、重组
- 再产出新数据集

这已经是一个明确的 research data flywheel，而不只是“导出几条样本看看”。

脚本里默认数据集名字也很能说明问题，例如：

- `NousResearch/hermes-agent-megascience-sft1`
- `NousResearch/Hermes-Agent-Thinking-GLM-4.7-SFT1`
- `NousResearch/Hermes-Agent-Thinking-GLM-4.7-SFT2`
- `NousResearch/terminal-tasks-glm-hermes-agent`

这说明 Hermes 的轨迹数据并不是附带产物，而是已经进入持续迭代的数据资产。

---

## 14. 这套数据流水线最值得学习的点

### 14.1 运行时和数据格式之间有明确桥梁

`run_agent.py` 不是只会跑对话，也负责把运行结果转换成稳定 trajectory 格式。
这让：

- 在线 agent
- 离线数据

共享同一套语义来源。

### 14.2 batch runner 明确面向长任务和中断恢复

它不假设任务一次跑完，而是把：

- resume
- checkpoint
- content-based recovery
- corrupted entry filtering

都做成一等能力。

### 14.3 数据质量约束被前置了

reasoning coverage、tool schema normalization、invalid tool filtering，这些都不是分析阶段再补，而是在生产阶段就开始约束。

这会显著降低后面数据清洗成本。

### 14.4 压缩阶段不是简单裁剪，而是语义压缩

通过保护头尾、压缩中段、插入 summary turn，Hermes 保留的是 agent 轨迹最有价值的结构，而不是机械删 token。

---

## 15. 代价与复杂性

这套设计也有明显代价。

### 15.1 trajectory 已经不是原始记录，信息会有再解释

一旦从运行时消息改写成 `<think>` / `<tool_call>` / `<tool_response>` 文本协议，就意味着：

- 它更适合训练
- 但不再是最原始的调试记录

这在“训练友好”和“运行时保真”之间做了偏置选择。

### 15.2 reasoning 偏好会引入样本分布偏置

直接丢弃 zero-reasoning 样本，当然能提升 thinking 数据密度，但也会让数据集更偏向：

- 会显式输出 reasoning 的模型
- 会留下较长思考痕迹的任务

### 15.3 压缩总结会进一步引入二次模型偏差

一旦长轨迹由另一个 summarizer 压缩，中间区域就不再是原始行为，而是：

- 二次模型解释后的行为摘要

这对下游训练和评估是有价值的，但也意味着新偏差来源。

---

## 16. 建议阅读顺序

如果要继续深挖这条线，推荐顺序是：

1. `run_agent.py::_convert_to_trajectory_format()`  
   先看在线对话如何被转成训练样本。

2. `agent/trajectory.py`  
   再看保存工具和 scratchpad / think 的辅助逻辑。

3. `batch_runner.py`  
   重点看 `_process_single_prompt()`、resume、merge、statistics。

4. `trajectory_compressor.py`  
   看长轨迹如何被压缩成仍可用的样本。

5. `scripts/sample_and_compress.py`  
   最后再看更大尺度的数据抽样与再加工流程。

---

## 17. 本篇结论

Hermes 在 trajectory 这一层最值得注意的，不是“能把对话存下来”，而是它已经把：

- agent execution
- dataset generation
- data cleaning
- data compression
- dataset repackaging

串成了一条相对完整的研究数据流水线。

这说明 Hermes 的一个很深层定位是：

- 它不只是 agent 产品
- 它也是 agent 数据生产基础设施

而这条线真正成熟的标志，不在于导出了多少 JSONL，而在于它已经开始系统性处理这些问题：

- reasoning 是否保留
- 样本是否被环境噪声污染
- batch 作业如何恢复
- schema 如何稳定
- 长轨迹如何压缩
- 旧数据如何再抽样再发布

这比“有个 batch 脚本”高出很多层。
