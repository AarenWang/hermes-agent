# 本地通过 Python main 运行 Hermes

这份文档解决两个问题：

1. 如何把 WSL Ubuntu 里 `~/.hermes/` 的关键文件复制到当前工程目录下
2. 如何在当前源码目录里通过 Python main 运行，达到接近安装后直接输入 `hermes` 的效果

结论先说：

- 真正等价于安装后输入 `hermes` 的 Python 入口是：

```bash
python -m hermes_cli.main
```

- 不建议用 `python run_agent.py` 代替 `hermes`
  - `run_agent.py` 对应的是 `hermes-agent` 风格入口
  - 交互式 terminal CLI 对应的是 `hermes_cli.main:main`

- 如果你不想手动执行多条命令，可以直接用一键脚本：

```powershell
.\scripts\run_local_hermes_from_wsl.ps1
```

默认行为：

- 从 WSL 的 `~/.hermes/` 复制关键文件到 `./local-hermes-home/`
- 在 WSL 里准备当前源码的 `.venv`
- 安装当前仓库的 editable package
- 用 `python -m hermes_cli.main` 启动

## 1. 从 WSL Ubuntu 复制 `~/.hermes` 关键文件到当前工程目录

建议把复制目标放到当前仓库下的：

```text
./local-hermes-home/
```

这样不会污染你本机真实的 `~/.hermes`。

### 1.1 推荐复制内容

建议复制这些：

- `config.yaml`
- `.env`
- `auth.json`
- `active_profile`
- `SOUL.md`
- `memories/`
- `skills/`
- `profiles/`
- `home/`

说明：

- `config.yaml` 和 `.env` 是最核心配置
- `auth.json` 常用于已登录 provider 的认证状态
- `active_profile` 和 `profiles/` 只在你使用多 profile 时需要
- `home/` 里可能有 git / ssh / gh 等子进程配置；如果你省略它，某些工具行为会和部署机不同
- `logs/`、`sessions/`、数据库、缓存通常不必复制

### 1.2 在 WSL 里执行复制

在 WSL Ubuntu 里执行，假设当前仓库在 Windows 路径：

```text
D:\dev\opensource\hermes-agent
```

对应的 WSL 路径通常是：

```bash
/mnt/d/dev/opensource/hermes-agent
```

执行命令：

```bash
cd /mnt/d/dev/opensource/hermes-agent

mkdir -p local-hermes-home

rsync -a \
  --include='/config.yaml' \
  --include='/.env' \
  --include='/auth.json' \
  --include='/active_profile' \
  --include='/SOUL.md' \
  --include='/memories/***' \
  --include='/skills/***' \
  --include='/profiles/***' \
  --include='/home/***' \
  --exclude='*' \
  ~/.hermes/ ./local-hermes-home/
```

校验复制结果：

```bash
find ./local-hermes-home -maxdepth 3 | sort
```

### 1.3 如果只需要最小可运行配置

如果你只想先跑起来，可以只保留：

- `config.yaml`
- `.env`
- `auth.json`

最小复制命令：

```bash
cd /mnt/d/dev/opensource/hermes-agent
mkdir -p local-hermes-home

cp ~/.hermes/config.yaml ./local-hermes-home/ 2>/dev/null || true
cp ~/.hermes/.env ./local-hermes-home/ 2>/dev/null || true
cp ~/.hermes/auth.json ./local-hermes-home/ 2>/dev/null || true
```

如果你在 WSL 里启用了 profile，再补：

```bash
cp ~/.hermes/active_profile ./local-hermes-home/ 2>/dev/null || true
rsync -a ~/.hermes/profiles/ ./local-hermes-home/profiles/
```

## 2. 在当前源码目录通过 Python main 运行

这里分成两种运行方式。

### 2.1 Windows 本地运行

适合：

- 你要在 Windows 上直接调试当前源码
- 你接受 terminal / process 等工具运行在 Windows，不是 WSL

命令：

