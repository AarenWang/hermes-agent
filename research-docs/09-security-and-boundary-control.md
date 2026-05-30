# Hermes Agent 调研 09：安全与边界控制

## 1. 这篇文档关注什么

前面的调研已经多次提到 Hermes 有不少安全相关机制：

- 危险命令审批
- 路径安全检查
- URL 安全检查
- skills / cron prompt 扫描
- gateway 侧授权与审批

但这些机制如果只按“功能清单”去看，很容易误读成一句话：

“Hermes 有很多安全防护，所以它本身就是安全边界。”

实际上，Hermes 在 `SECURITY.md` 里给出的立场恰恰更严格：

- 真正的安全边界是操作系统级隔离
- Agent 进程内的大部分防护都只是启发式保护
- 这些启发式保护很有价值，但不能被误当作 containment

这篇文档重点回答六个问题：

1. Hermes 到底把什么当作真正的安全边界。
2. 进程内的 approval / scan / redact / guardrail 各自解决什么问题。
3. 文件、URL、路径、skills、cron 等输入面是如何被约束的。
4. Gateway / ACP / TUI / dashboard 这些外部 surface 的授权模型是什么。
5. Plugin 与 skill 为什么被明确视为“高信任代码”。
6. 这套设计的优点、代价和盲区分别是什么。

---

## 2. 关键文件

核心文件：

- `SECURITY.md`
- `tools/approval.py`
- `tools/path_security.py`
- `tools/url_safety.py`
- `agent/file_safety.py`
- `agent/tool_guardrails.py`
- `tools/terminal_tool.py`

辅助但重要的文件：

- `tools/skills_tool.py`
- `tools/cronjob_tools.py`
- `gateway/platforms/`
- `acp_adapter/`
- `tui_gateway/`

---

## 3. Hermes 的核心安全判断

Hermes 的安全设计里，最重要的一句话不是“有审批”，而是：

“只有 OS-level isolation 才算真正边界。”

`SECURITY.md` 的立场很明确：

- agent 进程内的任何字符串检查、审批 gate、redaction、skill 扫描，都不是 adversarial LLM 的真正 containment
- 如果 LLM 的输出或输入面本身是敌对的，进程内启发式不能被视为充分防线
- 真正 load-bearing 的边界只有两种
  - terminal-backend isolation：只把 shell / file-tool 这类走终端后端的行为隔离出去
  - whole-process wrapping：把整个 agent 进程树一起包进容器或 sandbox

这是一种很成熟的姿态，因为它主动拒绝把“正则审批器”吹成安全沙箱。

也因此，Hermes 把安全分成了两层：

- 第一层是真边界：OS、容器、远程 host、云 sandbox、whole-process wrapper
- 第二层是事故预防：审批、扫描、denylist、路径校验、输出脱敏

这两层并不冲突，但职责完全不同。

---

## 4. 真正边界在哪里

### 4.1 Terminal-backend isolation

Hermes 的 `terminal()` 工具并不只支持本地执行，还支持：

- local
- docker
- ssh
- modal
- daytona
- singularity
- vercel sandbox

这意味着 Hermes 可以把 shell 命令和文件工具背后的实际执行环境切到受限后端。

这种隔离能约束的是：

- shell 命令
- 基于 shell 契约实现的文件工具

但它约束不了的也很明确：

- agent 进程内 Python 代码
- plugin 导入与 hook 执行
- skill 导入
- MCP 子进程
- code-execution tool 的宿主进程路径

所以 terminal backend sandbox 不是“整个 Hermes 被隔离”，而只是“走这个后端的能力被隔离”。

### 4.2 Whole-process wrapping

`SECURITY.md` 认为更稳妥的姿态是 whole-process wrapping，也就是把整个 Hermes 进程树放进统一 sandbox。

这时被一起约束的才包括：

- shell
- file tools
- MCP
- plugin
- skill
- code execution

这条判断非常关键，因为它解释了为什么 Hermes 一边有很多 in-process guard，一边仍然公开说：

- 不要把这些 guard 当成最终边界
- 真正 ingest 不受控输入时，建议 whole-process sandbox

---

## 5. 进程内防护的真实角色

### 5.1 approval gate 是事故预防，不是 containment

`tools/approval.py` 是危险命令系统的单一事实来源，负责：

- 危险命令模式检测
- session 级审批状态
- CLI 与 gateway 两套审批流
- smart approval
- permanent allowlist

