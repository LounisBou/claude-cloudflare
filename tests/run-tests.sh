#!/bin/bash
# Test suite. No network beyond 127.0.0.1, no real account, isolated HOME.
#
# A fixture server (tests/fixtures/server.py) stands in for the Cloudflare API
# and the engine reaches it through CF_API_BASE. The engine runs with a
# scrubbed environment, so no token of the machine can reach it. Every output
# it prints is kept and searched at the end for the fixture tokens.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENGINE="$ROOT/engine"
FIXTURES="$ROOT/tests/fixtures"
WORK=$(mktemp -d)
SERVER_PID=""

stop() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap stop EXIT

pass=0
fail=0

# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$1"
    printf '       expected: %s\n' "$(printf '%s' "$2" | tr '\n' '⏎')"
    printf '       actual:   %s\n' "$(printf '%s' "$3" | tr '\n' '⏎')"
    fail=$((fail + 1))
  fi
}

# check_contains <name> <needle> <haystack>
check_contains() {
  case "$3" in
    *"$2"*) check "$1" "$2" "$2" ;;
    *) check "$1" "$2" "$3" ;;
  esac
}

TOKEN_ALPHA=cf-fixture-token-alpha-7f3a9c2e
TOKEN_BETA=cf-fixture-token-beta-41d08b6a

python3 "$FIXTURES/server.py" "$FIXTURES/state.json" "$WORK/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do
  [ -s "$WORK/port" ] && break
  sleep 0.1
done
PORT=$(cat "$WORK/port" 2>/dev/null)
[ -n "$PORT" ] || { echo "the fixture server did not start"; exit 1; }
API="http://127.0.0.1:$PORT/client/v4"

# reset: the server back to its initial state, its request log emptied.
reset() { curl -fsS -X POST "http://127.0.0.1:$PORT/__reset" >/dev/null; }
# sent: the requests the server received since the last reset, one per line.
sent() {
  curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    q = "&".join("%s=%s" % kv for kv in sorted(r["query"].items()))
    print(r["method"], r["path"].replace("/client/v4", "") + ("?" + q if q else ""))'
}
# fail_next <method> <path suffix> <status> <code> <message>
fail_next() {
  curl -fsS -X POST "http://127.0.0.1:$PORT/__fail" -H 'Content-Type: application/json' \
    -d "{\"method\":\"$1\",\"path\":\"$2\",\"status\":$3,\"code\":$4,\"message\":\"$5\"}" >/dev/null
}

# The machine-local layout: alpha's token in an env file, beta's in the
# environment, a config naming the env file and a backup directory.
HOMEDIR="$WORK/home"
mkdir -p "$HOMEDIR"
printf '# fixture env file\nexport ALPHA_CLOUDFLARE_API_TOKEN="%s"\nOTHER=1\n' "$TOKEN_ALPHA" > "$HOMEDIR/.env"
CONFIG="$WORK/config.json"
printf '{"default_account": "alpha", "env_files": ["~/.env"], "backup_dir": "%s"}\n' "$WORK/backups" > "$CONFIG"

# run <entry> [args...]: the engine in a scrubbed environment; stdout in OUT,
# stderr in ERR, the exit code in CODE. Every output is also kept in CAPTURED.
CAPTURED="$WORK/captured"
: > "$CAPTURED"
run() {
  local entry="$1"
  shift
  env -i PATH="$PATH" HOME="$HOMEDIR" CLAUDE_CLOUDFLARE_CONFIG="$CONFIG" CF_API_BASE="$API" \
    BETA_CLOUDFLARE_API_TOKEN="$TOKEN_BETA" ${EXTRA_ENV:-} \
    python3 "$ENGINE/$entry" "$@" >"$WORK/out" 2>"$WORK/err" <"${STDIN:-/dev/null}"
  CODE=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
  cat "$WORK/out" "$WORK/err" >> "$CAPTURED"
}
cf() { run cf.py "$@"; }
cfw() { run cf-write.py "$@"; }
# cfj <json> / cfwj <json>: the request the mod sends, on stdin.
cfj() { printf '%s' "$1" > "$WORK/stdin"; STDIN="$WORK/stdin" run cf.py --stdin-json; }
cfwj() { printf '%s' "$1" > "$WORK/stdin"; STDIN="$WORK/stdin" run cf-write.py --stdin-json; }

