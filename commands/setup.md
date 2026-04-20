---
description: Install the which-claude-code statusline into ~/.claude/settings.json.
---

Run the plugin's setup script to install the statusLine into the user's
`~/.claude/settings.json`. The script is idempotent and backs up any
existing statusLine config.

Use the Bash tool to run:

```
${CLAUDE_PLUGIN_ROOT}/bin/setup.sh
```

After it finishes, tell the user to start a new Claude Code session (or
run `/reload`) for the statusline to take effect. Do not do anything else.
