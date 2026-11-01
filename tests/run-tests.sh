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
WORLD_PID=""
RESOLVER_PID=""

OTHER_PID=""

stop() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
  [ -n "$OTHER_PID" ] && kill "$OTHER_PID" 2>/dev/null && wait "$OTHER_PID" 2>/dev/null
  [ -n "$WORLD_PID" ] && kill "$WORLD_PID" 2>/dev/null && wait "$WORLD_PID" 2>/dev/null
  [ -n "$RESOLVER_PID" ] && kill "$RESOLVER_PID" 2>/dev/null && wait "$RESOLVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap stop EXIT

pass=0
fail=0
skip=0

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
# Gamma's token sees two accounts, alpha's and its own.
TOKEN_GAMMA=cf-fixture-token-gamma-9b2e5d17
# Tokens the doctor reads the policies of: each write under its dashboard name;
# names a prefix match would take for DNS Write and Cache Purge; Cache Purge alone.
TOKEN_IOTA=cf-fixture-token-iota-0c5e7d13
TOKEN_DELTA=cf-fixture-token-delta-9a2b4f60
TOKEN_EPSILON=cf-fixture-token-epsilon-3d7e1a85
# A token of an account with no zone, and one that reads its policies on its account only.
TOKEN_ZETA=cf-fixture-token-zeta-58c0e2b7
TOKEN_ETA=cf-fixture-token-eta-1f6a93d4

# A second server on another port is where a redirect points: it must never
# be reached.
python3 "$FIXTURES/server.py" "$FIXTURES/state.json" "$WORK/port" &
SERVER_PID=$!
python3 "$FIXTURES/server.py" "$FIXTURES/state.json" "$WORK/other-port" &
OTHER_PID=$!
for _ in $(seq 1 50); do
  [ -s "$WORK/port" ] && [ -s "$WORK/other-port" ] && break
  sleep 0.1
done
PORT=$(cat "$WORK/port" 2>/dev/null)
OTHER_PORT=$(cat "$WORK/other-port" 2>/dev/null)
[ -n "$PORT" ] && [ -n "$OTHER_PORT" ] || { echo "the fixture server did not start"; exit 1; }
API="http://127.0.0.1:$PORT/client/v4"

# reset: the server back to its initial state, its request log emptied. The
# log is kept first in REQUESTS, which the token check searches at the end.
REQUESTS="$WORK/requests"
reset() {
  curl -fsS "http://127.0.0.1:$PORT/__log" >> "$REQUESTS"
  curl -fsS -X POST "http://127.0.0.1:$PORT/__reset" >/dev/null
}
# sent: the requests the server received since the last reset, one per line.
sent() {
  curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    q = "&".join("%s=%s" % kv for kv in sorted(r["query"].items()))
    print(r["method"], r["path"].replace("/client/v4", "") + ("?" + q if q else ""))'
}
# writes: the requests other than GET the server received since the last
# cfw or cfwj began, one per line; empty when the command sent no write.
writes() { sent | tail -n +$((MARK + 1)) | grep -v '^GET'; }
MARK=0
# fixture <python expression on s>: the server's scripts and custom domains,
# {"scripts", "domains"}, as s; the expression's value is printed as JSON.
fixture() {
  curl -fsS "http://127.0.0.1:$PORT/__state" | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps(eval(sys.argv[1]), sort_keys=True))' "$1"
}
# plant <script json>: store a script on the server as given.
plant() {
  curl -fsS -X POST "http://127.0.0.1:$PORT/__script" -H 'Content-Type: application/json' -d "$1" >/dev/null
}
# fail_next <method> <path suffix> <status> <code> <message> [skip]: the next
# matching request fails, or the one after [skip] matching requests passed.
fail_next() {
  curl -fsS -X POST "http://127.0.0.1:$PORT/__fail" -H 'Content-Type: application/json' \
    -d "{\"method\":\"$1\",\"path\":\"$2\",\"status\":$3,\"code\":$4,\"message\":\"$5\",\"skip\":${6:-0}}" >/dev/null
}

# redirect_next <method> <path suffix> <status> <location>
redirect_next() {
  curl -fsS -X POST "http://127.0.0.1:$PORT/__fail" -H 'Content-Type: application/json' \
    -d "{\"method\":\"$1\",\"path\":\"$2\",\"status\":$3,\"location\":\"$4\"}" >/dev/null
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
# EXTRA_ENV adds variables split on blanks, RAW_ENV one variable kept whole.
CAPTURED="$WORK/captured"
: > "$CAPTURED"
run() {
  local entry="$1"
  shift
  env -i PATH="$PATH" HOME="$HOMEDIR" CLAUDE_CLOUDFLARE_CONFIG="$CONFIG" CF_API_BASE="$API" \
    BETA_CLOUDFLARE_API_TOKEN="$TOKEN_BETA" ${EXTRA_ENV:-} ${RAW_ENV:+"$RAW_ENV"} \
    python3 "$ENGINE/$entry" "$@" >"$WORK/out" 2>"$WORK/err" <"${STDIN:-/dev/null}"
  CODE=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
  cat "$WORK/out" "$WORK/err" >> "$CAPTURED"
}
cf() { run cf.py "$@"; }
cfw() { MARK=$(sent | wc -l); run cf-write.py "$@"; }
# cfj <json> / cfwj <json>: the request the mod sends, on stdin.
cfj() { printf '%s' "$1" > "$WORK/stdin"; STDIN="$WORK/stdin" run cf.py --stdin-json; }
cfwj() { printf '%s' "$1" > "$WORK/stdin"; MARK=$(sent | wc -l); STDIN="$WORK/stdin" run cf-write.py --stdin-json; }

echo "== manifests =="

check "plugin name" "cloudflare" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$ROOT/.claude-plugin/plugin.json")"
check "plugin version" "0.5.0" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")"
check "plugin license" "MIT" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["license"])' "$ROOT/.claude-plugin/plugin.json")"
check "marketplace lists the plugin at the same version" "cloudflare 0.5.0" \
  "$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["plugins"][0]; print(p["name"], p["version"])' "$ROOT/.claude-plugin/marketplace.json")"
check "marketplace describes the plugin as plugin.json does" "same" \
  "$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["description"]; b=json.load(open(sys.argv[2]))["plugins"][0]["description"]; print("same" if a == b else b)' "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json")"
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

RAW_ENV="ALPHA_CLOUDFLARE_API_TOKEN=$(printf '  %s\t' "$TOKEN_ALPHA")" cf auth-check
check "a token is read without the blanks around it" "alpha	active	tok-alpha" "$(printf '%s\n' "$OUT" | tail -1 | cut -f1-3)"
RAW_ENV="ALPHA_CLOUDFLARE_API_TOKEN=$(printf '%s\nX-Injected: 1' "$TOKEN_ALPHA")" cf auth-check
check "a token holding a line break exits 4" "4" "$CODE"
check "a token holding a line break is refused without being shown" \
  "cf: the token of account alpha holds a blank or a control character: set it again" "$ERR"
reset
RAW_ENV="ALPHA_CLOUDFLARE_API_TOKEN=$(printf '%s\x01' "$TOKEN_ALPHA")x" cf zones
check "a token holding a control character exits 4 and sends nothing" "4 " "$CODE $(sent)"

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
cat "$WORK/out" "$WORK/err" >> "$CAPTURED"
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
check "zones reads the second page" \
  "$(printf 'GET /accounts\nGET /zones?account.id=acc-alpha\nGET /zones?account.id=acc-alpha&page=2')" "$(sent)"

cf zones --json
check "zones --json gives full objects" "3 acc-alpha" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; z=json.load(sys.stdin); print(len(z), z[0]["account"]["id"])')"

cf zones --account beta
check "each account sees its own zones" "example.edu" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1)"

# A list longer than the engine reads is refused, not cut: a backup made of
# part of a name's records would have a later restore delete the rest.
reset
curl -fsS -X POST "http://127.0.0.1:$PORT/__pages" -H 'Content-Type: application/json' -d '{"total_pages": 100000}' >/dev/null
cf dns-list example.com
check "a list with pages left past the limit exits 3, printing nothing" "3 " "$CODE $OUT"
check_contains "a list with pages left past the limit says so" "pages: refused rather than cut" "$ERR"

reset
EXTRA_ENV="ALPHA_CLOUDFLARE_ACCOUNT_ID=acc-alpha" cf zones
check "a known account id filters the zones" "GET /zones?account.id=acc-alpha" "$(sent | head -1)"

EXTRA_ENV="GAMMA_CLOUDFLARE_API_TOKEN=$TOKEN_GAMMA GAMMA_CLOUDFLARE_ACCOUNT_ID=acc-gamma" cf zones --account gamma
check "a token that sees two accounts lists only its account's zones" \
  "$(printf 'name\tid\tstatus\tplan\nexample.io\t44444444444444444444444444444444\tactive\tFree Website')" "$OUT"
EXTRA_ENV="GAMMA_CLOUDFLARE_API_TOKEN=$TOKEN_GAMMA" cf zones --account gamma
check "a token that sees two accounts and no account id exits 4" \
  "4 cf: the token of gamma sees 2 accounts: set GAMMA_CLOUDFLARE_ACCOUNT_ID" "$CODE $ERR"

EXTRA_ENV="ALPHA_CLOUDFLARE_API_TOKEN=cf-wrong" cf zones
check "an API failure exits 3" "3" "$CODE"
check "an API failure is one line with Cloudflare's code" "cf: Cloudflare 10000: Authentication error" "$ERR"
reset
fail_next GET /zones 400 9999 'first line\n  second\tline'
cf zones
check "a Cloudflare message on several lines is printed on one" "3 cf: Cloudflare 9999: first line second line" "$CODE $ERR"

EXTRA_ENV="CF_API_BASE=http://127.0.0.1:1/client/v4" cf zones
check "an unreachable API exits 3" "3" "$CODE"
check "an unreachable API is one line" "1" "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')"
check_contains "an unreachable API names the failure" "cf: cannot reach the Cloudflare API" "$ERR"

reset
curl -fsS -X POST "http://127.0.0.1:$PORT/__fail" -H 'Content-Type: application/json' \
  -d '{"method":"GET","path":"/zones","raw":"NOT HTTP\r\n\r\n"}' >/dev/null
cf zones
check "an answer that is not HTTP exits 3, one line" "3 1" "$CODE $(printf '%s\n' "$ERR" | wc -l | tr -d ' ')"
check_contains "an answer that is not HTTP names the API" "cf: cannot read the Cloudflare API's answer" "$ERR"

reset
curl -fsS -X POST "http://127.0.0.1:$OTHER_PORT/__reset" >/dev/null
redirect_next GET /zones 302 "http://127.0.0.1:$OTHER_PORT/client/v4/zones"
cf zones
check "a redirect is not followed and exits 3" "3" "$CODE"
check "a redirect is one line" "cf: Cloudflare answered HTTP 302, a redirect, which is not followed" "$ERR"
check "a redirect reaches nothing at its target" "[]" "$(curl -fsS "http://127.0.0.1:$OTHER_PORT/__log")"

echo "== entry points and requests on stdin =="

cf nope
check "an unknown command exits 2" "2" "$CODE"
cf zones --jso
check "an abbreviated flag is refused" "2" "$CODE"
check "a usage error is one line" "cf: unrecognized arguments: --jso" "$ERR"
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
printf '{"command": "dns-get", "args": {"zone": "ex\377ample.com", "record": "www"}}' > "$WORK/stdin"
STDIN="$WORK/stdin" run cf.py --stdin-json
check "stdin that is not UTF-8 exits 2, one line" "2 cf: stdin is not UTF-8" "$CODE $ERR"
cfj '{"command": "rm -rf"}'
check "stdin json refuses an unknown command" "2 cf: unknown command: rm -rf" "$CODE $ERR"
cfj '{"command": "zones", "account": 3}'
check "stdin json refuses an account that is not a string" "2" "$CODE"

echo "== DNS reads =="

# lines: OUT's lines without the id column, the header dropped.
lines() { printf '%s\n' "$OUT" | sed 1d | cut -f1-5; }
backup_of() { printf '%s\n' "$OUT" | sed -n 's/^backup: //p'; }

reset
cf dns-list example.com
check "dns-list prints a header and one line per record, every page read" "8" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
check "dns-list header" "$(printf 'type\tname\tcontent\tproxied\tttl\tid')" "$(printf '%s\n' "$OUT" | head -1)"
check "dns-list shows a proxied record with an automatic ttl" "A	www.example.com	203.0.113.10	yes	auto" "$(lines | awk -F'\t' '$2 == "www.example.com"')"
check "dns-list puts the priority before an MX target" "MX	example.com	10 mail.example.com	no	3600" "$(lines | grep MX)"
check "dns-list reads four pages" "4" "$(sent | grep -c dns_records)"

cf dns-list example.com --type TXT
check "dns-list --type filters" "3" "$(lines | wc -l | tr -d ' ')"
reset
cf dns-list example.com --name www
check "dns-list --name takes a name relative to the zone" \
  "GET /zones/0123456789abcdef0123456789abcdef/dns_records?name=www.example.com" "$(sent | tail -1)"
cf dns-list 0123456789abcdef0123456789abcdef --name @ --type A
check "dns-list takes a zone id, and @ for the apex" "A	example.com	203.0.113.10	yes	auto" "$(lines)"
cf dns-list nope.example
check "an unknown zone exits 2" "2 cf: no zone nope.example on account alpha" "$CODE $ERR"

cf dns-get example.com app
check "dns-get finds a record by name" "CNAME	app.example.com	www.example.com	yes	auto" "$(lines)"
app_id=$(printf '%s\n' "$OUT" | sed -n 2p | cut -f6)
cf dns-get example.com "$app_id"
check "dns-get finds a record by id" "CNAME	app.example.com	www.example.com	yes	auto" "$(lines)"
cf dns-get example.com multi.example.com
check "dns-get lists every record of a name" "2" "$(lines | wc -l | tr -d ' ')"
cf dns-get example.com missing
check "dns-get of no record exits 2" "2 cf: no record missing.example.com in example.com" "$CODE $ERR"
cf dns-get example.com www --json
check "dns-get --json gives the full objects" "203.0.113.10 0123456789abcdef0123456789abcdef" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; r=json.load(sys.stdin)[0]; print(r["content"], r["zone_id"])')"

cf dns-export example.com
check_contains "dns-export gives the zone file" "$(printf 'www.example.com.\t300\tIN\tA\t203.0.113.10')" "$OUT"
cf dns-export example.com --json
check "dns-export --json gives every record" "7" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

echo "== DNS writes and backups =="

cf dns-create example.com --type A --name new --content 203.0.113.5
check "cf.py refuses a write" "2 cf: dns-create writes: use cf-write.py" "$CODE $ERR"
cfj '{"command": "dns-delete", "args": {"zone": "example.com", "record": "www"}}'
check "cf.py refuses a write sent on stdin" "2 cf: dns-delete writes: use cf-write.py" "$CODE $ERR"
reset
check "a refused write sends nothing" "" "$(sent)"
# The guard reads the command the parser selected, not the first word that
# looks like one: here "zones" is the value of --account, an account that exists.
EXTRA_ENV="ZONES_CLOUDFLARE_API_TOKEN=$TOKEN_ALPHA" cf --account zones dns-delete example.com www
check "cf.py refuses a write behind a flag value named like a read" "2 cf: dns-delete writes: use cf-write.py" "$CODE $ERR"
check "a write behind a flag value sends nothing" "" "$(sent | grep -v '^GET')"
cf dns-get example.com -- restore
check "a positional after -- named like a write is read" "2 cf: no record restore.example.com in example.com" "$CODE $ERR"
cf dns-get example.com dns-delete
check "a positional named like a write is read" "2 cf: no record dns-delete.example.com in example.com" "$CODE $ERR"

reset
cfw dns-create example.com --type A --name new --content 203.0.113.5 --proxied
check "dns-create prints the record" "created	A	new.example.com	203.0.113.5	yes	auto" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-6)"
create_bk=$(backup_of)
check "a write ends with its backup" "backup: $create_bk" "$(printf '%s\n' "$OUT" | tail -1)"
check_contains "the backup lies under backup_dir/<account>/<zone>" "$WORK/backups/alpha/example.com/" "$create_bk"
check "the backup is named <UTC timestamp>-<kind>.json" "1" \
  "$(basename "$create_bk" | grep -cE '^[0-9]{8}T[0-9]{6}\.[0-9]{6}Z-dns\.json$')"
check "the backup is private" "600" "$(stat -f '%Lp' "$create_bk" 2>/dev/null || stat -c '%a' "$create_bk")"
check "the backup of a create holds the name, without records" "new.example.com 0" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["data"]; print(" ".join(d["names"]), len(d["records"]))' "$create_bk")"
check "dns-create posts once" "1" "$(sent | grep -c '^POST /zones/0123456789abcdef0123456789abcdef/dns_records$')"

reset
taken_before=$(ls "$WORK/backups/alpha/example.com" | wc -l)
fail_next POST /dns_records 400 81053 "An A, AAAA, or CNAME record with that host already exists."
cfw dns-create example.com --type A --name failed --content 203.0.113.6
newest_bk() { printf '%s/%s' "$WORK/backups/alpha/example.com" "$(ls "$WORK/backups/alpha/example.com" | tail -1)"; }
check "a refused create exits 3 with Cloudflare's reason and its backup" \
  "3 cf: Cloudflare 81053: An A, AAAA, or CNAME record with that host already exists.; backup: $(newest_bk)" "$CODE $ERR"
check "the backup was taken before the call" "$((taken_before + 1))" "$(ls "$WORK/backups/alpha/example.com" | wc -l | tr -d ' ')"
record_id() { cf dns-get example.com "$1"; printf '%s\n' "$OUT" | sed -n 2p | cut -f6; }
fail_next PUT "/dns_records/$(record_id app)" 400 9005 "DNS record content is invalid"
cfw dns-update example.com app --content www.example.net
check "a failed update names its backup" "3 cf: Cloudflare 9005: DNS record content is invalid; backup: $(newest_bk)" "$CODE $ERR"
fail_next DELETE "/dns_records/$(record_id app)" 500 10001 "Internal error"
cfw dns-delete example.com app
check "a failed delete names its backup" "3 cf: Cloudflare 10001: Internal error; backup: $(newest_bk)" "$CODE $ERR"

reset
mkdir -p "$WORK/ro"
chmod 500 "$WORK/ro"
printf '{"default_account": "alpha", "backup_dir": "%s"}\n' "$WORK/ro/backups" > "$WORK/ro.json"
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/ro.json" cfw dns-delete example.com www
check "a backup that cannot be written stops the write" "4" "$CODE"
check_contains "a backup that cannot be written says nothing was changed" "nothing was changed" "$ERR"
check "a write without its backup sends nothing" "" "$(sent | grep -v '^GET')"
chmod 700 "$WORK/ro"

reset
cfw dns-update example.com app --type A --content 203.0.113.7
check "dns-update changes a CNAME into an A, proxied kept" \
  "$(printf 'before\tCNAME\tapp.example.com\twww.example.com\tyes\tauto\nafter\tA\tapp.example.com\t203.0.113.7\tyes\tauto')" \
  "$(printf '%s\n' "$OUT" | head -2 | cut -f1-6)"
check "dns-update keeps the record's id" "$(printf '%s\n' "$OUT" | sed -n 1p | cut -f7)" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f7)"
update_bk=$(backup_of)
check "the backup of an update holds the record before it" "CNAME www.example.com" \
  "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["data"]["records"][0]; print(r["type"], r["content"])' "$update_bk")"
check "dns-update overwrites the record" "1" "$(sent | grep -c '^PUT /zones/.*/dns_records/')"
# put_keys: the fields of the last PUT the server received.
put_keys() {
  curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
print(" ".join(sorted([r for r in json.load(sys.stdin) if r["method"] == "PUT"][-1]["body"])))'
}
check "a CNAME turned into an A is sent with the fields of an A" "content name proxied ttl type" "$(put_keys)"

reset
cfw dns-update example.com app --type A
check "a type changed without its content exits 2" \
  "2 cf: app.example.com changes from CNAME to A: pass the --content of the new type" "$CODE $ERR"
check "a type changed without its content sends no write" "" "$(sent | grep -v '^GET')"
cfw dns-update example.com @ --from-type MX --type A --content 203.0.113.12
check "an MX turned into an A leaves its priority behind" "content name proxied ttl type" "$(put_keys)"
reset

cfw dns-update example.com app
check "dns-update with nothing to change exits 2" "2 cf: nothing to change: pass type, name, content, ttl, proxied, priority or comment" "$CODE $ERR"
cfw dns-update example.com multi --content three
check "dns-update of an ambiguous name exits 2" "2" "$CODE"
check_contains "an ambiguous name lists the records to choose from" "TXT multi.example.com one" "$ERR"
check "an ambiguous name is one error line" "1" "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')"
cfw dns-update example.com www --type TXT --content hello
check "a type that cannot be proxied leaves the proxy" "after	TXT	www.example.com	hello	no" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1-5)"
cfw dns-update example.com www --type A --content 203.0.113.10 --proxied --ttl 120
cfw dns-update example.com multi --from-type TXT --content x
check "--from-type alone does not settle two records of one type" "2" "$CODE"

cfwj '{"command": "dns-update", "args": {"zone": "example.com", "record": "www", "proxied": false}}'
check "stdin json maps proxied false to --no-proxied" "after	A	www.example.com	203.0.113.10	no	120" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1-6)"

reset
cfw dns-delete example.com www
check "dns-delete prints the record it deleted" "deleted	A	www.example.com	203.0.113.10	yes	auto" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-6)"
delete_bk=$(backup_of)
check "dns-delete deletes once" "1" "$(sent | grep -c '^DELETE ')"
cf dns-get example.com www
check "the deleted record is gone" "2" "$CODE"

echo "== backups and restore =="

cf backups
check "backups lists every backup, oldest first" "account	zone	taken	kind	path" "$(printf '%s\n' "$OUT" | head -1)"
check "backups lists the writes made" "$delete_bk" "$(printf '%s\n' "$OUT" | tail -1 | cut -f5)"
cf backups --zone example.net
check "backups --zone filters" "" "$OUT"
cf backups --account beta
check "backups --account filters" "" "$OUT"
cf backups --account ALPHA
check "backups --account reads the name without regard to case" "1" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1 | grep -c '^alpha$')"
cf backups --json
check "backups --json gives objects" "dns" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["kind"])')"

cf restore "$delete_bk"
check "cf.py refuses restore" "2 cf: restore writes: use cf-write.py" "$CODE $ERR"

# Each restore below replays a write made after the same reset, on the same
# records.
reset
cfw dns-update example.com app --type A --content 203.0.113.7
cfw restore "$(backup_of)"
check "restore turns an A back into the CNAME it was" "restored	CNAME	app.example.com	www.example.com	yes	auto" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-6)"
check_contains "restore takes its own backup first" "backup: $WORK/backups/alpha/example.com/" "$(printf '%s\n' "$OUT" | tail -1)"

cfw dns-create example.com --type A --name new --content 203.0.113.5 --proxied
created_bk=$(backup_of)
cfw restore "$created_bk"
check "restore of a create's backup deletes the record created since" "deleted	A	new.example.com	203.0.113.5	yes	auto" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-6)"
cfw restore "$created_bk"
check "a restore with nothing to change writes nothing" "nothing to restore: new.example.com already matches the backup" "$OUT"

cfw dns-delete example.com www
cfw restore "$(backup_of)"
check "restore recreates a deleted record" "recreated	A	www.example.com	203.0.113.10	yes	auto" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-6)"
cf dns-get example.com www
check "the restored record is back" "A	www.example.com	203.0.113.10	yes	auto" "$(lines)"

printf '{}' > "$WORK/outside.json"
cfw restore "$WORK/outside.json"
check "restore refuses a file outside the backups" "2" "$CODE"
cfw restore "$WORK/backups/alpha/example.com/none-dns.json"
check "restore of a missing backup exits 2" "2" "$CODE"
mkdir -p "$WORK/backups/alpha/broken.example"
printf '{"account": "alpha", "zone": "broken.example", "kind": "dns", "data": {}}' \
  > "$WORK/backups/alpha/broken.example/20260101T000000.000000Z-dns.json"
cfw restore "$WORK/backups/alpha/broken.example/20260101T000000.000000Z-dns.json"
check "a malformed backup is an internal error, one line, no traceback" "1 cf: internal error: KeyError" "$CODE $ERR"
rm -r "$WORK/backups/alpha/broken.example"
cfw restore "$delete_bk" --account beta
check "restore refuses another account than the backup's" "2 cf: $delete_bk belongs to account alpha, not beta" "$CODE $ERR"

# A restore cut between its delete and its re-create names the backup it took
# of the state it was replacing, from which that state comes back. The A
# brought back by the delete's backup has a new id, so the update's backup
# deletes it before it creates the CNAME again.
reset
cfw dns-update example.com app --type A --content 203.0.113.7
cname_bk=$(backup_of)
cfw dns-delete example.com app
cfw restore "$(backup_of)"
fail_next POST /dns_records 500 10001 "Internal error"
cfw restore "$cname_bk"
cut_bk=$(printf '%s' "$ERR" | sed -n 's/.*; backup: //p')
check "an interrupted restore names its own backup" "3 cf: Cloudflare 10001: Internal error; backup: $(newest_bk)" "$CODE $ERR"
check "the interrupted restore deleted the A before it failed" "2" "$(cf dns-get example.com app; printf '%s' "$CODE")"
cfw restore "$cut_bk"
check "the interrupted restore's backup brings the A back" "recreated	A	app.example.com	203.0.113.7	yes" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-5)"
cfw dns-update example.com app --content 203.0.113.8
moved_bk=$(backup_of)
fail_next PUT "/dns_records/$(record_id app)" 500 10001 "Internal error"
cfw restore "$moved_bk"
check "a failed restore names its backup" "3 cf: Cloudflare 10001: Internal error; backup: $(newest_bk)" "$CODE $ERR"

echo "== end to end: a DNS cycle through the tool's requests =="

reset
cfj '{"command": "dns-list", "args": {"zone": "example.com", "name": "e2e"}}'
check "e2e: the name is free" "0 " "$CODE $OUT"
cfwj '{"command": "dns-create", "args": {"zone": "example.com", "type": "CNAME", "name": "e2e", "content": "www.example.com", "proxied": true}}'
check "e2e: create a CNAME" "created	CNAME	e2e.example.com	www.example.com	yes" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-5)"
cfwj '{"command": "dns-update", "args": {"zone": "example.com", "record": "e2e", "type": "A", "content": "203.0.113.9"}}'
check "e2e: change it into an A" "after	A	e2e.example.com	203.0.113.9	yes" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1-5)"
e2e_update_bk=$(backup_of)
cfwj '{"command": "dns-delete", "args": {"zone": "example.com", "record": "e2e"}}'
check "e2e: delete it" "deleted	A	e2e.example.com	203.0.113.9	yes" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-5)"
e2e_delete_bk=$(backup_of)
cfwj "{\"command\": \"restore\", \"args\": {\"path\": \"$e2e_delete_bk\"}}"
check "e2e: restore it from the delete's backup" "recreated	A	e2e.example.com	203.0.113.9	yes" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-5)"
cfj '{"command": "dns-list", "args": {"zone": "example.com", "name": "e2e"}}'
check "e2e: the A is back" "A	e2e.example.com	203.0.113.9	yes	auto" "$(lines)"
# The record came back under a new id: the update's backup replaces it.
cfwj "{\"command\": \"restore\", \"args\": {\"path\": \"$e2e_update_bk\"}}"
check "e2e: the update's backup brings the CNAME back" \
  "$(printf 'deleted\tA\te2e.example.com\t203.0.113.9\tyes\nrecreated\tCNAME\te2e.example.com\twww.example.com\tyes')" \
  "$(printf '%s\n' "$OUT" | head -2 | cut -f1-5)"
