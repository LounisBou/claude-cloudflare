"""The commands that span Cloudflare and the local Caddy: publish a service
under a host, unpublish it, and the inventory of a zone against the
Caddyfile.

publish checks everything it can before its first write: the SSL guard of a
proxied site, the record it would replace, the block it would edit, a Caddy
that answers. Then it writes the A record (after its backup) and the site
block (through the Caddy cycle). A cycle that fails after the record was
written puts the record back from that backup, so that a failure midway
leaves nothing half done; unpublish does the same the other way round. Every
backup taken is named in the output, or in the error line.
"""

import ipaddress
import re
import sys

from . import backup, caddy, caddyctl, caddyfile, check, dns, errors, fmt, guard, zones

# The SSL modes under which the edge reaches the origin over HTTPS.
SAFE_SSL = ("full", "strict")
# The records that make a name resolve, which publish and unpublish own.
SERVING = ("A", "AAAA", "CNAME")
_UPSTREAM = re.compile(r"^(?:(?:https?|h2c)://)?(?:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\])"
                       r"(?::\d{1,5})?$")
# The settings inventory prints, in order.
_SSL_SETTINGS = ("ssl", "universal_ssl", "min_tls_version", "tls_1_3", "always_use_https")
COLUMNS = ["host", "record", "proxied", "block", "https", "issuer", "expires"]
# What an --extra-file may not hold: Caddy's placeholders of the environment and of files.
_READING = ("{$", "{env.", "{file.")
# How the Caddy cycle words a validate failure, and what follows Caddy's line.
_VALIDATE = "caddy validate failed: "
_RESTORED = "; the Caddyfile is restored"


def _records_path(zone):
    return "/zones/%s/dns_records" % zone["id"]


def zone_of(ctx, host):
    """The zone of the account that holds the host: the longest suffix of it
    that is one of the account's zones."""
    labels = host.split(".")
    for k in range(len(labels) - 1):
        found = ctx.api.get("/zones", params={"name": ".".join(labels[k:])})
        if found:
            return found[0]
    raise errors.UsageError("no zone of account %s holds %s" % (ctx.account.name, host))


def upstream(raw):
    """What reverse_proxy is given: a port is one on this machine."""
    text = raw.strip()
    if text.isdigit():
        if not 0 < int(text) < 65536:
            raise errors.UsageError("--to takes a port or an upstream (host:port, http://host:port): %s" % raw)
        return "127.0.0.1:%d" % int(text)
    if not _UPSTREAM.match(text):
        raise errors.UsageError("--to takes a port or an upstream (host:port, http://host:port): %s" % raw)
    return text


def _address(raw, what):
    try:
        return str(ipaddress.IPv4Address(raw.strip()))
    except ValueError:
        raise errors.UsageError("%s takes an IPv4 address: %s" % (what, raw))


def target_ip(args, ctx):
    if args.ip:
        return _address(args.ip, "--ip")
    if not ctx.config.default_target:
        raise errors.ConfigError("no --ip, and no default_target in %s" % ctx.config.path)
    try:
        return str(ipaddress.IPv4Address(ctx.config.default_target))
    except ValueError:
        raise errors.ConfigError("%s: default_target is not an IPv4 address" % ctx.config.path)


def _extra(path):
    """The lines of an --extra-file, shaped as caddy-site-set shapes a body.
    Refused: an import, and the placeholders through which Caddy reads its
    environment or a file into the block, the envfile's token among them."""
    if not path:
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise errors.UsageError("cannot read %s: %s" % (path, getattr(exc, "strerror", None) or exc))
    if not raw.strip():
        raise errors.UsageError("%s is empty: leave --extra-file out" % path)
    lines = caddyfile.body(raw)
    found = None
    for number, line in enumerate(raw.replace("\r\n", "\n").split("\n"), 1):
        placeholder = next((p for p in _READING if p in line), None)
        if placeholder:
            found = "reads %s at line %d" % (placeholder, number)
            break
    if found is None:
        imported = next((t for t in caddyfile.tokens(raw) if not t.quoted and t.text == "import"), None)
        if imported:
            found = "imports at line %d" % imported.line
    if found:
        raise errors.UsageError("%s %s: an --extra-file may not import, nor read the environment or files "
                                "({$…}, {env.…}, {file.…}); nothing was changed" % (path, found))
    return lines


