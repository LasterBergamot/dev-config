# dev-config

Personal developer tooling for Windows: Claude Code guard hooks and status line, the Antigravity CLI status line, and shared git aliases. Nothing here is tied to one project or machine.

## Layout

- `claude-code/`: status line (`statusline.sh`) and PreToolUse guard hooks (`hooks/`). See [claude-code/README.md](claude-code/README.md).
- `antigravity-cli/`: status line for the Antigravity CLI (`statusline.sh`, `statusline.bat`).
- `git/.gitconfig`: shared git aliases and `status.showStash`. It has no `[user]` section, so your identity stays in your own `~/.gitconfig`.
- `docs/claude-code-hooks.md`: how the guard hooks work and how to change them.
- `.gitattributes`: keeps `*.sh` files LF. The hooks fail with CRLF line endings.

## Requirements

- Windows with Git for Windows, which provides `bash`, on `PATH`.
- `jq` on `PATH`.
- `gh` is optional; the status line uses it to show the open PR.

## Install

Claude Code, from the repo root in PowerShell:

```powershell
Copy-Item claude-code\statusline.sh $HOME\.claude\statusline.sh
New-Item -ItemType Directory -Force $HOME\.claude\hooks | Out-Null
Copy-Item claude-code\hooks\*.sh $HOME\.claude\hooks\ -Exclude test-hooks.sh
Copy-Item claude-code\hooks\local.sh.example $HOME\.claude\hooks\local.sh
```

Then fill in `~\.claude\hooks\local.sh` with this machine's drives and services, and merge the settings snippet from [claude-code/README.md](claude-code/README.md) into `~/.claude/settings.json`.

Git aliases, without copying them into your own config:

```powershell
git config --global --add include.path "C:/path/to/dev-config/git/.gitconfig"
```

Antigravity CLI: point the status line command at `antigravity-cli\statusline.bat`.

## Tests

From the repo root:

```powershell
bash claude-code/hooks/test-hooks.sh claude-code/hooks
```

The cases use sample payloads only. The workspace is this repo and the machine rules come from `claude-code/hooks/test-fixtures/local.sh`, so the run gives the same result on any machine.

## Keeping machine details out of the repo

Drive letters, media folders and service names belong in `~/.claude/hooks/local.sh`, which is never committed. The repo copy is the source; the live copy in `~/.claude` is a plain copy, so copy the files again after each change.
