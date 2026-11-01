# Plan — plugin `cloudflare` (Cloudflare + Caddy)

> Orchestrator header: phases are executed by implementer sessions spawned by the orchestrator, one
> phase = one session = one pull request. No plan-execution sub-skill applies.

Spec: `docs/specs/2026-11-01-cloudflare-design.md` (French). Prior art, read-only:
`~/.claude/plugins/cache/lounisbou/github/0.10.2` (`claude-github`: mod `hooks/register.ts`, engine
`engine/gh.py` + `engine/ghlib/`, fallback skill `skills/github-curl/`, `install.sh`, `commands/`,
`tests/run-tests.sh`). **Follow its patterns over generic practice.**

Method: the repository ships by **auto-merge** (operator, 2026-11-01): each pull request, once reviewed
(evidence review + norms check) and its single correction round verified, is squash-merged by the
orchestrator. Pull requests are opened as drafts by the implementer. Docs (spec, plan) are committed;
briefs are not (they live in `~/dev/CloudflareConfig/briefs/`). Commits: Conventional Commits, no AI
attribution, no mention of phases/agents/orchestrator in code, commits or PR text.

## Global constraints (every phase)

- Python 3.9+ standard library only in `engine/`; TypeScript mod with no npm dependency.
- **No real Cloudflare account and no real Caddy in tests.** Cloudflare: the engine's base URL is
  overridable by `CF_API_BASE` (tests point it at a local fixture server started by the suite);
  Caddy: the `caddy` binary and the service manager are paths from the config, tests point them at
  fake scripts. A test that would reach `api.cloudflare.com` or the real `/opt/homebrew/etc/Caddyfile`
  is a defect.
- A token never appears in stdout, stderr, a log, an argv (`ps`) or a file the plugin writes. Tests
  assert it (grep of every captured output for the fixture token).
- Output: compact text by default (one line per object, `\t`-separated, no JSON); `--json` on every
  read command for full objects. Errors: one line `cf: <message>` on stderr.
- Exit codes (contract, all phases): `0` ok · `1` internal error (one redacted line,
  `cf: internal error: <exception type>`, never a traceback) · `2` usage · `3` Cloudflare API error · `4`
  config/credentials · `5` refused by plan/quota or by a safety guard · `6` Caddy change rolled back ·
  `7` Caddy not alive after reload and rollback failed (operator must look).
- Quality gate per phase: `bash tests/run-tests.sh` green (engine), mod tests green (same runner as
  `claude-github`), `python3 -m py_compile` on all engine files.

## Contracts

### C1 — the tool (phase 1, extended by every later phase)

- Mod `hooks/register.ts` registers one tool, **`mcp__cloudflare__cf`** (server `cloudflare`, tool
  `cf`), input `{ command: <enum COMMANDS>, args?: object, account?: string }`.
- `export const COMMANDS: string[]` and `export const READS: Set<string>`; **a command absent from
  `READS` is a write**. `tests/run-tests.sh` fails when `COMMANDS` and the engine's parser disagree.
- Permission (`permit`), as `claude-github`: `$.tool.check` verdict; deny refuses; a read with no rule
  runs; every write asks the person (`Allow` / `Allow for this session` / `Deny`), except commands in
  `export const NEVER_GRANTED` (asked every time): `dns-delete`, `restore`, `purge-all`,
  `under-attack`, `worker-delete`, `unpublish`. Nobody to ask (`-p`) → refused.
- The mod runs `python3 <root>/engine/cf.py --stdin-json` with stdin
  `{"command","args","account"}`; no argv built from user input.
- Fallback skill `skills/cf-curl/`: `engine/cf.py` (reads only: refuses a write command with exit 2
  and the message `use cf-write.py`) and `engine/cf-write.py` (writes only), so Bash permission rules
  can tell them apart.

### C2 — engine layout (phase 1)

