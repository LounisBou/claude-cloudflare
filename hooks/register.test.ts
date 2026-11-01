import { expect, test } from 'claude-code/testing'
import { COMMANDS, READS, NEVER_GRANTED } from './register.js'

test('session.start registers the cf tool with the command enum', async ($, on) => {
  const registered: any[] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('tool.register', (_$, e) => {
    registered.push(e)
    return { value: undefined }
  })

  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  expect(registered.length).toBe(1)
  expect(registered[0].name).toBe('cf')
  expect(registered[0].isDeferred).toBe(false)
  expect(registered[0].inputSchema.properties.command.enum).toEqual(COMMANDS)
  expect(Object.keys(registered[0].inputSchema.properties)).toEqual(['command', 'args', 'account'])
  expect(registered[0].inputSchema.required).toEqual(['command'])
  expect(registered[0].description).toContain('/engine/REFERENCE.md')
})

// reply: a fixed { exitCode, stdout, stderr } value, or a function (e) => value
// for sequenced replies. Registered once per test — never register a second
// process.run stub afterwards; pass a function instead.
async function stubMod(
  on: any,
  runs: any[],
  reply: any = { exitCode: 0, stdout: 'ok', stderr: '' },
  verdict: any = { decision: 'allow' },
) {
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'session-1' }))
  // The dialog a $.ui.ask raises is itself checked: it must not meet the verdict
  // meant for the cf call.
  on('tool.check', (_$: any, e: any) => (e.tool === 'AskUserQuestion' ? { decision: 'allow' } : verdict))
  on('tool.register', () => ({ value: undefined }))
  on('process.run', (_$: any, e: any) => {
    // Each run is recorded as the request the engine reads on stdin, plus its argv.
    runs.push({ argv: e.argv, ...JSON.parse(e.init?.stdin ?? '{}') })
    return { value: typeof reply === 'function' ? reply(e) : reply }
  })
}

// answer: the label the stubbed dialog returns, or undefined for a dialog
// nobody can answer (a -p run).
function stubAsk(on: any, asked: string[], answer: string | undefined) {
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const question = e.questions[0].question
    asked.push(question)
    if (answer === undefined) return { deny: 'no one to ask' }
    return { result: { questions: e.questions, answers: { [question]: answer } } }
  })
}

const call = ($: any, command: string, args?: any, account?: string) =>
  $.tool.call({ tool: 'mcp__cloudflare__cf', command, ...(args ? { args } : {}), ...(account ? { account } : {}) })

test('a read goes to cf.py as JSON on stdin, no argv built from the input', async ($, on) => {
  const runs: any[] = []
  await stubMod(on, runs)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out = await call($, 'dns-get', { zone: 'example.com', record: 'www; rm -rf /' }, 'alpha')

  expect(out).toEqual({ result: 'ok' })
  expect(runs.length).toBe(1)
  expect(runs[0].argv[0]).toBe('python3')
  expect(runs[0].argv[1].endsWith('/engine/cf.py')).toBe(true)
  expect(runs[0].argv.slice(2)).toEqual(['--stdin-json'])
  expect(runs[0].command).toBe('dns-get')
  expect(runs[0].args).toEqual({ zone: 'example.com', record: 'www; rm -rf /' })
  expect(runs[0].account).toBe('alpha')
})

test('a write goes to cf-write.py, the same request on stdin', async ($, on) => {
  const runs: any[] = []
  await stubMod(on, runs)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'dns-create', { zone: 'example.com', type: 'A', name: 'x', content: '203.0.113.5' })

  expect(runs[0].argv[1].endsWith('/engine/cf-write.py')).toBe(true)
  expect(runs[0].argv.slice(2)).toEqual(['--stdin-json'])
  expect(runs[0].command).toBe('dns-create')
  expect(runs[0].account).toBeUndefined()
})

test('a command missing from READS is sent as a write', async ($, on) => {
  const runs: any[] = []
  await stubMod(on, runs)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  for (const command of COMMANDS) await call($, command)
  const toWrite = runs.filter((r) => r.argv[1].endsWith('/cf-write.py')).map((r) => r.command)
  expect(toWrite).toEqual(COMMANDS.filter((c) => !READS.has(c)))
})

