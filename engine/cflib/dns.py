"""DNS records of a zone: list, read, export, create, update, delete.

A record is named by its id or by its name, relative to the zone ("www",
"@" for the apex) or whole ("www.example.com"). Every write saves the
records of the names it touches first, and restore() replays such a backup.
"""

import argparse
import contextlib
import re

from . import backup, errors, fmt, zones

_RECORD_ID = re.compile(r"^[0-9a-f]{32}$")
PROXIABLE = ("A", "AAAA", "CNAME")
# The fields a record is written with, and compared on by restore.
_WRITTEN = ("type", "name", "content", "ttl", "proxied", "priority", "comment", "tags", "data")
# The fields a record keeps when its type changes: the others belong to the
# old type, and only the arguments given set them for the new one.
_ANY_TYPE = ("name", "ttl", "proxied", "comment", "tags")
COLUMNS = ["type", "name", "content", "proxied", "ttl", "id"]


def fqdn(zone_name, name):
    name = name.strip().lower().rstrip(".")
    if name in ("@", "", zone_name):
        return zone_name
    if name.endswith("." + zone_name):
        return name
    return name + "." + zone_name


def row(record):
    content = record.get("content")
    if record.get("priority") is not None:
        content = "%s %s" % (record["priority"], content)
    ttl = record.get("ttl")
    return {"type": record.get("type"), "name": record.get("name"), "content": content,
            "proxied": bool(record.get("proxied")), "ttl": "auto" if ttl == 1 else ttl,
            "id": record.get("id")}


def line(verb, record):
    """One record as a write prints it: the verb, then the dns-list columns."""
    return fmt.table([dict(row(record), verb=verb)], ["verb"] + COLUMNS).split("\n", 1)[1]


def _records_path(zone):
    return "/zones/%s/dns_records" % zone["id"]


def by_name(ctx, zone, name, rtype=None):
    params = {"name": fqdn(zone["name"], name)}
    if rtype:
        params["type"] = rtype.upper()
    return ctx.api.get(_records_path(zone), params=params) or []


def select(ctx, zone, record, rtype=None):
    """The records a selector names: one by id, or every one of a name."""
    if _RECORD_ID.match(record):
        found = [ctx.api.get(_records_path(zone) + "/" + record)]
    else:
        found = by_name(ctx, zone, record, rtype)
    if rtype:
        found = [r for r in found if r.get("type") == rtype.upper()]
    if not found:
        name = record if _RECORD_ID.match(record) else fqdn(zone["name"], record)
        raise errors.UsageError("no record %s in %s" % (name, zone["name"]))
    return found


def one(ctx, zone, record, rtype=None):
    found = select(ctx, zone, record, rtype)
    if len(found) > 1:
        choices = ", ".join("%s (%s %s %s)" % (r["id"], r["type"], r["name"], row(r)["content"]) for r in found)
        raise errors.UsageError("%d records answer to %s: name one by its id: %s" % (len(found), record, choices))
    return found[0]


def body(record):
    """A record as Cloudflare takes it on a create or an overwrite."""
    out = {}
    for key in _WRITTEN:
        value = record.get(key)
        if value is None or (key == "tags" and not value) or (key == "comment" and value == ""):
            continue
        out[key] = value
    if out.get("type") not in PROXIABLE:
        out.pop("proxied", None)
    return out


def save(ctx, zone, names, types):
    """Back up every record of these names, before a write changes them.
    types: the record types the write touches on each name ({name: [type]}),
    which restore takes back along with the types of the records saved."""
    records = []
    for name in sorted(set(names)):
        records.extend(by_name(ctx, zone, name))
    data = {"zone_id": zone["id"], "names": sorted(set(names)), "records": records,
            "types": {name: sorted(set(found)) for name, found in sorted(types.items())}}
    return ctx.backup.save(ctx.account, zone["name"], "dns", data)


