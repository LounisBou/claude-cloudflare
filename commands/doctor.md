---
description: Check python3, the accounts found and each account's token
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/install.sh:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/install.sh --check` and report its output to the user
verbatim. It checks that python3 3.9 or later runs, that the config file is
valid, that at least one account is found, and runs `auth-check` for each
account. It changes nothing and never prints a token.

Read the exit code and tell the user which class of problem it names:

| Code | Meaning | Remedy |
|---|---|---|
| `0` | everything satisfied | — |
| `11` | python3 3.9 or later is missing | install it, then `/cloudflare:doctor` |
| `12` | no Cloudflare account found | set `<NAME>_CLOUDFLARE_API_TOKEN` in the environment or in `~/.env`, then `/cloudflare:doctor` |
| `13` | a token failed its check | replace the token of the account named, then `/cloudflare:doctor` |
| `14` | the config file is not valid | fix the file named, then `/cloudflare:doctor` |

$ARGUMENTS
