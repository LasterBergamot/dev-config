#!/usr/bin/env bash
# ==============================================================================
# Antigravity CLI Custom Status Line (using jq)
# ==============================================================================

# Read JSON payload from stdin
input=$(cat)

if [ -z "$input" ]; then
  exit 0
fi

# Save last payload for debugging / inspection
printf '%s' "$input" > "$(dirname "$0")/last_payload.json" 2>/dev/null

# Parse relevant metrics in a single jq pass for maximum performance
parsed=$(printf '%s' "$input" | jq -r '
  [
    (.model.display_name // .model.id // "Gemini"),
    (.cwd // ""),
    (if .context_window.used_percentage != null then (.context_window.used_percentage | round | tostring) else "" end),
    (if .context_window.total_input_tokens != null then (.context_window.total_input_tokens | tostring) else "" end),
    (
      .quota as $q |
      if ($q | type) == "object" then
        ($q."gemini-weekly".remaining_fraction //
         ($q | to_entries | map(select(.value.remaining_fraction != null)) | .[0].value.remaining_fraction) //
         $q.remaining_fraction)
      else
        null
      end |
      if . != null then ((. * 100) | round | tostring) else "" end
    )
  ] | @tsv
' 2>/dev/null)

if [ -z "$parsed" ]; then
  exit 0
fi

# Split tab-separated values
IFS=$'\t' read -r model cwd ctx_pct total_tokens quota_pct <<< "$parsed"

# ANSI Colors
RESET="\033[0m"
BOLD="\033[1m"
CYAN="\033[36m"
MAGENTA="\033[35m"
BLUE="\033[34m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
GRAY="\033[90m"

SEP="${GRAY} │ ${RESET}"
output=""

# 1. Model Name
output+="${CYAN}⚡ Model: ${model}${RESET}"

# 2. Context Window Usage (Color coded)
if [ -n "$ctx_pct" ]; then
  ctx_num=$((ctx_pct))
  if [ "$ctx_num" -ge 80 ]; then
    ctx_color="$RED"
  elif [ "$ctx_num" -ge 50 ]; then
    ctx_color="$YELLOW"
  else
    ctx_color="$GREEN"
  fi

  ctx_str="Context: ${ctx_pct}%"

  # Append total tokens if available
  if [ -n "$total_tokens" ] && [ "$total_tokens" -gt 0 ] 2>/dev/null; then
    if [ "$total_tokens" -ge 1000 ]; then
      tokens_k=$(( (total_tokens + 500) / 1000 ))
      ctx_str+=" (${tokens_k}k tokens)"
    else
      ctx_str+=" (${total_tokens} tokens)"
    fi
  fi

  output+="${SEP}${ctx_color}${ctx_str}${RESET}"
fi

# 3. Quota Remaining (if available)
if [ -n "$quota_pct" ]; then
  q_num=$((quota_pct))
  if [ "$q_num" -le 20 ]; then
    q_color="$RED"
  elif [ "$q_num" -le 50 ]; then
    q_color="$YELLOW"
  else
    q_color="$BLUE"
  fi
  output+="${SEP}${q_color}Quota: ${quota_pct}%${RESET}"
fi

# 4. Current Directory
if [ -n "$cwd" ]; then
  folder=$(basename "$cwd")
  output+="${SEP}${GREEN}Dir: ${folder}${RESET}"

  # 5. Git Branch (if cwd is in a git repository)
  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
      output+="${SEP}${MAGENTA}Git: ${branch}${RESET}"
    fi
  fi
fi

echo -e "$output"
