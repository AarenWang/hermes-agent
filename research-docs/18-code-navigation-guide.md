# Hermes Agent 代码导航指南

## 🎯 快速代码查找

本文档提供了按功能模块分类的代码文件和函数查找指南，帮助开发者快速定位代码位置。

## 📂 主要目录结构

```
hermes-agent/
├── gateway/              # 网关和平台适配器
├── hermes_cli/           # 命令行界面
├── agent/                # Agent核心逻辑
├── tools/                # 工具实现
├── providers/            # LLM提供商适配
├── run_agent.py          # Agent运行器
└── cli.py               # CLI入口
```

## 🔍 按功能查找代码

### 飞书消息处理

**主要文件**: `gateway/platforms/feishu.py`

**关键函数和类**:
```python
# 飞书适配器主类
class FeishuAdapter(PlatformAdapter):
    def start_polling(self)                    # 启动轮询
    def _handle_message(self, event)          # 处理消息事件
    def _extract_media_files(self, event)     # 提取媒体文件
    def send_message(self, content, ...)      # 发送响应
```

**执行流程**:
1. `FeishuAdapter.start_polling()` - 开始监听飞书事件
2. `_handle_message()` - 处理接收到的消息
3. `_create_message_event()` - 创建统一消息事件
4. `GatewayRunner.queue_message()` - 发送到网关队列

### TUI命令处理

**主要文件**: `hermes_cli/main.py`

**关键函数和类**:
```python
# TUI命令处理
class ChatCommand:
    def run(self, user_input)                 # 运行命令
    def _parse_input(self, text)              # 解析输入
    def _handle_user_message(self, ...)       # 处理用户消息
    def _display_response(self, response)     # 显示响应
```

**执行流程**:
1. `ChatCommand.run()` - 接收用户输入
2. `_parse_input()` - 解析命令类型
3. `_create_message_event()` - 创建消息事件
4. `AIAgent.run_conversation()` - 直接调用Agent

### Gateway网关核心

**主要文件**: `gateway/run.py`

**关键类和函数**:
```python
class GatewayRunner:
    def __init__(self)                        # 初始化网关
    def start(self)                           # 启动网关
    def _handle_message(self, event)          # 处理消息
    def _get_or_create_session(self, key)     # 获取/创建会话
    def _get_agent(self, session_key)         # 获取Agent实例
    def _route_to_agent(self, session, ...)   # 路由到Agent
    def _deliver_to_platform(self, ...)       # 投递响应
```

**关键函数调用链**:
```
GatewayRunner._handle_message()
    → _parse_session_key()
    → _get_or_create_session()
    → _get_agent()
    → agent.run_conversation()
    → _deliver_to_platform()
```

### 会话管理

**主要文件**: `gateway/session.py`

**关键类和函数**:
```python
class Session:
    def __init__(self, session_key, agent)    # 初始化会话
    def load_history(self)                   # 加载历史
    def save_messages(self, messages)        # 保存消息
    def get_status(self)                     # 获取状态
    def is_expired(self)                     # 检查过期
```

**会话生命周期**:
1. `GatewayRunner._get_or_create_session()` - 创建会话
2. `Session.load_history()` - 加载对话历史
3. `agent.run_conversation()` - 执行对话
4. `Session.save_messages()` - 保存消息

### AIAgent核心执行

**主要文件**: `run_agent.py`

**关键类和函数**:
```python
class AIAgent:
    def __init__(self, base_url, model, ...)   # 初始化Agent
    def run_conversation(self, user_message)   # 运行对话
    def _build_system_prompt(self)            # 构建系统提示
    def _call_llm_api(self, messages)         # 调用LLM
    def _execute_tool_calls(self, response)   # 执行工具调用
    def _final_response(self, ...)            # 最终响应
```

**核心执行流程**:
```
AIAgent.run_conversation()
    → _build_system_prompt()           # 构建提示
    → _call_llm_api()                   # LLM调用
    → _process_response()              # 处理响应
    → _execute_tool_calls()            # 执行工具
    → _final_response()                 # 最终响应
```

