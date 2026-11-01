"""The zone's rulesets: the entrypoints of the custom rules, rate limiting
and managed rules phases.

A write never sends only the rule it targets: it reads the whole entrypoint,
changes that rule, and puts the whole list back, so that every other rule
(the ones made in the dashboard included) stays as it was. Each write saves
the whole entrypoint first, and restore() replays it. The rules the plugin
creates carry PREFIX in their description.
"""

import argparse

from . import backup, errors, fmt, quotas, zones

CUSTOM = "http_request_firewall_custom"
RATE = "http_ratelimit"
MANAGED = "http_request_firewall_managed"
PHASES = {"custom": CUSTOM, "ratelimit": RATE, "managed": MANAGED}
SHORT = {v: k for k, v in PHASES.items()}
PREFIX = "cf-plugin:"
# Fields Cloudflare adds when it reads a rule, and refuses when it is sent back.
_READ_ONLY = ("version", "last_updated", "categories")
CUSTOM_ACTIONS = ("block", "challenge", "js_challenge", "managed_challenge", "log")
COLUMNS = ["phase", "id", "action", "enabled", "description", "expression"]


def entrypoint_path(zone, phase):
    return "/zones/%s/rulesets/phases/%s/entrypoint" % (zone["id"], phase)


def read(ctx, zone, phase):
    """The zone's entrypoint of a phase, None while the zone has none."""
    try:
        return ctx.api.get(entrypoint_path(zone, phase))
    except errors.ApiError as exc:
        # A phase never written has no entrypoint: Cloudflare 10003.
        if exc.message.startswith("Cloudflare 10003:"):
            return None
        raise


def rules_of(entry):
    return list((entry or {}).get("rules") or [])


def count(entry):
    """How many rules an entrypoint holds (none read, none held)."""
    return len(rules_of(entry))


def body(rule):
    """A rule as Cloudflare takes it back."""
    return {k: v for k, v in rule.items() if k not in _READ_ONLY}


def save(ctx, zone, phase, entry):
    data = {"zone_id": zone["id"], "names": [phase], "phase": phase,
            "rules": None if entry is None else rules_of(entry)}
    return ctx.backup.save(ctx.account, zone["name"], "ruleset", data)


def write(ctx, zone, phase, entry, rules):
    """Save the entrypoint, then put the whole list of rules back. Returns
    the backup's path and the entrypoint as Cloudflare now holds it."""
    path = save(ctx, zone, phase, entry)
    with ctx.backup.naming(path):
        done = ctx.api.put(entrypoint_path(zone, phase), {"rules": [body(r) for r in rules]})
    return path, done


def stored(done, rule):
    """The rule as Cloudflare now holds it (its id included), found in the
    entrypoint a write answered with; the rule itself when it is not there."""
    for have in rules_of(done):
        if all(have.get(k) == rule.get(k) for k in ("expression", "description", "action")):
            return have
    return rule


def is_plugin(rule):
    return (rule.get("description") or "").startswith(PREFIX)


def row(rule, phase):
    return {"phase": SHORT.get(phase, phase), "id": rule.get("id"), "action": rule.get("action"),
            "enabled": rule.get("enabled", True), "description": rule.get("description"),
            "expression": rule.get("expression")}


def line(verb, rule, phase):
    return fmt.table([dict(row(rule, phase), verb=verb)], ["verb"] + COLUMNS).split("\n", 1)[1]


def find_rule(ctx, zone, rule_id):
    """(phase, entry, rule) of the rule of this id, in whichever phase holds it."""
    for phase in PHASES.values():
        entry = read(ctx, zone, phase)
        for rule in rules_of(entry):
            if rule.get("id") == rule_id:
                return phase, entry, rule
    raise errors.UsageError("no rule %s in %s" % (rule_id, zone["name"]))


# ---- reads ----

def rules(args, ctx):
    zone = zones.find(ctx, args.zone)
    phases = [PHASES[args.phase]] if args.phase else list(PHASES.values())
    found = []
    for phase in phases:
        for rule in rules_of(read(ctx, zone, phase)):
            if not args.plugin or is_plugin(rule):
                found.append((phase, rule))
    if args.json:
        return fmt.as_json([dict(rule, phase=SHORT[phase]) for phase, rule in found])
    return fmt.table([row(rule, phase) for phase, rule in found], COLUMNS)


# ---- writes ----

def rule_update(args, ctx):
    zone = zones.find(ctx, args.zone)
    changes = {}
    for key in ("expression", "action", "description", "enabled"):
        value = getattr(args, key)
        if value is not None:
            changes[key] = value
    if not changes:
        raise errors.UsageError("nothing to change: pass expression, action, description or enabled")
    phase, entry, current = find_rule(ctx, zone, args.rule)
    if phase == CUSTOM and changes.get("action") and changes["action"] not in CUSTOM_ACTIONS:
        raise errors.UsageError("action must be one of %s" % ", ".join(CUSTOM_ACTIONS))
    if changes.get("action") == "log" and phase == CUSTOM:
        if quotas.key(zone) not in quotas.LOG_PLANS:
            quotas.refuse(zone, "the log action is not offered")
    new = dict(current, **changes)
    path, _ = write(ctx, zone, phase, entry, [new if r.get("id") == current["id"] else r for r in rules_of(entry)])
    return "%s\n%s\nbackup: %s" % (line("before", current, phase), line("after", new, phase), path)


def rule_delete(args, ctx):
    zone = zones.find(ctx, args.zone)
    phase, entry, current = find_rule(ctx, zone, args.rule)
    path, _ = write(ctx, zone, phase, entry, [r for r in rules_of(entry) if r.get("id") != current["id"]])
    return "%s\nbackup: %s" % (line("deleted", current, phase), path)


@backup.restorer("ruleset")
def restore(ctx, saved):
    """Put the saved entrypoint back over the current one. Returns the lines
    to print, a backup of the state it replaces last; no line when the rules
    already are the saved ones."""
    data = saved["data"]
    zone = {"id": data["zone_id"], "name": saved["zone"]}
    phase = data["phase"]
    wanted = data["rules"] or []
    entry = read(ctx, zone, phase)
    if [body(r) for r in rules_of(entry)] == [body(r) for r in wanted]:
        return []
    path, _ = write(ctx, zone, phase, entry, wanted)
    return ["%s\t%s\t%d rules" % ("restored", SHORT.get(phase, phase), len(wanted)), "backup: " + path]


def register(subparsers):
    parser = subparsers.add_parser("rules", help="the rules of a zone's protection phases")
    parser.add_argument("zone", help="zone name or id")
    parser.add_argument("--phase", choices=sorted(PHASES), help="only this phase's (default: all three)")
    parser.add_argument("--plugin", action="store_true", help="only the rules this plugin made")
    parser.set_defaults(handler=rules, read=True)

    parser = subparsers.add_parser("rule-update", help="change a rule, by its id")
    parser.add_argument("zone")
    parser.add_argument("rule", help="rule id, as rules prints it")
    parser.add_argument("--expression")
    parser.add_argument("--action")
    parser.add_argument("--description")
    parser.add_argument("--enabled", action=argparse.BooleanOptionalAction, default=None,
                        help="--no-enabled turns the rule off")
    parser.set_defaults(handler=rule_update)

    parser = subparsers.add_parser("rule-delete", help="delete a rule, by its id")
    parser.add_argument("zone")
    parser.add_argument("rule", help="rule id, as rules prints it")
    parser.set_defaults(handler=rule_delete)
