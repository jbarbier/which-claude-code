# 0.2.0 — recursive self-invocation fix (security / reliability)

**If you're on any 0.1.x, please update immediately.**

## The bug

The `UserPromptSubmit` hook shelled out to `claude -p --model haiku` to
generate a session title. That child `claude -p` inherited your enabled
plugins, so its own `UserPromptSubmit` fired — spawning another `claude -p`,
and so on. Detached and `disown`ed, the chain kept running after you closed
Claude Code.

In the wild this produced:

- thousands of orphan `claude -p --model haiku` processes persisting after
  the UI was quit
- `~/.claude/projects/` growing from a few hundred MB to **12 GB**, filled
  with thousands of JSONL shards containing the title-generation prompt
  duplicated thousands of times
- Claude token usage burned across every project, because the plugin is global
- killing the processes did nothing — they instantly respawned

## Am I affected? 30-second check

```
pgrep -af 'update-session-title.sh' | grep -v grep
du -sh ~/.claude/projects
find ~/.claude/projects -type f | wc -l
```

- If the first line prints anything, you have a live leak — jump to **Step 0**.
- If `~/.claude/projects/` is multiple GB, or the file count is in the tens
  of thousands, you were affected.

## Upgrade

**Step 0** — *only if there are runaway processes right now*, stop the bleed:

```
pkill -f 'which-claude-code'
pkill -f 'claude -p --model haiku'
mv ~/.claude/plugins/cache/jbarbier/which-claude-code \
   ~/.claude/plugins/cache/jbarbier/which-claude-code.disabled 2>/dev/null
pgrep -af 'which-claude-code|claude -p --model haiku'   # should be empty
rm -rf ~/.claude/plugins/cache/jbarbier/which-claude-code.disabled
```

**Step 1** — inside Claude Code:

```
/plugin marketplace update jbarbier
/plugin install which-claude-code@jbarbier
/reload-plugins
```

Then fully quit and relaunch Claude Code.

**Step 2** — re-run setup (idempotent):

```
/which-claude-code:setup
```

Quit and relaunch Claude Code once more so the statusline picks up.

**Step 3** — verify you're on 0.2.0:

```
jq '.plugins["which-claude-code@jbarbier"][0].version' \
   ~/.claude/plugins/installed_plugins.json
```

Should print `"0.2.0"`.

**Step 4** — verify the fix is working. Submit a prompt or two, then:

```
pgrep -af 'update-session-title.sh' | grep -v grep
grep -l 'Generate a concise 3-6 word title' ~/.claude/projects/*/*.jsonl 2>/dev/null
```

Both should be empty. If the second one matches, file an issue.

## Cleanup (optional, recommended if you were affected)

```
du -xhd 1 ~/.claude/projects | sort -h | tail -10
```

Any project directory with thousands of tiny JSONL files is recursion
exhaust — safe to delete that project's shards. Claude Code conversation
history also lives in `~/.claude/projects/`, so if you're uncertain about
a directory, move it aside instead of deleting it.

## What changed

Six layered recursion defenses in `bin/update-session-title.sh`. Any single
one is sufficient to stop the loop; they are belt-and-suspenders so no
future regression can re-enable the bug.

| # | Guard | Purpose |
|---|---|---|
| G1 | `WHICH_CLAUDE_CODE_INTERNAL=1` on internal `claude -p`, checked at hook entry | Primary guard — children exit immediately |
| G2 | Stable marker in every outbound payload + literal-instruction detection | Content-based fallback if env stripping ever happens |
| G3 | `mkdir`-based atomic per-session lock, 60 s stale-lock cleanup | Prevents overlapping generations |
| G4 | 2 s per-session cooldown | Kills any rapid-fire storm |
| G5 | Plugin-owned bounded history file (5 lines × 200 chars, dedup) — raw transcript never read | Cuts the transcript → recursion → transcript feedback loop |
| G6 | 20 s timeout, no retries, 2 KB payload cap, stderr → log only | Safe failure |

Product behavior is preserved: the title still updates after every prompt
when it makes sense.

## Tests + docs

- `tests/run.sh` — 17 regression cases covering every guard, path-traversal,
  malformed JSON, payload size cap, history boundedness, and title evolution
- `README.md` — new "Defensive note for maintainers" section + manual
  verification checklist
- `CHANGELOG.md` — this change documented in repo

## Full diff

<https://github.com/jbarbier/which-claude-code/compare/v0.1.4...v0.2.0>
