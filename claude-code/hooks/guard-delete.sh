#!/usr/bin/env bash
# PreToolUse guard for deletion and overwriting. Asks before a file or another resource is
# deleted, moved away or overwritten. Deletes that touch only the temp folders (including the
# session scratchpad) pass without a prompt. Script text is checked the same way: new text written
# with Write, Edit or NotebookEdit, and the file a command runs (./x.ps1, python x.py).
# Defines guard_delete, which pretool.sh calls. Run directly, it checks one payload on stdin.

DELETE_GIT='( +(-c|-C) +[^ ]+| +--?[^ ]+)*'

# Commands that lose data or history. These ask whatever the path is.
DELETE_ALWAYS=(
  "git clean or rm"                         "^git$DELETE_GIT +(clean|rm)( |$)"
  "git reset --hard"                        "^git$DELETE_GIT +reset( .*)? --hard( |$)"
  "git checkout or restore discards changes" "^git$DELETE_GIT +(checkout|restore)( [^ ]+)* +(--|\.)( |$)"
  "git checkout or switch discards changes" "^git$DELETE_GIT +(checkout|switch)( .*)? (-f|--force|--discard-changes)( |$)"
  "git branch delete"                       "^git$DELETE_GIT +branch( .*)? (-d|--delete)( |$)"
  "git tag delete"                          "^git$DELETE_GIT +tag( .*)? (-d|--delete)( |$)"
  "git stash drop or clear"                 "^git$DELETE_GIT +stash +(drop|clear)( |$)"
  "git reflog expire or delete"             "^git$DELETE_GIT +reflog +(expire|delete)( |$)"
  "git prune"                               "^git$DELETE_GIT +prune( |$)"
  "registry deletion"                       "^(reg +delete|remove-itemproperty|rp)( |$)"
  "service deletion"                        "^sc(\.exe)? +delete( |$)"
  "scheduled task deletion"                 "^schtasks( .*)? /delete( |$)"
  "WSL distro unregister"                   "^wsl( .*)? --unregister( |$)"
  "user or group deletion"                  "^net +(user|localgroup|group) .*/delete( |$)"
  "package uninstall"                       "^(winget|choco|chocolatey|scoop|pip|pip3|pipx|npm|pnpm|yarn|apt|apt-get|brew|cargo|uninstall-package|uninstall-module|python|python3|py)( [^ ]+)* +(uninstall|remove|rm|unlink|unpublish|purge|autoremove)( |$)"
  "container or image removal"              "^(podman|docker)( [^ ]+)* +(rm|rmi|prune|reset|unregister)( |$)"
  "compose down with volumes"               "^(podman|docker)( [^ ]+)* +down( [^ ]+)* +(-v|--volumes)( |$)"
  "kubernetes delete"                       "^kubectl( [^ ]+)* +delete( |$)"
  "terraform destroy"                       "^terraform( [^ ]+)* +(destroy|apply -destroy)( |$)"
  "S3 removal"                              "^aws s3 +(rm|rb)( |$)"
  "cloud resource deletion"                 "^(az|gcloud|gsutil|aws) .*(delete|destroy|purge)[^ ]*( |$)"
  "GitHub deletion"                         "^gh (repo|release|secret|gist|workflow|label|issue|pr) +delete( |$)"
  "disk format, diskpart or recycle bin"    "^(clear-recyclebin|format-volume|format|diskpart|cipher)( |$)"
  "disk wipe or partition change"           "^(clear-disk|initialize-disk|set-disk|remove-partition|resize-partition|remove-physicaldisk|reset-physicaldisk|remove-virtualdisk|remove-storagepool)( |$)"
  "shadow copy or backup deletion"          "^((vssadmin|wbadmin)( .*)? delete|wmic( .*)? shadowcopy( .*)? delete)( |$)"
  "robocopy purge or move"                  "^robocopy( .*)? (/mir|/purge|/mov)( |$)"
  "rsync delete"                            "^rsync( .*)? --delete"
  "find -delete"                            "^find( .*)? -delete( |$)"
  "dd write"                                "^dd( .*)? of="
)

# git restore discards working-tree changes unless it only unstages (--staged without --worktree).
DELETE_RESTORE="^git$DELETE_GIT +restore( |$)"

# sc.exe subcommands. Any other first argument means sc is the PowerShell alias for Set-Content.
DELETE_SC_SERVICE='^(query|queryex|qc|qdescription|qfailure|qfailureflag|qsidtype|qprivs|qtriggerinfo|qpreferrednode|qmanagedaccount|start|stop|pause|continue|interrogate|control|config|create|delete|description|failure|failureflag|sidtype|privs|triggerinfo|preferrednode|managedaccount|sdshow|sdset|showsid|getdisplayname|getkeyname|enumdepend|boot|lock)$'

# Script files whose text is checked like a command: when Claude writes them and when a command
# runs them.
DELETE_SCRIPT_EXT='\.(ps1|psm1|sh|bash|py|bat|cmd|js|mjs|cjs|ts)$'

