#!/usr/bin/env bash
# which-claude-code: setup.
# Adds a statusLine block to ~/.claude/settings.json pointing at this
# plugin's statusline.sh (absolute path). If the user already has a
# different statusLine configured, it's backed up to
#   $WHICH_CLAUDE_CODE_STATE_DIR/settings-backup.json
# so /which-claude-code:uninstall can restore it cleanly.
#
# This script is idempotent — running it twice is a no-op.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE_PATH="$BIN_DIR/statusline.sh"

if [ ! -x "$STATUSLINE_PATH" ]; then
  echo "error: statusline.sh not found or not executable at $STATUSLINE_PATH" >&2
  exit 1
fi

SETTINGS="$HOME/.claude/settings.json"
STATE_DIR="${WHICH_CLAUDE_CODE_STATE_DIR:-$HOME/.claude/which-claude-code}"
BACKUP="$STATE_DIR/settings-backup.json"

mkdir -p "$STATE_DIR" "$(dirname "$SETTINGS")"

if [ -f "$SETTINGS" ]; then
  if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
    echo "error: $SETTINGS is not valid JSON. Fix it and try again." >&2
    exit 1
  fi
  current=$(cat "$SETTINGS")
else
  current="{}"
fi

existing=$(printf '%s' "$current" | jq -c '.statusLine // null')
existing_cmd=$(printf '%s' "$current" | jq -r '.statusLine.command // ""')

if [ "$existing_cmd" = "$STATUSLINE_PATH" ]; then
  echo "which-claude-code: already installed. nothing to do."
  exit 0
fi

if [ "$existing" != "null" ]; then
  printf '%s\n' "$existing" > "$BACKUP"
  printf 'backed up existing statusLine to %s\n' "$BACKUP"
fi

new=$(printf '%s' "$current" | jq --arg cmd "$STATUSLINE_PATH" '
  .statusLine = { type: "command", command: $cmd }
')

tmp="$SETTINGS.tmp.$$"
printf '%s\n' "$new" > "$tmp"
mv "$tmp" "$SETTINGS"

printf 'which-claude-code: statusLine installed → %s\n' "$STATUSLINE_PATH"
printf 'start a new Claude Code session (or /reload) to see it.\n'
