---
description: Check python3, the accounts found, each account's token and its permissions, and the local Caddy
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/install.sh:*), Read
---

Run `${CLAUDE_PLUGIN_ROOT}/install.sh --check` and report its output to the user
verbatim. It checks that python3 3.9 or later runs, that the config file is
valid, that at least one account is found, and runs `auth-check` for each
account. For each token it then says which families of commands it cannot
read (one read probe per family) and which it cannot write (from the token's
own policies, when the token may read them; else the writes are said to be
unchecked): a missing permission is reported, not a failure. When the config
has a `caddy` section, it checks that the caddy binary runs, that the service
is found and starts caddy with the envfile, that the envfile is private
(`0600`) and holds the variable the TLS snippet reads, and that this DNS-01
token is valid, with its DNS edit right when the token may read its own
policies. It changes nothing and never prints a token or an envfile value.

Read the exit code and tell the user which class of problem it names:

| Code | Meaning | Remedy |
|---|---|---|
| `0` | everything satisfied | — |
| `11` | python3 3.9 or later is missing | install it, then `/cloudflare:doctor` |
| `12` | no Cloudflare account found | set `<NAME>_CLOUDFLARE_API_TOKEN` in the environment or in `~/.env`, then `/cloudflare:doctor` |
| `13` | a token failed its check | replace the token of the account named, then `/cloudflare:doctor` |
| `14` | the config file is not valid | fix the file named, then `/cloudflare:doctor` |
| `15` | the local Caddy is not ready | fix the binary, service, envfile or DNS-01 token named, then `/cloudflare:doctor` |

$ARGUMENTS
