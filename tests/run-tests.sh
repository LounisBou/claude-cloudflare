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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
