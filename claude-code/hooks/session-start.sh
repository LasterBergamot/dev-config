#!/usr/bin/env bash
# SessionStart, informational: shows which guards are active and the state of the repository.
source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh"
hook_read_input || exit 0
cd "$CWD" 2>/dev/null || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="not a git repository"
changes=$(git status --porcelain 2>/dev/null | wc -l)
changes=${changes// /}

hook_jsv "Guards active: deletion and overwrite, git commit/push, protected media paths and services, network, credentials, writes outside the workspace. Repo: $branch, $changes uncommitted change(s)."
printf '{"systemMessage":%s}\n' "$JS"
exit 0