def _hide_caddy_line(exc, path):
    """A validate failure of a block holding an --extra-file, without
    Caddy's line, which may quote the file's directives."""
    head, sep, rest = exc.message.partition(_VALIDATE)
    if not sep or head:
        return exc
    _line, sep, rest = rest.rpartition(_RESTORED)
    return type(exc)("caddy validate failed on the block with the directives of %s (Caddy's line is not shown: "
                     "it may quote them)%s%s" % (path, sep, rest))


def block_lines(settings, to, extra):
    """The body publish writes: the TLS snippet, log, reverse_proxy, then the extra directives."""
    lines = ["\timport " + settings.tls_snippet] if settings.tls_snippet else []
    return lines + ["\tlog", "\treverse_proxy " + to] + extra


def ssl_guard(ctx, zone, host):
    """Exit 5 unless the edge can serve the host over HTTPS and reach the origin over HTTPS."""
    universal = ctx.api.get("/zones/%s/ssl/universal/settings" % zone["id"])
    if not universal.get("enabled"):
        raise errors.Refused(
            "Universal SSL is off on %s: the edge has no certificate for %s (universal-ssl %s on), "
            "or publish with --no-proxy; nothing was changed" % (zone["name"], host, zone["name"]))
    mode = ctx.api.get("/zones/%s/settings/ssl" % zone["id"])["value"]
    if mode not in SAFE_SSL:
        raise errors.Refused(
            "%s is in SSL mode %s: a proxied site needs full or strict (setting-set %s ssl full), "
            "or publish with --no-proxy; nothing was changed" % (zone["name"], mode, zone["name"]))


def current_a(ctx, zone, host):
    """The A record publish updates, None when it creates one; refused for a
    name it cannot take over without deleting something: a CNAME, an AAAA."""
    found = dns.by_name(ctx, zone, host)
    for record in found:
        if record["type"] == "CNAME":
            raise errors.Refused("%s is a CNAME to %s: dns-delete it, or dns-update it into an A, first; "
                                 "nothing was changed" % (host, record["content"]))
        if record["type"] == "AAAA":
            raise errors.UsageError("%s has an AAAA record (%s): dns-delete it first, publish writes an A alone; "
                                    "nothing was changed" % (host, record["content"]))
    a = [r for r in found if r["type"] == "A"]
    if len(a) > 1:
        raise errors.Refused("%s has %d A records: dns-delete all but one first; nothing was changed" % (host, len(a)))
    return a[0] if a else None


def caddy_ready(settings, host):
    """The Caddyfile's block of the host (None for none), once everything a
    cycle would refuse has been checked, before any write."""
    text = settings.read()
    blocks, loose = caddyfile.parse(text)
    block = caddyfile.target(text, blocks, loose, host)
    settings.variables()
    if not settings.alive():
        raise errors.Refused("caddy's admin API does not answer at %s: a reload cannot be checked, "
                             "nor taken back; nothing was changed" % settings.admin)
    return block


def write_a(ctx, zone, host, ip, proxied, current):
    """(lines, backup path or None): the record created or updated, or left
    alone, with no backup, when it is already right."""
    if current and current["content"] == ip and bool(current.get("proxied")) == proxied:
        return [dns.line("unchanged", current)], None
    path = dns.save(ctx, zone, [host], {host: ["A"]})
    if current:
        updated = guard.after_backup(path, ctx.api.put, _records_path(zone) + "/" + current["id"],
                                     dns.body(dict(current, content=ip, proxied=proxied)))
        lines = [dns.line("before", current), dns.line("after", updated)]
    else:
        record = {"type": "A", "name": host, "content": ip, "proxied": proxied, "ttl": 1}
        created = guard.after_backup(path, ctx.api.post, _records_path(zone), dns.body(record))
        lines = [dns.line("created", created)]
    return lines + ["backup: " + path], path


def _put_record_back(ctx, host, path, failure):
    """The error of a failed cycle, the record put back from its backup."""
    try:
        lines = dns.restore(ctx, backup.load(path))
    except errors.CfError as exc:
        return "%s; the DNS record of %s could not be put back (%s): restore it by hand; backup: %s" % (
            failure.message, host, exc.message, path)
    undone = lines[-1][len("backup: "):] if lines else "nothing to undo"
    return "%s; the DNS record of %s is put back (its undone state: %s); backup: %s" % (
        failure.message, host, undone, path)


