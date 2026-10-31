#!/usr/bin/env bash
# Interactive, selective installer for dev-config. Copies the Claude Code status line, the Antigravity
# CLI status line and the git aliases to where each tool reads them, and wires them into the tools'
# settings. Safe to re-run: unchanged files are skipped, replaced files are backed up first.
# The Claude Code guard hooks are installed from ai-common, not from here; claude-old-hooks removes
# the copy this repo used to install.
#
# Usage: bash install.sh [options]
#   (no options)      menu: pick what to install
#   --list            show what is installed and what is pending, then exit
#   --all             install everything, no menu
#   --only a,b        install only the named items, no menu
#   --skip a,b        leave the named items out (with --all)
#   --dry-run         show what would change and write nothing
#   -y, --yes         answer yes to questions (replacing a different statusLine)
#
# Folders can be redirected with CLAUDE_DIR (default ~/.claude) and GEMINI_DIR
# (default ~/.gemini/antigravity-cli).
set -u

# Native tools (jq, git) must receive arguments untouched under Git Bash.
export MSYS2_ARG_CONV_EXCL='*'

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR=${CLAUDE_DIR:-$HOME/.claude}
GEMINI_DIR=${GEMINI_DIR:-$HOME/.gemini/antigravity-cli}
BACKUP_DIR=$CLAUDE_DIR/dev-config-backups/$(date +%Y%m%d-%H%M%S)

case $(uname -s) in
  MINGW*|MSYS*|CYGWIN*) WINDOWS=1; PLATFORM='Windows (Git Bash)' ;;
  *)                    WINDOWS=0; PLATFORM='Linux' ;;
esac

ITEMS=(claude-old-hooks claude-statusline claude-settings-statusline claude-settings-deny
       antigravity-statusline git-aliases)

DRY=0; YES=0; MODE=menu; ONLY=''; SKIP=''; SELECTED=' '; CHANGES=0; SKIPPED=0
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# The hook scripts this repo used to copy to ~/.claude/hooks. They now come from ai-common, which
# installs them to ~/.claude/hooks/guards/scripts/. local.sh is not listed: ai-common reads it too.
OLD_HOOKS=(audit backup guard-delete guard-git guard-network guard-protect guard-secrets
           guard-workspace lib notify posttool-check pretool prompt-check session-start)

# --- output helpers ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
skip() { SKIPPED=$((SKIPPED + 1)); }  # an item the installer declined to apply

tilde() { local p=$1; [[ $p == "$HOME"* ]] && p="~${p#"$HOME"}"; printf '%s' "$p"; }

ask_yn() {  # $1 = question. --yes answers yes; with no terminal the answer is no
  (( YES )) && return 0
  [[ -t 0 ]] || { say "  $1 [skipped: no terminal, use --yes]"; return 1; }
  local a; read -r -p "  $1 [y/N] " a
  [[ $a == [yY]* ]]
}

is_sel() { [[ $SELECTED == *" $1 "* ]]; }
toggle() { if is_sel "$1"; then SELECTED=${SELECTED/ $1 / }; else SELECTED+="$1 "; fi; }

# --- file helpers -----------------------------------------------------------------------------

file_state() {  # $1 source, $2 destination -> new | changed | same
  if [[ ! -f $2 ]]; then echo new
  elif cmp -s "$1" "$2"; then echo same
  else echo changed; fi
}

files_state() {  # $1 destination dir, rest = sources -> same | new | changed
  local dest=$1 f s out=same; shift
  for f in "$@"; do
    s=$(file_state "$f" "$dest/${f##*/}")
    if [[ $s == changed ]]; then out=changed
    elif [[ $s == new && $out == same ]]; then out=new; fi
  done
  echo "$out"
}

backup_file() {  # keeps the file that is about to be replaced
  mkdir -p "$BACKUP_DIR" && cp "$1" "$BACKUP_DIR/$(printf '%s' "$1" | tr '/\\:' '___')"
}

