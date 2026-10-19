#!/usr/bin/env bash
# Notification and Stop hook: shows a Windows balloon notification when Claude is waiting for
# permission or has finished, so an "ask" in auto mode is not missed. Runs in the background.
source "${BASH_SOURCE[0]%"${BASH_SOURCE[0]##*/}"}lib.sh"
raw=$(cat)
event=$("$HOOK_JQ" -r '.hook_event_name // ""' <<<"$raw" 2>/dev/null) || exit 0
case $event in
  Notification) text=$("$HOOK_JQ" -r '.message // "Claude needs your attention."' <<<"$raw" 2>/dev/null) ;;
  Stop)         text="Claude has finished and is waiting for you." ;;
  *)            exit 0 ;;
esac

script='Add-Type -AssemblyName System.Windows.Forms,System.Drawing;
$n = New-Object System.Windows.Forms.NotifyIcon;
$n.Icon = [System.Drawing.SystemIcons]::Information;
$n.Visible = $true;
$n.ShowBalloonTip(6000, "Claude Code", $env:TOAST_TEXT, [System.Windows.Forms.ToolTipIcon]::Info);
Start-Sleep -Seconds 7;
$n.Dispose()'

encoded=$(printf '%s' "$script" | iconv -f utf-8 -t utf-16le | base64 -w0)
TOAST_TEXT=${text:0:300} powershell.exe -NoProfile -WindowStyle Hidden -EncodedCommand "$encoded" >/dev/null 2>&1 &
exit 0
