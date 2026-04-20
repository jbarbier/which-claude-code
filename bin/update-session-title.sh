#!/usr/bin/env bash
# which-claude: UserPromptSubmit hook.
# Generates a concise 3-6 word title for the current Claude Code session
# via a backgrounded `claude -p --model haiku` call, and writes it to
#   $HOME/.claude/which-claude/titles/<session_id>.txt
# The statusline script reads that file to display the current topic.
#
# The hook returns in ~10ms regardless of Haiku latency — the LLM call
# is forked to the background so nothing blocks the user's prompt.
set -u

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // ""')
prompt=$(printf '%s' "$input" | jq -r '.prompt // ""')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""')

[ -z "$session_id" ] && exit 0
[ -z "$prompt" ]     && exit 0

STATE_DIR="${WHICH_CLAUDE_STATE_DIR:-$HOME/.claude/which-claude}"
TITLES_DIR="$STATE_DIR/titles"
LOG="$STATE_DIR/hook.log"
mkdir -p "$TITLES_DIR"

(
  context=""
  if [ -f "$transcript" ]; then
    context=$(jq -r '
      select(.type == "user" and (.message.content | type == "string"))
      | .message.content
    ' < "$transcript" 2>/dev/null | tail -n 6 | head -c 3000)
  fi

  payload="Generate a concise 3-6 word title in Title Case for this coding-session topic. Output ONLY the title — no quotes, no prefix, no explanation, no trailing punctuation.

LATEST PROMPT:
$prompt

RECENT CONTEXT (older user turns):
$context"

  title=$(printf '%s' "$payload" \
    | timeout 30 claude -p --model haiku 2>>"$LOG" \
    | head -n 1 \
    | sed -E 's/^[[:space:]"'\''`*_#-]+//; s/[[:space:]"'\''`*_.]+$//' \
    | head -c 60)

  if [ -n "$title" ]; then
    tmp="$TITLES_DIR/$session_id.txt.tmp"
    printf '%s\n' "$title" > "$tmp"
    mv "$tmp" "$TITLES_DIR/$session_id.txt"
    printf '[%s] %s -> %s\n' "$(date -Iseconds 2>/dev/null || date)" "$session_id" "$title" >> "$LOG"
  else
    printf '[%s] %s -> (empty title)\n' "$(date -Iseconds 2>/dev/null || date)" "$session_id" >> "$LOG"
  fi
) >/dev/null 2>&1 </dev/null &
disown "$!" 2>/dev/null || true

exit 0
