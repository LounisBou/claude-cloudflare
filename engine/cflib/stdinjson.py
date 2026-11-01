"""Build a cf.py argument vector from one JSON request read on stdin.

The mod sends {"command", "args", "account"} instead of an argument vector,
so the mapping from names to positionals and flags lives here, next to the
parser it reads, and nothing outside the engine keeps a second copy of it.

Every value lands either as a positional after "--" or glued to its flag as
"--name=value", so no value can be read as an option.
"""

import argparse

from . import errors


def _scalar(key, value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise errors.UsageError('"%s" takes a string or a number' % key)
    return str(value)


def _positional(sub, key):
    for action in sub._actions:
        if not action.option_strings and action.dest == key:
            return action
    return None


def _option(sub, key):
    wanted = "--" + key
    for action in sub._actions:
        if wanted in action.option_strings:
            return action
    return None


def build_argv(parser, request):
    if not isinstance(request, dict):
        raise errors.UsageError("stdin must hold a JSON object")
    command = request.get("command")
    args = request.get("args") or {}
    account = request.get("account")
    subs = [a for a in parser._actions if a.dest == "command"][0].choices
    if not isinstance(command, str) or command not in subs:
        raise errors.UsageError("unknown command: %s" % command)
    if not isinstance(args, dict):
        raise errors.UsageError('"args" must be an object')
    sub = subs[command]

    flags = []
    values = {}
    for key, value in args.items():
        if value is None:
            continue
        positional = _positional(sub, key)
        option = _option(sub, key) if key not in ("help", "account") else None
        if positional is not None:
            if positional.nargs in ("+", "*"):
                items = value if isinstance(value, list) else [value]
                values[key] = [_scalar(key, v) for v in items]
            elif isinstance(value, list):
                raise errors.UsageError('"%s" takes a single value, not an array' % key)
            else:
                values[key] = [_scalar(key, value)]
        elif option is not None:
            if isinstance(option, (argparse._StoreTrueAction, argparse.BooleanOptionalAction)):
                if not isinstance(value, bool):
                    raise errors.UsageError('"%s" takes true or false' % key)
                if value:
                    flags.append("--" + key)
                elif isinstance(option, argparse.BooleanOptionalAction):
                    flags.append("--no-" + key)
            elif isinstance(option, argparse._AppendAction):
                items = value if isinstance(value, list) else [value]
                flags.extend("--%s=%s" % (key, _scalar(key, v)) for v in items)
            elif isinstance(value, list):
                raise errors.UsageError('"%s" takes a single value, not an array' % key)
            else:
                flags.append("--%s=%s" % (key, _scalar(key, value)))
        else:
            raise errors.UsageError('unknown argument "%s" for %s' % (key, command))

    positionals = []
    for action in sub._actions:
        if action.option_strings:
            continue
        got = values.get(action.dest)
        if not got:
            if action.nargs in ("?", "*"):
                continue
            raise errors.UsageError('missing argument "%s" for %s' % (action.dest, command))
        positionals.extend(got)

    argv = [command] + flags
    if account is not None:
        if not isinstance(account, str):
            raise errors.UsageError('"account" takes a string')
        argv.append("--account=" + account)
    # "--" with nothing after it is itself refused by argparse.
    return argv + (["--"] + positionals if positionals else [])
