"""A host as the public sees it: its name resolved through a public resolver,
then an HTTPS request to the address it resolves to, the certificate checked
as a browser would.

The resolver is 1.1.1.1, asked directly over UDP so that neither this
machine's resolver nor its hosts file has a say; CF_RESOLVER overrides it and
CF_CHECK_PORT the HTTPS port, which is how the suite points both at fakes.
The trusted authorities are the system's (SSL_CERT_FILE is honoured).
"""

import concurrent.futures
import os
import socket
import ssl
import struct
import time

from . import caddyfile, errors, fmt

RESOLVER = "1.1.1.1:53"
HTTPS_PORT = 443
RESOLVE_TIMEOUT = 3
HTTPS_TIMEOUT = 5
# The time the checks of an inventory have in all, counted from its start:
# under the tool's 120 seconds, with room for the reads before the checks.
# CF_CHECK_DEADLINE overrides it, which is how the suite shortens it.
DEADLINE = 90
NOT_IN_TIME = "not checked (time)"
COLUMNS = ["host", "address", "https", "issuer", "expires"]
_RCODES = {1: "formerr", 2: "servfail", 3: "nxdomain", 5: "refused"}
_A, _AAAA, _IN = 1, 28, 1
# The address family and size of each record type asked for.
_FAMILIES = {_A: (socket.AF_INET, 4), _AAAA: (socket.AF_INET6, 16)}


def _resolver():
    host, _, port = (os.environ.get("CF_RESOLVER") or RESOLVER).rpartition(":")
    return host, int(port)


def _https_port():
    return int(os.environ.get("CF_CHECK_PORT") or HTTPS_PORT)


def deadline():
    """The moment, on the monotonic clock, past which no check goes on."""
    return time.monotonic() + float(os.environ.get("CF_CHECK_DEADLINE") or DEADLINE)


def _within(timeout, until):
    """A step's timeout, cut to what is left before the deadline (None: no
    deadline); socket.timeout when nothing is left."""
    if until is None:
        return timeout
    left = until - time.monotonic()
    if left <= 0:
        raise socket.timeout("past the deadline")
    return min(timeout, left)


# ---- resolution ----

def _query(host, rtype):
    """(id, packet) of a query; ValueError for a name DNS cannot carry: not
    ASCII, an empty label or one over 63 characters."""
    labels = [label.encode("ascii") for label in host.split(".")]
    if len(host) > 253 or any(not 0 < len(label) < 64 for label in labels):
        raise ValueError(host)
    query_id = os.urandom(2)
    name = b"".join(bytes([len(label)]) + label for label in labels) + b"\0"
    return query_id, query_id + struct.pack(">HHHHH", 0x0100, 1, 0, 0, 0) + name + struct.pack(">HH", rtype, _IN)


def _skip_name(packet, i):
    """The offset past a name, compressed or not."""
    while True:
        size = packet[i]
        if size & 0xC0 == 0xC0:
            return i + 2
        if size == 0:
            return i + 1
        i += 1 + size


def _addresses(packet, query_id, rtype):
    """(addresses, problem): the records of the type asked for in an answer,
    or why there are none. IndexError for an answer cut short."""
    if len(packet) < 12 or packet[:2] != query_id:
        return [], "bad answer"
    flags, questions, answers = struct.unpack(">HHH", packet[2:8])
    rcode = flags & 0x000F
    if rcode:
        return [], _RCODES.get(rcode, "rcode %d" % rcode)
    family, length = _FAMILIES[rtype]
    i = 12
    for _ in range(questions):
        i = _skip_name(packet, i) + 4
    found = []
    for _ in range(answers):
        i = _skip_name(packet, i)
        kind, rclass, _ttl, size = struct.unpack(">HHIH", packet[i:i + 10])
        i += 10
        if i + size > len(packet):
            raise IndexError("answer cut short")
        if kind == rtype and rclass == _IN and size == length:
            found.append(socket.inet_ntop(family, packet[i:i + size]))
        i += size
    return found, None if found else "no answer"


def _ask(host, rtype, until=None):
    query_id, query = _query(host, rtype)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(_within(RESOLVE_TIMEOUT, until))
            sock.connect(_resolver())
            sock.send(query)
            packet = sock.recv(4096)
    except socket.timeout:
        return [], "resolver timeout"
    except OSError:
        return [], "no resolver"
    try:
        return _addresses(packet, query_id, rtype)
    except (IndexError, struct.error):
        return [], "bad answer"


def resolve(host, until=None):
    """(addresses, problem): the host's IPv4 addresses as the public resolver
    gives them, its IPv6 ones when it has no IPv4, or the reason it gives none."""
    try:
        addresses, problem = _ask(host, _A, until)
    except ValueError:
        return [], "bad name"
    if problem == "no answer":
        found, _ = _ask(host, _AAAA, until)
        if found:
            return found, None
    return addresses, problem


