# Hermes 在 WSL Ubuntu 的 Fork 拉取式部署工作流

## 问题定义

当前目标是建立这样一条工作流：

1. `~/.hermes/hermes-agent` 确认为官方仓库源码 checkout
2. 将官方仓库 fork 到个人 GitHub 账户
3. 在 Windows 本地仓库里开发、提交、push 到个人 fork
4. 在 WSL 的 `~/.hermes/hermes-agent` 里执行 `git pull`
5. 重启 Hermes，使修改生效

这个方案是可行的，但要注意一个关键前提：

> `WSL` 里的 `~/.hermes/hermes-agent` 只有在 remote 指向你的 fork，或者你显式从你的 fork 拉取时，`git pull` 才会拿到你的改动。

## 结论先行

这个方案可以成立，而且比“每次从 Windows rsync 覆盖到 WSL”更适合长期开发。

推荐的最佳实践是：

- Windows 本地仓库负责开发与 push
- WSL 安装目录负责 pull 与运行
- 官方仓库保留为 `upstream`
- 个人 fork 作为 `origin` 或 `myfork`

从长期维护角度看，这比直接修改 `~/.hermes/hermes-agent` 更清晰。

## 方案成立的前提

### 前提一：WSL 安装目录确实是 git checkout

根据 installer 的实现，普通用户安装模式下：

- 代码默认安装在 `~/.hermes/hermes-agent`
- 安装过程使用 `git clone`
- 已存在时会 `git fetch` / `git pull`

所以 `~/.hermes/hermes-agent` 通常就是一个 Git 工作树，而不是纯二进制目录。

### 前提二：WSL 里的 remote 需要能指向你的 fork

如果 WSL 里的仓库仍然是：

- `origin = 官方仓库`

那么你在 Windows push 到个人 fork 后，WSL 里直接执行：

```bash
git pull
```

拿到的仍然是官方仓库的更新，而不是你的 fork。

因此必须做下面两种选择之一：

1. 把 `origin` 改成你的 fork
2. 保留 `origin` 指向官方，再额外增加一个 `myfork` remote

## 推荐方案

推荐使用：

- Windows 开发仓库：
  - `origin` = 你的 fork
  - `upstream` = 官方仓库
- WSL 运行仓库：
  - `origin` = 官方仓库
  - `myfork` = 你的 fork

这样做的好处是：

- Windows 开发流程最符合 GitHub fork 常规习惯
- WSL 运行环境仍然保留对官方仓库的清晰认知
- 后续你仍然可以选择从官方拉，或从个人 fork 拉
- 不会把 installer / `hermes update` 的默认语义完全混淆

## Windows 侧标准配置

假设你已经 fork 了官方仓库到：

```text
git@github.com:<yourname>/hermes-agent.git
```

在 Windows 的开发仓库里，推荐配置为：

```bash
git remote rename origin upstream
git remote add origin git@github.com:<yourname>/hermes-agent.git
git remote -v
```

理想结果：

```text
origin   git@github.com:<yourname>/hermes-agent.git
upstream https://github.com/NousResearch/hermes-agent.git
```

之后开发流程就是：

```bash
git checkout -b my-feature
git add .
git commit -m "..."
git push -u origin my-feature
```

如果你是直接把变更部署到 WSL 而不是走 PR，也可以 push 到：

- `origin main`
- 或单独一个长期部署分支，例如 `origin deploy`

## WSL 侧标准配置

先检查当前 remote：

```bash
cd ~/.hermes/hermes-agent
git remote -v
```

如果当前 `origin` 还是官方仓库，推荐保留它，并新增你的 fork：

```bash
git remote add myfork git@github.com:<yourname>/hermes-agent.git
git fetch myfork
git remote -v
```

这样 WSL 里就会有两条来源：

- `origin` = 官方
- `myfork` = 你的 fork

## WSL 部署拉取方式

### 方式一：显式从 fork 拉取

这是最推荐的方式：

```bash
cd ~/.hermes/hermes-agent
git pull myfork main
```

优点：

- 语义明确
- 不会误以为自己拉的是官方
- 不需要修改 `origin`

如果你用的是部署分支，例如 `deploy`：

```bash
git pull myfork deploy
```

### 方式二：把 WSL 的 origin 改成你的 fork

如果你坚持想在 WSL 里直接用最短命令：

```bash
git pull
```

那就要把 `origin` 切到你的 fork：

```bash
git remote set-url origin git@github.com:<yourname>/hermes-agent.git
git fetch origin
git remote -v
```

这样以后 plain `git pull` 才会拉你的代码。

缺点是：

- `origin` 不再代表官方仓库
- 后续如果你忘了这一点，容易误判更新来源

