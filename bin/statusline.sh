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

# Usage segments: ctx / 5h / 7d — rendered only when Claude Code provides the
# underlying fields. Claude Code pre-rounds used_percentage to an integer, so
# anything under 0.5% arrives as literal 0; render that as "<1%" rather than
# "0%" so a freshly-reset 5-hour window doesn't look like the data is broken.
ctx_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
five_pct=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
week_pct=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)

fmt_pct() {
  local n
  n=$(printf '%.0f' "$1" 2>/dev/null) || return 1
  if [ "$n" = "0" ]; then
    printf '<1%%'
  else
    printf '%s%%' "$n"
  fi
}

usage_suffix=""
if [ -n "$ctx_pct" ]; then
  usage_suffix="${usage_suffix}${dim}ctx:${reset}$(fmt_pct "$ctx_pct")"
fi
if [ -n "$five_pct" ]; then
  [ -n "$usage_suffix" ] && usage_suffix="${usage_suffix} ${dim}·${reset} "
  usage_suffix="${usage_suffix}${dim}5h:${reset}$(fmt_pct "$five_pct")"
fi
if [ -n "$week_pct" ]; then
  [ -n "$usage_suffix" ] && usage_suffix="${usage_suffix} ${dim}·${reset} "
  usage_suffix="${usage_suffix}${dim}7d:${reset}$(fmt_pct "$week_pct")"
fi

if [ -n "$usage_suffix" ]; then
  usage_seg=" ${dim}·${reset} ${usage_suffix}"
else
  usage_seg=""
fi

printf '●  %s%s%s%s %s·%s %s%s · %s%s%s%s' \
  "$fg" "$bold" "$title" "$reset" \
  "$dim" "$reset" \
  "$dim" "$model" "$short_cwd" "$branch_seg" "$reset" \
  "$usage_seg"
