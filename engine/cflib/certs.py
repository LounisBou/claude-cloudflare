"""The edge certificate packs of a zone and their status."""

from . import fmt, zones


def _expires(pack):
    dates = [c.get("expires_on") for c in pack.get("certificates") or [] if c.get("expires_on")]
    return max(dates) if dates else None


def certs(args, ctx):
    zone = zones.find(ctx, args.zone)
    found = ctx.api.get("/zones/%s/ssl/certificate_packs" % zone["id"], params={"status": "all"}) or []
    if args.json:
        return fmt.as_json(found)
    rows = [{"id": p.get("id"), "type": p.get("type"), "status": p.get("status"),
             "hosts": ",".join(p.get("hosts") or []), "expires": _expires(p),
             "authority": p.get("certificate_authority")} for p in found]
    return fmt.table(rows, ["id", "type", "status", "hosts", "expires", "authority"])


def register(subparsers):
    parser = subparsers.add_parser("certs", help="the edge certificate packs of a zone and their status")
    parser.add_argument("zone", help="zone name or id")
    parser.set_defaults(handler=certs, read=True)
