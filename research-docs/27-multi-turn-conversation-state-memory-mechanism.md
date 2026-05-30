# Hermes-Agent 多轮对话状态记忆机制深度解析

## 概述

Hermes-Agent 实现了一个复杂而高效的多轮对话状态记忆系统，通过分层架构管理对话历史、用户记忆和上下文状态。该系统不仅支持单次会话内的对话连续性，还能实现跨会话的记忆保持和智能检索。

## 1. 核心架构组件

### 1.1 MemoryManager（记忆管理器）

**位置**: `agent/memory_manager.py`

MemoryManager 是整个记忆系统的中央协调器，负责：

- **统一管理**: 协调内置记忆提供者和外部插件提供者
- **工具路由**: 将模型调用路由到正确的记忆提供者
- **生命周期管理**: 管理提供者的初始化、运行和关闭
- **故障隔离**: 单个提供者故障不影响其他组件

**关键设计原则**:
```python
# 只允许一个外部提供者，避免工具模式冲突
if not is_builtin:
    if self._has_external:
        logger.warning("Rejected memory provider '%s' — external provider '%s' is already registered")
        return
    self._has_external = True
```

### 1.2 MemoryProvider（记忆提供者抽象）

**位置**: `agent/memory_provider.py`

定义了标准接口，支持多种后端实现：

**核心接口**:
- `initialize()` - 初始化连接，创建资源
- `prefetch()` - 预取相关上下文（每轮对话前）
- `sync_turn()` - 同步对话轮次（每轮对话后）
- `get_tool_schemas()` - 获取工具模式
- `handle_tool_call()` - 处理工具调用
- `shutdown()` - 清理和关闭

**可选钩子**:
- `on_turn_start()` - 对话轮次开始时的钩子
- `on_session_end()` - 会话结束时的钩子
- `on_session_switch()` - 会话切换时的钩子
- `on_pre_compress()` - 上下文压缩前的钩子
- `on_memory_write()` - 内置记忆写入时的钩子

### 1.3 ContextEngine（上下文引擎）

**位置**: `agent/context_engine.py`

管理对话上下文和智能压缩：

**核心职责**:
- Token 使用跟踪
- 压缩触发判断
- 智能上下文压缩
- 保留策略管理

**压缩保护策略**:
```python
protect_first_n: int = 3    # 保护前3条非系统消息
protect_last_n: int = 6     # 保护最后6条消息
threshold_percent: float = 0.75  # 达到75% token限制时触发压缩
```

## 2. 对话历史的内存管理

### 2.1 核心数据结构

**位置**: `run_agent.py`

```python
# 对话历史的核心数据结构
messages = list(conversation_history) if conversation_history else []
```

**消息格式**:
```python
{
    "role": "user" | "assistant" | "system",
    "content": "消息内容",
    "tool_calls": [...],           # 可选：工具调用
    "tool_call_id": "...",         # 可选：工具调用ID
    "reasoning": "...",            # 可选：推理内容
    "reasoning_content": "...",    # 可选：推理内容详情
}
```

### 2.2 多轮对话流程

**初始化阶段**:
```python
# 1. 加载历史对话
messages = list(conversation_history) if conversation_history else []

# 2. 恢复 TODO 状态（如果需要）
if conversation_history and not self._todo_store.has_items():
    self._hydrate_todo_store(conversation_history)

# 3. 恢复计数器状态（用于记忆提醒）
if conversation_history and self._user_turn_count == 0:
    prior_user_turns = sum(1 for m in conversation_history if m.get("role") == "user")
    if prior_user_turns > 0:
        self._user_turn_count = prior_user_turns
```

**执行阶段**:
```python
# 每轮对话的日志记录
logger.info(
    "conversation turn: session=%s model=%s provider=%s platform=%s history=%d msg=%r",
    self.session_id or "none", self.model, self.provider or "unknown",
    self.platform or "unknown", len(conversation_history or []),
    _msg_preview,
)
```

### 2.3 记忆注入机制

**系统提示词构建**:
```python
# 记忆上下文注入
def build_memory_context_block(raw_context: str) -> str:
    return (
        "<memory-context>\n"
        "[System note: The following is recalled memory context, "
        "NOT new user input. Treat as authoritative reference data — "
        "this is the agent's persistent memory and should inform all responses.]\n\n"
        f"{clean}\n"
        "</memory-context>"
    )
```