copy_files() {  # $1 destination dir, rest = sources
  local dest=$1 f name s; shift
  for f in "$@"; do
    name=${f##*/}; s=$(file_state "$f" "$dest/$name")
    [[ $s == same ]] && continue
    if (( DRY )); then say "  would copy $name ($s)"; continue; fi
    mkdir -p "$dest"
    [[ $s == changed ]] && backup_file "$dest/$name"
    if cp "$f" "$dest/$name"; then say "  copied $name ($s)"; CHANGES=$((CHANGES + 1)); else warn "could not copy $name"; fi
  done
}

# --- JSON settings helpers (jq) ---------------------------------------------------------------

# Every filter sees the current file as $cur and the fragment to merge in as $frag.
PRE='input as $cur | input as $frag | '

# Drops the hook entries that run one of the old scripts (bash ~/.claude/hooks/<name>.sh) and keeps
# every other hook, including ai-common's, whose paths end in /hooks/guards/scripts/<name>.sh.
F_OLD_HOOKS='$cur | if .hooks then
    .hooks |= (map_values(map(.hooks = ((.hooks // []) | map(select((.command // "") | test("^bash ~/\\.claude/hooks/[a-z-]+\\.sh$") | not))))
               | map(select(.hooks | length > 0)))
               | with_entries(select(.value | length > 0)))
    | if .hooks == {} then del(.hooks) else . end
  else . end'
F_STATUS='$cur | .statusLine = $frag.statusLine'
F_DENY='($cur.permissions.deny // []) as $d | $cur | .permissions.deny = ($d + ($frag.permissions.deny - $d))'

json_merge() {  # $1 settings file, $2 filter, $3 fragment JSON -> merged JSON; fails if the file is not JSON
  local cur='{}' out
  [[ -s $1 ]] && cur=$(cat "$1")
  [[ -z ${cur//[[:space:]]/} ]] && cur='{}'
  out=$(printf '%s\n%s\n' "$cur" "$3" | jq -n "$PRE$2" 2>/dev/null) || return 1
  printf '%s\n' "$out" | tr -d '\r'
}

json_state() {  # $1 settings file, $2 filter, $3 fragment JSON -> same | pending | invalid
  local new cur='{}'
  new=$(json_merge "$1" "$2" "$3") || { echo invalid; return; }
  [[ -s $1 ]] && cur=$(cat "$1")
  [[ -z ${cur//[[:space:]]/} ]] && cur='{}'
  if [[ "$(jq -cS . <<<"$cur" | tr -d '\r')" == "$(jq -cS . <<<"$new" | tr -d '\r')" ]]; then echo same; else echo pending; fi
}

json_apply() {  # $1 settings file, $2 filter, $3 fragment JSON, $4 what changes
  local new
  new=$(json_merge "$1" "$2" "$3") || { warn "$(tilde "$1") is not valid JSON; left alone"; skip; return 0; }
  if [[ $(json_state "$1" "$2" "$3") == same ]]; then return 0; fi
  if (( DRY )); then say "  would update $(tilde "$1"): $4"; return 0; fi
  mkdir -p "$(dirname "$1")"
  [[ -f $1 ]] && backup_file "$1"
  if printf '%s\n' "$new" >"$1.tmp" && mv "$1.tmp" "$1"; then
    say "  updated $(tilde "$1"): $4"; CHANGES=$((CHANGES + 1))
  else
    warn "could not write $(tilde "$1")"; rm -f "$1.tmp"
  fi
}

jq_get() { jq -c "$2" <"$1" 2>/dev/null | tr -d '\r'; }

confirm_statusline() {  # $1 settings file, $2 desired statusLine (compact JSON) -> 0 when it may be set
  local existing; [[ -f $1 ]] && existing=$(jq_get "$1" '.statusLine // empty') || existing=''
  [[ -z $existing || $existing == "$2" ]] && return 0
  ask_yn "$(tilde "$1") already has a statusLine ($existing). Replace it?"
}

# --- items ------------------------------------------------------------------------------------

FRAG_STATUS=$(cat "$REPO/claude-code/settings/statusline.json")
FRAG_DENY=$(cat "$REPO/claude-code/settings/deny.json")

CLAUDE_SETTINGS=$CLAUDE_DIR/settings.json
GEMINI_SETTINGS=$GEMINI_DIR/settings.json

item_desc() {
  case $1 in
    claude-old-hooks)           echo "Remove the old guard hooks (now installed from ai-common); keeps local.sh" ;;
    claude-statusline)          echo "Status line script -> $(tilde "$CLAUDE_DIR/statusline.sh")" ;;
    claude-settings-statusline) echo "Set statusLine in settings.json" ;;
    claude-settings-deny)       echo "Add deny rules for disk-wiping commands to settings.json" ;;
    antigravity-statusline)     echo "Antigravity CLI status line -> $(tilde "$GEMINI_DIR") + its settings.json" ;;
    git-aliases)                echo "Include git/.gitconfig from your global git config" ;;
  esac
}

antigravity_files() {
  AG_SRC=("$REPO/antigravity-cli/statusline.sh")
  (( WINDOWS )) && AG_SRC+=("$REPO/antigravity-cli/statusline.bat")
}

antigravity_command() {
  local p
  if (( WINDOWS )); then
    p=$(cygpath -w "$GEMINI_DIR/statusline.bat")
    [[ $p == *" "* ]] && p="\"$p\""
    printf '%s' "$p"
  else
    printf 'bash "%s"' "$GEMINI_DIR/statusline.sh"
  fi
}

antigravity_fragment() { CMD=$(antigravity_command) jq -nc '{statusLine: {type: "command", command: $ENV.CMD}}' | tr -d '\r'; }

git_include_path() { if (( WINDOWS )); then cygpath -m "$REPO/git/.gitconfig"; else printf '%s' "$REPO/git/.gitconfig"; fi; }

git_included() { git config --global --get-all include.path 2>/dev/null | tr -d '\r' | grep -Fxq -- "$(git_include_path)"; }

old_hook_files() {  # prints the old hook scripts still in ~/.claude/hooks; fails when there are none
  local n found=1
  for n in "${OLD_HOOKS[@]}"; do
    [[ -f $CLAUDE_DIR/hooks/$n.sh ]] && { printf '%s\n' "$CLAUDE_DIR/hooks/$n.sh"; found=0; }
  done
  return $found
}

# Unregisters the old hooks, then moves their scripts into the backup folder. In that order:
# pretool.sh is registered with onFailure "block", so removing it first would block every tool call.
remove_old_hooks() {
  local f moved=0
  local -a files
  if [[ $(json_state "$CLAUDE_SETTINGS" "$F_OLD_HOOKS" '{}') == invalid ]]; then
    warn "$(tilde "$CLAUDE_SETTINGS") is not valid JSON; old hooks left alone"; skip; return 0
  fi
  json_apply "$CLAUDE_SETTINGS" "$F_OLD_HOOKS" '{}' "old hook entries removed"
  mapfile -t files < <(old_hook_files)
  for f in "${files[@]}"; do
    if (( DRY )); then say "  would move ${f##*/} to the backup folder"; continue; fi
    mkdir -p "$BACKUP_DIR/old-hooks" && mv "$f" "$BACKUP_DIR/old-hooks/" && moved=$((moved + 1))
  done
  if (( moved )); then say "  moved $moved old hook script(s) to $(tilde "$BACKUP_DIR/old-hooks")"; CHANGES=$((CHANGES + 1)); fi
  say "  Install the guards from ai-common: apm install -g LasterBergamot/ai-common/packages/guards#<tag> --target claude"
}

state_of() {  # -> up to date | new | changed | pending | needs jq | invalid json
  local s
  if (( ! HAVE_JQ )) && [[ $1 == claude-settings-* || $1 == claude-old-hooks || $1 == antigravity-statusline ]]; then echo 'needs jq'; return; fi
  case $1 in
    claude-old-hooks)
      s=$(json_state "$CLAUDE_SETTINGS" "$F_OLD_HOOKS" '{}')
      if [[ $s == same ]] && old_hook_files >/dev/null; then s=pending; fi ;;
    claude-statusline) s=$(files_state "$CLAUDE_DIR" "$REPO/claude-code/statusline.sh") ;;
    claude-settings-statusline) s=$(json_state "$CLAUDE_SETTINGS" "$F_STATUS" "$FRAG_STATUS") ;;
    claude-settings-deny)       s=$(json_state "$CLAUDE_SETTINGS" "$F_DENY" "$FRAG_DENY") ;;
    antigravity-statusline)
      antigravity_files
      s=$(files_state "$GEMINI_DIR" "${AG_SRC[@]}")
      if [[ $s == same ]]; then s=$(json_state "$GEMINI_SETTINGS" "$F_STATUS" "$(antigravity_fragment)"); fi ;;
    git-aliases) git_included && s=same || s=pending ;;
  esac
  case $s in same) echo 'up to date' ;; invalid) echo 'invalid json' ;; *) echo "$s" ;; esac
}

