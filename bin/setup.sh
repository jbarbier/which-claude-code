#!/usr/bin/env bash
# which-claude-code: setup.
# Writes a *stable* dispatcher script to $STATE_DIR/statusline.sh and
# points ~/.claude/settings.json at it. The dispatcher resolves the
# currently-installed plugin version on every render, so /plugin update
# doesn't leave settings pointing at a stale cache path.
#
# If the user already has a different statusLine configured, it's
# backed up to $STATE_DIR/settings-backup.json so /which-claude-code:uninstall
# can restore it cleanly.
#
# Idempotent — running it twice is a no-op beyond refreshing the dispatcher.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
STATE_DIR="${WHICH_CLAUDE_CODE_STATE_DIR:-$HOME/.claude/which-claude-code}"
BACKUP="$STATE_DIR/settings-backup.json"
DISPATCHER="$STATE_DIR/statusline.sh"

mkdir -p "$STATE_DIR" "$(dirname "$SETTINGS")"

# Write (or refresh) the dispatcher at a stable path. This script reads
# installed_plugins.json on every invocation and execs the current version's
# statusline.sh — so plugin updates don't need a setup re-run.
cat > "$DISPATCHER" <<'DISPATCH_EOF'
#!/usr/bin/env bash
# which-claude-code dispatcher. Installed by /which-claude-code:setup.
# Routes statusLine rendering to the currently-installed plugin version.
set -u

installed="$HOME/.claude/plugins/installed_plugins.json"
cmd=""

if [ -f "$installed" ] && command -v jq >/dev/null 2>&1; then
  path=$(jq -r '.plugins["which-claude-code@jbarbier"][0].installPath // ""' "$installed" 2>/dev/null)
  [ -n "$path" ] && [ -x "$path/bin/statusline.sh" ] && cmd="$path/bin/statusline.sh"
fi

# Fallback: any installed version under the plugin cache.
if [ -z "$cmd" ]; then
  for s in "$HOME"/.claude/plugins/cache/jbarbier/which-claude-code/*/bin/statusline.sh; do
    [ -x "$s" ] && cmd="$s" && break
  done
fi

[ -n "$cmd" ] && exec "$cmd"
exit 0
DISPATCH_EOF
chmod +x "$DISPATCHER"

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

if [ "$existing_cmd" = "$DISPATCHER" ]; then
  echo "which-claude-code: already installed (dispatcher refreshed)."
  exit 0
fi

# Back up any existing statusLine that isn't a stale which-claude-code path
# (those we just silently replace since they're our own broken state).
if [ "$existing" != "null" ] && [[ "$existing_cmd" != *"which-claude-code"* ]]; then
  printf '%s\n' "$existing" > "$BACKUP"
  printf 'backed up existing statusLine to %s\n' "$BACKUP"
fi

new=$(printf '%s' "$current" | jq --arg cmd "$DISPATCHER" '
  .statusLine = { type: "command", command: $cmd }
')

tmp="$SETTINGS.tmp.$$"
printf '%s\n' "$new" > "$tmp"
mv "$tmp" "$SETTINGS"

printf 'which-claude-code: statusLine installed → %s\n' "$DISPATCHER"
printf 'start a new Claude Code session to see it.\n'
