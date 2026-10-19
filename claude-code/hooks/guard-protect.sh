#!/usr/bin/env bash
# PreToolUse guard for the things that must not change silently: protected locations (HOOK_PROTECTED
# and hook_local_protect, both set in local.sh), services, containers and running processes (any
# kill asks), HKLM registry keys, and the hook and settings files.
# Defines guard_protect, which pretool.sh calls. Run directly, it checks one payload on stdin.

PROTECT_SERVICES=(
  "service change"                      "^(stop|start|restart|set|remove|new|suspend|resume)-service( |$)"
  "sc service control"                  "^sc(\.exe)? +(stop|start|config|create|failure|pause|continue)( |$)"
  "net start or stop"                   "^net +(stop|start|pause|continue)( |$)"
  "container start, stop or compose"    "^(podman|docker)( +compose)? +(up|down|stop|kill|restart|start|pause|unpause)( |$)"
  "podman machine control"              "^(podman|docker) +machine +(start|stop|init|set|reset|ssh)( |$)"
  "shutdown or restart"                 "^(shutdown|restart-computer|stop-computer)( |$)"
  "firewall change"                     "^netsh( .*)? (advfirewall|firewall)( |$)"
  "WSL control"                         "^wsl( .*)? (--shutdown|--terminate|-t|--set-default|--import)( |$)"
  "process kill"                        "^(taskkill|tskill|stop-process|spps|kill|pkill|killall)( |$)"
  "WMI process termination"             "^wmic( .*)? process( .*)? (delete|call +terminate)( |$)"
)

PROTECT_HKLM=(
  "HKLM registry write"                 "^(reg +(add|delete|import|copy|restore|load|unload)|set-itemproperty|new-itemproperty|remove-itemproperty|new-item|set-item|remove-item|rename-item|clear-item)( |$)"
)

guard_protect() {
  local p re
  case $TOOL in
    Write|Edit|NotebookEdit)
      [[ -n $FILE ]] || return 0
      hook_norm_path "$FILE"
      if hook_protected_in "$NP"; then hook_ask "$TOOL writes inside a protected location: $FILE"; fi
      for p in "${HOOK_SELF[@]}"; do
        if [[ $NP == *"$p"* ]]; then hook_ask "$TOOL changes protected configuration: $FILE"; fi
      done
      ;;
    Bash|PowerShell)
      hook_prepare_cmd "$CMD"
      if [[ $LC == *disableallhooks* ]]; then hook_ask "command that turns the hooks off"; fi
      if [[ $LC =~ \.kill\( ]]; then hook_ask "process kill through .Kill()"; fi
      if hook_has_mutating "$LC"; then
        if hook_protected_in "$LC"; then hook_ask "command writes inside a protected location ($PROT)"; fi
        for p in "${HOOK_SELF[@]}"; do
          if [[ $LC == *"$p"* ]]; then hook_ask "command changes protected configuration"; fi
        done
      fi
      if declare -F hook_local_protect >/dev/null; then hook_local_protect; fi
      hook_split
      hook_scan_rules PROTECT_SERVICES
      if [[ $LC == *hklm* || $LC == *hkey_local_machine* ]]; then hook_scan_rules PROTECT_HKLM; fi
      ;;
  esac
  return 0
}

# Run directly: check one payload from stdin.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh" 2>/dev/null ||
    { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"hook library could not be loaded, so this call needs confirmation"}}'; exit 0; }
  hook_init guard-protect.sh
  hook_read_input || hook_ask "could not read the hook input"
  guard_protect
  exit 0
fi
