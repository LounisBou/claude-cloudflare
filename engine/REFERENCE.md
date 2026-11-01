# cf.py reference

## Calling

The `mcp__cloudflare__cf` tool takes `{"command", "args", "account"}`:

- `command`: one of the commands below.
- `args`: positionals by their documented name (`dns-get` →
  `{"zone": "example.com", "record": "www"}`); every other key is one of the
  command's own `--flag`s, spelled out whole (`{"type": "A"}` → `--type A`,
  `{"json": true}` → `--json`, `{"proxied": false}` → `--no-proxied`). An
  unknown or abbreviated key is refused.
- `account`: the account by name, without regard to case. Omitted, the
  config's `default_account`, else the only account found.

The mod sends a read to `cf.py --stdin-json` and a write to
`cf-write.py --stdin-json`, the request on stdin: no argument vector is built
from the input. `cf.py` runs only reads and `cf-write.py` only writes; each
refuses the other's commands with exit 2. A command the mod does not list as a
read is a write.

From Bash (the `cf-curl` skill): `python3 cf.py [--account NAME] <command> ...`
for reads, `python3 cf-write.py [--account NAME] <command> ...` for writes.

## Output

Compact text: a header line, then one line per object, tab-separated. `--json`
on any read prints the full objects instead. A write prints what it did and
ends with `backup: <path>`; a write whose call fails once its backup is taken
ends its error with `; backup: <path>`. Errors are one line, `cf: <message>`,
on stderr.

| Exit | Meaning |
|---|---|
| `0` | ok |
| `1` | internal error: `cf: internal error: <exception type>`, never a traceback |
| `2` | usage: unknown command or argument, a write sent to `cf.py`, no such zone or record |
| `3` | Cloudflare API error (`cf: Cloudflare <code>: <message>`), or the API unreachable |
| `4` | config or credentials: no account, unknown account, invalid config, backup not writable |
| `5` | refused by the zone's plan or quota, or by a safety guard |
| `6` | Caddy change rolled back |
| `7` | Caddy not alive after reload, rollback failed |

## Accounts

An account `<name>` exists when `<NAME>_CLOUDFLARE_API_TOKEN` is in the
environment or in an env file of the config (`env_files`, default
`["~/.env"]`); the environment wins. `<NAME>_CLOUDFLARE_ACCOUNT_ID` is
optional: when absent it is looked up from the token where needed. The
config is `$CLAUDE_CLOUDFLARE_CONFIG`, else
`~/.config/claude-cloudflare/config.json`.

### `accounts` (read)

No arguments, no API call. Columns: `name default source account_id`.

### `auth-check` (read)

Verifies the account's token (as a user token, else on its account).
Columns: `account status token_id expires_on`.

## Zones and DNS

A zone is named by its name or its id. A record is named by its id, or by its
name: relative to the zone (`www`, `@` for the apex) or whole
(`www.example.com`). `--ttl 1` is automatic, the default.

### `zones` (read)

The account's zones only, filtered on its account id; a token that sees
several accounts needs `<NAME>_CLOUDFLARE_ACCOUNT_ID` (exit 4 without it).
Columns: `name id status plan`.

### `dns-list <zone> [--type T] [--name N]` (read)

Columns: `type name content proxied ttl id`. An MX or SRV content starts with
its priority.

### `dns-get <zone> <record> [--type T]` (read)

Every record of the name (or the record of the id), as `dns-list` prints them.
Exit 2 when there is none.

### `dns-export <zone>` (read)

The zone file, as Cloudflare exports it. `--json`: every record, whole.

### `dns-create <zone> --name N --type T --content C [--ttl S] [--proxied|--no-proxied] [--priority P] [--comment C]` (write)

Prints `created` and the record's columns. Proxied is Cloudflare's default
(off) unless given.

### `dns-update <zone> <record> [--from-type T] [--type T] [--name N] [--content C] [--ttl S] [--proxied|--no-proxied] [--priority P] [--comment C]` (write)

Overwrites the record with the fields given, its type included (a CNAME into
an A keeps its id). A type change needs `--content`, and leaves behind the
fields of the old type (`priority`, `data`) unless given again. A type that
cannot be proxied drops the proxy. When the
name has several records, `--from-type` picks by type, else name it by its id.
Prints `before` and `after` lines.

### `dns-delete <zone> <record> [--type T]` (write)

Prints `deleted` and the record's columns. Asked every time.

## Backups

Before every zone write, the records of the names it touches are saved to
`backup_dir/<account>/<zone>/<UTC timestamp>-<kind>.json` (mode 600). A
backup that cannot be written stops the write. When a settings, ruleset, IP
access rule or Bot Fight Mode write fails after its backup, its error ends
with `; backup: <path>`.

### `backups [--zone Z]` (read)

Oldest first; `--account` filters by account. Columns:
`account zone taken kind path`.

### `restore <path>` (write)

Brings the names of the backup back to the records it holds, on the record
types it holds (those of its records and those its write touched): records of
those types added since are deleted, changed ones overwritten, deleted ones
created again under a new id. Records of other types are kept. It takes its
own backup first, so a restore can be restored. Lines: `deleted`, `restored`,
`recreated`, `kept: <n> records of a type the backup does not hold` when some
were kept, then `backup: <path>`; nothing differing, `nothing to restore: …`. The account is the backup's; another one named is
refused. Asked every time.

## Zone settings and certificates

### `settings <zone> [setting]` (read)

Every setting Cloudflare exposes under `/zones/:id/settings`, read generically
(`ssl`, `min_tls_version`, `tls_1_3`, `always_use_https`, `security_level`…),
or one by its id. Columns: `id value editable`; an object value is printed as
compact JSON.

### `setting-set <zone> <setting> <value>` (write)

