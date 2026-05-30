# Hermes Agent 用户交互流程图 - 实际示例

## 实际场景示例

### 场景1：飞书用户询问代码问题

```mermaid
sequenceDiagram
    autonumber
    actor User as 👨‍💻 开发者
    participant Feishu as 📱 飞书App
    participant Gateway as 🚪 Hermes网关
    participant Agent as 🤖 AIAgent
    participant Code as 💻 代码分析
    participant Memory as 💾 持久记忆
    
    User->>Feishu: "帮我看看这个Python函数有什么问题"
    User->>Feishu: 上传代码文件 main.py
    
    Feishu->>Gateway: 消息事件 + 文件附件
    Note over Gateway: 解析飞书格式<br/>下载文件到临时路径
    
    Gateway->>Agent: 创建/获取会话
    Note over Agent: session_key:<br/>agent:main:feishu:direct:user_123
    
    Agent->>Agent: 构建系统提示
    Note right of Agent: 身份: Python专家助手<br/>技能: 代码分析技能<br/>记忆: 用户偏好简洁解释
    
    Agent->>Code: 分析 main.py 文件
    Note over Code: 执行: read_file('main.py')<br/>工具: python语法检查
    
    Code-->>Agent: 返回分析结果
    Note right of Agent: 发现: 未处理的异常<br/>建议: 添加try-catch块
    
    Agent->>Memory: 保存用户偏好
    Note right of Memory: "用户偏好Python代码最佳实践"<br/>"项目使用pytest测试框架"
    
    Agent->>Gateway: 格式化响应
    Note over Gateway: 飞书格式: Markdown代码块<br/>高亮语法、行号引用
    
    Gateway->>Feishu: 发送响应
    Note right of Feishu: 📤 MEDIA:/tmp/main.py<br/>📝 修复建议代码
    
    Feishu->>User: 显示响应
    Note over User: ✅ 问题分析<br/>✅ 代码建议<br/>✅ 文件预览
```

### 场景2：TUI用户执行系统管理任务

```mermaid
sequenceDiagram
    autonumber
    actor User as 🔧 系统管理员
    participant TUI as 💻 终端界面
    participant Agent as 🤖 AIAgent
    participant Terminal as 🖥️ 系统终端
    participant Memory as 💾 持久记忆
    
    User->>TUI: 输入: "/disk-usage"
    
    TUI->>Agent: 命令解析
    Note over Agent: 识别为系统管理命令<br/>加载相关技能
    
    Agent->>Agent: 检查终端环境
    Note right of Agent: 环境: Linux服务器<br/>权限: sudo访问<br/>工作目录: /home/admin
    
    Agent->>Terminal: 执行磁盘检查命令
    Note over Terminal: df -h<br/>du -sh /var/log<br/>ls -lh /tmp/*
    
    Terminal-->>Agent: 返回系统状态
    Note right of Agent: /: 85% 使用<br/>/var/log: 2.3GB<br/>警告: /tmp 满
    
    Agent->>Agent: 分析结果
    Note right of Agent: 检测到问题<br/>制定清理方案<br/>提供安全建议
    
    Agent->>Memory: 保存系统信息
    Note right of Memory: "服务器磁盘使用率85%"<br/>"/var/log需要定期清理"<br/>"用户关注磁盘空间"
    
    Agent->>TUI: 格式化输出
    Note over TUI: 🔴 磁盘空间警告<br/>📊 使用率统计<br/>💡 清理建议
    
    TUI->>User: 显示彩色输出
    Note over User: ✅ 红色警告<br/>✅ 绿色正常<br/>✅ 黄色建议
```

### 场景3：飞书用户跨会话上下文召回

```mermaid
sequenceDiagram
    autonumber
    actor User as 👨‍💻 开发者
    participant Feishu as 📱 飞书App
    participant Gateway as 🚪 Hermes网关
    participant Agent as 🤖 AIAgent
    participant Search as 🔍 会话搜索
    participant Memory as 💾 持久记忆
    
    Note over User,Memory: 第一天：讨论API设计
    User->>Feishu: "我们决定使用RESTful API还是GraphQL?"
    Feishu->>Gateway: 消息事件
    Gateway->>Agent: 处理询问
    Agent->>Memory: 保存决策
    Note right of Memory: "项目选择RESTful API"<br/>"原因: 团队熟悉度"<br/>"使用Flask框架"
    
    Note over User,Memory: 一周后：继续开发
    User->>Feishu: "继续实现用户认证API"
    Feishu->>Gateway: 新消息事件
    
    Gateway->>Agent: 创建新会话
    Agent->>Search: 搜索相关历史
    Note over Search: query: "API设计"<br/>scope: 用户认证
    
    Search-->>Agent: 找到历史决策
    Note right of Agent: 找到: RESTful API设计<br/>找到: Flask框架选择<br/>找到: 团队讨论记录
    
    Agent->>Agent: 整合上下文
    Note right of Agent: 理解: 已决定RESTful<br/>理解: 使用Flask框架<br/>理解: 需要JWT认证
    
    Agent->>Memory: 更新项目记忆
    Note right of Memory: "开始实现用户认证API"<br/>"使用JWT + Flask"<br/>"参考历史设计决策"
    
    Agent->>Gateway: 提供上下文建议
    Note over Gateway: "基于我们上周的讨论，<br/>我来实现Flask + JWT的用户认证API"
    
    Gateway->>Feishu: 发送响应
    Note right of Feishu: ✅ 展示历史上下文<br/>✅ 提供实现建议<br/>✅ 保持决策一致性
```