它内部又分了三层：

- hardline blocklist：像 `rm -rf /`、`mkfs`、向裸块设备写入、fork bomb、shutdown / reboot 这类“无恢复路径”操作，直接作为底线阻断
- dangerous patterns：像 `curl|sh`、写入敏感路径、删除高风险目录这类，需要审批
- smart approval：可选地让辅助模型帮忙判断低风险命令是否可自动放行

这套设计的优点是：

- 它不把所有危险操作都一刀切禁掉
- 它支持 session 范围、永久 allowlist、gateway 异步审批、cron 特殊模式
- 它把“完全不可接受”和“高风险但可能有正当需求”的命令分层了

但 Hermes 自己也承认它不是边界，因为：

- shell 语义过于复杂，denylist 永远不完备
- smart approval 本质仍是 LLM 审一个 LLM 产物
- 用户批准的是字符串，不是受验证的真实 side effect

换句话说，approval 系统擅长防“合作模式下的误伤”，不擅长提供对抗式 containment。

### 5.2 tool guardrail 更像执行正确性保护

`agent/tool_guardrails.py` 处理的是另一类问题：

- 同一工具失败重试过多
- idempotent 工具无进展循环
- 相同参数重复调用

这层 guardrail 主要防的是：

- tool-call 死循环
- 空转
- 无进展重试

它和“安全边界”关系不大，更接近运行时自稳机制。

从安全视角看，它的价值在于减少 agent 在异常状态下持续尝试敏感能力，但它本身不是权限控制。

---

## 6. 文件与路径安全怎么分层

Hermes 在文件相关安全上不是一个点，而是几层叠加。

### 6.1 path traversal：先防明显逃逸

`tools/path_security.py` 提供的是最通用的路径安全原语：

- `has_traversal_component()`：快速检查路径字符串里有没有 `..`
- `validate_within_dir()`：通过 `resolve() + relative_to()` 确认真实路径是否仍在允许根目录内

这层很朴素，但很重要，因为很多工具都共享这类需求：

- skills
- cron
- credential files
- hub 下载内容

它的角色是统一“路径不能逃出允许根目录”这一类基础规则。

### 6.2 file safety：对高敏感写入做 denylist

`agent/file_safety.py` 处理的是更具体的文件写入风险。

它显式 deny 了一批敏感路径和前缀，例如：

- `~/.ssh/*`
- `~/.aws/`
- `~/.gnupg/`
- `~/.kube/`
- shell rc 文件
- Hermes 自己的 `.env`
- `/etc/passwd`
- `/etc/shadow`
- `/etc/sudoers`

另外它还支持 `HERMES_WRITE_SAFE_ROOT`，把写入范围进一步压到一个安全根目录内。

这层的设计特点是：

- 它不是“文件工具只能读写工作区”
- 而是显式把最危险、最容易造成长期后门或凭据泄漏的区域做 deny

这更像现实工程里的风险最小化，而不是学术化的完全能力隔离。

### 6.3 读保护：防内部缓存反向污染 prompt

`agent/file_safety.py` 还有一个不那么显眼但很有意思的点：

- 会阻止直接读取 Hermes skills hub 的内部缓存目录

原因不是传统意义上的“机密性”，而是：

- 防止 agent 直接把内部索引缓存当普通文本读进 prompt，形成 prompt injection 污染路径

这说明 Hermes 已经把“内部状态文件被再次当上下文吸入模型”视作真实攻击面。

---

## 7. URL 与网络输入面的安全

### 7.1 `url_safety.py` 在防 SSRF

`tools/url_safety.py` 的定位非常明确：

- 阻止访问私网、localhost、link-local、metadata endpoint
- 避免 prompt 或 skill 诱导 agent 去打内部资源

它显式区分了两种层次：

- always-blocked floor：永远禁止的目标，例如 `169.254.169.254`、`metadata.google.internal`
- ordinary private blocking：默认阻止私网 / loopback / 保留地址，但允许用户通过 `security.allow_private_urls` 配置关闭

这层做得比较成熟的地方有两个：

1. 它承认 DNS rebinding 这类问题无法靠 pre-flight 检查彻底解决。
2. 它把 metadata endpoint 当成“无条件红线”，即使用户开启 allow-private 也不放。

这体现出 Hermes 区分了：

- “企业 / 家庭网络里有时必须访问私网资源”
- “云 metadata endpoint 几乎没有正当 agent 使用场景”

