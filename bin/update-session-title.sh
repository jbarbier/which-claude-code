#!/usr/bin/env bash
# which-claude-code: UserPromptSubmit hook.
#
# Generates a concise 3-6 word title for the current Claude Code session via a
# backgrounded `claude -p --model haiku` call and writes it to
#   $STATE_DIR/titles/<session_id>.txt
# The statusline script reads that file to display the current topic.
#
# =============================================================================
# SECURITY: layered defenses against recursive self-invocation
# =============================================================================
# This hook shells out to `claude -p` in the background. That child Claude Code
# process inherits the user's plugin configuration — so its own
# UserPromptSubmit event fires this same script again, spawning another
# `claude -p`, and so on. In 0.1.4 and earlier, that recursion was unbounded:
# it survived the user closing the UI, burned tokens, and filled
# ~/.claude/projects/ with thousands of JSONL shards (CVE-class, self-DoS).
#
# We layer SIX independent guards so no single bypass re-enables the bug.
# Each guard MUST hold on its own; they are belt-and-suspenders, not a chain.
#
#   G1. Env-var recursion flag — child processes inherit
#       WHICH_CLAUDE_CODE_INTERNAL=1 and exit before doing anything.
#   G2. Content-based recursion detection — if the inbound prompt looks like
#       our own title-generation instruction, exit.
#   G3. Per-session atomic lock — at most one title generation in flight per
#       session. Stale-lock cleanup after 60s.
#   G4. Per-session rate limit — minimum 2s cooldown between generations.
#   G5. Plugin-owned bounded history — we keep our OWN tiny per-session
#       history file (max 5 lines, 200 chars/line). We never feed the raw
#       Claude transcript back into the title model.
#   G6. Safe failure — fixed timeout, no retries, hard payload cap, quiet
#       on error. A broken Haiku call never spirals.
#
# Maintainers: be extremely careful before removing any of these guards.
# See README.md "Defensive note on recursive Claude subprocess calls".
# =============================================================================
set -u

# ---- G1: environment recursion flag ----------------------------------------
# Set on every internal `claude -p` invocation below. Any descendant of an
# internal call (transitively) sees this and bails immediately.
if [ "${WHICH_CLAUDE_CODE_INTERNAL:-0}" = "1" ]; then
  exit 0
fi

# Stable marker embedded in every payload we send to `claude -p`. Used by G2
# to detect child invocations even if G1 is bypassed (e.g. a future Claude
# Code release strips custom env vars from hook invocations). DO NOT change
# this string casually — older installed versions rely on it to identify
# child invocations spawned by newer versions, and vice-versa.
TITLE_INSTRUCTION_MARKER='[which-claude-code:title-generation-v1]'
TITLE_INSTRUCTION='Generate a concise 3-6 word title in Title Case for this coding-session topic. Output ONLY the title — no quotes, no prefix, no explanation, no trailing punctuation.'

input=$(cat)

# jq is required; if it's missing we cannot parse the hook payload.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
prompt=$(printf '%s' "$input"     | jq -r '.prompt // ""'     2>/dev/null) || exit 0

[ -z "$session_id" ] && exit 0
[ -z "$prompt" ]     && exit 0

# ---- G2: content-based recursion detection ---------------------------------
# If the inbound prompt contains our marker OR the literal title instruction,
# this is almost certainly a child invocation. Exit before any side effects.
case "$prompt" in
  *"$TITLE_INSTRUCTION_MARKER"*) exit 0 ;;
  *"Generate a concise 3-6 word title in Title Case"*) exit 0 ;;
esac

# Reject session_ids that aren't safe as filenames — prevents path traversal
# and also guards against any weirdness in future CC releases.
case "$session_id" in
  ""|*[!A-Za-z0-9_-]*) exit 0 ;;
esac

STATE_DIR="${WHICH_CLAUDE_CODE_STATE_DIR:-$HOME/.claude/which-claude-code}"
TITLES_DIR="$STATE_DIR/titles"
HISTORY_DIR="$STATE_DIR/history"
LOCKS_DIR="$STATE_DIR/locks"
LOG="$STATE_DIR/hook.log"

mkdir -p "$TITLES_DIR" "$HISTORY_DIR" "$LOCKS_DIR" 2>/dev/null || exit 0

HISTORY_FILE="$HISTORY_DIR/$session_id.log"
LOCK_DIR_PATH="$LOCKS_DIR/$session_id.lock"
LAST_RUN_FILE="$LOCKS_DIR/$session_id.last"
TITLE_FILE="$TITLES_DIR/$session_id.txt"

# Bounds. Tuned for "enough context to notice a topic shift, not enough to be
# a liability." Do not raise these without thinking about the recursion
# scenario first.
MAX_HISTORY_LINES=5
MAX_LINE_CHARS=200
MAX_PAYLOAD_BYTES=2048
TIMEOUT_SECS=20
COOLDOWN_SECS=2
STALE_LOCK_SECS=60

# ---- helpers ----------------------------------------------------------------

