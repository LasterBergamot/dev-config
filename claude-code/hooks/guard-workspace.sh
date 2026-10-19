#!/usr/bin/env bash
# PreToolUse guard for writes outside the working directory. Temp folders and the Claude
# config folder (~/.claude) are allowed; anything else asks.
# Defines guard_workspace, which pretool.sh calls. Run directly, it checks one payload on stdin.

_workspace_allowed() {  # $1 = normalized path
  [[ $1 == "$CWD_N" || $1 == "$CWD_N"/* || $1 == "$T_HOME/.claude"/* ]] && return 0
  hook_is_temp "$1" && return 0
  return 1
}

_workspace_shell() {
  hook_prepare_cmd "$CMD"
  hook_has_mutating "$LC" || return 0
  local IFS=$' \t\n'
  local -a w
  local t
  w=($LC)
  for t in "${w[@]}"; do
    case $t in -*|/[a-z]) continue ;; esac  # options, and cmd switches such as /c
    t=${t##*>}  # redirections such as >file
    [[ -n $t && $t != /dev/null && $t != nul && $t != '$null' ]] || continue
    hook_norm_path "$t"
    if ! _workspace_allowed "$NP"; then hook_ask "command writes outside the working directory: $t"; fi
  done
  return 0
}

guard_workspace() {
  case $TOOL in
    Write|Edit|NotebookEdit)
      if [[ -n $FILE ]]; then
        hook_norm_path "$FILE"
        if ! _workspace_allowed "$NP"; then hook_ask "$TOOL writes outside the working directory: $FILE"; fi
      fi
      ;;
    Bash|PowerShell)
      _workspace_shell ;;
  esac
  return 0
}

# Run directly: check one payload from stdin.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh" 2>/dev/null ||
    { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"hook library could not be loaded, so this call needs confirmation"}}'; exit 0; }
  hook_init guard-workspace.sh
  hook_read_input || hook_ask "could not read the hook input"
  guard_workspace
  exit 0
fi
