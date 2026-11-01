"""Protections composed into rules: block or allow only countries, challenge,
rate limiting, managed rulesets, and the raw rule-add.

Each write reads the zone's plan and the phase's entrypoint, refuses (exit 5)
what the plan lacks or what is full before any call that changes something,
then writes the whole entrypoint back with every foreign rule intact. A rule
that already exists is left alone. On a full custom-rules quota, a block rule
is merged into the plugin's existing block rule (an « or » of the two
expressions) instead of taking a slot of its own.
"""

import re

from . import errors, quotas, rulesets, zones

HOST = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")
_COUNTRY = re.compile(r"^[A-Z]{2}$|^T1$")
_PATH = re.compile(r"/[A-Za-z0-9._~/%+-]*")
# A merge stops at 4,000 characters: Cloudflare refuses an expression past
# 4,096, and the margin leaves room to edit the merged rule by hand afterwards.
_MAX_EXPRESSION = 4000
# Cloudflare's managed rulesets, by the ids it lists them under (GET
# /zones/:id/rulesets, kind managed), the same on every zone.
MANAGED_IDS = {
    "free": "77454fe2d30c4220b5701f6fdfb893ba",
    "cloudflare": "efb7b8c949ac4650a09736fc376e9aee",
    "owasp": "4814384a9e5d4991b9815dcfc25d2f1f",
}
CHALLENGES = {"managed": "managed_challenge", "js": "js_challenge", "interactive": "challenge"}
RATE_ACTIONS = ("block", "challenge", "js_challenge", "managed_challenge")


# ---- expressions ----

def resolve(ctx, target):
    """(zone, host) of a target: a host of one of the account's zones, or a
    zone's name for the whole zone (host None)."""
    name = target.strip().lower().rstrip(".")
    if "*" in name:
        raise errors.UsageError("%s: a rule on http.host never matches a wildcard; target the zone instead" % name)
    if not HOST.match(name):
        raise errors.UsageError("%s is not a host or a zone name" % target)
    params = {"account.id": ctx.account.account_id} if ctx.account.account_id else None
    found = [z for z in ctx.api.get("/zones", params=params) or []
             if name == z["name"] or name.endswith("." + z["name"])]
    if not found:
        raise errors.UsageError("no zone of account %s holds %s" % (ctx.account.name, name))
    zone = max(found, key=lambda z: len(z["name"]))
    return zone, (None if name == zone["name"] else name)


def countries(codes):
    out = []
    for code in codes:
        for one in code.split(","):
            one = one.strip().upper()
            if not _COUNTRY.match(one):
                raise errors.UsageError("%s is not a two-letter country code" % one)
            if one not in out:
                out.append(one)
    if not out:
        raise errors.UsageError("name at least one country code")
    return out


def _in(codes):
    return "ip.src.country in {%s}" % " ".join('"%s"' % c for c in codes)


def host_clause(host):
    return 'http.host eq "%s"' % host if host else None


def path_clause(path):
    if path is None:
        return None
    if not _PATH.fullmatch(path):
        raise errors.UsageError("%r is not a path starting with /" % path)
    return 'starts_with(http.request.uri.path, "%s")' % path


def expression(*clauses):
    parts = [c for c in clauses if c]
    return "(%s)" % " and ".join(parts) if parts else "true"


def _label(host, zone):
    return host or zone["name"]


# ---- the rule to add ----

def _phase_rules(ctx, zone, phase):
    entry = rulesets.read(ctx, zone, phase)
    return entry, rulesets.rules_of(entry)


def _same_rule(a, b):
    return all(a.get(k) == b.get(k) for k in ("action", "expression", "action_parameters", "ratelimit"))


