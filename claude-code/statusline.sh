#!/usr/bin/env bash
# ==============================================================================
# Claude Code Custom Status Line (bash + jq + git + gh)
# Line 1: model, style, git, folder/project, session, location
# Line 2: context, quota, prompt cache, cost/time, PR status, flags, version
# Input: session JSON on stdin (see code.claude.com/docs/en/statusline)
#
# Speed: every external process costs ~35 ms on Windows. The foreground path
# runs jq once, reads cached git results, and never waits on gh (gh refreshes
# in the background).
# ==============================================================================

IFS= read -r -d '' input || true
[ -z "$input" ] && exit 0
export LC_NUMERIC=C

CACHE_DIR="${TMPDIR:-/tmp}/claude-statusline"
GIT_TTL=5    # seconds
PR_TTL=60    # seconds

# One jq pass for everything. Percentages are rounded here, and "left" is computed here.
mapfile -t f < <(jq -rb '
  def r: if . == null then "" else round | tostring end;
  def n: if . == null then "" else tostring end;
  def left: if . == null then "" else (100 - .) | round | tostring end;
  (.model.display_name // .model.id // "Claude"),
  (.effort.level // ""),
  (if .thinking.enabled == true then "think" else "" end),
  (.workspace.current_dir // .cwd // ""),
  (.workspace.project_dir // ""),
  (.session_name // ""),
  ((.session_id // "")[0:8]),
  (.context_window.context_window_size | n),
  (.context_window.used_percentage | r),
  (.context_window.current_usage | if . then ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) else null end | n),
  (.rate_limits.five_hour.used_percentage | left),
  (.rate_limits.five_hour.resets_at | n),
  (.rate_limits.seven_day.used_percentage | left),
  (.rate_limits.seven_day.resets_at | n),
  (.cost.total_cost_usd | n),
  (.cost.total_lines_added | n),
  (.cost.total_lines_removed | n),
  (.cost.total_duration_ms | if . == null then "" else (. / 60000 | round | tostring) end),
  (.cost.total_api_duration_ms | if . == null then "" else (. / 60000 | round | tostring) end),
  (.context_window.total_output_tokens | n),
  (.version // ""),
  (.vim.mode // ""),
  (.agent.name // ""),
  (.output_style.name // ""),
  (if .fast_mode == true then "fast" else "" end),
  (.workspace.repo | if . then "\(.owner)/\(.name)" else "" end),
  (.worktree.name // ""),
  (.pr.number | n),
  (.exceeds_200k_tokens // false | if . then "true" else "" end),
  (.prompt_cache | if . == null then "" elif .caching_observed then (if .warm then "warm" else "cold" end) else "" end),
  (.prompt_cache.expires_at | n),
  (.prompt_cache.hit_ratio | if . == null then "" else (. * 100 | round | tostring) end),
  (.prompt_cache.recache_tokens_if_cold | n),
  (.rate_limits.spend_limit | if . == null then "" else "$\(.used_usd | round) of $\(.limit_usd | round)" end)
' 2>/dev/null <<< "$input")

[ ${#f[@]} -eq 0 ] && exit 0

model=${f[0]}; effort=${f[1]}; think=${f[2]}
cur_dir=${f[3]}; proj_dir=${f[4]}; sess_name=${f[5]}; sess_id=${f[6]}
ctx_max=${f[7]}; ctx_pct=${f[8]}; ctx_tokens=${f[9]}
five_left=${f[10]}; five_reset=${f[11]}; week_left=${f[12]}; week_reset=${f[13]}
cost=${f[14]}; lines_add=${f[15]}; lines_del=${f[16]}
dur_min=${f[17]}; api_min=${f[18]}; out_tokens=${f[19]}
version=${f[20]}; vim_mode=${f[21]}; agent=${f[22]}; style=${f[23]}; fast=${f[24]}
repo=${f[25]}; worktree=${f[26]}; pr_num=${f[27]}; over200k=${f[28]}
cache_state=${f[29]}; cache_expires=${f[30]}; cache_hit=${f[31]}; cache_rebuild=${f[32]}
spend=${f[33]}

# ANSI colors
RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
CYAN=$'\033[36m'; MAGENTA=$'\033[35m'; BLUE=$'\033[34m'; GREEN=$'\033[32m'
YELLOW=$'\033[33m'; RED=$'\033[31m'; GRAY=$'\033[90m'; WHITE=$'\033[97m'
SEP="${GRAY} │ ${RESET}"

# Helpers set globals instead of printing, so no subshells are needed.
# Used-% color: high usage is bad
used_color() {
  if [ "$1" -ge 80 ]; then COLOR=$RED
  elif [ "$1" -ge 50 ]; then COLOR=$YELLOW
  else COLOR=$GREEN; fi
}

# Left-% color: low remaining is bad
left_color() {
  if [ "$1" -le 20 ]; then COLOR=$RED
  elif [ "$1" -le 50 ]; then COLOR=$YELLOW
  else COLOR=$BLUE; fi
}

# Seconds -> SPAN: "2d4h", "3h12m", "45m"
fmt_span() {
  local s=$1 d h m
  if [ "$s" -le 0 ]; then SPAN="now"; return; fi
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then SPAN="${d}d${h}h"
  elif [ "$h" -gt 0 ]; then SPAN="${h}h${m}m"
  else SPAN="${m}m"; fi
}

# Tokens -> TOK: "62k" / "850"
fmt_tokens() {
  if [ "$1" -ge 1000 ]; then TOK="$(( ($1 + 500) / 1000 ))k"
  else TOK="$1"; fi
}

# 10-cell block bar for a 0-100 percentage -> BAR
bar() {
  local p=$1 filled i out=""
  [ "$p" -gt 100 ] && p=100
  filled=$(( p / 10 ))
  for ((i = 0; i < 10; i++)); do
    if [ "$i" -lt "$filled" ]; then out+="▓"; else out+="░"; fi
  done
  BAR=$out
}

# Git state for a directory -> GIT_STR (plain text). Cached GIT_TTL seconds.
# One `git status` call gives branch, upstream ahead/behind, stash and dirty state.
git_info() {
  local dir=$1 file ts="" status line head="" ab="" stash="" dirty="" last="" a b
  file="$CACHE_DIR/git-${dir//[^A-Za-z0-9]/_}"
  GIT_STR=""
  if [ -f "$file" ]; then
    { read -r ts; read -r GIT_STR; } < "$file"
    if (( EPOCHSECONDS - ts < GIT_TTL )); then return; fi
  fi

  status=$(git -C "$dir" status --porcelain=v2 --branch --show-stash 2>/dev/null)
  GIT_STR=""
  if [ -n "$status" ]; then
    while IFS= read -r line; do
      case $line in
        "# branch.head "*) head=${line#"# branch.head "} ;;
        "# branch.ab "*)   ab=${line#"# branch.ab "} ;;
        "# stash "*)       stash=${line#"# stash "} ;;
        "#"*) ;;
        *) dirty="*" ;;
      esac
    done <<< "$status"

    [ "$head" = "(detached)" ] && head="detached"
    GIT_STR="⎇ ${head}${dirty}"
    if [ -n "$ab" ]; then
      read -r a b <<< "$ab"
      [ "${a#+}" -gt 0 ] && GIT_STR+=" ↑${a#+}"
      [ "${b#-}" -gt 0 ] && GIT_STR+=" ↓${b#-}"
    else
      GIT_STR+=" (no upstream)"
    fi
    [ -n "$stash" ] && GIT_STR+=" stash:${stash}"
    last=$(git -C "$dir" log -1 --format=%ct 2>/dev/null)
    if [ -n "$last" ]; then fmt_span $(( EPOCHSECONDS - last )); GIT_STR+=" · ${SPAN} ago"; fi
  fi

  [ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR"
  printf '%s\n%s\n' "$EPOCHSECONDS" "$GIT_STR" > "$file"
}

# gh filter: CI state and review decision in one line
GH_FILTER='
  (.reviewDecision // "") as $rd
  | [.statusCheckRollup[]? | (.conclusion // .state // .status // "")] as $c
  | (if any($c[]; . == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED") then "✗ CI"
     elif any($c[]; . == "" or . == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "WAITING") then "● CI"
     elif ($c | length) > 0 then "✓ CI"
     else "" end) as $ci
  | (if $rd == "APPROVED" then "approved"
     elif $rd == "CHANGES_REQUESTED" then "changes requested"
     elif $rd == "REVIEW_REQUIRED" then "review needed"
     else "" end) as $rv
  | [$ci, $rv] | map(select(. != "")) | join(" · ")
'

# PR CI/review text -> PR_STR. Cached per directory and PR number.
# A stale value is shown at once, and gh refreshes in a background job.
pr_info() {
  local dir=$1 file ts="" lock lts=""
  file="$CACHE_DIR/pr-${dir//[^A-Za-z0-9]/_}-${pr_num}"
  lock="$file.lock"
  PR_STR=""
  if [ -f "$file" ]; then { read -r ts; read -r PR_STR; } < "$file"; fi
  if [ -n "$ts" ] && (( EPOCHSECONDS - ts < PR_TTL )); then return; fi

  command -v gh >/dev/null 2>&1 || return
  if [ -f "$lock" ]; then read -r lts < "$lock"; fi
  if [ -n "$lts" ] && (( EPOCHSECONDS - lts < 120 )); then return; fi

  [ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR"
  printf '%s' "$EPOCHSECONDS" > "$lock"
  (
    out=$(cd "$dir" && gh pr view --json statusCheckRollup,reviewDecision --jq "$GH_FILTER" 2>/dev/null)
    printf '%s\n%s\n' "$EPOCHSECONDS" "$out" > "$file"
    rm -f "$lock"
  ) </dev/null >/dev/null 2>&1 &
}

# Location is a heuristic: the JSON has no local/remote field.
location="local"
[ -n "${SSH_CONNECTION:-}" ] && location="ssh"
[ -n "${WSL_DISTRO_NAME:-}" ] && location="wsl"
[ -n "${CLAUDE_CODE_REMOTE:-}" ] && location="remote"

folder=${cur_dir##*/}
project=${proj_dir:-$cur_dir}; project=${project##*/}

# ---------- Line 1 ----------
line1="${CYAN}⚡ ${model}${RESET}"
[ -n "$effort" ] && line1+=" ${CYAN}· ${effort}${RESET}"
[ -n "$think" ] && line1+=" ${CYAN}· ${think}${RESET}"
[ -n "$fast" ] && line1+=" ${YELLOW}fast${RESET}"
[ -n "$style" ] && [ "$style" != "default" ] && line1+=" ${DIM}[${style}]${RESET}"

if [ -n "$cur_dir" ]; then
  line1+="${SEP}${GREEN}📁 ${folder}${RESET}"
  [ "$project" != "$folder" ] && line1+=" ${DIM}(proj: ${project})${RESET}"
  [ -n "$repo" ] && line1+=" ${DIM}${repo}${RESET}"
  [ -n "$worktree" ] && line1+=" ${DIM}wt:${worktree}${RESET}"
  git_info "$cur_dir"
  [ -n "$GIT_STR" ] && line1+="${SEP}${MAGENTA}${GIT_STR}${RESET}"
fi

if [ -n "$sess_name" ]; then
  line1+="${SEP}${WHITE}“${sess_name}”${RESET}"
elif [ -n "$sess_id" ]; then
  line1+="${SEP}${GRAY}session ${sess_id}${RESET}"
fi
line1+="${SEP}${GRAY}@ ${location}${RESET}"

# ---------- Line 2 ----------
line2=""
add() { [ -n "$line2" ] && line2+="$SEP"; line2+="$1"; }

if [ -n "$ctx_pct" ]; then
  bar "$ctx_pct"; used_color "$ctx_pct"
  ctx_text="ctx ${BAR} ${ctx_pct}%"
  if [ -n "$ctx_tokens" ] && [ -n "$ctx_max" ]; then
    fmt_tokens "$ctx_tokens"; ctx_text+=" ${TOK}"
    fmt_tokens "$ctx_max"; ctx_text+="/${TOK}"
  fi
  add "${COLOR}${ctx_text}${RESET}"
  [ "$over200k" = "true" ] && add "${RED}${BOLD}⚠ >200k${RESET}"
else
  add "${GRAY}ctx --${RESET}"
fi

if [ -n "$five_left" ]; then
  left_color "$five_left"
  txt="5h ${five_left}% left"
  [ -n "$five_reset" ] && { fmt_span $(( five_reset - EPOCHSECONDS )); txt+=" · resets ${SPAN}"; }
  add "${COLOR}${txt}${RESET}"
fi

if [ -n "$week_left" ]; then
  left_color "$week_left"
  txt="7d ${week_left}% left"
  [ -n "$week_reset" ] && { fmt_span $(( week_reset - EPOCHSECONDS )); txt+=" · resets ${SPAN}"; }
  add "${COLOR}${txt}${RESET}"
fi

[ -n "$spend" ] && add "${YELLOW}budget ${spend}${RESET}"

# Prompt cache: a warm cache makes the next turn cheap. Once it expires,
# the next turn has to re-process the whole context at full price.
cache_left=$(( ${cache_expires:-0} - EPOCHSECONDS ))
if [ "$cache_state" = "warm" ] && [ -n "$cache_expires" ] && [ "$cache_left" -le 0 ]; then
  cache_state="cold"
fi
case $cache_state in
  warm)
    fmt_span "$cache_left"
    txt="cache ${SPAN} left"
    [ -n "$cache_hit" ] && txt+=" · hit ${cache_hit}%"
    if [ "$cache_left" -lt 120 ]; then COLOR=$YELLOW; else COLOR=$GREEN; fi
    add "${COLOR}${txt}${RESET}" ;;
  cold)
    txt="cache cold"
    if [ -n "$cache_rebuild" ]; then fmt_tokens "$cache_rebuild"; txt+=" · next turn rebuilds ~${TOK}"; fi
    add "${RED}${txt}${RESET}" ;;
esac

if [ -n "$cost" ]; then
  cost_txt=$(printf '$%.2f' "$cost")
  if [ -n "$lines_add" ] || [ -n "$lines_del" ]; then
    cost_txt+=" ${GREEN}+${lines_add:-0}${RESET}${RED}/-${lines_del:-0}${RESET}"
  fi
  add "${YELLOW}${cost_txt}${RESET}"
fi
if [ -n "$dur_min" ]; then
  t="${dur_min}m"; [ -n "$api_min" ] && t+=" (api ${api_min}m)"
  add "${GRAY}⏱ ${t}${RESET}"
fi
[ -n "$out_tokens" ] && { fmt_tokens "$out_tokens"; add "${GRAY}out ${TOK}${RESET}"; }

if [ -n "$pr_num" ]; then
  if [ -n "$cur_dir" ]; then pr_info "$cur_dir"; fi
  add "${MAGENTA}PR #${pr_num}${PR_STR:+ · $PR_STR}${RESET}"
fi
[ -n "$vim_mode" ] && add "${BOLD}${vim_mode}${RESET}"
[ -n "$agent" ] && add "${CYAN}agent: ${agent}${RESET}"
[ -n "$version" ] && add "${GRAY}v${version}${RESET}"

printf '%b\n' "$line1"
[ -n "$line2" ] && printf '%b\n' "$line2"
exit 0