# Sanitize a single prompt into one safe line:
#   * flatten whitespace
#   * drop anything resembling our own title-generation instruction (G2
#     applied to stored history, so we can never *store* a recursion-
#     triggering line and then feed it back on the next turn)
#   * hard-cap length
sanitize_line() {
  local s="$1"
  s=$(printf '%s' "$s" | tr '\n\r\t' '   ' | sed 's/  */ /g')
  case "$s" in
    *"$TITLE_INSTRUCTION_MARKER"*) s="" ;;
    *"Generate a concise 3-6 word title in Title Case"*) s="" ;;
  esac
  printf '%s' "$s" | head -c "$MAX_LINE_CHARS"
}

now_epoch() { date +%s 2>/dev/null || printf '0'; }

# ---- G5: append to plugin-owned, bounded-size history file -----------------
sanitized_prompt=$(sanitize_line "$prompt")
if [ -n "$sanitized_prompt" ]; then
  {
    printf '%s\n' "$sanitized_prompt"
    # Keep previous entries, but only up to (MAX_HISTORY_LINES - 1) of them,
    # deduplicated, oldest first. Rebuilding the file every turn guarantees
    # hard bounds even if an earlier write was interrupted.
    if [ -f "$HISTORY_FILE" ]; then
      tail -n "$MAX_HISTORY_LINES" "$HISTORY_FILE"
    fi
  } | awk 'length > 0 && !seen[$0]++' \
    | tail -n "$MAX_HISTORY_LINES" \
    > "$HISTORY_FILE.tmp.$$" 2>/dev/null \
    && mv "$HISTORY_FILE.tmp.$$" "$HISTORY_FILE"
  rm -f "$HISTORY_FILE.tmp.$$" 2>/dev/null || true
fi

# ---- G4: per-session rate limit --------------------------------------------
now=$(now_epoch)
if [ -f "$LAST_RUN_FILE" ]; then
  last=$(cat "$LAST_RUN_FILE" 2>/dev/null || printf '0')
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$last" -gt 0 ] && [ "$((now - last))" -lt "$COOLDOWN_SECS" ]; then
    exit 0
  fi
fi

# ---- G3: per-session atomic lock (mkdir) with stale-lock cleanup -----------
if [ -d "$LOCK_DIR_PATH" ]; then
  started=0
  [ -f "$LOCK_DIR_PATH/started" ] && started=$(cat "$LOCK_DIR_PATH/started" 2>/dev/null || printf '0')
  case "$started" in ''|*[!0-9]*) started=0 ;; esac
  if [ "$started" -gt 0 ] && [ "$((now - started))" -gt "$STALE_LOCK_SECS" ]; then
    rm -rf "$LOCK_DIR_PATH" 2>/dev/null || true
  else
    exit 0
  fi
fi
if ! mkdir "$LOCK_DIR_PATH" 2>/dev/null; then
  exit 0
fi
printf '%s' "$now" > "$LOCK_DIR_PATH/started" 2>/dev/null || true
printf '%s' "$now" > "$LAST_RUN_FILE" 2>/dev/null || true

# Test seam: synchronous mode skips backgrounding/disown so tests can assert
# completion deterministically. Never set in production installs.
SYNC="${WHICH_CLAUDE_CODE_SYNC:-0}"

run_generation() {
  # Bounded context from OUR history file only.
  context=""
  if [ -f "$HISTORY_FILE" ]; then
    context=$(tail -n "$MAX_HISTORY_LINES" "$HISTORY_FILE" 2>/dev/null)
  fi

  latest=$(sanitize_line "$prompt")

  payload=$(printf '%s\n\n%s\n\nLATEST PROMPT:\n%s\n\nRECENT USER PROMPTS:\n%s\n' \
    "$TITLE_INSTRUCTION" \
    "$TITLE_INSTRUCTION_MARKER" \
    "$latest" \
    "$context")
  # G6: hard cap the whole payload.
  payload=$(printf '%s' "$payload" | head -c "$MAX_PAYLOAD_BYTES")

  # ---- internal `claude -p` call ----
  # G1 set. G6 timeout. stderr redirected to log. Exactly one attempt.
  title=$(printf '%s' "$payload" \
    | WHICH_CLAUDE_CODE_INTERNAL=1 timeout "$TIMEOUT_SECS" claude -p --model haiku 2>>"$LOG" \
    | head -n 1 \
    | sed -E 's/^[[:space:]"'\''`*_#-]+//; s/[[:space:]"'\''`*_.]+$//' \
    | head -c 60)

  ts=$(date -Iseconds 2>/dev/null || date)
  if [ -n "$title" ]; then
    tmp="$TITLE_FILE.tmp.$$"
    printf '%s\n' "$title" > "$tmp" && mv "$tmp" "$TITLE_FILE"
    printf '[%s] %s -> %s\n' "$ts" "$session_id" "$title" >> "$LOG"
  else
    printf '[%s] %s -> (empty title)\n' "$ts" "$session_id" >> "$LOG"
  fi
}

cleanup_lock() {
  rm -rf "$LOCK_DIR_PATH" 2>/dev/null || true
}

if [ "$SYNC" = "1" ]; then
  trap cleanup_lock EXIT
  run_generation
  exit 0
fi

(
  trap cleanup_lock EXIT
  run_generation
) >/dev/null 2>&1 </dev/null &
disown "$!" 2>/dev/null || true

exit 0