Changes one setting. `ssl` takes `off flexible full strict`, `min_tls_version`
`1.0`…`1.3`, `tls_1_3` `on off zrt`, `always_use_https` `on off`; any other
setting is sent as given (a number or an object as JSON) and Cloudflare
judges it. `security_level` is refused: use `security-level` or `under-attack`.
Prints `changed <setting> <before> <after>`, or `unchanged` with no call and
no backup.

### `universal-ssl <zone> on|off` (write)

Turns Universal SSL on or off. Prints `changed universal_ssl <before> <after>`.

### `certs <zone>` (read)

The edge certificate packs. Columns: `id type status hosts expires authority`
(`expires` is the latest of the pack's certificates).

## Plan awareness

### `plan <zone>` (read)

Rows `item value limit`: `plan` (name), `custom_rules` (used, quota),
`rate_limit_rules` (used, quota), `managed_rulesets` (the ones the plan
offers: `free`, `cloudflare`, `owasp`), `bot_product`. Quotas come from
Cloudflare's product documentation and are kept in `cflib/quotas.py`: custom
rules 5 / 20 / 100 / 1,000 and rate limiting rules 1 / 2 / 5 / 100 on Free /
Pro / Business / Enterprise. A plan the table does not know takes the
Enterprise column.

Every protection write checks them first and exits 5, with one line
`cf: plan <name>: <reason>`, when the plan lacks the feature or the quota is
full: nothing is sent. A custom rule written past the quota is merged into
the plugin's existing rule of the same action (an `or` of both expressions,
the description extended) when that is possible, which is how host-scoped
protections share the five slots of a Free zone.

## Protections

A target is a host of one of the account's zones (`tm.example.com`), or a
zone's name for the whole zone; a wildcard host (`*.example.com`) exits 2, as
a rule on `http.host` never matches it: target the zone instead. Every write
below reads the zone's whole entrypoint, changes only the rule it targets and
puts the whole list back, so rules made in the dashboard stay as they were; it
saves the entrypoint first (`backup: <path>`, kind `ruleset`) and `restore`
replays it. Such a backup keeps every rule of the phase, the dashboard's
expressions included, in clear (file mode 0600). A rule that already exists is
left alone (`unchanged`). The rules the plugin creates have a description
starting with `cf-plugin:`.

### `rules <zone> [--phase custom|ratelimit|managed] [--plugin]` (read)

Columns: `phase id action enabled description expression`; `--plugin` keeps
the rules the plugin made.

### `rule-add <zone> --expression E --action A [--description D]` (write)

A custom rule from a raw Cloudflare expression; `A` is `block`, `challenge`,
`js_challenge`, `managed_challenge` or `log` (Enterprise only). Never merged:
a full quota exits 5.

### `rule-update <zone> <rule> [--expression E] [--action A] [--description D] [--enabled|--no-enabled]` (write)

Changes a rule of any of the three phases, by its id. Prints `before` and
`after` lines.

### `rule-delete <zone> <rule>` (write)

Prints `deleted` and the rule's columns.

### `block-countries <target> <CC...>` / `allow-only-countries <target> <CC...>` (write)

Block the visitors of these countries (two-letter codes, `T1` for Tor), or
every country but these, on a host or the whole zone. Custom rules; mergeable.

### `challenge <target> [--path P] [--country CC]... [--type managed|js|interactive]` (write)

Challenges the visitors of a host, narrowed to a path prefix and to countries.

### `rate-limit <target> --requests N [--period S] [--timeout S] [--path P] [--action block|challenge|js_challenge|managed_challenge]` (write)

A rate limiting rule (per IP and data centre). The period and the timeout
take Cloudflare's values only (10, 15, 20, 30, 40, 45, 60, 90, 120, 180, 240,
300, 480, 600, 900, 1200, 1800, 2400, 3600, 65535, 86400), up to the plan's
maximum: Free counts over 10 seconds and mitigates for 10; Pro counts up to
60 and mitigates up to 3600; Business up to 600 and 86400; Enterprise counts
up to 65535 and mitigates for any time up to 86400. Defaults: a period of 60
and a timeout of 600 where the plan allows them, else 10. Never merged.

### `managed-rules <zone> on|off [--ruleset free|cloudflare|owasp]` (write)

Deploys a managed ruleset (default `free` on Free, else `cloudflare`); the
plan must offer it. `off` deletes the plugin's rule and turns a dashboard's
off without deleting it.

## IP access rules, bots, security level

### `ip-rules <zone>` (read)

Columns: `mode target value notes id`; `mode` is `allow` or `block`.

### `ip-allow <zone> <target> [--note N]` / `ip-block <zone> <target> [--note N]` (write)

The target is an IPv4 or IPv6 address, a CIDR range (IPv4 `/16` or `/24`,
IPv6 `/32`, `/48` or `/64`, host bits zero; any other prefix exits 2),
`AS64500` or a country code. An existing rule of the target changes its mode (`before` / `after`). Saves the zone's
access rules first (kind `ip-rules`).

### `ip-rule-delete <zone> <rule>` (write)

The rule by its id or by its target.

### `security <zone>` (read)

Rows `item value`: security level, browser check, challenge TTL, Bot Fight
Mode, the numbers of custom, rate limiting and managed rules and of IP access
rules.

### `security-level <zone> essentially_off|low|medium|high` (write)

`under_attack` is refused: it is `under-attack`, which is asked every time.

### `under-attack <zone> on|off [--level L]` (write)

`on` sets the security level to `under_attack`; `off` sets it back to `L`
(default `medium`). Asked every time.

### `bot-fight <zone> on|off` (write)

Bot Fight Mode, the Free plan's product. Other plans (Super Bot Fight Mode,
Bot Management) exit 5: they are set in the dashboard.