# ---- HTTPS ----

def _issuer(cert):
    fields = dict(pair for rdn in cert.get("issuer", ()) for pair in rdn)
    org, name = fields.get("organizationName"), fields.get("commonName")
    if org and name:
        return "%s (%s)" % (org, name)
    return org or name


def _expires(cert):
    if not cert.get("notAfter"):
        return None
    return time.strftime("%Y-%m-%d", time.gmtime(ssl.cert_time_to_seconds(cert["notAfter"])))


def https(host, address, until=None):
    """{"https", "issuer", "expires"} of a GET / to the address with SNI and
    Host = host: the HTTP status, or down (connect, tls, timeout, http), or
    untrusted (the reason) for a certificate that does not verify. Each step
    ends by the deadline until, when there is one."""
    context = ssl.create_default_context()
    context.set_alpn_protocols(["http/1.1"])
    request = "GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: claude-cloudflare\r\nConnection: close\r\n\r\n" % host
    out = {"https": None, "issuer": None, "expires": None}
    try:
        raw = socket.create_connection((address, _https_port()), timeout=_within(HTTPS_TIMEOUT, until))
    except socket.timeout:
        return dict(out, https="down (timeout)")
    except OSError:
        return dict(out, https="down (connect)")
    with raw:
        try:
            raw.settimeout(_within(HTTPS_TIMEOUT, until))
            tls = context.wrap_socket(raw, server_hostname=host)
        except ssl.SSLCertVerificationError as exc:
            return dict(out, https="untrusted (%s)" % (exc.verify_message or exc.reason))
        except socket.timeout:
            return dict(out, https="down (timeout)")
        except (ssl.SSLError, OSError):
            return dict(out, https="down (tls)")
        with tls:
            cert = tls.getpeercert() or {}
            out.update(issuer=_issuer(cert), expires=_expires(cert))
            try:
                tls.settimeout(_within(HTTPS_TIMEOUT, until))
                tls.sendall(request.encode("ascii"))
                first = tls.makefile("rb").readline(256)
            except socket.timeout:
                return dict(out, https="down (timeout)")
            except (ssl.SSLError, OSError):
                first = b""
    parts = first.split()
    if len(parts) >= 2 and parts[0].startswith(b"HTTP/") and parts[1].isdigit():
        return dict(out, https=int(parts[1]))
    return dict(out, https="down (http)")


def _not_checked(host, why, https_state=None):
    return {"host": host, "addresses": [], "resolution": why, "https": https_state, "issuer": None, "expires": None}


def one(host, until=None):
    """The whole check of a host: {"host", "addresses", "resolution", "https",
    "issuer", "expires"}; resolution is the problem when nothing resolved.
    A check the deadline until cut short is not checked (time)."""
    addresses, problem = resolve(host, until)
    result = {"host": host, "addresses": addresses, "resolution": problem,
              "https": None, "issuer": None, "expires": None}
    if addresses:
        result.update(https(host, addresses[0], until))
    timed_out = problem == "resolver timeout" or result["https"] == "down (timeout)"
    if until is not None and timed_out and time.monotonic() >= until:
        return _not_checked(host, NOT_IN_TIME, NOT_IN_TIME)
    return result


def run(hosts, until=None):
    """{host: one(host)} for every host, checked side by side, until the
    deadline when there is one: a host whose check has not ended by then is
    not checked (time). A wildcard is no name to resolve: it is skipped."""
    wildcards = [h for h in hosts if h.startswith("*.")]
    named = [h for h in hosts if h not in wildcards]
    out = {h: _not_checked(h, "wildcard: not checked") for h in wildcards}
    if not named:
        return out
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(named)))
    futures = {pool.submit(one, h, until): h for h in named}
    left = None if until is None else max(0, until - time.monotonic())
    done, _ = concurrent.futures.wait(futures, timeout=left)
    # The checks still running end by the deadline too: their steps are cut to it.
    pool.shutdown(wait=True, cancel_futures=True)
    for future, host in futures.items():
        out[host] = future.result() if future in done else _not_checked(host, NOT_IN_TIME, NOT_IN_TIME)
    return out


def row(result):
    return {"host": result["host"], "address": ",".join(result["addresses"]) or result["resolution"],
            "https": result["https"], "issuer": result["issuer"], "expires": result["expires"]}


def host_name(raw):
    host = caddyfile.host_name(raw, wildcard=True)
    if host.startswith("*."):
        raise errors.UsageError("%s is a wildcard: check a name under it" % raw)
    return host


# ---- the command ----

def check(args, ctx):
    result = one(host_name(args.host))
    if args.json:
        return fmt.as_json(result)
    return fmt.table([row(result)], COLUMNS)


def register(subparsers):
    parser = subparsers.add_parser("check", help="a host as the public sees it: resolution, HTTPS, certificate")
    parser.add_argument("host")
    parser.set_defaults(handler=check, read=True, account_free=True)