**流式响应清洗**:
```python
# StreamingContextScrubber 用于清洗流式响应中的记忆标记
scrubber = StreamingContextScrubber()
for delta in stream:
    visible = scrubber.feed(delta)
    if visible:
        emit(visible)
```

## 3. 持久化存储机制

### 3.1 双重存储架构

**SessionStore** 实现了双重存储保证：

```python
class SessionStore:
    def __init__(self, sessions_dir: Path, config: GatewayConfig):
        # SQLite 主要存储
        self._db = SessionDB()

        # JSONL 备用存储
        self.transcript_path = sessions_dir / f"{session_id}.jsonl"
```

**写入流程**:
```python
def append_to_transcript(self, session_id: str, message: Dict[str, Any], skip_db: bool = False):
    # 1. 写入 SQLite（主要存储）
    if self._db and not skip_db:
        self._db.append_message(
            session_id=session_id,
            role=message.get("role", "unknown"),
            content=message.get("content"),
            tool_name=message.get("tool_name"),
            tool_calls=message.get("tool_calls"),
            # ... 其他字段
        )

    # 2. 写入 JSONL（备用存储）
    with open(transcript_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(message, ensure_ascii=False) + "\n")
```

### 3.2 读取和恢复机制

**智能选择数据源**:
```python
def load_transcript(self, session_id: str) -> List[Dict[str, Any]]:
    # 1. 尝试从 SQLite 读取
    db_messages = self._db.get_messages_as_conversation(session_id) if self._db else []

    # 2. 从 JSONL 读取历史数据
    jsonl_messages = []
    if transcript_path.exists():
        with open(transcript_path, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    jsonl_messages.append(json.loads(line))

    # 3. 选择消息数量较多的源（防止数据丢失）
    return jsonl_messages if len(jsonl_messages) > len(db_messages) else db_messages
```

## 4. 会话管理与状态跟踪

### 4.1 SessionEntry 元数据

**位置**: `gateway/session.py`

```python
@dataclass
class SessionEntry:
    # 基础标识
    session_key: str              # 会话键（平台+聊天ID+用户ID）
    session_id: str               # 唯一会话ID
    created_at: datetime          # 创建时间
    updated_at: datetime          # 更新时间

    # 来源信息
    origin: Optional[SessionSource] = None  # 消息来源

    # Token 跟踪
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    total_tokens: int = 0
    last_prompt_tokens: int = 0   # 最后一次 API 调用的 prompt tokens

    # 成本跟踪
    estimated_cost_usd: float = 0.0
    cost_status: str = "unknown"

    # 会话状态标记
    was_auto_reset: bool = False          # 是否自动重置
    auto_reset_reason: Optional[str] = None  # 重置原因
    reset_had_activity: bool = False      # 重置前是否有活动
    is_fresh_reset: bool = False          # 是否手动重置
    expiry_finalized: bool = False        # 是否已最终确定
    suspended: bool = False               # 是否暂停
    resume_pending: bool = False          # 是否等待恢复
```

### 4.2 会话键构建

**统一的会话隔离机制**:

```python
def build_session_key(source: SessionSource) -> str:
    platform = source.platform.value

    if source.chat_type == "dm":
        # DM: agent:main:{platform}:dm:{chat_id}
        dm_chat_id = canonical_whatsapp_identifier(source.chat_id)
        if dm_chat_id:
            if source.thread_id:
                return f"agent:main:{platform}:dm:{dm_chat_id}:{source.thread_id}"
            return f"agent:main:{platform}:dm:{dm_chat_id}"

    # 群组: agent:main:{platform}:{chat_type}:{chat_id}:{user_id}
    key_parts = ["agent:main", platform, source.chat_type]

    if source.chat_id:
        key_parts.append(source.chat_id)
    if source.thread_id:
        key_parts.append(source.thread_id)

    # 用户隔离
    if group_sessions_per_user:
        participant_id = source.user_id_alt or source.user_id
        if participant_id:
            key_parts.append(str(participant_id))

    return ":".join(key_parts)
```

**会话隔离规则**:
- **DM**: 按 `chat_id` 隔离，每个私聊独立会话
- **线程**: 按 `thread_id` 隔离，每个主题独立会话
- **群组**: 按 `chat_id + user_id` 隔离，每个用户在群组中有独立会话

