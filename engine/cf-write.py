#!/usr/bin/env python3
"""Cloudflare API calls for the cloudflare plugin: the commands that write.

The same parser as cf.py, which runs the commands that read. Each entry point
refuses the other's commands, so that a Bash permission rule can tell a write
from a read by the script it names.

    cf-write.py [--account NAME] <command> [arguments]
    cf-write.py --stdin-json  the request as {"command", "args", "account"}
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cf  # noqa: E402

if __name__ == "__main__":
    sys.exit(cf.main(sys.argv[1:], writes=True))
