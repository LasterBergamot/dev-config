#!/usr/bin/env bash
# PreToolUse guard: asks before a commit, push, merge or release. Enforces the standing rule
# that nothing is committed or pushed without the user's permission, even in auto mode.
# Defines guard_git, which pretool.sh calls. Run directly, it checks one payload on stdin.

GIT_OPTS='( +(-c|-C) +[^ ]+| +--?[^ ]+)*'
GIT_PUBLISH=(
  "git commit"               "^git$GIT_OPTS +(commit|push|merge|rebase|cherry-pick|am|revert)( |$)"
  "git tag creation"         "^git$GIT_OPTS +tag( +[^- ][^ ]*| -[as])( |$)"
  "pull request change"      "^gh pr +(create|merge|close)( |$)"
  "GitHub release creation"  "^gh release +create( |$)"
)

guard_git() {
  case $TOOL in
    Bash|PowerShell) ;;
    *) return 0 ;;
  esac
  hook_prepare_cmd "$CMD"
  hook_split
  hook_scan_rules GIT_PUBLISH
  return 0
}

# Run directly: check one payload from stdin.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh" 2>/dev/null ||
    { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"hook library could not be loaded, so this call needs confirmation"}}'; exit 0; }
  hook_init guard-git.sh
  hook_read_input || hook_ask "could not read the hook input"
  guard_git
  exit 0
fi
