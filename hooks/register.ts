// The cloudflare mod: a thin facade over the engine. The $, e and next
// arguments are typed loosely here; Claude Code writes the exact API types
// to .claude-plugin/types/ the first time the mod loads (gitignored).

// The engine's commands, for the tool's command enum. The engine itself maps
// the arguments (--stdin-json); tests/run-tests.sh fails when this list and
// the engine's parser disagree.
export const COMMANDS = [
  'auth-check', 'accounts', 'zones', 'dns-list', 'dns-get', 'dns-export', 'backups',
  'dns-create', 'dns-update', 'dns-delete', 'restore',
  'settings', 'certs', 'plan', 'rules', 'ip-rules', 'security',
  'setting-set', 'universal-ssl', 'rule-add', 'rule-update', 'rule-delete', 'block-countries',
  'allow-only-countries', 'rate-limit', 'challenge', 'managed-rules', 'ip-allow', 'ip-block',
  'ip-rule-delete', 'bot-fight', 'security-level', 'under-attack',
  'cache-rules', 'workers', 'worker-routes', 'worker-domains',
  'cache-rule-add', 'cache-rule-delete', 'purge', 'purge-all', 'worker-deploy', 'worker-delete',
  'worker-route-add', 'worker-route-delete', 'worker-domain-add', 'worker-domain-delete',
  'caddy-sites', 'caddy-site', 'caddy-status', 'caddy-docs',
  'caddy-site-set', 'caddy-site-remove', 'caddy-reload',
  'check', 'inventory',
  'publish', 'unpublish',
]

// The commands that only read. Every other one writes to Cloudflare, and a
// command missing here is treated as a write, so the safe side is the default.
export const READS = new Set([
  'auth-check', 'accounts', 'zones', 'dns-list', 'dns-get', 'dns-export', 'backups',
  'settings', 'certs', 'plan', 'rules', 'ip-rules', 'security',
  'cache-rules', 'workers', 'worker-routes', 'worker-domains',
  'caddy-sites', 'caddy-site', 'caddy-status', 'caddy-docs',
  'check', 'inventory',
])

// The writes no session grant covers, asked each time: a deletion, a replay
// over the current state, a purge, an emergency mode and a site taken down.
export const NEVER_GRANTED = new Set([
  'dns-delete', 'restore', 'purge-all', 'under-attack', 'worker-delete', 'unpublish',
])

export const TOOL = 'mcp__cloudflare__cf'

// The script a command runs through: reads through cf.py, writes through
// cf-write.py. Each refuses the other's commands, the split the Bash fallback
// relies on to let permission rules tell a write from a read.
export function entryFor(command: string): string {
  return READS.has(command) ? 'cf.py' : 'cf-write.py'
}

// The request travels as JSON on stdin: the engine maps it onto its own
// parser and refuses what that parser does not declare. No argv is built
// from the input, and the token never leaves the engine.
async function runCf($: any, command: string, args: Record<string, unknown> = {}, account?: string): Promise<string> {
  const entry = entryFor(command)
  const r = await $.process.run(
    ['python3', $.plugin.root + '/engine/' + entry, '--stdin-json'],
    { stdin: JSON.stringify({ command, args, account }), timeoutMs: 120_000 },
  )
  if (r.exitCode !== 0) throw new Error(r.stderr || entry + ' exited ' + r.exitCode)
  return r.isStdoutTruncated ? r.stdout + '\n[output cut at 4 MiB]' : r.stdout
}

/*
 * A tool.call hook that answers in place of next(e) skips core, and with it
 * the permission check: settings rules and the mode would never be read. So
 * the hook asks for the verdict itself. A deny refuses. An ask with no rule
 * behind it lets a read through, as reading is what the tool is mostly for,
 * and puts a write to the person. An ask from an explicit rule always asks.
 * Where nobody can answer (a -p run) the ask rejects and the call is refused.
 */
