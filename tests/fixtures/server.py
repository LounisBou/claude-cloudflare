#!/usr/bin/env python3
"""A local stand-in for the Cloudflare API, started by tests/run-tests.sh.

It keeps its state in memory, answers in Cloudflare's envelope
({"success", "errors", "result", "result_info"}) and pages its lists. Each
token sees its own accounts and zones, read from tests/fixtures/state.json.
Requests are logged (method, path, query, body) for the suite to assert on;
headers, and so tokens, are never logged.

Control endpoints, outside the API: POST /__reset restores the initial state
and empties the log, GET /__log returns the log, POST /__fail makes the next
request matching {"method", "path"} answer {"status", "code", "message"},
or, given {"location"} instead, answer {"status"} with that Location header,
or, given {"raw"}, write those bytes as the whole answer. POST /__pages
{"total_pages"} makes every list claim that many pages until the next reset.

    server.py <state.json> <port file>   binds 127.0.0.1 on a free port
"""

import copy
import json
import os
import socketserver
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PREFIX = "/client/v4"
PROXIABLE = ("A", "AAAA", "CNAME")
PHASES = ("http_request_firewall_custom", "http_ratelimit", "http_request_firewall_managed")
DEFAULT_SETTINGS = {
    "ssl": "full", "min_tls_version": "1.2", "tls_1_3": "on", "always_use_https": "off",
    "security_level": "medium", "browser_check": "on", "challenge_ttl": 1800,
    "automatic_https_rewrites": "on",
}


class State:
    def __init__(self, initial):
        self.initial = initial
        self.reset()

    def reset(self):
        data = copy.deepcopy(self.initial)
        self.page_size = data.get("page_size", 50)
        self.tokens = data["tokens"]
        self.zones = data["zones"]
        self.records = {}
        self.settings = {}
        self.rulesets = {}
        self.ip_rules = {}
        self.universal = {}
        self.packs = {}
        self.bot = {}
        for zone in self.zones:
            for rec in zone.pop("records", []):
                self.add_record(zone, rec)
            zid = zone["id"]
            self.settings[zid] = dict(DEFAULT_SETTINGS, **zone.pop("settings", {}))
            self.rulesets[zid] = {}
            for phase, rules in zone.pop("rulesets", {}).items():
                self.put_ruleset(zid, phase, rules)
            self.ip_rules[zid] = {}
            for rule in zone.pop("ip_rules", []):
                self.add_ip_rule(zid, rule)
            self.universal[zid] = {"enabled": True, **zone.pop("universal_ssl", {})}
            self.packs[zid] = zone.pop("cert_packs", [])
            self.bot[zid] = {"fight_mode": False, "enable_js": True, **zone.pop("bot", {})}
        self.log = []
        self.fail = []
        self.total_pages = None

    def put_ruleset(self, zid, phase, rules):
        old = self.rulesets[zid].get(phase)
        stored = []
        for rule in rules:
            rule = dict(rule)
            rule.setdefault("id", uuid.uuid4().hex)
            rule.setdefault("enabled", True)
            rule["version"] = "1"
            rule["last_updated"] = "2026-01-01T00:00:00Z"
            stored.append(rule)
        self.rulesets[zid][phase] = {
            "id": old["id"] if old else uuid.uuid4().hex, "name": "default", "kind": "zone",
            "phase": phase, "version": "1", "rules": stored}
        return self.rulesets[zid][phase]

    def add_ip_rule(self, zid, rule):
        rule = dict(rule)
        rule.setdefault("id", uuid.uuid4().hex)
        rule.setdefault("notes", "")
        rule["created_on"] = "2026-01-01T00:00:00Z"
        self.ip_rules[zid][rule["id"]] = rule
        return rule

    def add_record(self, zone, rec):
        rec = dict(rec)
        rec.setdefault("id", uuid.uuid4().hex)
        rec.setdefault("ttl", 1)
        rec.setdefault("proxied", False)
        rec["zone_id"] = zone["id"]
        rec["zone_name"] = zone["name"]
        rec["proxiable"] = rec["type"] in PROXIABLE
        self.records[rec["id"]] = rec
        return rec


