#!/usr/bin/env python3
"""A stand-in for the public resolver (1.1.1.1), for tests/run-tests.sh.

A UDP DNS server on 127.0.0.1 that reads <names.json> on every query,
{host: [addresses]}, and answers an A query with the host's IPv4 addresses
and an AAAA query with its IPv6 ones (NOERROR with no answer when it has none
of that kind), NXDOMAIN for a name it does not list. In place of the
addresses, a host may be listed with:

- "servfail" or "refused": that answer code;
- "empty": NOERROR with no answer, to either query;
- "wrong-id": an answer under another query id;
- "truncated": an answer cut in the middle of its record;
- {"delay": seconds, "addresses": [...]}: the answer, that much later.

Each query is answered in a thread of its own, so a delayed one holds no
other back. Each query's name is appended to <names.json>.log, one per line,
followed by "/AAAA" for an AAAA query.

    resolver.py <names.json> <port file>   the port file receives the port
"""

import json
import os
import socket
import struct
import sys
import threading
import time

_A, _AAAA = 1, 28
_RCODES = {"servfail": 2, "refused": 5}
_LOCK = threading.Lock()


def question(packet):
    """(name, type, the question's bytes) of a query."""
    labels, i = [], 12
    while packet[i]:
        size = packet[i]
        labels.append(packet[i + 1:i + 1 + size].decode("ascii").lower())
        i += 1 + size
    rtype = struct.unpack(">H", packet[i + 1:i + 3])[0]
    return ".".join(labels), rtype, packet[12:i + 5]


def answer(packet, names):
    query_id = packet[:2]
    name, rtype, asked = question(packet)
    with open(names, encoding="utf-8") as fh:
        found = json.load(fh).get(name)
    with _LOCK, open(names + ".log", "a", encoding="utf-8") as fh:
        fh.write(name + ("/AAAA" if rtype == _AAAA else "") + "\n")
    if isinstance(found, dict):
        time.sleep(found.get("delay", 0))
        found = found.get("addresses", [])
    if isinstance(found, str) and found in _RCODES:
        return query_id + struct.pack(">HHHHH", 0x8180 | _RCODES[found], 1, 0, 0, 0) + asked
    if found is None:
        return query_id + struct.pack(">HHHHH", 0x8183, 1, 0, 0, 0) + asked
    if found == "empty":
        return query_id + struct.pack(">HHHHH", 0x8180, 1, 0, 0, 0) + asked
    if found in ("wrong-id", "truncated"):
        record = struct.pack(">HHHIH", 0xC00C, _A, 1, 300, 4) + socket.inet_aton("127.0.0.1")
        whole = struct.pack(">HHHHH", 0x8180, 1, 1, 0, 0) + asked + record
        if found == "wrong-id":
            return bytes([query_id[0] ^ 0xFF, query_id[1]]) + whole
        return query_id + whole[:-6]
    family, size = (socket.AF_INET6, 16) if rtype == _AAAA else (socket.AF_INET, 4)
    kept = [ip for ip in found if (":" in ip) == (rtype == _AAAA)]
    records = b"".join(struct.pack(">HHHIH", 0xC00C, rtype, 1, 300, size) + socket.inet_pton(family, ip)
                       for ip in kept)
    return query_id + struct.pack(">HHHHH", 0x8180, 1, len(kept), 0, 0) + asked + records


def reply(sock, packet, peer, names):
    try:
        sock.sendto(answer(packet, names), peer)
    except (IndexError, ValueError, OSError, struct.error):
        pass


def main(names, port_file):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    with open(port_file + ".tmp", "w", encoding="utf-8") as fh:
        fh.write(str(sock.getsockname()[1]))
    os.replace(port_file + ".tmp", port_file)
    while True:
        packet, peer = sock.recvfrom(512)
        threading.Thread(target=reply, args=(sock, packet, peer, names), daemon=True).start()


if __name__ == "__main__":
    main(*sys.argv[1:3])