### 提示词构建

**主要文件**: `agent/prompt_builder.py`

**关键函数和常量**:
```python
# 主要构建函数
def build_system_prompt(...)          # 主构建函数
def load_soul_md(...)                 # SOUL.md加载
def build_context_files_prompt(...)    # 上下文文件
def build_skills_system_prompt(...)    # 技能索引
def build_environment_hints(...)       # 环境提示

# 关键常量
DEFAULT_AGENT_IDENTITY               # 默认身份
MEMORY_GUIDANCE                       # 记忆指导
PLATFORM_HINTS                        # 平台提示
```

**提示词组件**:
1. 身份提示: `DEFAULT_AGENT_IDENTITY`
2. 记忆指导: `MEMORY_GUIDANCE`
3. 技能索引: `build_skills_system_prompt()`
4. 上下文文件: `build_context_files_prompt()`
5. 平台提示: `PLATFORM_HINTS[platform]`

### 工具执行

**主要工具文件**:
```
tools/
├── terminal_tool.py          # 终端命令执行
├── file_tools.py             # 文件操作
├── search.py                 # 搜索功能
├── browser_tools.py          # 浏览器自动化
└── memory_tool.py            # 记忆管理
```

**工具执行流程**:
```
AIAgent._execute_tool_calls()
    → _parse_tool_call()              # 解析工具调用
    → _check_tool_availability()       # 检查可用性
    → tool.execute()                   # 执行工具
    → _handle_tool_result()            # 处理结果
    → _continue_after_tool()           # 继续对话
```

## 🎨 不同入口的代码路径对比

### 飞书消息路径

```
用户输入
↓
gateway/platforms/feishu.py::FeishuAdapter._handle_message()
↓
gateway/run.py::GatewayRunner._handle_message()
↓
gateway/run.py::GatewayRunner._get_or_create_session()
↓
gateway/run.py::GatewayRunner._get_agent()
↓
run_agent.py::AIAgent.run_conversation()
↓
gateway/run.py::GatewayRunner._deliver_to_platform()
↓
gateway/platforms/feishu.py::FeishuAdapter.send_message()
```

### TUI命令路径

```
用户输入
↓
hermes_cli/main.py::ChatCommand._parse_input()
↓
hermes_cli/main.py::ChatCommand._handle_user_message()
↓
run_agent.py::AIAgent.run_conversation()
↓
hermes_cli/display.py::format_response()
↓
hermes_cli/main.py::ChatCommand._display_response()
```

### 定时任务路径

```
调度器触发
↓
cron/scheduler.py::CronScheduler._execute_job()
↓
gateway/run.py::GatewayRunner._handle_cron_message()
↓
run_agent.py::AIAgent.run_conversation()
↓
cron/delivery.py::deliver_to_destination()
```

## 🗂️ 关键数据结构

### MessageEvent 结构

**位置**: `gateway/session.py`

```python
@dataclass
class MessageEvent:
    # 平台信息
    platform: str              # "feishu", "cli", "telegram"
    source: str                # 来源标识
    
    # 用户信息
    user_id: str              # 用户ID
    user_name: str            # 用户名
    
    # 消息内容
    content: str              # 文本内容
    media_files: List[str]    # 媒体文件列表
    
    # 会话信息
    session_key: str          # 会话密钥
    message_id: str           # 消息ID
    
    # 元数据
    timestamp: datetime        # 时间戳
    metadata: Dict[str, Any]  # 平台元数据
```

### Session 结构

**位置**: `gateway/session.py`

```python
@dataclass
class Session:
    session_key: str          # 会话唯一标识
    agent: AIAgent            # Agent实例
    created_at: datetime       # 创建时间
    last_activity: datetime   # 最后活动时间
    message_count: int        # 消息计数
    status: SessionStatus     # 会话状态
```

### AIAgent 消息结构

**位置**: `run_agent.py`

