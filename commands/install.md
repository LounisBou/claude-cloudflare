---
description: Check the Cloudflare setup and say how to add an account when none is found
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/install.sh:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/install.sh` and report its output to the user verbatim.

The plugin installs nothing: it needs python3 3.9 or later and one API token per
Cloudflare account. An account `<name>` exists when `<NAME>_CLOUDFLARE_API_TOKEN`
is set in the environment or in `~/.env` (or in an env file the config lists);
`<NAME>_CLOUDFLARE_ACCOUNT_ID` is optional. When no account is found, the script
says where the token goes and exits 12. The config file is
`$CLAUDE_CLOUDFLARE_CONFIG`, else `~/.config/claude-cloudflare/config.json`; every
key is optional. The script never prints, writes or logs a token.

It then runs the same checks as `/cloudflare:doctor`, whose table names each exit
code.

$ARGUMENTS