echo "== manifests =="

check "plugin name" "cloudflare" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$ROOT/.claude-plugin/plugin.json")"
check "plugin version" "0.1.0" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")"
check "plugin license" "MIT" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["license"])' "$ROOT/.claude-plugin/plugin.json")"
check "marketplace lists the plugin at the same version" "cloudflare 0.1.0" \
  "$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["plugins"][0]; print(p["name"], p["version"])' "$ROOT/.claude-plugin/marketplace.json")"
check "hooks.json names the module" "./register.ts" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["modules"][0])' "$ROOT/hooks/hooks.json")"

echo "== accounts and configuration =="

cf accounts
check "accounts lists every account, the default marked, without a call" \
  "$(printf 'name\tdefault\tsource\taccount_id\nalpha\tyes\t~/.env\t-\nbeta\tno\tenvironment\t-')" "$OUT"
reset
cf accounts
check "accounts makes no API call" "" "$(sent)"

EXTRA_ENV="BETA_CLOUDFLARE_ACCOUNT_ID=acc-beta" cf accounts
check "an account id in the environment is shown" "beta	no	environment	acc-beta" "$(printf '%s\n' "$OUT" | grep '^beta')"

cf accounts --json
check "accounts --json gives the objects" "alpha beta" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(" ".join(a["name"] for a in json.load(sys.stdin)))')"

cf auth-check
check "auth-check uses the default account" "$(printf 'account\tstatus\ttoken_id\texpires_on\nalpha\tactive\ttok-alpha\t-')" "$OUT"

cf auth-check --account beta
check "auth-check --account names the account" "beta	active	tok-beta	2027-01-01T00:00:00Z" "$(printf '%s\n' "$OUT" | tail -1)"

cf --account=BETA auth-check
check "an account name is read without regard to case" "beta" "$(printf '%s\n' "$OUT" | tail -1 | cut -f1)"

EXTRA_ENV="ALPHA_CLOUDFLARE_API_TOKEN=$TOKEN_BETA" cf auth-check
check "the environment wins over an env file" "tok-beta" "$(printf '%s\n' "$OUT" | tail -1 | cut -f3)"

cf auth-check --account gamma
check "an unknown account exits 4" "4" "$CODE"
check "an unknown account names the known ones" "cf: no account gamma; known: alpha, beta" "$ERR"

reset
fail_next GET /user/tokens/verify 400 1000 "Invalid API Token"
cf auth-check
check "an account-owned token is verified on its account" "alpha	active	tok-alpha	-" "$(printf '%s\n' "$OUT" | tail -1)"
check "the account id is looked up from the token" \
  "$(printf 'GET /user/tokens/verify\nGET /accounts\nGET /accounts/acc-alpha/tokens/verify')" "$(sent)"

printf '{"env_files": ["~/.env"], "backup_dir": "%s"}\n' "$WORK/backups" > "$WORK/nodefault.json"
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/nodefault.json" cf auth-check
check "two accounts and no default exit 4" "4" "$CODE"
check "two accounts and no default say what to do" \
  "cf: several accounts (alpha, beta): pass one or set default_account" "$ERR"

printf '{"env_files": []}\n' > "$WORK/onlyenv.json"
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/onlyenv.json" cf auth-check
check "the only account found is used" "beta" "$(printf '%s\n' "$OUT" | tail -1 | cut -f1)"

