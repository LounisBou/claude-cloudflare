"""The zone's cache: cache rules through the http_request_cache_settings
phase, and purge.

A cache rule write reads the whole entrypoint, changes the rule it targets,
and puts the whole list back, so that every other rule (the ones made in the
dashboard included) stays as it was; it saves the entrypoint first, and
restore replays it like any other ruleset. A purge changes no stored state,
so there is nothing to save.
"""

from urllib.parse import urlsplit

from . import errors, fmt, guard, protect, quotas, rulesets, zones

CACHE = "http_request_cache_settings"
ACTION = "set_cache_settings"
MODES = ("cache", "bypass", "ttl")
COLUMNS = ["id", "mode", "enabled", "description", "expression"]
# Purge kinds by the flag that names them: the field Cloudflare takes, and the
# word the refusals use.
PURGES = {"url": ("files", "URL"), "host": ("hosts", "host"), "prefix": ("prefixes", "prefix"),
          "tag": ("tags", "tag")}


def mode_of(rule):
    params = rule.get("action_parameters") or {}
    ttl = params.get("edge_ttl") or {}
    if params.get("cache") is False:
        return "bypass"
    if params.get("cache") and ttl.get("mode") == "override_origin" and "default" in ttl:
        return "ttl %s" % ttl["default"]
    return "cache" if params.get("cache") else "other"


def row(rule):
    return {"id": rule.get("id"), "mode": mode_of(rule), "enabled": rule.get("enabled", True),
            "description": rule.get("description"), "expression": rule.get("expression")}


def line(verb, rule):
    return fmt.table([dict(row(rule), verb=verb)], ["verb"] + COLUMNS).split("\n", 1)[1]


def _write(ctx, zone, entry, rules):
    """Save the entrypoint, then put the whole list back: (backup path, answer)."""
    path = rulesets.save(ctx, zone, CACHE, entry)
    done = guard.after_backup(path, ctx.api.put, rulesets.entrypoint_path(zone, CACHE),
                              {"rules": [rulesets.body(r) for r in rules]})
    return path, done


def _in_zone(zone, host):
    return host == zone["name"] or host.endswith("." + zone["name"])


def _host(zone, host):
    name = host.strip().lower().rstrip(".")
    if not protect.HOST.match(name) or "*" in name:
        raise errors.UsageError("%s is not a host" % host)
    if not _in_zone(zone, name):
        raise errors.UsageError("%s is not in %s" % (name, zone["name"]))
    return name


# ---- reads ----

def cache_rules(args, ctx):
    zone = zones.find(ctx, args.zone)
    found = rulesets.rules_of(rulesets.read(ctx, zone, CACHE))
    if args.json:
        return fmt.as_json(found)
    return fmt.table([row(r) for r in found], COLUMNS)


# ---- writes ----

def cache_rule_add(args, ctx):
    zone = zones.find(ctx, args.zone)
    simple = args.host or args.path_prefix
    if bool(args.expression) == bool(simple):
        raise errors.UsageError("give --host and/or --path-prefix, or a raw --expression, not both")
    if args.mode == "ttl":
        if not args.ttl or args.ttl < 1:
            raise errors.UsageError("--mode ttl needs --ttl, the edge TTL in seconds")
    elif args.ttl is not None:
        raise errors.UsageError("--ttl goes with --mode ttl")
    host = _host(zone, args.host) if args.host else None
    if args.expression:
        expr, label = args.expression, "rule-add"
        description = args.description or "%s cache-rule-add" % rulesets.PREFIX
    else:
        expr = protect.expression(protect.host_clause(host), protect.path_clause(args.path_prefix))
        label = " ".join(p for p in (host, args.path_prefix) if p)
        description = args.description or "%s cache %s" % (rulesets.PREFIX, label)
    params = {"cache": args.mode != "bypass"}
    if args.mode == "ttl":
        params["edge_ttl"] = {"mode": "override_origin", "default": args.ttl}
    rule = {"action": ACTION, "expression": expr, "description": description, "action_parameters": params}

    entry = rulesets.read(ctx, zone, CACHE)
    rules = rulesets.rules_of(entry)
    for have in rules:
        if all(have.get(k) == rule[k] for k in ("action", "expression", "action_parameters")):
            return line("unchanged", have)
    quotas.require_room(zone, "cache_rules", len(rules), "cache rules")
    written = dict(rule, enabled=True)
    path, done = _write(ctx, zone, entry, rules + [written])
    return "%s\nbackup: %s" % (line("created", rulesets.stored(done, written)), path)


