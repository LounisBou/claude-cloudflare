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

from cflib import (accounts, backup, backups, cache, caddy, caddyctl, certs, config, context, creds, dns,  # noqa: E402
                   errors, iprules, plan, protect, rulesets, security, settings, stdinjson, workers, zones)

_MODULES = (accounts, zones, dns, backups, settings, certs, plan, rulesets, iprules, security, protect, cache, workers,
            caddy)


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
        # One line, as every other error: the usage is in REFERENCE.md.
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


def _redact(text, secrets):
    for secret in secrets:
        text = text.replace(secret, "[token]")
    return text


def _fail(exc, secrets):
    # One line whatever the message holds, Cloudflare's own included.
    print("cf: " + " ".join(_redact(exc.message, secrets).split()), file=sys.stderr)
    return exc.code


def run(argv, writes):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        raise errors.UsageError("no command given; the commands are in engine/REFERENCE.md")
    # The command the parser selected, never a word of argv that looks like
    # one: a flag's value or a positional can be named like any command.
    if is_read(parser, args.command) == writes:
        if writes:
            raise errors.UsageError("%s only reads: use cf.py" % args.command)
        raise errors.UsageError("%s writes: use cf-write.py" % args.command)
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
                text = sys.stdin.buffer.read().decode("utf-8")
            except UnicodeDecodeError:
                raise errors.UsageError("stdin is not UTF-8")
            try:
                request = json.loads(text)
            except ValueError as exc:
                raise errors.UsageError("stdin is not valid JSON: %s" % exc)
            argv = stdinjson.build_argv(build_parser(), request)
        try:
            cfg = config.load_config()
            secrets = creds.secrets(cfg.env_files) | caddyctl.secrets(cfg)
        except errors.CfError:
            secrets = creds.secrets([])
        out = run(argv, writes)
        if out:
            print(_redact(out, secrets))
    except errors.CfError as exc:
        return _fail(exc, secrets)
    except Exception as exc:
        # Never a traceback: it could quote a token, and the caller reads one
        # line. The type alone says where to look.
        return _fail(errors.CfError("internal error: %s" % type(exc).__name__), secrets)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