### 场景4：TUI用户使用技能系统

```mermaid
sequenceDiagram
    autonumber
    actor User as 🔧 DevOps工程师
    participant TUI as 💻 终端界面
    participant Agent as 🤖 AIAgent
    participant Skills as 📚 技能系统
    participant Tools as 🔧 工具执行
    
    User->>TUI: "帮我部署应用到生产服务器"
    
    TUI->>Agent: 处理请求
    Agent->>Skills: 搜索相关技能
    Note over Skills: 搜索关键词: "部署"、"生产"<br/>找到: "docker-deploy"技能
    
    Skills-->>Agent: 返回技能内容
    Note right of Agent: 技能: Docker生产部署<br/>步骤: 构建→测试→部署<br/>注意事项: 健康检查、回滚
    
    Agent->>Agent: 加载技能指导
    Note right of Agent: 按照技能步骤执行<br/>使用指定的部署脚本<br/>遵循安全检查清单
    
    Agent->>Tools: 执行部署步骤
    Note over Tools: 1. 构建Docker镜像<br/>2. 运行安全扫描<br/>3. 推送到仓库<br/>4. 更新生产服务
    
    Tools-->>Agent: 返回执行结果
    Note right of Agent: ✅ 构建成功<br/>✅ 安全扫描通过<br/>⚠️ 警告: 内存限制过低<br/>✅ 部署完成
    
    Agent->>Skills: 更新技能
    Note right of Skills: 添加新发现的问题<br/>更新最佳实践<br/>记录环境特性
    
    Agent->>TUI: 格式化输出
    Note over TUI: 🚀 部署成功<br/>⚠️ 发现内存问题<br/>💡 技能已更新
    
    TUI->>User: 显示结果
    Note over User: ✅ 按技能标准流程部署<br/>✅ 自动安全检查<br/>✅ 技能自我改进
```

## 平台特性对比

### 飞书平台特性

```mermaid
flowchart LR
    Input[用户输入] --> Format[飞书格式特性]
    
    Format --> Rich[富文本支持]
    Format --> Media[媒体文件]
    Format --> At[@提及功能]
    Format --> Thread[消息线程]
    
    Rich --> Markdown[Markdown渲染]
    Rich --> Emoji[表情支持]
    Rich --> Code[代码高亮]
    
    Media --> Image[图片预览]
    Media --> Video[视频播放]
    Media --> File[文件下载]
    
    At --> User[用户提及]
    At --> Bot[机器人提及]
    At --> All[全体提及]
    
    Thread --> Reply[回复消息]
    Thread --> Quote[引用回复]
    Thread --> Forward[转发消息]
    
    Markdown --> Output[格式化输出]
    Emoji --> Output
    Code --> Output
    Image --> Output
    Video --> Output
    File --> Output
    User --> Output
    Bot --> Output
    All --> Output
    Reply --> Output
    Quote --> Output
    Forward --> Output
```

### TUI平台特性

```mermaid
flowchart LR
    Input[用户输入] --> Format[TUI格式特性]
    
    Format --> Simple[简洁文本]
    Format --> Color[彩色输出]
    Format --> Progress[进度显示]
    
    Simple --> Plain[纯文本]
    Simple --> Table[表格对齐]
    Simple --> List[列表格式]
    
    Color --> Red[红色错误]
    Color --> Green[绿色成功]
    Color --> Yellow[黄色警告]
    Color --> Blue[蓝色信息]
    
    Progress --> Bar[进度条]
    Progress --> Spinner[旋转图标]
    Progress --> Step[步骤显示]
    
    Plain --> Output[终端输出]
    Table --> Output
    List --> Output
    Red --> Output
    Green --> Output
    Yellow --> Output
    Blue --> Output
    Bar --> Output
    Spinner --> Output
    Step --> Output
```

## 性能对比分析

### 响应时间对比

```
飞书消息处理: ~2-5秒
- 平台适配: 100ms
- 网关路由: 50ms  
- 会话加载: 200ms
- Agent执行: 1-3秒
- 响应格式化: 100ms
- 平台投递: 200ms

TUI命令处理: ~1-3秒
- 命令解析: 50ms
- 直接调用: 0ms
- 会话加载: 150ms
- Agent执行: 0.5-2秒
- 终端输出: 50ms
- 界面渲染: 100ms
```

