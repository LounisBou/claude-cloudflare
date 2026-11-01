"""The machine-local config file and the accounts it makes known.

$CLAUDE_CLOUDFLARE_CONFIG, else ~/.config/claude-cloudflare/config.json. Every
key is optional, and an absent file is an empty one. Nothing machine-specific
lives in the repository: zones, addresses and paths are read from here.
"""

import json
import os

from . import creds, errors

DEFAULT_PATH = "~/.config/claude-cloudflare/config.json"
DEFAULT_ENV_FILES = ["~/.env"]
DEFAULT_BACKUP_DIR = "~/.local/share/claude-cloudflare/backups"


class Account:
    """An account by name. It holds where its token is, never the token."""

    def __init__(self, name, source, account_id=None):
        self.name = name
        self.source = source
        self.account_id = account_id


class Config:
    def __init__(self, path, data):
        self.path = path
        self.data = data
        self.default_account = _typed(data, "default_account", str, None, path)
        self.env_files = _typed(data, "env_files", list, DEFAULT_ENV_FILES, path)
        if not all(isinstance(p, str) for p in self.env_files):
            raise errors.ConfigError("%s: env_files must be a list of paths" % path)
        self.backup_dir = os.path.expanduser(_typed(data, "backup_dir", str, DEFAULT_BACKUP_DIR, path))
        self.default_target = _typed(data, "default_target", str, None, path)
        self.caddy = _typed(data, "caddy", dict, {}, path)

    def accounts(self):
        """{name: Account} for every account found, in name order."""
        found = creds.scan(self.env_files)
        return {
            name: Account(name, entry["source"], entry["account_id"])
            for name, entry in sorted(found.items())
        }

    def account(self, name=None):
        known = self.accounts()
        if name:
            wanted = name.lower()
            if wanted not in known:
                raise errors.ConfigError("no account %s; known: %s" % (wanted, ", ".join(known) or "none"))
            return known[wanted]
        if self.default_account:
            return self.account(self.default_account)
        if len(known) == 1:
            return next(iter(known.values()))
        if not known:
            raise errors.ConfigError(
                "no Cloudflare account: set <NAME>_CLOUDFLARE_API_TOKEN in the environment "
                "or in an env file (%s)" % ", ".join(self.env_files)
            )
        raise errors.ConfigError("several accounts (%s): pass one or set default_account" % ", ".join(known))


def _typed(data, key, kind, default, path):
    value = data.get(key)
    if value is None:
        return default
    if not isinstance(value, kind):
        raise errors.ConfigError("%s: %s must be a %s" % (path, key, kind.__name__))
    return value


def config_path():
    return os.path.expanduser(os.environ.get("CLAUDE_CLOUDFLARE_CONFIG") or DEFAULT_PATH)


def load_config():
    path = config_path()
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return Config(path, {})
    except OSError as exc:
        raise errors.ConfigError("cannot read %s: %s" % (path, exc.strerror))
    try:
        data = json.loads(raw)
    except ValueError as exc:
        raise errors.ConfigError("%s is not valid JSON: %s" % (path, exc))
    if not isinstance(data, dict):
        raise errors.ConfigError("%s must hold a JSON object" % path)
    return Config(path, data)
