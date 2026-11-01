"""Backups taken before every zone write, and the commands that list and
replay them.

A backup is backup_dir/<account>/<zone>/<UTC timestamp>-<kind>.json, private
to its owner, holding {"account", "zone", "kind", "taken", "data"}. "data" is
what the write is about to change, in the shape the kind's restorer reads.
"""

import contextlib
import datetime
import json
import os

from . import config, errors

# kind -> function(ctx, saved) -> str, registered by the domain modules
# (restorer below), so that restore replays any kind without knowing it.
RESTORERS = {}

_STAMP = "%Y%m%dT%H%M%S.%fZ"


def restorer(kind):
    def register(fn):
        RESTORERS[kind] = fn
        return fn

    return register


def _root():
    return config.load_config().backup_dir


def _name(account):
    return getattr(account, "name", account)


def _private_dirs(path):
    os.makedirs(path, mode=0o700, exist_ok=True)


def save(account, zone, kind, obj):
    """Write the backup and return its path. A backup that cannot be written
    stops the write it was taken for."""
    taken = datetime.datetime.now(datetime.timezone.utc)
    directory = os.path.join(_root(), _name(account), zone)
    payload = {"account": _name(account), "zone": zone, "kind": kind,
               "taken": taken.strftime("%Y-%m-%dT%H:%M:%SZ"), "data": obj}
    try:
        _private_dirs(directory)
        while True:
            path = os.path.join(directory, "%s-%s.json" % (taken.strftime(_STAMP), kind))
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                break
            except FileExistsError:
                taken += datetime.timedelta(microseconds=1)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=1, sort_keys=True)
            fh.write("\n")
    except OSError as exc:
        raise errors.ConfigError("cannot write the backup in %s: %s; nothing was changed" % (directory, exc.strerror))
    return path


@contextlib.contextmanager
def naming(path):
    """Around the write a backup was taken for: its failure names the backup,
    which holds the state the write meant to change."""
    try:
        yield
    except errors.CfError as exc:
        exc.message = "%s; backup: %s" % (exc.message, path)
        raise


def list_(account=None, zone=None):
    """Every backup, oldest first, as {"account", "zone", "taken", "kind", "path"}."""
    root = _root()
    found = []
    if not os.path.isdir(root):
        return found
    for acc in sorted(os.listdir(root)):
        if account and acc != _name(account):
            continue
        acc_dir = os.path.join(root, acc)
        if not os.path.isdir(acc_dir):
            continue
        for zone_name in sorted(os.listdir(acc_dir)):
            if zone and zone_name != zone:
                continue
            zone_dir = os.path.join(acc_dir, zone_name)
            if not os.path.isdir(zone_dir):
                continue
            for name in sorted(os.listdir(zone_dir)):
                stamp, sep, rest = name.partition("-")
                if not sep or not rest.endswith(".json"):
                    continue
                found.append({"account": acc, "zone": zone_name, "taken": stamp,
                              "kind": rest[:-len(".json")], "path": os.path.join(zone_dir, name)})
    return found


def load(path):
    """A backup file, refused unless it lies under the backup directory and
    holds what save() writes."""
    root = os.path.realpath(_root())
    real = os.path.realpath(os.path.expanduser(path))
    if os.path.commonpath([root, real]) != root:
        raise errors.UsageError("%s is not a backup: backups live in %s" % (path, root))
    try:
        with open(real, encoding="utf-8") as fh:
            saved = json.load(fh)
    except FileNotFoundError:
        raise errors.UsageError("no backup at %s" % path)
    except (OSError, ValueError) as exc:
        raise errors.UsageError("cannot read the backup %s: %s" % (path, exc))
    if not isinstance(saved, dict) or not all(k in saved for k in ("account", "zone", "kind", "data")):
        raise errors.UsageError("%s is not a backup this engine wrote" % path)
    return saved