```python
@dataclass
class Message:
    role: str                 # "system", "user", "assistant", "tool"
    content: str              # 消息内容
    tool_calls: List[ToolCall] # 工具调用
    tool_call_id: str         # 工具调用ID
```

## 🚀 调试和日志查找

### 启用调试日志

```python
# 设置日志级别
import logging
logging.basicConfig(level=logging.DEBUG)

# 模块特定日志
logging.getLogger('gateway.run').setLevel(logging.DEBUG)
logging.getLogger('run_agent').setLevel(logging.DEBUG)
```

### 关键日志点

1. **飞书消息接收**: `gateway/platforms/feishu.py:FeishuAdapter._handle_message()`
2. **网关路由**: `gateway/run.py:GatewayRunner._handle_message()`
3. **Agent执行**: `run_agent.py:AIAgent.run_conversation()`
4. **工具执行**: `tools/terminal_tool.py:terminal()`
5. **响应投递**: `gateway/delivery.py:format_response()`

### 性能监控点

1. **响应时间**: `run_agent.py:AIAgent.run_conversation()`
2. **工具执行**: `tools/terminal_tool.py:execute_command()`
3. **会话缓存**: `gateway/run.py:GatewayRunner._get_agent()`
4. **LLM调用**: `providers/:Provider.chat()`

## 📊 调用链追踪

### 飞书消息完整调用链

```
用户飞书消息
  ↓
gateway/platforms/feishu.py::FeishuAdapter.start_polling()
  ↓ 
gateway/platforms/feishu.py::FeishuAdapter._handle_message()
  ↓
gateway/platforms/feishu.py::FeishuAdapter._create_message_event()
  ↓
gateway/run.py::GatewayRunner.queue_message()
  ↓
gateway/run.py::GatewayRunner._handle_message()
  ↓
gateway/run.py::GatewayRunner._parse_session_key()
  ↓
gateway/run.py::GatewayRunner._get_or_create_session()
  ↓
gateway/session.py::Session.load_history()
  ↓
gateway/run.py::GatewayRunner._get_agent()
  ↓
run_agent.py::AIAgent.run_conversation()
  ↓
agent/prompt_builder.py::build_system_prompt()
  ↓
agent/prompt_builder.py::load_soul_md()
  ↓
agent/prompt_builder.py::build_skills_system_prompt()
  ↓
agent/prompt_builder.py::build_context_files_prompt()
  ↓
providers/::Provider.chat()
  ↓
run_agent.py::AIAgent._execute_tool_calls()
  ↓
tools/terminal_tool.py::terminal()
  ↓
tools/::execute_command()
  ↓
gateway/delivery.py::format_response()
  ↓
gateway/platforms/feishu.py::FeishuAdapter.send_message()
  ↓
用户飞书响应
```

### TUI命令完整调用链

```
用户TUI命令
  ↓
hermes_cli/main.py::ChatCommand.run()
  ↓
hermes_cli/main.py::ChatCommand._parse_input()
  ↓
hermes_cli/main.py::ChatCommand._route_command()
  ↓
hermes_cli/main.py::ChatCommand._handle_user_message()
  ↓
hermes_cli/main.py::ChatCommand._create_message_event()
  ↓
run_agent.py::AIAgent.run_conversation()
  ↓
agent/prompt_builder.py::build_system_prompt()
  ↓
providers/::Provider.chat()
  ↓
run_agent.py::AIAgent._execute_tool_calls()
  ↓
tools/terminal_tool.py::terminal()
  ↓
hermes_cli/display.py::format_response()
  ↓
hermes_cli/main.py::ChatCommand._display_response()
  ↓
用户TUI响应
```

## 🔧 修改和扩展指南

### 添加新平台支持

1. **创建平台适配器**:
   ```python
   # gateway/platforms/newplatform.py
   class NewPlatformAdapter(PlatformAdapter):
       def _handle_message(self, event):
           # 处理平台特定消息
           pass
   ```

2. **注册平台提示**:
   ```python
   # agent/prompt_builder.py
   PLATFORM_HINTS["newplatform"] = (
       "You are on NewPlatform..."
   )
   ```

