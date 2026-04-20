#!/usr/bin/env bash
# which-claude-code: statusline.
# Reads the per-session title written by the UserPromptSubmit hook and
# prints it alongside a session-deterministic color, so parallel Claude
# Code sessions are easy to tell apart.
set -u

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // ""')
cwd=$(printf '%s'       "$input" | jq -r '.cwd // ""')
model=$(printf '%s'     "$input" | jq -r '.model.display_name // .model.id // "Claude"')

# Git branch (empty if not a repo or git unavailable).
branch=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
        || git -C "$cwd" rev-parse --short HEAD 2>/dev/null \
        || true)
fi

# cwd: collapse $HOME -> ~, keep only the last two path segments.
if [ -n "$cwd" ]; then
  cwd="${cwd/#$HOME/~}"
  short_cwd=$(printf '%s' "$cwd" | awk -F/ '{
    n=NF
    if (n<=2) { print $0 }
    else      { print $(n-1)"/"$n }
  }')
else
  short_cwd=""
fi

# Deterministic color per session — POSIX cksum (works on macOS + Linux).
palette=(39 45 51 82 118 147 159 171 183 203 208 214 220 135 213 48 75 105 165 198)
if [ -n "$session_id" ]; then
  hash_dec=$(printf '%s' "$session_id" | cksum | awk '{print $1}')
  idx=$(( hash_dec % ${#palette[@]} ))
  color=${palette[$idx]}
else
  color=250
fi

# Title from the hook-written file; placeholder until Haiku returns.
STATE_DIR="${WHICH_CLAUDE_CODE_STATE_DIR:-$HOME/.claude/which-claude-code}"
title_file="$STATE_DIR/titles/$session_id.txt"
if [ -f "$title_file" ]; then
  title=$(head -n 1 "$title_file")
else
  title="·  ·  ·"
fi

esc=$(printf '\033')
reset="${esc}[0m"
dim="${esc}[2m"
fg="${esc}[38;5;${color}m"
bold="${esc}[1m"

if [ -n "$branch" ]; then
  branch_seg=" (${branch})"
else
  branch_seg=""
fi

printf '●  %s%s%s%s %s·%s %s%s · %s%s%s' \
  "$fg" "$bold" "$title" "$reset" \
  "$dim" "$reset" \
  "$dim" "$model" "$short_cwd" "$branch_seg" "$reset"