def _check_lines(host):
    """The check of the host, then a line saying so when it does not answer
    over HTTPS: the publish is done all the same."""
    result = check.one(host)
    lines = [fmt.table([check.row(result)], check.COLUMNS)]
    state = result["resolution"] if not result["addresses"] else result["https"]
    if not isinstance(state, int):
        lines.append("published, but the check reads %s" % state)
    return lines


# ---- writes ----

def publish(args, ctx):
    host = caddyfile.host_name(args.host)
    to = upstream(args.to)
    extra = _extra(args.extra_file)
    ip = target_ip(args, ctx)
    settings = caddyctl.Settings(ctx.config)
    zone = zone_of(ctx, host)
    proxied = not args.no_proxy
    if proxied:
        ssl_guard(ctx, zone, host)
    current = current_a(ctx, zone, host)
    caddy_ready(settings, host)
    if not settings.tls_snippet:
        print("cf: warning: no caddy.tls_snippet in %s: the block of %s imports no TLS snippet"
              % (ctx.config.path, host), file=sys.stderr)
    lines, path = write_a(ctx, zone, host, ip, proxied, current)
    try:
        cycled = caddy.cycle(ctx, lambda text: caddyfile.set_site(text, host, block_lines(settings, to, extra)), host)
    except errors.CfError as exc:
        if extra:
            exc = _hide_caddy_line(exc, args.extra_file)
        if path is None:
            raise exc
        raise type(exc)(_put_record_back(ctx, host, path, exc))
    except BaseException as exc:
        # Not an engine error (a bug, an interrupt): the record is put back
        # all the same, said on stderr, and the error goes on as it came.
        if path is not None:
            failed = errors.CfError("%s: %s" % (type(exc).__name__, exc))
            print("cf: " + _put_record_back(ctx, host, path, failed), file=sys.stderr)
        raise
    return "\n".join(lines + [cycled] + _check_lines(host))


def _put_block_back(ctx, host, original, failure):
    """The error of a failed record deletion, the block put back by a cycle."""
    try:
        cycled = caddy.cycle(ctx, lambda text: original)
    except errors.CfError as exc:
        return "%s; the site block of %s could not be put back (%s)" % (failure.message, host, exc.message)
    return "%s; the site block of %s is put back (the Caddyfile without it: %s)" % (
        failure.message, host, cycled.rsplit("backup: ", 1)[-1])


def unpublish(args, ctx):
    host = caddyfile.host_name(args.host)
    settings = caddyctl.Settings(ctx.config)
    zone = zone_of(ctx, host)
    records = [r for r in dns.by_name(ctx, zone, host) if r["type"] in SERVING]
    original = settings.read()
    blocks, loose = caddyfile.parse(original)
    block = caddyfile.target(original, blocks, loose, host)
    if block is None and not records:
        raise errors.UsageError("nothing to unpublish: no site block and no A, AAAA or CNAME record for %s" % host)
    # The records' backup comes first: once the block is gone, a backup that
    # cannot be written would leave the host half unpublished.
    path = dns.save(ctx, zone, [host], {host: sorted({r["type"] for r in records})}) if records else None
    lines = []
    if block is not None:
        cycled = caddy.cycle(ctx, lambda text: caddyfile.remove_site(text, host), host, removing=True)
        lines.append(cycled)
    if not records:
        return "\n".join(lines)
    deleted = []
    try:
        for record in records:
            ctx.api.delete(_records_path(zone) + "/" + record["id"])
            deleted.append(record)
    except errors.ApiError as exc:
        message = "%s; backup: %s" % (exc.message, path)
        if deleted:
            message = _put_record_back(ctx, host, path, exc)
        if block is not None:
            copy = cycled.rsplit("backup: ", 1)[-1]
            message = _put_block_back(ctx, host, original, errors.ApiError(message)) + "; backup: " + copy
        raise errors.ApiError(message)
    return "\n".join(lines + [dns.line("deleted", r) for r in deleted] + ["backup: " + path])


# ---- the inventory ----

