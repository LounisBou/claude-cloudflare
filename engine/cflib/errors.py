"""Typed failures, each carrying the process exit code it maps to."""


class CfError(Exception):
    code = 1

    def __init__(self, message):
        super().__init__(message)
        self.message = message


class UsageError(CfError):
    code = 2


class ApiError(CfError):
    code = 3


class ConfigError(CfError):
    code = 4


class Refused(CfError):
    """Refused by the zone's plan or quota, or by a safety guard."""

    code = 5


class RolledBack(CfError):
    """A Caddy change failed its checks and was taken back."""

    code = 6


class NotAlive(CfError):
    """Caddy is not alive after a reload and the rollback did not bring it back."""

    code = 7