### 7.2 它解决了什么，没解决什么

它能解决的是：

- 最常见 SSRF 误打
- 明显的私网 / 本地 / metadata 访问
- 一部分通过普通 URL 工具进入的内部网络探测

它解决不了的是：

- 完全意义上的连接级 TOCTOU / DNS rebinding
- 第三方 SaaS web 工具服务端内部的跳转与抓取行为

所以它依然属于“高价值 guard”，不是最终边界。

---

## 8. skills 与 cron 为什么被单独盯防

### 8.1 skills：不是普通文档，而是潜在执行入口

`tools/skills_tool.py` 很清楚地把 skills 当成高风险输入面。

它做了几件事：

- 对 skill 内容做 prompt injection 模式扫描
- 对 skill 内部特定文件读取做路径校验
- 对平台兼容、前置依赖、secret capture 做显式处理

但更关键的是，`SECURITY.md` 的立场并不是“扫描通过就可信”，而是：

- skill 扫描只是 review aid
- 第三方 skill 的真正边界是 operator review before install

这很重要，因为 skill 不只是 markdown 指南，它可能带：

- 脚本
- 模板
- 辅助文件

而且 skill 加载本身就可能影响 agent 行为。

所以 Hermes 没有把 skills guard 描述成“skill sandbox”，而是把它定位成：

- 安装前的粗筛
- 运行时的最小保护
- 不能替代人工审查

### 8.2 cron：因为它在 fresh session 中自动运行

`tools/cronjob_tools.py` 有专门的 cron prompt threat scan。

这里的风险比普通对话 prompt 更高，因为：

- cron job 会自动跑
- 通常在 fresh session 中启动
- 可能拥有完整工具面
- 没有即时人工纠偏

因此它只盯 critical-severity 模式，例如：

- ignore previous instructions
- do not tell the user
- system prompt override
- 读 secrets
- 改 `authorized_keys`
- 改 `sudoers`
- 明显 exfiltration 命令

这种做法的含义是：

- cron prompt 被视为“自动化执行入口”
- 所以要比普通用户消息更保守

同时，`approval.py` 对 cron 也单独做了 `approvals.cron_mode` 处理，避免把等待人工审批的逻辑错误地落到无人值守作业里。

---

## 9. Plugin / Skill trust model 的边界非常明确

这是 Hermes 安全观里最容易被忽视、但其实最成熟的一点：

- plugin 被视为高信任本地代码
- skill 也不能被简单视为纯文本提示

`SECURITY.md` 明说：

- plugin 运行在 agent 进程内，拥有与 core 几乎同等的能力
- skill / plugin 的主要防线是安装前的 operator review
- 恶意第三方 plugin 本身不自动构成 Hermes 漏洞

这其实把责任链说得很清楚：

- Hermes 负责让安装、发现、授权路径尽量透明
- 但不承诺把第三方扩展变成受限沙箱

对于一个高度可扩展的 agent 平台，这是比“我们会过滤一下插件”更诚实也更稳的说法。

---

## 10. 外部 surface 的授权模型

Hermes 的另一个重点不是“模型会不会乱说”，而是：

“谁能给 agent 下指令、看输出、点批准按钮？”

`SECURITY.md` 把外部 surface 统一归为四类：

- gateway 平台适配器
- network-exposed HTTP surfaces
- editor / IDE adapters
- TUI gateway

它的统一规则很值得注意。

### 10.1 每个跨信任边界的 surface 都必须有授权

对于网络 surface：

- 要求 operator-configured allowlist

对于本地 IPC / editor surface：

- 默认依赖 OS 账户与 loopback / 文件权限

这个划分很务实，因为 ACP / 本地 TUI gateway 和公网 webhook 面临的威胁模型并不一样。

### 10.2 session id 只是路由句柄，不是授权凭据

这条规则很关键：

- session identifier 负责路由到哪个会话
- 但不能因为知道 session id 就拥有该会话的审批权或输出读取权

这说明 Hermes 明确区分了：

- “我知道你的会话编号”
- “我被授权操作你的会话”

### 10.3 同一 allowlist 内默认等权

Hermes 不在单一 adapter 内建更细粒度 capability separation。

这意味着：

- 它的默认模型更像“单租户 personal agent”
- 如果要做更细的角色隔离，推荐分实例部署

这也和它在 `SECURITY.md` 里声明的 single-tenant posture 是一致的。