def add_custom(ctx, zone, rule, merge=True):
    """Add a custom rule; the lines to print. The rule is left alone when an
    equal one exists; merged into the plugin's block rule when the quota is
    full and merge allows it; refused when the quota is full otherwise."""
    entry, rules = _phase_rules(ctx, zone, rulesets.CUSTOM)
    for have in rules:
        if _same_rule(have, rule):
            return rulesets.line("unchanged", have, rulesets.CUSTOM)
    if rule["action"] == "log" and quotas.key(zone) not in quotas.LOG_PLANS:
        quotas.refuse(zone, "the log action is not offered")
    if rulesets.count(entry) < quotas.limits(zone)["custom_rules"]:
        written = dict(rule, enabled=True)
        path, done = rulesets.write(ctx, zone, rulesets.CUSTOM, entry, rules + [written])
        return "%s\nbackup: %s" % (rulesets.line("created", rulesets.stored(done, written), rulesets.CUSTOM), path)
    target = next((r for r in rules if merge and rulesets.is_plugin(r) and r.get("enabled", True)
                   and r.get("action") == rule["action"] and not r.get("action_parameters")
                   and not r.get("ratelimit")), None)
    if target is None:
        quotas.require_room(zone, "custom_rules", rulesets.count(entry), "custom rules")
    merged = dict(target, expression="(%s) or (%s)" % (target["expression"], rule["expression"]),
                  description="%s | %s" % (target["description"], rule["description"][len(rulesets.PREFIX):].strip()))
    if len(merged["expression"]) > _MAX_EXPRESSION:
        quotas.refuse(zone, "custom rules quota is full (%d of %d) and the plugin's %s rule is too long to take another"
                      % (rulesets.count(entry), quotas.limits(zone)["custom_rules"], rule["action"]))
    path, _ = rulesets.write(ctx, zone, rulesets.CUSTOM, entry,
                             [merged if r.get("id") == target["id"] else r for r in rules])
    return "%s\n%s\nbackup: %s" % (rulesets.line("before", target, rulesets.CUSTOM),
                                   rulesets.line("merged", merged, rulesets.CUSTOM), path)


def _plugin_rule(description, expr, action, **extra):
    return dict({"action": action, "expression": expr, "description": "%s %s" % (rulesets.PREFIX, description)}, **extra)


# ---- commands ----

def rule_add(args, ctx):
    zone = zones.find(ctx, args.zone)
    if args.action not in rulesets.CUSTOM_ACTIONS:
        raise errors.UsageError("action must be one of %s" % ", ".join(rulesets.CUSTOM_ACTIONS))
    rule = {"action": args.action, "expression": args.expression,
            "description": args.description or "%s rule-add" % rulesets.PREFIX}
    return add_custom(ctx, zone, rule, merge=False)


def block_countries(args, ctx):
    zone, host = resolve(ctx, args.target)
    codes = countries(args.countries)
    rule = _plugin_rule("block-countries %s %s" % (_label(host, zone), ",".join(codes)),
                        expression(host_clause(host), _in(codes)), "block")
    return add_custom(ctx, zone, rule)


def allow_only_countries(args, ctx):
    zone, host = resolve(ctx, args.target)
    codes = countries(args.countries)
    rule = _plugin_rule("allow-only-countries %s %s" % (_label(host, zone), ",".join(codes)),
                        expression(host_clause(host), "not " + _in(codes)), "block")
    return add_custom(ctx, zone, rule)


def challenge(args, ctx):
    zone, host = resolve(ctx, args.target)
    codes = countries(args.country) if args.country else None
    desc = " ".join(p for p in ("challenge", _label(host, zone), args.path or "", ",".join(codes or [])) if p)
    rule = _plugin_rule(desc, expression(host_clause(host), path_clause(args.path), codes and _in(codes)),
                        CHALLENGES[args.type])
    return add_custom(ctx, zone, rule)


def rate_limit(args, ctx):
    zone, host = resolve(ctx, args.target)
    limits = quotas.limits(zone)
    periods, timeouts = limits["periods"], limits["timeouts"]
    period = args.period if args.period is not None else (60 if 60 in periods else 10)
    if period not in periods:
        quotas.refuse(zone, "rate limiting counts over %s seconds only" % ", ".join(map(str, periods)))
    if args.timeout is not None:
        timeout = args.timeout
    else:
        timeout = 600 if timeouts is None else max(t for t in timeouts if t <= 600)
    if timeouts is None:
        if not 10 <= timeout <= quotas.RATE_PERIODS[-1]:
            quotas.refuse(zone, "the mitigation timeout goes from 10 to %d seconds" % quotas.RATE_PERIODS[-1])
    elif timeout not in timeouts:
        quotas.refuse(zone, "the mitigation timeout takes %s seconds only" % ", ".join(map(str, timeouts)))
    if args.requests < 1:
        raise errors.UsageError("--requests must be at least 1")
    expr = expression(host_clause(host), path_clause(args.path))
    rule = _plugin_rule("rate-limit %s %s %d/%ds" % (_label(host, zone), args.path or "", args.requests, period),
                        expr, args.action, ratelimit={
                            "characteristics": ["cf.colo.id", "ip.src"], "period": period,
                            "requests_per_period": args.requests, "mitigation_timeout": timeout})
    rule["description"] = " ".join(rule["description"].split())
    entry, rules = _phase_rules(ctx, zone, rulesets.RATE)
    for have in rules:
        if _same_rule(have, rule):
            return rulesets.line("unchanged", have, rulesets.RATE)
    quotas.require_room(zone, "rate_limit_rules", rulesets.count(entry), "rate limiting rules")
    written = dict(rule, enabled=True)
    path, done = rulesets.write(ctx, zone, rulesets.RATE, entry, rules + [written])
    return "%s\nbackup: %s" % (rulesets.line("created", rulesets.stored(done, written), rulesets.RATE), path)


