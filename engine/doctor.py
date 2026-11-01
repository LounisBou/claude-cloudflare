#!/usr/bin/env python3
"""The checks of /cloudflare:doctor that auth-check does not make, run by
install.sh: what an account's token may read and write for the plugin's
commands, and the local Caddy's binary, service and envfile. Only reads.

    doctor.py permissions <account> [token id]
    doctor.py caddy
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cflib import doctor  # noqa: E402

if __name__ == "__main__":
    sys.exit(doctor.main(sys.argv[1:]))
