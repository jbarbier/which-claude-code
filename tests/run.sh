#!/usr/bin/env bash
# which-claude-code: regression test suite for update-session-title.sh
#
# These tests exercise the six layered recursion defenses plus the bounded
# history mechanism. They use a fake `claude` binary on PATH so the hook can
# be run end-to-end without spending tokens or hitting the network.
#
# Run:
#   bash tests/run.sh
#
# Exit code 0 = all tests passed.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
hook="$root/bin/update-session-title.sh"

pass=0
fail=0
failures=()

# ---- fake claude binary + isolated state dir ------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fake_bin="$work/bin"
mkdir -p "$fake_bin"
write_fake_claude() {
  # $1 = "ok" (prints canned title) or "fail" (exits 1 after logging).
  cat > "$fake_bin/claude" <<EOF
#!/usr/bin/env bash
# Fake \`claude\`. Reads stdin, logs it, and prints a canned title.
log="\${FAKE_CLAUDE_LOG:-/tmp/fake-claude.log}"
mode="$1"
{
  printf '%s %s\n' '@@@INVOCATION' "\$(date +%s%N 2>/dev/null || date +%s)"
  printf 'argv:'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'
  printf 'WHICH_CLAUDE_CODE_INTERNAL=%s\n' "\${WHICH_CLAUDE_CODE_INTERNAL:-unset}"
  printf '%s\n' '@@@STDIN_BEGIN'
  body=\$(cat)
  printf '%s' "\$body"
  printf '\n%s\n' '@@@STDIN_END'
  printf 'body_len=%d\n' "\${#body}"
} >> "\$log"
if [ "\$mode" = "fail" ]; then exit 1; fi
printf '%s\n' "\${FAKE_CLAUDE_OUTPUT:-Fake Test Title}"
EOF
  chmod +x "$fake_bin/claude"
}
write_fake_claude ok

export PATH="$fake_bin:$PATH"

# Each test gets a fresh state dir + fake-claude log.
reset_env() {
  state=$(mktemp -d -p "$work")
  fake_log="$state/fake-claude.log"
  export WHICH_CLAUDE_CODE_STATE_DIR="$state"
  export FAKE_CLAUDE_LOG="$fake_log"
  export WHICH_CLAUDE_CODE_SYNC=1
  unset WHICH_CLAUDE_CODE_INTERNAL
  unset FAKE_CLAUDE_OUTPUT
}

# Count invocations by counting our fake's marker lines.
fake_calls() {
  if [ -f "$fake_log" ]; then
    grep -c '^@@@INVOCATION ' "$fake_log" 2>/dev/null || printf '0'
  else
    printf '0'
  fi
}

