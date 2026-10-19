#!/usr/bin/env bash
# PreToolUse, never blocks: keeps a copy of a file before Write, Edit or NotebookEdit changes it.
# Copies go to ~/.claude/backups/<date>/ and folders older than 14 days are removed now and then.
# Defines backup_file, which pretool.sh calls. Run directly, it backs up one payload's file.

backup_file() {
  case $TOOL in
    Write|Edit|NotebookEdit) ;;
    *) return 0 ;;
  esac
  [[ -n $FILE ]] || return 0
  hook_norm_path "$FILE"
  [[ -f $NP ]] || return 0

  local size day stamp name dir
  size=$(stat -c %s "$NP" 2>/dev/null) || return 0
  (( size < 5000000 )) || return 0

  printf -v day '%(%Y%m%d)T' -1
  printf -v stamp '%(%H%M%S)T' -1
  name=${FILE##*[\\/]}
  dir=$HOME/.claude/backups/$day
  mkdir -p "$dir" 2>/dev/null || return 0
  cp -p -- "$NP" "$dir/$stamp-$name" 2>/dev/null || :

  if (( RANDOM % 50 == 0 )); then
    find "$HOME/.claude/backups" -mindepth 1 -maxdepth 1 -mtime +14 -exec rm -rf {} + 2>/dev/null || :
  fi
  return 0
}

# Run directly: back up one payload's file.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh" || exit 0
  hook_read_input || exit 0
  backup_file
  exit 0
fi