# Script languages that are not shell. Their text gets only the code checks below, because parsing
# it as shell turns help text such as "--format TEMPLATE" into commands.
DELETE_LANG_EXT='\.(py|js|mjs|cjs|ts)$'

# A shell-out from code that runs a delete command, on one line.
DELETE_SHELLOUT="(os\.system|os\.popen|subprocess\.[a-z_]+|child_process|execsync|spawnsync|exec)\([^"$'\n'"]*[^a-z](rm|rmdir|del|rd|remove-item|rimraf)[^a-z]"

# Interpreters whose first script-file argument is the script they run. "." and source load a
# script into the current shell.
DELETE_RUNNERS=' powershell pwsh python python3 py bash sh node cmd deno tsx ts-node . source '

# Scripts larger than this are not read; running one asks.
DELETE_SCRIPT_MAX=1000000

# A redirect that replaces a file: >, 1>, 2>, *>. Appends (>>) and handle copies (2>&1) are
# removed before matching.
DELETE_REDIRECT='>[[:space:]]*([^[:space:];|&)>]+)'

# Prefix for the ask reason: empty for commands, names the file for script text.
DELETE_CTX=

# One command position, e.g. "rm -rf build". $2 = 1 for script text, where paths resolve when the
# script runs, so the overwrite checks (which look at files that exist now) are skipped.
_delete_rest() {
  local cmd=${1%% *} i
  for (( i = 0; i < ${#DELETE_ALWAYS[@]}; i += 2 )); do
    if [[ $1 =~ ${DELETE_ALWAYS[i+1]} ]]; then hook_ask "$DELETE_CTX${DELETE_ALWAYS[i]}: ${1:0:160}"; fi
  done
  if [[ $1 =~ $DELETE_RESTORE ]] && [[ ! $1 =~ \ --staged( |$) || $1 =~ \ (--worktree|-w)( |$) ]]; then
    hook_ask "${DELETE_CTX}git restore discards changes: ${1:0:160}"
  fi
  hook_targets "$1"
  case $cmd in
    rm|rmdir|unlink|shred|del|erase|rd|ri|remove-item|truncate)
      hook_guard_targets "$DELETE_CTX$cmd" ;;
    mv|move|move-item|mi|ren|rename|rename-item|rni)
      hook_guard_targets "$DELETE_CTX$cmd moves its source" ;;
  esac
  (( ${2:-0} )) && return 0
  case $cmd in
    cp|copy|copy-item|cpi)
      if (( ${#TARGETS[@]} )); then TARGETS=("${TARGETS[-1]}"); hook_overwrite_check "$cmd"; fi ;;
    set-content|out-file|clear-content|clc)
      hook_overwrite_check "$cmd" ;;
    sc)
      if [[ ! ${TARGETS[0]-} =~ $DELETE_SC_SERVICE ]]; then hook_overwrite_check "sc (Set-Content)"; fi ;;
    tee)
      if [[ $1 != *" -a"* ]]; then hook_overwrite_check "tee"; fi ;;
  esac
  return 0
}

