"""Writes that name their backup when they fail."""

from . import errors


def after_backup(path, call, *args, **kwargs):
    """Run the call that follows a backup. An API failure then also says where
    the backup is, so the person can replay it."""
    try:
        return call(*args, **kwargs)
    except errors.ApiError as exc:
        raise errors.ApiError("%s; backup: %s" % (exc.message, path)) from exc
