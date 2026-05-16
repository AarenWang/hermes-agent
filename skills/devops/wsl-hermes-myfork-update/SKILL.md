---
name: wsl-hermes-myfork-update
description: Update a WSL Hermes install from your fork.
version: 1.0.0
author: Hermes Agent
license: Apache-2.0
platforms: [windows]
metadata:
  hermes:
    tags: [wsl, deployment, git, fork, hermes]
    category: devops
---

# WSL Hermes Myfork Update Skill

Use this skill when the user wants to update a Hermes install inside WSL from a personal GitHub fork. It is for the workflow where Windows is the development machine, WSL runs the installed Hermes checkout, and the WSL checkout has a `myfork` remote. It is not for generic Linux deployment or for `hermes update`.

## When to Use

- The user asks to update `~/.hermes/hermes-agent` inside WSL from their fork.
- The repository already contains [scripts/deploy_to_wsl.ps1](scripts/deploy_to_wsl.ps1).
- The desired workflow is `push on Windows -> pull in WSL -> restart Hermes`.

## Prerequisites

- Use the `terminal` tool from the repository root.
- Windows host has `git` and `wsl.exe`.
- The WSL install lives at `~/.hermes/hermes-agent`.
- The WSL checkout has a `myfork` remote pointing to the user's fork.
- The repo branch to deploy is known. Default to the current branch if the user does not specify one.

## How to Run

Preferred command:

```powershell
.\scripts\deploy_to_wsl.ps1 -Mode Pull -Branch <branch> -Push
```

Useful variants:

```powershell
.\scripts\deploy_to_wsl.ps1 -Mode Pull -Branch <branch> -Push -InstallDeps
.\scripts\deploy_to_wsl.ps1 -Mode Pull -Branch <branch> -Push -BuildFrontend
.\scripts\deploy_to_wsl.ps1 -Mode Pull -Branch <branch> -DryRun
```

## Quick Reference

- Code only: `.\scripts\deploy_to_wsl.ps1 -Mode Pull -Branch <branch> -Push`
- Dependency change: add `-InstallDeps`
- Frontend change: add `-BuildFrontend`
- Preview only: add `-DryRun`
- After success: tell the user to restart Hermes inside WSL

## Procedure

1. Confirm the current branch with the `terminal` tool.
2. Prefer the repo script instead of hand-writing `git push` plus `wsl git pull`.
3. For normal code updates, run:

```powershell
.\scripts\deploy_to_wsl.ps1 -Mode Pull -Branch <branch> -Push
```

4. If the change touches `pyproject.toml`, dependency groups, or install-time Python packaging, rerun with `-InstallDeps`.
5. If the change touches `web/` or `ui-tui/`, rerun with `-BuildFrontend`.
6. If the user wants a safe preview, use `-DryRun` first and then the real command.
7. After a successful pull, explicitly tell the user to restart the WSL Hermes process.

## Pitfalls

- Do not use `hermes update` for unpublished local changes.
- Do not assume plain `git pull` in WSL will fetch the fork. The WSL checkout must pull from `myfork`.
- Do not skip `-InstallDeps` when packaging or dependency files changed.
- Do not skip `-BuildFrontend` when frontend artifacts need rebuilding.
- Do not claim the update is live until the user restarts Hermes in WSL.

## Verification

- Check that the script reports a successful push and WSL pull.
- Confirm the WSL checkout HEAD matches the expected commit.
- If needed, verify inside WSL:

```bash
cd ~/.hermes/hermes-agent
git rev-parse --short HEAD
git remote -v
```

- End by telling the user to restart Hermes in WSL so the new code is actually used.
