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

OTHER_PID=""

stop() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
  [ -n "$OTHER_PID" ] && kill "$OTHER_PID" 2>/dev/null && wait "$OTHER_PID" 2>/dev/null
  [ -n "$WORLD_PID" ] && kill "$WORLD_PID" 2>/dev/null && wait "$WORLD_PID" 2>/dev/null
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
# fail_next <method> <path suffix> <status> <code> <message>
fail_next() {
  curl -fsS -X POST "http://127.0.0.1:$PORT/__fail" -H 'Content-Type: application/json' \
    -d "{\"method\":\"$1\",\"path\":\"$2\",\"status\":$3,\"code\":$4,\"message\":\"$5\"}" >/dev/null
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
check "plugin version" "0.4.0" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")"
check "plugin license" "MIT" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["license"])' "$ROOT/.claude-plugin/plugin.json")"
check "marketplace lists the plugin at the same version" "cloudflare 0.4.0" \
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
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=example.com -days 2 \
  -keyout "$CADDY/key.pem" -out "$CADDY/cert.pem" >/dev/null 2>&1 || { echo "openssl could not make the fixture certificate"; exit 1; }
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
  "$(grep -cE "$TOKEN_ALPHA|$TOKEN_BETA|$TOKEN_GAMMA" "$REQUESTS")"
check "no backup holds a fixture token" "" \
  "$(grep -rlE "$TOKEN_ALPHA|$TOKEN_BETA|$TOKEN_GAMMA|$CADDY_TOKEN" "$WORK/backups" 2>/dev/null)"
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
    return set(re.findall(r"'([a-z-]+)'", src.split(head, 1)[1].split(close, 1)[0]))
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
else
  echo "  skip the mod's tests: claude is not on PATH"
  skip=$((skip + 1))
fi

echo "== no output holds a token =="

# Every output the engine printed, and the mod's test log.
check "no output of the engine or of the mod holds a fixture token" "0" \
  "$(cat "$CAPTURED" "$WORK/mod.log" 2>/dev/null | grep -cE "$TOKEN_ALPHA|$TOKEN_BETA|$TOKEN_GAMMA|$CADDY_TOKEN")"

echo
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