---

## 11. 这套设计最值得学习的点

### 11.1 明确区分 boundary 和 heuristic

很多 agent 项目最大的问题不是 guard 太少，而是把 heuristic 讲成 boundary。

Hermes 在这点上做得非常清楚：

- OS sandbox 才是边界
- approval / scan / redact / guard 只是防误伤层

这使它的安全叙述比较不容易自欺欺人。

### 11.2 风险按输入面和执行面分层处理

Hermes 不是拿一个总开关解决所有风险，而是按风险类型拆层：

- shell 风险：approval + terminal backend
- 文件风险：path validation + write denylist
- URL 风险：SSRF guard
- skill / cron 风险：injection / exfiltration scan
- 外部入口风险：allowlist + OS-local trust

这种分层比“统一做一个安全模块”更贴近真实系统。

### 11.3 自动化入口比普通对话入口更严格

cron 的特殊扫描、gateway 审批队列、外部 surface allowlist，都说明 Hermes 明白：

- 长期运行、异步执行、远程触达

才是真正把 agent 从 demo 推向产品时的危险区。

---

## 12. 这套设计的代价与盲区

### 12.1 启发式永远不完备

这是 Hermes 自己承认的事实。

所以你不能指望：

- dangerous command regex 覆盖所有 shell 变体
- prompt injection 字样扫描发现所有绕过
- redaction 阻止真正有动机的 secret exfiltration

### 12.2 terminal backend sandbox 不是全系统 sandbox

如果 operator 误以为：

- “我把 terminal 切到 container 里了，所以整套 Hermes 都安全了”

那就是理解错误。

plugin、skill、MCP、code execution 等路径依然可能运行在 agent 自身信任域内。

### 12.3 单租户心智不适合直接外推到多租户

Hermes 的 trust model 很明显是 single-tenant personal agent。

因此它默认并不提供：

- 单 adapter 内的细粒度 capability RBAC
- 多用户强隔离
- 第三方扩展的强约束执行环境

如果未来要做 shared deployment，这一层需要更重的外部治理与隔离。

### 12.4 URL safety 仍停留在 pre-flight 层

这足以挡掉大量常见 SSRF，但对连接级攻击并不充分。

如果部署环境真的把“不能访问任何私网资源”当硬边界，那仍需要：

- egress proxy
- 网络策略
- whole-process sandbox

---

## 13. 对通用 Agent 框架的启发

从通用 Agent 框架角度，Hermes 的安全层最值得学的不是某个正则，而是三条原则。

### 13.1 不要把审批器当沙箱

审批器可以极大减少误操作，但它不是 adversarial containment。

### 13.2 输入面和执行面要分别建模

安全问题不只来自“执行了危险命令”，也来自：

- 读入了被污染的上下文
- 开放了未授权的外部入口
- 把高信任扩展当成低信任内容来处理

### 13.3 必须有清晰的 trust model 文档

Hermes 的一个优点是，它把哪些算边界、哪些不算、哪些 in scope、哪些 out of scope 明文写出来了。

这会直接改善：

- operator 预期
- 安全报告质量
- 架构讨论的准确度

---

## 14. 建议阅读顺序

建议按这个顺序读：

1. `SECURITY.md`
2. `tools/approval.py`
3. `tools/terminal_tool.py`
4. `agent/file_safety.py`
5. `tools/path_security.py`
6. `tools/url_safety.py`
7. `tools/skills_tool.py`
8. `tools/cronjob_tools.py`
9. `gateway/platforms/` 中任一带审批 / allowlist 逻辑的平台适配器

这样读的好处是：

- 先建立 trust model
- 再看执行前 guard
- 再看输入面防护
- 最后回到外部 surface

---

## 15. 本篇结论

Hermes 的安全设计最值得学习的地方，不是“有很多防护”，而是它对防护层级的认识比较清醒：

- 真正边界是 OS-level isolation
- 进程内 guard 主要负责减少误伤和提高默认安全性
- 外部 surface 的授权与 allowlist 是产品化运行的刚需
- plugin / skill 必须按高信任扩展对待，而不是假装它们只是提示词

如果把 Hermes 看成一个通用 Agent 平台，它在安全上的核心贡献不是发明了某种神奇防线，而是比较完整地回答了：

“一个可执行、可扩展、可远程触达的 Agent，哪些东西必须由系统边界解决，哪些东西只能作为启发式辅助。”