### 4.3 会话生命周期管理

**自动重置策略**:

```python
def _should_reset(self, entry: SessionEntry, source: SessionSource) -> Optional[str]:
    policy = self.config.get_reset_policy(
        platform=source.platform,
        session_type=source.chat_type
    )

    now = _now()

    # 1. 空闲超时
    if policy.mode in {"idle", "both"}:
        idle_deadline = entry.updated_at + timedelta(minutes=policy.idle_minutes)
        if now > idle_deadline:
            return "idle"

    # 2. 每日重置
    if policy.mode in {"daily", "both"}:
        today_reset = now.replace(hour=policy.at_hour, minute=0, second=0, microsecond=0)
        if now.hour < policy.at_hour:
            today_reset -= timedelta(days=1)
        if entry.updated_at < today_reset:
            return "daily"

    return None
```

**重置模式**:
- `none`: 不自动重置
- `idle`: 空闲超时后重置
- `daily`: 每天固定时间重置
- `both`: 空闲超时或每日时间重置

## 5. 智能记忆检索与预取

### 5.1 记忆检索流程

**每轮对话的完整流程**:

```python
# 1. 预取阶段（对话开始前）
prefetch_context = memory_manager.prefetch_all(user_message, session_id=session_id)

# 2. 构建系统提示词
if prefetch_context:
    memory_block = build_memory_context_block(prefetch_context)
    system_prompt += memory_block

# 3. 执行对话
response = agent.run_conversation(user_message, system_prompt=system_prompt)

# 4. 同步记忆（对话结束后）
memory_manager.sync_all(user_message, response, session_id=session_id)

# 5. 预取下一轮记忆
memory_manager.queue_prefetch_all(user_message, session_id=session_id)
```

### 5.2 异步预取机制

**预取队列**:
```python
def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
    """为下一轮对话排队记忆预取"""
    # 在后台执行检索，结果缓存到下一轮使用
    # 提供者应实现非阻塞的预取逻辑
```

### 5.3 记忆清洗和过滤

**上下文围栏**:
```python
# 清洗记忆上下文中的标记和系统注释
def sanitize_context(text: str) -> str:
    # 移除 <memory-context> 标记
    text = _FENCE_TAG_RE.sub('', text)

    # 移除内部上下文块
    text = _INTERNAL_CONTEXT_RE.sub('', text)

    # 移除系统注释
    text = _INTERNAL_NOTE_RE.sub('', text)

    return text
```

## 6. 上下文压缩与长对话管理

### 6.1 压缩触发条件

**自动触发**:
```python
def should_compress(self, prompt_tokens: int = None) -> bool:
    if prompt_tokens and prompt_tokens > self.threshold_tokens:
        return True
    if self.last_prompt_tokens > self.threshold_tokens:
        return True
    return False
```

**手动触发**:
- `/compress` 命令
- `/focus <topic>` 命令（引导式压缩）

### 6.2 压缩保护策略

**重要消息保护**:
```python
# ContextCompressor 的保护策略
protect_first_n: int = 3    # 前3条非系统消息
protect_last_n: int = 6     # 最后6条消息

# 压缩时的消息保留策略
# 1. 系统提示词（始终保留）
# 2. 前 protect_first_n 条非系统消息
# 3. 最后 protect_last_n 条消息
# 4. 中间的消息进行智能总结
```

### 6.3 记忆提供者参与压缩

**压缩前提取**:
```python
def on_pre_compress(self, messages: List[Dict[str, Any]]) -> str:
    """在上下文压缩前提取重要信息"""
    # 记忆提供者可以从即将被压缩的消息中提取重要信息
    # 返回的文本将被包含在压缩总结提示词中
    return ""
```

## 7. 跨平台会话连续性

### 7.1 平台统一抽象

**SessionSource 数据结构**:
```python
@dataclass
class SessionSource:
    platform: Platform           # 平台类型
    chat_id: str                 # 聊天ID
    chat_name: Optional[str]     # 聊天名称
    chat_type: str               # 聊天类型："dm", "group", "channel", "thread"
    user_id: Optional[str]       # 用户ID
    user_name: Optional[str]     # 用户名
    thread_id: Optional[str]     # 线程ID
    chat_topic: Optional[str]    # 频道主题
```