```
engine/cf.py            entry: argparse (allow_abbrev=False), --stdin-json, dispatch, exit codes
engine/cf-write.py      entry for writes (same parser, writes only)
engine/cflib/errors.py  UsageError(2) ApiError(3) ConfigError(4) Refused(5) RolledBack(6) NotAlive(7)
engine/cflib/config.py  load_config() -> Config ; Config.account(name|None) -> Account
engine/cflib/creds.py   token(account) -> str  (never logged)
engine/cflib/http.py    class Api: get/post/put/patch/delete(path, body=None, params=None) -> dict|list
                        (pagination folded, "success": false -> ApiError with Cloudflare's codes)
engine/cflib/fmt.py     table(rows, cols) -> str ; as_json(obj) -> str
engine/cflib/backup.py  save(account, zone, kind, obj) -> path ; list_() ; load(path)
engine/cflib/<domain>.py  each: register(subparsers) and handlers run(args, ctx) -> str
```

`ctx` = `Context(config: Config, account: Account, api: Api, backup: module)`.

- **Accounts by name** (spec §2): an account `<name>` exists when `<NAME>_CLOUDFLARE_API_TOKEN` is
  found (`NAME` = name upper-cased) in the process environment or in an env file listed by the config
  (default `["~/.env"]`); `<NAME>_CLOUDFLARE_ACCOUNT_ID` optional (looked up from the token when
  absent). `account` omitted → `config.default_account`, else the only account found, else exit 4.
- Config file (machine-local, never in the repo): `$CLAUDE_CLOUDFLARE_CONFIG` or
  `~/.config/claude-cloudflare/config.json`, all keys optional:

```json
{
  "default_account": "izno",
  "env_files": ["~/.env"],
  "backup_dir": "~/.local/share/claude-cloudflare/backups",
  "default_target": "203.0.113.10",
  "caddy": {
    "manager": "launchd",
    "binary": "/opt/homebrew/opt/caddy/bin/caddy",
    "caddyfile": "/opt/homebrew/etc/Caddyfile",
    "envfile": "/opt/homebrew/etc/caddy.env",
    "service": "~/Library/LaunchAgents/homebrew.mxcl.caddy.plist",
    "tls_snippet": "tls_config",
    "sudo": false,
    "admin": "localhost:2019"
  }
}
```

- **Backup before every zone write** (spec §6): the objects a write touches are saved as JSON under
  `backup_dir/<account>/<zone>/<UTC timestamp>-<kind>.json` before the call; the write's output ends
  with `backup: <path>`. `restore <path>` replays it (write, NEVER_GRANTED).

### C3 — commands (names are the contract; arguments are the builder's, documented in REFERENCE.md)

| Phase | Reads | Writes |
|---|---|---|
| 1 | `auth-check`, `accounts`, `zones`, `dns-list`, `dns-get`, `dns-export`, `backups` | `dns-create`, `dns-update`, `dns-delete`, `restore` |
| 2 | `settings`, `certs`, `plan`, `rules`, `ip-rules`, `security` | `setting-set`, `universal-ssl`, `rule-add`, `rule-update`, `rule-delete`, `block-countries`, `allow-only-countries`, `rate-limit`, `challenge`, `managed-rules`, `ip-allow`, `ip-block`, `ip-rule-delete`, `bot-fight`, `security-level`, `under-attack` |
| 3 | `cache-rules`, `workers`, `worker-routes` | `cache-rule-add`, `cache-rule-delete`, `purge`, `purge-all`, `worker-deploy`, `worker-delete`, `worker-route-add`, `worker-route-delete`, `worker-domain-add` |
| 4 | `caddy-sites`, `caddy-site`, `caddy-status`, `caddy-docs` | `caddy-site-set`, `caddy-site-remove`, `caddy-reload` |
| 5 | `check`, `inventory` | `publish`, `unpublish` |

Plan awareness (phase 2, spec §6): `plan` prints the zone's plan and the quotas the engine relies on;
every protection write checks them first and exits 5 with the reason when the plan lacks the feature
or the quota is full. Ruleset writes read the phase entrypoint, change only the rules they target, and
write it back with every other rule intact (rules made in the dashboard included).

### C4 — Caddy cycle (phase 4, spec §6, binding)

`caddy-site-set <host> --body-file <path>` / `caddy-site-remove <host>` / `caddy-reload`:
1. Copy the Caddyfile to `<caddyfile>.bak-<UTC timestamp>`.
2. Edit: the block whose address is exactly `https://<host>` or `<host>` is replaced/removed/appended;
   brace-aware parser; global options, snippets, `:80`, comments and every other block are kept
   byte-for-byte; a block with several addresses or a wildcard is refused (exit 5).