def _held(data):
    """{name: types} a backup holds: its records' and the types its write touched."""
    held = {name: set((data.get("types") or {}).get(name) or ()) for name in data["names"]}
    for record in data["records"]:
        held.setdefault(record["name"], set()).add(record["type"])
    return held


@contextlib.contextmanager
def backed_by(path):
    """A call that fails after its backup was taken names that backup, from
    which the state it started from comes back."""
    try:
        yield
    except errors.ApiError as exc:
        raise errors.ApiError("%s; backup: %s" % (exc.message, path)) from None


# ---- reads ----

def dns_list(args, ctx):
    zone = zones.find(ctx, args.zone)
    params = {}
    if args.type:
        params["type"] = args.type.upper()
    if args.name:
        params["name"] = fqdn(zone["name"], args.name)
    found = ctx.api.get(_records_path(zone), params=params or None) or []
    if args.json:
        return fmt.as_json(found)
    return fmt.table([row(r) for r in found], COLUMNS)


def dns_get(args, ctx):
    zone = zones.find(ctx, args.zone)
    found = select(ctx, zone, args.record, args.type)
    if args.json:
        return fmt.as_json(found)
    return fmt.table([row(r) for r in found], COLUMNS)


def dns_export(args, ctx):
    zone = zones.find(ctx, args.zone)
    if args.json:
        return fmt.as_json(ctx.api.get(_records_path(zone)) or [])
    return ctx.api.get(_records_path(zone) + "/export", raw=True).rstrip("\n")


# ---- writes ----

def _changes(args):
    changes = {}
    for key in ("type", "content", "ttl", "proxied", "priority", "comment"):
        value = getattr(args, key, None)
        if value is not None:
            changes[key] = value.upper() if key == "type" else value
    return changes


def dns_create(args, ctx):
    zone = zones.find(ctx, args.zone)
    record = dict(_changes(args), name=fqdn(zone["name"], args.name))
    record.setdefault("ttl", 1)
    path = save(ctx, zone, [record["name"]], {record["name"]: [record["type"]]})
    with backed_by(path):
        created = ctx.api.post(_records_path(zone), body(record))
    return "%s\nbackup: %s" % (line("created", created), path)


def dns_update(args, ctx):
    zone = zones.find(ctx, args.zone)
    changes = _changes(args)
    if args.name:
        changes["name"] = fqdn(zone["name"], args.name)
    if not changes:
        raise errors.UsageError("nothing to change: pass type, name, content, ttl, proxied, priority or comment")
    current = one(ctx, zone, args.record, args.from_type)
    if changes.get("type", current["type"]) != current["type"]:
        if "content" not in changes:
            raise errors.UsageError("%s changes from %s to %s: pass the --content of the new type"
                                    % (current["name"], current["type"], changes["type"]))
        record = dict({k: current[k] for k in _ANY_TYPE if k in current}, **changes)
    else:
        record = dict(current, **changes)
    moved = [current["type"], record["type"]]
    path = save(ctx, zone, [current["name"], record["name"]], {current["name"]: moved, record["name"]: moved})
    with backed_by(path):
        updated = ctx.api.put(_records_path(zone) + "/" + current["id"], body(record))
    return "%s\n%s\nbackup: %s" % (line("before", current), line("after", updated), path)


def dns_delete(args, ctx):
    zone = zones.find(ctx, args.zone)
    current = one(ctx, zone, args.record, args.type)
    path = save(ctx, zone, [current["name"]], {current["name"]: [current["type"]]})
    with backed_by(path):
        ctx.api.delete(_records_path(zone) + "/" + current["id"])
    return "%s\nbackup: %s" % (line("deleted", current), path)