3. **添加到网关**:
   ```python
   # gateway/run.py
   self.adapters["newplatform"] = NewPlatformAdapter(...)
   ```

### 添加新工具

1. **创建工具函数**:
   ```python
   # tools/my_tool.py
   def my_tool(parameter: str) -> str:
       # 工具逻辑
       pass
   ```

2. **注册工具**:
   ```python
   # hermes_cli/tools_config.py
   TOOL_DEFINITIONS["my_tool"] = {
       "function": my_tool,
       "description": "My tool description"
   }
   ```

### 自定义提示词

1. **修改身份提示**:
   ```python
   # agent/prompt_builder.py
   DEFAULT_AGENT_IDENTITY = "You are my custom assistant..."
   ```

2. **添加平台提示**:
   ```python
   # agent/prompt_builder.py
   PLATFORM_HINTS["myplatform"] = "Platform-specific guidance..."
   ```

3. **添加技能指导**:
   ```python
   # agent/prompt_builder.py
   SKILLS_GUIDANCE = "Custom skills guidance..."
   ```

## 📝 代码阅读建议

### 新手入门路径

1. **从TUI开始**: `hermes_cli/main.py` → `run_agent.py` → `agent/prompt_builder.py`
2. **理解工具系统**: `tools/terminal_tool.py` → `tools/file_tools.py` → `hermes_cli/tools_config.py`
3. **学习网关**: `gateway/run.py` → `gateway/session.py` → `gateway/platforms/base.py`

### 高级开发者路径

1. **多平台架构**: `gateway/platforms/` → `gateway/platform_registry.py` → `gateway/run.py`
2. **性能优化**: `gateway/run.py` (Agent缓存) → `agent/prompt_builder.py` (提示词缓存)
3. **并发处理**: `gateway/run.py` (消息队列) → `tools/environments.py` (环境隔离)

### 维护者路径

1. **核心协议**: `run_agent.py` → `providers/` → `tools/`
2. **扩展机制**: `agent/skill_utils.py` → `agent/prompt_builder.py` → `gateway/platforms/base.py`
3. **监控和调试**: `hermes_logging.py` → `gateway/status.py` → `tools/debug.py`

## 🎯 快速问题定位

### 问题: 飞书消息没有响应

**检查点**:
1. `gateway/platforms/feishu.py:FeishuAdapter.start_polling()` - 轮询是否启动
2. `gateway/run.py:GatewayRunner._handle_message()` - 消息是否到达网关
3. `gateway/session.py:Session.load_history()` - 会话是否创建
4. `run_agent.py:AIAgent.run_conversation()` - Agent是否执行

### 问题: TUI命令执行错误

**检查点**:
1. `hermes_cli/main.py:ChatCommand._parse_input()` - 命令解析是否正确
2. `run_agent.py:AIAgent._build_system_prompt()` - 提示词构建是否成功
3. `tools/terminal_tool.py:terminal()` - 工具权限是否足够
4. `hermes_cli/display.py:format_response()` - 响应格式化是否正确

### 问题: 性能问题

**检查点**:
1. `gateway/run.py:GatewayRunner._get_agent()` - Agent缓存命中率
2. `agent/prompt_builder.py:build_skills_system_prompt()` - 提示词缓存效率
3. `tools/environments.py:get_environment().execute()` - 环境执行性能
4. `providers/:Provider.chat()` - LLM API响应时间

## 📚 相关文档

- [15-message-processing-flow-swimlane-diagram.md](./15-message-processing-flow-swimlane-diagram.md) - 主流程泳道图
- [16-technical-execution-flow-diagram.md](./16-technical-execution-flow-diagram.md) - 技术执行流程
- [17-user-interaction-scenarios.md](./17-user-interaction-scenarios.md) - 实际交互场景

---

**提示**: 使用IDE的"转到定义"功能(通常是F12或Ctrl+点击)可以快速在相关代码文件之间导航。
