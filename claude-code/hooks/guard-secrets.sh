#!/usr/bin/env bash
# PreToolUse guard for credentials: asks before a file that holds secrets is read or changed,
# and before a credential-shaped value is written or passed on the command line.
# Defines guard_secrets, which pretool.sh calls. Run directly, it checks one payload on stdin.

guard_secrets() {
  local re
  case $TOOL in
    Read|Write|Edit|NotebookEdit)
      if [[ -n $FILE ]]; then
        hook_norm_path "$FILE"
        for re in "${HOOK_CREDENTIAL_PATHS[@]}"; do
          if [[ $NP =~ $re ]]; then hook_ask "$TOOL touches a credential file: $FILE"; fi
        done
      fi
      if [[ $TOOL != Read && -n $CONTENT ]]; then
        for re in "${HOOK_CREDENTIAL_TEXT[@]}"; do
          if [[ $CONTENT =~ $re ]]; then hook_ask "$TOOL content looks like a credential"; fi
        done
      fi
      ;;
    Bash|PowerShell)
      hook_prepare_cmd "$CMD"
      for re in "${HOOK_CREDENTIAL_PATHS[@]}"; do
        if [[ $LC =~ $re ]]; then hook_ask "command touches a credential file"; fi
      done
      for re in "${HOOK_CREDENTIAL_TEXT[@]}"; do
        if [[ $CMD =~ $re ]]; then hook_ask "command contains a credential"; fi
      done
      ;;
  esac
  return 0
}

# Run directly: check one payload from stdin.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh" 2>/dev/null ||
    { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"hook library could not be loaded, so this call needs confirmation"}}'; exit 0; }
  hook_init guard-secrets.sh
  hook_read_input || hook_ask "could not read the hook input"
  guard_secrets
  exit 0
fi
