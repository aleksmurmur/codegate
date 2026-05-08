#!/bin/bash
# notify.sh
# Cross-platform desktop notification + terminal bell for codegate phase
# boundaries (typically: quality gate complete, PR created).
#
# Usage:
#   bash .claude/scripts/notify.sh "title" "body"
#
# Tries osascript (macOS), notify-send (Linux desktop), powershell.exe
# (Windows / WSL with powershell on PATH), in that order. Silent when none
# are available. Always emits one stderr line so the message is visible in
# CI / headless environments and the IDE terminal scrollback.

TITLE="${1:-Codegate}"
BODY="${2:-}"

# Terminal bell. Most IDE terminals (VS Code, JetBrains, Windows Terminal,
# Tabby, iTerm2) flash the tab/window on BEL — this is the "attention even
# when console is inside an IDE" path.
printf '\a' >&2

notified=0

if [ "$notified" = 0 ] && command -v osascript >/dev/null 2>&1; then
  esc_title="${TITLE//\\/\\\\}"; esc_title="${esc_title//\"/\\\"}"
  esc_body="${BODY//\\/\\\\}";   esc_body="${esc_body//\"/\\\"}"
  if osascript -e "display notification \"$esc_body\" with title \"$esc_title\"" >/dev/null 2>&1; then
    notified=1
  fi
fi

if [ "$notified" = 0 ] && command -v notify-send >/dev/null 2>&1; then
  if notify-send "$TITLE" "$BODY" >/dev/null 2>&1; then
    notified=1
  fi
fi

if [ "$notified" = 0 ] && command -v powershell.exe >/dev/null 2>&1; then
  CG_TITLE="$TITLE" CG_BODY="$BODY" powershell.exe -NoProfile -Command "
    try {
      [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
      \$tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
      \$xml = \$tpl.GetXml()
      \$xml.GetElementsByTagName('text').Item(0).AppendChild(\$xml.CreateTextNode(\$env:CG_TITLE)) | Out-Null
      \$xml.GetElementsByTagName('text').Item(1).AppendChild(\$xml.CreateTextNode(\$env:CG_BODY)) | Out-Null
      \$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml)
      [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Codegate').Show(\$toast)
    } catch { }
  " >/dev/null 2>&1
fi

echo "[notify] $TITLE — $BODY" >&2

exit 0
