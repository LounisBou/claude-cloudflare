"""plan: a zone's plan and the quotas the engine relies on, with what is used."""

from . import fmt, quotas, rulesets, zones


def count(ctx, zone, phase):
    return len(rulesets.rules_of(rulesets.read(ctx, zone, phase)))


def plan(args, ctx):
    zone = zones.find(ctx, args.zone)
    q = quotas.limits(zone)
    rows = [
        {"item": "plan", "value": quotas.name(zone), "limit": None},
        {"item": "custom_rules", "value": count(ctx, zone, rulesets.CUSTOM), "limit": q["custom_rules"]},
        {"item": "rate_limit_rules", "value": count(ctx, zone, rulesets.RATE), "limit": q["rate_limit_rules"]},
        {"item": "managed_rulesets", "value": ",".join(q["managed"]), "limit": None},
        {"item": "bot_product", "value": q["bot"], "limit": None},
    ]
    if args.json:
        return fmt.as_json({"zone": zone["name"], "plan": quotas.name(zone), "quotas": q, "used": {
            "custom_rules": rows[1]["value"], "rate_limit_rules": rows[2]["value"]}})
    return fmt.table(rows, ["item", "value", "limit"])


def register(subparsers):
    parser = subparsers.add_parser("plan", help="a zone's plan and the quotas the engine relies on")
    parser.add_argument("zone", help="zone name or id")
    parser.set_defaults(handler=plan, read=True)
