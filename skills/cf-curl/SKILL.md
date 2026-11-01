---
name: cf-curl
description: |
  Use when making Cloudflare API calls and the mcp__cloudflare__cf tool is not
  in the tool list (a session where mods do not load: claude -p, an older
  Claude Code). Runs the same Python standard-library engine from Bash:
  accounts, zones, DNS records, zone settings, certificates, protections (rules, rate limiting, managed rules, IP access rules), backups and restore.
  WHEN: a Cloudflare call is needed and mcp__cloudflare__cf is unavailable.
  WHEN NOT: mcp__cloudflare__cf is available (use it).
---

# cf-curl

When the `mcp__cloudflare__cf` tool is listed, use it instead: it takes the same
commands as JSON and asks before every write.

Otherwise, run the engine from Bash. Reads go through `cf.py`, writes through
`cf-write.py`; each refuses the other's commands (exit 2), so a permission rule
can allow `cf.py` and keep `cf-write.py` asked.

```bash
CF="${CLAUDE_PLUGIN_ROOT}/engine/cf.py"
CFW="${CLAUDE_PLUGIN_ROOT}/engine/cf-write.py"

python3 "$CF" accounts
python3 "$CF" --account alpha dns-list example.com --type A
python3 "$CFW" dns-update example.com www --content 203.0.113.7
```

Every command, its arguments, its output and the exit codes are listed in
`${CLAUDE_PLUGIN_ROOT}/engine/REFERENCE.md`. Tokens are read by the engine
from the environment or the env files: never pass one on the command line,
and never print one.

Every write saves the records it touches first and ends with `backup: <path>`;
`python3 "$CFW" restore <path>` replays it.