test('a non-zero engine exit returns isError with stderr', async ($, on) => {
  const runs: any[] = []
  await stubMod(on, runs, { exitCode: 4, stdout: '', stderr: 'cf: no account gamma; known: alpha' })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out = await call($, 'zones', undefined, 'gamma')
  expect(out.isError).toBe(true)
  expect(out.result).toBe('cf: no account gamma; known: alpha')
})

test('a rejected process.run surfaces as isError, not a skipped hook', async ($, on) => {
  await stubMod(on, [], { deny: 'python3: not found' })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out = await call($, 'auth-check')
  expect(out.isError).toBe(true)
})

test('a truncated engine output says so', async ($, on) => {
  await stubMod(on, [], { exitCode: 0, stdout: 'zone file', stderr: '', isStdoutTruncated: true })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out = await call($, 'dns-export', { zone: 'example.com' })
  expect(out).toEqual({ result: 'zone file\n[output cut at 4 MiB]' })
})

test('an empty output says so', async ($, on) => {
  await stubMod(on, [], { exitCode: 0, stdout: '', stderr: '' })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out = await call($, 'dns-list', { zone: 'example.com' })
  expect(out).toEqual({ result: '(no output)' })
})

test('every read is a command, and no write that is never granted is a read', () => {
  for (const name of READS) expect(COMMANDS).toContain(name)
  for (const name of NEVER_GRANTED) expect(READS.has(name)).toBe(false)
  expect([...NEVER_GRANTED].sort()).toEqual(
    ['dns-delete', 'purge-all', 'restore', 'under-attack', 'unpublish', 'worker-delete'],
  )
})

// ---- permission ----

test('a deny verdict refuses the call without running the engine', async ($, on) => {
  const runs: any[] = []
  await stubMod(on, runs, undefined, { decision: 'deny', reason: 'denied by mcp__cloudflare__cf', rule: 'mcp__cloudflare__cf' })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out: any = await call($, 'zones')
  expect(JSON.stringify(out)).toContain('denied by mcp__cloudflare__cf')
  expect(out.result).toBeUndefined()
  expect(runs.length).toBe(0)
})

test('a deny rule on a write refuses it without a dialog or a run', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'deny', reason: 'denied by mcp__cloudflare__cf(dns-delete)', rule: 'mcp__cloudflare__cf' })
  stubAsk(on, asked, 'Allow')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out: any = await call($, 'dns-delete', { zone: 'example.com', record: 'www' })
  expect(JSON.stringify(out)).toContain('denied by mcp__cloudflare__cf(dns-delete)')
  expect(out.result).toBeUndefined()
  expect(asked.length).toBe(0)
  expect(runs.length).toBe(0)
})

test('an allow verdict runs a write without a dialog', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'allow', rule: 'mcp__cloudflare__cf' })
  stubAsk(on, asked, 'Deny')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out = await call($, 'dns-delete', { zone: 'example.com', record: 'www' })
  expect(out).toEqual({ result: 'ok' })
  expect(asked.length).toBe(0)
})

test('an ask with no rule lets a read through without a dialog', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  stubAsk(on, asked, 'Deny')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out = await call($, 'dns-list', { zone: 'example.com' })
  expect(out).toEqual({ result: 'ok' })
  expect(asked.length).toBe(0)
  expect(runs.length).toBe(1)
})

test('an ask puts a write to the person, and Allow runs it', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  stubAsk(on, asked, 'Allow')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out = await call($, 'dns-create', { zone: 'example.com', type: 'A', name: 'x', content: '203.0.113.5' }, 'alpha')
  expect(out).toEqual({ result: 'ok' })
  expect(asked[0]).toContain('dns-create')
  expect(asked[0]).toContain('account alpha')
  expect(asked[0]).toContain('203.0.113.5')
  expect(runs.length).toBe(1)
})

test('the question names the command, the zone and the record before any cut', async ($, on) => {
  const asked: string[] = []
  await stubMod(on, [], undefined, { decision: 'ask' })
  stubAsk(on, asked, 'Allow')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'dns-update', { comment: 'x'.repeat(500), zone: 'example.com', record: 'www' }, 'alpha')
  await call($, 'dns-create', { content: 'y'.repeat(500), zone: 'example.net', name: 'api' })
  expect(asked[0]).toContain('cf dns-update')
  expect(asked[0]).toContain('zone example.com')
  expect(asked[0]).toContain('record www')
  expect(asked[0]).toContain('…')
  expect(asked[0].length).toBeLessThan(500)
  expect(asked[1]).toContain('zone example.net')
  expect(asked[1]).toContain('name api')
})

