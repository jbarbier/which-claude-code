#!/usr/bin/env bash
# which-claude-code: uninstall.
# Removes the plugin's statusLine block from ~/.claude/settings.json and
# deletes the dispatcher. If /which-claude-code:setup backed up a previous
# statusLine, it's restored. Only acts if the currently-configured statusLine
# points at this plugin — never touches a statusLine that isn't ours.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
STATE_DIR="${WHICH_CLAUDE_CODE_STATE_DIR:-$HOME/.claude/which-claude-code}"
BACKUP="$STATE_DIR/settings-backup.json"
DISPATCHER="$STATE_DIR/statusline.sh"

if [ ! -f "$SETTINGS" ]; then
  echo "nothing to do: $SETTINGS does not exist."
  rm -f "$DISPATCHER"
  exit 0
fi

if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
  echo "error: $SETTINGS is not valid JSON. Fix it and try again." >&2
  exit 1
fi

current=$(cat "$SETTINGS")
current_cmd=$(printf '%s' "$current" | jq -r '.statusLine.command // ""')

# Recognize both the new dispatcher path and legacy versioned paths
# (.../cache/jbarbier/which-claude-code/<ver>/bin/statusline.sh) from
# users upgrading from 0.1.3 or earlier.
if [ "$current_cmd" != "$DISPATCHER" ] && [[ "$current_cmd" != *"/jbarbier/which-claude-code/"*"/bin/statusline.sh" ]]; then
  echo "which-claude-code: statusLine is not currently installed. nothing to do."
  rm -f "$DISPATCHER"
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

rm -f "$DISPATCHER"

printf 'which-claude-code: uninstalled from %s\n' "$SETTINGS"