cfj '{"command": "dns-get", "args": {"zone": "example.com", "record": "e2e"}}'
check "e2e: the name holds the CNAME alone" "CNAME	e2e.example.com	www.example.com	yes	auto" "$(lines)"
# A restore brings back the types its backup holds, and leaves the others.
cfwj '{"command": "dns-update", "args": {"zone": "example.com", "record": "www", "content": "203.0.113.11"}}'
e2e_a_bk=$(backup_of)
cfwj '{"command": "dns-create", "args": {"zone": "example.com", "type": "TXT", "name": "www", "content": "added since"}}'
cfwj "{\"command\": \"restore\", \"args\": {\"path\": \"$e2e_a_bk\"}}"
check "e2e: restore brings the A back and says what it kept" \
  "$(printf 'restored\tA\twww.example.com\t203.0.113.10\tyes\nkept: 1 record of a type the backup does not hold')" \
  "$(printf '%s\n' "$OUT" | head -2 | cut -f1-5)"
cfj '{"command": "dns-get", "args": {"zone": "example.com", "record": "www"}}'
check "e2e: the TXT added since survives the restore" \
  "$(printf 'A\twww.example.com\t203.0.113.10\tyes\tauto\nTXT\twww.example.com\tadded since\tno\tauto')" "$(lines)"

echo "== zone settings, certificates, plan =="

# last_put <path suffix>: the rules of the last PUT sent to a path, one "action expression" per line.
last_put() {
  curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
puts = [r for r in json.load(sys.stdin) if r["method"] == "PUT" and r["path"].endswith(sys.argv[1])]
for rule in puts[-1]["body"]["rules"]:
    print(rule["action"], rule["expression"])' "$1"
}
# col <n>: the nth column of OUT's lines, the header dropped.
col() { printf '%s\n' "$OUT" | sed 1d | cut -f"$1"; }
# mark, then since_mark: the requests sent after the mark, one per line.
mark() { MARK=$(sent | wc -l); }
since_mark() { sent | tail -n +$((MARK + 1)); }
# foreign_kept <zone> <phase>: "kept" when the last PUT since the mark to the
# zone's entrypoint of the phase carries each dashboard rule the fixture gives
# that phase whole (id, description, enabled, action, expression and the
# rest), else what it lost.
foreign_kept() {
  curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
with open(sys.argv[1]) as fh:
    zone = [z for z in json.load(fh)["zones"] if z["name"] == sys.argv[2]][0]
foreign = zone["rulesets"][sys.argv[3]]
path = "/zones/%s/rulesets/phases/%s/entrypoint" % (zone["id"], sys.argv[3])
puts = [r for r in json.load(sys.stdin)[int(sys.argv[4]):] if r["method"] == "PUT" and r["path"].endswith(path)]
if not puts:
    sys.exit(print("no PUT"))
carried = {r.get("id"): r for r in puts[-1]["body"]["rules"]}
lost = [f["id"] for f in foreign
        if any(carried.get(f["id"], {}).get(k) != f[k] for k in ("id", "description", "enabled", "action", "expression"))
        or any(carried[f["id"]].get(k) != v for k, v in f.items())]
print("lost " + " ".join(lost) if lost else "kept")' "$FIXTURES/state.json" "$1" "$2" "$MARK"
}

reset
cf settings example.com
check "settings header" "id	value	editable" "$(printf '%s\n' "$OUT" | head -1)"
check "settings lists every setting of the zone" "8" "$(col 1 | wc -l | tr -d ' ')"
check "settings shows a value" "ssl	full	yes" "$(printf '%s\n' "$OUT" | grep '^ssl	')"
cf settings example.com SSL
check "settings of one setting, without regard to case" "ssl	full	yes" "$(col 1-3)"
cf settings example.com nope
check "an unknown setting exits 3" "3 cf: Cloudflare 1142: Unknown setting nope" "$CODE $ERR"

cf certs example.com
check "certs header" "id	type	status	hosts	expires	authority" "$(printf '%s\n' "$OUT" | head -1)"
check "certs shows a pack with its latest expiry" "pack-1	universal	active	example.com,*.example.com	2027-01-30T00:00:00Z	lets_encrypt" "$(col 1-6 | sed -n 1p)"
check "certs shows a pack still pending" "pack-2	advanced	pending_validation	app.example.com	-	google" "$(col 1-6 | sed -n 2p)"

cf plan example.com
check "plan prints the plan and the quotas with their use" \
  "$(printf 'item\tvalue\tlimit\nplan\tFree Website\t-\ncustom_rules\t1\t5\nrate_limit_rules\t0\t1\nmanaged_rulesets\tfree\t-\nbot_product\tbot-fight-mode\t-')" "$OUT"
cf plan example.org
check "plan reads the plan from its name when it has no legacy id" \
  "$(printf 'plan\tPro Website\t-\ncustom_rules\t0\t20\nrate_limit_rules\t1\t2\nmanaged_rulesets\tfree,cloudflare,owasp\t-\nbot_product\tsuper-bot-fight-mode\t-')" "$(printf '%s\n' "$OUT" | sed 1d)"
cf plan example.net --json
check "plan --json gives the quotas and the use" "Free Website 5 0" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p["plan"], p["quotas"]["custom_rules"], p["used"]["custom_rules"])')"

cf rules example.com
check "rules lists the dashboard rule" "custom	block	yes	dashboard: no wp-login" "$(col 1,3-5 | sed -n 1p)"
cf rules example.net
check "a zone with no entrypoint has no rules" "" "$OUT"
cf rules example.com --plugin
check "rules --plugin shows none of the dashboard's rules" "" "$OUT"
cf rules example.com --phase nope
check "an unknown phase exits 2" "2" "$CODE"

cf ip-rules example.com
check "ip-rules lists the access rules" "block	ip	198.51.100.7	dashboard" "$(col 1-4)"

cf security example.com
check "security gives the protections in place" \
  "$(printf 'item\tvalue\nsecurity_level\tmedium\nbrowser_check\ton\nchallenge_ttl\t1800\nbot_fight_mode\toff\ncustom_rules\t1\nrate_limit_rules\t0\nmanaged_rules\t0\nip_access_rules\t1')" "$OUT"

cfw settings example.com
check "cf-write.py refuses the new reads" "2 cf: settings only reads: use cf.py" "$CODE $ERR"

echo "== zone setting writes =="

reset
cfw setting-set example.com ssl strict
check "setting-set shows the change" "changed	ssl	full	strict" "$(printf '%s\n' "$OUT" | head -1)"
set_bk=$(backup_of)
check "setting-set ends with its backup" "1" "$(printf '%s\n' "$OUT" | grep -c '^backup: ')"
cf settings example.com ssl
check "the setting changed" "strict" "$(col 2)"
check "the backup holds the value before" "full" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["settings"]["ssl"])' "$set_bk")"
reset
cfw setting-set example.com ssl full
check "a setting already at the value is left alone" "unchanged	ssl	full" "$OUT"
check "an unchanged setting sends no write" "" "$(sent | grep -v '^GET')"
cfw setting-set example.com ssl wrong
check "a value the setting does not take exits 2" "2 cf: ssl takes off, flexible, full, strict" "$CODE $ERR"
cfw setting-set example.com security_level under_attack
check "setting-set leaves the security level to its own commands" "2" "$CODE"
mark
cfw setting-set example.com ../dns_records x
check "a setting id carrying a path exits 2" "2 cf: ../dns_records is not a setting id (letters, digits and _)" "$CODE $ERR"
check "a setting id carrying a path sends no request" "" "$(since_mark)"
mark
cfw setting-set example.com security_level/.. x
check "a setting id cannot walk round the security level's refusal" "2 cf: security_level/.. is not a setting id (letters, digits and _)" "$CODE $ERR"
check "a setting id walking round a refusal sends no request" "" "$(since_mark)"
mark
cf settings example.com ../dns_records
check "settings refuses a setting id carrying a path" "2 cf: ../dns_records is not a setting id (letters, digits and _)" "$CODE $ERR"
check "settings with a bad setting id sends no request" "" "$(since_mark)"
cfw setting-set example.com challenge_ttl 900
check "a number is sent as a number" "changed	challenge_ttl	1800	900" "$(printf '%s\n' "$OUT" | head -1)"
cfwj '{"command": "setting-set", "args": {"zone": "example.com", "setting": "min_tls_version", "value": "1.3"}}'
check "stdin json sets a setting" "changed	min_tls_version	1.2	1.3" "$(printf '%s\n' "$OUT" | head -1)"
cfw setting-set example.com ssl strict
cfw restore "$(backup_of)"
check "restore puts a setting back" "restored	ssl	full" "$(printf '%s\n' "$OUT" | head -1)"
cf settings example.com ssl
check "the setting is back" "full" "$(col 2)"
# A settings backup edited to name a setting id carrying a path.
bad_set_bk="$WORK/backups/alpha/example.com/bad-setting.json"
python3 - "$set_bk" "$bad_set_bk" <<'PYBK'
import json, sys
with open(sys.argv[1]) as fh:
    saved = json.load(fh)
saved["data"]["settings"] = {"../dns_records": "x"}
saved["data"]["names"] = ["../dns_records"]
with open(sys.argv[2], "w") as fh:
    json.dump(saved, fh)
PYBK
mark
cfw restore "$bad_set_bk"
check "restore refuses a settings backup naming a bad setting id" "2 cf: ../dns_records is not a setting id (letters, digits and _)" "$CODE $ERR"
check "restore of a bad setting id sends no request" "" "$(since_mark)"

reset
cfw universal-ssl example.com off
check "universal-ssl off" "changed	universal_ssl	on	off" "$(printf '%s\n' "$OUT" | head -1)"
usl_bk=$(backup_of)
cfw universal-ssl example.com off
check "universal-ssl already off is left alone" "unchanged	universal_ssl	off" "$OUT"
cfw restore "$usl_bk"
check "restore turns Universal SSL back on" "restored	universal_ssl	on" "$(printf '%s\n' "$OUT" | head -1)"
cfw universal-ssl example.com maybe
check "universal-ssl takes on or off" "2" "$CODE"

reset
cfw security-level example.com high
check "security-level sets the level" "changed	security_level	medium	high" "$(printf '%s\n' "$OUT" | head -1)"
cfw security-level example.com under_attack
check "security-level refuses the emergency mode" "2" "$CODE"
cfw under-attack example.com on
check "under-attack on" "changed	security_level	high	under_attack" "$(printf '%s\n' "$OUT" | head -1)"
cfw under-attack example.com off
check "under-attack off goes back to medium" "changed	security_level	under_attack	medium" "$(printf '%s\n' "$OUT" | head -1)"
cfw under-attack example.com on
cfw under-attack example.com off --level high
check "under-attack off --level names the level" "changed	security_level	under_attack	high" "$(printf '%s\n' "$OUT" | head -1)"

reset
cfw bot-fight example.com on
check "bot-fight on" "changed	bot_fight_mode	off	on" "$(printf '%s\n' "$OUT" | head -1)"
bot_bk=$(backup_of)
cfw bot-fight example.com on
check "bot-fight already on is left alone" "unchanged	bot_fight_mode	on" "$OUT"
cfw restore "$bot_bk"
check "restore turns Bot Fight Mode back off" "restored	bot_fight_mode	off" "$(printf '%s\n' "$OUT" | head -1)"
reset
cfw bot-fight example.org on
check "bot-fight on a Pro zone is refused" "5 cf: plan Pro Website: Bot Fight Mode is the Free product; this plan's super-bot-fight-mode is set in the dashboard" "$CODE $ERR"
check "a refused write sends no change" "" "$(sent | grep -v '^GET')"

echo "== rules: composition, merge and foreign rules =="

reset
mark
cfw block-countries tm.example.com ru CN
check "block-countries creates a plugin rule" "created	custom	block	yes	cf-plugin: block-countries tm.example.com RU,CN" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,2,4-6)"
check "block-countries keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.com http_request_firewall_custom)"
bc_bk=$(backup_of)
check "the host and the countries are composed into an expression" \
  '(http.host eq "tm.example.com" and ip.src.country in {"RU" "CN"})' \
  "$(cf rules example.com --plugin; printf '%s\n' "$OUT" | sed 1d | cut -f6)"
check "the write sent the dashboard rule back with the new one" "2" "$(last_put "/rulesets/phases/http_request_firewall_custom/entrypoint" | wc -l | tr -d ' ')"
check "the dashboard rule is intact" 'block (http.request.uri.path contains "/wp-login.php")' "$(last_put "/rulesets/phases/http_request_firewall_custom/entrypoint" | sed -n 1p)"
cf rules example.com
check "rules shows the dashboard rule and the plugin's" "2" "$(col 1 | wc -l | tr -d ' ')"
check "the backup holds the whole entrypoint as it was" "1 dashboard: no wp-login" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["data"]; print(len(d["rules"]), d["rules"][0]["description"])' "$bc_bk")"
check "the backup is of kind ruleset" "ruleset" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kind"])' "$bc_bk")"
reset
cfw block-countries tm.example.com RU CN
cfw block-countries tm.example.com RU,CN
check "the same rule twice changes nothing" "unchanged" "$(printf '%s\n' "$OUT" | cut -f1)"
mark
cfw block-countries example.com fr
check "a zone's name makes the rule zone-wide" '(ip.src.country in {"FR"})' "$(cf rules example.com --plugin; printf '%s\n' "$OUT" | sed 1d | cut -f6 | tail -1)"
check "block-countries on a whole zone keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.com http_request_firewall_custom)"
cfw block-countries nope.test FR
check "a host of no zone exits 2" "2 cf: no zone of account alpha holds nope.test" "$CODE $ERR"
cfw block-countries 'a" or true or "b.example.com' FR
check "a host cannot carry an expression" "2" "$CODE"
cfw block-countries tm.example.com FRA
check "a country code has two letters" "2 cf: FRA is not a two-letter country code" "$CODE $ERR"
mark
cfw block-countries '*.example.com' FR
check "a wildcard host exits 2, saying to target the zone" \
  "2 cf: *.example.com: a rule on http.host never matches a wildcard; target the zone instead" "$CODE $ERR"
check "a wildcard host sends no request" "" "$(since_mark)"
mark
cfwj '{"command": "challenge", "args": {"target": "tm.example.com", "path": "/admin\n"}}'
check "a path ending in a newline exits 2" "2 cf: '/admin\n' is not a path starting with /" "$CODE $ERR"
check "a path ending in a newline sends no write" "" "$(since_mark | grep -v '^GET')"
mark
cfwj '{"command": "rate-limit", "args": {"target": "tm.example.com", "requests": 5, "path": "/api\n"}}'
check "rate-limit refuses a path ending in a newline" "2 cf: '/api\n' is not a path starting with /" "$CODE $ERR"
check "rate-limit with a path ending in a newline sends no write" "" "$(since_mark | grep -v '^GET')"

reset
mark
cfw allow-only-countries tm.example.com fr
check "allow-only-countries blocks every other country" 'block (http.host eq "tm.example.com" and not ip.src.country in {"FR"})' "$(last_put "/rulesets/phases/http_request_firewall_custom/entrypoint" | tail -1)"
check "allow-only-countries keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.com http_request_firewall_custom)"
mark
cfw challenge tm.example.com --path /admin --country RU --country CN
check "challenge composes host, path and countries" 'managed_challenge (http.host eq "tm.example.com" and starts_with(http.request.uri.path, "/admin") and ip.src.country in {"RU" "CN"})' "$(last_put "/rulesets/phases/http_request_firewall_custom/entrypoint" | tail -1)"
check "challenge keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.com http_request_firewall_custom)"
mark
cfwj '{"command": "challenge", "args": {"target": "api.example.com", "type": "js", "country": ["RU"]}}'
check "stdin json takes a list of countries and a challenge type" 'js_challenge (http.host eq "api.example.com" and ip.src.country in {"RU"})' "$(last_put "/rulesets/phases/http_request_firewall_custom/entrypoint" | tail -1)"
check "challenge from stdin json keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.com http_request_firewall_custom)"
cf rules example.com --plugin
check "rules --plugin shows the plugin's rules" "3" "$(col 1 | wc -l | tr -d ' ')"

reset
mark
cfw rule-add example.com --expression '(ip.src.asn eq 64500)' --action block --description 'from the agent'
check "rule-add takes a raw expression" "created	custom	block	yes	from the agent" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,2,4-6)"
check "rule-add keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.com http_request_firewall_custom)"
new_id=$(printf '%s\n' "$OUT" | head -1 | cut -f3)
cfw rule-add example.com --expression 'true' --action nuke
check "rule-add refuses an unknown action" "2" "$CODE"
mark
cfw rule-add example.com --expression 'true' --action log
check "the log action is refused on a Free zone" "5 cf: plan Free Website: the log action is not offered" "$CODE $ERR"
check "a refused log action sent no change" "" "$(since_mark | grep -v '^GET')"
mark
cfw rule-update example.com "$new_id" --no-enabled --description renamed
check "rule-update shows before and after" "before after" "$(printf '%s\n' "$OUT" | head -2 | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
check "rule-update keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.com http_request_firewall_custom)"
cf rules example.com
check "rule-update turned the rule off" "no" "$(printf '%s\n' "$OUT" | grep renamed | cut -f4)"
check "rule-update kept the dashboard rule" "1" "$(printf '%s\n' "$OUT" | grep -c 'dashboard: no wp-login')"
cfw rule-update example.com "$new_id"
check "rule-update with nothing to change exits 2" "2" "$CODE"
cfw rule-update example.com 00000000000000000000000000000000 --action block
check "an unknown rule exits 2" "2 cf: no rule 00000000000000000000000000000000 in example.com" "$CODE $ERR"
mark
cfw rule-delete example.com "$new_id"
del_bk=$(backup_of)
check "rule-delete prints the rule" "deleted" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
check "rule-delete keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.com http_request_firewall_custom)"
cf rules example.com
check "rule-delete kept the dashboard rule" "dashboard: no wp-login" "$(col 5)"
mark
cfw restore "$del_bk"
check "restore puts the ruleset back" "restored	custom	2 rules" "$(printf '%s\n' "$OUT" | head -1)"
check "restore keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.com http_request_firewall_custom)"
cf rules example.com
check "the deleted rule is back" "2" "$(col 1 | wc -l | tr -d ' ')"
cfw restore "$del_bk"
check "a restore with nothing to change says so" "nothing to restore: http_request_firewall_custom already matches the backup" "$OUT"

reset
cfw block-countries www.example.net FR
check "a zone with no entrypoint gets one, whole" "created" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
cfw restore "$(backup_of)"
check "restore of a backup taken with no entrypoint empties it" "restored	custom	0 rules" "$(printf '%s\n' "$OUT" | head -1)"

echo "== plans and quotas =="

reset
cfw rate-limit tm.example.com --requests 20 --period 60
check "a Free zone counts over 10 seconds only" "5 cf: plan Free Website: rate limiting counts over 10 seconds only" "$CODE $ERR"
check "a refused rate limit sent no change" "" "$(sent | grep -v '^GET')"
cfw rate-limit tm.example.com --requests 20
check "rate-limit creates a rule in its own phase" "created	ratelimit	block	yes	cf-plugin: rate-limit tm.example.com 20/10s" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,2,4-6)"
check "rate-limit sends the limit" "10 20 10" "$(curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin) if x["method"] == "PUT"][-1]["body"]["rules"][0]["ratelimit"]
print(r["period"], r["requests_per_period"], r["mitigation_timeout"])')"
mark
cfw rate-limit api.example.com --requests 5
check "a second rate limit on Free exits 5 naming the plan and the full quota" "5 cf: plan Free Website: rate limiting rules quota is full (1 of 1)" "$CODE $ERR"
check "a second rate limit on Free sent no change" "" "$(since_mark | grep -v '^GET')"
mark
cfw rate-limit tm.example.com --requests 20 --timeout 600
check "a Free zone mitigates for 10 seconds only" "5 cf: plan Free Website: the mitigation timeout takes 10 seconds only" "$CODE $ERR"
check "a refused mitigation timeout sent no change" "" "$(since_mark | grep -v '^GET')"
mark
cfw rate-limit example.org --requests 5
check "a Pro zone counts over 60 seconds and mitigates for 600 by default" "60 5 600" "$(curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin) if x["method"] == "PUT"][-1]["body"]["rules"][-1]["ratelimit"]
print(r["period"], r["requests_per_period"], r["mitigation_timeout"])')"
check "rate-limit keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.org http_ratelimit)"
# The Pro zone's two slots are taken: back to its dashboard rule alone.
reset
mark
cfw rate-limit www.example.org --requests 5 --period 60 --timeout 3600 --path /api
check "a Pro zone counts over a minute" "ratelimit" "$(printf '%s\n' "$OUT" | head -1 | cut -f2)"
check "rate-limit on a path keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.org http_ratelimit)"
mark
cfw rate-limit www.example.org --requests 5 --period 120
check "a Pro zone refuses two minutes" "5" "$CODE"
check "a Pro zone names the periods it counts over" \
  "cf: plan Pro Website: rate limiting counts over 10, 15, 20, 30, 40, 45, 60 seconds only" "$ERR"
check "a refused period sent no change" "" "$(since_mark | grep -v '^GET')"
mark
cfw rate-limit www.example.org --requests 5 --period 30 --timeout 25
check "a Pro zone refuses a mitigation timeout Cloudflare does not take" \
  "5 cf: plan Pro Website: the mitigation timeout takes 10, 15, 20, 30, 40, 45, 60, 90, 120, 180, 240, 300, 480, 600, 900, 1200, 1800, 2400, 3600 seconds only" "$CODE $ERR"
check "a refused mitigation timeout on Pro sent no change" "" "$(since_mark | grep -v '^GET')"
reset
mark
cfw rate-limit www.example.org --requests 5 --period 30 --timeout 1800
check "a Pro zone counts over any period it takes up to a minute" "30 1800" "$(curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin) if x["method"] == "PUT"][-1]["body"]["rules"][-1]["ratelimit"]
print(r["period"], r["mitigation_timeout"])')"
check "rate-limit over 30 seconds keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.org http_ratelimit)"

reset
cfw managed-rules example.com on
check "managed-rules on Free deploys the Free Managed Ruleset" 'execute true' "$(last_put "/rulesets/phases/http_request_firewall_managed/entrypoint")"
cfw managed-rules example.com on
check "managed-rules already on changes nothing" "unchanged" "$(printf '%s\n' "$OUT" | cut -f1)"
mark
cfw managed-rules example.com on --ruleset owasp
check "OWASP is refused on a Free zone" "5 cf: plan Free Website: no Cloudflare OWASP Core Ruleset" "$CODE $ERR"
check "a refused OWASP ruleset sent no change" "" "$(since_mark | grep -v '^GET')"
mark
cfw managed-rules example.org on
check "a Pro zone deploys the Cloudflare Managed Ruleset" "created" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
check "managed-rules on keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.org http_request_firewall_managed)"
mark
cfw managed-rules example.org off
check "managed-rules off on a Pro zone deletes the plugin's rule" "deleted" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
check "managed-rules off keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.org http_request_firewall_managed)"
cfw managed-rules example.com off
check "managed-rules off deletes the plugin's rule" "deleted" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
cfw managed-rules example.com off
check "managed-rules off with none changes nothing" "unchanged	free	off" "$OUT"

reset
cfw ip-block example.com 203.0.113.0/24 --note scanner
check "ip-block creates an access rule" "created	block	ip_range	203.0.113.0/24	scanner" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-5)"
ip_bk=$(backup_of)
cfw ip-block example.com 203.0.113.0/24
check "the same access rule twice changes nothing" "unchanged" "$(printf '%s\n' "$OUT" | cut -f1)"
cfw ip-allow example.com 203.0.113.0/24
check "ip-allow over a block changes its mode" "before	block	ip_range	203.0.113.0/24	scanner" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-5)"
check "ip-allow over a block shows the rule after it, allowed" "after	allow	ip_range	203.0.113.0/24	scanner" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1-5)"
cfw ip-block example.com AS64500
check "an AS number is a target" "created	block	asn	AS64500" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-4)"
cfw ip-block example.com ru
check "a country code is a target" "created	block	country	RU" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-4)"
cfw ip-block example.com not-an-ip
check "a target that is none exits 2" "2" "$CODE"
cfw ip-rule-delete example.com 198.51.100.7
check "ip-rule-delete takes a target" "deleted	block	ip	198.51.100.7	dashboard" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-5)"
del_ip_bk=$(backup_of)
cfw ip-rule-delete example.com 198.51.100.7
check "ip-rule-delete of nothing exits 2" "2" "$CODE"
cfw restore "$del_ip_bk"
check "restore recreates the access rule" "recreated	block	ip	198.51.100.7	dashboard" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-5)"
cf ip-rules example.com
check "the access rule is back, with the plugin's" "5" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
cfw restore "$ip_bk"
check "restore of the first backup removes what was added since" "deleted" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"

# last_body <method>: the path and the body (keys sorted) of the last request of this method.
last_body() {
  curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin) if x["method"] == sys.argv[1]][-1]
print(r["path"].replace("/client/v4", ""), json.dumps(r["body"], sort_keys=True))' "$1"
}
# backups_of <zone>: how many backups example.com's account holds for the zone.
backups_of() { ls "$WORK/backups/alpha/$1" 2>/dev/null | wc -l | tr -d ' '; }
ZONE_PATH=/zones/0123456789abcdef0123456789abcdef

reset
cfw ip-block example.com 2001:DB8::7 --note v6
check "an IPv6 address is an ip6 target" "created	block	ip6	2001:db8::7	v6" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-5)"
check "the rule posted for an IPv6 address names target ip6" \
  "$ZONE_PATH/firewall/access_rules/rules {\"configuration\": {\"target\": \"ip6\", \"value\": \"2001:db8::7\"}, \"mode\": \"block\", \"notes\": \"v6\"}" \
  "$(last_body POST)"
v6_id=$(printf '%s\n' "$OUT" | head -1 | cut -f6)
cfw ip-allow example.com 2001:db8::7
check "ip-allow over an IPv6 block patches that rule to allow" \
  "$ZONE_PATH/firewall/access_rules/rules/$v6_id {\"mode\": \"whitelist\", \"notes\": \"v6\"}" "$(last_body PATCH)"
cfw ip-block example.com 2001:db8::9/128
check "an IPv6 /128 is one address" "created	block	ip6	2001:db8::9" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-4)"
cfw ip-block example.com 203.0.113.9/32
check "an IPv4 /32 is one address" "created	block	ip	203.0.113.9" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-4)"
for range in 198.18.0.0/16 198.19.7.0/24 2001:db9::/32 2001:db8:2::/48 2001:db8:3:4::/64; do
  cfw ip-block example.com "$range"
  check "a $range range is an ip_range target" "created	block	ip_range" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-3)"
