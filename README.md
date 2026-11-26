# dev-config

Personal developer tooling for Windows and Linux: the Claude Code status line and deny rules, the Antigravity CLI status line, shared git aliases, and a disk-space cleanup command for Linux. Nothing here is tied to one project or machine. An interactive installer applies any part of it.

The Claude Code **guard hooks** moved to the private [ai-common](https://github.com/LasterBergamot/ai-common) repo (`packages/guards`, installed with APM). A machine set up for general-purpose Claude Code use takes both repos: this one for the status line, deny rules and git aliases, ai-common for the guards. ai-common's `docs/USING.md` ("Machine setup with dev-config") has the order and the details.

## Layout

- `install.sh`, `install.ps1`: the installer (see Install). `install.ps1` is the Windows launcher for `install.sh`.
- `claude-code/`: status line (`statusline.sh`) and the `settings.json` pieces the installer merges (`settings/`: status line, deny rules). See [claude-code/README.md](claude-code/README.md).
- `antigravity-cli/`: status line for the Antigravity CLI (`statusline.sh`, `statusline.bat`).
- `disk-cleanup/disk-cleanup.sh`: frees disk space taken by Docker, uv, mise, JetBrains, pacman, yay, npm and pnpm, with a dry run first (see Disk cleanup). Linux only.
- `git/.gitconfig`: shared git aliases and `status.showStash`. It has no `[user]` section, so your identity stays in your own `~/.gitconfig`.
- `.gitattributes`: keeps `*.sh` files LF. The status lines fail with CRLF line endings.

## Requirements

- Windows: Git for Windows on `PATH`. It provides the `bash` that the status lines and installer run in.
- Linux: `bash`.
- `jq` on `PATH`. The settings items of the installer need it too.
- `gh` is optional; the status line uses it to show the open PR.

## Install

From the repo root: `bash install.sh` on Linux, `.\install.ps1` in PowerShell on Windows. With no options it shows a menu of seven items with their state (`new`, `changed`, `pending` or `up to date`). Everything that still needs doing is preselected. Type a number to toggle an item, `a` for everything pending, `n` for none, Enter to install.

| Item | What it does |
|---|---|
| `claude-old-hooks` | removes the guard hooks this repo used to install: unregisters them in `~/.claude/settings.json`, then moves the scripts to the backup folder. Keeps `hooks/local.sh` and ai-common's hooks |
| `claude-statusline` | copies `statusline.sh` to `~/.claude` |
| `claude-settings-statusline` | sets `statusLine` in `~/.claude/settings.json` |
| `claude-settings-deny` | adds the `permissions.deny` rules for disk-wiping commands |
| `antigravity-statusline` | copies the Antigravity status line to `~/.gemini/antigravity-cli` and sets its `statusLine` |
| `git-aliases` | adds `git/.gitconfig` to your global git config as an `include.path` |
| `disk-cleanup` | copies `disk-cleanup/disk-cleanup.sh` to `~/.local/bin/disk-cleanup` (Linux only) |

Without the menu:

```
bash install.sh --list                          # states only
bash install.sh --all                           # everything
bash install.sh --only claude-statusline,git-aliases
bash install.sh --all --skip antigravity-statusline
bash install.sh --all --dry-run                 # show the changes, write nothing
```

`--yes` answers the question with yes: replacing a `statusLine` that differs from ours. Without a terminal those questions are answered no, and the item is reported as skipped.

How it treats your files:

- Unchanged files are skipped, so re-running is safe. A file it replaces, and `settings.json`, are copied to `~/.claude/dev-config-backups/<timestamp>/` first.
- Settings are merged, not overwritten. The installer sets `statusLine`, adds the deny rules you don't have yet, removes only the old hook entries (`bash ~/.claude/hooks/<name>.sh`), and leaves every other key alone. A file that is not valid JSON is left untouched.
- `CLAUDE_DIR`, `GEMINI_DIR` and `BIN_DIR` (for `disk-cleanup`, default `~/.local/bin`) redirect the target folders.

Linux notes: on Linux the Antigravity status line is set to run `statusline.sh` with `bash`; the `.bat` file is only copied on Windows. The installer has been run successfully on Linux.

## Disk cleanup

`disk-cleanup` (installed by the `disk-cleanup` item, or run as `bash disk-cleanup/disk-cleanup.sh`) frees space that caches and old versions take up on a Linux dev machine. Every run first shows, per target, what would be removed, where and how big it is. It starts and ends with `df` for `/` (and for `$HOME` when that is another filesystem) and ends with a total. A target whose tool is not installed is skipped.

```
disk-cleanup                              # check (dry run): every target, sizes, total
disk-cleanup list                         # the target IDs
disk-cleanup clean                        # every default target, asking y/N for each
disk-cleanup clean docker-build uv        # only these targets
disk-cleanup clean --skip pacman,yay      # all default targets but these
disk-cleanup clean --yes --only npm,pnpm  # no questions
disk-cleanup clean docker-volumes         # opt-in target: lists the volumes, then always asks
```

| Target | What `clean` runs |
|---|---|
| `docker-build` | `docker builder prune -a` |
| `docker-images` | `docker image prune -a` (images no container uses) |
| `docker-volumes` | `docker volume prune`: anonymous unused volumes; `--all-volumes` adds unused named ones. Opt-in: only when named, and it asks even with `--yes` |
| `uv` | `uv cache prune` (unused entries); `--uv-clean` runs `uv cache clean` (everything) |
| `mise` | `mise prune --tools`: versions that no tracked config selects (`mise ls --prunable`) |
| `jetbrains` | removes the cache and data folders of older IDE versions (`~/.cache/JetBrains`, `~/.local/share/JetBrains`), keeping the newest version of each product. Settings in `~/.config/JetBrains` are left alone |
| `jetbrains-toolbox` | removes Toolbox's rollback copies of previous IDE builds and its download cache. Skipped while Toolbox runs |
| `pacman` | `sudo paccache -rk1` and `sudo paccache -ruk0`: keeps only the newest version of each installed package |
| `yay` | `yay -Sca`: AUR build cache; yay asks its own questions (`--yes` adds `--noconfirm`) |
| `npm` | `npm cache clean --force` |
| `pnpm` | `pnpm store prune`, and removes stores of older pnpm versions |

For `uv`, `yay` and `pnpm` only an upper bound is known before they run, so `check` lists them apart from the total. `clean` reports what each target freed as the change in free space.

## Keeping machine details out of the repo

Drive letters, media folders and service names belong in `~/.claude/hooks/local.sh` (read by ai-common's guards) and in hand-added `Edit(...)` deny rules, neither of which is committed. The repo copy is the source; the live copy in `~/.claude` is a plain copy, so run the installer again after each change.
