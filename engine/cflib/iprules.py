"""IP access rules of a zone: allow or block an address, a range, an AS
number or a country. Every write saves the zone's rules first, and restore()
replays such a backup.
"""

import ipaddress
import re

from . import backup, errors, fmt, zones

MODES = {"allow": "whitelist", "block": "block"}
SHOWN = {v: k for k, v in MODES.items()}
COLUMNS = ["mode", "target", "value", "notes", "id"]
_ASN = re.compile(r"^(?:AS)?(\d{1,10})$", re.I)
_COUNTRY = re.compile(r"^[A-Za-z]{2}$|^T1$")
# The ranges IP access rules take, by IP version
# (developers.cloudflare.com/waf/tools/ip-access-rules/parameters/); a /32
# IPv4 or a /128 IPv6 is one address.
_PREFIXES = {4: (16, 24), 6: (32, 48, 64)}
_ADDRESS = {4: "ip", 6: "ip6"}


def _path(zone, rule=None):
    base = "/zones/%s/firewall/access_rules/rules" % zone["id"]
    return base + "/" + rule if rule else base


def configuration(text):
    """The access rule configuration a target names: an IP, a CIDR range, AS<n> or a country code."""
    text = text.strip()
    try:
        net = ipaddress.ip_network(text, strict=False)
    except ValueError:
        net = None
    if net is not None:
        if net.prefixlen == net.max_prefixlen:
            return {"target": _ADDRESS[net.version], "value": str(net.network_address)}
        if net.prefixlen not in _PREFIXES[net.version]:
            raise errors.UsageError("%s: IP access rules take IPv4 ranges of /16 or /24 and IPv6 ranges of /32, /48 or /64"
                                    % text)
        try:
            ipaddress.ip_network(text)
        except ValueError:
            raise errors.UsageError("%s has host bits set: the range is %s" % (text, net))
        return {"target": "ip_range", "value": str(net)}
    found = _ASN.match(text)
    if found and text.upper().startswith("AS"):
        return {"target": "asn", "value": "AS" + found.group(1)}
    if _COUNTRY.match(text):
        return {"target": "country", "value": text.upper()}
    raise errors.UsageError("%s is not an IP, a CIDR range, an AS number (AS64500) or a country code" % text)


def row(rule):
    conf = rule.get("configuration") or {}
    return {"mode": SHOWN.get(rule.get("mode"), rule.get("mode")), "target": conf.get("target"),
            "value": conf.get("value"), "notes": rule.get("notes"), "id": rule.get("id")}


def line(verb, rule):
    return fmt.table([dict(row(rule), verb=verb)], ["verb"] + COLUMNS).split("\n", 1)[1]


def _all(ctx, zone):
    return ctx.api.get(_path(zone)) or []


def save(ctx, zone, rules):
    return ctx.backup.save(ctx.account, zone["name"], "ip-rules",
                           {"zone_id": zone["id"], "names": [zone["name"]], "rules": rules})


def _same(a, b):
    return {k: a.get(k) for k in ("mode", "configuration")} == {k: b.get(k) for k in ("mode", "configuration")}


# ---- reads ----

def ip_rules(args, ctx):
    zone = zones.find(ctx, args.zone)
    found = _all(ctx, zone)
    if args.json:
        return fmt.as_json(found)
    return fmt.table([row(r) for r in found], COLUMNS)


# ---- writes ----

def _set(ctx, args, mode):
    conf = configuration(args.target)
    zone = zones.find(ctx, args.zone)
    rules = _all(ctx, zone)
    existing = next((r for r in rules if r.get("configuration") == conf), None)
    if existing and existing.get("mode") == mode:
        return line("unchanged", existing)
    path = save(ctx, zone, rules)
    with ctx.backup.naming(path):
        if existing:
            done = ctx.api.patch(_path(zone, existing["id"]), {"mode": mode, "notes": args.note or existing.get("notes") or ""})
            return "%s\n%s\nbackup: %s" % (line("before", existing), line("after", done), path)
        done = ctx.api.post(_path(zone), {"mode": mode, "configuration": conf, "notes": args.note or "cf-plugin"})
    return "%s\nbackup: %s" % (line("created", done), path)


def ip_allow(args, ctx):
    return _set(ctx, args, MODES["allow"])


def ip_block(args, ctx):
    return _set(ctx, args, MODES["block"])


def ip_rule_delete(args, ctx):
    zone = zones.find(ctx, args.zone)
    rules = _all(ctx, zone)
    conf = None if any(r.get("id") == args.rule for r in rules) else configuration(args.rule)
    found = [r for r in rules if (r.get("id") == args.rule if conf is None else r.get("configuration") == conf)]
    if not found:
        raise errors.UsageError("no IP access rule %s in %s" % (args.rule, zone["name"]))
    path = save(ctx, zone, rules)
    lines = []
    with ctx.backup.naming(path):
        for rule in found:
            ctx.api.delete(_path(zone, rule["id"]))
            lines.append(line("deleted", rule))
    return "\n".join(lines + ["backup: " + path])


@backup.restorer("ip-rules")
def restore(ctx, saved):
    data = saved["data"]
    zone = {"id": data["zone_id"], "name": saved["zone"]}
    wanted = data["rules"]
    current = _all(ctx, zone)
    wanted_ids = {r["id"] for r in wanted}
    now = {r["id"]: r for r in current}
    deletes = [r for r in current if r["id"] not in wanted_ids and not any(_same(r, w) for w in wanted)]
    patches = [(now[w["id"]], w) for w in wanted if w["id"] in now and not _same(now[w["id"]], w)]
    posts = [w for w in wanted if w["id"] not in now and not any(_same(c, w) for c in current)]
    if not (deletes or patches or posts):
        return []
    path = save(ctx, zone, current)
    lines = []
    with ctx.backup.naming(path):
        for rule in deletes:
            ctx.api.delete(_path(zone, rule["id"]))
            lines.append(line("deleted", rule))
        for _, rule in patches:
            lines.append(line("restored", ctx.api.patch(_path(zone, rule["id"]), {"mode": rule["mode"], "notes": rule.get("notes") or ""})))
        for rule in posts:
            made = ctx.api.post(_path(zone), {"mode": rule["mode"], "configuration": rule["configuration"], "notes": rule.get("notes") or ""})
            lines.append(line("recreated", made))
    return lines + ["backup: " + path]


def register(subparsers):
    parser = subparsers.add_parser("ip-rules", help="the IP access rules of a zone")
    parser.add_argument("zone", help="zone name or id")
    parser.set_defaults(handler=ip_rules, read=True)

    for name, handler, what in (("ip-allow", ip_allow, "allow"), ("ip-block", ip_block, "block")):
        parser = subparsers.add_parser(name, help="%s an IP, a range, an AS number or a country" % what)
        parser.add_argument("zone")
        parser.add_argument("target", help="203.0.113.7, 2001:db8::7, 203.0.113.0/24 (/16, /24; IPv6 /32, /48, /64), AS64500 or FR")
        parser.add_argument("--note")
        parser.set_defaults(handler=handler)

    parser = subparsers.add_parser("ip-rule-delete", help="delete an IP access rule, by id or by its target")
    parser.add_argument("zone")
    parser.add_argument("rule", help="rule id, or the target it names")
    parser.set_defaults(handler=ip_rule_delete)
