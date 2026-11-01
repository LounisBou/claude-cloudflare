#!/usr/bin/env bash
# /cloudflare:install and /cloudflare:doctor: check that the engine can run
# and that every account it finds has a working token.
#
#   install.sh           check, and say how to set an account up when none is found
#   install.sh --check   check only (/cloudflare:doctor)
#
# Tokens are read by the engine alone: this script never reads one into a
# variable, prints it, logs it or writes it anywhere. It lists the accounts
# and runs auth-check for each, whose output names the account, never the token.
set -u

ROOT=$(cd "$(dirname "$0")" && pwd)
CF="$ROOT/engine/cf.py"
MODE=install
[ "${1:-}" = "--check" ] && MODE=check

say() { printf 'cloudflare: %s\n' "$1"; }

fail() {
  printf 'error: %s\n' "$1" >&2
  printf 'fix:   %s\n' "$2" >&2
  exit "$3"
}

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is not installed" "install Python 3.9 or later, then run /cloudflare:doctor" 11
fi
if [ "$(python3 -c 'import sys; print(sys.version_info >= (3, 9))' 2>/dev/null)" != "True" ]; then
  fail "python3 is older than 3.9" "install Python 3.9 or later, then run /cloudflare:doctor" 11
fi
say "$(python3 -c 'import platform; print("python3 " + platform.python_version())')"

# accounts makes no API call and needs no account: it fails only on the config.
listing=$(python3 "$CF" accounts 2>&1)
if [ $? -ne 0 ]; then
  fail "${listing#cf: }" "fix the config file, then run /cloudflare:doctor" 14
fi
names=$(printf '%s\n' "$listing" | sed 1d | cut -f1)

if [ -z "$names" ]; then
  if [ "$MODE" = install ]; then
    {
      echo "cloudflare: to add an account <name>, set <NAME>_CLOUDFLARE_API_TOKEN (and optionally"
      echo "            <NAME>_CLOUDFLARE_ACCOUNT_ID) in the environment or in ~/.env, or in an env"
      echo "            file the config lists under env_files. The config file is"
      echo "            \$CLAUDE_CLOUDFLARE_CONFIG or ~/.config/claude-cloudflare/config.json."
    } >&2
  fi
  fail "no Cloudflare account found" \
    "set <NAME>_CLOUDFLARE_API_TOKEN in the environment or in ~/.env, then run /cloudflare:doctor" 12
fi

code=0
for name in $names; do
  if check=$(python3 "$CF" --account="$name" auth-check 2>&1); then
    status=$(printf '%s\n' "$check" | sed -n 2p | cut -f2)
    say "account $name: $status"
  else
    printf 'cloudflare: account %s: %s\n' "$name" "$check" >&2
    code=13
  fi
done

if [ "$code" -eq 0 ]; then
  echo "cloudflare: all checks passed."
  echo
  echo "Tool available:"
  echo "  cf            Cloudflare API calls from the standard library: accounts,"
  echo "                zones, DNS records, backups and restore"
  echo
  echo "Skill available (where mods do not load):"
  echo "  cf-curl       the same engine from Bash"
  exit 0
fi

echo "cloudflare: not ready. Replace the token named above, then run /cloudflare:doctor." >&2
exit "$code"
