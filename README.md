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

## How it works

Two moving parts, both pure shell:

1. **`UserPromptSubmit` hook** (`bin/update-session-title.sh`) — on every
   prompt you submit, forks a background process that reads the last few user
   turns from the transcript, asks Haiku for a concise title, and atomically
   writes it to `~/.claude/which-claude-code/titles/<session_id>.txt`. The hook
   itself returns in ~10ms so your prompt is never delayed.

2. **Statusline** (`bin/statusline.sh`) — reads that file on every render,
   printing `●  <title> · <model> · <cwd> (<branch>)`. The title is colored from a
   20-color palette, indexed by `cksum(session_id)`, so the mapping is stable
   for the life of the session.

State lives under `~/.claude/which-claude-code/` (overridable via
`$WHICH_CLAUDE_CODE_STATE_DIR`). Nothing else is touched.

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
