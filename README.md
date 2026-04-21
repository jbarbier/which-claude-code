# which-claude-code

**Auto-generated session titles + per-session colors in the Claude Code statusline.**

If you run several Claude Code sessions in parallel terminals, you've probably
asked yourself: *which tab was the one fixing the auth bug? which was the one
writing tests?* This plugin answers that question automatically, without you
having to name anything.

After every prompt you submit, a tiny background Haiku call distills your
intent into a 3-6 word title. It shows up in the statusline, tinted with a
color uniquely hashed from the session ID. Same session = same color, forever.
Different sessions = visually distinct at a glance.

```
●  Fix Autopublish Double-Publish Bug · Opus 4.7 · opt/vanio-gtm (main)
●  Refactor Dashboard Credits Panel · Opus 4.7 · opt/vanio-gtm (dash-credits)
●  Ship WhatsApp Alert Routing · Opus 4.7 · opt/vanio-gtm (wa-routing)
```

## Install

Three steps, with a Claude Code restart after each of the first two.

**1. Add the marketplace and install the plugin:**

```
/plugin marketplace add jbarbier/which-claude-code
/plugin install which-claude-code@jbarbier
```

**2. Quit and relaunch Claude Code.** This lets the plugin's slash commands
register. Then wire up the statusline:

```
/which-claude-code:setup
```

**3. Quit and relaunch Claude Code once more.** The statusline config
is only read at startup, so a final restart is what makes it appear.

The statusline shows `·  ·  ·` until your first prompt; after that every
prompt refreshes the title.

### Why the `setup` step?

Claude Code plugins can contribute hooks, commands, agents, and skills —
but not a `statusLine`. The `setup` command writes a `statusLine` block
into `~/.claude/settings.json` pointing at a small dispatcher at
`~/.claude/which-claude-code/statusline.sh`. The dispatcher reads
`installed_plugins.json` on every render and execs whichever plugin
version is currently installed — so `/plugin update` doesn't leave
`settings.json` pointing at a deleted cache path. You only need to re-run
`setup` if this dispatcher itself gets an upgrade.

If you already have a `statusLine` configured, it's backed up and
restored automatically on uninstall.

## Updating

```
/plugin marketplace update jbarbier
/plugin update which-claude-code@jbarbier
```

Then restart Claude Code once for the new statusline to take effect.

**A note on the UI**: after `/plugin update`, Claude Code drops you onto
the **Discover** tab with a list of every available plugin. That's
CC's default — there's no "updated X → Y" confirmation. Your success
signal is the **Errors** tab showing no count (just "Errors", not
"Errors (1)"). The update itself worked; the UI just isn't telling you.

You don't need to re-run `/which-claude-code:setup` after an update —
the dispatcher installed on first setup handles version routing
automatically.

## How it works

Two moving parts, both pure shell:

1. **`UserPromptSubmit` hook** (`bin/update-session-title.sh`) — on every
   prompt you submit, forks a background process that appends a sanitized copy
   of your prompt to a tiny per-session history file (capped at 5 lines × 200
   chars), asks Haiku for a concise title, and atomically writes it to
   `~/.claude/which-claude-code/titles/<session_id>.txt`. The hook itself
   returns in ~10ms so your prompt is never delayed.

2. **Statusline** (`bin/statusline.sh`) — reads that file on every render,
   printing `●  <title> · <model> · <cwd> (<branch>)`. The title is colored from a
   20-color palette, indexed by `cksum(session_id)`, so the mapping is stable
   for the life of the session.

State lives under `~/.claude/which-claude-code/` (overridable via
`$WHICH_CLAUDE_CODE_STATE_DIR`). Nothing else is touched.

## Defensive note for maintainers — recursive Claude subprocess calls

**If you fork this plugin or write a similar one: read this.**

Any hook that shells out to `claude -p` (or any Claude Code subprocess) can
trigger **unbounded recursion**. The child `claude -p` inherits the user's
`~/.claude/settings.json` and enabled plugins, so its own `UserPromptSubmit`
event fires — re-invoking the same hook, which spawns another `claude -p`,
and so on. Detached and `disown`ed, the chain survives the user closing the
UI. In the wild this has been observed to produce:

- thousands of orphan `claude -p` processes after the UI was closed
- `~/.claude/projects/` growing from hundreds of MB to >12 GB in hours
- the title-generation prompt duplicated thousands of times inside a single
  saved session JSONL shard
- token quota exhaustion across unrelated projects, because the plugin is
  global

