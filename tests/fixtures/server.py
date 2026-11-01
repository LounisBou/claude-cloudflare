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
        for zone in self.zones:
            for rec in zone.pop("records", []):
                self.add_record(zone, rec)
        self.log = []
        self.fail = []
        self.total_pages = None

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
