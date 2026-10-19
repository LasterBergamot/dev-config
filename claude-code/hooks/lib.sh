# Shared helpers for the Claude Code hooks. Sourced by the hooks, never run directly.
#
# Guard hooks call hook_init, which turns any unexpected error into an "ask", so a broken
# guard can never let a risky call through silently. Logging hooks (audit, backup, notify,
# session start, prompt check) skip hook_init, so a failure there never blocks a tool call.

set -f  # the analysed text is word-split without globbing

HOOK_LOG_DIR=$HOME/.claude/logs

# jq binary used by the hooks. Chocolatey's jq.exe shim adds about 25 ms to every call, so the
# real binary is used when it is there. HOOK_JQ overrides the choice.
if [[ -z ${HOOK_JQ-} ]]; then
  HOOK_JQ=jq
  for _c in /c/ProgramData/chocolatey/lib/jq/tools/jq.exe; do
    if [[ -x $_c ]]; then HOOK_JQ=$_c; fi
  done
fi

# Lowercase, forward-slash form of a path, used as the comparison base.
_hook_base() {
  NB=${1,,}
  NB=${NB//\\//}
  NB=${NB%/}
}
_hook_base "${TEMP:-}";             T_TEMP=$NB
_hook_base "${TMP:-}";              T_TMP=$NB
_hook_base "${LOCALAPPDATA:-}";     T_LAD=$NB
_hook_base "${USERPROFILE:-$HOME}"; T_HOME=$NB

# Locations whose writes ask, matched as substrings of lowercase text. Drives, media libraries and
# container data differ per machine, so local.sh fills this in. Nothing is protected by default.
HOOK_PROTECTED=()

# Machine-specific rules: protected locations and the hook_local_protect function. Optional and
# never committed. HOOK_LOCAL overrides the path, which the tests use.
HOOK_LOCAL=${HOOK_LOCAL:-$HOME/.claude/hooks/local.sh}
if [[ -f $HOOK_LOCAL ]]; then source "$HOOK_LOCAL"; fi

# Configuration the agent must not change without asking. Agents, skills, commands, plugins, the
# status line and MCP server lists all run code or steer Claude, so they count as configuration.
HOOK_SELF=(/.claude/settings /.claude/hooks/ /.claude/claude.md /.git/hooks/ .wslconfig
  /.claude/agents/ /.claude/skills/ /.claude/commands/ /.claude/plugins/ /.claude/statusline
  /.claude.json .mcp.json)

# Words that write, move or delete. Matched against the basename of each token. Includes the
# PowerShell 5.1 aliases: sc is Set-Content there, not only the service tool.
HOOK_MUTATING=' rm rmdir unlink shred del erase rd ri remove-item clear-content clc truncate mv move move-item mi cp copy copy-item cpi ren rename rename-item rni set-content sc out-file add-content ac set-item si tee new-item mkdir md ni chmod chown icacls takeown set-itemproperty new-itemproperty remove-itemproperty rp dd '

# .NET file calls that write, move or delete, matched against lowercase command text. They name
# no cmdlet, so the word list above cannot see them.
HOOK_DOTNET_WRITE='(io\.|\[)(file|directory)\]::(delete|move|replace|copy|create|createtext|writeall[a-z]*|appendall[a-z]*)|\.(delete|moveto|copyto)\(|(deletefile|deletedirectory)\('

# Credential-looking paths, matched against normalized paths and lowercase command text.
HOOK_CREDENTIAL_PATHS=(
  '(^|[ /])\.env($|[ ./])'
  '(^|[ /])[^ /]*\.(pem|key|pfx|p12|kdbx)($|[ ])'
  '(^|[ /])id_(rsa|dsa|ecdsa|ed25519)'
  '(^|[ /])\.(ssh|aws|azure|gnupg|kube)/'
  '(^|[ /])\.(npmrc|pypirc|netrc|git-credentials)($|[ ])'
  '(^|[ /])\.credentials\.json'
  '(^|[ /])(credentials|secrets?|tokens?)\.(json|ya?ml|toml|ini|txt)($|[ ])'
  '/(login data|cookies)($|[ ])'
  '/appdata/(local|roaming)/(google/chrome|microsoft/edge|mozilla/firefox)'
)

# Credential formats, matched against raw text (case-sensitive).
HOOK_CREDENTIAL_TEXT=(
  'AKIA[0-9A-Z]{16}'
  'gh[pousr]_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'sk-[A-Za-z0-9_-]{20,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'AIza[0-9A-Za-z_-]{35}'
)

# JSON string literal for $1, stored in JS. No subshell, so it is cheap on the hot path.
hook_jsv() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  JS=\"$s\"
}

# Appends one JSON object line to today's audit log. $1 = members without braces.
hook_log() {
  local day ts
  printf -v day '%(%Y%m%d)T' -1
  printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' -1
  [[ -d $HOOK_LOG_DIR ]] || mkdir -p "$HOOK_LOG_DIR" 2>/dev/null || :
  printf '{"ts":"%s",%s}\n' "$ts" "$1" >>"$HOOK_LOG_DIR/audit-$day.jsonl" 2>/dev/null || :
  return 0
}

# Answers "ask" for the harness and stops. $1 = reason shown to the user.
hook_ask() {
  local reason=${1:0:400}
  hook_jsv "$HOOK_NAME"; local name=$JS
  hook_jsv "$reason";    local why=$JS
  hook_log "\"hook\":$name,\"decision\":\"ask\",\"reason\":$why"
  hook_jsv "[$HOOK_NAME] $reason"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":%s}}\n' "$JS"
  exit 0
}

# Marks this process as a guard: any unexpected error from here on becomes an "ask".
hook_init() {  # $1 = hook file name
  HOOK_NAME=$1
  HOOK_GUARD=1
  set -E
  hook_guard_on
}

hook_guard_on() {
  trap 'hook_ask "internal error at line $LINENO, so this call needs your confirmation"' ERR
}

# Logging code runs with the fail-closed trap off, so its errors never block a call.
hook_guard_off() {
  trap - ERR
}

# Reads the hook payload from stdin in one jq call. Sets TOOL, CMD, FILE, CONTENT, ACTION, CWD,
# CWD_N, SESSION, PROMPT and MESSAGE. Returns 1 when the payload is malformed, or when a guard
# gets a payload with no tool name.
hook_read_input() {
  command -v "$HOOK_JQ" >/dev/null 2>&1 || return 1
  local parsed
  parsed=$("$HOOK_JQ" -j '[.tool_name, .tool_input.command, (.tool_input.file_path // .tool_input.notebook_path),
    (.tool_input.content // .tool_input.new_string // .tool_input.new_source), .tool_input.action, .cwd, .session_id, .prompt, .message]
    | map(. // "" | tostring) | join("\u001f")') || return 1
  local IFS=$'\x1f'
  local -a f
  f=($parsed)
  TOOL=${f[0]-}; CMD=${f[1]-}; FILE=${f[2]-}; CONTENT=${f[3]-}; ACTION=${f[4]-}
  CWD=${f[5]-}; SESSION=${f[6]-}; PROMPT=${f[7]-}; MESSAGE=${f[8]-}
  [[ -n $CWD ]] || CWD=$PWD
  _hook_base "$CWD"; CWD_N=$NB
  [[ -n $TOOL || -z ${HOOK_GUARD-} ]]
}

# Path as written in a tool call -> NP: absolute, lowercase, forward slashes, no . or ..
hook_norm_path() {
  local p=${1,,}
  p=${p//\\//}
  p=${p//\"/}
  p=${p//\'/}
  p=${p//\$env:temp/$T_TEMP}
  p=${p//\$env:tmp/$T_TEMP}
  p=${p//\%temp\%/$T_TEMP}
  p=${p//\%tmp\%/$T_TEMP}
  p=${p//\$env:localappdata/$T_LAD}
  p=${p//\%localappdata\%/$T_LAD}
  p=${p//\$env:userprofile/$T_HOME}
  p=${p//\%userprofile\%/$T_HOME}
  if [[ $p == '~'* ]]; then p=$T_HOME${p:1}; fi
  if [[ $p =~ ^/([a-z])(/.*)?$ ]]; then p=${BASH_REMATCH[1]}:${BASH_REMATCH[2]}; fi
  if [[ $p != [a-z]:* && $p != /* ]]; then p=$CWD_N/$p; fi
  local IFS=/ s
  local -a seg out=()
  seg=($p)
  for s in "${seg[@]}"; do
    case $s in
      ''|.) ;;
      ..) if (( ${#out[@]} )); then unset 'out[-1]'; fi ;;
      *) out+=("$s") ;;
    esac
  done
  if [[ $p == /* ]]; then NP="/${out[*]}"; else NP="${out[*]}"; fi
}

# NP is inside the temp folders, including the session scratchpad. Git Bash sets TEMP to /tmp,
# which is the same folder as %LOCALAPPDATA%\Temp, so the Windows locations are checked too.
hook_is_temp() {
  [[ -n $T_TEMP && ($1 == "$T_TEMP" || $1 == "$T_TEMP"/*) ]] && return 0
  [[ -n $T_TMP && $1 == "$T_TMP"/* ]] && return 0
  [[ -n $T_LAD && $1 == "$T_LAD/temp"/* ]] && return 0
  [[ -n $T_HOME && $1 == "$T_HOME/appdata/local/temp"/* ]] && return 0
  [[ $1 == /tmp/* ]] && return 0
  return 1
}

# $1 (lowercase text) names a protected location. Sets PROT to the match.
hook_protected_in() {
  local p
  for p in "${HOOK_PROTECTED[@]}"; do
    if [[ $1 == *"$p"* ]]; then PROT=$p; return 0; fi
  done
  return 1
}

# $1 (lowercase text) writes, moves, deletes or redirects.
hook_has_mutating() {
  if [[ $1 == *'>'* ]]; then return 0; fi
  if [[ $1 =~ $HOOK_DOTNET_WRITE ]]; then return 0; fi
  local IFS=$' \t\n'
  local -a w
  local t
  w=($1)
  for t in "${w[@]}"; do
    t=${t##*/}
    if [[ $HOOK_MUTATING == *" $t "* ]]; then return 0; fi
  done
  return 1
}

# Raw command -> LC: lowercase, no quotes, forward slashes, environment shortcuts expanded.
hook_prepare_cmd() {
  LC=${1,,}
  LC=${LC//\\//}
  LC=${LC//\"/ }
  LC=${LC//\'/ }
  LC=${LC//\$env:temp/$T_TEMP}
  LC=${LC//\$env:tmp/$T_TEMP}
  LC=${LC//\%temp\%/$T_TEMP}
  LC=${LC//\%tmp\%/$T_TEMP}
  LC=${LC//\$env:localappdata/$T_LAD}
  LC=${LC//\%localappdata\%/$T_LAD}
  LC=${LC//\$env:userprofile/$T_HOME}
  LC=${LC//\%userprofile\%/$T_HOME}
}

# LC -> SEGS: the command cut at ; & | ( ) ` { } and line breaks.
hook_split() {
  local s=$LC
  s=${s//$'\r'/;}
  s=${s//$'\n'/;}
  s=${s//&/;}
  s=${s//|/;}
  s=${s//(/;}
  s=${s//)/;}
  s=${s//\`/;}
  s=${s//\{/;}
  s=${s//\}/;}
  local IFS=';'
  SEGS=($s)
}

# One segment -> appends each command position to RESTS, as the command name followed by its
# arguments, and the command token as written (with its path) to RESTS_RAW at the same index.
# Looks through wrappers such as sudo, env, xargs, bash -c and cmd /c.
hook_rests() {
  local IFS=$' \t\n'
  local -a t
  local i tok expect=1
  t=($1)
  for (( i = 0; i < ${#t[@]}; i++ )); do
    tok=${t[i]}
    if (( expect )); then
      case $tok in
        -*|/[a-z]|*=*|sudo|env|command|time|nohup|nice|xargs|exec|builtin|doas|call|start-process|then|do|else|if|while|until)
          ;;
        *)
          RESTS_RAW+=("$tok")
          tok=${tok##*/}
          tok=${tok%.exe}
          t[i]=$tok
          RESTS+=("${t[*]:i}")
          expect=0
          ;;
      esac
    fi
    case ${t[i]} in
      -c|-command|-encodedcommand|-exec|-execdir|-ok|-okdir|eval|/c|/k|then|do|else) expect=1 ;;
    esac
  done
  return 0
}

# One command position -> TARGETS: its arguments that are not options.
hook_targets() {
  local IFS=$' \t\n'
  local -a t
  local i
  TARGETS=()
  t=($1)
  for (( i = 1; i < ${#t[@]}; i++ )); do
    case ${t[i]} in
      -*|/[a-z]|*=*) ;;
      *) TARGETS+=("${t[i]}") ;;
    esac
  done
  return 0
}

# Asks unless every target is a plain path inside the temp folders. $1 = what the call does.
hook_guard_targets() {
  local t
  if (( ! ${#TARGETS[@]} )); then hook_ask "$1 with no clear target"; fi
  for t in "${TARGETS[@]}"; do
    case $t in *'$'*|*'%'*|*'*'*|*'?'*|*'['*) hook_ask "$1: unresolved target $t" ;; esac
    hook_norm_path "$t"
    hook_is_temp "$NP" || hook_ask "$1: $t"
  done
  return 0
}

# Asks if any target already exists outside the temp folders. $1 = what the call does.
hook_overwrite_check() {
  local t
  for t in "${TARGETS[@]}"; do
    case $t in *'$'*|*'%'*|*'*'*|*'?'*|*'['*) hook_ask "$1: unresolved target $t" ;; esac
    hook_norm_path "$t"
    if [[ -e $NP ]] && ! hook_is_temp "$NP"; then hook_ask "$1 would overwrite $t"; fi
  done
  return 0
}

# $1 = name of a "description" "regex" array. Asks on the first command position that matches.
hook_scan_rules() {
  local -n _pairs=$1
  local seg rest i
  for seg in "${SEGS[@]}"; do
    RESTS=()
    hook_rests "$seg"
    for rest in "${RESTS[@]}"; do
      for (( i = 0; i < ${#_pairs[@]}; i += 2 )); do
        if [[ $rest =~ ${_pairs[i+1]} ]]; then hook_ask "${_pairs[i]}: ${rest:0:160}"; fi
      done
    done
  done
  return 0
}

# $1 = name of a "description" "regex" array. Matched against the whole command (LC).
hook_scan_text() {
  local -n _pairs=$1
  local i
  for (( i = 0; i < ${#_pairs[@]}; i += 2 )); do
    if [[ $LC =~ ${_pairs[i+1]} ]]; then hook_ask "${_pairs[i]}"; fi
  done
  return 0
}