test('an ask on a write refused by the person runs nothing', async ($, on) => {
  const runs: any[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  stubAsk(on, [], 'Deny')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out: any = await call($, 'dns-update', { zone: 'example.com', record: 'www', content: '203.0.113.6' })
  expect(JSON.stringify(out)).toContain('the user refused cf dns-update')
  expect(runs.length).toBe(0)
})

test('an ask from an explicit rule asks even for a read', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask', rule: 'mcp__cloudflare__cf' })
  stubAsk(on, asked, 'Allow')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'zones')
  expect(asked.length).toBe(1)
  expect(runs.length).toBe(1)
})

test('a write that needs permission is refused when nobody can be asked', async ($, on) => {
  const runs: any[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  stubAsk(on, [], undefined)
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })

  for (const command of ['dns-create', ...NEVER_GRANTED]) {
    const out: any = await call($, command)
    expect(JSON.stringify(out)).toContain('cf ' + command + ' needs permission and nobody could be asked')
  }
  expect(runs.length).toBe(0)
})

test('a Caddy write is asked on the local Caddy, its host shown before any truncation', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  stubAsk(on, asked, 'Allow for this session')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'caddy-site-set', { 'body-file': '/work/' + 'b'.repeat(300) + '.caddy', host: 'app.example.com' }, 'alpha')
  await call($, 'caddy-site-set', { host: 'api.example.com', 'body-file': '/work/api.caddy' })
  expect(asked.length).toBe(1)
  expect(asked[0]).toContain('every later cf caddy-site-set on the local Caddy until')
  expect(asked[0]).toContain('Run cf caddy-site-set on the local Caddy for app.example.com with ')
  expect(asked[0]).not.toContain('account')
  expect(runs.length).toBe(2)
  expect(runs[0].argv[1].endsWith('/engine/cf-write.py')).toBe(true)
})

test('caddy-site-remove and caddy-reload are writes, the Caddy reads are not asked', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  stubAsk(on, asked, 'Allow')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  for (const command of ['caddy-sites', 'caddy-site', 'caddy-status', 'caddy-docs']) await call($, command)
  expect(asked.length).toBe(0)
  expect(runs.length).toBe(4)
  expect(runs.every((r) => r.argv[1].endsWith('/engine/cf.py'))).toBe(true)
  await call($, 'caddy-site-remove', { host: 'old.example.com' })
  await call($, 'caddy-reload')
  expect(asked.map((q) => q.split(' with ')[0].split('. ').pop())).toEqual([
    'Run cf caddy-site-remove on the local Caddy for old.example.com',
    'Run cf caddy-reload on the local Caddy',
  ])
  expect(runs.length).toBe(6)
})

test('publish is one ask for its whole cycle, on the account and the local Caddy, its host shown first', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  stubAsk(on, asked, 'Allow')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out = await call($, 'publish', { 'extra-file': '/work/' + 'e'.repeat(300) + '.caddy', host: 'new.example.com', to: '8080' }, 'alpha')
  expect(out).toEqual({ result: 'ok' })
  expect(asked.length).toBe(1)
  expect(asked[0]).toContain('Run cf publish on account alpha and the local Caddy for new.example.com with ')
  expect(runs.length).toBe(1)
  expect(runs[0].argv[1].endsWith('/engine/cf-write.py')).toBe(true)
  expect(runs[0].command).toBe('publish')
})

// The extra file the publish ask reads: its bytes, never shown as text.
const EXTRA = 'header X-Long ' + 'v'.repeat(600) + '\n'

test('the publish ask names host, target, address and proxy first, then the overwrite, then the extra file by size and digest', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  const read: any[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  on('fs.read', (_$: any, e: any) => {
    read.push(e)
    return { value: { base64: btoa(EXTRA) } }
  })
  stubAsk(on, asked, 'Allow')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'publish', { 'extra-file': '/work/extra.caddy', host: 'new.example.com', to: '8080', 'no-proxy': true, ip: '203.0.113.5' }, 'alpha')
  await call($, 'publish', { host: 'two.example.com', to: 'http://127.0.0.1:9000' }, 'alpha')
  expect(asked[0]).toContain(
    'Run cf publish on account alpha and the local Caddy for new.example.com with --to 8080, --ip 203.0.113.5, '
    + 'DNS only (--no-proxy). It may overwrite an existing DNS record of new.example.com and its existing site block. '
    + '--extra-file /work/extra.caddy: 615 bytes, sha256 d90cda62039d?',
  )
  expect(asked[0]).not.toContain('vvvv')
  expect(read).toEqual([{ path: '/work/extra.caddy', as: 'bytes' }])
  expect(asked[1]).toContain(
    'for two.example.com with --to http://127.0.0.1:9000, --ip the default_target of the config, proxied. It may overwrite',
  )
  expect(runs.length).toBe(2)
})

