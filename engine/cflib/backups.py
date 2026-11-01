"""The backups taken before zone writes: list them, and replay one."""

from . import backup, context, errors, fmt


def backups(args, ctx):
    found = backup.list_(getattr(args, "account", None) and args.account.lower(), args.zone)
    if args.json:
        return fmt.as_json(found)
    return fmt.table(found, ["account", "zone", "taken", "kind", "path"])


def restore(args, ctx):
    saved = backup.load(args.path)
    named = getattr(args, "account", None)
    if named and named.lower() != saved["account"]:
        raise errors.UsageError("%s belongs to account %s, not %s" % (args.path, saved["account"], named.lower()))
    replay = backup.RESTORERS.get(saved["kind"])
    if replay is None:
        raise errors.UsageError("no restore for a backup of kind %s" % saved["kind"])
    lines = replay(context.make(ctx.config, saved["account"]), saved)
    if not lines:
        names = ", ".join(saved["data"].get("names") or [saved["zone"]])
        return "nothing to restore: %s already matches the backup" % names
    return "\n".join(lines)


def register(subparsers):
    parser = subparsers.add_parser("backups", help="the backups taken before zone writes")
    parser.add_argument("--zone", help="only this zone's")
    parser.set_defaults(handler=backups, read=True, account_free=True)

    parser = subparsers.add_parser("restore", help="replay a backup")
    parser.add_argument("path", help="a path that backups lists")
    parser.set_defaults(handler=restore, account_free=True)
