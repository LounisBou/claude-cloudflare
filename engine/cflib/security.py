"""The zone-wide protections that are single settings: security level,
« Under Attack » (the security level under_attack) and Bot Fight Mode; and
the overview of every protection in place.
"""

from . import backup, errors, fmt, quotas, rulesets, settings, zones

LEVELS = ("essentially_off", "low", "medium", "high")
_BOT_FIELD = "fight_mode"


def _bot_path(zone):
    return "/zones/%s/bot_management" % zone["id"]


# ---- reads ----

def security(args, ctx):
    zone = zones.find(ctx, args.zone)
    values = {s["id"]: s.get("value") for s in ctx.api.get("/zones/%s/settings" % zone["id"]) or []}
    bot = ctx.api.get(_bot_path(zone)) or {}
    rows = [{"item": "security_level", "value": values.get("security_level")},
            {"item": "browser_check", "value": values.get("browser_check")},
            {"item": "challenge_ttl", "value": values.get("challenge_ttl")},
            {"item": "bot_fight_mode", "value": "on" if bot.get(_BOT_FIELD) else "off"},
            {"item": "custom_rules", "value": rulesets.count(rulesets.read(ctx, zone, rulesets.CUSTOM))},
            {"item": "rate_limit_rules", "value": rulesets.count(rulesets.read(ctx, zone, rulesets.RATE))},
            {"item": "managed_rules", "value": rulesets.count(rulesets.read(ctx, zone, rulesets.MANAGED))},
            {"item": "ip_access_rules",
             "value": len(ctx.api.get("/zones/%s/firewall/access_rules/rules" % zone["id"]) or [])}]
    if args.json:
        return fmt.as_json({r["item"]: r["value"] for r in rows})
    return fmt.table(rows, ["item", "value"])


# ---- writes ----

def security_level(args, ctx):
    if args.level == "under_attack":
        raise errors.UsageError("under_attack is set with under-attack, which is asked every time")
    return settings.apply(ctx, zones.find(ctx, args.zone), "security_level", args.level)


def under_attack(args, ctx):
    zone = zones.find(ctx, args.zone)
    return settings.apply(ctx, zone, "security_level", "under_attack" if args.state == "on" else args.level)


def bot_fight(args, ctx):
    zone = zones.find(ctx, args.zone)
    if quotas.key(zone) != "free":
        quotas.refuse(zone, "Bot Fight Mode is the Free product; this plan's %s is set in the dashboard"
                      % quotas.limits(zone)["bot"])
    wanted = args.state == "on"
    current = bool((ctx.api.get(_bot_path(zone)) or {}).get(_BOT_FIELD))
    if current == wanted:
        return "unchanged\tbot_fight_mode\t%s" % args.state
    data = {"zone_id": zone["id"], "names": ["bot_management"], _BOT_FIELD: current}
    path = ctx.backup.save(ctx.account, zone["name"], "bot", data)
    with ctx.backup.naming(path):
        ctx.api.put(_bot_path(zone), {_BOT_FIELD: wanted})
    return "changed\tbot_fight_mode\t%s\t%s\nbackup: %s" % ("on" if current else "off", args.state, path)


@backup.restorer("bot")
def restore(ctx, saved):
    data = saved["data"]
    zone = {"id": data["zone_id"], "name": saved["zone"]}
    current = bool((ctx.api.get(_bot_path(zone)) or {}).get(_BOT_FIELD))
    if current == data[_BOT_FIELD]:
        return []
    now = {"zone_id": zone["id"], "names": ["bot_management"], _BOT_FIELD: current}
    path = ctx.backup.save(ctx.account, zone["name"], "bot", now)
    with ctx.backup.naming(path):
        ctx.api.put(_bot_path(zone), {_BOT_FIELD: data[_BOT_FIELD]})
    return ["restored\tbot_fight_mode\t%s" % ("on" if data[_BOT_FIELD] else "off"), "backup: " + path]


def register(subparsers):
    parser = subparsers.add_parser("security", help="the protections in place on a zone")
    parser.add_argument("zone", help="zone name or id")
    parser.set_defaults(handler=security, read=True)

    parser = subparsers.add_parser("security-level", help="set the security level")
    parser.add_argument("zone")
    parser.add_argument("level", choices=LEVELS + ("under_attack",))
    parser.set_defaults(handler=security_level)

    parser = subparsers.add_parser("under-attack", help="turn « Under Attack » on, or off back to a level")
    parser.add_argument("zone")
    parser.add_argument("state", choices=("on", "off"))
    parser.add_argument("--level", choices=LEVELS, default="medium", help="the level \"off\" goes back to")
    parser.set_defaults(handler=under_attack)

    parser = subparsers.add_parser("bot-fight", help="turn Bot Fight Mode on or off")
    parser.add_argument("zone")
    parser.add_argument("state", choices=("on", "off"))
    parser.set_defaults(handler=bot_fight)
