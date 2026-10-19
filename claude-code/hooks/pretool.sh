#!/usr/bin/env bash
# PreToolUse entry point. One process per tool call: reads the payload once, logs the call, runs
# the guards in order (the first one to ask ends the call), then backs up a file about to change.
# Each guard file also runs on its own; see the comment at the top of each.
_d=${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}
source "${_d}lib.sh" 2>/dev/null ||
  { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"hook library could not be loaded, so this call needs confirmation"}}'; exit 0; }
source "${_d}guard-delete.sh"
source "${_d}guard-git.sh"
source "${_d}guard-network.sh"
source "${_d}guard-protect.sh"
source "${_d}guard-secrets.sh"
source "${_d}guard-workspace.sh"
source "${_d}audit.sh"
source "${_d}backup.sh"

hook_init pretool.sh
hook_read_input || hook_ask "could not read the hook input"

hook_guard_off
audit_call
hook_guard_on

guard_delete
guard_git
guard_network
guard_protect
guard_secrets
guard_workspace

hook_guard_off
backup_file
exit 0
