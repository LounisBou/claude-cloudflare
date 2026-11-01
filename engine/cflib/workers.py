"""Workers: the account's scripts, a zone's routes and the custom domains.

A script is uploaded as an ES module (multipart: a metadata part naming the
main module, and the module itself). An upload over a script keeps its
bindings, its secrets among them, and its compatibility flags. What a write is
about to overwrite or delete is saved first: a script's main module, its name
and content, under the "workers" directory of the account's backups, a zone's
routes under the zone's; a script whose content is more than its main module
cannot be saved whole, and is not overwritten or deleted. restore replays
both. Workers KV, R2, secrets and bindings are not managed here.
"""

import datetime
import email.parser
import email.policy
import json
import os
import re

from . import accounts, backup, errors, fmt, guard, protect, quotas, zones

_NAME = re.compile(r"^[A-Za-z0-9_-]{1,63}$")
_MODULE = re.compile(r"^[A-Za-z0-9_.-]+\.m?js$")
# Where an account's script backups live: not a zone name, which has a dot.
BACKUP_DIR = "workers"
MODULE_TYPE = "application/javascript+module"
# A service worker's script part: a script whose content is plain text.
SCRIPT_TYPE = "application/javascript"
# What a restored service worker's part is called: the content alone is saved.
RESTORED_MODULE = "worker.js"


def _base(ctx):
    return "/accounts/%s/workers" % accounts.account_id(ctx)


def scripts(ctx):
    return ctx.api.get(_base(ctx) + "/scripts") or []


def find_script(ctx, name):
    return next((s for s in scripts(ctx) if s.get("id") == name), None)


def require_script(ctx, name):
    script = find_script(ctx, name)
    if script is None:
        raise errors.UsageError("no Worker %s on account %s" % (name, ctx.account.name))
    return script


def _name(name):
    if not _NAME.match(name):
        raise errors.UsageError("%s is not a script name: letters, digits, - and _" % name)
    return name


def _unfaithful(name, reason):
    raise errors.Refused("cannot save the Worker %s faithfully: %s; nothing was changed" % (name, reason))


def _content(ctx, name):
    """The script's code as content/v2 gives it: (main module, content). A
    module Worker's is multipart, its main module named by the cf-entrypoint
    header; a service worker's is plain text, with no main module (None).
    Content that cannot be saved whole is refused (exit 5)."""
    headers, answer = ctx.api.get_content("%s/scripts/%s/content/v2" % (_base(ctx), name))
    ctype = headers.get("Content-Type") or ""
    module = None
    if ctype.lower().startswith("multipart/form-data"):
        module = headers.get("cf-entrypoint")
        if not module:
            _unfaithful(name, "its multipart content names no main module (cf-entrypoint)")
        form = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
            b"Content-Type: " + ctype.encode("latin-1") + b"\r\n\r\n" + answer)
        parts = list(form.iter_parts()) if form.is_multipart() else []
        if len(parts) != 1:
            _unfaithful(name, "its content holds %d parts, not its main module alone" % len(parts))
        part = parts[0]
        if part.get_param("name", header="content-disposition") != module or part.get_content_type() != MODULE_TYPE:
            _unfaithful(name, "its one part is not the ES module %s" % module)
        answer = part.get_payload(decode=True)
    try:
        return module, answer.decode("utf-8")
    except UnicodeDecodeError:
        _unfaithful(name, "its content is not UTF-8 text")


def _kept(ctx, script):
    """What an upload over the script carries so that the script keeps its
    bindings, secrets included (keep_bindings: the types of the bindings
    Cloudflare keeps from the previous upload), and its compatibility flags
    (which an upload replaces)."""
    settings = ctx.api.get("%s/scripts/%s/settings" % (_base(ctx), script["id"])) or {}
    kept = {}
    types = sorted({b["type"] for b in settings.get("bindings") or [] if b.get("type")})
    if types:
        kept["keep_bindings"] = types
    if script.get("compatibility_flags"):
        kept["compatibility_flags"] = script["compatibility_flags"]
    return kept


def _save_script(ctx, script, module, content):
    return ctx.backup.save(ctx.account, BACKUP_DIR, "worker", {
        "account_id": accounts.account_id(ctx), "name": script["id"], "main_module": module,
        "content": content, "compatibility_date": script.get("compatibility_date")})