apply_item() {
  case $1 in
    claude-old-hooks)
      remove_old_hooks ;;
    claude-statusline)
      copy_files "$CLAUDE_DIR" "$REPO/claude-code/statusline.sh" ;;
    claude-settings-statusline)
      if [[ ! -f $CLAUDE_DIR/statusline.sh ]] && ! { (( DRY )) && is_sel claude-statusline; }; then
        warn "statusline.sh is not installed; not setting statusLine. Install claude-statusline too."; skip; return 0
      fi
      if confirm_statusline "$CLAUDE_SETTINGS" "$(jq -c .statusLine <<<"$FRAG_STATUS" | tr -d '\r')"; then
        json_apply "$CLAUDE_SETTINGS" "$F_STATUS" "$FRAG_STATUS" "statusLine"
      else skip; fi ;;
    claude-settings-deny)
      json_apply "$CLAUDE_SETTINGS" "$F_DENY" "$FRAG_DENY" "permissions.deny" ;;
    antigravity-statusline)
      antigravity_files
      copy_files "$GEMINI_DIR" "${AG_SRC[@]}"
      local frag; frag=$(antigravity_fragment)
      if confirm_statusline "$GEMINI_SETTINGS" "$(jq -c .statusLine <<<"$frag" | tr -d '\r')"; then
        json_apply "$GEMINI_SETTINGS" "$F_STATUS" "$frag" "statusLine"
      else skip; fi ;;
    git-aliases)
      if git_included; then return; fi
      if (( DRY )); then say "  would add include.path $(git_include_path) to the global git config"
      elif git config --global --add include.path "$(git_include_path)"; then
        say "  added include.path $(git_include_path)"; CHANGES=$((CHANGES + 1))
      else warn "git config failed"; fi ;;
  esac
}

