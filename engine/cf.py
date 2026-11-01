#!/usr/bin/env python3
"""Cloudflare API calls for the cloudflare plugin: the commands that read.

The commands that write run through cf-write.py instead, the same parser
behind a second entry point, so that a Bash permission rule can tell a read
from a write by the script it names. Each refuses the other's commands.

    cf.py [--account NAME] <command> [arguments]
    cf.py --stdin-json        the request as {"command", "args", "account"}
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cflib import accounts, backup, backups, config, context, creds, dns, errors, stdinjson, zones  # noqa: E402

_MODULES = (accounts, zones, dns, backups)


class _ArgumentParser(argparse.ArgumentParser):
    """Routes argparse's own usage failures through the same exit-code
    mapping as every other usage error, instead of argparse's own exit(2).

    Abbreviated flags are refused: a request on stdin names its flags whole,
    and a prefix must never reach a flag the caller did not name. Subparsers
    inherit this class, so the rule holds for every subcommand.
    """

    def __init__(self, *args, **kwargs):
        kwargs.setdefault("allow_abbrev", False)
        super().__init__(*args, **kwargs)

    def error(self, message):
        self.print_usage(sys.stderr)
        raise errors.UsageError(message)


def build_parser():
    parser = _ArgumentParser(prog="cf.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--account", help="the account by name (default: the config's)")
    subparsers = parser.add_subparsers(dest="command")
    for module in _MODULES:
        module.register(subparsers)
    for sub in subparsers.choices.values():
        # The global flag after the subcommand as well: SUPPRESS keeps the
        # subparser from overwriting the parent's value when it is omitted.
        sub.add_argument("--account", default=argparse.SUPPRESS)
        if sub.get_default("read"):
            sub.add_argument("--json", action="store_true", help="full objects as JSON")
    return parser


def is_read(parser, command):
    """A command not marked as a read is a write: the safe side is the default."""
    subs = [a for a in parser._actions if a.dest == "command"][0].choices
    return bool(subs[command].get_default("read"))


def _command_in(parser, argv):
    subs = [a for a in parser._actions if a.dest == "command"][0].choices
    for item in argv:
        if item == "--":
            return None
        if item in subs:
            return item
    return None


def _redact(text, secrets):
    for secret in secrets:
        text = text.replace(secret, "[token]")
    return text


def _fail(exc, secrets):
    print("cf: " + _redact(exc.message, secrets), file=sys.stderr)
    return exc.code


def run(argv, writes):
    parser = build_parser()
    command = _command_in(parser, argv)
    if command and is_read(parser, command) == writes:
        if writes:
            raise errors.UsageError("%s only reads: use cf.py" % command)
        raise errors.UsageError("%s writes: use cf-write.py" % command)
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_usage(sys.stderr)
        raise errors.UsageError("no command given")
    cfg = config.load_config()
    if getattr(args, "account_free", False):
        ctx = context.Context(cfg, None, None, backup)
    else:
        ctx = context.make(cfg, args.account)
    return args.handler(args, ctx)


def main(argv, writes=False):
    """Run one command; writes is True for the cf-write.py entry point."""
    secrets = set()
    try:
        if argv == ["--stdin-json"]:
            try:
                request = json.loads(sys.stdin.read())
            except ValueError as exc:
                raise errors.UsageError("stdin is not valid JSON: %s" % exc)
            argv = stdinjson.build_argv(build_parser(), request)
        try:
            secrets = creds.secrets(config.load_config().env_files)
        except errors.CfError:
            secrets = creds.secrets([])
        out = run(argv, writes)
    except errors.CfError as exc:
        return _fail(exc, secrets)
    if out:
        print(_redact(out, secrets))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
