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

OTHER_PID=""

stop() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
  [ -n "$OTHER_PID" ] && kill "$OTHER_PID" 2>/dev/null && wait "$OTHER_PID" 2>/dev/null
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

check "no backup holds a fixture token" "" \
  "$(grep -rlE "$TOKEN_ALPHA|$TOKEN_BETA|$TOKEN_GAMMA" "$WORK/backups" 2>/dev/null)"
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
  "$(cat "$CAPTURED" "$WORK/mod.log" 2>/dev/null | grep -cE "$TOKEN_ALPHA|$TOKEN_BETA|$TOKEN_GAMMA")"

echo
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