test('the publish ask keeps host and target whole past a long extra file, and a Deny runs nothing', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  on('fs.read', () => ({ value: { base64: btoa(EXTRA.repeat(50)) } }))
  stubAsk(on, asked, 'Deny')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out: any = await call($, 'publish', { 'extra-file': '/work/' + 'e'.repeat(300) + '.caddy', host: 'new.example.com', to: '8080' }, 'alpha')
  expect(asked[0]).toContain('for new.example.com with --to 8080, --ip the default_target of the config, proxied.')
  expect(asked[0]).toContain(': 30750 bytes, sha256 ')
  expect(asked[0]).not.toContain('header X-Long')
  expect(JSON.stringify(out)).toContain('the user refused cf publish')
  expect(runs.length).toBe(0)
})

test('the publish ask says when the extra file cannot be read', async ($, on) => {
  const asked: string[] = []
  await stubMod(on, [], undefined, { decision: 'ask' })
  on('fs.read', () => ({ deny: 'ENOENT' }))
  stubAsk(on, asked, 'Deny')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'publish', { 'extra-file': '/work/absent.caddy', host: 'new.example.com', to: '8080' })
  expect(asked[0]).toContain('--extra-file /work/absent.caddy: cannot be read, publish will refuse it?')
})

test('the unpublish ask says every A, AAAA and CNAME record of the host goes', async ($, on) => {
  const asked: string[] = []
  await stubMod(on, [], undefined, { decision: 'ask' })
  stubAsk(on, asked, 'Allow')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'unpublish', { host: 'old.example.com' })
  expect(asked[0]).toContain(
    'for old.example.com with {"host":"old.example.com"}. It removes the site block of old.example.com and deletes every A, AAAA and CNAME record of old.example.com?',
  )
})

test('a publish grant covers later publishes on that account only', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  let first = true
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const question = e.questions[0].question
    asked.push(question)
    const answer = first ? 'Allow for this session' : 'Deny'
    first = false
    return { result: { questions: e.questions, answers: { [question]: answer } } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'publish', { host: 'a.example.com', to: '8080' }, 'alpha')
  await call($, 'publish', { host: 'b.example.com', to: '8081' }, 'alpha')
  await call($, 'publish', { host: 'c.example.com', to: '8082' }, 'beta')
  expect(asked.length).toBe(2)
  expect(asked[0]).toContain('every later cf publish on account alpha and the local Caddy until')
  expect(runs.length).toBe(2)
})

test('a publish grant does not cover unpublish', async ($, on) => {
  const runs: any[] = []
  const options: string[][] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  let first = true
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const q = e.questions[0]
    options.push(q.options.map((o: any) => o.label))
    const answer = first ? 'Allow for this session' : 'Deny'
    first = false
    return { result: { questions: e.questions, answers: { [q.question]: answer } } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'publish', { host: 'a.example.com', to: '8080' }, 'alpha')
  const out: any = await call($, 'unpublish', { host: 'a.example.com' }, 'alpha')
  expect(options).toEqual([['Allow', 'Allow for this session', 'Deny'], ['Allow', 'Deny']])
  expect(JSON.stringify(out)).toContain('the user refused cf unpublish')
  expect(runs.map((r) => r.command)).toEqual(['publish'])
})

test('unpublish is asked every time, Allow and Deny only, its host shown', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  const options: string[][] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const q = e.questions[0]
    asked.push(q.question)
    options.push(q.options.map((o: any) => o.label))
    return { result: { questions: e.questions, answers: { [q.question]: 'Allow' } } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'unpublish', { host: 'old.example.com' })
  await call($, 'unpublish', { host: 'old.example.com' })
  expect(options).toEqual([['Allow', 'Deny'], ['Allow', 'Deny']])
  expect(asked[0]).toContain('Run cf unpublish on the default account and the local Caddy for old.example.com with ')
  expect(runs.length).toBe(2)
})

