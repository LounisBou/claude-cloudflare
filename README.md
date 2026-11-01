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
the accounts found and each account's token, says which families of commands
each token cannot read or write, and, with a `caddy` section, that the caddy
binary runs, that its service starts it with the envfile and that the envfile
holds the variable the TLS snippet reads. It never prints a token.

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
  "backup_dir": "~/.local/share/claude-cloudflare/backups",
  "default_target": "203.0.113.10"
}
```

Tokens are read by the engine when a request needs them and go in its
Authorization header only: never in an argument, an output, a log or a file.
A token the API echoes back is masked.

## The tool

`mcp__cloudflare__cf` takes `{ command, args?, account? }`:

- reads: `auth-check`, `accounts`, `zones`, `dns-list`, `dns-get`,
  `dns-export`, `backups`, `settings`, `certs`, `plan`, `rules`, `ip-rules`,
  `security`, `cache-rules`, `workers`, `worker-routes`, `worker-domains`,
  `caddy-sites`, `caddy-site`, `caddy-status`, `caddy-docs`, `check`,
  `inventory`;
- writes: `dns-create`, `dns-update` (type change included), `dns-delete`,
  `restore`, `setting-set`, `universal-ssl`, `rule-add`, `rule-update`,
  `rule-delete`, `block-countries`, `allow-only-countries`, `rate-limit`,
  `challenge`, `managed-rules`, `ip-allow`, `ip-block`, `ip-rule-delete`,
  `bot-fight`, `security-level`, `under-attack`, `cache-rule-add`,
  `cache-rule-delete`, `purge`, `purge-all`, `worker-deploy`, `worker-delete`,
  `worker-route-add`, `worker-route-delete`, `worker-domain-add`,
  `worker-domain-delete`, `caddy-site-set`, `caddy-site-remove`, `caddy-reload`, `publish`,
  `unpublish`.

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

## Zone settings and protections

`settings` reads every zone setting generically; `setting-set`, `universal-ssl`
and `certs` cover SSL mode, Universal SSL, minimum TLS, TLS 1.3, Always Use
HTTPS and the edge certificate packs. Protections are one call each:
`block-countries tm.example.com RU CN`, `allow-only-countries tm.example.com
FR`, `challenge`, `rate-limit`, `managed-rules`, `ip-block`, `bot-fight`,
`under-attack`; `rule-add` takes a raw Cloudflare expression for the rest.

A ruleset write reads the zone's whole entrypoint, changes only the rule it
targets and writes everything back: rules made in the dashboard are never
lost. `plan` prints the zone's plan and the quotas the engine relies on; a
write the plan cannot take (a feature it lacks, a full quota) exits 5 with the
reason and sends nothing. On a Free zone, block rules for several hosts merge
into one when the five custom rules are used up.

## Cache and Workers

`cache-rule-add example.com --host tm.example.com` caches everything on a host;
`--path-prefix`, `--mode bypass` and `--mode ttl --ttl 3600` cover the usual
cases, `--expression` takes a raw one. Cache rules go through the same read,
change, write-back as the protections, so the dashboard's are kept, and the
plan's quota is checked first. `purge` takes URLs, hosts, prefixes or tags;
`purge-all` empties the zone's cache.

`worker-deploy hello --file hello.js` uploads an ES module (the script's
content is saved first when it replaces one), `worker-delete` saves the
content before deleting, `worker-route-add` / `worker-route-delete` manage a
zone's routes, `worker-domains` lists the custom domains, `worker-domain-add`
attaches a hostname to a script and `worker-domain-delete` detaches it, saved
first. `restore` puts back cache rules, a deleted script, deleted routes and a
detached domain.

## Caddy

On a machine with a Caddy, the config's `caddy` section names its files:

```json
{
  "caddy": {
    "manager": "launchd",
    "binary": "/usr/local/bin/caddy",
    "caddyfile": "/usr/local/etc/Caddyfile",
    "envfile": "/usr/local/etc/caddy.env",
    "service": "~/Library/LaunchAgents/caddy.plist",
    "tls_snippet": "tls_config",
    "sudo": false,
    "admin": "localhost:2019"
  }
}
```

`manager` is `launchd` (macOS) or `systemd` (Linux); `sudo: true` runs every
caddy call as `sudo -n`, and reads or writes the Caddyfile and its copies
through `sudo -n cat`, `tee` and `cp -p` when the user cannot. The Caddyfile
is the only source of truth: nothing is written through the admin API, and
Caddy is never stopped or restarted.

`sudo -n` never asks for a password: the commands need a sudoers rule without
one. The envfile's variables reach caddy by name (`--preserve-env=NAMES`),
which sudo allows only with the `SETENV` tag (or the names in `env_keep`).
With the paths `command -v` gives, for example in `/etc/sudoers.d/caddy`
(edited with `visudo -f`):

```
deploy ALL=(root) NOPASSWD: SETENV: /usr/bin/caddy version, /usr/bin/caddy validate *, /usr/bin/caddy reload *, \
    /usr/bin/cat /etc/caddy/Caddyfile, /usr/bin/tee /etc/caddy/Caddyfile, \
    /usr/bin/cp -p /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-*