async function permit($: any, e: any): Promise<string | undefined> {
  const input = { command: e.command, args: e.args, account: e.account }
  const verdict = await $.tool.check({ tool: TOOL, input })
  if (verdict.decision === 'deny') return verdict.reason || 'refused by a permission rule'
  if (verdict.decision === 'allow') return undefined
  if (READS.has(e.command) && !verdict.rule) return undefined

  // A grant for the session stands in for an ask no rule demanded, and only
  // for the command and account it was given on.
  const grantable = !verdict.rule && !NEVER_GRANTED.has(e.command)
  const key = grantable ? await grantKey($, e) : undefined
  if (key && sessionGrants.has(key)) return undefined
  const described = await describe($, e)
  if (!key) return ask($, described + '?', ['Allow', 'Deny'], e.command)
  const question = '« Allow for this session » also allows every later cf ' + e.command + ' on '
    + where(e) + inZone(e) + ' until the session ends. ' + described + '?'
  try {
    const answer = await $.ui.ask(question, ['Allow', 'Allow for this session', 'Deny'])
    if (answer === 'Allow') return undefined
    if (answer === 'Allow for this session') {
      sessionGrants.add(key)
      return undefined
    }
  } catch {
    return 'cf ' + e.command + ' needs permission and nobody could be asked'
  }
  return 'the user refused cf ' + e.command
}

async function ask($: any, question: string, options: string[], command: string): Promise<string | undefined> {
  try {
    if ((await $.ui.ask(question, options)) === options[0]) return undefined
  } catch {
    return 'cf ' + command + ' needs permission and nobody could be asked'
  }
  return 'the user refused cf ' + command
}

// The Caddy commands act on this machine's Caddy, whatever the account.
function isCaddy(command: string): boolean {
  return command.startsWith('caddy-')
}

// The writes that change a zone and the local Caddy in one command.
const SPANNING = new Set(['publish', 'unpublish'])

function where(e: any): string {
  if (isCaddy(e.command)) return 'the local Caddy'
  const account = e.account ? 'account ' + String(e.account).toLowerCase() : 'the default account'
  return SPANNING.has(e.command) ? account + ' and the local Caddy' : account
}

function cut(text: string): string {
  return text.length > 200 ? text.slice(0, 199) + '…' : text
}

function zoneOf(e: any): string {
  const zone = e.args?.zone
  return zone === undefined || zone === null ? '' : String(zone).toLowerCase()
}

function inZone(e: any): string {
  return zoneOf(e) ? ' in zone ' + zoneOf(e) : ''
}

// The arguments that say what a write touches, shown whole and first, so that
// the cut of a long remainder can never hide them.
const NAMED = ['zone', 'record', 'name', 'path']

// The command and its target come first, whole: only the remaining arguments are cut.
async function describe($: any, e: any): Promise<string> {
  const args = e.args ?? {}
  const host = (isCaddy(e.command) || SPANNING.has(e.command)) && typeof args.host === 'string' ? args.host : undefined
  const named = NAMED.filter((k) => args[k] !== undefined && args[k] !== null)
    .map((k) => k + ' ' + (typeof args[k] === 'string' ? args[k] : JSON.stringify(args[k])))
  const head = 'Run cf ' + e.command + ' on ' + where(e) + (host ? ' for ' + host : '')
    + named.map((n) => ', ' + n).join('') + ' with '
  if (e.command === 'publish') return head + await publishing($, args, host)
  const detail = cut(JSON.stringify(Object.fromEntries(Object.entries(args).filter(([k]) => !NAMED.includes(k)))))
  if (e.command === 'unpublish') {
    return head + detail + '. It removes the site block of ' + host + ' and deletes every A, AAAA and CNAME record of ' + host
  }
  return head + detail
}

// What a publish does, in the order a person reads it: the target, the
// address, the proxy, what it may overwrite, then the extra file by its size
// and digest, never its text; the other arguments last, cut.
async function publishing($: any, args: Record<string, unknown>, host: string | undefined): Promise<string> {
  const known = ['host', 'to', 'ip', 'no-proxy', 'extra-file']
  const parts = [
    '--to ' + cut(String(args.to)),
    '--ip ' + (args.ip === undefined ? 'the default_target of the config' : cut(String(args.ip))),
    args['no-proxy'] === true ? 'DNS only (--no-proxy)' : 'proxied',
  ]
  let text = parts.join(', ') + '. It may overwrite an existing DNS record of ' + host + ' and its existing site block.'
  if (args['extra-file'] !== undefined) {
    const path = String(args['extra-file'])
    text += ' --extra-file ' + cut(path) + ': ' + await fingerprint($, path)
  }
  const rest = Object.fromEntries(Object.entries(args).filter(([name]) => !known.includes(name)))
  return Object.keys(rest).length ? text + ' Other arguments: ' + cut(JSON.stringify(rest)) : text
}

