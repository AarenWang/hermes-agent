# Hermes 在 WSL Ubuntu 的本地改动快速更新方案

## 背景

当前场景是：

- 你已经在 `WSL Ubuntu` 里通过
  `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash`
  安装了 Hermes。
- 当前 Windows 工作目录里的仓库代码已经有本地修改。
- 你希望把这些“当前目录下的修改”尽快部署到 WSL Ubuntu 的 Hermes 安装中。

这个场景和 `hermes update` 不完全一样：

- `hermes update` 适合从 `origin/main` 拉最新代码并重装依赖。
- 它不适合“把你当前本地未提交/未推送的改动”部署到 WSL 安装。

## 先确认安装布局

根据官方安装文档和 `scripts/install.sh`：

- per-user git installer 的代码目录默认是 `~/.hermes/hermes-agent/`
- `hermes` 命令入口默认是 `~/.local/bin/hermes`
- 这个 launcher 最终指向 `~/.hermes/hermes-agent/venv/bin/hermes`

也就是说，WSL 里的运行时代码通常在：

```bash
~/.hermes/hermes-agent
```

## 结论先行

推荐方案是：

1. 把当前仓库内容同步覆盖到 WSL 的 `~/.hermes/hermes-agent`
2. 仅在需要时补做依赖安装 / 前端构建
3. 重启当前正在跑的 Hermes 进程

这是最稳妥的方案，因为它：

- 保持 installer 的目录结构不变
- 不破坏 `hermes update` 的后续使用
- 不要求你把 WSL 运行时直接绑到 `/mnt/d/...` 这种跨文件系统路径
- 对纯 Python 改动来说非常快

## 推荐方案：Overlay Sync 到现有安装

### 适用场景

适用于绝大多数本地开发和验证场景，尤其是：

- 改了 `run_agent.py`、`cli.py`、`agent/`、`tools/`、`gateway/` 等 Python 代码
- 改了内置技能、文档、模板、静态资源
- 希望 WSL 运行环境仍然保持“官方 installer 布局”

### 核心思路

WSL 安装本身已经是一个 editable install 风格的运行目录。

因此：

- 如果你只是把文件同步到 `~/.hermes/hermes-agent`
- 且没有改 `pyproject.toml` / 依赖声明 / entry points

通常**不需要重新创建 venv**
，很多情况下甚至**不需要重新执行 `pip install -e`**
，只需要重启正在跑的 Hermes 进程即可生效。

### 推荐操作步骤

#### 1. 从 Windows 当前仓库同步到 WSL 安装目录

如果当前仓库在 Windows 侧，例如：

```text
D:\dev\opensource\hermes-agent
```

在 Windows PowerShell 中可以走这条思路：

```powershell
$RepoWin = (Get-Location).Path
$RepoWsl = (wsl.exe wslpath -a $RepoWin).Trim()

wsl.exe -d Ubuntu -- bash -lc @"
set -e
SRC='$RepoWsl'
DST='$HOME/.hermes/hermes-agent'

mkdir -p "$DST"
rsync -a --delete \
  --exclude '.git' \
  --exclude '.venv' \
  --exclude 'venv' \
  --exclude 'node_modules' \
  --exclude '__pycache__' \
  --exclude '.pytest_cache' \
  --exclude 'dist' \
  --exclude 'build' \
  --exclude '.mypy_cache' \
  --exclude '.ruff_cache' \
  "$SRC/" "$DST/"
"@
```

这里 `rsync --delete` 的含义是：

- 让 WSL 安装目录尽量与当前仓库一致
- 删除已经在本地仓库中消失的旧文件

如果你担心误删，也可以先去掉 `--delete`，确认无误后再加。

#### 2. 判断是否需要补装依赖

下面这些改动，建议在同步后补跑一次：

- `pyproject.toml`
- `uv.lock`
- `package.json`
- `web/`
- `ui-tui/`
- 新增了 Python package / 新增了 entry point / 新增了 extras 依赖

如果只是普通 Python 逻辑改动，通常可以跳过。

#### 3. 需要时重装 Python 依赖

在 WSL 里执行：

```bash
cd ~/.hermes/hermes-agent
source venv/bin/activate
uv pip install -e ".[all]"
```

这是和现有文档、`hermes update` 行为最一致的更新方式。

如果你想更贴近 installer 的 locked 安装方式，也可以用：

```bash
cd ~/.hermes/hermes-agent
UV_PROJECT_ENVIRONMENT="$PWD/venv" uv sync --extra all --locked
```

但从“快速更新本地改动”的角度，`uv pip install -e ".[all]"` 更直接。