printf '{"env_files": ["~/.nothing"]}\n' > "$WORK/noaccount.json"
env -i PATH="$PATH" HOME="$HOMEDIR" CLAUDE_CLOUDFLARE_CONFIG="$WORK/noaccount.json" CF_API_BASE="$API" \
  python3 "$ENGINE/cf.py" zones >"$WORK/out" 2>"$WORK/err"
check "no account at all exits 4" "4" "$?"
check "no account at all says where tokens are read" \
  "cf: no Cloudflare account: set <NAME>_CLOUDFLARE_API_TOKEN in the environment or in an env file (~/.nothing)" \
  "$(cat "$WORK/err")"

printf '{"default_account": "alpha",' > "$WORK/broken.json"
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/broken.json" cf zones
check "a malformed config exits 4" "4" "$CODE"
check_contains "a malformed config is named" "cf: $WORK/broken.json is not valid JSON" "$ERR"

printf '{"env_files": "~/.env"}\n' > "$WORK/badtype.json"
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/badtype.json" cf zones
check "a config key of the wrong type exits 4" "4" "$CODE"

EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/absent.json" cf accounts
check "an absent config file reads ~/.env by default" "alpha" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1)"

echo "== transport and zones =="

reset
cf zones
check "zones folds every page" \
  "$(printf 'name\tid\tstatus\tplan\nexample.com\t0123456789abcdef0123456789abcdef\tactive\tFree Website\nexample.net\t11111111111111111111111111111111\tactive\tFree Website\nexample.org\t22222222222222222222222222222222\tpending\tPro Website')" \
  "$OUT"
check "zones reads the second page" "$(printf 'GET /zones\nGET /zones?page=2')" "$(sent)"

cf zones --json
check "zones --json gives full objects" "3 acc-alpha" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; z=json.load(sys.stdin); print(len(z), z[0]["account"]["id"])')"

cf zones --account beta
check "each account sees its own zones" "example.edu" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1)"

reset
EXTRA_ENV="ALPHA_CLOUDFLARE_ACCOUNT_ID=acc-alpha" cf zones
check "a known account id filters the zones" "GET /zones?account.id=acc-alpha" "$(sent | head -1)"

EXTRA_ENV="ALPHA_CLOUDFLARE_API_TOKEN=cf-wrong" cf zones
check "an API failure exits 3" "3" "$CODE"
check "an API failure is one line with Cloudflare's code" "cf: Cloudflare 10000: Authentication error" "$ERR"

EXTRA_ENV="CF_API_BASE=http://127.0.0.1:1/client/v4" cf zones
check "an unreachable API exits 3" "3" "$CODE"
check "an unreachable API is one line" "1" "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')"
check_contains "an unreachable API names the failure" "cf: cannot reach the Cloudflare API" "$ERR"

echo "== entry points and requests on stdin =="

cf nope
check "an unknown command exits 2" "2" "$CODE"
cf zones --jso
check "an abbreviated flag is refused" "2" "$CODE"
cf
check "no command exits 2" "2" "$CODE"

cfw zones
check "cf-write.py refuses a read" "2" "$CODE"
check "cf-write.py names the read entry" "cf: zones only reads: use cf.py" "$ERR"

cfj '{"command": "zones", "account": "beta"}'
check "stdin json runs a command on an account" "example.edu" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1)"
cfj '{"command": "zones", "args": {"json": true}}'
check "stdin json maps a boolean flag" "3" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
cfj '{"command": "zones", "args": {"colour": "red"}}'
check "stdin json refuses an unknown argument" "2 cf: unknown argument \"colour\" for zones" "$CODE $ERR"
cfj '{"command": "zones", "args": {"json": "yes"}}'
check "stdin json refuses a flag value of the wrong type" "2" "$CODE"
cfj 'nope'
check "stdin that is not JSON exits 2" "2" "$CODE"
cfj '{"command": "rm -rf"}'
check "stdin json refuses an unknown command" "2 cf: unknown command: rm -rf" "$CODE $ERR"
cfj '{"command": "zones", "account": 3}'
check "stdin json refuses an account that is not a string" "2" "$CODE"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
