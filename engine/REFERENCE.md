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

## Cache rules and purge

Cache rules are the zone's `http_request_cache_settings` entrypoint, written
with the same discipline as the protections: the whole entrypoint is read,
only the targeted rule changes, every other rule is sent back, and the
entrypoint is saved first (kind `ruleset`; `restore` replays it). The plan's
cache-rule quota (Free 10, Pro 25, Business 50, Enterprise 300) is checked
before the write: exit 5 when full.

### `cache-rules <zone>` (read)

Columns: `id mode enabled description expression`. `mode` is `cache`,
`bypass`, `ttl <seconds>` or `other`.

### `cache-rule-add <zone> (--host H [--path-prefix P] | --path-prefix P | --expression E) [--mode cache|bypass|ttl] [--ttl S] [--description D]` (write)

`cache` (default) caches everything that matches; `bypass` never caches;
`ttl` caches with an edge TTL of `--ttl` seconds that overrides the origin's.
`--host` must belong to the zone. A raw `--expression` excludes `--host` and
`--path-prefix`. An equal rule already there: `unchanged`. Lines: `created`
(columns of `cache-rules`, the verb first), then `backup: <path>`.

### `cache-rule-delete <zone> <rule>` (write)

Deletes the rule of this id from the cache entrypoint, the other rules kept.
Lines: `deleted`, then `backup: <path>`.

### `purge <zone> --url U... | --host H... | --prefix P... | --tag T...` (write)

One kind per call, each flag repeatable (`"url": ["…"]` on stdin). URLs, hosts
and prefixes must belong to the zone. A call takes at most 100 values (500 URLs
on Enterprise): more exits 5. Output: `purged<TAB>files|hosts|prefixes|tags<TAB>count`.
Nothing is saved: a purge changes no stored state.

### `purge-all <zone>` (write)

Purges everything cached for the zone. Output: `purged<TAB>everything<TAB>zone`.
Asked every time.

## Workers

The account's id is `<NAME>_CLOUDFLARE_ACCOUNT_ID`, else the one account the
token sees. Script backups are kept under `backup_dir/<account>/workers/`
(kind `worker`); a zone's route backups under the zone's (kind
`worker-routes`). A script's main module is saved and restored, its name and
content: a module Worker's content is read as multipart, its main module named
by Cloudflare's `cf-entrypoint` header; a service worker's as plain text, and
restored as one. A script whose content cannot be saved whole (more than its
main module, no `cf-entrypoint`, not UTF-8) is not overwritten, deleted or
restored over: exit 5, nothing changed. Bindings are not managed, but an upload
over a script keeps the script's own, secrets included (`keep_bindings`, the
types its settings list), and its compatibility flags.

### `workers` (read)

Columns: `name modified compatibility_date`.

### `worker-deploy <name> --file <module.js> [--compatibility-date YYYY-MM-DD]` (write)

Uploads the file as an ES module: a multipart body with a `metadata` part
(`main_module`, `compatibility_date`; over a script, `keep_bindings` and
`compatibility_flags` too) and the module part. The compatibility
date defaults to the script's current one, else today (UTC). A script it
replaces is saved first. Lines: `deployed<TAB>name<TAB>date`, then
`backup: <path>` when one was taken.

### `worker-delete <name>` (write)

Saves the script's content, then deletes it. Lines: `deleted<TAB>name`, then
`backup: <path>`. `restore` uploads it again. Asked every time.

### `worker-routes <zone>` (read)

Columns: `id pattern script`.

### `worker-route-add <zone> <pattern> <script>` (write)

The pattern's host must belong to the zone and the script must exist. The
zone's routes are saved first. Lines: `created<TAB>id<TAB>pattern<TAB>script`,
then `backup: <path>`.

### `worker-route-delete <zone> <route>` (write)

By id or pattern. Lines: `deleted…`, then `backup: <path>`. `restore` of a
routes backup deletes the routes added since and creates the deleted ones again
(`recreated`, under a new id).

### `worker-domain-add <hostname> <script>` (write)