#### 4. 如果改了 dashboard / TUI，再补前端构建

如果修改涉及：

- `web/`
- `ui-tui/`
- `hermes_cli/web_dist`
- `hermes_cli/tui_dist`

建议在 WSL 里补构建：

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

备注：

- dashboard 的 web 产物会进 `hermes_cli/web_dist`
- TUI 的源码构建产物默认在 `ui-tui/dist`
- 如果只改 Python，不需要做这一步

#### 5. 重启运行中的 Hermes

如果只是手动运行 CLI，重新启动即可。

如果你跑的是 gateway，需要重启相应进程。

WSL 官方文档里更推荐前台运行或用 `tmux` 托管，因此常见做法是：

```bash
tmux kill-session -t hermes
tmux new -d -s hermes 'hermes gateway run'
```

如果你不是用 `tmux`，就按你当前的启动方式重启对应进程。

## 什么时候可以“只同步文件，不重装依赖”

满足下面条件时，通常可以：

- 只改了 `.py` 文件
- 没改 `pyproject.toml`
- 没改前端依赖
- 没新增需要安装的外部包
- 当前运行的只是 CLI / gateway Python 逻辑

这时通常只需要：

1. `rsync` 覆盖代码
2. 重启 Hermes 进程

## 什么时候必须补 `uv pip install -e ".[all]"`

出现以下任一情况时，建议补跑：

- 改了 `pyproject.toml`
- 改了 extras / dependency groups
- 改了 console entry points
- 新增了以前没安装过的依赖
- 改动触发 `ModuleNotFoundError`
- 你不确定当前 venv 是否和代码状态一致

## 什么时候必须补前端构建

出现以下情况时，建议补跑前端构建：

- 改了 `web/`
- 改了 `ui-tui/`
- 改了 dashboard 的 React/Vite 代码
- 改了 TUI 的 Ink / TypeScript 代码

## 可选方案二：让 WSL 直接跑当前仓库

### 思路

不再把代码同步到 `~/.hermes/hermes-agent`，而是直接让 WSL 使用当前仓库路径，例如：

```bash
/mnt/d/dev/opensource/hermes-agent
```

这样你每次改 Windows 仓库文件，WSL 立刻看到最新代码，不需要再 `rsync`。

### 优点

- 开发时最快
- 不需要每次复制文件

### 缺点

- `/mnt/d/...` 上的 Linux 文件 IO 性能通常差于 WSL 原生文件系统
- 容易和当前 installer 布局分叉
- 后续 `hermes update` 的语义会变得不清晰
- Windows 侧生成的缓存/权限/换行符问题更容易混入

### 判断

适合“高频开发调试”，不适合作为长期稳定部署方案。

## 可选方案三：只同步少量文件

如果只是临时热修一个或几个文件，也可以直接 copy：

```bash
cp /mnt/d/dev/opensource/hermes-agent/run_agent.py ~/.hermes/hermes-agent/run_agent.py
cp -r /mnt/d/dev/opensource/hermes-agent/agent ~/.hermes/hermes-agent/
```

但这种方式的问题是：

- 很容易漏文件
- 删除/重命名文件时不可靠
- 不适合持续开发

所以更适合一次性热修，不适合作为标准流程。

## 推荐的标准工作流

如果目标是“当前目录改动快速部署到 WSL”，建议固定为下面这条：

1. Windows 当前仓库作为开发源
2. PowerShell 一键 `rsync` 到 `~/.hermes/hermes-agent`
3. 若改了依赖，补 `uv pip install -e ".[all]"`
4. 若改了前端，补 `npm run build`
5. 重启 WSL 中运行的 Hermes

## 建议后续脚本化

这套流程非常适合固化成一个脚本，例如：

- `scripts/deploy_to_wsl.sh`
- `scripts/deploy_to_wsl.ps1`

脚本职责建议包括：

1. 自动把当前 Windows 路径转成 WSL 路径
2. 自动 `rsync` 到 `~/.hermes/hermes-agent`
3. 可选参数：
   - `--deps`
   - `--web`
   - `--restart`
   - `--wsl-distro Ubuntu`
4. 默认只做“代码同步”
5. 需要时再显式触发依赖安装 / 前端构建 / gateway 重启

## 最终建议

对于你当前这个场景，最推荐的是：

- **短期立刻可用**：用 `rsync` 把当前仓库同步到 `~/.hermes/hermes-agent`
- **依赖没变时**：只重启 Hermes
- **依赖变了时**：补 `uv pip install -e ".[all]"`
- **前端变了时**：再补 `npm install && npm run build`

这是对现有 installer 布局侵入最小、成功率最高、后续也最容易脚本化的方案。

