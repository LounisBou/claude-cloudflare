# claude-cloudflare

A Claude Code mod that talks to the Cloudflare API through one native tool, over
a Python 3.9+ standard-library engine. No third-party packages, no npm
dependency in the mod.

The tool needs Claude Code with mods enabled. Where mods do not load
(`claude -p`, an older Claude Code), the `cf-curl` skill runs the same engine
from Bash.

## Install

Install the `cloudflare` plugin from its marketplace, then run
`/cloudflare:install`. The plugin needs python3 3.9 or later and one API token
per Cloudflare account; `/cloudflare:doctor` checks python3, the config file,
the accounts found and each account's token, and never prints a token.

## Accounts by name

An account `<name>` exists when `<NAME>_CLOUDFLARE_API_TOKEN` is set in the
environment or in an env file (`~/.env` by default); the environment wins.
`<NAME>_CLOUDFLARE_ACCOUNT_ID` is optional. Every call names its account, or
falls back to the configured default, else to the only account found.

The machine-local config lives outside the repository, in
`$CLAUDE_CLOUDFLARE_CONFIG` or `~/.config/claude-cloudflare/config.json`. Every
key is optional:

```json
{
  "default_account": "alpha",
  "env_files": ["~/.env"],
  "backup_dir": "~/.local/share/claude-cloudflare/backups"
}
```

Tokens are read by the engine when a request needs them and go in its
Authorization header only: never in an argument, an output, a log or a file.
A token the API echoes back is masked.

## The tool

`mcp__cloudflare__cf` takes `{ command, args?, account? }`:

- reads: `auth-check`, `accounts`, `zones`, `dns-list`, `dns-get`,
  `dns-export`, `backups`;
- writes: `dns-create`, `dns-update` (type change included), `dns-delete`,
  `restore`.

Output is compact text, one line per object; `"json": true` on a read gives
the full objects. `engine/REFERENCE.md` lists every command, its arguments and
the exit codes.

The mod sends a read to `engine/cf.py --stdin-json` and a write to
`engine/cf-write.py --stdin-json`, the request as JSON on stdin; no argument
vector is built from the input. `cf.py` runs only reads and `cf-write.py`
only writes, each refusing the other's commands, so in the Bash fallback a
permission rule can tell a read from a write by the script it names.

Calls follow the session's permission rules. A `deny` rule refuses. A read runs
unless a rule asks. A write is asked unless a rule or the mode allows it: the
dialog offers « Allow for this session », which covers that one command on
that one account until the session ends. It is never offered for
`dns-delete`, `restore`, `purge-all`, `under-attack`, `worker-delete` or
`unpublish`, nor where an explicit rule asks. A command the mod does not list
as a read is a write. Where nobody can answer (`claude -p`), a write is
refused.

## Backups and restore

Before every zone write the engine saves the records of the names the write
touches to `backup_dir/<account>/<zone>/<UTC timestamp>-<kind>.json`, and the
write's output ends with `backup: <path>`. A backup that cannot be written
stops the write. `backups` lists them; `restore <path>` brings those names
back to the saved records, after saving the current ones.

## Tests

Offline: a fixture server on 127.0.0.1 stands in for the Cloudflare API
(`CF_API_BASE`), and no real account or token is used.

```
bash tests/run-tests.sh        # the engine, install.sh, and the mod (claude plugin test)
```

## Licence

MIT.