async function fingerprint($: any, path: string): Promise<string> {
  try {
    const read = await $.fs.read(path, { as: 'bytes' })
    const bytes = Uint8Array.from(atob(read.base64), (c) => c.charCodeAt(0))
    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))
    const hex = Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('')
    return bytes.length + ' bytes, sha256 ' + hex.slice(0, 12)
  } catch {
    return 'cannot be read, publish will refuse it'
  }
}

// A grant is the session's, the command's, the account's (named or the
// default one) and the zone's; for a Caddy command, the local Caddy's.
async function grantKey($: any, e: any): Promise<string | undefined> {
  try {
    const session = await $.session.id()
    return session + '\n' + e.command + '\n' + where(e) + '\n' + zoneOf(e)
  } catch {
    // Without the session no grant can be scoped: ask.
    return undefined
  }
}

// The grants « Allow for this session » gave, by session, command, account and zone.
// Kept in the module: a reload or a restart drops them, which only asks again.
const sessionGrants = new Set<string>()

// install.sh's exit codes, the table commands/doctor.md gives in prose.
export const DIAGNOSTIC: Record<number, string> = {
  0: 'everything satisfied',
  11: 'python3 3.9 or later is missing',
  12: 'no Cloudflare account: set <NAME>_CLOUDFLARE_API_TOKEN, then run /cloudflare:doctor',
  13: 'a token failed its check: replace it, then run /cloudflare:doctor',
  14: 'the config file is not valid: fix it, then run /cloudflare:doctor',
  15: 'the local Caddy is not ready: fix what is named, then run /cloudflare:doctor',
}

// install.sh run in the session's directory, its output verbatim and its exit
// code named. Both commands only check; install also says how to set up.
export async function diagnose($: any, check = false): Promise<string> {
  const argv = ['bash', $.plugin.root + '/install.sh', ...(check ? ['--check'] : [])]
  const r = await $.process.run(argv, { timeoutMs: 120_000 })
  const out = [r.stdout, r.stderr].map((t: string) => (t ?? '').trimEnd()).filter(Boolean).join('\n')
  const meaning = DIAGNOSTIC[r.exitCode] ?? 'an unexpected failure'
  return out + '\n\nExit code ' + r.exitCode + ': ' + meaning + '.'
}

export function register(on: any): void {
  on('session.start', async ($: any, e: any, next: any) => {
    const root = $.plugin.root
    await $.tool.register({
      name: 'cf',
      // Listed with its schema from the start: behind ToolSearch the model
      // would reach for Bash and curl before it found this tool.
      isDeferred: false,
      description:
        'Cloudflare API: accounts by name, zones, DNS records (list, get, export, '
        + 'create, update, delete), protections, cache, Workers (scripts, routes, '
        + 'custom domains), the backups taken before every write and their '
        + 'restore; the local Caddy: site blocks of the Caddyfile, set or removed '
        + 'through validate, reload and rollback, with digests of the Caddy docs '
        + '(caddy-docs); and both at once: publish and unpublish a host, check it '
        + 'from the public side, inventory a zone against the Caddyfile. Before first use, Read ' + root + '/engine/REFERENCE.md for every '
        + 'command. Pass positionals by their documented name (dns-get: {"zone": '
        + '"example.com", "record": "www"}); other keys become --flags. Output is '
        + 'compact text; "json": true on a read gives full objects.',
      inputSchema: {
        type: 'object',
        properties: {
          command: { type: 'string', enum: COMMANDS },
          args: {
            type: 'object',
            description: 'command arguments: positionals by name, flags as keys',
          },
          account: { type: 'string', description: 'the account by name (default: the configured one)' },
        },
        required: ['command'],
      },
    })
    return next(e)
  }).catch(async (_$: any, e: any, next: any) => next(e))

  on('tool.call', { tool: TOOL }, async ($: any, e: any) => {
    const refused = await permit($, e)
    if (refused) return { deny: refused }
    try {
      return { result: await runCf($, e.command, e.args ?? {}, e.account) || '(no output)' }
    } catch (err: any) {
      return { result: String(err?.message ?? err), isError: true }
    }
  }).catch(async () => ({ deny: 'cloudflare mod error: the hook itself failed' }))

  // The markdown commands answered here without a model turn. A failure falls
  // back to the markdown, which runs the same script through the model.
  on('command.run', { command: 'cloudflare:install' }, async ($: any) => ({ text: await diagnose($) }))
    .catch(async (_$: any, e: any, next: any) => next(e))
  on('command.run', { command: 'cloudflare:doctor' }, async ($: any) => ({ text: await diagnose($, true) }))
    .catch(async (_$: any, e: any, next: any) => next(e))
}