### 7.2 跨会话记忆共享

**SessionContext 上下文注入**:
```python
@dataclass
class SessionContext:
    source: SessionSource
    connected_platforms: List[Platform]  # 已连接的平台
    home_channels: Dict[Platform, HomeChannel]  # 主频道
    shared_multi_user_session: bool = False     # 多用户会话标志

    # 动态系统提示词注入
    def build_session_context_prompt(self) -> str:
        # 告诉 AI 它当前的运行环境和可用能力
        # 包括：平台信息、用户信息、连接的平台、主频道等
```

### 7.3 会话恢复机制

**断点续传**:
```python
def mark_resume_pending(self, session_key: str, reason: str = "restart_timeout") -> bool:
    """标记会话为可恢复状态"""
    entry = self._entries.get(session_key)
    if entry and not entry.suspended:
        entry.resume_pending = True
        entry.resume_reason = reason
        return True
    return False
```

**会话切换**:
```python
def switch_session(self, session_key: str, target_session_id: str) -> Optional[SessionEntry]:
    """切换到指定会话"""
    # 用于 /resume 命令，恢复之前的会话
    # 保持会话 ID 不变，加载完整的历史记录
```

## 8. 记忆的长期学习机制

### 8.1 自改进循环

**定期提醒机制**:
```python
# MemoryManager 中的提醒逻辑
def on_turn_start(self, turn_number: int, message: str, **kwargs) -> None:
    """每轮对话开始时检查是否需要提醒保存记忆"""
    if self._memory_nudge_interval > 0:
        self._turns_since_memory += 1
        if self._turns_since_memory >= self._memory_nudge_interval:
            # 触发记忆提醒，让 AI 保存重要信息
            self._trigger_memory_nudge()
```

### 8.2 技能创建和改进

**自动技能创建**:
- 复杂任务完成后自动创建技能
- 技能在使用过程中自我改进
- 支持 agentskills.io 开放标准

### 8.3 跨会话检索

**全文搜索**:
- SQLite FTS5 全文搜索
- LLM 总结检索结果
- 跨会话语义搜索

## 9. 性能优化策略

### 9.1 缓存机制

**代理缓存**:
```python
# Gateway 中的代理缓存
# 1 小时空闲驱逐
# 配置签名变化时重建
# 支持进程重启后恢复
```

**提示词缓存**:
```python
# OpenAI prompt caching
# 缓存系统提示词和早期消息
# 显著减少长对话的成本
```

### 9.2 懒加载和按需初始化

**OpenAI SDK 懒加载**:
```python
# run_agent.py 中的懒加载实现
class _OpenAIProxy:
    """延迟加载 OpenAI SDK"""
    def __call__(self, *args, **kwargs):
        return _load_openai_cls()(*args, **kwargs)
```

### 9.3 批处理和异步操作

**记忆同步批处理**:
```python
def sync_turn(self, user_content: str, assistant_content: str) -> None:
    """非阻塞同步，排队处理"""
    # 避免阻塞主对话流程
    # 在后台异步写入持久化存储
```

## 10. 总结

Hermes-Agent 的多轮对话状态记忆系统是一个精心设计的分层架构：

### 10.1 架构层次

1. **内存层**: 当前对话历史的实时管理
2. **存储层**: SQLite + JSONL 双重持久化
3. **记忆层**: 智能检索和上下文注入
4. **会话层**: 跨平台会话管理和状态跟踪
5. **压缩层**: 长对话的智能压缩和总结

### 10.2 核心特性

- **连续性**: 跨会话、跨平台的对话连续性
- **智能性**: 基于上下文的智能记忆检索
- **效率性**: Token 优化和压缩策略
- **可靠性**: 双重存储和故障恢复
- **扩展性**: 插件化的记忆提供者架构

### 10.3 技术亮点

- **分层设计**: 清晰的职责分离和接口抽象
- **故障隔离**: 单点故障不影响整体系统
- **性能优化**: 缓存、懒加载、异步操作
- **用户体验**: 断点续传、智能压缩、跨平台同步

这个系统使得 Hermes-Agent 能够处理长对话、跨会话记忆，同时保持高效的 token 使用和良好的响应速度，是一个优秀的多轮对话状态管理解决方案。