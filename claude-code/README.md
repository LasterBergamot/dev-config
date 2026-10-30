# Claude Code status line

`statusline.sh` is a two-line status bar for Claude Code, built with bash and jq.

- **Line 1:** model, effort and thinking, git branch (dirty `*`, ahead `↑`, behind `↓`), folder and project, session name, location.
- **Line 2:** context usage, 5-hour and 7-day quota left with reset times, session cost and lines changed, PR, vim mode, agent, version.

## Requirements

- Git for Windows (provides `bash`)
- `jq` on `PATH`

## Install

Run the `claude-statusline` and `claude-settings-statusline` items of the installer in the repo root (see the main README). By hand: copy `statusline.sh` to `~/.claude/statusline.sh`, and merge [settings/statusline.json](settings/statusline.json) into `~/.claude/settings.json`.

Claude Code picks up the change on the next session or after the settings reload.

## Hooks

`hooks/` holds guard and feedback hooks for Claude Code. They keep working in auto mode, because a hook's `ask` is a real prompt, not a permission setting.

- `pretool.sh` is the single PreToolUse entry point: one process per tool call. It logs the call, then runs the guards in order. The first guard that asks ends the call.
  - `guard-delete.sh`: deleting or overwriting files and other resources (`rm`, `Remove-Item` and its aliases, .NET calls such as `[IO.File]::Delete`, `git clean`, `git restore`, `podman rm`, `reg delete`, `Clear-Disk`, `vssadmin delete`, `deleteFiles=true` API calls, `DROP TABLE`, and more). Redirects (`>`, `2>`, `*>`) onto an existing file ask like `Set-Content`. Deletes inside the temp folders, including the session scratchpad, pass without a prompt. Script files are checked the same way, both when Claude writes them and when a command runs them (`.\x.ps1`, `python x.py`, `powershell -File x.ps1`, `cmd /c x.bat`): the hook reads the script first. Shell scripts (`.ps1`, `.sh`, `.bat`, `.cmd`) are parsed as commands; Python, JavaScript and TypeScript only get code checks such as `shutil.rmtree`, `.unlink()` and shell-outs to `rm`.
  - `guard-git.sh`: `git commit`, `push`, `merge`, `rebase`, tag creation and `gh pr` / `gh release` changes. Enforces "no commit or push without permission".
  - `guard-protect.sh`: writes into the protected locations (`HOOK_PROTECTED`, set in `local.sh`), service and container control, any process kill (`Stop-Process`, `taskkill`, `.Kill()`, including services that run as plain processes), HKLM registry writes, changes to Claude configuration (settings, hooks, agents, skills, commands, plugins, the status line, `.mcp.json`), and any extra rule in `local.sh`.
  - `guard-secrets.sh`: reads or writes of credential files, and credential-shaped text.
  - `guard-network.sh`: uploads and POST requests (including splatted or variable `-Method` and WebClient/HttpClient writes), `ssh`/`scp`, code piped into an interpreter, global package installs.
  - `guard-workspace.sh`: writes outside the working folder (temp and `~/.claude` are allowed).
  - `audit.sh` logs every call; `backup.sh` copies a file before Write, Edit or NotebookEdit changes it.
- `posttool-check.sh` syntax-checks a file after it is written and sends failures back to Claude.
- `prompt-check.sh` warns when a prompt contains a credential-shaped string.
- `session-start.sh` shows the active guards and the repository state.
- `notify.sh` shows a Windows notification when Claude asks for permission or finishes.

Requirements: Git for Windows (provides `bash`) and `jq`. If Chocolatey's `jq` shim is installed, the hooks call the real `jq.exe` underneath it, which is about 25 ms faster per call.

Install: run the `claude-hooks`, `claude-settings-hooks` and `claude-settings-deny` items of the installer in the repo root (see the main README). By hand: copy `hooks/*.sh` except `test-hooks.sh` to `~/.claude/hooks/`, and merge [settings/hooks.json](settings/hooks.json) and [settings/deny.json](settings/deny.json) into `~/.claude/settings.json`.

`onFailure: "block"` (Claude Code v2.1.295 or later) in `settings/hooks.json` makes a guard that crashes or times out block the call. Without it, a failed PreToolUse hook lets the call through. The `permissions.deny` rules hold even when the hooks are not running.

Run `/hooks` in Claude Code to confirm the hooks are loaded. Run the tests with `bash claude-code/hooks/test-hooks.sh`. They use only sample payloads and never write to the repo or the media libraries.

Adding or changing a rule means editing the arrays at the top of each guard file, such as `DELETE_ALWAYS` in `guard-delete.sh`.

Machine-specific rules go in `~/.claude/hooks/local.sh`, which every hook sources when it exists. Copy `hooks/local.sh.example` to start. It sets `HOOK_PROTECTED`, the locations whose writes ask, and can define `hook_local_protect`, which `guard-protect.sh` runs on every Bash and PowerShell command. Keep the filled-in copy out of the repo. Also add an `Edit(...)` entry to `permissions.deny` for each media folder, for example `Edit(//d/Media/**)`, because that list still holds when the hooks are not running.

Limits:

- A script is only read when the command names it with its extension. A script reached another way (`make clean`, `npm run`, `& $script`, a script that calls another script) is not seen. Backups and the audit log cover those cases. A script path with an unresolved variable asks.
- Writing, editing or running a script that deletes files asks every time, even without `--apply`. That includes `test-hooks.sh` and edits to the guard files themselves.
- Python, JavaScript and TypeScript are not parsed as shell, so a delete they make through a library the checks don't know about is not seen.
- A hook that fails or cannot read its input asks instead of allowing the call; with `onFailure: "block"`, a crash or timeout blocks it.
- Overwriting an existing file with Write asks everywhere outside the temp folders. This is the noisiest rule. Remove the Write branch from `guard_delete` if it is too frequent.
- Logs go to `~/.claude/logs/audit-YYYYMMDD.jsonl` and backups to `~/.claude/backups/`.

## Notes

- Quota shows percentages and reset times only. Claude Code does not expose message counts.
- Location (`local`, `ssh`, `wsl`, `remote`) is inferred from environment variables. The input JSON has no such field.
- Git status is cached for 5 seconds per directory to keep refreshes cheap.
