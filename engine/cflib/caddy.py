"""The local Caddy: its site blocks, its state, the embedded digests of its
documentation, and the cycle every change goes through.

A change (caddy-site-set, caddy-site-remove, caddy-reload) holds a lock for
its whole cycle, one change at a time, and runs the same steps: copy the
Caddyfile beside itself; probe every site; edit the one block; caddy
validate, and on failure put the copy back; caddy reload; check the admin API
answers; probe every site again. A site that answered and no longer does, a
failed reload or a dead admin API put the copy back, validate and reload it,
and probe again: exit 6, or 7 when Caddy is still not alive. Any other
exception once the file is written, SIGTERM included, puts the copy back
before it goes on; a copy that cannot be put back is exit 4. The cycle has
one deadline: each step takes its time from what is left, a step past it is a
failure the rollback takes back, in the time kept for it. The Caddyfile is
the only source of truth: nothing is written through the admin API, and Caddy
is never stopped or restarted.
"""

import os
import re
import signal

from . import caddyctl, caddyfile, errors, fmt

DOCS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "docs", "caddy")
_TOPIC = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# In the config's backup_dir: the lock one change at a time holds.
LOCK = "caddy.lock"


def _status(code):
    return "down" if code is caddyctl.DOWN else str(code)


# ---- reads ----

def caddy_sites(args, ctx):
    settings = caddyctl.Settings(ctx.config)
    text = settings.read()
    blocks, _ = caddyfile.parse(text)
    if args.json:
        return fmt.as_json([{"kind": b.kind, "addresses": b.addresses, "line": b.line, "end_line": b.end_line,
                             "reverse_proxy": caddyfile.upstreams(text, b)} for b in blocks])
    return fmt.table([{"address": ",".join(b.addresses), "line": b.line,
                       "reverse_proxy": ",".join(caddyfile.upstreams(text, b))}
                      for b in blocks if b.kind == "site"], ["address", "line", "reverse_proxy"])


def caddy_site(args, ctx):
    host = caddyfile.host_name(args.host, wildcard=True)
    settings = caddyctl.Settings(ctx.config)
    text = settings.read()
    blocks, _ = caddyfile.parse(text)
    found = caddyfile.serving(blocks, host)
    if not found:
        raise errors.UsageError("no site block for %s in %s" % (host, settings.caddyfile))
    if args.json:
        return fmt.as_json([{"address": ", ".join(b.addresses), "line": b.line, "end_line": b.end_line,
                             "text": text[b.start:b.end]} for b in found])
    return "\n\n".join(text[b.start:b.end] for b in found)


def caddy_status(args, ctx):
    settings = caddyctl.Settings(ctx.config)
    rows, warnings = [], []

    def run(call, *args):
        try:
            return call(*args)
        except caddyctl.SudoRefused as exc:
            return False, exc.message

    try:
        variables, unreadable = settings.variables(), None
    except errors.ConfigError as exc:
        variables, unreadable = None, exc
    # Every caddy run gets the envfile's variables, version included.
    ok, version = run(settings.call, ["version"], variables or {})
    rows.append({"check": "binary", "state": "ok" if ok else "failed",
                 "detail": "%s: %s" % (settings.binary, version.splitlines()[0] if version else "-")})
    alive = settings.alive()
    rows.append({"check": "admin", "state": "alive" if alive else "down", "detail": settings.admin})
    if not alive:
        warnings.append("caddy's admin API does not answer at %s: caddy is stopped, or listens elsewhere"
                        % settings.admin)
    try:
        blocks, _ = caddyfile.parse(settings.read())
        sites = sum(1 for b in blocks if b.kind == "site")
        rows.append({"check": "caddyfile", "state": "ok", "detail": "%s: %d sites" % (settings.caddyfile, sites)})
    except errors.CfError as exc:
        rows.append({"check": "caddyfile", "state": "unreadable", "detail": exc.message})
    if unreadable:
        rows.append({"check": "validate", "state": "skipped", "detail": "the envfile cannot be read"})
        rows.append({"check": "envfile", "state": "unreadable", "detail": unreadable.message})
    if variables is not None:
        ok, line = run(settings.validate, variables)
        rows.append({"check": "validate", "state": "ok" if ok else "failed", "detail": None if ok else line})
        if settings.envfile:
            try:
                mode = os.stat(settings.envfile).st_mode & 0o777
            except OSError as exc:
                rows.append({"check": "envfile", "state": "unreadable",
                             "detail": "cannot read the envfile %s: %s" % (settings.envfile, exc.strerror)})
            else:
                rows.append({"check": "envfile", "state": "ok",
                             "detail": "%s: %d variables" % (settings.envfile, len(variables))})
                if mode & 0o077:
                    warnings.append("%s is readable by others (mode %o): chmod 600 it" % (settings.envfile, mode))
        else:
            rows.append({"check": "envfile", "state": "-", "detail": "none in the config"})
    state, detail, warning = caddyctl.service(settings)
    rows.append({"check": "service", "state": state, "detail": detail})
    if warning:
        warnings.append(warning)
    if args.json:
        return fmt.as_json({"checks": rows, "warnings": warnings})
    out = fmt.table(rows, ["check", "state", "detail"])
    return "\n".join([out] + ["warning: " + w for w in warnings])