test('worker-domains is a read, never asked; worker-domain-delete a write, asked', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  stubAsk(on, asked, 'Allow')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'worker-domains', { zone: 'example.com' })
  expect(asked.length).toBe(0)
  await call($, 'worker-domain-delete', { hostname: 'edge.example.com' }, 'alpha')
  expect(asked.length).toBe(1)
  expect(asked[0]).toContain('Run cf worker-domain-delete on account alpha with {"hostname":"edge.example.com"}')
  expect(runs.map((r) => r.argv[1].split('/').pop())).toEqual(['cf.py', 'cf-write.py'])
})

test('check and inventory are reads, never asked', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  stubAsk(on, asked, 'Deny')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'check', { host: 'app.example.com' })
  await call($, 'inventory', { zone: 'example.com' })
  expect(asked.length).toBe(0)
  expect(runs.map((r) => r.argv[1].split('/').pop())).toEqual(['cf.py', 'cf.py'])
})

// ---- « Allow for this session » ----

test('« Allow for this session » runs the call and every later one of that command on that account', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  stubAsk(on, asked, 'Allow for this session')
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'dns-create', { zone: 'example.com', name: 'a' }, 'alpha')
  await call($, 'dns-create', { zone: 'example.com', name: 'b' }, 'Alpha')
  expect(asked.length).toBe(1)
  expect(asked[0]).toContain('every later cf dns-create on account alpha')
  expect(runs.length).toBe(2)
})

test('a grant covers neither another command nor another account', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  let first = true
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const question = e.questions[0].question
    asked.push(question)
    const answer = first ? 'Allow for this session' : 'Deny'
    first = false
    return { result: { questions: e.questions, answers: { [question]: answer } } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'dns-create', { zone: 'example.com' }, 'alpha')
  await call($, 'dns-update', { zone: 'example.com' }, 'alpha')
  await call($, 'dns-create', { zone: 'example.com' }, 'beta')
  await call($, 'dns-create', { zone: 'example.com' })
  expect(asked.length).toBe(4)
  expect(runs.length).toBe(1)
})

test('a grant on one zone never covers another', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const question = e.questions[0].question
    asked.push(question)
    const answer = asked.length === 1 ? 'Allow for this session' : 'Deny'
    return { result: { questions: e.questions, answers: { [question]: answer } } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'dns-create', { zone: 'example.com', name: 'a' }, 'alpha')
  await call($, 'dns-create', { zone: 'example.com', name: 'b' }, 'alpha')
  await call($, 'dns-create', { zone: 'example.net', name: 'a' }, 'alpha')
  expect(asked.length).toBe(2)
  expect(asked[0]).toContain('zone example.com')
  expect(runs.length).toBe(2)
})

test('the writes that are never granted are offered Allow and Deny only', async ($, on) => {
  const runs: any[] = []
  const options: string[][] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const q = e.questions[0]
    options.push(q.options.map((o: any) => o.label))
    return { result: { questions: e.questions, answers: { [q.question]: 'Allow' } } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'dns-delete', { zone: 'example.com', record: 'www' })
  await call($, 'restore', { path: '/b/alpha/example.com/x-dns.json' })
  await call($, 'dns-create', { zone: 'example.com' })
  expect(options).toEqual([['Allow', 'Deny'], ['Allow', 'Deny'], ['Allow', 'Allow for this session', 'Deny']])
  expect(runs.length).toBe(3)
})

test('an explicit ask rule is never answered by a grant', async ($, on) => {
  const options: string[][] = []
  await stubMod(on, [], undefined, { decision: 'ask', rule: 'mcp__cloudflare__cf' })
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const q = e.questions[0]
    options.push(q.options.map((o: any) => o.label))
    return { result: { questions: e.questions, answers: { [q.question]: 'Allow' } } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'dns-create', { zone: 'example.com' })
  expect(options).toEqual([['Allow', 'Deny']])
})

test('a grant is not given by plain Allow, nor by text typed under Other', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  await stubMod(on, runs, undefined, { decision: 'ask' })
  const answers = ['Allow', 'yes, allow it for the whole session', 'Deny']
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const question = e.questions[0].question
    asked.push(question)
    return { result: { questions: e.questions, answers: { [question]: answers[asked.length - 1] } } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  for (const name of ['a', 'b', 'c']) await call($, 'dns-create', { zone: 'example.com', name })
  expect(asked.length).toBe(3)
  expect(runs.length).toBe(1)
})