def cache_rule_delete(args, ctx):
    zone = zones.find(ctx, args.zone)
    entry = rulesets.read(ctx, zone, CACHE)
    rules = rulesets.rules_of(entry)
    current = next((r for r in rules if r.get("id") == args.rule), None)
    if current is None:
        raise errors.UsageError("no cache rule %s in %s" % (args.rule, zone["name"]))
    path, _ = _write(ctx, zone, entry, [r for r in rules if r is not current])
    return "%s\nbackup: %s" % (line("deleted", current), path)


def _purge_call(ctx, zone, body):
    ctx.api.post("/zones/%s/purge_cache" % zone["id"], body)


def _purge_host(value):
    """The host a URL or a prefix (host/path) names."""
    return (urlsplit(value).hostname if "://" in value else value.split("/")[0]).lower()


def purge(args, ctx):
    zone = zones.find(ctx, args.zone)
    given = {kind: getattr(args, kind) for kind in PURGES if getattr(args, kind)}
    if len(given) != 1:
        raise errors.UsageError("purge by one of --url, --host, --prefix or --tag")
    kind, values = next(iter(given.items()))
    field, word = PURGES[kind]
    if len(values) > quotas.purge_max(zone, field):
        quotas.refuse(zone, "purge by %s takes %d at a time, not %d" % (word, quotas.purge_max(zone, field), len(values)))
    if kind in ("url", "host", "prefix"):
        for value in values:
            host = _purge_host(value)
            if not host or not _in_zone(zone, host):
                raise errors.UsageError("%s is not in %s" % (value, zone["name"]))
    _purge_call(ctx, zone, {field: values})
    return "purged\t%s\t%d" % (field, len(values))


def purge_all(args, ctx):
    zone = zones.find(ctx, args.zone)
    _purge_call(ctx, zone, {"purge_everything": True})
    return "purged\teverything\t%s" % zone["name"]


def register(subparsers):
    parser = subparsers.add_parser("cache-rules", help="the cache rules of a zone")
    parser.add_argument("zone", help="zone name or id")
    parser.set_defaults(handler=cache_rules, read=True)

    parser = subparsers.add_parser("cache-rule-add", help="add a cache rule for a host and/or a path prefix, or a raw expression")
    parser.add_argument("zone")
    parser.add_argument("--host", help="a host of the zone")
    parser.add_argument("--path-prefix", help="only paths starting with this")
    parser.add_argument("--expression", help="a Cloudflare rule expression, instead of --host and --path-prefix")
    parser.add_argument("--mode", choices=MODES, default="cache",
                        help="cache: cache everything; bypass: never cache; ttl: cache with an edge TTL (--ttl)")
    parser.add_argument("--ttl", type=int, help="edge TTL in seconds, with --mode ttl")
    parser.add_argument("--description")
    parser.set_defaults(handler=cache_rule_add)

    parser = subparsers.add_parser("cache-rule-delete", help="delete a cache rule, by its id")
    parser.add_argument("zone")
    parser.add_argument("rule", help="rule id, as cache-rules prints it")
    parser.set_defaults(handler=cache_rule_delete)

    parser = subparsers.add_parser("purge", help="purge cached content by URL, host, prefix or tag")
    parser.add_argument("zone")
    for kind, (_, word) in PURGES.items():
        parser.add_argument("--" + kind, action="append", help="a %s to purge (repeatable)" % word)
    parser.set_defaults(handler=purge)

    parser = subparsers.add_parser("purge-all", help="purge everything cached for a zone")
    parser.add_argument("zone")
    parser.set_defaults(handler=purge_all)