@backup.restorer("dns")
def restore(ctx, saved):
    """Bring the names of a backup back to the records it holds, on the
    record types it holds: records of those types added since are deleted,
    changed ones overwritten, deleted ones created again (under a new id).
    Records of any other type are kept, and counted. Returns the lines to
    print, a backup of the state it replaces last; no line when nothing
    differs."""
    data = saved["data"]
    zone = {"id": data["zone_id"], "name": saved["zone"]}
    names = data["names"]
    held = _held(data)
    wanted = {r["id"]: r for r in data["records"]}
    current = []
    kept = 0
    for name in names:
        for record in by_name(ctx, zone, name):
            if record["id"] in wanted or record["type"] in held.get(record["name"], ()):
                current.append(record)
            else:
                kept += 1
    deletes = [r for r in current if r["id"] not in wanted]
    now = {r["id"]: r for r in current}
    puts = [r for i, r in wanted.items() if i in now and body(now[i]) != body(r)]
    posts = [r for i, r in wanted.items() if i not in now]
    tail = ["kept: %d record%s of a type the backup does not hold" % (kept, "" if kept == 1 else "s")] if kept else []
    if not (deletes or puts or posts):
        if not tail:
            return []
        return ["nothing to restore: %s already matches the backup" % ", ".join(names)] + tail
    path = save(ctx, zone, names, {name: sorted(held.get(name, ())) for name in names})
    lines = []
    # Deletions first: a CNAME cannot share its name with the records it replaces.
    with backed_by(path):
        for record in deletes:
            ctx.api.delete(_records_path(zone) + "/" + record["id"])
            lines.append(line("deleted", record))
        for record in puts:
            lines.append(line("restored", ctx.api.put(_records_path(zone) + "/" + record["id"], body(record))))
        for record in posts:
            lines.append(line("recreated", ctx.api.post(_records_path(zone), body(record))))
    return lines + tail + ["backup: " + path]


def _proxied(parser):
    parser.add_argument("--proxied", action=argparse.BooleanOptionalAction, default=None,
                        help="through Cloudflare's proxy (--no-proxied: DNS only)")


def _record_fields(parser, required):
    parser.add_argument("--type", required=required, help="A, AAAA, CNAME, MX, TXT…")
    parser.add_argument("--content", required=required)
    parser.add_argument("--ttl", type=int, help="seconds; 1 is automatic (the default)")
    _proxied(parser)
    parser.add_argument("--priority", type=int, help="MX and SRV")
    parser.add_argument("--comment")


def register(subparsers):
    parser = subparsers.add_parser("dns-list", help="the records of a zone")
    parser.add_argument("zone", help="zone name or id")
    parser.add_argument("--type")
    parser.add_argument("--name", help="relative to the zone, @ for the apex")
    parser.set_defaults(handler=dns_list, read=True)

    parser = subparsers.add_parser("dns-get", help="the records of one name, or one record by id")
    parser.add_argument("zone")
    parser.add_argument("record", help="record id, or name")
    parser.add_argument("--type")
    parser.set_defaults(handler=dns_get, read=True)

    parser = subparsers.add_parser("dns-export", help="the zone file of a zone (--json: every record)")
    parser.add_argument("zone")
    parser.set_defaults(handler=dns_export, read=True)

    parser = subparsers.add_parser("dns-create", help="create a record")
    parser.add_argument("zone")
    parser.add_argument("--name", required=True, help="relative to the zone, @ for the apex")
    _record_fields(parser, True)
    parser.set_defaults(handler=dns_create)

    parser = subparsers.add_parser("dns-update", help="change a record, its type included")
    parser.add_argument("zone")
    parser.add_argument("record", help="record id, or name")
    parser.add_argument("--from-type", help="the type of the record to change, when its name has several")
    parser.add_argument("--name", help="a new name")
    _record_fields(parser, False)
    parser.set_defaults(handler=dns_update)

    parser = subparsers.add_parser("dns-delete", help="delete a record")
    parser.add_argument("zone")
    parser.add_argument("record", help="record id, or name")
    parser.add_argument("--type", help="the type of the record, when its name has several")
    parser.set_defaults(handler=dns_delete)

