"""The zones of an account."""

import re

from . import accounts, errors, fmt

_ZONE_ID = re.compile(r"^[0-9a-f]{32}$")


def find(ctx, zone):
    """A zone of the account, by name or by id."""
    if _ZONE_ID.match(zone):
        return ctx.api.get("/zones/" + zone)
    found = ctx.api.get("/zones", params={"name": zone.lower().rstrip(".")})
    if not found:
        raise errors.UsageError("no zone %s on account %s" % (zone, ctx.account.name))
    return found[0]


def zones(args, ctx):
    # Filtered on the account, so a token that sees several never lists
    # another account's zones as this one's.
    found = ctx.api.get("/zones", params={"account.id": accounts.account_id(ctx)}) or []
    if args.json:
        return fmt.as_json(found)
    rows = [{"name": z.get("name"), "id": z.get("id"), "status": z.get("status"),
             "plan": (z.get("plan") or {}).get("name")} for z in found]
    return fmt.table(rows, ["name", "id", "status", "plan"])


def register(subparsers):
    parser = subparsers.add_parser("zones", help="the zones of the account")
    parser.set_defaults(handler=zones, read=True)
