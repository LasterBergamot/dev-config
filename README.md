# dev-config

Personal developer tooling for Windows and Linux: Claude Code guard hooks and status line, the Antigravity CLI status line, and shared git aliases. Nothing here is tied to one project or machine. An interactive installer applies any part of it.

## Layout

- `install.sh`, `install.ps1`: the installer (see Install). `install.ps1` is the Windows launcher for `install.sh`.
- `claude-code/`: status line (`statusline.sh`), PreToolUse guard hooks (`hooks/`) and the `settings.json` pieces the installer merges (`settings/`). See [claude-code/README.md](claude-code/README.md).
- `antigravity-cli/`: status line for the Antigravity CLI (`statusline.sh`, `statusline.bat`).
- `git/.gitconfig`: shared git aliases and `status.showStash`. It has no `[user]` section, so your identity stays in your own `~/.gitconfig`.
- `docs/claude-code-hooks.md`: how the guard hooks work and how to change them.
- `.gitattributes`: keeps `*.sh` files LF. The hooks fail with CRLF line endings.

## Requirements

- Windows: Git for Windows on `PATH`. It provides the `bash` that the hooks, status lines and installer run in.
- Linux: `bash`.
- `jq` on `PATH`. The settings items of the installer need it too.
- `gh` is optional; the status line uses it to show the open PR.

## Install

From the repo root: `bash install.sh` on Linux, `.\install.ps1` in PowerShell on Windows. With no options it shows a menu of eight items with their state (`new`, `changed`, `pending` or `up to date`). Everything that still needs doing is preselected. Type a number to toggle an item, `a` for everything pending, `n` for none, Enter to install.

| Item | What it does |
|---|---|
| `claude-hooks` | copies the hook scripts to `~/.claude/hooks` |
| `claude-local` | creates `hooks/local.sh` from `local.sh.example`; never overwrites an existing one |
| `claude-statusline` | copies `statusline.sh` to `~/.claude` |
| `claude-settings-hooks` | registers the hooks in `~/.claude/settings.json` |
| `claude-settings-statusline` | sets `statusLine` in `~/.claude/settings.json` |
| `claude-settings-deny` | adds the `permissions.deny` rules for disk-wiping commands |
| `antigravity-statusline` | copies the Antigravity status line to `~/.gemini/antigravity-cli` and sets its `statusLine` |
| `git-aliases` | adds `git/.gitconfig` to your global git config as an `include.path` |

Without the menu:

```
bash install.sh --list                          # states only
bash install.sh --all                           # everything
bash install.sh --only claude-hooks,git-aliases
bash install.sh --all --skip antigravity-statusline
bash install.sh --all --dry-run                 # show the changes, write nothing
```

`--yes` answers the questions with yes: replacing a `statusLine` that differs from ours, and running the hook tests afterwards (Windows only). Without a terminal those questions are answered no, and the item is reported as skipped.

How it treats your files:

- Unchanged files are skipped, so re-running is safe. A file it replaces, and `settings.json`, are copied to `~/.claude/dev-config-backups/<timestamp>/` first.
- Settings are merged, not overwritten. The installer replaces only the hook entries that run our scripts, adds the deny rules you don't have yet, and leaves every other key alone. A file that is not valid JSON is left untouched.
- It will not register the hooks unless `pretool.sh` is installed, because `onFailure: "block"` would otherwise block every tool call.
- `CLAUDE_DIR` and `GEMINI_DIR` redirect the target folders.

Fill in `~/.claude/hooks/local.sh` with this machine's drives and services after installing; see below.

Linux notes: `notify.sh` shows a Windows notification, so it does nothing on Linux, and `test-hooks.sh` needs Git Bash. The Linux path of the installer has not been run on a Linux machine.

## Tests

From the repo root:

```powershell
bash claude-code/hooks/test-hooks.sh claude-code/hooks
```

The cases use sample payloads only. The workspace is this repo and the machine rules come from `claude-code/hooks/test-fixtures/local.sh`, so the run gives the same result on any machine.

## Keeping machine details out of the repo

Drive letters, media folders and service names belong in `~/.claude/hooks/local.sh`, which is never committed. The repo copy is the source; the live copy in `~/.claude` is a plain copy, so run the installer again after each change.