# --- menu -------------------------------------------------------------------------------------

STATE=()
load_states() { local id; STATE=(); for id in "${ITEMS[@]}"; do STATE+=("$(state_of "$id")"); done; }

selectable() { [[ ${STATE[$1]} != 'needs jq' && ${STATE[$1]} != 'invalid json' ]]; }

preselect_pending() {
  local i; SELECTED=' '
  for i in "${!ITEMS[@]}"; do
    case ${STATE[i]} in new|changed|pending) SELECTED+="${ITEMS[i]} " ;; esac
  done
}

show_list() {
  local i mark
  for i in "${!ITEMS[@]}"; do
    if [[ $1 == menu ]]; then is_sel "${ITEMS[i]}" && mark='[x]' || mark='[ ]'; else mark=''; fi
    printf ' %d  %s %-27s %-13s %s\n' $((i + 1)) "$mark" "${ITEMS[i]}" "${STATE[i]}" "$(item_desc "${ITEMS[i]}")"
  done
}

run_menu() {
  local ans tok n
  preselect_pending
  while true; do
    say; say "dev-config installer: $PLATFORM"; say
    show_list menu
    say
    read -r -p "Number toggles an item, a = everything pending, n = none, Enter = install, q = quit: " ans \
      || die "no input for the menu; use --all or --only a,b (see --help)"
    [[ -z $ans ]] && break
    for tok in ${ans//,/ }; do
      if [[ $tok == q ]]; then exit 0
      elif [[ $tok == a ]]; then preselect_pending
      elif [[ $tok == n ]]; then SELECTED=' '
      elif [[ $tok =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#ITEMS[@]} )); then
        n=$((tok - 1))
        if selectable "$n"; then toggle "${ITEMS[n]}"; else say "  ${ITEMS[n]}: ${STATE[n]}; cannot be installed"; fi
      else say "  ignored: $tok"; fi
    done
  done
}

valid_item() { local id; for id in "${ITEMS[@]}"; do [[ $id == "$1" ]] && return 0; done; return 1; }

# --- main -------------------------------------------------------------------------------------

while (( $# )); do
  case $1 in
    --list)    MODE=list ;;
    --all)     MODE=all ;;
    --only)    MODE=only; ONLY=${2:-}; shift ;;
    --skip)    SKIP=${2:-}; shift ;;
    --dry-run) DRY=1 ;;
    -y|--yes)  YES=1 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//' ; exit 0 ;;
    *)         die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

load_states

case $MODE in
  list) show_list list; exit 0 ;;
  menu)
    run_menu ;;
  all)
    SELECTED=' '
    for i in "${!ITEMS[@]}"; do selectable "$i" && SELECTED+="${ITEMS[i]} "; done ;;
  only)
    [[ -n $ONLY ]] || die "--only needs a comma-separated list of items"
    SELECTED=' '
    for id in ${ONLY//,/ }; do
      valid_item "$id" || die "unknown item: $id (see --list)"
      SELECTED+="$id "
    done ;;
esac

for id in ${SKIP//,/ }; do
  valid_item "$id" || die "unknown item in --skip: $id (see --list)"
  is_sel "$id" && toggle "$id"
done

if [[ $SELECTED == ' ' ]]; then say "Nothing selected."; exit 0; fi

(( DRY )) && say "Dry run: nothing will be written."
for i in "${!ITEMS[@]}"; do
  id=${ITEMS[i]}
  is_sel "$id" || continue
  if ! selectable "$i"; then warn "$id skipped: ${STATE[i]}"; continue; fi
  say "$id"
  apply_item "$id"
done

say
if (( DRY )); then say "Dry run finished; nothing was written."
elif (( CHANGES )); then
  say "$CHANGES change(s) made."
  [[ -d $BACKUP_DIR ]] && say "Replaced files were saved to $(tilde "$BACKUP_DIR")."
  say "Restart Claude Code, or run /hooks, to pick up hook and settings changes."
elif (( ! SKIPPED )); then say "Everything selected was already up to date."; fi
if (( SKIPPED )); then say "$SKIPPED item(s) skipped; see the messages above."; fi