### 并发处理能力

```mermaid
flowchart LR
    Load[负载类型] --> Gateway[Gateway网关]
    Load --> TUI[TUI界面]
    
    Gateway --> G1[支持100+并发会话]
    Gateway --> G2[自动负载均衡]
    Gateway --> G3[Agent缓存复用]
    
    TUI --> T1[单用户顺序处理]
    TUI --> T2[直接访问Agent]
    TUI --> T3[无网络延迟]
    
    G1 --> Perf[性能优势]
    G2 --> Perf
    G3 --> Perf
    
    T2 --> Simp[简洁优势]
    T3 --> Simp
    
    Perf --> Conclusion[Gateway: 高并发<br/>TUI: 低延迟]
    Simp --> Conclusion
```

## 用户体验优化

### 飞书体验优化

```mermaid
flowchart TD
    Input[用户输入] --> Detect{检测意图}
    
    Detect -->|简单问题| Quick[快速回复]
    Detect -->|复杂任务| Progress[进度展示]
    Detect -->|文件操作| Preview[文件预览]
    
    Quick --> Immediate[立即响应]
    Progress --> Steps[分步执行]
    Steps --> Update[实时更新]
    
    Preview --> ShowFile[显示文件内容]
    ShowFile --> Suggest[建议操作]
    
    Immediate --> Output[优化输出]
    Update --> Output
    Suggest --> Output
    
    Output --> Features[飞书特性]
    Features --> RichMedia[富文本+媒体]
    Features --> Interactive[交互按钮]
    Features --> Contextual[上下文感知]
    
    RichMedia --> UX[用户体验]
    Interactive --> UX
    Contextual --> UX
```

### TUI体验优化

```mermaid
flowchart TD
    Input[用户输入] --> Analyze{分析命令}
    
    Analyze -->|查询命令| Direct[直接执行]
    Analyze -->|交互任务| Confirm[确认提示]
    Analyze -->|长时间任务| Background[后台执行]
    
    Direct --> Fast[快速响应]
    Confirm --> Choice[用户选择]
    Background --> Progress[进度显示]
    
    Fast --> Colorize[彩色输出]
    Choice --> Adaptive[自适应建议]
    Progress --> Realtime[实时反馈]
    
    Colorize --> Output[终端输出]
    Adaptive --> Output
    Realtime --> Output
    
    Output --> Features[TUI特性]
    Features --> Syntax[语法高亮]
    Features --> Table[表格格式]
    Features --> Compact[紧凑显示]
    
    Syntax --> UX[用户体验]
    Table --> UX
    Compact --> UX
```

## 故障处理对比

### 飞书故障处理

```mermaid
flowchart TD
    Error[错误发生] --> Type{错误类型}
    
    Type -->|网络错误| Retry[自动重试]
    Type -->|API错误| Fallback[降级处理]
    Type -->|用户错误| Guide[引导纠正]
    
    Retry --> Notify[通知用户]
    Fallback --> Notify
    Guide --> Notify
    
    Notify --> Platform[飞书平台特性]
    Platform --> Async[异步处理]
    Platform --> Media[媒体重传]
    Platform --> Context[上下文保持]
    
    Async --> Recovery[故障恢复]
    Media --> Recovery
    Context --> Recovery
```

### TUI故障处理

```mermaid
flowchart TD
    Error[错误发生] --> Type{错误类型}
    
    Type -->|命令错误| Correct[自动纠正]
    Type -->|权限错误| Suggest[建议提权]
    Type -->|执行错误| Debug[调试信息]
    
    Correct --> Fix[直接修复]
    Suggest --> Solution[提供解决方案]
    Debug --> Detail[详细错误信息]
    
    Fix --> Terminal[TUI特性]
    Solution --> Terminal
    Detail --> Terminal
    
    Terminal --> Immediate[立即反馈]
    Terminal --> Interactive[交互式修复]
    Terminal --> Verbose[详细日志]
    
    Immediate --> Recovery[故障恢复]
    Interactive --> Recovery
    Verbose --> Recovery
```

## 总结

### 平台选择建议

**使用飞书平台**:
- 需要富文本和媒体支持
- 团队协作和讨论
- 异步沟通
- 文件共享和预览

**使用TUI界面**:
- 快速命令执行
- 系统管理任务
- 开发和调试
- 低延迟要求

### 最佳实践

1. **飞书**: 利用平台特性提升体验
2. **TUI**: 最大化终端效率和简洁性
3. **混合**: 根据任务特点选择合适入口
4. **一致**: 保持核心功能和记忆的同步

Hermes Agent 的多入口设计为不同场景提供了最优的交互方式，用户可以根据具体需求选择最合适的界面。
