#!/usr/bin/env bash
# PreToolUse guard for outward and supply-chain actions: uploads and POST requests, remote
# shells and copies, code piped into an interpreter, global package installs.
# Defines guard_network, which pretool.sh calls. Run directly, it checks one payload on stdin.

NETWORK_RULES=(
  "upload or write request"   "^(curl|wget|iwr|invoke-webrequest|invoke-restmethod|irm|http|https|xh|httpie)( .*)? (-x (post|put|patch|delete)|-d|--data[^ ]*|--form|--upload[^ ]*|--post-file|-body|-infile|-method (post|put|patch|delete)|--request (post|put|patch|delete))( |$)"
  "request with a hidden method or splatted parameters" "^(iwr|invoke-webrequest|invoke-restmethod|irm)( .*)? (@[a-z_][a-z0-9_]*|-method +\\\$[^ ]*|-x +\\\$[^ ]*)( |$)"
  "remote shell or copy"      "^(scp|sftp|ftp|nc|ncat|netcat|ssh|telnet|psftp|plink)( |$)"
  "execution policy change"   "^set-executionpolicy( |$)"
  "invoke-expression"         "^(iex|invoke-expression)( |$)"
  "global package install"    "^(npm|pnpm|yarn) +(i|install|add)( .*)? (-g|--global)( |$)"
  "package install"           "^(pip|pip3|pipx|python|python3|py)( .*)? install( |$)"
  "system package install"    "^(winget|choco|chocolatey|scoop|brew|apt|apt-get)( .*)? (install|add)( |$)"
  "language tool install"     "^(cargo|go) install( |$)"
)

NETWORK_TEXT=(
  "code piped into an interpreter" '\|[ ]*(sh|bash|zsh|iex|invoke-expression|pwsh|powershell|cmd|python3?|node|perl|ruby)( |$)'
  "download run in place"          '(iex|invoke-expression).*(irm|invoke-restmethod|iwr|invoke-webrequest|curl|wget)'
  "WebClient or HttpClient upload or write" '(\.upload(string|data|file|values)(async)?\(|\.(postasync|putasync|patchasync|deleteasync|sendasync)\()'
)

guard_network() {
  case $TOOL in
    Bash|PowerShell) ;;
    *) return 0 ;;
  esac
  hook_prepare_cmd "$CMD"
  hook_scan_text NETWORK_TEXT
  hook_split
  hook_scan_rules NETWORK_RULES
  return 0
}

# Run directly: check one payload from stdin.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh" 2>/dev/null ||
    { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"hook library could not be loaded, so this call needs confirmation"}}'; exit 0; }
  hook_init guard-network.sh
  hook_read_input || hook_ask "could not read the hook input"
  guard_network
  exit 0
fi