def _upload(ctx, name, module, content, date, kept):
    """Upload the script: an ES module named module, or a service worker when
    module is None; kept is what _kept gave for the script it replaces."""
    meta = dict(kept, compatibility_date=date)
    if module:
        meta["main_module"] = module
        part = (module, module, MODULE_TYPE)
    else:
        meta["body_part"] = RESTORED_MODULE
        part = (RESTORED_MODULE, RESTORED_MODULE, SCRIPT_TYPE)
    return ctx.api.put_form("%s/scripts/%s" % (_base(ctx), name), [
        ("metadata", None, "application/json", json.dumps(meta).encode()), part + (content.encode(),)])


# ---- scripts ----

def workers(args, ctx):
    found = scripts(ctx)
    if args.json:
        return fmt.as_json(found)
    return fmt.table([{"name": s.get("id"), "modified": s.get("modified_on"),
                       "compatibility_date": s.get("compatibility_date")} for s in found],
                     ["name", "modified", "compatibility_date"])


def worker_deploy(args, ctx):
    name = _name(args.name)
    module = os.path.basename(args.file)
    if not _MODULE.match(module):
        raise errors.UsageError("%s is not a .js or .mjs module" % args.file)
    try:
        with open(args.file, encoding="utf-8") as fh:
            content = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise errors.UsageError("cannot read %s: %s" % (args.file, getattr(exc, "strerror", None) or exc))
    current = find_script(ctx, name)
    lines = []
    path = None
    kept = {}
    if current:
        saved = _content(ctx, name)
        kept = _kept(ctx, current)
        path = _save_script(ctx, current, *saved)
    date = args.compatibility_date or (current or {}).get("compatibility_date") \
        or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    if path:
        guard.after_backup(path, _upload, ctx, name, module, content, date, kept)
    else:
        _upload(ctx, name, module, content, date, kept)
    lines.append("deployed\t%s\t%s" % (name, date))
    if path:
        lines.append("backup: " + path)
    return "\n".join(lines)


def worker_delete(args, ctx):
    name = _name(args.name)
    script = require_script(ctx, name)
    path = _save_script(ctx, script, *_content(ctx, name))
    guard.after_backup(path, ctx.api.delete, "%s/scripts/%s" % (_base(ctx), name))
    return "deleted\t%s\nbackup: %s" % (name, path)


@backup.restorer("worker")
def restore_worker(ctx, saved):
    """Upload the saved script over the current one; no line when it already is."""
    data = saved["data"]
    name = data["name"]
    module = data.get("main_module", RESTORED_MODULE)
    current = find_script(ctx, name)
    lines = []
    kept = {}
    if current:
        have = _content(ctx, name)
        if have == (module, data["content"]):
            return []
        kept = _kept(ctx, current)
        lines.append("backup: " + _save_script(ctx, current, *have))
    date = data.get("compatibility_date") or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    _upload(ctx, name, module, data["content"], date, kept)
    return ["restored\t%s\t%s" % (name, date)] + lines


# ---- routes ----

def _routes_path(zone):
    return "/zones/%s/workers/routes" % zone["id"]


def _route_line(verb, route):
    return "%s\t%s\t%s\t%s" % (verb, route.get("id"), route.get("pattern"), route.get("script") or "-")


def _save_routes(ctx, zone, routes):
    return ctx.backup.save(ctx.account, zone["name"], "worker-routes", {"zone_id": zone["id"], "routes": routes})


def worker_routes(args, ctx):
    zone = zones.find(ctx, args.zone)
    found = ctx.api.get(_routes_path(zone)) or []
    if args.json:
        return fmt.as_json(found)
    return fmt.table(found, ["id", "pattern", "script"])


def worker_route_add(args, ctx):
    zone = zones.find(ctx, args.zone)
    host = args.pattern.split("/")[0].lstrip("*").lstrip(".").lower()
    if not host or not (host == zone["name"] or host.endswith("." + zone["name"])):
        raise errors.UsageError("%s is not a route of %s" % (args.pattern, zone["name"]))
    require_script(ctx, _name(args.script))
    path = _save_routes(ctx, zone, ctx.api.get(_routes_path(zone)) or [])
    made = guard.after_backup(path, ctx.api.post, _routes_path(zone), {"pattern": args.pattern, "script": args.script})
    return "%s\nbackup: %s" % (_route_line("created", made), path)


