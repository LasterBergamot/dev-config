# Claude Code: status line and deny rules

`statusline.sh` is a two-line status bar for Claude Code, built with bash and jq.

- **Line 1:** model, effort and thinking, git branch (dirty `*`, ahead `↑`, behind `↓`), folder and project, session name, location.
- **Line 2:** context usage, 5-hour and 7-day quota left with reset times, session cost and lines changed, PR, vim mode, agent, version.

## Requirements

- Git for Windows (provides `bash`)
- `jq` on `PATH`

## Install

Run the `claude-statusline` and `claude-settings-statusline` items of the installer in the repo root (see the main README). By hand: copy `statusline.sh` to `~/.claude/statusline.sh`, and merge [settings/statusline.json](settings/statusline.json) into `~/.claude/settings.json`.

Claude Code picks up the change on the next session or after the settings reload.

## Deny rules

[settings/deny.json](settings/deny.json) adds `permissions.deny` rules for disk-wiping commands (`Format-Volume`, `Clear-Disk`, `diskpart`, `format`, …). Install them with the `claude-settings-deny` item. They hold even when no hook is running, so keep them next to the guard hooks as the backstop. Also add an `Edit(...)` entry for each media folder in `~/.claude/settings.json` by hand, for example `Edit(//d/Media/**)`; those paths differ per machine, so they are not in the repo.

## Guard hooks: moved to ai-common

The guard and feedback hooks (`pretool.sh`, the `guard-*.sh` scripts, backup, audit log, syntax check, notifications) used to live in `hooks/` here. They now live in the private [ai-common](https://github.com/LasterBergamot/ai-common) repo as the `guards` package, installed with APM:

```bash
apm install -g LasterBergamot/ai-common/packages/guards#<tag> --target claude
```

ai-common's `docs/USING.md` covers the install and how it fits with this repo, and `docs/HOOKS.md` covers what each guard asks on. Machine rules stay in `~/.claude/hooks/local.sh`, which ai-common reads from the same place.

A machine that still has this repo's old copy (scripts directly in `~/.claude/hooks/`) needs the `claude-old-hooks` installer item. It unregisters the old hooks from `settings.json` first, then moves the scripts into the backup folder. Otherwise every guard runs twice once ai-common's are installed.

## Notes

- Quota shows percentages and reset times only. Claude Code does not expose message counts.
- Location (`local`, `ssh`, `wsl`, `remote`) is inferred from environment variables. The input JSON has no such field.
- Git status is cached for 5 seconds per directory to keep refreshes cheap.
