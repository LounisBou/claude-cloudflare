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
backup that cannot be written stops the write.

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