def envelope(result, info=None):
    body = {"success": True, "errors": [], "messages": [], "result": result}
    if info is not None:
        body["result_info"] = info
    return body


def failure(code, message):
    return {"success": False, "errors": [{"code": code, "message": message}], "messages": [], "result": None}


class Handler(BaseHTTPRequestHandler):
    server_version = "fixture"

    def log_message(self, *args):
        pass

    def _send(self, status, body, text=False):
        raw = body.encode() if text else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain" if text else "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _redirect(self, status, location):
        self.send_response(status)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return None
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except ValueError:
            return {"__unparsed": raw.decode(errors="replace")}

    def _handle(self, method):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        body = self._body()
        state = self.server.state

        if url.path == "/__reset":
            state.reset()
            return self._send(200, {"ok": True})
        if url.path == "/__log":
            return self._send(200, state.log)
        if url.path == "/__fail":
            state.fail.append(body)
            return self._send(200, {"ok": True})
        if url.path == "/__pages":
            state.total_pages = body["total_pages"]
            return self._send(200, {"ok": True})

        state.log.append({"method": method, "path": url.path, "query": query, "body": body})
        for i, rule in enumerate(state.fail):
            if rule["method"] == method and url.path.endswith(rule["path"]):
                state.fail.pop(i)
                if rule.get("raw"):
                    self.close_connection = True
                    return self.wfile.write(rule["raw"].encode())
                if rule.get("location"):
                    return self._redirect(rule["status"], rule["location"])
                return self._send(rule["status"], failure(rule["code"], rule["message"]))

        auth = self.headers.get("Authorization", "")
        token = auth[len("Bearer "):] if auth.startswith("Bearer ") else ""
        who = state.tokens.get(token)
        if who is None:
            return self._send(401, failure(10000, "Authentication error"))
        if not url.path.startswith(PREFIX):
            return self._send(404, failure(7003, "No route for that URI"))
        parts = [p for p in url.path[len(PREFIX):].split("/") if p]
        try:
            status, result = self.route(state, who, method, parts, query, body)
        except Problem as exc:
            return self._send(exc.status, failure(exc.code, exc.message))
        if isinstance(result, str):
            return self._send(status, result, text=True)
        return self._send(status, result)

    def route(self, state, who, method, parts, query, body):
        if parts == ["user", "tokens", "verify"] and method == "GET":
            return 200, envelope({"id": who["token_id"], "status": "active", "expires_on": who.get("expires_on")})
        if parts == ["accounts"] and method == "GET":
            return 200, page(state, [{"id": a, "name": a + " account"} for a in who["accounts"]], query)
        if len(parts) == 4 and parts[0] == "accounts" and parts[2:] == ["tokens", "verify"]:
            if parts[1] not in who["accounts"]:
                raise Problem(403, 9109, "Unauthorized to access requested resource")
            return 200, envelope({"id": who["token_id"], "status": "active"})
        if parts == ["zones"] and method == "GET":
            zones = [z for z in state.zones if z["account"]["id"] in who["accounts"]]
            if "name" in query:
                zones = [z for z in zones if z["name"] == query["name"]]
            if "account.id" in query:
                zones = [z for z in zones if z["account"]["id"] == query["account.id"]]
            return 200, page(state, zones, query)
        if len(parts) >= 2 and parts[0] == "zones":
            zone = next((z for z in state.zones if z["id"] == parts[1]), None)
            if zone is None or zone["account"]["id"] not in who["accounts"]:
                raise Problem(404, 1001, "Invalid zone identifier")
            return self.zone_route(state, zone, method, parts[2:], query, body)
        raise Problem(404, 7003, "No route for that URI")

    def zone_route(self, state, zone, method, parts, query, body):
        if parts == [] and method == "GET":
            return 200, envelope(zone)
        zid = zone["id"]
        if parts == ["settings"] and method == "GET":
            return 200, envelope([self.setting(k, v) for k, v in sorted(state.settings[zid].items())])
        if len(parts) == 2 and parts[0] == "settings":
            if parts[1] not in state.settings[zid]:
                raise Problem(400, 1142, "Unknown setting %s" % parts[1])
            if method == "PATCH":
                if not isinstance(body, dict) or "value" not in body:
                    raise Problem(400, 1007, "Invalid value for zone setting %s" % parts[1])
                state.settings[zid][parts[1]] = body["value"]
            return 200, envelope(self.setting(parts[1], state.settings[zid][parts[1]]))
        if parts == ["ssl", "universal", "settings"]:
            if method == "PATCH":
                if not isinstance(body, dict) or not isinstance(body.get("enabled"), bool):
                    raise Problem(400, 1007, "Invalid enabled")
                state.universal[zid]["enabled"] = body["enabled"]
            return 200, envelope(state.universal[zid])
        if parts == ["ssl", "certificate_packs"] and method == "GET":
            return 200, page(state, state.packs[zid], query)
        if parts == ["bot_management"]:
            if method == "PUT":
                if not isinstance(body, dict):
                    raise Problem(400, 1007, "Invalid body")
                state.bot[zid].update(body)
            return 200, envelope(state.bot[zid])
        if len(parts) == 4 and parts[:2] == ["rulesets", "phases"] and parts[3] == "entrypoint":
            return self.entrypoint(state, zid, parts[2], method, body)
        if parts[:3] == ["firewall", "access_rules", "rules"]:
            return self.access_rules(state, zid, method, parts[3:], query, body)
        if parts == ["dns_records", "export"] and method == "GET":
            lines = [";; fixture export of " + zone["name"]]
            for rec in self.zone_records(state, zone):
                ttl = rec["ttl"] if rec["ttl"] != 1 else 300
                lines.append("%s.\t%s\tIN\t%s\t%s" % (rec["name"], ttl, rec["type"], rec["content"]))
            return 200, "\n".join(lines) + "\n"
        if parts == ["dns_records"] and method == "GET":
            records = self.zone_records(state, zone)
            if "name" in query:
                records = [r for r in records if r["name"] == query["name"]]
            if "type" in query:
                records = [r for r in records if r["type"] == query["type"]]
            return 200, page(state, records, query)
        if parts == ["dns_records"] and method == "POST":
            rec = self.checked(state, zone, body, None)
            return 200, envelope(state.add_record(zone, rec))
        if len(parts) == 2 and parts[0] == "dns_records":
            rec = state.records.get(parts[1])
            if rec is None or rec["zone_id"] != zone["id"]:
                raise Problem(404, 81044, "Record does not exist.")
            if method == "GET":
                return 200, envelope(rec)
            if method == "DELETE":
                del state.records[rec["id"]]
                return 200, envelope({"id": rec["id"]})
            if method in ("PUT", "PATCH"):
                merged = dict(body or {}) if method == "PUT" else dict(rec, **(body or {}))
                new = self.checked(state, zone, merged, rec["id"])
                del state.records[rec["id"]]
                new["id"] = rec["id"]
                return 200, envelope(state.add_record(zone, new))
        raise Problem(404, 7003, "No route for that URI")

    def setting(self, key, value):
        return {"id": key, "value": value, "editable": True, "modified_on": "2026-01-01T00:00:00Z"}

    def entrypoint(self, state, zid, phase, method, body):
        if phase not in PHASES:
            raise Problem(400, 20012, "Unknown phase %s" % phase)
        current = state.rulesets[zid].get(phase)
        if method == "GET":
            if current is None:
                raise Problem(404, 10003, "could not find entrypoint ruleset in phase %s" % phase)
            return 200, envelope(current)
        if method == "PUT":
            rules = (body or {}).get("rules")
            if not isinstance(rules, list):
                raise Problem(400, 20012, "rules must be a list")
            for rule in rules:
                if "version" in rule or "last_updated" in rule:
                    raise Problem(400, 20012, "read-only field in rule")
                if not rule.get("expression") or not rule.get("action"):
                    raise Problem(400, 20012, "rule needs an expression and an action")
            return 200, envelope(state.put_ruleset(zid, phase, rules))
        raise Problem(405, 7003, "Method not allowed")

    def access_rules(self, state, zid, method, parts, query, body):
        rules = state.ip_rules[zid]
        if parts == [] and method == "GET":
            found = sorted(rules.values(), key=lambda r: r["created_on"] + r["id"])
            if "mode" in query:
                found = [r for r in found if r["mode"] == query["mode"]]
            if "configuration.value" in query:
                found = [r for r in found if r["configuration"]["value"] == query["configuration.value"]]
            return 200, page(state, found, query)
        if parts == [] and method == "POST":
            conf = (body or {}).get("configuration") or {}
            if (body or {}).get("mode") not in ("block", "challenge", "whitelist", "js_challenge", "managed_challenge") \
                    or not conf.get("target") or not conf.get("value"):
                raise Problem(400, 10001, "Invalid access rule")
            if any(r["configuration"] == conf for r in rules.values()):
                raise Problem(400, 10009, "firewallaccessrules.api.duplicate_of_existing")
            return 200, envelope(state.add_ip_rule(zid, body))
        if len(parts) == 1:
            rule = rules.get(parts[0])
            if rule is None:
                raise Problem(404, 10001, "access rule not found")
            if method == "DELETE":
                del rules[rule["id"]]
                return 200, envelope({"id": rule["id"]})
            if method == "PATCH":
                rule.update({k: v for k, v in (body or {}).items() if k in ("mode", "notes")})
                return 200, envelope(rule)
        raise Problem(404, 7003, "No route for that URI")

    def zone_records(self, state, zone):
        return sorted(
            (r for r in state.records.values() if r["zone_id"] == zone["id"]),
            key=lambda r: (r["name"], r["type"], r["content"]),
        )

    def checked(self, state, zone, body, own_id):
        if not isinstance(body, dict):
            raise Problem(400, 9207, "Request body is invalid.")
        for key in ("type", "name", "content"):
            if not body.get(key):
                raise Problem(400, 9005, "DNS record %s is required" % key)
        rec = {k: v for k, v in body.items() if k not in ("id", "zone_id", "zone_name", "proxiable")}
        if not rec["name"].endswith(zone["name"]):
            rec["name"] = rec["name"] + "." + zone["name"]
        if rec.get("proxied") and rec["type"] not in PROXIABLE:
            raise Problem(400, 9004, "This record type cannot be proxied.")
        same = [r for r in self.zone_records(state, zone) if r["name"] == rec["name"] and r["id"] != own_id]
        if same and (rec["type"] == "CNAME" or any(r["type"] == "CNAME" for r in same)):
            raise Problem(400, 81053, "An A, AAAA, or CNAME record with that host already exists.")
        return rec


class Problem(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def page(state, items, query):
    per_page = min(int(query.get("per_page", state.page_size)), state.page_size)
    number = int(query.get("page", 1))
    total_pages = state.total_pages or max(1, -(-len(items) // per_page))
    chunk = items[(number - 1) * per_page:number * per_page]
    info = {"page": number, "per_page": per_page, "count": len(chunk),
            "total_count": len(items), "total_pages": total_pages}
    return envelope(chunk, info)


for _method in ("GET", "POST", "PUT", "PATCH", "DELETE"):
    setattr(Handler, "do_" + _method, (lambda m: lambda self: self._handle(m))(_method))


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind looks the host up by reverse DNS, which can
        # hang on a machine whose resolver is slow: the name is never used.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def main(argv):
    with open(argv[0], encoding="utf-8") as fh:
        initial = json.load(fh)
    server = Server(("127.0.0.1", 0), Handler)
    server.state = State(initial)
    with open(argv[1] + ".tmp", "w") as fh:
        fh.write(str(server.server_address[1]))
    # Renamed into place so the suite never reads a half-written port.
    os.replace(argv[1] + ".tmp", argv[1])
    server.serve_forever()


if __name__ == "__main__":
    main(sys.argv[1:])