# Redirect targets in LC that already exist outside the temp folders ask, like Set-Content.
_delete_redirects() {
  local s=${LC//>>/ } t
  s=${s//>&/ }
  TARGETS=()
  while [[ $s =~ $DELETE_REDIRECT ]]; do
    t=${BASH_REMATCH[1]}
    s=${s#*"${BASH_REMATCH[0]}"}
    case $t in '$null'|/dev/null|nul) continue ;; esac
    TARGETS+=("$t")
  done
  if (( ${#TARGETS[@]} )); then hook_overwrite_check "redirect"; fi
  return 0
}

# The script file a command position runs, from the command itself (./x.ps1) or an interpreter
# argument (python x.py, powershell -file x.ps1). $1 = rest, $2 = command as written. Sets RUN.
_delete_run_target() {
  local IFS=$' \t\n' t
  local -a w
  RUN=
  if [[ $2 =~ $DELETE_SCRIPT_EXT ]]; then RUN=$2; return 0; fi
  [[ $DELETE_RUNNERS == *" ${1%% *} "* ]] || return 0
  w=($1)
  for t in "${w[@]:1}"; do
    if [[ $t =~ $DELETE_SCRIPT_EXT ]]; then RUN=$t; return 0; fi
  done
  return 0
}

# Reads each script in $@ and checks its text, so a script that already exists is seen when it
# runs. A script that cannot be found is skipped: nothing runs.
_delete_run_scripts() {
  local r size content
  for r in "$@"; do
    case $r in *'$'*|*'%'*) hook_ask "runs a script whose path cannot be resolved: $r" ;; esac
    hook_norm_path "$r"
    [[ -f $NP ]] || continue
    size=$(stat -c %s "$NP")
    if (( size > DELETE_SCRIPT_MAX )); then hook_ask "runs ${r##*/}, which is too large to check"; fi
    content=$(<"$NP")
    DELETE_CTX="running ${r##*/}: "
    _delete_text "$content" "$(_delete_mode "$r")"
  done
  DELETE_CTX=
  return 0
}

# Prints the _delete_text mode for script file $1: 2 for code, 1 for shell.
_delete_mode() {
  if [[ ${1,,} =~ $DELETE_LANG_EXT ]]; then echo 2; else echo 1; fi
}

# Checks command or script text. $1 = text, $2 = mode: 0 command, 1 shell script, 2 code (Python,
# JavaScript, TypeScript), which skips the shell parsing.
_delete_text() {
  hook_prepare_cmd "$1"

  # Code that is hidden or runs unseen cannot be checked, so it always asks.
  if [[ $LC =~ (-encodedcommand|-enc[[:space:]]|frombase64string|base64[[:space:]]+(-d|--decode)) ]]; then
    hook_ask "${DELETE_CTX}encoded command, cannot verify what it deletes"
  fi
  if [[ $LC =~ (os\.remove|os\.unlink|os\.rmdir|shutil\.rmtree|\.unlink\(|\.rmdir\(|fs\.rm|rimraf|\.delete\(|file\.delete|directory\.delete|\.moveto\() ]]; then
    hook_ask "${DELETE_CTX}inline code that deletes files"
  fi
  if [[ $LC =~ (io\.|\[)(file|directory)\]::(delete|move|replace|copy|writeall[a-z]*)\(|(deletefile|deletedirectory)\( ]]; then
    hook_ask "${DELETE_CTX}.NET call that deletes, moves or overwrites files"
  fi

  # Media managers and torrent clients delete the files on disk when deleteFiles is true.
  if [[ $LC =~ deletefiles[[:space:]]*[=:][[:space:]]*\$?true ]]; then
    hook_ask "${DELETE_CTX}API call that deletes files on disk (deleteFiles=true)"
  fi

  # SQL
  if [[ $LC =~ (drop|truncate)[[:space:]]+(table|database|schema|view|index|collection) ]]; then
    hook_ask "${DELETE_CTX}SQL drop or truncate"
  fi
  if [[ $LC =~ delete[[:space:]]+from ]] && [[ $LC != *where* ]]; then
    hook_ask "${DELETE_CTX}SQL DELETE without WHERE"
  fi

  if [[ ${2:-0} == 2 ]]; then
    if [[ $LC =~ $DELETE_SHELLOUT ]]; then hook_ask "${DELETE_CTX}code runs a delete command"; fi
    return 0
  fi

  (( ${2:-0} )) || _delete_redirects

  # Scripts the command runs are collected here and read after the loop, because checking one
  # reuses LC, SEGS and RESTS. Script text does not follow further scripts.
  hook_split
  local seg i
  local -a runs=()
  for seg in "${SEGS[@]}"; do
    RESTS=()
    RESTS_RAW=()
    hook_rests "$seg"
    for i in "${!RESTS[@]}"; do
      _delete_rest "${RESTS[i]}" "${2:-0}"
      if (( ! ${2:-0} )); then
        _delete_run_target "${RESTS[i]}" "${RESTS_RAW[i]}"
        if [[ -n $RUN ]]; then runs+=("$RUN"); fi
      fi
    done
  done
  if (( ${#runs[@]} )); then _delete_run_scripts "${runs[@]}"; fi
  return 0
}

# New text for a script file, so a delete written into a script is seen before the script runs.
_delete_script() {
  [[ -n $FILE && -n $CONTENT && ${FILE,,} =~ $DELETE_SCRIPT_EXT ]] || return 0
  DELETE_CTX="$TOOL script text (${FILE##*[\\/]}): "
  _delete_text "$CONTENT" "$(_delete_mode "$FILE")"
  DELETE_CTX=
  return 0
}

guard_delete() {
  case $TOOL in
    Bash|PowerShell)
      _delete_text "$CMD" ;;
    Write)
      if [[ -n $FILE ]]; then TARGETS=("$FILE"); hook_overwrite_check "Write"; fi
      _delete_script ;;
    Edit|NotebookEdit)
      _delete_script ;;
    Artifact|ArtifactData)
      if [[ $ACTION == delete ]]; then hook_ask "$TOOL delete action"; fi ;;
    CronDelete|TaskStop)
      hook_ask "$TOOL removes a scheduled or running task" ;;
    mcp__*)
      if [[ ${TOOL,,} =~ (delete|remove|destroy|drop|purge|unlink|erase) ]]; then hook_ask "$TOOL looks destructive"; fi ;;
  esac
  return 0
}

# Run directly: check one payload from stdin.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh" 2>/dev/null ||
    { echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"hook library could not be loaded, so this call needs confirmation"}}'; exit 0; }
  hook_init guard-delete.sh
  hook_read_input || hook_ask "could not read the hook input"
  guard_delete
  exit 0
fi
