#!/usr/bin/env python3
"""A stand-in for sudo, put first on the engine's PATH by the suite.

Every call is logged, its arguments joined by spaces, as a line of
$FAKE_CADDY_STATE/sudo.log. Only "sudo -n [--preserve-env=NAMES] <command>"
is taken. With FAKE_SUDO=refuse every call is refused as sudo -n refuses one
it may not run without a password. Otherwise the command runs as the user,
with root's reach emulated for cat, tee and cp: the files they name and their
directories are opened to the user for the run, then given their modes back.
"""

import os
import stat
import subprocess
import sys


def main(argv):
    with open(os.path.join(os.environ["FAKE_CADDY_STATE"], "sudo.log"), "a", encoding="utf-8") as fh:
        fh.write(" ".join(argv) + "\n")
    if not argv or argv[0] != "-n":
        print("sudo: a terminal is required to read the password", file=sys.stderr)
        return 1
    argv = argv[1:]
    if argv and argv[0].startswith("--preserve-env="):
        argv = argv[1:]
    if os.environ.get("FAKE_SUDO") == "refuse":
        print("sudo: a password is required", file=sys.stderr)
        return 1
    if os.path.basename(argv[0]) not in ("cat", "tee", "cp"):
        os.execvp(argv[0], argv)
    paths = [a for a in argv[1:] if os.path.isabs(a)]
    opened = {}
    for path in paths + [os.path.dirname(p) for p in paths]:
        if os.path.exists(path) and path not in opened:
            opened[path] = stat.S_IMODE(os.stat(path).st_mode)
            os.chmod(path, opened[path] | stat.S_IRWXU)
    try:
        return subprocess.run(argv).returncode
    finally:
        for path, mode in opened.items():
            os.chmod(path, mode)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