done
cfw ip-block example.com 2001:db9::/32
check "an IPv6 range is matched as an existing rule" "unchanged" "$(printf '%s\n' "$OUT" | cut -f1)"
for range in 0.0.0.0/0 ::/0 203.0.113.0/20 198.18.0.0/8 2001:db8::/56 2001:db8::/16; do
  taken_before=$(backups_of example.com)
  mark
  cfw ip-block example.com "$range"
  check "a $range range exits 2 naming the ranges IP access rules take" \
    "2 cf: $range: IP access rules take IPv4 ranges of /16 or /24 and IPv6 ranges of /32, /48 or /64" "$CODE $ERR"
  check "a refused $range range sends no write and takes no backup" "0 $taken_before" \
    "$(since_mark | grep -vc '^GET') $(backups_of example.com)"
done
taken_before=$(backups_of example.com)
mark
cfw ip-allow example.com 203.0.113.7/24
check "a range with host bits set exits 2" "2 cf: 203.0.113.7/24 has host bits set: the range is 203.0.113.0/24" "$CODE $ERR"
check "a range with host bits set sends no write and takes no backup" "0 $taken_before" \
  "$(since_mark | grep -vc '^GET') $(backups_of example.com)"

echo "== backups of the protection writes =="

# backup_holds <backup> <state read before the write, as --json printed it>:
# "same" when the backup file holds that state, else what it holds.
backup_holds() {
  python3 - "$1" "$2" <<'PYHOLDS'
import json, os, sys
path, before = sys.argv[1], json.loads(sys.argv[2])
if not os.path.isfile(path):
    sys.exit(print("no backup at " + path))
with open(path) as fh:
    data = json.load(fh)["data"]
if "settings" in data:
    held, read = data["settings"], {s["id"]: s["value"] for s in before}
else:
    held, read = data["rules"] or [], [{k: v for k, v in r.items() if k != "phase"} for r in before]
print("same" if held == read else "differs: " + json.dumps(held, sort_keys=True))
PYHOLDS
}
# backup_cycle <name> <method> <path suffix> <read command> -- <write command>:
# the write once, its backup holding the state read before it; then again from
# the same state with the write's own request failing: the backup was taken
# first and the error ends with it.
backup_cycle() {
  local name="$1" method="$2" suffix="$3" read_command="$4" before failed_bk
  shift 5
  reset
  cf $read_command --json
  before="$OUT"
  cfw "$@"
  check "$name takes a backup of the state before it" "same" "$(backup_holds "$(backup_of)" "$before")"
  reset
  fail_next "$method" "$suffix" 400 9999 "refused by the fixture"
  cfw "$@"
  failed_bk="${ERR##*; backup: }"
  check "$name failing on its write exits 3, its error ending with its backup" \
    "3 cf: Cloudflare 9999: refused by the fixture; backup: $failed_bk" "$CODE $ERR"
  check "$name failing on its write was backed up first" "same" "$(backup_holds "$failed_bk" "$before")"
}

backup_cycle rule-add PUT /rulesets/phases/http_request_firewall_custom/entrypoint "rules example.com --phase custom" -- \
  rule-add example.com --expression '(ip.src.asn eq 64500)' --action block
backup_cycle rule-update PUT /rulesets/phases/http_request_firewall_custom/entrypoint "rules example.com --phase custom" -- \
  rule-update example.com da5b0a4d000000000000000000000c01 --description renamed
backup_cycle rate-limit PUT /rulesets/phases/http_ratelimit/entrypoint "rules example.org --phase ratelimit" -- \
  rate-limit www.example.org --requests 5
backup_cycle managed-rules PUT /rulesets/phases/http_request_firewall_managed/entrypoint "rules example.org --phase managed" -- \
  managed-rules example.org on
backup_cycle ip-block POST /firewall/access_rules/rules "ip-rules example.com" -- \
  ip-block example.com 203.0.113.0/24
backup_cycle ip-allow PATCH /firewall/access_rules/rules/da5b0a4d000000000000000000000i01 "ip-rules example.com" -- \
  ip-allow example.com 198.51.100.7
backup_cycle security-level PATCH /settings/security_level "settings example.com security_level" -- \
  security-level example.com high
backup_cycle under-attack PATCH /settings/security_level "settings example.com security_level" -- \
  under-attack example.com on

echo "== end to end: a protection cycle on a Free zone at its quota =="

# example.edu is Free and holds four dashboard rules of its five slots.
reset
cfj '{"command": "plan", "account": "beta", "args": {"zone": "example.edu"}}'
check "e2e: the plan shows four of five rules used" "custom_rules	4	5" "$(printf '%s\n' "$OUT" | grep custom_rules)"
mark
cfwj '{"command": "block-countries", "account": "beta", "args": {"target": "tm.example.edu", "countries": ["RU", "CN"]}}'
check "e2e: block-countries takes the last slot" "created" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
check "e2e: block-countries keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.edu http_request_firewall_custom)"
mark
cfwj '{"command": "allow-only-countries", "account": "beta", "args": {"target": "api.example.edu", "countries": ["FR"]}}'
check "e2e: allow-only-countries merges under the quota" "before	custom	block" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,2,4)"
check "e2e: the merge keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.edu http_request_firewall_custom)"
check "e2e: allow-only-countries merges into the plugin's block rule" "merged" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1)"
cfj '{"command": "rules", "account": "beta", "args": {"zone": "example.edu"}}'
check "e2e: rules shows five rules, four of them the dashboard's" "5 4" "$(printf '%s\n' "$OUT" | sed 1d | wc -l | tr -d ' ') $(printf '%s\n' "$OUT" | grep -c 'dashboard:')"
check "e2e: the merged rule carries both hosts" "2" \
  "$(printf '%s\n' "$OUT" | grep 'cf-plugin' | cut -f6 | grep -o 'tm.example.edu\|api.example.edu' | wc -l | tr -d ' ')"
merged_id=$(printf '%s\n' "$OUT" | grep 'cf-plugin' | cut -f2)
mark
cfwj "{\"command\": \"rule-delete\", \"account\": \"beta\", \"args\": {\"zone\": \"example.edu\", \"rule\": \"$merged_id\"}}"
check "e2e: rule-delete removes the merged rule" "deleted" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
check "e2e: rule-delete keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.edu http_request_firewall_custom)"
cfj '{"command": "rules", "account": "beta", "args": {"zone": "example.edu", "plugin": true}}'
check "e2e: only the dashboard's four are left" "" "$OUT"
mark
cfwj "{\"command\": \"restore\", \"account\": \"beta\", \"args\": {\"path\": \"$(ls -d "$WORK"/backups/beta/example.edu/* | tail -1)\"}}"
check "e2e: restore from the delete's backup brings the merged rule back" "restored	custom	5 rules" "$(printf '%s\n' "$OUT" | head -1)"
check "e2e: restore keeps every dashboard rule of the phase whole" "kept" "$(foreign_kept example.edu http_request_firewall_custom)"
cfj '{"command": "rules", "account": "beta", "args": {"zone": "example.edu", "plugin": true}}'
check "e2e: the merged rule is back" "1" "$(printf '%s\n' "$OUT" | sed 1d | wc -l | tr -d ' ')"
reset_log_mark=$(sent | wc -l)
cfwj '{"command": "challenge", "account": "beta", "args": {"target": "www.example.edu"}}'
check "e2e: a write past the quota exits 5, naming the plan and the full quota" \
  "5 cf: plan Free Website: custom rules quota is full (5 of 5)" "$CODE $ERR"
check "e2e: the refused write sent no change" "0" "$(sent | tail -n +$((reset_log_mark + 1)) | grep -vc '^GET')"
cfwj '{"command": "ip-block", "account": "beta", "args": {"zone": "example.edu", "target": "2001:db8:abcd::/48", "note": "e2e"}}'
check "e2e: ip-block takes an IPv6 range" "created	block	ip_range	2001:db8:abcd::/48	e2e" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-5)"
cfwj '{"command": "ip-block", "account": "beta", "args": {"zone": "example.edu", "target": "2001:db8:abcd::1"}}'
check "e2e: ip-block takes an IPv6 address as an ip6 target" "created	block	ip6	2001:db8:abcd::1" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-4)"
e2e_v6_bk=$(backup_of)
cfj '{"command": "ip-rules", "account": "beta", "args": {"zone": "example.edu"}}'
check "e2e: ip-rules shows both IPv6 rules" "$(printf 'block\tip6\t2001:db8:abcd::1\nblock\tip_range\t2001:db8:abcd::/48')" "$(col 1-3 | LC_ALL=C sort)"
cfwj "{\"command\": \"restore\", \"account\": \"beta\", \"args\": {\"path\": \"$e2e_v6_bk\"}}"
check "e2e: restore from the ip6 rule's backup deletes it" "deleted	block	ip6	2001:db8:abcd::1" "$(printf '%s\n' "$OUT" | head -1 | cut -f1-4)"
cfj '{"command": "ip-rules", "account": "beta", "args": {"zone": "example.edu"}}'
check "e2e: the IPv6 range is left" "block	ip_range	2001:db8:abcd::/48" "$(col 1-3)"

echo "== cache rules =="

CACHE_EP="/rulesets/phases/http_request_cache_settings/entrypoint"
# last_body <method> <path suffix>: the JSON body of the last such request, compact.
last_body() {
  curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
found = [r for r in json.load(sys.stdin) if r["method"] == sys.argv[1] and r["path"].endswith(sys.argv[2])]
print(json.dumps(found[-1]["body"], sort_keys=True) if found else "none")' "$1" "$2"
}
# last_rule: the last rule of the last PUT to the cache entrypoint, as JSON.
last_rule() { last_body PUT "$CACHE_EP" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["rules"][-1], sort_keys=True))'; }
# The dashboard's cache rule of example.com as a write must send it back: all
# of it, its id and the field the engine does not know included, but for the
# read-only version and last_updated.
FOREIGN_ID=c0ffee00c0ffee00c0ffee00c0ffee00
FOREIGN_CACHE='{"action": "set_cache_settings", "action_parameters": {"cache": true}, "description": "dashboard: cache css", "enabled": true, "expression": "(http.request.uri.path.extension eq \"css\")", "id": "c0ffee00c0ffee00c0ffee00c0ffee00", "logging": {"enabled": true}}'
# foreign_sent: the dashboard's rule in the last PUT to the cache entrypoint.
foreign_sent() {
  last_body PUT "$CACHE_EP" | python3 -c '
import json, sys
print(json.dumps(next((r for r in json.load(sys.stdin)["rules"] if r.get("id") == sys.argv[1]), None), sort_keys=True))' "$FOREIGN_ID"
}
# foreign_read: the dashboard's rule in OUT, a cache-rules --json, its
# read-only fields dropped; then the number of rules read.
foreign_read() {
  printf '%s' "$OUT" | python3 -c '
import json, sys
rules = json.load(sys.stdin)
found = next((r for r in rules if r.get("id") == sys.argv[1]), None)
print(json.dumps(found and {k: v for k, v in found.items() if k not in ("version", "last_updated")}, sort_keys=True), len(rules))' "$FOREIGN_ID"
}

reset
cf cache-rules example.com
check "cache-rules header" "$(printf 'id\tmode\tenabled\tdescription\texpression')" "$(printf '%s\n' "$OUT" | head -1)"
check "cache-rules shows the dashboard's rule" "$(printf 'cache\tyes\tdashboard: cache css')" "$(col 2-4)"
cfw cache-rule-add example.com --host tm.example.com
check "cache-rule-add on a host caches everything" "$(printf 'created\tcache\tyes\tcf-plugin: cache tm.example.com\t(http.host eq "tm.example.com")')" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,3-6)"
cache_bk=$(backup_of)
check "the rule is a set_cache_settings that caches" '{"cache": true}' \
  "$(last_rule | python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps(r["action_parameters"]), r["action"])' | sed 's/ set_cache_settings$//')"
check "the dashboard's cache rule was sent back whole" "$FOREIGN_CACHE" "$(foreign_sent)"
cf cache-rules example.com --json
check "cache-rules reads the foreign rule back intact, beside the new one" "$FOREIGN_CACHE 2" "$(foreign_read)"
check "the backup is of kind ruleset and holds the entrypoint as it was" "1 http_request_cache_settings" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["data"]; print(len(d["rules"]), d["phase"])' "$cache_bk")"
cfw cache-rule-add example.com --host tm.example.com
check "the same cache rule twice changes nothing" "unchanged" "$(printf '%s\n' "$OUT" | cut -f1)"
check "…and sends no PUT" "" "$(writes)"

cfw cache-rule-add example.com --host api.example.com --path-prefix /static --mode ttl --ttl 7200
check "an edge TTL on a host and a path prefix" \
  '{"cache": true, "edge_ttl": {"default": 7200, "mode": "override_origin"}} (http.host eq "api.example.com" and starts_with(http.request.uri.path, "/static"))' \
  "$(last_rule | python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps(r["action_parameters"], sort_keys=True), r["expression"])')"
check "…sending the dashboard's rule back whole" "$FOREIGN_CACHE" "$(foreign_sent)"
cfw cache-rule-add example.com --path-prefix /private --mode bypass
check "bypass turns the cache off" '{"cache": false}' "$(last_rule | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["action_parameters"]))')"
check "…sending the dashboard's rule back whole" "$FOREIGN_CACHE" "$(foreign_sent)"
cfw cache-rule-add example.com --expression '(ip.src.asn eq 64500)' --mode bypass --description raw
check "a raw expression is taken whole" "(ip.src.asn eq 64500)" "$(printf '%s\n' "$OUT" | head -1 | cut -f6)"
check "…sending the dashboard's rule back whole" "$FOREIGN_CACHE" "$(foreign_sent)"
raw_id=$(printf '%s\n' "$OUT" | head -1 | cut -f2)
cfw cache-rule-add example.com --mode ttl --host a.example.com
check "ttl mode needs --ttl" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
cfw cache-rule-add example.com
check "a rule with no host, path or expression exits 2" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
cfw cache-rule-add example.com --host a.example.com --expression true
check "a raw expression excludes the simple forms" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
cfw cache-rule-add example.com --host 'a" or true or "b.example.com'
check "a host cannot carry an expression" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
cfw cache-rule-delete example.com "$raw_id"
check "cache-rule-delete prints the rule" "deleted" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
check "…sending the dashboard's rule back whole" "$FOREIGN_CACHE" "$(foreign_sent)"
del_cache_bk=$(backup_of)
cf cache-rules example.com --json
check "cache-rule-delete kept the foreign rule intact" "$FOREIGN_CACHE 4" "$(foreign_read)"
cfw cache-rule-delete example.com 00000000000000000000000000000000
check "an unknown cache rule exits 2" "2 cf: no cache rule 00000000000000000000000000000000 in example.com" "$CODE $ERR"
check "…and sends no write" "" "$(writes)"
cfw restore "$del_cache_bk"
check "restore puts the cache rules back" "$(printf 'restored\thttp_request_cache_settings\t5 rules')" "$(printf '%s\n' "$OUT" | head -1)"
check "…sending the dashboard's rule back whole" "$FOREIGN_CACHE" "$(foreign_sent)"
cf cache-rules example.com
check "the deleted cache rule is back" "1" "$(printf '%s\n' "$OUT" | grep -c 'raw')"

reset
fail_next PUT "$CACHE_EP" 400 20012 "bad rule"
cfw cache-rule-add example.com --host tm.example.com
check "a write that fails after its backup exits 3" "3" "$CODE"
check_contains "…and names the backup in its error line" "cf: Cloudflare 20012: bad rule; backup: $WORK/backups/alpha/example.com/" "$ERR"
check "…the refused PUT carried the dashboard's rule whole" "$FOREIGN_CACHE" "$(foreign_sent)"

# example.net is Free with no entrypoint yet; fill its ten slots.
reset
for i in 1 2 3 4 5 6 7 8 9 10; do cfw cache-rule-add example.net --host "h$i.example.net" >/dev/null; done
cfw cache-rule-add example.net --host h11.example.net
check "the eleventh cache rule of a Free zone exits 5 naming the plan and the quota" \
  "5 cf: plan Free Website: cache rules quota is full (10 of 10)" "$CODE $ERR"
check "the refused cache rule sent no change after the tenth" "10" "$(sent | grep -c "^PUT .*$CACHE_EP")"
check "…the refusal itself sent no write" "" "$(writes)"

echo "== purge =="

reset
cfw purge example.com --url https://example.com/a.css --url https://www.example.com/b.css
check "purge by URL says what it purged" "$(printf 'purged\tfiles\t2')" "$OUT"
check "purge by URL sends files" '{"files": ["https://example.com/a.css", "https://www.example.com/b.css"]}' "$(last_body POST /purge_cache)"
cfw purge example.com --host www.example.com
check "purge by host sends hosts" '{"hosts": ["www.example.com"]}' "$(last_body POST /purge_cache)"
cfw purge example.com --prefix www.example.com/img/
check "purge by prefix sends prefixes" '{"prefixes": ["www.example.com/img/"]}' "$(last_body POST /purge_cache)"
cfw purge example.com --tag a --tag b
check "purge by tag sends tags" '{"tags": ["a", "b"]}' "$(last_body POST /purge_cache)"
cfwj '{"command": "purge", "args": {"zone": "example.com", "url": ["https://example.com/x"]}}'
check "stdin json takes a list of URLs" '{"files": ["https://example.com/x"]}' "$(last_body POST /purge_cache)"
cfw purge example.com
check "purge with nothing to purge exits 2" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
cfw purge example.com --url https://example.com/a --tag a
check "purge takes one kind at a time" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
cfw purge example.com --url https://other.test/a
check "a URL outside the zone exits 2" "2 cf: https://other.test/a is not in example.com" "$CODE $ERR"
check "…and sends no write" "" "$(writes)"
cfw purge example.com --host other.test
check "a host outside the zone exits 2" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
reset
urls=$(for i in $(seq 1 101); do printf -- '--url=https://example.com/%s ' "$i"; done)
cfw purge example.com $urls
check "more URLs than the plan takes per call exits 5" "5 cf: plan Free Website: purge by URL takes 100 at a time, not 101" "$CODE $ERR"
check "…and sent no purge" "0" "$(sent | grep -c purge_cache)"
check "…and no write at all" "" "$(writes)"
cfw purge-all example.com
check "purge-all says so" "$(printf 'purged\teverything\texample.com')" "$OUT"
check "purge-all sends purge_everything" '{"purge_everything": true}' "$(last_body POST /purge_cache)"
cf purge-all example.com
check "cf.py refuses purge-all" "2 cf: purge-all writes: use cf-write.py" "$CODE $ERR"

echo "== Workers =="

printf 'export default { fetch() { return new Response("v2") } }\n' > "$WORK/hello.js"
printf 'export default { fetch() { return new Response("new") } }\n' > "$WORK/new.js"
# upload_of <script>: the parts of the last upload of a script, "name|filename|content type" per line.
upload_of() {
  curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
found = [r for r in json.load(sys.stdin) if r["method"] == "PUT" and r["path"].endswith("/workers/scripts/" + sys.argv[1])]
for p in found[-1]["body"]["__multipart"]:
    print("%s|%s|%s" % (p["name"], p["filename"], p["content_type"]))' "$1"
}
# framing_of <script>: how the last upload of a script was framed, "ok" when
# its Content-Type is multipart/form-data with a boundary, and its body is
# that boundary's parts and closing delimiter, nothing before or after.
framing_of() {
  curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, re, sys
found = [r for r in json.load(sys.stdin) if r["method"] == "PUT" and r["path"].endswith("/workers/scripts/" + sys.argv[1])]
body = found[-1]["body"]
m = re.fullmatch(r"multipart/form-data; boundary=([0-9a-f]{32})", body["__content_type"])
if not m:
    print("Content-Type " + body["__content_type"])
    sys.exit()
delimiter = "--" + m.group(1)
raw = body["__raw"]
parts = len(body["__multipart"])
ok = raw.startswith(delimiter + "\r\n") and raw.endswith("\r\n" + delimiter + "--\r\n") \
    and raw.count(delimiter) == parts + 1
print("ok" if ok else "body " + raw[:80])' "$1"
}
# part_of <script> <part>: the content of a part of the last upload of a script.
part_of() {
  curl -fsS "http://127.0.0.1:$PORT/__log" | python3 -c '
import json, sys
found = [r for r in json.load(sys.stdin) if r["method"] == "PUT" and r["path"].endswith("/workers/scripts/" + sys.argv[1])]
print(next(p["content"] for p in found[-1]["body"]["__multipart"] if p["name"] == sys.argv[2]))' "$1" "$2"
}

reset
cf workers
check "workers lists the scripts" "$(printf 'name\tmodified\tcompatibility_date\nhello\t2026-01-01T00:00:00Z\t2025-01-01')" "$OUT"
cfw worker-deploy fresh --file "$WORK/new.js" --compatibility-date 2026-02-01
check "worker-deploy says what it deployed" "$(printf 'deployed\tfresh\t2026-02-01')" "$OUT"
check "the upload is multipart: a metadata part and the module part" \
  "$(printf 'metadata|None|application/json\nnew.js|new.js|application/javascript+module')" "$(upload_of fresh)"
check "the metadata names the main module and the compatibility date" \
  '{"compatibility_date": "2026-02-01", "main_module": "new.js"}' \
  "$(part_of fresh metadata | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')"
check "the module part is the file's content" "$(cat "$WORK/new.js")" "$(part_of fresh new.js)"
check "the upload is framed by the boundary its Content-Type names" "ok" "$(framing_of fresh)"
cfw worker-deploy hello --file "$WORK/hello.js"
check "redeploying a script says what it deployed" "$(printf 'deployed\thello\t2025-01-01')" "$(printf '%s\n' "$OUT" | head -1)"
hello_bk=$(backup_of)
check "…after a backup of its previous content" "export default { fetch() { return new Response('hello') } }" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["content"].strip())' "$hello_bk")"
check "…and of its main module's name, read from the multipart content" "hello.js" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["main_module"])' "$hello_bk")"
check "redeploying keeps the script's bindings, its secrets among them, and its compatibility flags" \
  '{"compatibility_date": "2025-01-01", "compatibility_flags": ["nodejs_compat"], "keep_bindings": ["kv_namespace", "secret_text"], "main_module": "hello.js"}' \
  "$(part_of hello metadata | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')"
check "…and the script still has them" '[["CACHE", "kv_namespace"], ["API_KEY", "secret_text"]] ["nodejs_compat"]' \
  "$(fixture '[[b["name"], b["type"]] for b in s["scripts"]["hello"]["bindings"]]') $(fixture 's["scripts"]["hello"]["compatibility_flags"]')"
check "the redeployed module is the file's content" "$(cat "$WORK/hello.js")" "$(part_of hello hello.js)"
cfw worker-deploy bad --file "$WORK/nope.js"
check "a missing file exits 2" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
cfw worker-deploy 'bad name' --file "$WORK/new.js"
check "a script name is a plain name" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
cfw worker-delete hello
check "worker-delete prints the script" "deleted	hello" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,2)"
del_worker_bk=$(backup_of)
check "the delete's backup is of kind worker" "worker" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kind"])' "$del_worker_bk")"
cf workers
check "the script is gone" "fresh" "$(col 1)"
cfw worker-delete hello
check "deleting an unknown script exits 2" "2 cf: no Worker hello on account alpha" "$CODE $ERR"
check "…and sends no write" "" "$(writes)"
cfw restore "$del_worker_bk"
check "restore uploads the deleted script again" "restored	hello" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,2)"
cf workers
check "the script is back" "fresh hello" "$(col 1 | tr '\n' ' ' | sed 's/ $//')"
check "restore re-uploads the saved module, under its name" 'export default { fetch() { return new Response("v2") } }' "$(part_of hello hello.js)"

# The content of a script that is not one module cannot be saved faithfully:
# the write it was read for is refused before anything is changed.
reset
plant '{"id": "multi", "account": "acc-alpha", "main_module": "index.js", "content": "import x from \"./lib.js\"; export default x;\n", "extra_parts": [{"name": "lib.js", "content_type": "application/javascript+module", "content": "export default {}\n"}], "compatibility_date": "2025-01-01"}'
cfw worker-deploy multi --file "$WORK/new.js"
check "redeploying a script of several modules exits 5" \
  "5 cf: cannot save the Worker multi faithfully: its content holds 2 parts, not its main module alone; nothing was changed" "$CODE $ERR"
check "…and sends no write" "" "$(writes)"
cfw worker-delete multi
check "deleting a script of several modules exits 5" "5" "$CODE"
check "…and sends no write" "" "$(writes)"
plant '{"id": "noentry", "account": "acc-alpha", "main_module": "index.js", "content": "export default {}\n", "no_entrypoint": true, "compatibility_date": "2025-01-01"}'
cfw worker-deploy noentry --file "$WORK/new.js"
check "a multipart content that names no main module exits 5" \
  "5 cf: cannot save the Worker noentry faithfully: its multipart content names no main module (cf-entrypoint); nothing was changed" "$CODE $ERR"
check "…and sends no write" "" "$(writes)"
cfw worker-deploy fresh --file "$WORK/new.js" >/dev/null
cfw worker-deploy fresh --file "$WORK/hello.js"
fresh_bk=$(backup_of)
plant '{"id": "fresh", "account": "acc-alpha", "main_module": "new.js", "content": "export default {}\n", "extra_parts": [{"name": "map.js.map", "content_type": "application/source-map", "content": "{}"}], "compatibility_date": "2025-01-01"}'
cfw restore "$fresh_bk"
check "restoring over a script that cannot be saved faithfully exits 5" "5" "$CODE"
check "…and sends no write" "" "$(writes)"

# A service-worker script's content is plain text: it is saved whole, and
# restored as a service worker.
plant '{"id": "classic", "account": "acc-alpha", "body_part": "script.js", "content": "addEventListener(\"fetch\", e => e.respondWith(new Response(\"classic\")))\n", "compatibility_date": "2024-01-01"}'
cfw worker-delete classic
classic_bk=$(backup_of)
check "a service worker's plain-text content is saved whole, with no main module" \
  '"addEventListener(\"fetch\", e => e.respondWith(new Response(\"classic\")))\n" null' \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["data"]; print(json.dumps(d["content"]), json.dumps(d["main_module"]))' "$classic_bk")"
cfw restore "$classic_bk"
check "restore uploads it back as a service worker" \
  "$(printf 'metadata|None|application/json\nworker.js|worker.js|application/javascript')" "$(upload_of classic)"
check "…its metadata naming the body part" '{"body_part": "worker.js", "compatibility_date": "2024-01-01"}' \
  "$(part_of classic metadata | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')"
check "…and the script is the saved one" '"addEventListener(\"fetch\", e => e.respondWith(new Response(\"classic\")))\n"' \
  "$(fixture 's["scripts"]["classic"]["content"]')"

