"""Zone settings (/zones/:id/settings, read generically) and Universal SSL.

Every write saves the settings it changes first, and restore() replays such
a backup. security_level is changed through security-level and under-attack
only, so that the emergency mode keeps its own permission ask.
"""

import json
import re

from . import backup, errors, fmt, zones

# Values Cloudflare takes, for the settings the plugin knows. Any other
# setting is sent as given and Cloudflare judges it.
ENUMS = {
    "ssl": ("off", "flexible", "full", "strict"),
    "min_tls_version": ("1.0", "1.1", "1.2", "1.3"),
    "tls_1_3": ("on", "off", "zrt"),
    "always_use_https": ("on", "off"),
    "automatic_https_rewrites": ("on", "off"),
    "browser_check": ("on", "off"),
    "security_level": ("essentially_off", "low", "medium", "high", "under_attack"),
}
_ID = re.compile(r"[a-z0-9_]+")


def setting_id(text):
    """A setting id, lower-cased; refused before it reaches a path when it is
    not one (a / or .. would reach any zone path)."""
    setting = text.lower()
    if not _ID.fullmatch(setting):
        raise errors.UsageError("%s is not a setting id (letters, digits and _)" % text)
    return setting


def _path(zone, setting=None):
    base = "/zones/%s/settings" % zone["id"]
    return base + "/" + setting if setting else base


def _compact(value):
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True, separators=(",", ":"))
    return value


def coerce(text):
    """A setting's value from the command line: a number, an object or a list
    as JSON, anything else as the string it is."""
    text = text.strip()
    if text.lstrip("-").isdigit() or text[:1] in ("{", "["):
        try:
            return json.loads(text)
        except ValueError:
            raise errors.UsageError("%s is not valid JSON" % text)
    return text


def save(ctx, zone, values):
    data = {"zone_id": zone["id"], "names": sorted(values), "settings": values}
    return ctx.backup.save(ctx.account, zone["name"], "setting", data)


def apply(ctx, zone, setting, value):
    """Set one setting: the lines to print. A setting already at the value
    is left alone, with no backup."""
    allowed = ENUMS.get(setting)
    if allowed and value not in allowed:
        raise errors.UsageError("%s takes %s" % (setting, ", ".join(allowed)))
    current = ctx.api.get(_path(zone, setting))["value"]
    if current == value:
        return "unchanged\t%s\t%s" % (setting, fmt.cell(_compact(value)))
    path = save(ctx, zone, {setting: current})
    with ctx.backup.naming(path):
        ctx.api.patch(_path(zone, setting), {"value": value})
    return "changed\t%s\t%s\t%s\nbackup: %s" % (
        setting, fmt.cell(_compact(current)), fmt.cell(_compact(value)), path)


# ---- reads ----

def settings(args, ctx):
    setting = setting_id(args.setting) if args.setting else None
    zone = zones.find(ctx, args.zone)
    if setting:
        found = [ctx.api.get(_path(zone, setting))]
    else:
        found = ctx.api.get(_path(zone)) or []
    if args.json:
        return fmt.as_json(found)
    return fmt.table([{"id": s.get("id"), "value": _compact(s.get("value")), "editable": s.get("editable")}
                      for s in found], ["id", "value", "editable"])


# ---- writes ----

def setting_set(args, ctx):
    setting = setting_id(args.setting)
    if setting == "security_level":
        raise errors.UsageError("security_level is set with security-level, or under-attack for the emergency mode")
    return apply(ctx, zones.find(ctx, args.zone), setting, coerce(args.value))


def _universal(zone):
    return "/zones/%s/ssl/universal/settings" % zone["id"]


def universal_ssl(args, ctx):
    zone = zones.find(ctx, args.zone)
    wanted = args.state == "on"
    current = ctx.api.get(_universal(zone))["enabled"]
    if current == wanted:
        return "unchanged\tuniversal_ssl\t%s" % args.state
    data = {"zone_id": zone["id"], "names": ["universal_ssl"], "enabled": current}
    path = ctx.backup.save(ctx.account, zone["name"], "universal-ssl", data)
    with ctx.backup.naming(path):
        ctx.api.patch(_universal(zone), {"enabled": wanted})
    return "changed\tuniversal_ssl\t%s\t%s\nbackup: %s" % (
        "on" if current else "off", args.state, path)


@backup.restorer("setting")
def restore(ctx, saved):
    data = saved["data"]
    zone = {"id": data["zone_id"], "name": saved["zone"]}
    for setting in data["settings"]:
        setting_id(setting)
    changes = {}
    for setting, value in data["settings"].items():
        current = ctx.api.get(_path(zone, setting))["value"]
        if current != value:
            changes[setting] = current
    if not changes:
        return []
    path = save(ctx, zone, changes)
    lines = []
    with ctx.backup.naming(path):
        for setting in sorted(changes):
            ctx.api.patch(_path(zone, setting), {"value": data["settings"][setting]})
            lines.append("restored\t%s\t%s" % (setting, fmt.cell(_compact(data["settings"][setting]))))
    return lines + ["backup: " + path]


@backup.restorer("universal-ssl")
def restore_universal(ctx, saved):
    data = saved["data"]
    zone = {"id": data["zone_id"], "name": saved["zone"]}
    if ctx.api.get(_universal(zone))["enabled"] == data["enabled"]:
        return []
    now = {"zone_id": zone["id"], "names": ["universal_ssl"], "enabled": not data["enabled"]}
    path = ctx.backup.save(ctx.account, zone["name"], "universal-ssl", now)
    with ctx.backup.naming(path):
        ctx.api.patch(_universal(zone), {"enabled": data["enabled"]})
    return ["restored\tuniversal_ssl\t%s" % ("on" if data["enabled"] else "off"), "backup: " + path]


def register(subparsers):
    parser = subparsers.add_parser("settings", help="the zone's settings, or one of them")
    parser.add_argument("zone", help="zone name or id")
    parser.add_argument("setting", nargs="?", help="a setting id (ssl, min_tls_version, tls_1_3…)")
    parser.set_defaults(handler=settings, read=True)

    parser = subparsers.add_parser("setting-set", help="change a zone setting")
    parser.add_argument("zone")
    parser.add_argument("setting", help="a setting id (ssl, min_tls_version, tls_1_3, always_use_https…)")
    parser.add_argument("value", help="the value: on, off, full, 1.2…; a number or an object as JSON")
    parser.set_defaults(handler=setting_set)

    parser = subparsers.add_parser("universal-ssl", help="turn Universal SSL on or off")
    parser.add_argument("zone")
    parser.add_argument("state", choices=("on", "off"))
    parser.set_defaults(handler=universal_ssl)