```

A refusal of sudo is exit 4 and names the rule: before any write nothing is
changed, after one the Caddyfile is put back; it is never read as a failed
validate.

`caddy-site-set app.example.com --body-file app.caddy` replaces the block of
that host, or appends one, and keeps every other byte of the file: global
options, snippets, comments and the other sites. `caddy-site-remove` takes a
block out, `caddy-reload` reloads a file edited by hand and writes nothing,
not even a copy. Each runs the same
cycle: a copy of the Caddyfile beside it, `caddy validate` with the envfile's
variables in its environment (never in its arguments), `caddy reload`, the
admin API checked, and every site probed on `127.0.0.1:443` by its name before
and after. A site that stopped answering, a failed validate or reload, or a
dead admin API put the copy back (exit 6, or 7 when Caddy still does not
answer). A block with several addresses, or a wildcard one, is refused: those
are edited by hand.

`caddy-status` checks the binary, the admin API, the Caddyfile, `caddy
validate`, the envfile, and that the service (launchd `--envfile`, systemd
`EnvironmentFile=`) loads the envfile. `caddy-docs` prints short digests of
caddyserver.com/docs, one per directive family (`docs/caddy/`).

## Publish, check and inventory

`publish app.example.com --to 8080` puts a service on line in one command, and
one permission ask: the `A` record (proxied, on the config's `default_target`
unless `--ip` names another address; `--no-proxy` for DNS only), then the site
block through the Caddy cycle, then a `check` of the host:

```
https://app.example.com {
	import tls_config
	log
	reverse_proxy 127.0.0.1:8080
}
```

`--extra-file` adds directives after `reverse_proxy` (never an `import`, nor a
placeholder that reads the environment or a file); the permission ask shows
its size and digest, not its text. A proxied publish is refused, before
anything is written, when the zone's Universal SSL is off or its SSL mode is
not `full` or `strict`; a name with a `CNAME` or an `AAAA` is refused too. If the Caddy cycle fails after the
record was written, the record is put back from its backup, and the error
names every backup. `unpublish` removes the block, then the record.

`check app.example.com` resolves the name through `1.1.1.1` and requests it
over HTTPS on the address it resolves to: one line with the address, the HTTP
status, the certificate's issuer and its expiry. `inventory example.com`
backs the zone up (a file written), prints its SSL settings, then one line per
host with its record, its Caddy block and its check, within one deadline, and
lists the records without a block and the blocks without a record. Both reach
outside the account: a public resolver, and each host itself.

## Backups and restore

Before every zone write the engine saves what the write touches (the records
of the names, the whole ruleset entrypoint, the settings or access rules, a Worker script's content, a zone's routes) to `backup_dir/<account>/<zone>/<UTC timestamp>-<kind>.json`, and the
write's output ends with `backup: <path>`. A backup that cannot be written
stops the write. `backups` lists them; `restore <path>` brings those names
back to the saved records, after saving the current ones.

## Tests

Offline: a fixture server on 127.0.0.1 stands in for the Cloudflare API
(`CF_API_BASE`), and no real account or token is used. A fake caddy binary
and a fake running Caddy (a TLS listener reached through `CF_CADDY_PROBE`, an
admin API) stand in for Caddy; the suite needs `openssl` for their test
certificate.

```
bash tests/run-tests.sh        # the engine, install.sh, and the mod (claude plugin test)
```

## Licence

MIT.