reset
cf worker-routes example.com
check "worker-routes lists the zone's routes" "$(printf 'pattern\tscript')" "$(printf '%s\n' "$OUT" | head -1 | cut -f2,3)"
check "…the foreign route among them" "example.com/legacy/*	legacy" "$(col 2,3)"
cfw worker-route-add example.com 'tm.example.com/*' hello
check "worker-route-add creates the route" "created	tm.example.com/*	hello" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,3,4)"
route_bk=$(backup_of)
route_id=$(printf '%s\n' "$OUT" | head -1 | cut -f2)
check "the route body is a pattern and a script" '{"pattern": "tm.example.com/*", "script": "hello"}' "$(last_body POST /workers/routes)"
check "the routes backup holds the foreign route" "1" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["data"]["routes"]))' "$route_bk")"
cfw worker-route-add example.com 'tm.example.com/*' hello
check "a duplicate route is Cloudflare's refusal" "3" "$CODE"
check_contains "…naming the backup" "; backup: " "$ERR"
cfw worker-route-add example.com 'other.test/*' hello
check "a pattern outside the zone exits 2" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
cfw worker-route-add example.com 'tm.example.com/*' nope
check "a route to an unknown script exits 2" "2 cf: no Worker nope on account alpha" "$CODE $ERR"
check "…and sends no write" "" "$(writes)"
cfw worker-route-delete example.com "$route_id"
check "worker-route-delete prints the route" "deleted	tm.example.com/*	hello" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,3,4)"
del_route_bk=$(backup_of)
cf worker-routes example.com
check "the foreign route is intact" "1" "$(col 1 | wc -l | tr -d ' ')"
cfw restore "$del_route_bk"
check "restore brings the deleted route back" "recreated	tm.example.com/*	hello" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,3,4)"
cfw worker-route-delete example.com 'legacy-nope/*'
check "an unknown route exits 2" "2" "$CODE"
check "…and sends no write" "" "$(writes)"
# example.net has a route that runs no script.
cfw worker-route-add example.net 'example.net/on/*' hello
off_bk=$(backup_of)
cfw worker-route-delete example.net 'example.net/off/*'
cfw restore "$off_bk"
check "restore recreates a route with no script without naming one" '{"pattern": "example.net/off/*"}' "$(last_body POST /workers/routes)"

reset
cfw worker-domain-add tm.example.com hello
check "worker-domain-add attaches the hostname" "attached	tm.example.com	hello" "$(printf '%s\n' "$OUT" | cut -f1,2,3)"
check "the domain body names the zone" \
  '{"hostname": "tm.example.com", "service": "hello", "zone_id": "0123456789abcdef0123456789abcdef", "zone_name": "example.com"}' \
  "$(last_body PUT /workers/domains)"
cfw worker-domain-add tm.example.com hello
check "attaching the same pair twice changes nothing" "unchanged	tm.example.com	hello" "$OUT"
cfw worker-deploy fresh --file "$WORK/new.js"
cfw worker-domain-add tm.example.com fresh
check "a hostname already on another Worker exits 5" \
  "5 cf: plan Free Website: tm.example.com is already attached to the Worker hello" "$CODE $ERR"
check "…sends no PUT to the account's custom domains" "" "$(writes | grep '/workers/domains')"
check "…and sends no write at all" "" "$(writes)"
check "…and the hostname is still on its script" '"hello"' "$(fixture 's["domains"]["tm.example.com"]["service"]')"
cfw worker-domain-add tm2.example.com nope
check "a domain for an unknown script exits 2" "2" "$CODE"
check "…and sends no write" "" "$(writes)"

reset
cf worker-domains
check "worker-domains lists the account's custom domains" \
  "$(printf 'id\thostname\tservice\tzone_name\ndom-legacy\tlegacy.example.com\thello\texample.com\ndom-net\tapp.example.net\thello\texample.net')" "$OUT"
cf worker-domains example.com
check "worker-domains <zone> lists the zone's alone" "legacy.example.com" "$(col 2)"
check "…asking Cloudflare for the zone's" "zone_id=0123456789abcdef0123456789abcdef" "$(sent | grep '/workers/domains' | tail -1 | sed 's/.*?//')"
cf worker-domains --json
check "worker-domains --json gives the objects" "legacy.example.com app.example.net" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(" ".join(d["hostname"] for d in json.load(sys.stdin)))')"
reset
cfw worker-domain-delete nope.example.com
check "worker-domain-delete of an unknown domain exits 2, naming it" "2 cf: no custom domain nope.example.com on account alpha" "$CODE $ERR"
check "…writing nothing, and taking no backup" " 0" \
  "$(sent | grep -v '^GET') $(ls "$WORK/backups/alpha/example.com/"*-worker-domain.json 2>/dev/null | wc -l | tr -d ' ')"
cfw worker-domain-delete Legacy.Example.com
check "worker-domain-delete detaches the hostname, after its backup" \
  "deleted	legacy.example.com	hello	example.com" "$(printf '%s\n' "$OUT" | head -1)"
domain_bk=$(backup_of)
check "…one write: the domain's deletion" "DELETE /accounts/acc-alpha/workers/domains/dom-legacy" "$(sent | grep -v '^GET')"
check "…its backup of kind worker-domain, under the zone, holding the domain" "worker-domain example.com legacy.example.com hello" \
  "$(python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); print(b["kind"], b["zone"], b["data"]["domain"]["hostname"], b["data"]["domain"]["service"])' "$domain_bk")"
cf worker-domains
check "…the other domains kept" "app.example.net" "$(col 2)"
cfw restore "$domain_bk"
check "restore attaches the deleted domain again" "restored	legacy.example.com	hello	example.com" "$(printf '%s\n' "$OUT" | head -1)"
check "…by one PUT of its hostname, script and zone" \
  '{"hostname": "legacy.example.com", "service": "hello", "zone_id": "0123456789abcdef0123456789abcdef", "zone_name": "example.com"}' \
  "$(last_body PUT /workers/domains)"
cf worker-domains
check "…beside the others" "app.example.net legacy.example.com" "$(col 2 | sort | tr '\n' ' ' | sed 's/ $//')"
cfw restore "$domain_bk"
check "…and a second restore has nothing to do" "0 nothing to restore" "$CODE $(printf '%s' "$OUT" | cut -c1-18)"
cf worker-domain-delete app.example.net
check "worker-domain-delete is a write: cf.py refuses it" "2 cf: worker-domain-delete writes: use cf-write.py" "$CODE $ERR"

echo "== end to end: a cache and Workers cycle =="

reset
cfwj '{"command": "cache-rule-add", "args": {"zone": "example.com", "host": "tm.example.com"}}'
check "e2e: cache-rule-add on a host" "created" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
check "e2e: the write sent the dashboard's cache rule back whole" "$FOREIGN_CACHE" "$(foreign_sent)"
cfj '{"command": "cache-rules", "args": {"zone": "example.com", "json": true}}'
check "e2e: cache-rules reads the foreign rule back intact, beside the new one" "$FOREIGN_CACHE 2" "$(foreign_read)"
cfwj '{"command": "purge", "args": {"zone": "example.com", "url": ["https://tm.example.com/a.css"]}}'
check "e2e: purge by URL" "$(printf 'purged\tfiles\t1')" "$OUT"
cfwj "{\"command\": \"worker-deploy\", \"args\": {\"name\": \"tm\", \"file\": \"$WORK/new.js\"}}"
check "e2e: worker-deploy" "deployed" "$(printf '%s\n' "$OUT" | cut -f1)"
cfwj '{"command": "worker-route-add", "args": {"zone": "example.com", "pattern": "tm.example.com/*", "script": "tm"}}'
check "e2e: worker-route-add" "created" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
cfwj "{\"command\": \"worker-deploy\", \"args\": {\"name\": \"hello\", \"file\": \"$WORK/hello.js\"}}"
check "e2e: redeploying a script keeps its bindings" '[["CACHE", "kv_namespace"], ["API_KEY", "secret_text"]]' \
  "$(fixture '[[b["name"], b["type"]] for b in s["scripts"]["hello"]["bindings"]]')"
cfwj '{"command": "worker-delete", "args": {"name": "tm"}}'
check "e2e: worker-delete" "deleted" "$(printf '%s\n' "$OUT" | head -1 | cut -f1)"
e2e_bk=$(backup_of)
check "e2e: the backup holds the main module read from the multipart content" "new.js $(cat "$WORK/new.js")" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["data"]; print(d["main_module"], d["content"])' "$e2e_bk")"
cfwj "{\"command\": \"restore\", \"args\": {\"path\": \"$e2e_bk\"}}"
check "e2e: restore of the deleted script" "restored	tm" "$(printf '%s\n' "$OUT" | head -1 | cut -f1,2)"
cfj '{"command": "workers"}'
check "e2e: the script is back" "1" "$(printf '%s\n' "$OUT" | grep -c '^tm')"
check "e2e: …as the module it was" "$(cat "$WORK/new.js")" "$(part_of tm new.js)"

echo "== Caddy: the fixtures =="

# A fake caddy binary (tests/fixtures/caddy/fake-caddy.py) and a fake running
# Caddy (world.py): a TLS listener standing for 127.0.0.1:443 and an admin
# API, both answering from world.json, which each fake reload rewrites. The
# Caddyfile, its envfile and the service files are made under $WORK from the
# config's paths: nothing of the machine's Caddy is read, run or probed.
CADDY="$WORK/caddy"
CSTATE="$CADDY/state"
mkdir -p "$CADDY/etc" "$CSTATE" "$CADDY/bin"
# The sites' certificate is issued by a fixture CA, which check trusts
# through SSL_CERT_FILE; the probe of the cycle does not verify it.
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:example.com,DNS:*.example.com\nauthorityKeyIdentifier=keyid\n' > "$CADDY/leaf.ext"
{ openssl req -x509 -newkey rsa:2048 -nodes -subj "/O=Fixture Trust/CN=Fixture CA" -days 2 \
    -addext "keyUsage=critical,keyCertSign,cRLSign" -keyout "$CADDY/ca-key.pem" -out "$CADDY/ca.pem" \
  && openssl req -newkey rsa:2048 -nodes -subj /CN=example.com -keyout "$CADDY/key.pem" -out "$CADDY/leaf.csr" \
  && openssl x509 -req -in "$CADDY/leaf.csr" -CA "$CADDY/ca.pem" -CAkey "$CADDY/ca-key.pem" -CAcreateserial \
    -days 2 -extfile "$CADDY/leaf.ext" -out "$CADDY/cert.pem"; } >/dev/null 2>&1 \
  || { echo "openssl could not make the fixture certificates"; exit 1; }
printf '{"alive": true, "sites": {}}\n' > "$CSTATE/world.json"
python3 "$FIXTURES/caddy/world.py" "$CSTATE" "$CADDY/cert.pem" "$CADDY/key.pem" "$CADDY/ports" &
WORLD_PID=$!
for _ in $(seq 1 50); do
  [ -s "$CADDY/ports" ] && break
  sleep 0.1
done
read -r TLS_PORT ADMIN_PORT < "$CADDY/ports" || { echo "the fake Caddy did not start"; exit 1; }

CADDY_TOKEN=cf-caddy-fixture-token-5e1d2a9b
CADDYFILE="$CADDY/etc/Caddyfile"
ENVFILE="$CADDY/etc/caddy.env"
PLIST="$CADDY/homebrew.mxcl.caddy.plist"
UNIT="$CADDY/caddy.service"
FAKE_CADDY="$FIXTURES/caddy/fake-caddy.py"
printf '# the DNS-01 token\nCF_API_TOKEN=%s\nLOG=info\n' "$CADDY_TOKEN" > "$ENVFILE"
chmod 600 "$ENVFILE"
# plist <path> <with envfile: yes|no>: a launchd service as Homebrew writes it.
plist() {
  python3 - "$1" "$2" "$FAKE_CADDY" "$CADDYFILE" "$ENVFILE" <<'PYPLIST'
import plistlib, sys
path, with_env, binary, caddyfile, envfile = sys.argv[1:6]
args = [binary, "run", "--config", caddyfile] + (["--envfile", envfile] if with_env == "yes" else [])
with open(path, "wb") as fh:
    plistlib.dump({"Label": "homebrew.mxcl.caddy", "ProgramArguments": args, "RunAtLoad": True}, fh)
PYPLIST
}
plist "$PLIST" yes
plist "$CADDY/noenv.plist" no
printf '[Unit]\nDescription=Caddy\n\n[Service]\nUser=caddy\nEnvironmentFile=-%s\nExecStart=/usr/bin/caddy run --config %s\nExecReload=/usr/bin/caddy reload --config %s\n' \
  "$ENVFILE" "$CADDYFILE" "$CADDYFILE" > "$UNIT"
printf '[Service]\nExecStart=/usr/bin/caddy run --config %s\n' "$CADDYFILE" > "$CADDY/noenv.service"

# caddy_config <file> [extra keys]: the config with a caddy section on the fakes.
caddy_config() {
  printf '{"default_account": "alpha", "env_files": ["~/.env"], "backup_dir": "%s", "caddy": {"manager": "launchd", "binary": "%s", "caddyfile": "%s", "envfile": "%s", "service": "%s", "tls_snippet": "tls_config", "sudo": false, "admin": "127.0.0.1:%s"%s}}\n' \
    "$WORK/backups" "$FAKE_CADDY" "$CADDYFILE" "$ENVFILE" "$PLIST" "$ADMIN_PORT" "${2:-}" > "$1"
}
CADDY_CONFIG="$WORK/caddy-config.json"
caddy_config "$CADDY_CONFIG"
# caddy_env: what every Caddy run adds to the engine's environment.
caddy_env() { printf 'CLAUDE_CLOUDFLARE_CONFIG=%s CF_CADDY_PROBE=127.0.0.1:%s FAKE_CADDY_STATE=%s %s' "${CCONF:-$CADDY_CONFIG}" "$TLS_PORT" "$CSTATE" "${CADDY_EXTRA:-}"; }
cdy() { EXTRA_ENV="$(caddy_env)" cf "$@"; }
cdyw() { EXTRA_ENV="$(caddy_env)" cfw "$@"; }
cdyj() { EXTRA_ENV="$(caddy_env)" cfj "$1"; }
cdywj() { EXTRA_ENV="$(caddy_env)" cfwj "$1"; }

# caddy_reset: the fixture Caddyfile in place, every site answering 200, no
# copy, no call recorded, nothing queued for the fake binary.
caddy_reset() {
  cp "$FIXTURES/caddy/Caddyfile" "$CADDYFILE"
  rm -f "$CADDYFILE".bak-* "$CSTATE/validate" "$CSTATE/reload" "$CSTATE/calls.jsonl" "$CSTATE/sudo.log" "$CSTATE/hung.pids"
  printf '{"alive": true, "sites": {"app.example.com": 200, "www.example.com": 200, "a.example.com": 200, "b.example.com": 200}}\n' > "$CSTATE/world.json"
}
# calls: the fake binary's commands since the last reset, space-separated.
calls() {
  [ -f "$CSTATE/calls.jsonl" ] || return 0
  python3 -c 'import json,sys; print(" ".join(json.loads(l)["argv"][0] for l in open(sys.argv[1])))' "$CSTATE/calls.jsonl"
}
# copies: how many copies of the Caddyfile lie beside it.
copies() { ls "$CADDYFILE".bak-* 2>/dev/null | wc -l | tr -d ' '; }
same() { cmp -s "$1" "$2" && echo same || echo differs; }
# untouched: whether the Caddyfile is the original, then the copies and the calls.
untouched() { printf '%s %s %s' "$(same "$CADDYFILE" "$ORIGINAL")" "$(copies)" "$(calls)"; }
# envfile_everywhere: "yes" when every caddy call had the envfile's token in
# its environment, else the commands that did not.
envfile_everywhere() {
  python3 -c 'import json,sys; m=[c["argv"][0] for c in map(json.loads, open(sys.argv[1])) if c["env"].get("CF_API_TOKEN") != sys.argv[2]]; print(" ".join(m) or "yes")' \
    "$CSTATE/calls.jsonl" "$CADDY_TOKEN"
}
# user_only <what>: false, saying so, when the suite runs as root, whom no mode stops.
user_only() {
  [ "$(id -u)" != 0 ] && return 0
  echo "  skip $1: the suite runs as root"
  return 1
}
# inject <python> <command> [args...]: the engine's main after the Python
# (a patch of the engine) has run, in cdy's environment; OUT, ERR and CODE
# as run sets them. What it prints is not kept: a patch may raise on purpose.
inject() {
  local patch="$1"
  shift
  env -i PATH="$PATH" HOME="$HOMEDIR" CF_API_BASE="$API" $(caddy_env) \
    python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import cf; from cflib import caddy, caddyctl; exec(sys.argv[2]); sys.exit(cf.main(sys.argv[3:], writes=not cf.is_read(cf.build_parser(), sys.argv[3])))' \
    "$ENGINE" "$patch" "$@" >"$WORK/out" 2>"$WORK/err"
  CODE=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
}
# alive <pid...>: those of the pids still running, each followed by a space.
alive() {
  for _ in $(seq 1 20); do
    left=""
    for pid in "$@"; do kill -0 "$pid" 2>/dev/null && left="$left$pid "; done
    [ -z "$left" ] && break
    sleep 0.1
  done
  printf '%s' "$left"
}
BODY="$FIXTURES/caddy/body-proxy.caddy"
ORIGINAL="$FIXTURES/caddy/Caddyfile"

echo "== Caddy: reads =="

caddy_reset
cdy caddy-sites
check "caddy-sites lists every site block with its line and its upstreams" \
  "$(printf 'address\tline\treverse_proxy\n:80\t13\t-\nhttps://app.example.com\t18\t127.0.0.1:8080\nwww.example.com\t24\t-\na.example.com,b.example.com\t34\t127.0.0.1:9000\n*.example.com\t39\t-\nhttp://plain.example.com\t44\t-')" \
  "$OUT"
check "caddy-sites runs no caddy" "" "$(calls)"
cdy caddy-sites --json
check "caddy-sites --json gives the blocks, snippets and global options included" "global snippet site site site site site site" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(" ".join(b["kind"] for b in json.load(sys.stdin)))')"

cdy caddy-site www.example.com
check "caddy-site prints the block as written, its quoted, commented and heredoc braces included" \
  "$(sed -n 24,32p "$ORIGINAL")" "$OUT"
cdy caddy-site b.example.com
check "caddy-site finds a host in a block of several" "$(sed -n 34,37p "$ORIGINAL")" "$OUT"
cdy caddy-site zz.example.com
check "caddy-site serves a host covered by a wildcard from the wildcard's block" "$(sed -n 39,42p "$ORIGINAL")" "$OUT"
cdy caddy-site '*.example.com'
check "caddy-site reads a wildcard block by its address" "$(sed -n 39,42p "$ORIGINAL")" "$OUT"
cdy caddy-site nothere.example.org
check "caddy-site on a host with no block exits 2" "2" "$CODE"
check_contains "…naming the Caddyfile" "cf: no site block for nothere.example.org in $CADDYFILE" "$ERR"
cdy caddy-site 'bad host'
check "caddy-site refuses a host that is not a name" "2" "$CODE"
cdy caddy-site app.example.com --json
check "caddy-site --json gives the block's address and lines" "https://app.example.com 18 22" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; b=json.load(sys.stdin)[0]; print(b["address"], b["line"], b["end_line"])')"

cdy caddy-status
check "caddy-status checks the binary, the admin API, the Caddyfile, validate, the envfile and the service" \
  "$(printf 'check\tstate\nbinary\tok\nadmin\talive\ncaddyfile\tok\nvalidate\tok\nenvfile\tok\nservice\tok')" \
  "$(printf '%s\n' "$OUT" | cut -f1,2)"
check_contains "caddy-status names the version" "v2.8.4" "$OUT"
check_contains "caddy-status counts the sites" "$CADDYFILE: 6 sites" "$OUT"
check_contains "caddy-status says the service loads the envfile" "launchd $PLIST: --envfile $ENVFILE" "$OUT"
check "caddy-status runs only version and validate" "version validate" "$(calls)"
check "…each with the envfile's variables" "yes" "$(envfile_everywhere)"
check "a launchd service with its envfile gives no warning" "0" "$(printf '%s\n' "$OUT" | grep -c '^warning:')"
caddy_config "$WORK/caddy-goneenv.json" ", \"envfile\": \"$CADDY/etc/gone.env\""
CCONF="$WORK/caddy-goneenv.json" inject 'caddyctl.Settings.variables = lambda self: {}' caddy-status
check "an envfile gone between its reading and its mode is unreadable in caddy-status, no traceback" \
  "0 $(printf 'envfile\tunreadable')" "$CODE $(printf '%s\n' "$OUT" | grep '^envfile' | cut -f1,2)"
check "…and nothing else is raised" "" "$ERR"

caddy_config "$WORK/caddy-noenv.json" ", \"service\": \"$CADDY/noenv.plist\""
CCONF="$WORK/caddy-noenv.json" cdy caddy-status
check "a launchd service without --envfile is a warning" \
  "warning: $CADDY/noenv.plist does not start caddy with --envfile $ENVFILE: a restart of the service would run caddy without its variables" \
  "$(printf '%s\n' "$OUT" | grep '^warning:')"
check "…and its row says so" "$(printf 'service\tno-envfile')" "$(printf '%s\n' "$OUT" | grep '^service' | cut -f1,2)"

caddy_config "$WORK/caddy-systemd.json" ", \"manager\": \"systemd\", \"service\": \"$UNIT\""
CCONF="$WORK/caddy-systemd.json" cdy caddy-status
check "a systemd unit with EnvironmentFile= is ok" "$(printf 'service\tok\tsystemd %s: EnvironmentFile=%s' "$UNIT" "$ENVFILE")" \
  "$(printf '%s\n' "$OUT" | grep '^service')"
mkdir -p "$CADDY/dropin.service.d"
printf '[Service]\nExecStart=/usr/bin/caddy run\n' > "$CADDY/dropin.service"
printf '[Service]\nEnvironmentFile=%s\n' "$ENVFILE" > "$CADDY/dropin.service.d/override.conf"
caddy_config "$WORK/caddy-dropin.json" ", \"manager\": \"systemd\", \"service\": \"$CADDY/dropin.service\""
CCONF="$WORK/caddy-dropin.json" cdy caddy-status
check "a systemd drop-in beside the unit counts" "$(printf 'service\tok')" "$(printf '%s\n' "$OUT" | grep '^service' | cut -f1,2)"
caddy_config "$WORK/caddy-systemd-noenv.json" ", \"manager\": \"systemd\", \"service\": \"$CADDY/noenv.service\""
CCONF="$WORK/caddy-systemd-noenv.json" cdy caddy-status
check "a systemd unit without EnvironmentFile= is a warning" \
  "warning: $CADDY/noenv.service has no EnvironmentFile=$ENVFILE: a restart of the service would run caddy without its variables" \
  "$(printf '%s\n' "$OUT" | grep '^warning:')"

# service_state <manager> <service file>: caddy-status's service row, check and state.
service_state() {
  caddy_config "$WORK/caddy-svc.json" ", \"manager\": \"$1\", \"service\": \"$2\""
  CCONF="$WORK/caddy-svc.json" cdy caddy-status
  printf '%s\n' "$OUT" | grep '^service' | cut -f2
}
mkdir -p "$CADDY/reset.service.d"
printf '[Service]\nEnvironmentFile=%s\n' "$ENVFILE" > "$CADDY/reset.service"
printf '[Service]\nEnvironmentFile=\n' > "$CADDY/reset.service.d/override.conf"
check "a drop-in's empty EnvironmentFile= resets the unit's" "no-envfile" "$(service_state systemd "$CADDY/reset.service")"
printf '[Service]\nEnvironmentFile=\nEnvironmentFile=-"%s"\n' "$ENVFILE" > "$CADDY/reset.service.d/override.conf"
check "…and one set after the reset counts, quoted and with its - prefix" "ok" "$(service_state systemd "$CADDY/reset.service")"
printf '[Service]\nEnvironmentFile="%s"\n' "$ENVFILE" > "$CADDY/quoted.service"
check "a quoted EnvironmentFile= path counts" "ok" "$(service_state systemd "$CADDY/quoted.service")"
printf "[Service]\nEnvironmentFile='%s'\n" "$ENVFILE" > "$CADDY/single.service"
check "…single-quoted too" "ok" "$(service_state systemd "$CADDY/single.service")"
printf '[Service]\nEnvironmentFile=-%s\n' "$ENVFILE" > "$CADDY/dash.service"
check "a - prefixed EnvironmentFile= counts" "ok" "$(service_state systemd "$CADDY/dash.service")"
python3 - "$CADDY/sh.plist" "$ENVFILE" <<'PYSH'
import plistlib, sys
with open(sys.argv[1], "wb") as fh:
    plistlib.dump({"Label": "caddy", "ProgramArguments": ["/bin/sh", "-c", "exec caddy run --config /srv/Caddyfile --envfile '%s'" % sys.argv[2]]}, fh)
PYSH
check "a launchd service running sh -c \"caddy run --envfile x\" counts" "ok" "$(service_state launchd "$CADDY/sh.plist")"
python3 - "$CADDY/eq.plist" "$ENVFILE" <<'PYEQ'
import plistlib, sys
with open(sys.argv[1], "wb") as fh:
    plistlib.dump({"Label": "caddy", "ProgramArguments": ["caddy", "run", "--envfile=" + sys.argv[2]]}, fh)
PYEQ
check "a launchd service with --envfile=PATH counts" "ok" "$(service_state launchd "$CADDY/eq.plist")"

chmod 644 "$ENVFILE"
cdy caddy-status
check "an envfile others can read is a warning" "warning: $ENVFILE is readable by others (mode 644): chmod 600 it" \
  "$(printf '%s\n' "$OUT" | grep '^warning:')"
chmod 600 "$ENVFILE"

printf '{"alive": true, "admin_status": 500, "sites": {}}\n' > "$CSTATE/world.json"
cdy caddy-status
check "an admin API that answers 500 is not alive" "$(printf 'admin\tdown')" "$(printf '%s\n' "$OUT" | grep '^admin' | cut -f1,2)"
caddy_config "$WORK/caddy-nosvc.json" ", \"service\": \"$CADDY/absent.plist\""
CCONF="$WORK/caddy-nosvc.json" cdy caddy-status
check "a service file that cannot be read is unreadable, with a warning" "$(printf 'service\tunreadable') 1" \
  "$(printf '%s\n' "$OUT" | grep '^service' | cut -f1,2) $(printf '%s\n' "$OUT" | grep -c "^warning: cannot read $CADDY/absent.plist")"
printf 'not a plist' > "$CADDY/garbage.plist"
caddy_config "$WORK/caddy-badsvc.json" ", \"service\": \"$CADDY/garbage.plist\""
CCONF="$WORK/caddy-badsvc.json" cdy caddy-status
check "a service file that is no plist is unreadable" "$(printf 'service\tunreadable')" "$(printf '%s\n' "$OUT" | grep '^service' | cut -f1,2)"
printf '{"default_account": "alpha", "env_files": ["~/.env"], "backup_dir": "%s", "caddy": {"binary": "%s", "caddyfile": "%s", "envfile": "%s", "admin": "127.0.0.1:%s"}}\n' \
  "$WORK/backups" "$FAKE_CADDY" "$CADDYFILE" "$ENVFILE" "$ADMIN_PORT" > "$WORK/caddy-nomanager.json"
CCONF="$WORK/caddy-nomanager.json" cdy caddy-status
check "no manager in the config: the service is not checked" "$(printf 'service\t-\tno manager in the config')" \
  "$(printf '%s\n' "$OUT" | grep '^service')"

printf '{"alive": false, "sites": {}}\n' > "$CSTATE/world.json"
cdy caddy-status
check "caddy-status says when the admin API does not answer" "$(printf 'admin\tdown')" "$(printf '%s\n' "$OUT" | grep '^admin' | cut -f1,2)"
check_contains "…with a warning" "warning: caddy's admin API does not answer" "$OUT"

