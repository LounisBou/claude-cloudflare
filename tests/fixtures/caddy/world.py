#!/usr/bin/env python3
"""What a running Caddy looks like from outside, for tests/run-tests.sh.

Two listeners on 127.0.0.1: a TLS one standing for :443, and an HTTP one
standing for the admin API. Both read <state dir>/world.json on every
connection, {"alive": bool, "sites": {host: status}}, which fake-caddy.py
rewrites on each reload:

- TLS: a handshake whose SNI is a host of "sites" completes and the request
  is answered with that host's status (0: the connection closes with no
  answer); any other name, or a world that is not alive, fails the handshake.
- admin: GET /config/ answers 200 (or the world's "admin_status") while the
  world is alive, 503 otherwise.

    world.py <state dir> <cert.pem> <key.pem> <port file>
    the port file receives "<tls port> <admin port>"
"""

import json
import os
import socketserver
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def world(state):
    with open(os.path.join(state, "world.json"), encoding="utf-8") as fh:
        return json.load(fh)


def main(state, cert, key, port_file):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)

    def by_name(sock, name, _context):
        now = world(state)
        if not now.get("alive") or name not in now.get("sites", {}):
            return ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME
        sock.fake_status = now["sites"][name]
        return None

    context.sni_callback = by_name

    class Site(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                tls = context.wrap_socket(self.request, server_side=True)
            except (ssl.SSLError, OSError):
                return
            try:
                reader = tls.makefile("rb")
                while reader.readline(4096) not in (b"\r\n", b"\n", b""):
                    pass
                status = getattr(tls, "fake_status", 200)
                if status == 0:
                    return
                tls.sendall(("HTTP/1.1 %d Fake\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" % status).encode())
            except (ssl.SSLError, OSError):
                pass
            finally:
                tls.close()

    class Admin(BaseHTTPRequestHandler):
        def do_GET(self):
            now = world(state)
            alive = now.get("alive") and self.path == "/config/"
            self.send_response(now.get("admin_status", 200) if alive else 503)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

        def log_message(self, *args):
            pass

    socketserver.ThreadingTCPServer.allow_reuse_address = True
    sites = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Site)
    sites.daemon_threads = True
    admin = ThreadingHTTPServer(("127.0.0.1", 0), Admin)
    admin.daemon_threads = True
    threading.Thread(target=sites.serve_forever, daemon=True).start()
    with open(port_file + ".tmp", "w", encoding="utf-8") as fh:
        fh.write("%d %d\n" % (sites.server_address[1], admin.server_address[1]))
    os.replace(port_file + ".tmp", port_file)
    admin.serve_forever()


if __name__ == "__main__":
    main(*sys.argv[1:5])
