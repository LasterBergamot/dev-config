# Claude Code guard hooks

Full install and settings snippet: `claude-code/README.md`. Source: `claude-code/hooks/`.

## How it works

`pretool.sh` is the only PreToolUse entry point. It sources `lib.sh` and the guard files, installs an ERR trap that turns any internal error into an "ask", logs the call (`audit.sh`), then runs the guards in this order; the first guard that asks ends the call:

`guard_delete` -> `guard_git` -> `guard_network` -> `guard_protect` -> `guard_secrets` -> `guard_workspace`, then `backup_file` copies the file about to change.

Guards only ever emit `ask`, never `deny`, so they prompt even in auto mode. `permissions.deny` in `~/.claude/settings.json` (Edit on the media folders, disk formatting) is the backstop that holds when hooks fail.

| Guard | Asks on |
|---|---|
| `guard-delete.sh` | Deletes and overwrites (`rm`, `Remove-Item`, `mv`, `cp`/`Set-Content`/redirect onto an existing file, `git clean`, `reset --hard`, `reg delete`, `sc delete`, robocopy mirror, `DROP`), a `Write` over an existing file outside temp, and scripts it can read before they run (`.ps1 .sh .py .bat .js`) |
| `guard-git.sh` | `git commit/push/merge/rebase/cherry-pick/am/revert`, tag creation, `gh pr` and `gh release` changes |
| `guard-network.sh` | `curl`/`iwr`/`irm` with POST/PUT/PATCH/DELETE or a body, `ssh`/`scp`, code piped to an interpreter, global package installs |
| `guard-protect.sh` | Protected locations and extra rules from `local.sh`, services, any process kill, HKLM writes, Claude config |
| `guard-secrets.sh` | Credential files and credential-shaped text in writes and commands |
| `guard-workspace.sh` | Writes outside the working directory (temp and `~/.claude` allowed) |

## Consequences for work in this repo

- The arr scripts use PUT/POST, so running them prompts.
- Running or writing a script that deletes files prompts even without `--apply`; so do `test-hooks.sh` and edits to the guard files.
- Editing `CLAUDE.md` or anything under `~/.claude` prompts (`HOOK_SELF` in `lib.sh`). Temp and the session scratchpad pass.
- Commit and push always prompt.

## Editing the hooks

- Rules are arrays at the top of each guard file (for example `DELETE_ALWAYS`, `PROTECT_SERVICES`); protected paths are `HOOK_PROTECTED` in `lib.sh` and, per machine, in `local.sh`; credential patterns are `HOOK_CREDENTIAL_PATHS` and `HOOK_CREDENTIAL_TEXT`.
- **The repo copy is not the live copy.** After editing, deploy: `Copy-Item claude-code\hooks\*.sh $HOME\.claude\hooks\ -Exclude test-hooks.sh`.
- Test: `bash claude-code/hooks/test-hooks.sh` (sample payloads only; `VIA_DISPATCHER=1` routes through `pretool.sh`). Add a case for every new rule.
- Keep `.sh` files LF (`.gitattributes`).
- Machine rules live in `~/.claude/hooks/local.sh` (template: `hooks/local.sh.example`). The tests load `hooks/test-fixtures/local.sh` instead, so they pass on any machine.
- Logs: `~/.claude/logs/audit-YYYYMMDD.jsonl`; backups: `~/.claude/backups/<date>/` (pruned after 14 days).
- Update `claude-code/README.md` and the root `README.md` layout row when guard behaviour changes.

## Other hooks

`posttool-check.sh` syntax-checks written `.sh/.py/.json/.ps1`; `prompt-check.sh` warns on credential-shaped prompts; `session-start.sh` lists the guards; `notify.sh` raises a Windows notification on Notification/Stop.