def topics():
    try:
        return sorted(n[:-len(".md")] for n in os.listdir(DOCS) if n.endswith(".md") and n != "index.md")
    except OSError:
        return []


def caddy_docs(args, ctx):
    topic = args.topic or "index"
    if not _TOPIC.match(topic) or (topic != "index" and topic not in topics()):
        raise errors.UsageError("no Caddy digest %s; topics: %s" % (topic, ", ".join(topics())))
    try:
        with open(os.path.join(DOCS, topic + ".md"), encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise errors.ConfigError("cannot read the digest %s: %s" % (topic, exc.strerror))
    if args.json:
        return fmt.as_json({"topic": topic, "text": text})
    return text.rstrip("\n")


# ---- the cycle ----

def _put_back(settings, original, copy, reason, reloaded):
    """The Caddyfile as it was before the edit, or a ConfigError naming the
    copy: caddy did not fail, the file did, and caddy runs what it ran.
    Without a copy nothing was written, and there is nothing to put back."""
    if copy is None:
        return
    try:
        settings.write(original)
    except OSError as exc:
        try:
            if settings.read() == original:
                return
        except errors.CfError:
            pass
        running = "caddy runs the changed Caddyfile" if reloaded else \
            "caddy was not reloaded and still runs the config it had"
        raise errors.ConfigError("%s, and the Caddyfile could not be restored (%s): %s; put %s back by hand "
                                 "before anything reloads it; backup: %s"
                                 % (reason, exc.strerror, running, copy, copy))


def _backup(copy):
    return "; backup: %s" % copy if copy else ""


def _rollback(settings, variables, original, copy, hosts, broken, reason):
    """Put the copy back (a reload with no edit has none), validate and
    reload it, probe again; raise RolledBack, or NotAlive when Caddy still
    does not answer."""
    settings.deadline.rolling_back = True
    reason = _late(settings, reason)
    _put_back(settings, original, copy, reason, True)
    ok, line = settings.validate(variables)
    if copy:
        done = "the Caddyfile is restored"
        if not ok:
            done += ", but it does not validate (%s)" % line
        else:
            ok, line = settings.reload(variables)
            done += " and reloaded" if ok else ", but its reload failed (%s)" % line
    else:
        done = "the Caddyfile was not changed"
        if not ok:
            done += ", and it does not validate (%s)" % line
        else:
            ok, line = settings.reload(variables)
            done += " and is reloaded again" if ok else ", and its reload failed again (%s)" % line
    alive = settings.alive()
    again = caddyctl.probe(hosts, settings)
    still = [h for h in broken if again.get(h) is caddyctl.DOWN]
    if still:
        done += ", still down: " + ", ".join(still)
    if not alive:
        raise errors.NotAlive("%s; %s, but caddy is not alive after the rollback either: look at it now%s"
                              % (reason, done, _backup(copy)))
    raise errors.RolledBack("%s; %s%s" % (reason, done, _backup(copy)))


def _late(settings, reason):
    """The reason, saying so when the cycle's steps have used up their time."""
    if settings.deadline.passed():
        return "%s, past the cycle's budget of %g seconds" % (reason, settings.deadline.budget)
    return reason


def _terminated(signum, frame):
    # SIGTERM as an exception, so the edited Caddyfile is put back on the way out.
    raise SystemExit(128 + signum)


def cycle(ctx, edit, host=None, removing=False):
    """Run one change through every step. edit(text) gives the new text;
    the identity for a reload, which writes nothing. Lines: one per host
    whose status changed (host<TAB>before→after), then backup: <copy>;
    "reloaded" when a reload has neither."""
    previous = signal.signal(signal.SIGTERM, _terminated)
    try:
        return _cycle(ctx, edit, host, removing)
    finally:
        signal.signal(signal.SIGTERM, previous)


def _cycle(ctx, edit, host, removing):
    settings = caddyctl.Settings(ctx.config)
    settings.deadline = caddyctl.Deadline()
    with caddyctl.locked(os.path.join(ctx.config.backup_dir, LOCK), settings.deadline):
        return _locked_cycle(settings, edit, host, removing)


def _locked_cycle(settings, edit, host, removing):
    variables = settings.variables()
    original = settings.read()
    blocks, _ = caddyfile.parse(original)
    new = edit(original)
    if host and new == original:
        return "unchanged\t%s" % host
    # A reload of the file as it is writes nothing: no copy, no rewrite.
    edited = new != original
    if edited and not settings.writable():
        raise errors.ConfigError("cannot write %s: permission denied; nothing was changed" % settings.caddyfile)
    new_blocks, _ = caddyfile.parse(new)
    hosts = sorted(set(caddyfile.hosts(blocks)) | set(caddyfile.hosts(new_blocks)))
    if not settings.alive():
        raise errors.Refused("caddy's admin API does not answer at %s: a reload cannot be checked, "
                             "nor taken back; nothing was changed" % settings.admin)
    copy = settings.copy(original) if edited else None
    before = caddyctl.probe(hosts, settings)
    if settings.deadline.passed():
        raise errors.Refused("the sites took the cycle's budget of %g seconds to probe; nothing was changed%s"
                             % (settings.deadline.budget, _backup(copy)))
    if edited:
        try:
            settings.write(new)
        except OSError as exc:
            reason = "cannot write %s: %s" % (settings.caddyfile, exc.strerror)
            _put_back(settings, original, copy, reason, False)
            raise errors.ConfigError("%s; nothing was changed%s" % (reason, _backup(copy)))
    reloaded = False
    try:
        ok, line = settings.validate(variables)
        if not ok:
            reason = _late(settings, "caddy validate failed: %s" % line)
            _put_back(settings, original, copy, reason, False)
            done = "the Caddyfile is restored" if copy else "the Caddyfile was not changed"
            raise errors.RolledBack("%s; %s%s" % (reason, done, _backup(copy)))
        reloaded = True
        ok, line = settings.reload(variables)
        if not ok:
            _rollback(settings, variables, original, copy, hosts, [], "caddy reload failed: %s" % line)
        if not settings.alive():
            _rollback(settings, variables, original, copy, hosts, [],
                      "caddy's admin API did not answer after the reload")
        after = caddyctl.probe(hosts, settings)
        broken = [h for h in hosts if before[h] is not caddyctl.DOWN and after[h] is caddyctl.DOWN
                  and not (removing and h == host)]
        if broken:
            _rollback(settings, variables, original, copy, hosts, broken,
                      "%s went down after the reload" % ", ".join(broken))
    except caddyctl.SudoRefused as exc:
        # sudo ran nothing: caddy runs what it ran, and the file goes back as it was.
        _put_back(settings, original, copy, exc.message, False)
        done = "the Caddyfile is restored" if copy else "the Caddyfile was not changed"
        raise errors.ConfigError("%s; %s%s" % (exc.message, done, _backup(copy)))
    except errors.CfError:
        # Each failure above has dealt with the file already.
        raise
    except BaseException:
        # Anything else, an interrupt or SIGTERM included: the file as it was before going on.
        _put_back(settings, original, copy, "interrupted", reloaded)
        raise
    lines = ["%s\t%s→%s" % (h, _status(before[h]), _status(after[h])) for h in hosts if before[h] != after[h]]
    lines += ["backup: " + copy] if copy else []
    return "\n".join(lines) or "reloaded"


def _body(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return caddyfile.body(fh.read())
    except (OSError, UnicodeDecodeError) as exc:
        raise errors.UsageError("cannot read %s: %s" % (path, getattr(exc, "strerror", None) or exc))


def caddy_site_set(args, ctx):
    host = caddyfile.host_name(args.host)
    lines = _body(args.body_file)

    return cycle(ctx, lambda text: caddyfile.set_site(text, host, lines), host)


def caddy_site_remove(args, ctx):
    host = caddyfile.host_name(args.host)

    return cycle(ctx, lambda text: caddyfile.remove_site(text, host), host, removing=True)


def caddy_reload(args, ctx):
    return cycle(ctx, lambda text: text)


def register(subparsers):
    parser = subparsers.add_parser("caddy-sites", help="the site blocks of the Caddyfile")
    parser.set_defaults(handler=caddy_sites, read=True, account_free=True)

    parser = subparsers.add_parser("caddy-site", help="the block that serves a host, as written")
    parser.add_argument("host")
    parser.set_defaults(handler=caddy_site, read=True, account_free=True)

    parser = subparsers.add_parser("caddy-status", help="binary, admin API, Caddyfile, validate, envfile, service")
    parser.set_defaults(handler=caddy_status, read=True, account_free=True)

    parser = subparsers.add_parser("caddy-docs", help="the Caddy digests: the index, or one topic")
    parser.add_argument("topic", nargs="?")
    parser.set_defaults(handler=caddy_docs, read=True, account_free=True)

    parser = subparsers.add_parser("caddy-site-set", help="replace or add the block of a host, then validate and reload")
    parser.add_argument("host")
    parser.add_argument("--body-file", required=True, help="the block's directives, without the address and braces")
    parser.set_defaults(handler=caddy_site_set, account_free=True)

    parser = subparsers.add_parser("caddy-site-remove", help="remove the block of a host, then validate and reload")
    parser.add_argument("host")
    parser.set_defaults(handler=caddy_site_remove, account_free=True)

    parser = subparsers.add_parser("caddy-reload", help="validate and reload the Caddyfile as it is")
    parser.set_defaults(handler=caddy_reload, account_free=True)