ok() { pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
ko() { fail=$((fail+1)); failures+=("$1: $2"); printf 'FAIL %s — %s\n' "$1" "$2"; }

run_hook() {
  # usage: run_hook '<json>'
  printf '%s' "$1" | bash "$hook"
}

mkinput() {
  # usage: mkinput <session_id> <prompt>
  jq -nc --arg s "$1" --arg p "$2" '{session_id:$s, prompt:$p}'
}

# ============================================================================
# Test 1 — happy path: one prompt → one claude call → title file written
# ============================================================================
reset_env
run_hook "$(mkinput 'sess-1' 'fix the login bug')"
title_file="$state/titles/sess-1.txt"
if [ -f "$title_file" ] && [ "$(fake_calls)" = "1" ] && [ "$(cat "$title_file")" = "Fake Test Title" ]; then
  ok "happy path writes title and calls claude once"
else
  ko "happy path writes title and calls claude once" "calls=$(fake_calls) file=$([ -f "$title_file" ] && cat "$title_file" || echo MISSING)"
fi

# ============================================================================
# Test 2 — G1: WHICH_CLAUDE_CODE_INTERNAL=1 → no claude call, no title file
# ============================================================================
reset_env
WHICH_CLAUDE_CODE_INTERNAL=1 run_hook "$(mkinput 'sess-2' 'anything')"
if [ "$(fake_calls)" = "0" ] && [ ! -f "$state/titles/sess-2.txt" ]; then
  ok "G1: env-var recursion guard blocks immediately"
else
  ko "G1: env-var recursion guard blocks immediately" "calls=$(fake_calls)"
fi

# ============================================================================
# Test 3 — G2a: prompt containing the marker → no claude call
# ============================================================================
reset_env
run_hook "$(mkinput 'sess-3' 'foo [which-claude-code:title-generation-v1] bar')"
if [ "$(fake_calls)" = "0" ]; then
  ok "G2a: marker in prompt blocks immediately"
else
  ko "G2a: marker in prompt blocks immediately" "calls=$(fake_calls)"
fi

# ============================================================================
# Test 4 — G2b: prompt containing the literal title instruction → no call
# ============================================================================
reset_env
run_hook "$(mkinput 'sess-4' 'Generate a concise 3-6 word title in Title Case for this coding-session topic. Output ONLY the title.')"
if [ "$(fake_calls)" = "0" ]; then
  ok "G2b: literal instruction in prompt blocks"
else
  ko "G2b: literal instruction in prompt blocks" "calls=$(fake_calls)"
fi

# ============================================================================
# Test 5 — G4: rate limit suppresses a rapid second call for the same session
# ============================================================================
reset_env
run_hook "$(mkinput 'sess-5' 'first')"
run_hook "$(mkinput 'sess-5' 'second')"
# First call succeeds (count=1). Second is within cooldown → suppressed.
if [ "$(fake_calls)" = "1" ]; then
  ok "G4: rate limit suppresses rapid second call"
else
  ko "G4: rate limit suppresses rapid second call" "calls=$(fake_calls)"
fi

# ============================================================================
# Test 6 — G4: different session within cooldown is NOT suppressed
# ============================================================================
reset_env
run_hook "$(mkinput 'sess-6a' 'first')"
run_hook "$(mkinput 'sess-6b' 'also first')"
if [ "$(fake_calls)" = "2" ]; then
  ok "G4: cooldown is per-session, not global"
else
  ko "G4: cooldown is per-session, not global" "calls=$(fake_calls)"
fi

# ============================================================================
# Test 7 — G5: history file bounded to MAX_HISTORY_LINES (5) after many prompts
# ============================================================================
reset_env
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  # Force each into a unique session to avoid rate-limit skip; but history is
  # per-session, so use a single session and blow past the rate limit by
  # setting WHICH_CLAUDE_CODE_SYNC=1 and tweaking last-run.
  # Simpler: call with same session and clear the last-run file between.
  run_hook "$(mkinput 'sess-7' "prompt number $i")"
  rm -f "$state/locks/sess-7.last" 2>/dev/null || true
done
lines=$(wc -l < "$state/history/sess-7.log" 2>/dev/null || echo 0)
lines=$(printf '%s' "$lines" | tr -d ' ')
if [ "$lines" = "5" ]; then
  ok "G5: history file capped at 5 lines after 12 prompts"
else
  ko "G5: history file capped at 5 lines after 12 prompts" "lines=$lines"
fi

# ============================================================================
# Test 8 — G5: each history line is length-capped (<=200 chars)
# ============================================================================
reset_env
big=$(printf 'A%.0s' $(seq 1 5000))
run_hook "$(mkinput 'sess-8' "$big")"
maxlen=$(awk '{ if (length($0) > m) m=length($0) } END { print m+0 }' "$state/history/sess-8.log")
if [ "$maxlen" -le 200 ]; then
  ok "G5: history lines truncated to <=200 chars (got $maxlen)"
else
  ko "G5: history lines truncated to <=200 chars" "maxlen=$maxlen"
fi

# ============================================================================
# Test 9 — G5: history never stores title-instruction-looking prompts
# ============================================================================
reset_env
run_hook "$(mkinput 'sess-9a' 'real prompt')"
# now simulate a tainted prompt landing — G2 will exit before storing, but
# assert it was in fact not stored.
run_hook "$(mkinput 'sess-9a' 'prefix Generate a concise 3-6 word title in Title Case suffix')"
if ! grep -q 'Generate a concise 3-6 word title' "$state/history/sess-9a.log" 2>/dev/null; then
  ok "G5: tainted prompt never enters history"
else
  ko "G5: tainted prompt never enters history" "history contains marker"
fi

# ============================================================================
# Test 10 — G6: fake claude crashes → hook still exits 0 and no retry
# ============================================================================
reset_env
write_fake_claude fail
run_hook "$(mkinput 'sess-10' 'boom')"
rc=$?
calls=$(fake_calls)
if [ "$rc" = "0" ] && [ "$calls" = "1" ]; then
  ok "G6: hook exits 0 on claude failure with no retry"
else
  ko "G6: hook exits 0 on claude failure with no retry" "rc=$rc calls=$calls"
fi
write_fake_claude ok

# ============================================================================
# Test 11 — internal invocation sets WHICH_CLAUDE_CODE_INTERNAL=1 when calling claude
# ============================================================================
reset_env
run_hook "$(mkinput 'sess-11' 'something new')"
if grep -q 'WHICH_CLAUDE_CODE_INTERNAL=1' "$fake_log" 2>/dev/null; then
  ok "internal claude call carries WHICH_CLAUDE_CODE_INTERNAL=1"
else
  ko "internal claude call carries WHICH_CLAUDE_CODE_INTERNAL=1" "env not set on child"
fi

# ============================================================================
# Test 12 — the payload sent to claude contains the marker (so descendants
# can detect themselves via G2 even if G1 is stripped)
# ============================================================================
reset_env
run_hook "$(mkinput 'sess-12' 'build a new thing')"
if grep -q 'which-claude-code:title-generation-v1' "$fake_log" 2>/dev/null; then
  ok "outbound payload contains title-generation marker"
else
  ko "outbound payload contains title-generation marker" "marker missing from payload"
fi

# ============================================================================
# Test 13 — payload size is hard-capped (<= 2048 bytes of *our* payload)
# ============================================================================
reset_env
# Pre-seed history with 5 maxed-out lines.
mkdir -p "$state/history"
for i in 1 2 3 4 5; do
  printf '%s\n' "$(printf 'X%.0s' $(seq 1 200))-$i" >> "$state/history/sess-13.log"
done
huge=$(printf 'Z%.0s' $(seq 1 10000))
run_hook "$(mkinput 'sess-13' "$huge")"
# Authoritative size reported by the fake from its own stdin buffer.
body_len=$(awk -F= '/^body_len=/ { print $2; exit }' "$fake_log" | tr -d '[:space:]')
# Payload cap is 2048 bytes. Allow 0 slack — it's a hard cap.
if [ -n "$body_len" ] && [ "$body_len" -le 2048 ] && [ "$body_len" -gt 0 ]; then
  ok "G6: outbound payload capped to <=2048 bytes (got $body_len)"
else
  ko "G6: outbound payload capped to <=2048 bytes" "body_len='$body_len'"
fi

# ============================================================================
# Test 14 — session_id validation rejects unsafe filenames
# ============================================================================
reset_env
run_hook "$(mkinput '../../etc/passwd' 'evil')"
if [ "$(fake_calls)" = "0" ] && [ ! -f "$state/titles/../../etc/passwd.txt" ]; then
  ok "rejects unsafe session_id (path traversal attempt)"
else
  ko "rejects unsafe session_id" "calls=$(fake_calls)"
fi

# ============================================================================
# Test 15 — end-to-end "no process storm" smoke: 10 rapid calls same session
# produce at most 1 claude invocation (due to rate limit) and no runaway
# ============================================================================
reset_env
for i in 1 2 3 4 5 6 7 8 9 10; do
  run_hook "$(mkinput 'sess-15' "rapid $i")"
done
calls=$(fake_calls)
if [ "$calls" -le 1 ]; then
  ok "no process storm: 10 rapid calls → $calls claude invocation(s)"
else
  ko "no process storm" "calls=$calls (expected <=1)"
fi

# ============================================================================
# Test 16 — title evolves across prompts when rate limit is respected
# ============================================================================
reset_env
export FAKE_CLAUDE_OUTPUT="First Topic"
run_hook "$(mkinput 'sess-16' 'work on auth')"
rm -f "$state/locks/sess-16.last"
export FAKE_CLAUDE_OUTPUT="Second Topic"
run_hook "$(mkinput 'sess-16' 'switch to billing'
)"
title=$(cat "$state/titles/sess-16.txt" 2>/dev/null || echo MISSING)
if [ "$title" = "Second Topic" ]; then
  ok "title evolves across prompts (got '$title')"
else
  ko "title evolves across prompts" "title='$title'"
fi
unset FAKE_CLAUDE_OUTPUT

# ============================================================================
# Test 17 — malformed JSON input: hook exits cleanly, no invocation
# ============================================================================
reset_env
printf 'not-json' | bash "$hook"
rc=$?
if [ "$rc" = "0" ] && [ "$(fake_calls)" = "0" ]; then
  ok "malformed JSON input: clean exit, no claude call"
else
  ko "malformed JSON input" "rc=$rc calls=$(fake_calls)"
fi

# ============================================================================
# summary
# ============================================================================
printf '\n---\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf '\nFailures:\n'
  for f in "${failures[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