test('a grant holds for its session only, and never past a deny', async ($, on) => {
  const runs: any[] = []
  const asked: string[] = []
  let session = 'session-1'
  let verdict: any = { decision: 'ask' }
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: session }))
  on('tool.check', (_$: any, e: any) => (e.tool === 'AskUserQuestion' ? { decision: 'allow' } : verdict))
  on('tool.register', () => ({ value: undefined }))
  on('process.run', (_$: any, e: any) => {
    runs.push(JSON.parse(e.init?.stdin ?? '{}'))
    return { value: { exitCode: 0, stdout: 'ok', stderr: '' } }
  })
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const question = e.questions[0].question
    asked.push(question)
    return { result: { questions: e.questions, answers: { [question]: asked.length === 1 ? 'Allow for this session' : 'Deny' } } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'dns-create', { zone: 'example.com' })
  await call($, 'dns-create', { zone: 'example.com' })
  verdict = { decision: 'deny', reason: 'now denied', rule: 'mcp__cloudflare__cf' }
  const denied: any = await call($, 'dns-create', { zone: 'example.com' })
  expect(JSON.stringify(denied)).toContain('now denied')
  verdict = { decision: 'ask' }
  session = 'session-2'
  await call($, 'dns-create', { zone: 'example.com' })
  expect(asked.length).toBe(2)
  expect(runs.length).toBe(2)
})

test('without a session id no grant is offered', async ($, on) => {
  const options: string[][] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ deny: 'no session' }))
  on('tool.check', (_$: any, e: any) => (e.tool === 'AskUserQuestion' ? { decision: 'allow' } : { decision: 'ask' }))
  on('tool.register', () => ({ value: undefined }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: 'ok', stderr: '' } }))
  on('tool.call', { tool: 'AskUserQuestion' }, (_$: any, e: any) => {
    const q = e.questions[0]
    options.push(q.options.map((o: any) => o.label))
    return { result: { questions: e.questions, answers: { [q.question]: 'Allow' } } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  await call($, 'dns-create', { zone: 'example.com' })
  expect(options).toEqual([['Allow', 'Deny']])
})

// ---- /cloudflare:install and /cloudflare:doctor ----

test('/cloudflare:doctor runs install.sh and names its exit code, with no model turn', async ($, on) => {
  const runs: any[] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('tool.register', () => ({ value: undefined }))
  on('process.run', (_$: any, e: any) => {
    runs.push(e.argv)
    return { value: { exitCode: 12, stdout: '', stderr: 'cloudflare: no account found\n' } }
  })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  for (const command of ['cloudflare:doctor', 'cloudflare:install']) {
    const out: any = await $.command.run({ command, args: '' })
    expect(out.text).toBe(
      'cloudflare: no account found\n\nExit code 12: no Cloudflare account: set <NAME>_CLOUDFLARE_API_TOKEN, then run /cloudflare:doctor.',
    )
  }
  expect(runs[0][0]).toBe('bash')
  expect(runs[0][1].endsWith('/install.sh')).toBe(true)
  expect(runs[0].slice(2)).toEqual(['--check'])
  expect(runs[1].slice(2)).toEqual([])
})

test('/cloudflare:doctor names exit 15, the local Caddy not ready', async ($, on) => {
  on('session.start', () => ({ cwd: '/work' }))
  on('tool.register', () => ({ value: undefined }))
  on('process.run', () => ({ value: { exitCode: 15, stdout: 'cloudflare: account alpha: active\n', stderr: 'cloudflare: caddy: error: no envfile\n' } }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out: any = await $.command.run({ command: 'cloudflare:doctor', args: '' })
  expect(out.text).toBe(
    'cloudflare: account alpha: active\ncloudflare: caddy: error: no envfile\n\n'
    + 'Exit code 15: the local Caddy is not ready: fix what is named, then run /cloudflare:doctor.',
  )
})

test('/cloudflare:doctor falls back to the markdown command when the script cannot run', async ($, on) => {
  on('session.start', () => ({ cwd: '/work' }))
  on('tool.register', () => ({ value: undefined }))
  on('process.run', () => ({ deny: 'no process' }))
  on('command.run', { command: 'cloudflare:doctor' }, () => ({ text: 'markdown ran' }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })

  const out: any = await $.command.run({ command: 'cloudflare:doctor', args: '' })
  expect(out.text).toBe('markdown ran')
})