def worker_route_delete(args, ctx):
    zone = zones.find(ctx, args.zone)
    routes = ctx.api.get(_routes_path(zone)) or []
    current = next((r for r in routes if args.route in (r.get("id"), r.get("pattern"))), None)
    if current is None:
        raise errors.UsageError("no route %s in %s" % (args.route, zone["name"]))
    path = _save_routes(ctx, zone, routes)
    guard.after_backup(path, ctx.api.delete, "%s/%s" % (_routes_path(zone), current["id"]))
    return "%s\nbackup: %s" % (_route_line("deleted", current), path)


@backup.restorer("worker-routes")
def restore_routes(ctx, saved):
    """Bring the zone's routes back to the saved ones: routes added since are
    deleted, deleted ones created again (under a new id)."""
    data = saved["data"]
    zone = {"id": data["zone_id"], "name": saved["zone"]}
    current = ctx.api.get(_routes_path(zone)) or []
    wanted = {(r["pattern"], r.get("script")) for r in data["routes"]}
    have = {(r["pattern"], r.get("script")) for r in current}
    deletes = [r for r in current if (r["pattern"], r.get("script")) not in wanted]
    posts = [r for r in data["routes"] if (r["pattern"], r.get("script")) not in have]
    if not (deletes or posts):
        return []
    path = _save_routes(ctx, zone, current)
    lines = []
    for route in deletes:
        ctx.api.delete("%s/%s" % (_routes_path(zone), route["id"]))
        lines.append(_route_line("deleted", route))
    for route in posts:
        # A route that runs no script is sent without one, not with a null.
        body = {"pattern": route["pattern"]}
        if route.get("script"):
            body["script"] = route["script"]
        lines.append(_route_line("recreated", ctx.api.post(_routes_path(zone), body)))
    return lines + ["backup: " + path]


# ---- custom domains ----

def worker_domain_add(args, ctx):
    zone, _ = protect.resolve(ctx, args.hostname)
    hostname = args.hostname.strip().lower().rstrip(".")
    require_script(ctx, _name(args.script))
    path = "%s/domains" % _base(ctx)
    # A hostname already attached to another Worker is refused, not taken over:
    # the attachment it had could not be put back.
    for have in ctx.api.get(path, params={"hostname": hostname}) or []:
        if have.get("hostname") == hostname:
            if have.get("service") == args.script:
                return "unchanged\t%s\t%s" % (hostname, args.script)
            quotas.refuse(zone, "%s is already attached to the Worker %s" % (hostname, have.get("service")))
    ctx.api.put(path, {"hostname": hostname, "service": args.script, "zone_id": zone["id"], "zone_name": zone["name"]})
    return "attached\t%s\t%s" % (hostname, args.script)


def register(subparsers):
    parser = subparsers.add_parser("workers", help="the Worker scripts of the account")
    parser.set_defaults(handler=workers, read=True)

    parser = subparsers.add_parser("worker-routes", help="the Worker routes of a zone")
    parser.add_argument("zone", help="zone name or id")
    parser.set_defaults(handler=worker_routes, read=True)

    parser = subparsers.add_parser("worker-deploy", help="upload a script as an ES module")
    parser.add_argument("name", help="the script's name")
    parser.add_argument("--file", required=True, help="the module, a .js or .mjs file")
    parser.add_argument("--compatibility-date", help="YYYY-MM-DD (default: the script's, else today)")
    parser.set_defaults(handler=worker_deploy)

    parser = subparsers.add_parser("worker-delete", help="delete a script, its content saved first")
    parser.add_argument("name")
    parser.set_defaults(handler=worker_delete)

    parser = subparsers.add_parser("worker-route-add", help="run a script on the requests matching a pattern")
    parser.add_argument("zone")
    parser.add_argument("pattern", help="e.g. app.example.com/*")
    parser.add_argument("script")
    parser.set_defaults(handler=worker_route_add)

    parser = subparsers.add_parser("worker-route-delete", help="delete a route")
    parser.add_argument("zone")
    parser.add_argument("route", help="route id or pattern, as worker-routes prints them")
    parser.set_defaults(handler=worker_route_delete)

    parser = subparsers.add_parser("worker-domain-add", help="serve a hostname from a script (custom domain)")
    parser.add_argument("hostname", help="a host of one of the account's zones")
    parser.add_argument("script")
    parser.set_defaults(handler=worker_domain_add)
