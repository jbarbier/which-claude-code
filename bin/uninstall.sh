#!/usr/bin/env bash
# which-claude-code: uninstall.
# Removes the plugin's statusLine block from ~/.claude/settings.json. If
# /which-claude-code:setup backed up a previous statusLine, it's restored.
# Only acts if the currently-configured statusLine points at this plugin —
# never touches a statusLine that isn't ours.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE_PATH="$BIN_DIR/statusline.sh"

SETTINGS="$HOME/.claude/settings.json"
STATE_DIR="${WHICH_CLAUDE_CODE_STATE_DIR:-$HOME/.claude/which-claude-code}"
BACKUP="$STATE_DIR/settings-backup.json"

if [ ! -f "$SETTINGS" ]; then
  echo "nothing to do: $SETTINGS does not exist."
  exit 0
fi

if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
  echo "error: $SETTINGS is not valid JSON. Fix it and try again." >&2
  exit 1
fi

current=$(cat "$SETTINGS")
current_cmd=$(printf '%s' "$current" | jq -r '.statusLine.command // ""')

if [ "$current_cmd" != "$STATUSLINE_PATH" ]; then
  echo "which-claude-code: statusLine is not currently installed. nothing to do."
  exit 0
fi

if [ -f "$BACKUP" ]; then
  restored=$(cat "$BACKUP")
  new=$(printf '%s' "$current" | jq --argjson r "$restored" '.statusLine = $r')
  rm -f "$BACKUP"
  printf 'restored previous statusLine from backup.\n'
else
  new=$(printf '%s' "$current" | jq 'del(.statusLine)')
  printf 'removed statusLine.\n'
fi

tmp="$SETTINGS.tmp.$$"
printf '%s\n' "$new" > "$tmp"
mv "$tmp" "$SETTINGS"

printf 'which-claude-code: uninstalled from %s\n' "$SETTINGS"