caddy_reset
printf 'fail adapting config using caddyfile: Caddyfile:20: unrecognized directive: revers_proxy\n' > "$CSTATE/validate"
cdy caddy-status
check "caddy-status shows the line validate failed on" \
  "$(printf 'validate\tfailed\tError: adapting config using caddyfile: Caddyfile:20: unrecognized directive: revers_proxy')" \
  "$(printf '%s\n' "$OUT" | grep '^validate')"

cdy caddy-docs
check "caddy-docs prints the index" "# Caddy" "$(printf '%s\n' "$OUT" | head -1 | cut -c1-7)"
for topic in $(ls "$ROOT/docs/caddy" | sed -n 's/\.md$//p' | grep -v '^index$'); do
  check_contains "the index names $topic" "\`$topic\`" "$(cat "$ROOT/docs/caddy/index.md")"
done
cdy caddy-docs reverse-proxy
check "caddy-docs <topic> prints the topic file" "$(cat "$ROOT/docs/caddy/reverse-proxy.md")" "$OUT"
cdy caddy-docs nope
check "an unknown topic exits 2" "2" "$CODE"
check_contains "…and lists the topics" "topics: " "$ERR"
cdy caddy-docs ../README
check "a topic cannot climb out of the docs" "2" "$CODE"
check "every Caddy digest is under 150 lines" "" \
  "$(for f in "$ROOT"/docs/caddy/*.md; do [ "$(wc -l < "$f")" -lt 150 ] || echo "$f"; done)"