def _ssl(ctx, zone):
    values = {s["id"]: s.get("value") for s in ctx.api.get("/zones/%s/settings" % zone["id"]) or []}
    universal = ctx.api.get("/zones/%s/ssl/universal/settings" % zone["id"])
    values["universal_ssl"] = "on" if universal.get("enabled") else "off"
    return {key: values.get(key) for key in _SSL_SETTINGS}


def _in_zone(zone, host):
    return host == zone["name"] or host.endswith("." + zone["name"])


def _covered(wildcards, host):
    return any(host.endswith(w[1:]) and host.count(".") == w.count(".") for w in wildcards)


def matrix(zone, records, blocks):
    """(rows, records without block, blocks without record) for the hosts of
    the zone: the names of its A, AAAA and CNAME records, and the https hosts
    of the Caddyfile under it. blocks None: no Caddy to compare with."""
    by_host, wildcards = {}, []
    for record in records:
        if record["type"] not in SERVING:
            continue
        if record["name"].startswith("*."):
            wildcards.append(record["name"])
        else:
            by_host.setdefault(record["name"], []).append(record)
    served = [h for h in caddyfile.hosts(blocks or []) if _in_zone(zone, h)]
    rows = []
    for host in sorted(set(by_host) | set(served)):
        found = by_host.get(host, [])
        if blocks is None:
            block = None
        elif host in served:
            block = "yes"
        else:
            covering = caddyfile.serving(blocks, host)
            block = ", ".join(covering[0].addresses) if covering else "no"
        rows.append({"host": host, "block": block,
                     "record": " + ".join("%s %s" % (r["type"], r["content"]) for r in found) or None,
                     "proxied": any(r.get("proxied") for r in found) if found else None})
    without_block = [r["host"] for r in rows if r["block"] == "no"]
    without_record = [h for h in served if h not in by_host and not _covered(wildcards, h)]
    return rows, without_block, without_record


def inventory(args, ctx):
    until = check.deadline()
    zone = zones.find(ctx, args.zone)
    records = ctx.api.get(_records_path(zone)) or []
    data = {"zone_id": zone["id"], "names": sorted({r["name"] for r in records}), "records": records}
    path = ctx.backup.save(ctx.account, zone["name"], "dns", data)
    values = _ssl(ctx, zone)
    if not ctx.config.caddy:
        blocks, note = None, "no caddy section in %s: the blocks are not compared" % ctx.config.path
    else:
        blocks, note = caddyfile.parse(caddyctl.Settings(ctx.config).read())[0], None
    rows, without_block, without_record = matrix(zone, records, blocks)
    checks = check.run([r["host"] for r in rows], until)
    for row in rows:
        result = checks[row["host"]]
        row.update(https=result["https"], issuer=result["issuer"], expires=result["expires"],
                   address=check.row(result)["address"])
    if args.json:
        return fmt.as_json({"zone": zone["name"], "ssl": values, "hosts": rows, "records_without_block": without_block,
                            "blocks_without_record": without_record, "caddy": note, "backup": path})
    out = ["\t".join("%s %s" % (key, "-" if values[key] is None else values[key]) for key in _SSL_SETTINGS)]
    table = fmt.table(rows, COLUMNS)
    if table:
        out.append(table)
    if note:
        out.append("caddy: " + note)
    else:
        out.append("records without block: " + (", ".join(without_block) or "none"))
        out.append("blocks without record: " + (", ".join(without_record) or "none"))
    return "\n".join(out + ["backup: " + path])


def register(subparsers):
    parser = subparsers.add_parser("inventory", help="a zone's SSL settings and its records against the Caddyfile")
    parser.add_argument("zone", help="zone name or id")
    parser.set_defaults(handler=inventory, read=True)

    parser = subparsers.add_parser("publish", help="the A record, the site block, validate, reload, then check")
    parser.add_argument("host")
    parser.add_argument("--to", required=True, help="the upstream: a port on this machine, or host:port, http://…")
    parser.add_argument("--no-proxy", action="store_true", help="DNS only, not through Cloudflare's proxy")
    parser.add_argument("--ip", help="the A record's address (default: the config's default_target)")
    parser.add_argument("--extra-file", help="more directives for the block, after reverse_proxy")
    parser.set_defaults(handler=publish)

    parser = subparsers.add_parser("unpublish", help="remove the site block, then delete the record")
    parser.add_argument("host")
    parser.set_defaults(handler=unpublish)
