#!/usr/bin/env bash
# PostToolUse, after Write, Edit or NotebookEdit: checks the syntax of the file that was just
# written. A failed check is sent back to Claude as the block reason so it can fix the file.
source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh"
hook_read_input || exit 0
[[ -n $FILE ]] || exit 0
hook_norm_path "$FILE"
[[ -f $NP ]] || exit 0

problem=
case ${NP,,} in
  *.sh)
    problem=$(bash -n "$NP" 2>&1) ;;
  *.py)
    command -v python >/dev/null 2>&1 &&
      problem=$(python -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$NP" 2>&1) ;;
  *.json)
    problem=$("$HOOK_JQ" empty "$NP" 2>&1) ;;
  *.ps1)
    problem=$(PS_FILE=$NP powershell.exe -NoProfile -Command '$t = $null; $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:PS_FILE, [ref]$t, [ref]$e); $e | ForEach-Object { $_.Message }' 2>&1) ;;
esac

if [[ -n $problem ]]; then
  hook_jsv "syntax check failed for $FILE:"$'\n'"${problem:0:1500}"
  printf '{"decision":"block","reason":%s}\n' "$JS"
fi
exit 0
