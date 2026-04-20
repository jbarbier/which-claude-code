---
description: Remove the which-claude-code statusline from ~/.claude/settings.json.
---

Run the plugin's uninstall script to remove the statusLine from the user's
`~/.claude/settings.json`. If the original setup backed up a previous
statusLine, it will be restored.

Use the Bash tool to run:

```
${CLAUDE_PLUGIN_ROOT}/bin/uninstall.sh
```

After it finishes, remind the user that `/plugin uninstall which-claude-code`
still needs to be run separately to remove the hook and marketplace entry.
Do not do anything else.