def managed_rules(args, ctx):
    zone = zones.find(ctx, args.zone)
    ruleset = args.ruleset or ("free" if quotas.key(zone) == "free" else "cloudflare")
    quotas.require_managed(zone, ruleset)
    wanted = MANAGED_IDS[ruleset]
    entry, rules = _phase_rules(ctx, zone, rulesets.MANAGED)
    ours = [r for r in rules if r.get("action") == "execute" and (r.get("action_parameters") or {}).get("id") == wanted]
    phase = rulesets.MANAGED
    if args.state == "on":
        if any(r.get("enabled", True) for r in ours):
            return rulesets.line("unchanged", ours[0], phase)
        if ours:
            new = dict(ours[0], enabled=True)
            path, _ = rulesets.write(ctx, zone, phase, entry, [new if r is ours[0] else r for r in rules])
            return "%s\nbackup: %s" % (rulesets.line("enabled", new, phase), path)
        new = _plugin_rule("managed-rules %s" % ruleset, "true", "execute", action_parameters={"id": wanted}, enabled=True)
        path, done = rulesets.write(ctx, zone, phase, entry, rules + [new])
        return "%s\nbackup: %s" % (rulesets.line("created", rulesets.stored(done, new), phase), path)
    # off: the plugin's own rule goes; one made in the dashboard is turned off, not deleted.
    live = [r for r in ours if r.get("enabled", True) or rulesets.is_plugin(r)]
    if not live:
        return "unchanged\t%s\toff" % ruleset
    kept = []
    lines = []
    for rule in rules:
        if rule not in live:
            kept.append(rule)
        elif rulesets.is_plugin(rule):
            lines.append(rulesets.line("deleted", rule, phase))
        else:
            kept.append(dict(rule, enabled=False))
            lines.append(rulesets.line("disabled", rule, phase))
    path, _ = rulesets.write(ctx, zone, phase, entry, kept)
    return "\n".join(lines + ["backup: " + path])


def register(subparsers):
    parser = subparsers.add_parser("rule-add", help="add a custom rule from a raw expression")
    parser.add_argument("zone", help="zone name or id")
    parser.add_argument("--expression", required=True, help="a Cloudflare rule expression")
    parser.add_argument("--action", required=True, help="/".join(rulesets.CUSTOM_ACTIONS))
    parser.add_argument("--description")
    parser.set_defaults(handler=rule_add)

    for name, handler, what in (
        ("block-countries", block_countries, "block visitors from these countries"),
        ("allow-only-countries", allow_only_countries, "block every country but these"),
    ):
        parser = subparsers.add_parser(name, help=what)
        parser.add_argument("target", help="a host of the account's zones, or a zone name for the whole zone")
        parser.add_argument("countries", nargs="+", metavar="CC", help="two-letter country codes (T1: Tor)")
        parser.set_defaults(handler=handler)

    parser = subparsers.add_parser("challenge", help="challenge visitors of a host, a path, countries")
    parser.add_argument("target", help="a host, or a zone name for the whole zone")
    parser.add_argument("--path", help="only paths starting with this")
    parser.add_argument("--country", action="append", help="only visitors from this country (repeatable)")
    parser.add_argument("--type", choices=sorted(CHALLENGES), default="managed")
    parser.set_defaults(handler=challenge)

    parser = subparsers.add_parser("rate-limit", help="limit the requests of one visitor to a host")
    parser.add_argument("target", help="a host, or a zone name for the whole zone")
    parser.add_argument("--requests", type=int, required=True, help="requests allowed per period")
    parser.add_argument("--period", type=int, help="seconds counted (default: 60 where the plan allows it, else 10)")
    parser.add_argument("--timeout", type=int, help="seconds the visitor stays mitigated (default: 600 where the plan allows it, else 10)")
    parser.add_argument("--path", help="only paths starting with this")
    parser.add_argument("--action", choices=RATE_ACTIONS, default="block")
    parser.set_defaults(handler=rate_limit)

    parser = subparsers.add_parser("managed-rules", help="turn a managed ruleset on or off")
    parser.add_argument("zone")
    parser.add_argument("state", choices=("on", "off"))
    parser.add_argument("--ruleset", choices=sorted(MANAGED_IDS), help="default: free on Free, else cloudflare")
    parser.set_defaults(handler=managed_rules)