Attaches the hostname (a host of one of the account's zones) to the script as
a custom domain. Already attached to the same script: `unchanged`; attached to
another one: exit 5, nothing is overwritten. Output: `attached<TAB>host<TAB>script`.

## Caddy

The local Caddy, as the config's `caddy` section describes it: `caddyfile`
(required), `binary` (default `caddy` on the PATH), `envfile`, `manager`
(`launchd` or `systemd`), `service` (the plist or the unit), `sudo` (default
`false`), `admin` (default `localhost:2019`, host:port only). No account is
used. A missing section exits 4.

The Caddyfile is the only source of truth: nothing is written through the
admin API, and Caddy is never stopped or restarted. The envfile's variables
reach `caddy validate` and `caddy reload` through their environment, never
their arguments; with `"sudo": true` each call runs as
`sudo -n --preserve-env=<the envfile's names> <binary> …`, so a password prompt
fails instead of waiting, and the Caddyfile and its copies are read and
written through `sudo -n cat`, `tee` and `cp -p` when the user cannot. A
refusal of sudo exits 4 and names the sudoers rule it needs (NOPASSWD, and
SETENV or `env_keep` for `--preserve-env`): never a failed validate, and the
Caddyfile is put back when it was written. The envfile's values are masked in
every output, before an error line is cut; an envfile name that is not
`[A-Za-z_][A-Za-z0-9_]*`, or is `PATH`, `LD_*` or `DYLD_*`, exits 4.

A host is a DNS name, read without regard to case or an `https://` prefix.
Its block is the one whose only address is `<host>` or `https://<host>`. A
block holding the host with other addresses or under another form
(`<host>:443`, `<host>.`), two blocks for it, a wildcard host, a site written without
braces or a Caddyfile whose braces do not balance exit 5: edit those by hand,
then `caddy-reload`. A wildcard block that also covers the host is left alone.

### `caddy-sites` (read)

Columns: `address line reverse_proxy`, one line per site block (addresses
comma-joined, the upstreams of its `reverse_proxy` directives). `--json` gives
every top-level block, global options and snippets included, with `kind`,
`addresses`, `line`, `end_line`, `reverse_proxy`.

### `caddy-site <host>` (read)

The block serving the host, as written: the one naming it, else the wildcard
blocks covering it. A wildcard (`*.example.com`) names its own block. No such
block: exit 2.

### `caddy-status` (read)

Columns: `check state detail`, rows `binary` (`caddy version`), `admin`
(`alive` when `GET /config/` answers 200, `down` on any other answer),
`caddyfile` (site count),
`validate` (`ok` or `failed` with Caddy's error line), `envfile`, `service`.
Then `warning: …` lines: the service does not start Caddy with the envfile
(launchd: no `--envfile <envfile>` in `ProgramArguments`; systemd: no
`EnvironmentFile=<envfile>` in the unit or its `<unit>.d/*.conf` drop-ins), the
envfile is readable by others, the admin API does not answer.

### `caddy-docs [topic]` (read)

Without a topic, the index of the Caddy digests (`docs/caddy/`); with one,
that digest. An unknown topic exits 2 and lists them.

### `caddy-site-set <host> --body-file <path>` (write)

The file holds the block's directives only, without the address and braces;
its braces must balance (else exit 2). Its common indentation becomes one tab;
the lines inside a backtick string or a heredoc keep their bytes. The host's
block is replaced (its address kept as written) or a new `https://<host>`
block is appended after one blank line (blank lines ending the file count as
that one). Every other byte of
the file is kept. A body equal to the current one: `unchanged<TAB>host`,
nothing run.

### `caddy-site-remove <host>` (write)

Removes the host's block, its lines and one of the blank lines around it.
No such block: exit 2. The removed host going down is expected, not a failure.

### `caddy-reload` (write)

The same cycle on the file as it is (after a hand edit), writing nothing: no
copy, no rewrite, so a Caddyfile the user cannot write is reloaded all the
same. Its rollback can only reload that same file again: a host still down is
named. Output: the status lines, or `reloaded`.

### The cycle (the three writes)

One change at a time: each holds `<backup_dir>/caddy.lock` for its whole
cycle; another waits for it 15 seconds at most, then exits 5, nothing
changed. A whole cycle stays within 100 seconds (under the tool's 120): each
step's timeout is cut to what is left, 40 % of it kept for a rollback; a step
past it fails, is taken back like any failure, and the error says the budget
ran out. A caddy run past its timeout is killed with every process it started.

Before anything, a Caddyfile the user cannot write (and `sudo` is off) exits
4, and the admin API must answer: a Caddy that is not running exits 5;
nothing changed either way.

1. Copy the Caddyfile to `<caddyfile>.bak-<UTC timestamp>` (mode 600; through
   sudo, the Caddyfile's owner and mode).
2. Probe every https site of the file, old and new: a TLS handshake and a
   request on `127.0.0.1:443` with SNI = the host; `ok` (any HTTP status, or
   `no-http`: the handshake completed but no HTTP line came) or `down`
   (connection or TLS failure).
3. Write the edit in place (the file keeps its inode, owner and mode). A
   Caddyfile that cannot be written exits 4, unchanged.
4. `caddy validate --config <caddyfile> --adapter caddyfile`. Failure: the copy
   is put back, exit 6 with Caddy's error line.
5. `caddy reload --config <caddyfile> --adapter caddyfile` (with `--address
   <admin>` when the admin API is not the default), then the admin API must
   answer `GET /config/` with 200.
6. Probe again. A host `ok` before and `down` after, a failed reload or a dead
   admin API: the copy is put back, validated, reloaded and probed again; exit
   6, or 7 when Caddy is still not alive (look at it now).
7. Output: one line per host whose status changed, `host<TAB>before→after`
   (`200`, `502`, `down`…), then `backup: <copy>`. A status change that is not
   a fall to `down` (a 502 behind a stopped service) is reported, not rolled
   back.

Every failure after step 1 ends its error line with `backup: <copy>`. Any
other exception once the file is written, SIGTERM included, puts the copy back
before the engine stops. A copy that cannot be put back exits 4 (not 7: caddy
runs, the file is what failed) and says what caddy runs and what to put back.
