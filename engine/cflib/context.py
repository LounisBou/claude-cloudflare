"""What a command handler is given: the config, the account, its API and the
backup module (ctx.backup.save before every zone write)."""

from . import backup as backup_module
from . import http


class Context:
    def __init__(self, config, account, api, backup):
        self.config = config
        self.account = account
        self.api = api
        self.backup = backup


def make(config, name=None):
    """The context of an account, by name or the config's default."""
    account = config.account(name)
    return Context(config, account, http.Api(account), backup_module)
