# Hermes Agent 多租户 Session 管理 vs Coding Agent Session 对比

## 1. 核心区别

两者 session 解决的是不同层面的问题：

| 维度 | Coding Agent（Claude Code / Codex） | Hermes Agent（多入口 IM） |
|------|--------------------------------------|---------------------------|
| 进程模型 | 一个 session 一个进程 | 一个进程服务 N 个 session |
| 隔离方式 | 天然隔离（进程级） | 逻辑隔离（session key） |
| 生命周期 | 跟随终端进程 | 空闲超时 + 定时重置 |
| 状态持久化 | 文件系统 | SQLite + JSONL |
| 并发处理 | 无需 | 异步锁保证同 session 顺序执行 |
| 用户身份 | 无需 | session key 包含 user_id，群聊按用户隔离 |

简单类比：
- **Coding Agent** — "一人一间房"，关灯走人房间就没了
- **Hermes Agent** — "酒店管理"，同一个前台要管很多房间，每间有独立钥匙、独立有效期、独立清理策略

## 2. Coding Agent 的 Session 特点

- **1:1 绑定**：一个终端窗口 = 一个 session，生命周期跟随进程
- **无隔离需求**：只有你一个人在用，不需要区分用户
- **上下文 = 文件**：通过文件系统天然保持状态，session 断了重连后文件还在
- **创建/销毁**：启动进程即创建，关掉终端即结束，没有过期/续期的概念

## 3. Hermes Agent Session 机制

### 3.1 Session Key 设计

```
agent:main:{platform}:{chat_type}:{chat_id}:{thread_id}:{user_id}
```

按平台和聊天类型动态拼接，示例：

| 场景 | Session Key 示例 | 隔离规则 |
|------|------------------|----------|
| 飞书私聊 | `feishu:private:ou_xxx::uid_xxx` | 每人独立 |
| 飞书群聊 | `feishu:group:oc_xxx::uid_xxx` | 同群不同用户隔离（`group_sessions_per_user=True`） |
| 飞书话题 | `feishu:thread::thread_xxx:` | 同话题内共享（`thread_sessions_per_user=False`） |

**代码位置**：`gateway/session.py:600-665` — `build_session_key()` 函数

### 3.2 Session 生命周期

```
创建 → 活跃 → 空闲超时/每日重置 → 清理
         ↑                    ↓
         └── 新消息重激活 ←───┘
```

**重置策略**（`gateway/session.py:752-788`）：
- **空闲过期**：`idle_minutes` 无消息则 session 过期
- **每日重置**：可配置固定时间点（如凌晨4点）自动开新 session
- **模式**：`none` / `idle` / `daily` / `both`

**后台清理**（`gateway/run.py:4052-4151`）：
- GatewayRunner 每 5 分钟扫描过期 session
- 驱逐缓存的 Agent 实例
- 释放工具资源
- 标记 session 为 `expiry_finalized`
- 失败最多重试 3 次

### 3.3 Agent 缓存池（LRU）

不同于 coding agent 每个 session 独占一个进程，Hermes 用 LRU 缓存池管理 Agent 实例：

```python
# gateway/run.py:1275-1276
_agent_cache: OrderedDict[str, (AIAgent, config_signature)]  # max 128
```

运行机制：
- 同一个 session_key 复用同一个 Agent（保留对话历史和工具状态）
- 缓存满时淘汰最久未访问的 Agent
- 用户发 `/new`、`/reset`、`/model` 切换时主动驱逐旧 Agent
- Agent 空闲超过 1 小时自动淘汰（`_AGENT_CACHE_IDLE_TTL_SECS = 3600`）

**代码位置**：
- 缓存管理：`gateway/run.py:15250-15309`
- 容量限制：`gateway/run.py` — `_enforce_agent_cache_cap()`
- 资源清理：`gateway/run.py:14074-14095` — `_cleanup_agent_resources()`

### 3.4 并发安全

同 session 内的消息需要顺序处理，不同 session 可以并行：

```python
# gateway/session_context.py — 上下文变量隔离
# 每个会话独立的执行上下文，asyncio.Lock 保证顺序
async with self.lock:
    return await self._execute_in_context(message)
```

### 3.5 持久化

Session 状态通过双重存储保证可靠性：
- **SQLite**：主存储，支持索引查询
- **JSONL**：备用/审计日志

Agent 实例本身不在磁盘上持久化（内存中的 LRU 缓存），但对话历史通过 memory provider 持久化，网关重启后可以恢复 session 上下文。

## 4. 为什么需要这种设计

Hermes Agent 作为多入口 IM 平台的 Agent，需要解决 coding agent 不需要面对的问题：

1. **多用户并发**：飞书群里 10 个人同时 @机器人，需要 10 个独立 session
2. **长连接场景**：IM 是 7x24 在线的，session 不能随"关终端"结束
3. **资源有限**：不可能为每个用户常驻一个 Agent 进程，需要 LRU 缓存 + 按需加载
4. **隔离安全**：用户 A 的对话历史不能泄露给用户 B
5. **状态恢复**：网关重启后，用户无感知地继续之前的对话
