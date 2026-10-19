#!/usr/bin/env bash
# PreToolUse, logging only: appends one line per tool call to ~/.claude/logs/audit-YYYYMMDD.jsonl.
# The guards add their own "ask" lines to the same files. Content is not logged, only its size.
# Defines audit_call, which pretool.sh calls. Run directly, it logs one payload from stdin.

audit_call() {
  local tool cwd session file command
  hook_jsv "$TOOL";         tool=$JS
  hook_jsv "$CWD";          cwd=$JS
  hook_jsv "$SESSION";      session=$JS
  hook_jsv "$FILE";         file=$JS
  hook_jsv "${CMD:0:1000}"; command=$JS
  hook_log "\"tool\":$tool,\"session\":$session,\"cwd\":$cwd,\"file\":$file,\"command\":$command,\"content_chars\":${#CONTENT}"
  return 0
}

# Run directly: log one payload from stdin.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh" || exit 0
  hook_read_input || exit 0
  audit_call
  exit 0
fi