因此不如保留 `origin=官方`、新增 `myfork` 那么清晰。

## 标准部署流程

推荐使用下面这条完整链路。

### 第一步：Windows 开发并 push

```bash
git add .
git commit -m "your change"
git push origin my-feature
```

如果你想让 WSL 直接跟这个分支跑，也可以：

```bash
git push origin deploy
```

### 第二步：WSL 拉取 fork 分支

```bash
cd ~/.hermes/hermes-agent
git fetch myfork
git checkout main
git pull myfork main
```

如果走部署分支：

```bash
cd ~/.hermes/hermes-agent
git fetch myfork
git checkout deploy
git pull myfork deploy
```

### 第三步：视改动类型决定是否补安装

#### 仅 Python 代码改动

通常只需要：

1. `git pull`
2. 重启 Hermes

#### 改了 Python 依赖

如果改动涉及：

- `pyproject.toml`
- `uv.lock`
- 新增 Python 包
- 调整 extras

建议在 WSL 补跑：

```bash
cd ~/.hermes/hermes-agent
source venv/bin/activate
uv pip install -e ".[all]"
```

#### 改了前端

如果改动涉及：

- `web/`
- `ui-tui/`

建议补跑：

```bash
cd ~/.hermes/hermes-agent/web
npm install
npm run build

cd ~/.hermes/hermes-agent/ui-tui
npm install
npm run build

mkdir -p ~/.hermes/hermes-agent/hermes_cli/tui_dist
cp -r ~/.hermes/hermes-agent/ui-tui/dist/* ~/.hermes/hermes-agent/hermes_cli/tui_dist/
```

### 第四步：重启 Hermes

如果你只是手动执行 CLI，重新启动命令即可。

如果你在 WSL 里跑的是 gateway，按你的运行方式重启对应进程：

- `tmux`
- `screen`
- 前台 shell
- 其他守护方式

例如：

```bash
tmux kill-session -t hermes
tmux new -d -s hermes 'hermes gateway run'
```

## 什么时候“git pull + 重启”就够

以下情况通常可以：

- 只改 `.py` 文件
- 只改业务逻辑
- 没改依赖
- 没改前端
- 没改 installer / entry point / extras

这时通常只需要：

1. Windows push
2. WSL `git pull myfork ...`
3. 重启 Hermes

## 什么时候“git pull + 重启”不够

以下情况通常不够：

- 改了 `pyproject.toml`
- 改了 `uv.lock`
- 改了 `package.json`
- 改了 `web/`
- 改了 `ui-tui/`
- 新增需要安装的依赖
- 改了生成产物依赖的构建流程

这时必须追加：

- Python 依赖安装
- 前端构建
- 然后再重启

## 与前一方案的关系

上一份文档 `19-wsl-local-deployment-update-plan.md` 给的是：

- 本地目录直接 overlay sync 到 WSL 安装目录

这一份给的是：

- 通过 fork + push + pull 的 Git 工作流部署到 WSL

两者的区别：

- `19` 适合本地临时调试、未提交改动快速同步
- `20` 更适合长期开发、可追踪、可回滚、可多人协作

## 最终建议

如果你接下来要持续在 Windows 开发、WSL 运行，最推荐的工作流是：

1. 官方仓库 fork 到个人账户
2. Windows 本地仓库：
   - `origin = 个人 fork`
   - `upstream = 官方仓库`
3. WSL 安装仓库：
   - `origin = 官方仓库`
   - `myfork = 个人 fork`
4. 开发后：
   - Windows `git push origin <branch>`
   - WSL `git pull myfork <branch>`
   - 必要时补依赖/前端构建
   - 重启 Hermes

这是在“保持 installer 原有结构”和“获得稳定开发部署链路”之间，最平衡的一种方案。

## 已落地脚本

仓库里已经补了一个可直接执行的 PowerShell 脚本：

```powershell
.\scripts\deploy_to_wsl.ps1 -Mode Pull -Branch main
```

这个脚本支持两种模式：

- `-Mode Pull`：按本篇文档的 fork 工作流，在 WSL 安装目录里执行 `git fetch/pull`
- `-Mode Sync`：按上一份文档的 overlay sync 方式，把当前 Windows 仓库直接同步到 WSL 安装目录

常见用法：

```powershell
.\scripts\deploy_to_wsl.ps1 -Mode Pull -Branch main -Push
.\scripts\deploy_to_wsl.ps1 -Mode Pull -Branch main -InstallDeps -RestartGateway
.\scripts\deploy_to_wsl.ps1 -Mode Sync -BuildFrontend
.\scripts\deploy_to_wsl.ps1 -Mode Pull -Branch main -DryRun
```
