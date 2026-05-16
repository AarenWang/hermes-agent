[CmdletBinding()]
param(
    [ValidateSet("Pull", "Sync")]
    [string]$Mode = "Pull",
    [string]$WslDistro = "Ubuntu",
    [string]$TargetDir = "~/.hermes/hermes-agent",
    [string]$Remote = "myfork",
    [string]$Branch = "",
    [switch]$Push,
    [string]$PushRemote = "origin",
    [switch]$InstallDeps,
    [switch]$BuildFrontend,
    [switch]$RestartGateway,
    [string]$TmuxSession = "hermes",
    [string]$GatewayCommand = "hermes gateway run",
    [switch]$NoDelete,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "WARN $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "ERR  $Message" -ForegroundColor Red
}

function Test-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Command)
    return [bool](Get-Command -Name $Command -ErrorAction SilentlyContinue)
}

function Quote-Bash {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "'""'""'") + "'"
}

function Convert-WindowsPathToWslPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath -notmatch '^(?<drive>[A-Za-z]):\\(?<rest>.*)$') {
        throw "Only drive-letter paths are supported for Sync mode: $fullPath"
    }

    $drive = $Matches.drive.ToLowerInvariant()
    $rest = $Matches.rest -replace '\\', '/'
    if ([string]::IsNullOrWhiteSpace($rest)) {
        return "/mnt/$drive"
    }
    return "/mnt/$drive/$rest"
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    Write-Info $Description
    & $ScriptBlock
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Invoke-WslScript {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$ScriptText
    )

    if ($DryRun) {
        Write-Host ""
        Write-Host "---- DRY RUN: $Description ----" -ForegroundColor Yellow
        Write-Host $ScriptText
        Write-Host "---- END ----" -ForegroundColor Yellow
        Write-Host ""
        return
    }

    Write-Info $Description
    $tmpFile = New-TemporaryFile
    try {
        Set-Content -LiteralPath $tmpFile.FullName -Value $ScriptText -Encoding utf8NoBOM
        Get-Content -LiteralPath $tmpFile.FullName -Raw | & wsl.exe -d $WslDistro -- bash -s --
    } finally {
        Remove-Item -LiteralPath $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-CommandExists "git")) {
    Write-Err "git not found on Windows PATH"
    exit 1
}

if (-not (Test-CommandExists "wsl.exe")) {
    Write-Err "wsl.exe not found on Windows PATH"
    exit 1
}

$RepoRoot = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RepoRoot)) {
    Write-Err "Current directory is not inside a git repository"
    exit 1
}
$RepoRoot = (Resolve-Path $RepoRoot.Trim()).Path

if ([string]::IsNullOrWhiteSpace($Branch)) {
    $Branch = (& git branch --show-current 2>$null).Trim()
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        Write-Err "Could not determine current git branch. Pass -Branch explicitly."
        exit 1
    }
}

Write-Info "Repository root: $RepoRoot"
Write-Info "Mode: $Mode"
Write-Info "WSL distro: $WslDistro"
Write-Info "WSL target: $TargetDir"
Write-Info "Branch: $Branch"

if ($Push) {
    Invoke-Checked -Description "Pushing current branch to $PushRemote/$Branch" -ScriptBlock {
        & git push $PushRemote $Branch
    }
}

switch ($Mode) {
    "Pull" {
        $pullScript = @'
set -euo pipefail
DST={0}
REMOTE={1}
BRANCH={2}

cd "$DST"

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "Remote '$REMOTE' does not exist in $DST" >&2
  exit 2
fi

git fetch "$REMOTE"

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git checkout "$BRANCH"
else
  git checkout -B "$BRANCH" --track "$REMOTE/$BRANCH"
fi

git pull --ff-only "$REMOTE" "$BRANCH"
'@ -f (Quote-Bash $TargetDir), (Quote-Bash $Remote), (Quote-Bash $Branch)
        Invoke-WslScript -Description "Pulling $Remote/$Branch inside WSL install" -ScriptText $pullScript
        Write-Success "WSL git pull completed"
    }
    "Sync" {
        $RepoRootWsl = Convert-WindowsPathToWslPath -Path $RepoRoot
        if ([string]::IsNullOrWhiteSpace($RepoRootWsl)) {
            Write-Err "Failed to translate Windows repo path into a WSL path"
            exit 1
        }

        $deleteFlag = if ($NoDelete) { "" } else { "--delete" }
        $syncScript = @'
set -euo pipefail
SRC={0}
DST={1}

if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required in WSL for Sync mode" >&2
  exit 2
fi

mkdir -p "$DST"

rsync -a {2} \
  --exclude '.git' \
  --exclude '.venv' \
  --exclude 'venv' \
  --exclude 'node_modules' \
  --exclude '__pycache__' \
  --exclude '.pytest_cache' \
  --exclude '.mypy_cache' \
  --exclude '.ruff_cache' \
  --exclude 'build' \
  --exclude 'dist' \
  "$SRC/" "$DST/"
'@ -f (Quote-Bash $RepoRootWsl), (Quote-Bash $TargetDir), $deleteFlag
        Invoke-WslScript -Description "Syncing local repository into WSL install" -ScriptText $syncScript
        Write-Success "WSL sync completed"
    }
}

if ($InstallDeps) {
    $depsScript = @'
set -euo pipefail
DST={0}

cd "$DST"
source venv/bin/activate

if command -v uv >/dev/null 2>&1; then
  uv pip install -e '.[all]'
else
  python -m pip install -e '.[all]'
fi
'@ -f (Quote-Bash $TargetDir)
    Invoke-WslScript -Description "Refreshing Python dependencies in WSL install" -ScriptText $depsScript
    Write-Success "Dependency refresh completed"
}

if ($BuildFrontend) {
    $frontendScript = @'
set -euo pipefail
DST={0}

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required for -BuildFrontend" >&2
  exit 2
fi

cd "$DST/web"
npm install
npm run build

cd "$DST/ui-tui"
npm install
npm run build

mkdir -p "$DST/hermes_cli/tui_dist"
cp -r "$DST/ui-tui/dist/"* "$DST/hermes_cli/tui_dist/"
'@ -f (Quote-Bash $TargetDir)
    Invoke-WslScript -Description "Building dashboard and TUI frontend assets in WSL" -ScriptText $frontendScript
    Write-Success "Frontend build completed"
}

if ($RestartGateway) {
    $restartScript = @'
set -euo pipefail
SESSION={0}
CMD={1}

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required for -RestartGateway" >&2
  exit 2
fi

tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"
tmux new-session -d -s "$SESSION" "$CMD"
'@ -f (Quote-Bash $TmuxSession), (Quote-Bash $GatewayCommand)
    Invoke-WslScript -Description "Restarting Hermes gateway tmux session in WSL" -ScriptText $restartScript
    Write-Success "Gateway restart completed"
}

Write-Success "deploy_to_wsl.ps1 finished"