```powershell
cd D:\dev\opensource\hermes-agent

py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1

python -m pip install --upgrade pip
python -m pip install -e ".[all]"

$env:HERMES_HOME = (Resolve-Path .\local-hermes-home).Path

python -m hermes_cli.main
```

如果你用的是某个 profile，例如 `coder`：

```powershell
python -m hermes_cli.main -p coder
```

如果你不想依赖 `active_profile`，也可以直接把 `HERMES_HOME` 指向某个 profile 目录：

```powershell
$env:HERMES_HOME = (Resolve-Path .\local-hermes-home\profiles\coder).Path
python -m hermes_cli.main
```

### 2.2 在 WSL 中运行当前源码

适合：

- 你想让 terminal 工具、路径语义、shell 行为尽量接近部署机
- 你希望效果最像 WSL 里安装后的 `hermes`

命令：

```bash
cd /mnt/d/dev/opensource/hermes-agent

python3 -m venv .venv
source .venv/bin/activate

python -m pip install --upgrade pip
python -m pip install -e '.[all]'

export HERMES_HOME="$PWD/local-hermes-home"

python -m hermes_cli.main
```

如果要指定 profile：

```bash
python -m hermes_cli.main -p coder
```

## 3. 这和直接输入 `hermes` 的关系

安装后的命令入口是：

```text
hermes -> hermes_cli.main:main
```

所以：

- `python -m hermes_cli.main`
  - 最接近 `hermes`
- `python run_agent.py`
  - 更接近 `hermes-agent`
  - 不是完整交互式 CLI

## 4. 重要差异

### 4.1 Windows 本地运行时

即使你复制的是 WSL 的 `~/.hermes` 配置，只要你是在 Windows 上执行：

```powershell
python -m hermes_cli.main
```

那么：

- terminal 工具默认在 Windows 执行
- 路径语义是 Windows 路径
- 某些 git / ssh / shell 行为会和 WSL 不同

### 4.2 想要最像部署机的行为

优先用：

```bash
python -m hermes_cli.main
```

并且在 WSL 里执行，而不是在 Windows PowerShell 里执行。

## 5. 推荐操作顺序

1. 在 WSL 把 `~/.hermes` 关键文件复制到 `./local-hermes-home/`
2. 优先先在 WSL 里运行当前源码：

```bash
export HERMES_HOME="$PWD/local-hermes-home"
python -m hermes_cli.main
```

3. 如果确认没问题，再切到 Windows 本地运行做调试

## 6. 快速命令汇总

### 一键脚本

最像部署机运行效果：

```powershell
.\scripts\run_local_hermes_from_wsl.ps1
```

只复制配置，不启动：

```powershell
.\scripts\run_local_hermes_from_wsl.ps1 -Mode CopyOnly
```

复制后在 Windows 本地启动：

```powershell
.\scripts\run_local_hermes_from_wsl.ps1 -Mode Windows
```

指定 WSL 发行版：

```powershell
.\scripts\run_local_hermes_from_wsl.ps1 -WslDistro Ubuntu
```

指定 profile：

```powershell
.\scripts\run_local_hermes_from_wsl.ps1 -Profile coder
```

### WSL 复制配置

```bash
cd /mnt/d/dev/opensource/hermes-agent
mkdir -p local-hermes-home
rsync -a \
  --include='/config.yaml' \
  --include='/.env' \
  --include='/auth.json' \
  --include='/active_profile' \
  --include='/SOUL.md' \
  --include='/memories/***' \
  --include='/skills/***' \
  --include='/profiles/***' \
  --include='/home/***' \
  --exclude='*' \
  ~/.hermes/ ./local-hermes-home/
```

### WSL 运行当前源码

```bash
cd /mnt/d/dev/opensource/hermes-agent
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[all]'
export HERMES_HOME="$PWD/local-hermes-home"
python -m hermes_cli.main
```

### Windows 本地运行当前源码

```powershell
cd D:\dev\opensource\hermes-agent
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -e ".[all]"
$env:HERMES_HOME = (Resolve-Path .\local-hermes-home).Path
python -m hermes_cli.main
```
