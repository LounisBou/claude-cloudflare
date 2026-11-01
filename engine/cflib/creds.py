"""Where each account's credentials are found, and its token.

An account <name> exists when <NAME>_CLOUDFLARE_API_TOKEN is set in the
process environment or in one of the config's env files; the environment
wins. The token itself is read only by token(), at the moment a request
needs it: no other function returns it, and nothing here prints it.
"""

import os
import re

from . import errors

_TOKEN_KEY = re.compile(r"^([A-Za-z0-9]+(?:_[A-Za-z0-9]+)*)_CLOUDFLARE_API_TOKEN$")
# Inside a token, a blank or a control character could end the Authorization
# header and start another one.
_UNSAFE = re.compile(r"[\s\x00-\x1f\x7f-\x9f]")
ENVIRONMENT = "environment"


def read_env_file(path):
    """The KEY=value pairs of a dotenv file; an absent or unreadable file has none."""
    values = {}
    try:
        with open(os.path.expanduser(path), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except (OSError, UnicodeDecodeError):
        return values
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, sep, value = line.partition("=")
        if not sep:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        elif " #" in value:
            value = value.split(" #", 1)[0].rstrip()
        values[key.strip()] = value
    return values


def scan(env_files):
    """{name: {"source", "account_id"}} for every account found, names lowercased."""
    found = {}
    sources = [(path, read_env_file(path)) for path in reversed(env_files)]
    sources.append((ENVIRONMENT, dict(os.environ)))
    # Later sources win: the first env file over the next ones, the
    # environment over every file.
    for source, values in sources:
        for key, value in values.items():
            match = _TOKEN_KEY.match(key)
            if not match or not value:
                continue
            name = match.group(1).lower()
            found[name] = {"source": source, "account_id": None}
    for name, entry in found.items():
        prefix = name.upper() + "_CLOUDFLARE_ACCOUNT_ID"
        for _source, values in sources:
            if values.get(prefix):
                entry["account_id"] = values[prefix]
    return found


def token(account):
    """The API token of an account, from the source it was found in."""
    key = account.name.upper() + "_CLOUDFLARE_API_TOKEN"
    if account.source == ENVIRONMENT:
        value = os.environ.get(key)
    else:
        value = read_env_file(account.source).get(key)
    value = (value or "").strip()
    if not value:
        raise errors.ConfigError("no token for account %s in %s" % (account.name, account.source))
    if _UNSAFE.search(value):
        raise errors.ConfigError(
            "the token of account %s holds a blank or a control character: set it again" % account.name
        )
    return value


def redact(text, secrets):
    """The text with every one of the secrets replaced by [token]."""
    for secret in secrets:
        text = text.replace(secret, "[token]")
    return text


def secrets(env_files):
    """Every Cloudflare token value the process can see, to keep them out of any output."""
    values = set()
    for source in [dict(os.environ)] + [read_env_file(p) for p in env_files]:
        for key, value in source.items():
            if _TOKEN_KEY.match(key) and value.strip():
                values.update((value, value.strip()))
    return values