`which-claude-code` 0.2.0+ layers **six independent recursion defenses** in
`bin/update-session-title.sh`. None of them is optional. If you remove any
of them, you are re-opening the bug:

| # | Guard | What it does |
|---|-------|-------------|
| G1 | Env-var flag | Child `claude -p` gets `WHICH_CLAUDE_CODE_INTERNAL=1`; the hook exits immediately when it sees that var. |
| G2 | Content marker | Every outbound payload carries `[which-claude-code:title-generation-v1]`. If the inbound prompt contains it (or the literal title instruction), exit. |
| G3 | Atomic lock | `mkdir`-based per-session lock with 60s stale-lock cleanup. |
| G4 | Rate limit | Minimum 2s cooldown per session between generations. |
| G5 | Bounded history | Plugin-owned history file, max 5 lines × 200 chars. The raw Claude transcript is never read. |
| G6 | Safe failure | Fixed 20s timeout, no retries, hard 2 KB payload cap, stderr only to a log. |

The env-var guard (G1) is the primary defense; the rest are fallbacks in case
a future Claude Code release strips custom env vars from hook subprocesses, or
the plugin is updated while children are mid-flight.

## Manual verification checklist

Run this before cutting a new release (or after touching the hook):

```
bash tests/run.sh
```

All 17 cases must pass. Then run the live smoke test below in a throwaway
shell with `which-claude-code` installed:

1. **No process storm.** In a second terminal:
   ```
   watch -n 1 "pgrep -af 'claude -p --model haiku' | wc -l"
   ```
   Submit 5 prompts in sequence. The count should briefly spike to 1 per
   prompt and return to 0 within ~20s. It should **never** climb.

2. **No duplicate title instructions in saved shards.** After a few prompts:
   ```
   grep -l 'Generate a concise 3-6 word title' ~/.claude/projects/*/*.jsonl 2>/dev/null
   ```
   This should return nothing. If any file matches, the content guard is not
   working.

3. **Bounded history stays bounded.** Submit 20 prompts in a session, then:
   ```
   wc -l ~/.claude/which-claude-code/history/<session>.log
   ```
   Must be ≤ 5.

4. **No ~/.claude/projects explosion.** Before and after a ~5-minute typing
   session:
   ```
   du -xhd 1 ~/.claude/projects | sort -h | tail -5
   find ~/.claude/projects -type f | wc -l
   ```
   File count delta per project should be in the low tens, not thousands.

5. **Title still evolves.** Submit a prompt about auth, wait for the
   statusline to update, then submit a prompt about billing. The title
   should change within a few seconds.

6. **Kill-test.** While a Claude Code session is idle (no prompt in flight),
   check there are no orphaned processes:
   ```
   pgrep -af 'which-claude-code|claude -p --model haiku'
   ```
   Output should be empty.

## Cost

The hook calls `claude -p --model haiku`, which reuses whatever auth your
Claude Code is already configured with:

- **Pro / Max subscription** — counts against your normal quota. Each title is
  ~200-500 Haiku tokens, so the usage is negligible.
- **API key** — billed at Haiku rates, roughly $0.001 per prompt submission.
- **Team / Enterprise** — uses org auth.

No separate API key or config is needed.

## Requirements

- Claude Code 2.x with plugin support
- `claude` CLI on `$PATH`
- `jq`
- POSIX `cksum` + `awk` + `sed` (all standard)
- macOS or Linux. Windows users should run inside WSL.

## Troubleshooting

Everything lands in `~/.claude/which-claude-code/`:

- `titles/<session_id>.txt` — one file per session, the current title
- `hook.log` — every hook invocation, including Haiku stderr if it fails

If the statusline is stuck on `·  ·  ·`:

```
tail -f ~/.claude/which-claude-code/hook.log
```

and submit a prompt. You should see a `session_id -> <title>` line within a
couple seconds. If not, the most common cause is `claude -p` not being on
`$PATH` for the hook process — try

```
which claude
```

and make sure the shown path is in your login shell's `PATH`.

## Uninstall

```
/which-claude-code:uninstall
/plugin uninstall which-claude-code@jbarbier
rm -rf ~/.claude/which-claude-code
```

The first line removes the `statusLine` block from `~/.claude/settings.json`
(restoring any prior one). The second removes the hook and plugin. The third
clears cached titles and the hook log. Restart Claude Code after to clear
the statusline from any active sessions.

## License

MIT — see [LICENSE](LICENSE).