3. `caddy validate --config <caddyfile>` with the envfile's variables in the **environment** of the
   child process (never argv). Failure → restore the copy, exit 6 with Caddy's error line.
4. Probe « before » (taken before the edit): for every site host in the file, TLS handshake +
   HTTP request to `127.0.0.1:443` with SNI = host; class = `ok` (any HTTP status) or `down`
   (connect or TLS failure).
5. `caddy reload --config <caddyfile>` (env as in 3); with `sudo: true`, `sudo -n` prefixes the call.
   Never stop, restart, `brew services restart` or `systemctl restart`.
6. Alive: admin API `GET http://<admin>/config/` answers 200.
7. Probe « after »; any host `ok` → `down`, or not alive → restore the copy, validate, reload, probe
   again, exit 6 (or 7 when it is still not alive), listing the hosts.
8. Output: one line per host whose HTTP status changed (`host before→after`), then `backup: <path>`.

`caddy-status` also checks the service starts with the envfile: launchd plist carries `--envfile
<envfile>`, or the systemd unit carries `EnvironmentFile=<envfile>`; missing → a warning line.
`caddy-docs [topic]` prints the index or one topic file from `docs/caddy/` (short French or English
digests of caddyserver.com/docs, one file per directive family, each < 150 lines).

### C5 — combined commands (phase 5)

- `publish <host> --to <port|url> [--no-proxy] [--ip <a.b.c.d>] [--extra-file <caddy directives>]`:
  refuses (exit 5) a proxied publish when Universal SSL is off or SSL mode is not `full`/`strict`;
  creates or updates the A record (`default_target` when `--ip` omitted); writes the site block
  `https://<host> {\n\timport <tls_snippet>\n\tlog\n\treverse_proxy <to>\n}` (+ extra directives)
  through the C4 cycle; then `check <host>`. One permission ask for the whole command.
- `unpublish <host>`: removes the block (C4), deletes the record (backup first).
- `check <host>`: public resolution (1.1.1.1), HTTPS through the public address, status, certificate
  issuer and expiry; one line.
- `inventory`: zone backup, SSL settings, DNS ↔ Caddyfile matrix (records without block, blocks
  without record), `check` of every host; compact table.

## Phases

| # | Branch (base) | Scope | Tier |
|---|---|---|---|
| 1 | `feat/foundation` (`main`) | C1, C2, phase-1 commands of C3, `install.sh`, `/cloudflare:install`, `/cloudflare:doctor`, fallback skill, README, REFERENCE.md, tests harness (fixture server, fake token grep) | deep |
| 2 | `feat/security` (phase 1 head) | zone settings, certificates, plan awareness, rulesets and every phase-2 command | standard |
| 3 | `feat/cache-workers` (phase 2 head) | cache rules, purge, Workers (script upload multipart, routes, custom domains) | standard |
| 4 | `feat/caddy` (phase 3 head) | C4, launchd + systemd, `docs/caddy/` digests, phase-4 commands | deep |
| 5 | `feat/publish` (phase 4 head) | C5, `doctor` extended (token permissions, Caddy envfile and token), final spec-conformity pass section by section, E2E of the spec on fixtures | standard |

Each phase: TDD, its own E2E on fixtures (`E2E: tests/run-tests.sh — <cases>`), REFERENCE.md
updated for its commands, README section, version bump in `plugin.json` (0.1.0 at phase 1, minor per
phase).

### Review focus per phase

1. Contracts C1/C2 exactly; READS-default-write; token never leaks; permit mirrors `claude-github`.
2. Ruleset merge keeps foreign rules; plan refusal before any write; backups.
3. Purge scope; worker upload format; NEVER_GRANTED.
4. Byte-for-byte preservation of untouched Caddyfile parts; rollback path really restores and
   reloads; env never in argv; no stop/restart anywhere.
5. Publish refusal guards; one ask; inventory output size.

## After phase 5 (orchestrator)

1. Marketplace: add `cloudflare` (source github `LounisBou/claude-cloudflare`) to the `lounisbou`
   marketplace repository.
2. Deploy on IznoServer: install the plugin, write `~/.config/claude-cloudflare/config.json` (values
   of C2), `/cloudflare:doctor` green, `inventory` read-only run compared with the 2026-11-01 manual
   inventory.