check "the docs make at least ten digests and an index" "yes" \
  "$([ "$(ls "$ROOT"/docs/caddy/*.md | wc -l)" -ge 11 ] && echo yes || echo no)"

echo "== Caddy: the Caddyfile parser =="

# tests/caddyfile-cases.py: inline Caddyfiles through set and remove, one check per line.
python3 "$ROOT/tests/caddyfile-cases.py" "$ENGINE" > "$WORK/cases" 2>"$WORK/cases.err"
check "the parser's cases run to their end" "0 " "$? $(cat "$WORK/cases.err")"
while IFS=$'\t' read -r name expected actual; do
  check "$name" "$expected" "$actual"
done < "$WORK/cases"

echo "== Caddy: site writes =="

caddy_reset
cdy caddy-site-set new.example.com --body-file "$BODY"
check "cf.py refuses a Caddy write" "2 cf: caddy-site-set writes: use cf-write.py" "$CODE $ERR"

caddy_reset
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "caddy-site-set on a new host exits 0" "0" "$CODE"
copy=$(backup_of)
check "…prints the host whose status changed, then the copy" \
  "$(printf 'new.example.com\tdown→200\nbackup: %s' "$copy")" "$OUT"
check "…appends the block and keeps every other byte" "same" "$(same "$CADDYFILE" "$FIXTURES/caddy/expected-set-new")"
check "…copies the Caddyfile first, beside it, with a UTC timestamp" "1" \
  "$(printf '%s\n' "${copy#"$CADDYFILE"}" | grep -cE '^\.bak-20[0-9]{6}T[0-9]{6}\.[0-9]{6}Z$')"
check "…the copy holds the Caddyfile as it was" "same" "$(same "$copy" "$ORIGINAL")"
check "…the copy is private" "600" "$(stat -f '%Lp' "$copy" 2>/dev/null || stat -c '%a' "$copy")"
check "…validates, then reloads" "validate reload" "$(calls)"
check "…validate and reload each with the envfile's variables" "yes" "$(envfile_everywhere)"
check "validate and reload name the Caddyfile and its adapter, reload the admin API the config names" \
  "$(printf 'validate --config %s --adapter caddyfile\nreload --config %s --adapter caddyfile --address 127.0.0.1:%s' "$CADDYFILE" "$CADDYFILE" "$ADMIN_PORT")" \
  "$(python3 -c 'import json,sys; [print(" ".join(json.loads(l)["argv"])) for l in open(sys.argv[1])]' "$CSTATE/calls.jsonl")"
check "the envfile's variables reach caddy through its environment" "$CADDY_TOKEN $CADDY_TOKEN" \
  "$(python3 -c 'import json,sys; print(" ".join(json.loads(l)["env"].get("CF_API_TOKEN", "-") for l in open(sys.argv[1])))' "$CSTATE/calls.jsonl")"
check "the envfile's values never reach caddy's argv" "0" \
  "$(python3 -c 'import json,sys; print(sum(sys.argv[2] in " ".join(json.loads(l)["argv"]) for l in open(sys.argv[1])))' "$CSTATE/calls.jsonl" "$CADDY_TOKEN")"
cdy caddy-sites
check "caddy-sites shows the new block" "$(printf 'https://new.example.com\t48\t127.0.0.1:3000')" "$(printf '%s\n' "$OUT" | tail -1)"

caddy_reset
cdyw caddy-site-set app.example.com --body-file "$BODY"
check "caddy-site-set on an existing host replaces its block, address as written, every other byte kept" "same" \
  "$(same "$CADDYFILE" "$FIXTURES/caddy/expected-set-app")"
check "…and prints only the copy when no status changed" "backup: $(backup_of)" "$OUT"
rm -f "$CSTATE/calls.jsonl"
cdyw caddy-site-set app.example.com --body-file "$BODY"
check "the same block again changes nothing and runs nothing" "$(printf 'unchanged\tapp.example.com') " "$OUT $(calls)"
check "…and makes no copy" "1" "$(copies)"
check "…and leaves the file byte for byte" "same" "$(same "$CADDYFILE" "$FIXTURES/caddy/expected-set-app")"

caddy_reset
cdyw caddy-site-set www.example.com --body-file "$BODY"
check "a block with braces in quotes, comments and a heredoc is replaced whole" \
  "$(sed -n 1,23p "$ORIGINAL"; printf 'www.example.com {\n\timport tls_config\n\treverse_proxy 127.0.0.1:3000\n}\n'; sed -n '33,$p' "$ORIGINAL")" \
  "$(cat "$CADDYFILE")"

caddy_reset
cdyw caddy-site-remove www.example.com
check "caddy-site-remove exits 0" "0" "$CODE"
check "…removes the block and one blank line, every other byte kept" "same" "$(same "$CADDYFILE" "$FIXTURES/caddy/expected-remove-www")"
check "…prints the removed host's status, then the copy" "$(printf 'www.example.com\t200→down\nbackup: %s' "$(backup_of)")" "$OUT"
check "…a host going down because its block was removed is no rollback" "validate reload" "$(calls)"

caddy_reset
cdyw caddy-site-set new.example.com --body-file "$BODY"
cdyw caddy-site-remove new.example.com
check "set then remove gives the Caddyfile back byte for byte" "same" "$(same "$CADDYFILE" "$ORIGINAL")"

caddy_reset
cdyw caddy-site-set HTTPS://New.Example.com --body-file "$BODY"
check "a host is read without regard to case or an https:// prefix" "same" "$(same "$CADDYFILE" "$FIXTURES/caddy/expected-set-new")"

echo "== Caddy: what is refused =="

caddy_reset
cdyw caddy-site-set a.example.com --body-file "$BODY"
check "a block of several addresses is refused with exit 5" "5" "$CODE"
check_contains "…naming the block" "cf: a.example.com is in the block of line 34 with other addresses (a.example.com, b.example.com)" "$ERR"
check "…its set writes, copies and runs nothing" "same 0 " "$(untouched)"
cdyw caddy-site-remove b.example.com
check "…and is not removed either" "5" "$CODE"
check "…its remove writes, copies and runs nothing" "same 0 " "$(untouched)"
cdyw caddy-site-set '*.example.com' --body-file "$BODY"
check "a wildcard host is refused with exit 5" "5" "$CODE"
check "…and writes, copies and runs nothing" "same 0 " "$(untouched)"
check "nothing refused for its addresses was written, copied or run" "same 0 " "$(same "$CADDYFILE" "$ORIGINAL") $(copies) $(calls)"

cdyw caddy-site-remove nothere.example.com
check "removing a host with no block exits 2" "2" "$CODE"
check "…a remove of no block writes, copies and runs nothing" "same 0 " "$(untouched)"
cdyw caddy-site-set 'a b.example.com' --body-file "$BODY"
check "a host that is not a name exits 2" "2" "$CODE"
check "…a host that is no name writes, copies and runs nothing" "same 0 " "$(untouched)"
cdyw caddy-site-set new.example.com --body-file "$WORK/absent.caddy"
check "a body file that cannot be read exits 2" "2" "$CODE"
check "…an unreadable body writes, copies and runs nothing" "same 0 " "$(untouched)"
printf 'reverse_proxy 127.0.0.1:3000 {\n' > "$WORK/open.caddy"
cdyw caddy-site-set new.example.com --body-file "$WORK/open.caddy"
check "a body whose braces do not balance exits 2" "2" "$CODE"
check "…an unbalanced body writes, copies and runs nothing" "same 0 " "$(untouched)"
printf '}\nevil.example.com {\n' > "$WORK/close.caddy"
cdyw caddy-site-set new.example.com --body-file "$WORK/close.caddy"
check "a body that closes the block early exits 2" "2" "$CODE"
check "…a body closing early writes, copies and runs nothing" "same 0 " "$(untouched)"
printf '\n\n' > "$WORK/empty.caddy"
cdyw caddy-site-set new.example.com --body-file "$WORK/empty.caddy"
check "an empty body exits 2" "2" "$CODE"
check "…an empty body writes, copies and runs nothing" "same 0 " "$(untouched)"
check "nothing refused for its host or its body was written, copied or run" "same 0 " "$(same "$CADDYFILE" "$ORIGINAL") $(copies) $(calls)"

printf 'example.com {\n\trespond "x"\n' > "$CADDYFILE"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a Caddyfile whose braces do not balance is refused with exit 5" "5" "$CODE"
printf 'example.com\nrespond "x"\n' > "$CADDYFILE"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a site without braces is refused with exit 5" "5" "$CODE"
printf 'import sites/*\n\nexample.com {\n\trespond "x"\n}\n' > "$CADDYFILE"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a top-level import is no obstacle" "0" "$CODE"
check "no copy is left by the refused edits" "1" "$(copies)"

if user_only "an envfile of mode 000"; then
  caddy_reset
  chmod 000 "$ENVFILE"
  cdyw caddy-site-set new.example.com --body-file "$BODY"
  check "an envfile that cannot be read exits 4 before anything changes" "4 same 0" "$CODE $(same "$CADDYFILE" "$ORIGINAL") $(copies)"
  chmod 600 "$ENVFILE"
fi

# envkey <line> <what the error names>: an envfile holding the line is refused.
envkey() {
  caddy_reset
  printf 'CF_API_TOKEN=%s\n%s\n' "$CADDY_TOKEN" "$1" > "$CADDY/etc/bad.env"
  caddy_config "$WORK/caddy-badenv.json" ", \"envfile\": \"$CADDY/etc/bad.env\""
  CCONF="$WORK/caddy-badenv.json" cdyw caddy-site-set new.example.com --body-file "$BODY"
  check "an envfile line $1 exits 4 before anything changes" "4 same 0 " \
    "$CODE $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(calls)"
  check_contains "…naming what is wrong with $1" "$2" "$ERR"
}
envkey 'PATH=/tmp/evil' "cf: the envfile $CADDY/etc/bad.env sets PATH"
envkey 'LD_PRELOAD=/tmp/evil.so' "cf: the envfile $CADDY/etc/bad.env sets LD_PRELOAD"
envkey 'DYLD_INSERT_LIBRARIES=/tmp/evil.dylib' "cf: the envfile $CADDY/etc/bad.env sets DYLD_INSERT_LIBRARIES"
envkey 'MY-TOKEN=x' "cf: the envfile $CADDY/etc/bad.env: MY-TOKEN is not a variable name"
envkey '1TOKEN=x' "cf: the envfile $CADDY/etc/bad.env: 1TOKEN is not a variable name"
envkey '=x' "cf: the envfile $CADDY/etc/bad.env has a line with no name before ="
printf 'CF_API_TOKEN=%s\n_LOG_LEVEL2=debug\n' "$CADDY_TOKEN" > "$CADDY/etc/bad.env"
CCONF="$WORK/caddy-badenv.json" cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a name of letters, digits and underscores is taken" "0" "$CODE"

printf '{"backup_dir": "%s"}\n' "$WORK/backups" > "$WORK/nocaddy.json"
CCONF="$WORK/nocaddy.json" cdy caddy-sites
check "no caddy section in the config exits 4" "4" "$CODE"
check_contains "…saying so" "no caddy section" "$ERR"
caddy_config "$WORK/caddy-unix.json" ', "admin": "unix//run/caddy-admin.sock"'
CCONF="$WORK/caddy-unix.json" cdyw caddy-reload
check "an admin API on a unix socket is refused with exit 4" "4" "$CODE"
caddy_config "$WORK/caddy-badsudo.json" ', "sudo": "yes"'
CCONF="$WORK/caddy-badsudo.json" cdy caddy-sites
check "a caddy key of the wrong type exits 4" "4" "$CODE"

echo "== Caddy: validate, reload and rollback =="

caddy_reset
printf 'fail adapting config using caddyfile: Caddyfile:50: unrecognized directive: revers_proxy\n' > "$CSTATE/validate"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a validate failure exits 6" "6" "$CODE"
check "…puts the Caddyfile back byte for byte" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
check "…reloads nothing" "validate" "$(calls)"
check "…and gives Caddy's error line and the copy" \
  "cf: caddy validate failed: Error: adapting config using caddyfile: Caddyfile:50: unrecognized directive: revers_proxy; the Caddyfile is restored; backup: $(ls "$CADDYFILE".bak-*)" \
  "$ERR"

caddy_reset
printf '{"down": ["app.example.com"]}\n' > "$CSTATE/reload"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a host going down after the reload exits 6" "6" "$CODE"
check "…restores the Caddyfile byte for byte" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
check "…validates and reloads the restored file" "validate reload validate reload" "$(calls)"
check "…every call of the cycle and of its rollback had the envfile's variables" "yes" "$(envfile_everywhere)"
check "…both reloads name the admin API the config names" "--address 127.0.0.1:$ADMIN_PORT --address 127.0.0.1:$ADMIN_PORT" \
  "$(python3 -c 'import json,sys; print(" ".join(" ".join(a["argv"][-2:]) for a in map(json.loads, open(sys.argv[1])) if a["argv"][0] == "reload"))' "$CSTATE/calls.jsonl")"
# argv_of <admin, or "" for none>: the argv validate and reload would run, recorded instead of run.
argv_of() {
  python3 - "$ENGINE" "$1" <<'PYARGV'
import sys
sys.path.insert(0, sys.argv[1])
from cflib import caddyctl
class Config:
    path = "config.json"
    caddy = {"caddyfile": "/srv/Caddyfile", **({"admin": sys.argv[2]} if sys.argv[2] else {})}
settings = caddyctl.Settings(Config())
settings.call = lambda args, variables: (True, " ".join(args))
print(settings.validate({})[1])
print(settings.reload({})[1])
PYARGV
}
check "with the default admin API, validate and reload carry no --address" \
  "$(printf 'validate --config /srv/Caddyfile --adapter caddyfile\nreload --config /srv/Caddyfile --adapter caddyfile')" "$(argv_of '')"
check "…nor when the config names the default" \
  "$(printf 'validate --config /srv/Caddyfile --adapter caddyfile\nreload --config /srv/Caddyfile --adapter caddyfile')" "$(argv_of localhost:2019)"
check "another admin API reaches reload only, validate has no such flag" \
  "$(printf 'validate --config /srv/Caddyfile --adapter caddyfile\nreload --config /srv/Caddyfile --adapter caddyfile --address 127.0.0.1:2020')" "$(argv_of 127.0.0.1:2020)"
check "…the second reload had the restored file" "same" "$(same "$CADDYFILE" "$(ls "$CADDYFILE".bak-*)")"
check "…and names the host and the copy" \
  "cf: app.example.com went down after the reload; the Caddyfile is restored and reloaded; backup: $(ls "$CADDYFILE".bak-*)" \
  "$ERR"
check "…and the site answers again" "app.example.com" \
  "$(python3 -c 'import json,sys; print(" ".join(h for h in json.load(open(sys.argv[1]))["sites"] if h == "app.example.com"))' "$CSTATE/world.json")"

caddy_reset
printf '{"alive": false}\n{"alive": false}\n' > "$CSTATE/reload"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "caddy still not alive after the rollback exits 7" "7" "$CODE"
check "…after validate, reload, then validate and reload of the restored file" "validate reload validate reload" "$(calls)"
check "…the Caddyfile is restored all the same" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
check_contains "…and says to look now" "caddy is not alive after the rollback either" "$ERR"
check_contains "…naming the copy to put back" "backup: $CADDYFILE.bak-" "$ERR"

caddy_reset
printf '{"down": ["app.example.com"]}\nfail loading config: listener busy\n' > "$CSTATE/reload"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a rollback whose reload fails exits 6, the Caddyfile restored" "6 same" "$CODE $(same "$CADDYFILE" "$ORIGINAL")"
check "…after validate, reload, validate, reload" "validate reload validate reload" "$(calls)"
check_contains "…saying the reload of the restored file failed and the host is still down" \
  "cf: app.example.com went down after the reload; the Caddyfile is restored, but its reload failed (Error: loading config: listener busy), still down: app.example.com; backup: $CADDYFILE.bak-" "$ERR"

caddy_reset
printf 'pass\nfail adapting config: broken\n' > "$CSTATE/validate"
printf '{"down": ["app.example.com"]}\n' > "$CSTATE/reload"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a rollback whose restored file does not validate exits 6, the Caddyfile restored, not reloaded" "6 same validate reload validate" \
  "$CODE $(same "$CADDYFILE" "$ORIGINAL") $(calls)"
check_contains "…saying the restored file does not validate" \
  "cf: app.example.com went down after the reload; the Caddyfile is restored, but it does not validate (Error: adapting config: broken), still down: app.example.com" "$ERR"

caddy_reset
printf '{"down": ["app.example.com"]}\n' > "$CSTATE/reload"
cdyw caddy-site-remove www.example.com
check "a remove that takes another host down is rolled back: exit 6, the Caddyfile restored" "6 same" \
  "$CODE $(same "$CADDYFILE" "$ORIGINAL")"
check_contains "…naming only the other host, not the removed one" \
  "cf: app.example.com went down after the reload; the Caddyfile is restored and reloaded" "$ERR"

caddy_reset
printf '{"alive": false}\n' > "$CSTATE/reload"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "caddy not alive after the reload but alive after the rollback exits 6" "6" "$CODE"
check_contains "…saying why" "cf: caddy's admin API did not answer after the reload; the Caddyfile is restored and reloaded" "$ERR"

caddy_reset
printf 'fail loading config: tls: certificate store is locked\n' > "$CSTATE/reload"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a reload failure exits 6, the Caddyfile restored" "6 same" "$CODE $(same "$CADDYFILE" "$ORIGINAL")"
check_contains "…with Caddy's error line" "cf: caddy reload failed: Error: loading config: tls: certificate store is locked; the Caddyfile is restored and reloaded" "$ERR"

caddy_reset
printf '{"status": {"app.example.com": 502}}\n' > "$CSTATE/reload"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a status change is reported, not rolled back" "0" "$CODE"
check "…one line per host whose status changed" "$(printf 'app.example.com\t200→502\nnew.example.com\tdown→200')" "$(printf '%s\n' "$OUT" | sed '$d')"

caddy_reset
printf '{"status": {"app.example.com": 0}}\n' > "$CSTATE/reload"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a site that completes the TLS handshake but sends no HTTP line still answers: no rollback" "0" "$CODE"
check "…its status is reported as no-http" "$(printf 'app.example.com\t200→no-http\nnew.example.com\tdown→200')" \
  "$(printf '%s\n' "$OUT" | sed '$d')"

# mtime <file>: its modification time, in nanoseconds.
mtime() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$1"; }
caddy_reset
reload_mtime=$(mtime "$CADDYFILE")
cdyw caddy-reload
check "caddy-reload validates and reloads the file as it is" "0 validate reload" "$CODE $(calls)"
check "…and writes nothing: no copy, no rewrite, the same modification time" "reloaded 0 same $reload_mtime" \
  "$OUT $(copies) $(same "$CADDYFILE" "$ORIGINAL") $(mtime "$CADDYFILE")"
if user_only "a Caddyfile of mode 444 reloaded"; then
  chmod 444 "$CADDYFILE"
  cdyw caddy-reload
  check "caddy-reload works on a Caddyfile it cannot write" "0" "$CODE"
  chmod 644 "$CADDYFILE"
fi
caddy_reset
printf '{"down": ["www.example.com"]}\n{"down": ["www.example.com"]}\n' > "$CSTATE/reload"
cdyw caddy-reload
check "caddy-reload with a host down after it exits 6 and names it as still down" "6" "$CODE"
check_contains "…the error names the host, the reload again and the host still down" "www.example.com went down after the reload; the Caddyfile was not changed and is reloaded again, still down: www.example.com" "$ERR"
check "…and writes nothing either" "0 same" "$(copies) $(same "$CADDYFILE" "$ORIGINAL")"

caddy_reset
mkdir -p "$CADDY/sudobin"
ln -sf "$FIXTURES/caddy/fake-sudo.py" "$CADDY/sudobin/sudo"
caddy_config "$WORK/caddy-sudo.json" ', "sudo": true'
CCONF="$WORK/caddy-sudo.json" CADDY_EXTRA="PATH=$CADDY/sudobin:$PATH" cdyw caddy-site-set new.example.com --body-file "$BODY"
check "with sudo: true the cycle runs" "0" "$CODE"
check "…every caddy call goes through sudo -n, keeping the envfile's names, never its values" \
  "$(printf -- '-n --preserve-env=CF_API_TOKEN,LOG %s validate --config %s --adapter caddyfile\n-n --preserve-env=CF_API_TOKEN,LOG %s reload --config %s --adapter caddyfile --address 127.0.0.1:%s' "$FAKE_CADDY" "$CADDYFILE" "$FAKE_CADDY" "$CADDYFILE" "$ADMIN_PORT")" \
  "$(cat "$CSTATE/sudo.log")"

# sudo_lines: the commands sudo was given since the last reset, its own flags dropped.
sudo_lines() { sed -E 's/^-n (--preserve-env=[^ ]+ )?//' "$CSTATE/sudo.log" 2>/dev/null; }
if user_only "the files only root can read or write, through sudo"; then
  caddy_reset
  chmod 444 "$CADDYFILE"
  chmod 555 "$CADDY/etc"
  CCONF="$WORK/caddy-sudo.json" CADDY_EXTRA="PATH=$CADDY/sudobin:$PATH" cdyw caddy-site-set new.example.com --body-file "$BODY"
  copy=$(backup_of)
  chmod 755 "$CADDY/etc"
  check "with sudo: true, a Caddyfile and a directory the user cannot write are written through sudo -n" "0 same" \
    "$CODE $(same "$CADDYFILE" "$FIXTURES/caddy/expected-set-new")"
  check "…the copy by cp, the file by tee, then caddy" \
    "$(printf 'cp -p %s %s\ntee %s\n%s validate\n%s reload' "$CADDYFILE" "$copy" "$CADDYFILE" "$FAKE_CADDY" "$FAKE_CADDY")" \
    "$(sudo_lines | cut -d' ' -f1-4 | sed -E "s#^($FAKE_CADDY [a-z]+).*#\1#")"
  check "…the copy holds the Caddyfile as it was, the file keeps its mode" "same 444" \
    "$(same "$copy" "$ORIGINAL") $(stat -f '%Lp' "$CADDYFILE" 2>/dev/null || stat -c '%a' "$CADDYFILE")"
  chmod 644 "$CADDYFILE"

  caddy_reset
  chmod 000 "$CADDYFILE"
  CCONF="$WORK/caddy-sudo.json" CADDY_EXTRA="PATH=$CADDY/sudobin:$PATH" cdy caddy-sites
  check "with sudo: true, a Caddyfile only root can read is read through sudo -n cat" "0 cat $CADDYFILE" \
    "$CODE $(sudo_lines)"
  check_contains "…and listed" "https://app.example.com" "$OUT"
  chmod 644 "$CADDYFILE"

  caddy_reset
  chmod 444 "$CADDYFILE"
  CCONF="$WORK/caddy-sudo.json" CADDY_EXTRA="PATH=$CADDY/sudobin:$PATH FAKE_SUDO=refuse" cdyw caddy-site-set new.example.com --body-file "$BODY"
  check "a sudo -n that refuses to write the Caddyfile exits 4, the file unchanged, caddy never run" "4 same " \
    "$CODE $(same "$CADDYFILE" "$ORIGINAL") $(calls)"
  check_contains "…naming sudo and the sudoers rule it needs" \
    "cf: cannot write $CADDYFILE: sudo -n refused tee (sudo: a password is required): it needs a sudoers rule with NOPASSWD" "$ERR"
  check_contains "…nothing changed" "; nothing was changed; backup: $CADDYFILE.bak-" "$ERR"
  chmod 644 "$CADDYFILE"
fi

caddy_reset
CCONF="$WORK/caddy-sudo.json" CADDY_EXTRA="PATH=$CADDY/sudobin:$PATH FAKE_SUDO=refuse" cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a sudo -n that refuses caddy validate exits 4, not as a validate failure" "4" "$CODE"
check "…the Caddyfile restored, caddy never run, nothing reloaded" "same " "$(same "$CADDYFILE" "$ORIGINAL") $(calls)"
check_contains "…naming sudo, the sudoers rule and --preserve-env" \
  "cf: sudo -n refused caddy validate (sudo: a password is required): it needs a sudoers rule with NOPASSWD, and SETENV or env_keep for --preserve-env" "$ERR"
check_contains "…saying the file is restored" "; the Caddyfile is restored; backup: $CADDYFILE.bak-" "$ERR"

caddy_reset
printf 'hang\n' > "$CSTATE/validate"
inject 'caddyctl.CALL_TIMEOUT = 1' caddy-site-set new.example.com --body-file "$BODY"
check "a caddy run past its time exits 6, the Caddyfile restored" "6 same" "$CODE $(same "$CADDYFILE" "$ORIGINAL")"
check_contains "…saying it did not end in time" "cf: caddy validate failed: caddy validate did not end within 1 seconds" "$ERR"
check "…and the run is killed with every process it started" "" "$(alive $(cat "$CSTATE/hung.pids"))"

caddy_reset
inject 'def boom(*args):
    raise ValueError("injected")
caddyctl.Settings.validate = boom' caddy-site-set new.example.com --body-file "$BODY"
check "an exception raised after the write puts the Caddyfile back byte for byte before it goes on" "1 same" \
  "$CODE $(same "$CADDYFILE" "$ORIGINAL")"
check_contains "…the exception still goes on, named without a traceback" "cf: internal error: ValueError" "$ERR"
caddy_reset
inject 'def interrupt(*args):
    raise KeyboardInterrupt
caddyctl.Settings.reload = interrupt' caddy-site-set new.example.com --body-file "$BODY"
check "an interrupt during the reload puts the Caddyfile back byte for byte" "same" "$(same "$CADDYFILE" "$ORIGINAL")"

caddy_reset
printf 'hang\n' > "$CSTATE/validate"
env -i PATH="$PATH" HOME="$HOMEDIR" CF_API_BASE="$API" $(caddy_env) \
  python3 "$ENGINE/cf-write.py" caddy-site-set new.example.com --body-file "$BODY" >"$WORK/out" 2>"$WORK/err" &
engine_pid=$!
for _ in $(seq 1 50); do
  [ -s "$CSTATE/hung.pids" ] && break
  sleep 0.1
done
check "a validate that hangs runs on the edited Caddyfile" "differs" "$(same "$CADDYFILE" "$ORIGINAL")"
kill -TERM "$engine_pid"
wait "$engine_pid"
check "SIGTERM during the cycle puts the Caddyfile back byte for byte, exit 143" "143 same" "$? $(same "$CADDYFILE" "$ORIGINAL")"
check "…and kills the caddy it was running" "" "$(alive $(cat "$CSTATE/hung.pids"))"
cat "$WORK/out" "$WORK/err" >> "$CAPTURED"

caddy_reset
printf 'fail adapting config\n' > "$CSTATE/validate"
inject 'real = caddyctl.Settings.write
writes = []
def second_fails(self, text):
    writes.append(text)
    if len(writes) > 1:
        raise PermissionError(13, "Permission denied")
    real(self, text)
caddyctl.Settings.write = second_fails' caddy-site-set new.example.com --body-file "$BODY"
check "a Caddyfile that cannot be put back after a failed validate exits 4, not 7" "4" "$CODE"
check_contains "…saying caddy was not reloaded and still runs, and what to put back" \
  "the Caddyfile could not be restored (Permission denied): caddy was not reloaded and still runs the config it had; put $CADDYFILE.bak-" "$ERR"
caddy_reset
printf '{"down": ["app.example.com"]}\n' > "$CSTATE/reload"
inject 'real = caddyctl.Settings.write
writes = []
def second_fails(self, text):
    writes.append(text)
    if len(writes) > 1:
        raise PermissionError(13, "Permission denied")
    real(self, text)
caddyctl.Settings.write = second_fails' caddy-site-set new.example.com --body-file "$BODY"
check "a Caddyfile that cannot be put back after a reload exits 4, not 7" "4" "$CODE"
check_contains "…saying caddy runs the reloaded config" \
  "the Caddyfile could not be restored (Permission denied): caddy runs the changed Caddyfile; put $CADDYFILE.bak-" "$ERR"

check "the cycle's budget stays under the mod's timeout for a call" "yes" \
  "$(python3 - "$ENGINE" "$ROOT/hooks/register.ts" <<'PYBUDGET'
import re, sys
sys.path.insert(0, sys.argv[1])
from cflib import caddyctl
ms = min(int(t.replace("_", "")) for t in re.findall(r"timeoutMs: ([0-9_]+)", open(sys.argv[2]).read()))
print("yes" if caddyctl.BUDGET * 1000 < ms else "no: %s s against %d ms" % (caddyctl.BUDGET, ms))
PYBUDGET
)"
caddy_reset
printf '{"sleep": 30}\n' > "$CSTATE/reload"
started=$(date +%s)
CADDY_EXTRA="CF_CADDY_BUDGET=4" cdyw caddy-site-set new.example.com --body-file "$BODY"
took=$(( $(date +%s) - started ))
check "a reload that outlasts the cycle's budget is rolled back: exit 6, the Caddyfile restored" "6 same" \
  "$CODE $(same "$CADDYFILE" "$ORIGINAL")"
check_contains "…the error says the budget ran out" \
  "cf: caddy reload failed: caddy reload did not end within" "$ERR"
check_contains "…past the budget" "past the cycle's budget of 4 seconds; the Caddyfile is restored and reloaded" "$ERR"
check "…the rollback validated and reloaded the restored file" "validate reload validate reload" "$(calls)"
check "…and the whole cycle ended within the budget, not the reload's 30 seconds" "yes" \
  "$([ "$took" -le 5 ] && echo yes || echo "no: $took s")"

# hold_lock: a process holding the Caddy lock until killed; its pid in HOLDER.
hold_lock() {
  rm -f "$WORK/held"
  python3 -c 'import fcntl, os, sys, time
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
fh = open(sys.argv[1], "a")
fcntl.flock(fh, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)' "$WORK/backups/caddy.lock" "$WORK/held" &
  HOLDER=$!
  for _ in $(seq 1 50); do
    [ -e "$WORK/held" ] && break
    sleep 0.1
  done
}
caddy_reset
hold_lock
started=$(date +%s)
CADDY_EXTRA="CF_CADDY_BUDGET=3" cdyw caddy-site-set new.example.com --body-file "$BODY"
took=$(( $(date +%s) - started ))
kill "$HOLDER"
wait "$HOLDER" 2>/dev/null
check "a change while another holds the lock fails with exit 5 after a bounded wait" "5 yes" \
  "$CODE $([ "$took" -le 4 ] && echo yes || echo "no: $took s")"
check_contains "…saying another change runs" "cf: another Caddy change is running (it holds $WORK/backups/caddy.lock)" "$ERR"
check "…nothing written, copied or run" "same 0 " "$(same "$CADDYFILE" "$ORIGINAL") $(copies) $(calls)"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "once the lock is let go, the change runs" "0" "$CODE"

check "no stop, restart or service command anywhere in the engine" "" \
  "$(grep -rnE 'brew services|systemctl (re)?start|systemctl stop|launchctl|caddy stop|"stop"|"restart"' "$ENGINE" 2>/dev/null)"

caddy_reset
caddy_config "$WORK/caddy-nobinary.json" ", \"binary\": \"$CADDY/bin/absent\""
CCONF="$WORK/caddy-nobinary.json" cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a caddy binary that cannot run fails validate: exit 6, the Caddyfile restored" "6 same" "$CODE $(same "$CADDYFILE" "$ORIGINAL")"
check_contains "…naming the binary" "cf: caddy validate failed: cannot run $CADDY/bin/absent" "$ERR"

if user_only "a Caddyfile of mode 444 written"; then
  caddy_reset
  chmod 444 "$CADDYFILE"
  cdyw caddy-site-set new.example.com --body-file "$BODY"
  check "a Caddyfile that cannot be written exits 4, unchanged, nothing run" "4 same " "$CODE $(same "$CADDYFILE" "$ORIGINAL") $(calls)"
  check "…saying nothing was changed, before any copy" "cf: cannot write $CADDYFILE: permission denied; nothing was changed 0" \
    "$ERR $(copies)"
  chmod 644 "$CADDYFILE"
fi

caddy_reset
printf '{"alive": false, "sites": {}}\n' > "$CSTATE/world.json"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a Caddy whose admin API does not answer is not touched: exit 5" "5" "$CODE"
check "…the waiting change writes, copies and runs nothing" "same 0 " "$(same "$CADDYFILE" "$ORIGINAL") $(copies) $(calls)"

caddy_reset
printf 'fail invalid token %s\n' "$CADDY_TOKEN" > "$CSTATE/validate"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a value of the envfile that caddy echoes is masked" \
  "cf: caddy validate failed: Error: invalid token [token]; the Caddyfile is restored; backup: $(ls "$CADDYFILE".bak-*)" "$ERR"

caddy_reset
printf 'fail %s %s\n' "$(printf 'x%.0s' $(seq 1 380))" "$CADDY_TOKEN" > "$CSTATE/validate"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check "a value echoed across the cut of a long error line is masked before the cut" "0" \
  "$(printf '%s' "$ERR" | grep -c "${CADDY_TOKEN:0:8}")"
check_contains "…and the line keeps the mask" "x [token]; the Caddyfile is restored" "$ERR"

caddy_reset
printf 'fail loading config: bad token %s\n' "$CADDY_TOKEN" > "$CSTATE/reload"
cdyw caddy-site-set new.example.com --body-file "$BODY"
check_contains "a value of the envfile echoed by a reload is masked" \
  "cf: caddy reload failed: Error: loading config: bad token [token]; the Caddyfile is restored" "$ERR"

caddy_reset
printf 'CF_API_TOKEN=%s\nSHORT=sevench\nLONGER=eightchr\n' "$CADDY_TOKEN" > "$CADDY/etc/short.env"
caddy_config "$WORK/caddy-short.json" ", \"envfile\": \"$CADDY/etc/short.env\""
printf 'fail short sevench long eightchr\n' > "$CSTATE/validate"
CCONF="$WORK/caddy-short.json" cdyw caddy-site-set new.example.com --body-file "$BODY"
check_contains "a value one character under the masking minimum is shown, one at the minimum is masked" \
  "cf: caddy validate failed: Error: short sevench long [token];" "$ERR"

echo "== end to end: a Caddy cycle through the tool's requests =="

caddy_reset
cdywj "{\"command\": \"caddy-site-set\", \"args\": {\"host\": \"new.example.com\", \"body-file\": \"$BODY\"}}"
check "e2e: caddy-site-set on a new host" "$(printf 'new.example.com\tdown→200')" "$(printf '%s\n' "$OUT" | head -1)"
cdyj '{"command": "caddy-sites"}'
check "e2e: caddy-sites shows it" "1" "$(printf '%s\n' "$OUT" | grep -c '^https://new.example.com	')"
check "e2e: every other byte kept" "same" "$(same "$CADDYFILE" "$FIXTURES/caddy/expected-set-new")"
cp "$CADDYFILE" "$WORK/caddy-before-break"
printf '{"down": ["app.example.com"]}\n' > "$CSTATE/reload"
cdywj "{\"command\": \"caddy-site-set\", \"args\": {\"host\": \"new.example.com\", \"body-file\": \"$WORK/open.caddy\"}}"
check "e2e: a broken body is refused before anything changes" "2" "$CODE"
printf 'respond "v2"\n' > "$WORK/v2.caddy"
cdywj "{\"command\": \"caddy-site-set\", \"args\": {\"host\": \"new.example.com\", \"body-file\": \"$WORK/v2.caddy\"}}"
check "e2e: a change that breaks a running host is rolled back, exit 6" "6" "$CODE"
check "e2e: the file is identical to before" "same" "$(same "$CADDYFILE" "$WORK/caddy-before-break")"
cdywj '{"command": "caddy-site-remove", "args": {"host": "new.example.com"}}'
check "e2e: caddy-site-remove" "0" "$CODE"
check "e2e: the Caddyfile is the original again" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
e2e_set="{\"command\": \"caddy-site-set\", \"args\": {\"host\": \"new.example.com\", \"body-file\": \"$BODY\"}}"
caddy_reset
hold_lock
CADDY_EXTRA="CF_CADDY_BUDGET=3" cdywj "$e2e_set"
kill "$HOLDER"
wait "$HOLDER" 2>/dev/null
check "e2e: a change while another holds the lock exits 5, the Caddyfile untouched" "5 same 0 " "$CODE $(untouched)"
caddy_reset
printf '{"sleep": 30}\n' > "$CSTATE/reload"
started=$(date +%s)
CADDY_EXTRA="CF_CADDY_BUDGET=4" cdywj "$e2e_set"
took=$(( $(date +%s) - started ))
check "e2e: a reload past the cycle's budget is rolled back within it, exit 6, the file identical" "6 same yes" \
  "$CODE $(same "$CADDYFILE" "$ORIGINAL") $([ "$took" -le 5 ] && echo yes || echo "no: $took s")"
caddy_reset
printf 'hang\n' > "$CSTATE/validate"
printf '%s' "$e2e_set" > "$WORK/stdin"
env -i PATH="$PATH" HOME="$HOMEDIR" CF_API_BASE="$API" $(caddy_env) \
  python3 "$ENGINE/cf-write.py" --stdin-json <"$WORK/stdin" >"$WORK/out" 2>"$WORK/err" &
engine_pid=$!
for _ in $(seq 1 50); do
  [ -s "$CSTATE/hung.pids" ] && break
  sleep 0.1
done
kill -TERM "$engine_pid"
wait "$engine_pid"
check "e2e: SIGTERM in the middle of a change puts the file back, exit 143" "143 same" "$? $(same "$CADDYFILE" "$ORIGINAL")"
cat "$WORK/out" "$WORK/err" >> "$CAPTURED"
CCONF="$WORK/caddy-noenv.json" cdyj '{"command": "caddy-status"}'
check_contains "e2e: caddy-status warns of the service without its envfile" "warning: $CADDY/noenv.plist does not start caddy with --envfile" "$OUT"

echo "== check =="

# A fake public resolver (tests/fixtures/resolver.py) answers from names.json;
# its addresses lead to the fake running Caddy, reached on its TLS port through
# CF_CHECK_PORT, whose certificate the fixture CA (SSL_CERT_FILE) vouches for.
# Nothing is resolved through 1.1.1.1 and no port 443 is probed.
NAMES="$WORK/names.json"
printf '{"app.example.com": ["127.0.0.1"], "www.example.com": ["127.0.0.1"], "new.example.com": ["127.0.0.1"], "two.example.com": ["127.0.0.1", "127.0.0.2"], "broken.example.com": "servfail", "example.com": ["127.0.0.1"], "orphan.example.com": ["127.0.0.1"], "svc.example.com": ["127.0.0.1"], "v6.example.com": ["::1"], "empty.example.com": "empty", "refused.example.com": "refused", "wrongid.example.com": "wrong-id", "truncated.example.com": "truncated", "slow.example.com": {"delay": 4, "addresses": ["127.0.0.1"]}, "slower.example.com": {"delay": 8, "addresses": ["127.0.0.1"]}}\n' > "$NAMES"
python3 "$FIXTURES/resolver.py" "$NAMES" "$WORK/dns-port" &
RESOLVER_PID=$!
for _ in $(seq 1 50); do
  [ -s "$WORK/dns-port" ] && break
  sleep 0.1
done
DNS_PORT=$(cat "$WORK/dns-port" 2>/dev/null)
[ -n "$DNS_PORT" ] || { echo "the fake resolver did not start"; exit 1; }
ISSUER="Fixture Trust (Fixture CA)"
EXPIRES=$(python3 -c 'import ssl, sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(ssl.cert_time_to_seconds(sys.argv[1]))))' \
  "$(openssl x509 -enddate -noout -in "$CADDY/cert.pem" | cut -d= -f2)")
# A port nothing listens on, for a site that refuses connections.
CLOSED_PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
# check_env: what a check, a publish or an inventory adds to the Caddy runs'.
check_env() {
  printf '%s CF_RESOLVER=%s CF_CHECK_PORT=%s %s' "$(caddy_env)" "${CHECK_RESOLVER:-127.0.0.1:$DNS_PORT}" \
    "${CHECK_PORT:-$TLS_PORT}" "${CHECK_CA-SSL_CERT_FILE=$CADDY/ca.pem}"
}
pub() { EXTRA_ENV="$(check_env)" cf "$@"; }
pubw() { EXTRA_ENV="$(check_env)" cfw "$@"; }
pubj() { EXTRA_ENV="$(check_env)" cfj "$1"; }
pubwj() { EXTRA_ENV="$(check_env)" cfwj "$1"; }
# resolved: the names the fake resolver was asked since the last caddy_reset.
resolved() { [ -f "$NAMES.log" ] && tr '\n' ' ' < "$NAMES.log" | sed 's/ $//'; }
CHECK_HEAD="$(printf 'host\taddress\thttps\tissuer\texpires')"

caddy_reset
rm -f "$NAMES.log"
reset
pub check app.example.com
check "check resolves the host publicly, then gives its HTTPS status, issuer and expiry, in one line" \
  "$(printf '%s\napp.example.com\t127.0.0.1\t200\t%s\t%s' "$CHECK_HEAD" "$ISSUER" "$EXPIRES")" "$OUT"
check "…asking the resolver it is given" "app.example.com" "$(resolved)"
check "…with no API call and no caddy run" " " "$(sent) $(calls)"
pub check HTTPS://App.Example.com.
check "check reads a host without regard to case or an https:// prefix" "app.example.com	127.0.0.1	200" "$(printf '%s\n' "$OUT" | sed 1d | cut -f1-3)"
pub check new.example.com
check "a host whose TLS handshake fails is down, with no certificate" "new.example.com	127.0.0.1	down (tls)	-	-" "$(printf '%s\n' "$OUT" | sed 1d)"
pub check nothere.example.com
check "a name the resolver does not know is nxdomain, and nothing is connected" "nothere.example.com	nxdomain	-	-	-" "$(printf '%s\n' "$OUT" | sed 1d)"
pub check broken.example.com
check "a resolver failure is named" "broken.example.com	servfail	-	-	-" "$(printf '%s\n' "$OUT" | sed 1d)"
pub check two.example.com
check "every address is given, the first one is connected" "two.example.com	127.0.0.1,127.0.0.2	down (tls)" "$(printf '%s\n' "$OUT" | sed 1d | cut -f1-3)"
printf '{"alive": true, "sites": {"app.example.com": 502}}\n' > "$CSTATE/world.json"
pub check app.example.com
check "a site answering 502 gives its status and its certificate" "app.example.com	127.0.0.1	502	$ISSUER	$EXPIRES" "$(printf '%s\n' "$OUT" | sed 1d)"
caddy_reset
CHECK_CA= pub check app.example.com
check_contains "a certificate no trusted authority issued is untrusted, with the reason" "app.example.com	127.0.0.1	untrusted (" "$OUT"
check "…and the command still exits 0" "0" "$CODE"
CHECK_PORT=$CLOSED_PORT pub check app.example.com
check "a site refusing the connection is down" "app.example.com	127.0.0.1	down (connect)	-	-" "$(printf '%s\n' "$OUT" | sed 1d)"
CHECK_RESOLVER=127.0.0.1:$CLOSED_PORT pub check app.example.com
check "a resolver that does not answer is named" "app.example.com	no resolver	-	-	-" "$(printf '%s\n' "$OUT" | sed 1d)"
pub check app.example.com --json
check "check --json gives the whole result" "app.example.com 127.0.0.1 200 $EXPIRES" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c["host"], ",".join(c["addresses"]), c["https"], c["expires"])')"
pubj '{"command": "check", "args": {"host": "www.example.com"}}'
check "check through the tool's request" "www.example.com	127.0.0.1	200" "$(printf '%s\n' "$OUT" | sed 1d | cut -f1-3)"
pub check 'bad host'
check "check refuses a host that is not a name" "2" "$CODE"
pubw check app.example.com
check "check is a read: cf-write.py refuses it" "2 cf: check only reads: use cf.py" "$CODE $ERR"

# The answers of a resolver that is wrong, or slow, and a host with no A.
rm -f "$NAMES.log"
pub check v6.example.com
check "a host with no A falls back to its AAAA" "v6.example.com	::1	down (connect)" "$(printf '%s\n' "$OUT" | sed 1d | cut -f1-3)"
check "…asking for the AAAA once the A has no answer" "v6.example.com v6.example.com/AAAA" "$(resolved)"
pub check empty.example.com
check "an answer with no record, to either query, is no answer" "empty.example.com	no answer	-	-	-" "$(printf '%s\n' "$OUT" | sed 1d)"
pub check refused.example.com
check "an answer code other than NXDOMAIN is named" "refused.example.com	refused	-	-	-" "$(printf '%s\n' "$OUT" | sed 1d)"
pub check wrongid.example.com
check "an answer to another query id is a bad answer, and nothing is connected" "wrongid.example.com	bad answer	-	-	-" "$(printf '%s\n' "$OUT" | sed 1d)"
pub check truncated.example.com
check "an answer cut short is a bad answer" "truncated.example.com	bad answer	-	-	-" "$(printf '%s\n' "$OUT" | sed 1d)"
pub check slow.example.com
check "a resolver slower than the timeout is named" "slow.example.com	resolver timeout	-	-	-" "$(printf '%s\n' "$OUT" | sed 1d)"
check "…and every one of them exits 0" "0" "$CODE"
check "no name check asks for is a wildcard: check.run skips one, asking nothing" "*.example.com	wildcard: not checked " \
  "$(rm -f "$NAMES.log"; env -i PATH="$PATH" $(check_env) python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from cflib import check; r = check.run(["*.example.com"])["*.example.com"]; print(r["host"] + "\t" + r["resolution"])' "$ENGINE") $(resolved)"

# A certificate past its date, issued by the fixture CA, on a listener that
# takes one connection and ends.
openssl x509 -req -in "$CADDY/leaf.csr" -CA "$CADDY/ca.pem" -CAkey "$CADDY/ca-key.pem" -CAcreateserial \
  -not_before 20200101000000Z -not_after 20200102000000Z -extfile "$CADDY/leaf.ext" -out "$CADDY/expired.pem" >/dev/null 2>&1
if [ -s "$CADDY/expired.pem" ]; then
  python3 - "$CADDY/expired.pem" "$CADDY/key.pem" "$WORK/once-port" <<'PYONCE' &
import os, socket, ssl, sys
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(1)
server.settimeout(20)
with open(sys.argv[3] + ".tmp", "w") as fh:
    fh.write(str(server.getsockname()[1]))
os.replace(sys.argv[3] + ".tmp", sys.argv[3])
try:
    conn, _ = server.accept()
    context.wrap_socket(conn, server_side=True).close()
except (OSError, ssl.SSLError):
    pass
PYONCE
  ONCE_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$WORK/once-port" ] && break
    sleep 0.1
  done
  CHECK_PORT=$(cat "$WORK/once-port") pub check app.example.com
  wait "$ONCE_PID"
  check "a certificate past its date is untrusted, saying so" "app.example.com	127.0.0.1	untrusted (certificate has expired)	-	-" \
    "$(printf '%s\n' "$OUT" | sed 1d)"
else
  echo "  skip the expired certificate: openssl cannot set the dates (-not_before, -not_after)"
fi

echo "== publish =="

ZID=0123456789abcdef0123456789abcdef
DNSBK="$WORK/backups/alpha/example.com"
# with_keys <config> <copy> <json object>: the config with these top-level keys.
with_keys() {
  python3 -c 'import json, sys; c = json.load(open(sys.argv[1])); c.update(json.loads(sys.argv[3])); json.dump(c, open(sys.argv[2], "w"))' "$1" "$2" "$3"
}
PUB_CONFIG="$WORK/publish-config.json"
with_keys "$CADDY_CONFIG" "$PUB_CONFIG" '{"default_target": "203.0.113.10"}'
# mark / writes: the requests that are not reads, sent since the last mark.
mark() { MARK=$(sent | wc -l | tr -d ' '); }
writes() { sent | tail -n +$((MARK + 1)) | grep -v '^GET' | sed 's,/[0-9a-f]\{32\}$,/<id>,'; }
# expected_new <file> <host> <upstream> [extra lines]: the fixture Caddyfile with
# the block publish appends.
expected_new() {
  { cat "$ORIGINAL"; printf '\nhttps://%s {\n\timport tls_config\n\tlog\n\treverse_proxy %s\n' "$2" "$3"; [ -n "${4:-}" ] && printf '%s\n' "$4"; printf '}\n'; } > "$1"
}
nth() { printf '%s\n' "$OUT" | sed -n "$1p"; }
# pub_reset: the fixture Caddyfile and zone back, no backup of example.com, the mark at 0.
pub_reset() { caddy_reset; reset; rm -rf "$DNSBK"; MARK=0; }
www_id() { CCONF="$PUB_CONFIG" pub dns-get example.com www --json; printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])'; }
CCONF="$PUB_CONFIG"

pub_reset
pubw publish new.example.com --to 8080 --ip 203.0.113.50
check "publish creates the A record, proxied, then the block, then checks the host" "0" "$CODE"
check "…the record line" "created	A	new.example.com	203.0.113.50	yes	auto" "$(nth 1 | cut -f1-6)"
check "…the record's backup" "backup: $(ls "$DNSBK"/*-dns.json)" "$(nth 2)"
check "…the Caddy cycle's lines and copy" "$(printf 'new.example.com\tdown→200\nbackup: %s' "$(ls "$CADDYFILE".bak-*)")" "$(nth 3,4)"
check "…then the check of the host" "$(printf '%s\nnew.example.com\t127.0.0.1\t200\t%s\t%s' "$CHECK_HEAD" "$ISSUER" "$EXPIRES")" "$(nth 5,6)"
expected_new "$WORK/expected-publish" new.example.com 127.0.0.1:8080
check "…the block in C5's shape appended, every other byte kept" "same" "$(same "$CADDYFILE" "$WORK/expected-publish")"
check "…one write to Cloudflare" "POST /zones/$ZID/dns_records" "$(writes)"
check "…one validate and one reload" "validate reload" "$(calls)"
pub dns-get example.com new
check "…the record is there" "A	new.example.com	203.0.113.50	yes	auto" "$(lines)"

pub_reset
pubw publish www.example.com --to http://127.0.0.1:9000
check "publish on a record already right writes no record and takes no backup of it" \
  "unchanged	A	www.example.com	203.0.113.10	yes	auto" "$(nth 1 | cut -f1-6)"
check "…without --ip, the config's default_target" "" "$(writes)"
check "…and no backup of the record is written" "absent" "$(test ! -e "$DNSBK" && echo absent || ls "$DNSBK")"
check "…the block of the host is replaced, its address kept" \
  "$(printf 'www.example.com {\n\timport tls_config\n\tlog\n\treverse_proxy http://127.0.0.1:9000\n}')" \
  "$(sed -n '/^www.example.com {/,/^}/p' "$CADDYFILE")"
check "…no status changed: the cycle prints its copy alone" "backup: $(ls "$CADDYFILE".bak-*)" "$(nth 2)"

pub_reset
pubw publish www.example.com --to 8080 --ip 203.0.113.60 --no-proxy
check "publish updates the A record: content and proxy" \
  "$(printf 'before\tA\twww.example.com\t203.0.113.10\tyes\nafter\tA\twww.example.com\t203.0.113.60\tno')" "$(nth 1,2 | cut -f1-5)"
check "…one write, on that record" "PUT /zones/$ZID/dns_records/<id>" "$(writes)"
check "…and names its backup" "backup: $(ls "$DNSBK"/*-dns.json | tail -1)" "$(nth 3)"

pub_reset
printf 'encode gzip\nheader X-Frame-Options DENY\n' > "$WORK/extra.caddy"
pubw publish new.example.com --to 8080 --ip 203.0.113.50 --extra-file "$WORK/extra.caddy"
expected_new "$WORK/expected-extra" new.example.com 127.0.0.1:8080 "$(printf '\tencode gzip\n\theader X-Frame-Options DENY')"
check "publish --extra-file adds its directives after reverse_proxy" "0 same" "$CODE $(same "$CADDYFILE" "$WORK/expected-extra")"

pub_reset
cfw setting-set example.com ssl flexible
mark
pubw publish new.example.com --to 8080
check "publish refuses a proxied site on SSL mode flexible: exit 5" "5" "$CODE"
check "…saying why and what to do" \
  "cf: example.com is in SSL mode flexible: a proxied site needs full or strict (setting-set example.com ssl full), or publish with --no-proxy; nothing was changed" "$ERR"
check "…before any write: no Cloudflare write, no copy, no caddy run" "same 0 " "$(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
pubw publish new.example.com --to 8080 --no-proxy
check "…while --no-proxy publishes on flexible" "0 created	A	new.example.com	203.0.113.10	no" "$CODE $(nth 1 | cut -f1-5)"

pub_reset
cfw setting-set example.com ssl off
mark
pubw publish new.example.com --to 8080
check "publish refuses a proxied site on SSL mode off: exit 5, before any write" "5 same 0 " \
  "$CODE $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
cfw setting-set example.com ssl strict
mark
pubw publish new.example.com --to 8080
check "publish passes the guard on SSL mode strict" "0 created	A	new.example.com	203.0.113.10	yes" "$CODE $(nth 1 | cut -f1-5)"
pub_reset
fail_next GET /settings/ssl 403 9109 "Unauthorized to access requested resource"
pubw publish new.example.com --to 8080
check "publish whose SSL guard cannot be read is refused: exit 3, nothing written" \
  "3 cf: Cloudflare 9109: Unauthorized to access requested resource same 0 " \
  "$CODE $ERR $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"

pub_reset
cfw universal-ssl example.com off
mark
pubw publish new.example.com --to 8080
check "publish refuses a proxied site with Universal SSL off: exit 5" \
  "5 cf: Universal SSL is off on example.com: the edge has no certificate for new.example.com (universal-ssl example.com on), or publish with --no-proxy; nothing was changed" \
  "$CODE $ERR"
check "…before any write" "same 0 " "$(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"

pub_reset
pubw publish app.example.com --to 8080
check "publish refuses a host that is a CNAME: exit 5, nothing written" \
  "5 cf: app.example.com is a CNAME to www.example.com: dns-delete it, or dns-update it into an A, first; nothing was changed same " \
  "$CODE $ERR $(same "$CADDYFILE" "$ORIGINAL") $(writes)$(calls)"
pubw publish a.example.com --to 8080
check "publish refuses a host in a block of several before writing its record: exit 5" \
  "5  0" "$CODE $(writes)$(calls) $(copies)"
check_contains "…naming the block" "a.example.com is in the block of line 34 with other addresses" "$ERR"
printf '{"alive": false, "sites": {}}\n' > "$CSTATE/world.json"
pubw publish new.example.com --to 8080
check "publish refuses when Caddy's admin API does not answer, before writing the record: exit 5" "5 " "$CODE $(writes)$(calls)"
caddy_reset
CCONF="$CADDY_CONFIG" pubw publish new.example.com --to 8080
check "publish without --ip and without default_target exits 4, nothing written" \
  "4 cf: no --ip, and no default_target in $CADDY_CONFIG " "$CODE $ERR $(writes)"
CCONF="$CONFIG" pubw publish new.example.com --to 8080
check "publish without a caddy section exits 4, nothing written" "4 " "$CODE $(writes)"
pubw publish new.example.invalid --to 8080
check "publish on a host no zone of the account holds exits 2" "2 cf: no zone of account alpha holds new.example.invalid" "$CODE $ERR"
check "…the Caddyfile, its copies and caddy untouched" "same 0 " "$(same "$CADDYFILE" "$ORIGINAL") $(copies) $(calls)"
for to in '8080; respond x' 0 70000 'http://a b' '{$HOME}'; do
  pubw publish new.example.com --to "$to"
  check "publish refuses --to $to: exit 2, nothing written" "2 " "$CODE $(writes)"
  check "…the Caddyfile, its copies and caddy untouched" "same 0 " "$(same "$CADDYFILE" "$ORIGINAL") $(copies) $(calls)"
done
check_contains "…saying what --to takes" "cf: --to takes a port or an upstream (host:port, http://host:port): " "$ERR"
pubw publish new.example.com --to 8080 --ip 203.0.113
check "publish refuses an --ip that is not IPv4: exit 2" "2 cf: --ip takes an IPv4 address: 203.0.113" "$CODE $ERR"
check "…the Caddyfile, its copies and caddy untouched, nothing sent" "same 0 " "$(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
with_keys "$CADDY_CONFIG" "$WORK/publish-badtarget.json" '{"default_target": "203.0.113.300"}'
CCONF="$WORK/publish-badtarget.json" pubw publish new.example.com --to 8080
check "publish refuses a default_target that is not IPv4: exit 4, nothing written" \
  "4 cf: $WORK/publish-badtarget.json: default_target is not an IPv4 address same 0 " "$CODE $ERR $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
printf 'encode gzip\n' > "$WORK/locked-extra.caddy"
chmod 000 "$WORK/locked-extra.caddy"
pubw publish new.example.com --to 8080 --extra-file "$WORK/locked-extra.caddy"
check "publish refuses an --extra-file it may not read: exit 2, nothing written" \
  "2 cf: cannot read $WORK/locked-extra.caddy: Permission denied same 0 " "$CODE $ERR $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
chmod 600 "$WORK/locked-extra.caddy"
printf 'header {\n' > "$WORK/open-extra.caddy"
pubw publish new.example.com --to 8080 --extra-file "$WORK/open-extra.caddy"
check "publish refuses an --extra-file whose braces do not balance: exit 2, nothing written" "2 0" "$CODE $(writes)$(copies)"
for form in 'header X-Key {$CF_API_TOKEN}' 'header X-Key {env.CF_API_TOKEN}' 'header X-Key {file./etc/passwd}' 'import tls_config' \
    "$(printf 'handle /x {\n\timport other\n}')"; do
  printf '%s\n' "$form" > "$WORK/refused-extra.caddy"
  pubw publish new.example.com --to 8080 --extra-file "$WORK/refused-extra.caddy"
  check "publish refuses an --extra-file holding $(printf '%s' "$form" | tr '\n\t' '  '): exit 2, nothing written" \
    "2 same 0 " "$CODE $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
done
check_contains "…saying what it may not hold" \
  "cf: $WORK/refused-extra.caddy imports at line 2: an --extra-file may not import, nor read the environment or files ({\$…}, {env.…}, {file.…}); nothing was changed" "$ERR"
printf 'header X-Key {$CF_API_TOKEN}\n' > "$WORK/refused-extra.caddy"
pubw publish new.example.com --to 8080 --extra-file "$WORK/refused-extra.caddy"
check "…naming the placeholder" \
  "cf: $WORK/refused-extra.caddy reads {\$ at line 1: an --extra-file may not import, nor read the environment or files ({\$…}, {env.…}, {file.…}); nothing was changed" "$ERR"
pubw publish new.example.com --to 8080 --extra-file "$WORK/absent-extra.caddy"
check "publish refuses an --extra-file that is not there: exit 2, nothing written" \
  "2 cf: cannot read $WORK/absent-extra.caddy: No such file or directory same 0 " "$CODE $ERR $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
printf 'encode gzip\n}\nheader X 1\n' > "$WORK/stray-extra.caddy"
pubw publish new.example.com --to 8080 --extra-file "$WORK/stray-extra.caddy"
check "publish refuses an --extra-file with a stray closing brace: exit 2, nothing written" \
  "2 cf: the body cannot be used: a closing brace closes the site block at line 2 same 0 " "$CODE $ERR $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
printf 'header X \xff\xfe\n' > "$WORK/binary-extra.caddy"
pubw publish new.example.com --to 8080 --extra-file "$WORK/binary-extra.caddy"
check "publish refuses an --extra-file that is not UTF-8: exit 2, nothing written" "2 same 0 " \
  "$CODE $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
check_contains "…saying it cannot read it" "cf: cannot read $WORK/binary-extra.caddy: " "$ERR"
printf '\n  \n' > "$WORK/empty-extra.caddy"
pubw publish new.example.com --to 8080 --extra-file "$WORK/empty-extra.caddy"
check "publish refuses an empty --extra-file: exit 2, nothing written" \
  "2 cf: $WORK/empty-extra.caddy is empty: leave --extra-file out same 0 " "$CODE $ERR $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
pubw publish '*.example.com' --to 8080
check "publish refuses a wildcard: exit 5" "5" "$CODE"
check "…the Caddyfile, its copies and caddy untouched" "same 0 " "$(same "$CADDYFILE" "$ORIGINAL") $(copies) $(calls)"
check "no refusal sent a write" "" "$(writes)"

pub_reset
cfw dns-create example.com --name www --type A --content 203.0.113.11
mark
pubw publish www.example.com --to 8080
check "publish refuses a host with several A records: exit 5, nothing written" \
  "5 cf: www.example.com has 2 A records: dns-delete all but one first; nothing was changed same 0 " \
  "$CODE $ERR $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"

pub_reset
cfw dns-create example.com --name new --type AAAA --content 2001:db8::5
mark
pubw publish new.example.com --to 8080 --ip 203.0.113.50
check "publish refuses a host that has an AAAA record: exit 2, naming it, nothing written" \
  "2 cf: new.example.com has an AAAA record (2001:db8::5): dns-delete it first, publish writes an A alone; nothing was changed same 0 " \
  "$CODE $ERR $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"

pub_reset
caddy_config "$WORK/caddy-nosnippet.json" ', "tls_snippet": null'
with_keys "$WORK/caddy-nosnippet.json" "$WORK/publish-nosnippet.json" '{"default_target": "203.0.113.10"}'
CCONF="$WORK/publish-nosnippet.json" pubw publish new.example.com --to 8080 --ip 203.0.113.50
check "publish without a tls_snippet configured still publishes" "0" "$CODE"
check "…warning on stderr that the block imports none" \
  "cf: warning: no caddy.tls_snippet in $WORK/publish-nosnippet.json: the block of new.example.com imports no TLS snippet" "$ERR"
check "…the block without the import" "$(printf 'https://new.example.com {\n\tlog\n\treverse_proxy 127.0.0.1:8080\n}')" \
  "$(sed -n '/^https:\/\/new.example.com {/,/^}/p' "$CADDYFILE")"

pub_reset
pubw publish fresh.example.com --to 8080 --ip 203.0.113.50
check "publish whose check reads nxdomain still exits 0" "0" "$CODE"
check "…and says so in its last line" "published, but the check reads nxdomain" "$(printf '%s\n' "$OUT" | tail -1)"
pub_reset
CHECK_PORT=$CLOSED_PORT pubw publish new.example.com --to 8080 --ip 203.0.113.50
check "publish whose check reads down says so, exit 0" "0 published, but the check reads down (connect)" "$CODE $(printf '%s\n' "$OUT" | tail -1)"
pub_reset
CHECK_CA= pubw publish new.example.com --to 8080 --ip 203.0.113.50
check_contains "publish whose check reads untrusted says so" "published, but the check reads untrusted (" "$(printf '%s\n' "$OUT" | tail -1)"
pub_reset
pubw publish new.example.com --to 8080 --ip 203.0.113.50
check "publish whose check answers prints no such line" "0" "$(printf '%s\n' "$OUT" | grep -c 'published, but')"

echo "== publish: a failure midway =="

pub_reset
printf '{"down": ["app.example.com"]}\n' > "$CSTATE/reload"
pubw publish new.example.com --to 8080 --ip 203.0.113.50
check "a Caddy rollback after the record was created exits 6" "6" "$CODE"
check "…the Caddyfile restored" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
check "…by validate and reload, then the copy validated and reloaded" "validate reload validate reload" "$(calls)"
check "…the record created, then deleted again" \
  "$(printf 'POST /zones/%s/dns_records\nDELETE /zones/%s/dns_records/<id>' "$ZID" "$ZID")" "$(writes)"
check "…and every backup is named: the Caddyfile's, the undone record's, the record's" \
  "cf: app.example.com went down after the reload; the Caddyfile is restored and reloaded; backup: $(ls "$CADDYFILE".bak-*); the DNS record of new.example.com is put back (its undone state: $(ls "$DNSBK"/*-dns.json | tail -1)); backup: $(ls "$DNSBK"/*-dns.json | head -1)" \
  "$ERR"
pub dns-get example.com new
check "…no record is left" "2" "$CODE"

for failing in 'fail the admin endpoint refused the reload' '{"down": ["app.example.com"]}'; do
  pub_reset
  printf '%s\n' "$failing" > "$CSTATE/reload"
  pubw publish www.example.com --to 8080 --ip 203.0.113.60
  check "a rollback after the record was updated ($failing) exits 6" "6" "$CODE"
  pub dns-get example.com www
  check "…the record back to 203.0.113.10, proxied" "A	www.example.com	203.0.113.10	yes	auto" "$(lines)"
  check "…and the Caddyfile byte for byte" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
done

pub_reset
printf 'fail adapting config: unrecognized directive\n' > "$CSTATE/validate"
pubw publish www.example.com --to 8080 --ip 203.0.113.60
check "a validate failure after the record was updated exits 6" "6" "$CODE"
pub dns-get example.com www
check "…the record is put back as it was" "A	www.example.com	203.0.113.10	yes	auto" "$(lines)"
check "…by a second write of it" \
  "$(printf 'PUT /zones/%s/dns_records/<id>\nPUT /zones/%s/dns_records/<id>' "$ZID" "$ZID")" "$(writes)"

pub_reset
printf 'header X-Key extra-secret-value-91\n' > "$WORK/secret-extra.caddy"
printf 'fail adapting config: header X-Key extra-secret-value-91: unrecognized\n' > "$CSTATE/validate"
pubw publish new.example.com --to 8080 --ip 203.0.113.50 --extra-file "$WORK/secret-extra.caddy"
check "a validate failure with an --extra-file exits 6, the Caddyfile restored" "6 same" "$CODE $(same "$CADDYFILE" "$ORIGINAL")"
check_contains "…naming the extra file, not Caddy's line" \
  "cf: caddy validate failed on the block with the directives of $WORK/secret-extra.caddy (Caddy's line is not shown: it may quote them); the Caddyfile is restored; backup: " "$ERR"
check "…which never reaches the output" "0" "$(printf '%s%s' "$OUT" "$ERR" | grep -c 'extra-secret-value-91')"

pub_reset
WWW=$(www_id)
mark
printf '{"down": ["app.example.com"]}\n' > "$CSTATE/reload"
fail_next PUT "/dns_records/$WWW" 500 1000 "boom" 1
pubw publish www.example.com --to 8080 --ip 203.0.113.60
check "a record that cannot be put back keeps the Caddy exit code" "6" "$CODE"
check_contains "…and says the record could not be put back, with the failed write's own backup" \
  "; the DNS record of www.example.com could not be put back (Cloudflare 1000: boom; backup: " "$ERR"
check_contains "…and says to restore it by hand from its backup" \
  "): restore it by hand; backup: $(ls "$DNSBK"/*-dns.json | head -1)" "$ERR"
check "…the Caddyfile restored all the same" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
pub dns-get example.com www
check "…the record left with the published address" "A	www.example.com	203.0.113.60	yes	auto" "$(lines)"

# boom_publish <args...>: publish, its Caddy cycle failing with an error that is
# no engine error; stdout, stderr and the exit code as run() keeps them.
boom_publish() {
  env -i PATH="$PATH" HOME="$HOMEDIR" CF_API_BASE="$API" $(check_env) \
    python3 - "$ENGINE" "$@" >"$WORK/out" 2>"$WORK/err" <<'PYBOOM'
import sys
sys.path.insert(0, sys.argv[1])
import cf
from cflib import caddy
def boom(*args, **kwargs):
    raise RuntimeError("boom in the cycle")
caddy.cycle = boom
sys.exit(cf.main(sys.argv[2:], writes=True))
PYBOOM
  CODE=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
}
pub_reset
boom_publish publish new.example.com --to 8080 --ip 203.0.113.50
check "an error that is no engine error after the record was created puts the record back" \
  "$(printf 'POST /zones/%s/dns_records\nDELETE /zones/%s/dns_records/<id>' "$ZID" "$ZID")" "$(writes)"
check_contains "…then is raised again" "RuntimeError: boom in the cycle" "$ERR"
check_contains "…having said the record is put back" "cf: RuntimeError: boom in the cycle; the DNS record of new.example.com is put back" "$ERR"
check "…not exit 0" "1" "$CODE"
pub dns-get example.com new
check "…no record is left" "2" "$CODE"
pub_reset
boom_publish publish www.example.com --to 8080 --ip 203.0.113.60
pub dns-get example.com www
check "…and an updated record is as it was" "A	www.example.com	203.0.113.10	yes	auto" "$(lines)"

pub_reset
fail_next POST /dns_records 500 1000 "boom"
pubw publish new.example.com --to 8080 --ip 203.0.113.50
check "a record write that fails stops publish before Caddy: exit 3, naming the backup" \
  "3 cf: Cloudflare 1000: boom; backup: $(ls "$DNSBK"/*-dns.json | tail -1) same " "$CODE $ERR $(same "$CADDYFILE" "$ORIGINAL") $(calls)"

echo "== unpublish =="

pub_reset
pubw publish new.example.com --to 8080 --ip 203.0.113.50
rm -f "$CADDYFILE".bak-* "$CSTATE/calls.jsonl"
mark
pubw unpublish new.example.com
check "unpublish removes the block, then deletes the record" "0" "$CODE"
check "…the cycle's line and copy, then the record and its backup" \
  "$(printf 'new.example.com\t200→down\nbackup: %s\ndeleted\tA\tnew.example.com\t203.0.113.50\tyes\nbackup: %s' "$(ls "$CADDYFILE".bak-*)" "$(ls "$DNSBK"/*-dns.json | tail -1)")" \
  "$(printf '%s\n' "$OUT" | cut -f1-5)"
check "…the Caddyfile is the original again" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
check "…one write: the record's deletion" "DELETE /zones/$ZID/dns_records/<id>" "$(writes)"
pub dns-get example.com new
check "…no record is left" "2" "$CODE"

pub_reset
pubw unpublish www.example.com
check "unpublish of a block written by hand removes it like caddy-site-remove" "0 same" "$CODE $(same "$CADDYFILE" "$FIXTURES/caddy/expected-remove-www")"

pub_reset
pubw unpublish example.com
check "unpublish of a record with no block runs no caddy, deletes only the A" \
  "0 deleted	A	example.com DELETE /zones/$ZID/dns_records/<id>" "$CODE $(nth 1 | cut -f1-3) $(writes)$(calls)"
pub dns-get example.com @
check "…the MX and the TXT of the name are kept" "MX TXT" "$(col 1 | tr '\n' ' ' | sed 's/ $//')"

pub_reset
pubw unpublish nothere.example.com
check "unpublish with neither block nor record exits 2" \
  "2 cf: nothing to unpublish: no site block and no A, AAAA or CNAME record for nothere.example.com" "$CODE $ERR"

pub_reset
printf '{"down": ["app.example.com"]}\n' > "$CSTATE/reload"
pubw unpublish www.example.com
check "a Caddy rollback stops unpublish before the record: exit 6, the record kept" "6 " "$CODE $(writes)"

pub_reset
mkdir -p "$DNSBK"
chmod 500 "$DNSBK"
pubw unpublish www.example.com
check "a records' backup that cannot be written stops unpublish before the block: exit 4" \
  "4 same 0 " "$CODE $(same "$CADDYFILE" "$ORIGINAL") $(copies) $(writes)$(calls)"
chmod 700 "$DNSBK"

pub_reset
WWW=$(www_id)
mark
fail_next DELETE "/dns_records/$WWW" 500 1000 "boom"
pubw unpublish www.example.com
check "a record deletion that fails after the block was removed exits 3" "3" "$CODE"
check "…and puts the block back: the Caddyfile is the original" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
check "…through a second cycle" "validate reload validate reload" "$(calls)"
check "…naming the record's backup and both copies" \
  "cf: Cloudflare 1000: boom; backup: $(ls "$DNSBK"/*-dns.json | tail -1); the site block of www.example.com is put back (the Caddyfile without it: $(ls "$CADDYFILE".bak-* | tail -1)); backup: $(ls "$CADDYFILE".bak-* | head -1)" \
  "$ERR"
pub_reset
WWW=$(www_id)
printf 'pass\nfail the block cannot be validated again\n' > "$CSTATE/validate"
fail_next DELETE "/dns_records/$WWW" 500 1000 "boom"
pubw unpublish www.example.com
check "a block that cannot be put back after a failed deletion exits 3" "3" "$CODE"
check_contains "…saying so with the cycle's reason" \
  "; the site block of www.example.com could not be put back (caddy validate failed: Error: the block cannot be validated again; the Caddyfile is restored; backup: " "$ERR"
check "…the Caddyfile left without the block" "same" "$(same "$CADDYFILE" "$FIXTURES/caddy/expected-remove-www")"
pub dns-get example.com www
check "…the record kept" "A	www.example.com	203.0.113.10	yes	auto" "$(lines)"

pub_reset
APEX=$(CCONF="$PUB_CONFIG" pub dns-get example.com @ --json; printf '%s' "$OUT" | python3 -c 'import json,sys; print(next(r["id"] for r in json.load(sys.stdin) if r["type"] == "A"))')
fail_next DELETE "/dns_records/$APEX" 500 1000 "boom"
pubw unpublish example.com
check "unpublish of a record with no block whose deletion fails exits 3, naming the backup, no caddy run" \
  "3 cf: Cloudflare 1000: boom; backup: $(ls "$DNSBK"/*-dns.json | tail -1) " "$CODE $ERR $(calls)"
pub dns-get example.com @
check "…the record kept" "A MX TXT" "$(col 1 | tr '\n' ' ' | sed 's/ $//')"

pub_reset
cfw dns-create example.com --name www --type AAAA --content 2001:db8::1 --proxied
AAAA_ID=$(printf '%s\n' "$OUT" | head -1 | cut -f7)
rm -rf "$DNSBK"
fail_next DELETE "/dns_records/$AAAA_ID" 500 1000 "boom"
pubw unpublish www.example.com
check "a deletion that fails after another one exits 3" "3" "$CODE"
check_contains "…saying the record is put back" "cf: Cloudflare 1000: boom; the DNS record of www.example.com is put back (its undone state: " "$ERR"
check_contains "…and the block" "; the site block of www.example.com is put back (the Caddyfile without it: " "$ERR"
check "…the block is back" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
pub dns-get example.com www
check "…the deleted record is back beside the one kept" "A AAAA" "$(col 1 | tr '\n' ' ' | sed 's/ $//')"
unset CCONF

echo "== inventory =="

INV_CADDYFILE="$FIXTURES/caddy/Caddyfile-inventory"
INV_HEAD="$(printf 'host\trecord\tproxied\tblock\thttps\tissuer\texpires')"
caddy_reset
cp "$INV_CADDYFILE" "$CADDYFILE"
printf '{"alive": true, "sites": {"app.example.com": 200, "www.example.com": 200, "orphan.example.com": 200}}\n' > "$CSTATE/world.json"
reset
mark
pub inventory example.com
check "inventory: the zone's SSL settings, the DNS ↔ Caddyfile matrix with each host's check, the backup" \
  "$(printf 'ssl full\tuniversal_ssl on\tmin_tls_version 1.2\ttls_1_3 on\talways_use_https off\n%s\napp.example.com\tCNAME www.example.com\tyes\tyes\t200\t%s\t%s\nexample.com\tA 203.0.113.10\tyes\tno\tdown (tls)\t-\t-\norphan.example.com\t-\t-\tyes\t200\t%s\t%s\nwww.example.com\tA 203.0.113.10\tyes\tyes\t200\t%s\t%s\nrecords without block: example.com\nblocks without record: orphan.example.com\nbackup: %s' \
    "$INV_HEAD" "$ISSUER" "$EXPIRES" "$ISSUER" "$EXPIRES" "$ISSUER" "$EXPIRES" "$(ls "$DNSBK"/*-dns.json | tail -1)")" \
  "$OUT"
check "…sends no write and runs no caddy" "" "$(writes)$(calls)"
check "…the backup holds every record of the zone" "7" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["data"]["records"]))' "$(ls "$DNSBK"/*-dns.json | tail -1)")"
cfw restore "$(ls "$DNSBK"/*-dns.json | tail -1)"
check "…and it replays: nothing to restore on an unchanged zone" "0 nothing to restore" "$CODE $(printf '%s' "$OUT" | cut -c1-18)"
pub inventory example.com --json
check "inventory --json gives the matrix and the checks" "orphan.example.com example.com 4 200" \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; i=json.load(sys.stdin); print(" ".join(i["blocks_without_record"]), " ".join(i["records_without_block"]), len(i["hosts"]), i["hosts"][0]["https"])')"
CCONF="$CONFIG" pub inventory example.com
check "inventory on a machine without Caddy compares nothing, and says so" \
  "$(printf 'example.com\tA 203.0.113.10\tyes\t-\ncaddy: no caddy section in %s: the blocks are not compared' "$CONFIG")" \
  "$(printf '%s\n' "$OUT" | grep -E '^example.com|^caddy:' | cut -f1-4)"
caddy_reset
pub inventory example.com
check "inventory on the full fixture: the hosts of a block of several have no record" \
  "$(printf 'records without block: example.com\nblocks without record: a.example.com, b.example.com')" "$(printf '%s\n' "$OUT" | grep 'without')"
pubw inventory example.com
check "inventory is a read: cf-write.py refuses it" "2" "$CODE"

caddy_reset
cp "$INV_CADDYFILE" "$CADDYFILE"
printf '{"alive": true, "sites": {"app.example.com": 200, "www.example.com": 200, "orphan.example.com": 200}}\n' > "$CSTATE/world.json"
reset
cfw dns-create example.com --name slower --type A --content 203.0.113.9
started=$(python3 -c 'import time; print(time.monotonic())')
CADDY_EXTRA="CF_CHECK_DEADLINE=2" pub inventory example.com
took=$(python3 -c 'import sys, time; print(int(time.monotonic() - float(sys.argv[1])))' "$started")
check "inventory: a host whose resolver answers past the deadline is not checked (time)" \
  "slower.example.com	A 203.0.113.9	no	no	not checked (time)" "$(printf '%s\n' "$OUT" | grep '^slower' | cut -f1-5)"
check "…the others checked within it" "200 200" "$(printf '%s\n' "$OUT" | grep -E '^(app|www)\.' | cut -f5 | tr '\n' ' ' | sed 's/ $//')"
check "…the whole inventory ending by the deadline, not by the slow answer (8 s)" "yes" "$([ "$took" -lt 5 ] && echo yes || echo "no: $took s")"
check "…and exits 0" "0" "$CODE"

reset
cfw dns-create example.com --name 'é' --type A --content 203.0.113.9
cfw dns-create example.com --name "$(printf 'l%.0s' $(seq 1 64))" --type A --content 203.0.113.9
cfw dns-create example.com --name '*' --type A --content 203.0.113.9
rm -f "$NAMES.log"
pub inventory example.com --json
check "inventory checks a name that is not ASCII, or has a label over 63 characters, as a bad name" "0 bad name bad name" \
  "$CODE $(printf '%s' "$OUT" | python3 -c 'import json,sys; h={r["host"]: r for r in json.load(sys.stdin)["hosts"]}; print(h["é.example.com"]["address"], h["l" * 64 + ".example.com"]["address"])')"
check "…asking the resolver for neither, nor for the wildcard" "" "$(resolved | tr ' ' '\n' | grep -E 'é|l{64}|\*')"
check "…with no traceback" "0" "$(grep -c Traceback "$WORK/err")"

echo "== end to end: the whole spec through the tool's requests =="

# DNS, protections, cache, Caddy, then publish, check, inventory and
# unpublish of one service, each as the request the mod sends.
CCONF="$PUB_CONFIG"
pub_reset
pubj '{"command": "rules", "args": {"zone": "example.com", "plugin": true}}'
RULES_BEFORE=$OUT
pubj '{"command": "cache-rules", "args": {"zone": "example.com"}}'
CACHE_BEFORE=$OUT
pubwj '{"command": "dns-create", "args": {"zone": "example.com", "name": "svc", "type": "A", "content": "203.0.113.70", "proxied": false}}'
check "e2e: DNS: a record for the service, DNS only" "created	A	svc.example.com	203.0.113.70	no" "$(nth 1 | cut -f1-5)"
pubwj '{"command": "allow-only-countries", "args": {"target": "svc.example.com", "countries": ["FR"]}}'
check "e2e: protections: France only on the host, in one call" "created" "$(nth 1 | cut -f1)"
pubj '{"command": "rules", "args": {"zone": "example.com", "plugin": true}}'
SVC_RULE=$(printf '%s\n' "$OUT" | grep 'svc.example.com')
pubwj '{"command": "cache-rule-add", "args": {"zone": "example.com", "host": "svc.example.com"}}'
check "e2e: cache: the host cached" "created" "$(nth 1 | cut -f1)"
pubj '{"command": "cache-rules", "args": {"zone": "example.com"}}'
SVC_CACHE=$(printf '%s\n' "$OUT" | grep 'svc.example.com')
pubj '{"command": "caddy-status"}'
check "e2e: Caddy: alive, validating, its service loading the envfile" "alive ok ok" \
  "$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "admin" || $1 == "validate" || $1 == "service" {print $2}' | tr '\n' ' ' | sed 's/ $//')"
pubwj '{"command": "publish", "args": {"host": "svc.example.com", "to": "8081"}}'
check "e2e: publish takes the record over: proxied, on the default target" \
  "$(printf 'before\tA\tsvc.example.com\t203.0.113.70\tno\nafter\tA\tsvc.example.com\t203.0.113.10\tyes')" "$(nth 1,2 | cut -f1-5)"
check "e2e: …the block written and served" "svc.example.com	down→200" "$(printf '%s\n' "$OUT" | grep '→')"
check "e2e: …and the host checked" "svc.example.com	127.0.0.1	200	$ISSUER	$EXPIRES" "$(printf '%s\n' "$OUT" | tail -1)"
check "e2e: …with C5's block" "$(printf 'https://svc.example.com {\n\timport tls_config\n\tlog\n\treverse_proxy 127.0.0.1:8081\n}')" \
  "$(sed -n '/^https:\/\/svc.example.com {/,/^}/p' "$CADDYFILE")"
pubj '{"command": "check", "args": {"host": "svc.example.com"}}'
check "e2e: check" "svc.example.com	127.0.0.1	200	$ISSUER	$EXPIRES" "$(nth 2)"
pubj '{"command": "inventory", "args": {"zone": "example.com"}}'
check "e2e: inventory: the host with its record, its block and its check" "svc.example.com	A 203.0.113.10	yes	yes	200" \
  "$(printf '%s\n' "$OUT" | grep '^svc' | cut -f1-5)"
check "e2e: …the matrix" "$(printf 'records without block: example.com\nblocks without record: a.example.com, b.example.com')" \
  "$(printf '%s\n' "$OUT" | grep 'without')"
pubwj '{"command": "unpublish", "args": {"host": "svc.example.com"}}'
check "e2e: unpublish: the block removed, then the record" \
  "$(printf 'svc.example.com\t200→down\ndeleted\tA\tsvc.example.com\t203.0.113.10\tyes')" "$(printf '%s\n' "$OUT" | grep -v '^backup: ' | cut -f1-5)"
check "e2e: …the Caddyfile is the original again" "same" "$(same "$CADDYFILE" "$ORIGINAL")"
pubj '{"command": "check", "args": {"host": "svc.example.com"}}'
check "e2e: check: the host no longer answers" "svc.example.com	127.0.0.1	down (tls)	-	-" "$(nth 2)"
pubj '{"command": "inventory", "args": {"zone": "example.com"}}'
check "e2e: inventory: the host is gone" "0" "$(printf '%s\n' "$OUT" | grep -c '^svc')"
pubwj '{"command": "dns-create", "args": {"zone": "example.com", "name": "v6only", "type": "AAAA", "content": "2001:db8::7"}}'
pubwj '{"command": "publish", "args": {"host": "v6only.example.com", "to": "8082"}}'
check "e2e: publish refuses a host with an AAAA, naming it" \
  "2 cf: v6only.example.com has an AAAA record (2001:db8::7): dns-delete it first, publish writes an A alone; nothing was changed" "$CODE $ERR"
pubwj '{"command": "publish", "args": {"host": "late.example.com", "to": "8083"}}'
check "e2e: publish of a host the public cannot resolve yet says so, exit 0" "0 published, but the check reads nxdomain" \
  "$CODE $(printf '%s\n' "$OUT" | tail -1)"
pubwj '{"command": "unpublish", "args": {"host": "late.example.com"}}'
check "e2e: …and its unpublish leaves the Caddyfile as it was" "0 same" "$CODE $(same "$CADDYFILE" "$ORIGINAL")"
pubwj '{"command": "worker-domain-add", "args": {"hostname": "edge.example.com", "script": "hello"}}'
check "e2e: Workers: a custom domain attached" "attached	edge.example.com	hello" "$OUT"
pubj '{"command": "worker-domains", "args": {"zone": "example.com"}}'
check "e2e: …listed among the zone's" "edge.example.com legacy.example.com" "$(col 2 | sort | tr '\n' ' ' | sed 's/ $//')"
pubwj '{"command": "worker-domain-delete", "args": {"hostname": "edge.example.com"}}'
check "e2e: …detached, after its backup" "deleted	edge.example.com	hello	example.com" "$(nth 1)"
pubwj "{\"command\": \"restore\", \"args\": {\"path\": \"$(backup_of)\"}}"
check "e2e: …and attached again by restore" "restored	edge.example.com	hello	example.com" "$(nth 1)"
pubj '{"command": "rules", "args": {"zone": "example.com", "plugin": true}}'
check "e2e: the protection is kept: unpublish touches only the record and the block" "1" "$(printf '%s\n' "$OUT" | grep -c 'svc.example.com')"
check "e2e: …the very rule, by value" "$SVC_RULE" "$(printf '%s\n' "$OUT" | grep 'svc.example.com')"
pubj '{"command": "cache-rules", "args": {"zone": "example.com"}}'
check "e2e: …and the very cache rule" "$SVC_CACHE" "$(printf '%s\n' "$OUT" | grep 'svc.example.com')"
pubwj "{\"command\": \"rule-delete\", \"args\": {\"zone\": \"example.com\", \"rule\": \"$(printf '%s' "$SVC_RULE" | cut -f2)\"}}"
check "e2e: the rule deleted after the unpublish" "0 deleted" "$CODE $(nth 1 | cut -f1)"
pubwj "{\"command\": \"cache-rule-delete\", \"args\": {\"zone\": \"example.com\", \"rule\": \"$(printf '%s' "$SVC_CACHE" | cut -f1)\"}}"
check "e2e: the cache rule deleted after the unpublish" "0 deleted" "$CODE $(nth 1 | cut -f1)"
pubj '{"command": "rules", "args": {"zone": "example.com", "plugin": true}}'
check "e2e: …the rules are gone: the plugin's rules as before the cycle" "$RULES_BEFORE" "$OUT"
pubj '{"command": "cache-rules", "args": {"zone": "example.com"}}'
check "e2e: …the cache rules as before the cycle, the dashboard's kept" "$CACHE_BEFORE" "$OUT"
unset CCONF

echo "== install.sh and the doctor =="

# inst [args...]: install.sh in the same scrubbed environment as the engine.
inst() {
  env -i PATH="${INST_PATH:-$PATH}" HOME="$HOMEDIR" CLAUDE_CLOUDFLARE_CONFIG="$CONFIG" CF_API_BASE="$API" \
    BETA_CLOUDFLARE_API_TOKEN="${INST_BETA-$TOKEN_BETA}" ${EXTRA_ENV:-} \
    /bin/bash "$ROOT/install.sh" "$@" >"$WORK/out" 2>"$WORK/err"
  CODE=$?
  OUT=$(cat "$WORK/out")
  ERR=$(cat "$WORK/err")
  cat "$WORK/out" "$WORK/err" >> "$CAPTURED"
}

reset
inst --check
check "the doctor passes with every token valid" "0" "$CODE"
check_contains "the doctor checks alpha's token" "cloudflare: account alpha: active" "$OUT"
check_contains "the doctor checks beta's token" "cloudflare: account beta: active" "$OUT"
check "the doctor verifies each account once" "2" "$(sent | grep -c 'tokens/verify')"

mkdir -p "$WORK/nopython"
INST_PATH="$WORK/nopython" inst --check
check "no python3 exits 11" "11" "$CODE"
check_contains "no python3 names the fix" "fix:" "$ERR"

mkdir -p "$WORK/oldpython"
printf '#!/bin/sh\necho False\n' > "$WORK/oldpython/python3"
chmod +x "$WORK/oldpython/python3"
INST_PATH="$WORK/oldpython:/usr/bin:/bin" inst --check
check "a python3 older than 3.9 exits 11" "11" "$CODE"

# An empty token is no account.
INST_BETA= EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/noaccount.json" inst --check
check "no account exits 12" "12" "$CODE"
INST_BETA= EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/noaccount.json" inst
check_contains "install says where a token goes" "<NAME>_CLOUDFLARE_API_TOKEN" "$ERR"

EXTRA_ENV="BETA_CLOUDFLARE_API_TOKEN=cf-wrong" inst --check
check "a token that fails its check exits 13" "13" "$CODE"
check_contains "the other accounts are still checked" "cloudflare: account alpha: active" "$OUT"
check_contains "the failing account is named" "cloudflare: account beta: cf: Cloudflare 10000: Authentication error" "$ERR"

EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/broken.json" inst --check
check "a malformed config exits 14" "14" "$CODE"

echo "== the doctor: permissions and the local Caddy =="

reset
inst --check
check_contains "the doctor reads every family of commands with alpha's token" "cloudflare: account alpha: reads: every family readable" "$OUT"
check_contains "…and names the write its policies lack, with the commands that need it" \
  "cloudflare: account alpha: missing write: Workers Scripts (worker-deploy, worker-delete, worker-domain-add, worker-domain-delete)" "$OUT"
check "…and no other" "1" "$(printf '%s\n' "$OUT" | grep -c 'account alpha: missing')"
check_contains "beta's token is refused the Workers reads: named" \
  "cloudflare: account beta: missing read: Workers Routes (worker-routes)" "$OUT"
check_contains "…both of them" "cloudflare: account beta: missing read: Workers Scripts (workers, worker-domains)" "$OUT"
check_contains "…and its writes, which its policies cannot show, are said to be unchecked" \
  "cloudflare: account beta: writes: not checked: the token cannot read its own policies (grant it API Tokens Read for this check)" "$OUT"
check "missing permissions are reported, not a failure" "0" "$CODE"
check "the doctor's probes only read" "" "$(sent | grep -v '^GET')"
check_contains "without a caddy section the Caddy checks are skipped" \
  "cloudflare: caddy: no caddy section in $CONFIG: the Caddy checks are skipped" "$OUT"

caddy_reset
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$CADDY_CONFIG FAKE_CADDY_STATE=$CSTATE" inst --check
check "the doctor passes with the local Caddy set up" "0" "$CODE"
check_contains "…the binary found" "cloudflare: caddy: binary $FAKE_CADDY: v2.8.4 h1:fake" "$OUT"
check_contains "…the service found, starting caddy with the envfile" "cloudflare: caddy: service launchd $PLIST: --envfile $ENVFILE" "$OUT"
check_contains "…the envfile holding the variable the tls snippet reads, its value never shown" \
  "cloudflare: caddy: envfile $ENVFILE holds CF_API_TOKEN, the variable of the tls_config snippet" "$OUT"
check "…running caddy version only" "version" "$(calls)"

printf 'LOG=info\n' > "$CADDY/novar.env"
chmod 600 "$CADDY/novar.env"
caddy_config "$WORK/caddy-novar.json" ", \"envfile\": \"$CADDY/novar.env\""
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/caddy-novar.json FAKE_CADDY_STATE=$CSTATE" inst --check
check "an envfile without the token variable exits 15" "15" "$CODE"
check_contains "…naming the variable" \
  "cloudflare: caddy: error: envfile $CADDY/novar.env has no CF_API_TOKEN, the variable of the tls_config snippet" "$ERR"
check_contains "…and the fix" "cloudflare: not ready. Fix the Caddy setup named above" "$ERR"
caddy_config "$WORK/caddy-noenvfile.json" ", \"envfile\": \"$CADDY/absent.env\""
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/caddy-noenvfile.json FAKE_CADDY_STATE=$CSTATE" inst --check
check "an envfile that is not there exits 15" "15" "$CODE"
check_contains "…naming it" "cloudflare: caddy: error: cannot read the envfile $CADDY/absent.env" "$ERR"
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/caddy-noenv.json FAKE_CADDY_STATE=$CSTATE" inst --check
check "a service that does not load the envfile exits 15" "15" "$CODE"
check_contains "…saying so" "cloudflare: caddy: error: $CADDY/noenv.plist does not start caddy with --envfile $ENVFILE" "$ERR"
caddy_config "$WORK/caddy-noservice.json" ", \"service\": \"$CADDY/absent.plist\""
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/caddy-noservice.json FAKE_CADDY_STATE=$CSTATE" inst --check
check "a service file that is not there exits 15" "15" "$CODE"
check_contains "…naming it" "cloudflare: caddy: error: cannot read $CADDY/absent.plist" "$ERR"
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/caddy-nobinary.json FAKE_CADDY_STATE=$CSTATE" inst --check
check "a caddy binary that is not there exits 15" "15" "$CODE"
check_contains "…naming it" "cloudflare: caddy: error: binary $CADDY/bin/absent: cannot run $CADDY/bin/absent" "$ERR"
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/caddy-novar.json FAKE_CADDY_STATE=$CSTATE BETA_CLOUDFLARE_API_TOKEN=cf-wrong" inst --check
check "a failing token outranks a Caddy problem: exit 13" "13" "$CODE"
check "no doctor output holds the envfile's token" "0" "$(grep -c "$CADDY_TOKEN" "$CAPTURED")"

# doc <args...>: engine/doctor.py, as install.sh runs it.
doc() { run doctor.py "$@"; }
reset
EXTRA_ENV="IOTA_CLOUDFLARE_API_TOKEN=$TOKEN_IOTA" doc permissions iota tok-iota
check "a token holding every write under its dashboard name (… Edit): every family writable" \
  "0 $(printf 'reads: every family readable\nwrites: every family writable')" "$CODE $OUT"
EXTRA_ENV="DELTA_CLOUDFLARE_API_TOKEN=$TOKEN_DELTA" doc permissions delta tok-delta
check "DNS Firewall Write grants no DNS write, Cache Settings Write no purge: no false « every family writable »" \
  "$(printf 'reads: every family readable\nmissing write: DNS (dns-create, dns-update, dns-delete, publish, unpublish)\nmissing write: Cache Purge (purge, purge-all)')" "$OUT"
EXTRA_ENV="EPSILON_CLOUDFLARE_API_TOKEN=$TOKEN_EPSILON" doc permissions epsilon tok-epsilon
check "Cache Purge alone: the cache rules' writes are missing, not the purges" \
  "$(printf 'reads: every family readable\nmissing write: Cache Rules (cache-rule-add, cache-rule-delete)')" "$OUT"
EXTRA_ENV="BETA_CLOUDFLARE_API_TOKEN=cf-wrong" doc permissions beta
check "an invalid token is said invalid, not missing every read: exit 1" \
  "1 invalid token: Cloudflare 10000: Authentication error: nothing it may read or write can be told" "$CODE $OUT"
EXTRA_ENV="ZETA_CLOUDFLARE_API_TOKEN=$TOKEN_ZETA" doc permissions zeta tok-zeta
check "a token with no zone to probe on says which families are not probed" \
  "$(printf 'not probed: %s (no zone to probe on)\n' DNS 'Zone Settings' 'SSL and Certificates' 'Zone WAF' 'Firewall Services' 'Bot Management' 'Cache Rules' 'Workers Routes')
writes: not checked: the token cannot read its own policies (grant it API Tokens Read for this check)" "$OUT"
reset
EXTRA_ENV="ETA_CLOUDFLARE_API_TOKEN=$TOKEN_ETA ETA_CLOUDFLARE_ACCOUNT_ID=acc-alpha" doc permissions eta tok-eta
check "a token refused its policies as a user reads them on its account" "writes: every family writable" "$(printf '%s\n' "$OUT" | tail -1)"
check "…asking the user path, then the account's" "$(printf 'GET /user/tokens/tok-eta\nGET /accounts/acc-alpha/tokens/tok-eta')" \
  "$(sent | grep 'tokens/tok-eta')"
doc
check "doctor.py without arguments gives its usage: exit 2" \
  "2 cf: usage: doctor.py permissions <account> [token id] | doctor.py caddy" "$CODE $ERR"
doc permissions
check "…and with too few" "2" "$CODE"
check "the doctor's permission checks only read" "" "$(sent | grep -v '^GET')"

# The DNS-01 token of the envfile: verified, its DNS edit right read when it
# may read its own policies; each envfile alone, the service not checked.
CADDY_TOKEN_DNS=cf-caddy-fixture-token-dns-2c8f71e4
CADDY_TOKEN_ZONE=cf-caddy-fixture-token-zone-6b3d09fa
CADDY_TOKEN_OLD=cf-caddy-fixture-token-old-4e9a17c2
CADDY_TOKEN_BAD=cf-caddy-fixture-token-bad-7d21e5b8
# dns01_doc <token>: doctor.py caddy on an envfile holding that token.
dns01_doc() {
  printf 'CF_API_TOKEN=%s\n' "$1" > "$CADDY/dns01.env"
  chmod 600 "$CADDY/dns01.env"
  caddy_config "$WORK/caddy-dns01.json" ", \"envfile\": \"$CADDY/dns01.env\", \"manager\": null"
  EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/caddy-dns01.json FAKE_CADDY_STATE=$CSTATE" doc caddy
}
reset
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$CADDY_CONFIG FAKE_CADDY_STATE=$CSTATE" doc caddy
check "the DNS-01 token is verified; one that may not read its policies has its DNS edit right said not checkable" \
  "0 caddy: DNS-01 token CF_API_TOKEN: valid; DNS edit right not checkable with this token (it may not read its own policies)" \
  "$CODE $(printf '%s\n' "$OUT" | tail -1)"
check "…by a GET of /user/tokens/verify, then of the token" "$(printf 'GET /user/tokens/verify\nGET /user/tokens/tok-caddy')" "$(sent)"
dns01_doc "$CADDY_TOKEN_DNS"
check "a DNS-01 token that reads its policies and holds DNS Write passes" "0 caddy: DNS-01 token CF_API_TOKEN: valid, with DNS Write" \
  "$CODE $(printf '%s\n' "$OUT" | tail -1)"
dns01_doc "$CADDY_TOKEN_ZONE"
check "a DNS-01 token without DNS Write fails" \
  "1 caddy: error: DNS-01 token CF_API_TOKEN is valid but has no DNS Write: Caddy cannot answer a DNS-01 challenge" \
  "$CODE $(printf '%s\n' "$OUT" | tail -1)"
dns01_doc "$CADDY_TOKEN_OLD"
check "an expired DNS-01 token fails" "1 caddy: error: DNS-01 token CF_API_TOKEN is expired" "$CODE $(printf '%s\n' "$OUT" | tail -1)"
dns01_doc "$CADDY_TOKEN_BAD"
check "an invalid DNS-01 token fails" "1 caddy: error: DNS-01 token CF_API_TOKEN is invalid: Cloudflare 10000: Authentication error" \
  "$CODE $(printf '%s\n' "$OUT" | tail -1)"
chmod 644 "$CADDY/dns01.env"
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/caddy-dns01.json FAKE_CADDY_STATE=$CSTATE" doc caddy
check_contains "an envfile wider than 0600 is flagged" "caddy: warning: $CADDY/dns01.env is readable by others (mode 644): chmod 600 it" "$OUT"
printf 'CF_API_TOKEN=%s\nLOG=info\n' "$CADDY_TOKEN_DNS" > "$CADDY/dns01.env"
chmod 600 "$CADDY/dns01.env"
caddy_config "$WORK/caddy-nosnippet-doc.json" ", \"envfile\": \"$CADDY/dns01.env\", \"manager\": null, \"tls_snippet\": null"
reset
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/caddy-nosnippet-doc.json FAKE_CADDY_STATE=$CSTATE" doc caddy
check "without a tls_snippet the token variable is not checked, and says so" \
  "0 caddy: envfile $CADDY/dns01.env: 2 variables; no tls_snippet configured, token variable not checked" \
  "$CODE $(printf '%s\n' "$OUT" | tail -1)"
check "…nor sent" "" "$(sent)"
check "a config without a manager says the service is not checked" "caddy: service: no manager in the config, not checked" \
  "$(printf '%s\n' "$OUT" | grep '^caddy: service')"
caddy_config "$WORK/caddy-noenvfile-doc.json" ", \"envfile\": null, \"manager\": null"
EXTRA_ENV="CLAUDE_CLOUDFLARE_CONFIG=$WORK/caddy-noenvfile-doc.json FAKE_CADDY_STATE=$CSTATE" doc caddy
check "a config without an envfile fails, saying what validate and reload would lack" \
  "1 caddy: error: no envfile in the config: caddy validate and reload would run without the DNS-01 token" \
  "$CODE $(printf '%s\n' "$OUT" | tail -1)"
check "no doctor output holds a DNS-01 token" "0" \
  "$(grep -cE "$CADDY_TOKEN|$CADDY_TOKEN_DNS|$CADDY_TOKEN_ZONE|$CADDY_TOKEN_OLD|$CADDY_TOKEN_BAD" "$CAPTURED")"

echo "== tokens never leave =="

reset
fail_next GET /zones 400 9999 "bad header Bearer $TOKEN_ALPHA"
cf zones
check "a token echoed back by the API is masked" "cf: Cloudflare 9999: bad header Bearer [token]" "$ERR"
fail_next GET /zones 400 9999 "bad header Bearer $TOKEN_BETA"
EXTRA_ENV="BETA_CLOUDFLARE_ACCOUNT_ID=acc-beta" cf zones --account beta
check "the second account's token echoed back is masked" "cf: Cloudflare 9999: bad header Bearer [token]" "$ERR"
reset
fail_next PUT /rulesets/phases/http_request_firewall_custom/entrypoint 400 9999 "bad header Bearer $TOKEN_ALPHA"
cfw block-countries tm.example.com RU
check "a token echoed back by a failing write is masked" \
  "3 cf: Cloudflare 9999: bad header Bearer [token]; backup: ${ERR##*; backup: }" "$CODE $ERR"

fail_next POST /purge_cache 400 9999 "bad header Bearer $TOKEN_ALPHA"
cfw purge example.com --host www.example.com
check "…by a failing purge" "3 cf: Cloudflare 9999: bad header Bearer [token]" "$CODE $ERR"
fail_next PUT /workers/scripts/fresh 400 9999 "bad header Bearer $TOKEN_ALPHA"
cfw worker-deploy fresh --file "$WORK/new.js"
check "…by a failing deploy" "3 cf: Cloudflare 9999: bad header Bearer [token]" "$CODE $ERR"

# Every request the server received, multipart bodies whole among them.
reset
check "the request log holds the multipart bodies as sent" "yes" "$(grep -q '"__raw": "--' "$REQUESTS" && echo yes)"
check "no request the engine sent holds a fixture token" "0" \
  "$(grep -cE "$TOKEN_ALPHA|$TOKEN_BETA|$TOKEN_GAMMA|$TOKEN_IOTA|$TOKEN_DELTA|$TOKEN_EPSILON|$TOKEN_ZETA|$TOKEN_ETA|$CADDY_TOKEN|$CADDY_TOKEN_DNS|$CADDY_TOKEN_ZONE|$CADDY_TOKEN_OLD|$CADDY_TOKEN_BAD" "$REQUESTS")"
check "no output of the engine holds a fixture token" "0" \
  "$(grep -cE "$TOKEN_ALPHA|$TOKEN_BETA|$TOKEN_GAMMA|$TOKEN_IOTA|$TOKEN_DELTA|$TOKEN_EPSILON|$TOKEN_ZETA|$TOKEN_ETA|$CADDY_TOKEN|$CADDY_TOKEN_DNS|$CADDY_TOKEN_ZONE|$CADDY_TOKEN_OLD|$CADDY_TOKEN_BAD" "$CAPTURED")"
check "no backup holds a fixture token" "" \
  "$(grep -rlE "$TOKEN_ALPHA|$TOKEN_BETA|$TOKEN_GAMMA|$TOKEN_IOTA|$TOKEN_DELTA|$TOKEN_EPSILON|$TOKEN_ZETA|$TOKEN_ETA|$CADDY_TOKEN|$CADDY_TOKEN_DNS|$CADDY_TOKEN_ZONE|$CADDY_TOKEN_OLD|$CADDY_TOKEN_BAD" "$WORK/backups" 2>/dev/null)"
check "no Caddyfile or copy of it holds the envfile's token" "" \
  "$(grep -lF "$CADDY_TOKEN" "$CADDYFILE" "$CADDYFILE".bak-* 2>/dev/null)"
check "the engine prints no traceback" "0" "$(grep -c 'Traceback' "$CAPTURED")"

echo "== the mod and the engine agree =="

# The mod's lists are static; they must name exactly the engine's commands,
# and its reads exactly the commands the engine marks as reads.
agreement=$(python3 - "$ENGINE" "$ROOT/hooks/register.ts" <<'PYENUM'
import re, sys
sys.path.insert(0, sys.argv[1])
import cf
parser = cf.build_parser()
subs = [a for a in parser._actions if a.dest == "command"][0].choices
src = open(sys.argv[2], encoding="utf-8").read()
def listed(head, close):
    if head not in src:
        return None
    return set(re.findall(r"'([A-Za-z0-9_-]+)'", src.split(head, 1)[1].split(close, 1)[0]))
commands = listed("export const COMMANDS = [", "]")
reads = listed("export const READS = new Set([", "])")
if commands is None or reads is None:
    print("no COMMANDS or READS list in register.ts")
    sys.exit()
engine_reads = {name for name in subs if cf.is_read(parser, name)}
print("commands:" + " ".join(sorted(set(subs) ^ commands)) + " reads:" + " ".join(sorted(engine_reads ^ reads)))
PYENUM
)
check "the mod's COMMANDS and READS match the engine's" "commands: reads:" "$agreement"

echo "== the mod =="

if command -v claude >/dev/null 2>&1; then
  claude plugin test "$ROOT" >"$WORK/mod.log" 2>&1
  mod_code=$?
  grep -E '^\(fail\)|^ *[0-9]+ (pass|fail)$' "$WORK/mod.log"
  check "the mod's tests pass (claude plugin test)" "0" "$mod_code"
  claude plugin validate "$ROOT" >"$WORK/validate.log" 2>&1
  validate_code=$?
  [ "$validate_code" -eq 0 ] || grep -E '✘|^ *❯' "$WORK/validate.log"
  check "the plugin passes claude plugin validate" "0" "$validate_code"
else
  echo "  skip the mod's tests: claude is not on PATH"
  skip=$((skip + 1))
  echo "  skip claude plugin validate: claude is not on PATH"
  skip=$((skip + 1))
fi

echo "== no output holds a token =="

# Every output the engine printed, and the mod's test log.
check "no output of the engine or of the mod holds a fixture token" "0" \
  "$(cat "$CAPTURED" "$WORK/mod.log" 2>/dev/null | grep -cE "$TOKEN_ALPHA|$TOKEN_BETA|$TOKEN_GAMMA|$TOKEN_IOTA|$TOKEN_DELTA|$TOKEN_EPSILON|$TOKEN_ZETA|$TOKEN_ETA|$CADDY_TOKEN|$CADDY_TOKEN_DNS|$CADDY_TOKEN_ZONE|$CADDY_TOKEN_OLD|$CADDY_TOKEN_BAD")"

echo
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
