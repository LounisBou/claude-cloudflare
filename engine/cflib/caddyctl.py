"""The local Caddy as the config's caddy section describes it: its files, the
caddy binary run with the envfile's variables, its admin API and the probe of
its sites.

The envfile's variables reach caddy through the environment of the child
process, never its argument vector. With "sudo": true every caddy call is
prefixed with sudo -n, which keeps those variables by name
(--preserve-env=NAMES): a password prompt fails instead of waiting. Nothing
here stops, starts or restarts the service: caddy is only validated and
reloaded.
"""

import concurrent.futures
import datetime
import os
import plistlib
import re
import socket
import ssl
import subprocess
import urllib.error
import urllib.request

from . import creds, errors

MANAGERS = ("launchd", "systemd")
DEFAULT_ADMIN = "localhost:2019"
# Where the sites are probed: Caddy's HTTPS port on this machine.
# CF_CADDY_PROBE overrides it, which is how the suite points it at a fake.
PROBE = "127.0.0.1:443"
PROBE_TIMEOUT = 5
CALL_TIMEOUT = 60
# An envfile value shorter than this is no secret worth masking ("1", "info").
SECRET_MIN = 8
_STAMP = "%Y%m%dT%H%M%S.%fZ"
_STATUS = re.compile(rb"^HTTP/\d(?:\.\d)? (\d{3})")
DOWN = None


class Settings:
    """The caddy section of the config, checked: types, the manager, and an
    admin endpoint this engine can reach."""

    def __init__(self, cfg):
        data = cfg.caddy
        if not data:
            raise errors.ConfigError("no caddy section in %s: the Caddy commands need one" % cfg.path)

        def value(key, kind=str, default=None):
            got = data.get(key)
            if got is None:
                return default
            if not isinstance(got, kind):
                raise errors.ConfigError("%s: caddy.%s must be a %s" % (cfg.path, key, kind.__name__))
            return got

        def path(key, default=None):
            got = value(key, default=default)
            return os.path.expanduser(got) if got else got

        self.manager = value("manager")
        if self.manager is not None and self.manager not in MANAGERS:
            raise errors.ConfigError("%s: caddy.manager must be %s" % (cfg.path, " or ".join(MANAGERS)))
        self.binary = path("binary", "caddy")
        self.caddyfile = path("caddyfile")
        if not self.caddyfile:
            raise errors.ConfigError("%s: caddy.caddyfile is not set" % cfg.path)
        self.envfile = path("envfile")
        self.service = path("service")
        self.tls_snippet = value("tls_snippet")
        self.sudo = value("sudo", bool, False)
        self.admin = value("admin", default=DEFAULT_ADMIN)
        if "/" in self.admin:
            raise errors.ConfigError("%s: caddy.admin must be host:port; an admin API on a unix socket "
                                     "is not supported" % cfg.path)

    # ---- the Caddyfile ----

    def read(self):
        try:
            with open(self.caddyfile, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            raise errors.ConfigError("cannot read %s: %s" % (self.caddyfile, exc.strerror))
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            raise errors.ConfigError("%s is not UTF-8 text" % self.caddyfile)

    def write(self, text):
        """In place: the file keeps its inode, owner and mode, and a symlink
        keeps pointing where it did."""
        with open(self.caddyfile, "wb") as fh:
            fh.write(text.encode("utf-8"))

    def copy(self, text):
        """<caddyfile>.bak-<UTC timestamp>, private, never over an older one."""
        taken = datetime.datetime.now(datetime.timezone.utc)
        try:
            while True:
                path = "%s.bak-%s" % (self.caddyfile, taken.strftime(_STAMP))
                try:
                    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    break
                except FileExistsError:
                    taken += datetime.timedelta(microseconds=1)
            with os.fdopen(fd, "wb") as fh:
                fh.write(text.encode("utf-8"))
        except OSError as exc:
            raise errors.ConfigError("cannot copy %s before the edit: %s; nothing was changed"
                                     % (self.caddyfile, exc.strerror))
        return path

    # ---- the envfile ----

    def variables(self):
        """The envfile's KEY=value pairs; {} without an envfile. One that is
        set but cannot be read stops the command before anything changes."""
        if not self.envfile:
            return {}
        try:
            with open(self.envfile, "rb"):
                pass
        except OSError as exc:
            raise errors.ConfigError("cannot read the envfile %s: %s; nothing was changed"
                                     % (self.envfile, exc.strerror))
        return creds.read_env_file(self.envfile)

    # ---- caddy ----

    def call(self, args, variables):
        """(ok, its output, or the line that says why not) for one caddy run."""
        argv = [self.binary] + args
        if self.sudo:
            keep = ["--preserve-env=" + ",".join(sorted(variables))] if variables else []
            argv = ["sudo", "-n"] + keep + argv
        env = dict(os.environ)
        env.update(variables)
        try:
            done = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=CALL_TIMEOUT)
        except OSError as exc:
            # A failure like any other: after an edit, the cycle puts the copy back.
            return False, "cannot run %s: %s" % (argv[0], exc.strerror)
        except subprocess.TimeoutExpired:
            return False, "caddy %s did not end within %d seconds" % (args[0], CALL_TIMEOUT)
        if done.returncode == 0:
            return True, done.stdout.decode("utf-8", "replace").strip()
        return False, error_line(done.stderr.decode("utf-8", "replace") + "\n"
                                 + done.stdout.decode("utf-8", "replace"), args[0], done.returncode)

    def validate(self, variables):
        return self.call(["validate", "--config", self.caddyfile, "--adapter", "caddyfile"], variables)

    def reload(self, variables):
        return self.call(["reload", "--config", self.caddyfile, "--adapter", "caddyfile"], variables)

    def alive(self):
        """Whether the admin API answers GET /config/ with 200. The answer,
        which may hold secrets, is read and dropped."""
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open("http://%s/config/" % self.admin, timeout=PROBE_TIMEOUT) as resp:
                resp.read()
                return resp.status == 200
        except (urllib.error.URLError, OSError, ValueError):
            return False


def error_line(output, command, code):
    """Caddy's own reason: its last "Error:" line, else its last line."""
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    errs = [line for line in lines if line.startswith("Error:")]
    line = (errs or lines or ["caddy %s exited %d" % (command, code)])[-1]
    return line if len(line) <= 400 else line[:399] + "…"


def secrets(cfg):
    """The envfile's values, to keep them out of any output. Never fails: an
    unreadable envfile or a malformed section has nothing to mask."""
    envfile = cfg.caddy.get("envfile") if isinstance(cfg.caddy, dict) else None
    if not isinstance(envfile, str):
        return set()
    return {v for v in creds.read_env_file(envfile).values() if len(v) >= SECRET_MIN}


# ---- the probe ----

def _probe_address():
    host, _, port = (os.environ.get("CF_CADDY_PROBE") or PROBE).rpartition(":")
    return host, int(port)


def probe_one(host, address):
    """The HTTP status the site answers at the address with SNI = host, or
    DOWN when the connection or the TLS handshake fails, or no HTTP answer
    comes. The certificate is not checked: the probe is about the reload."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["http/1.1"])
    request = "HEAD / HTTP/1.1\r\nHost: %s\r\nUser-Agent: claude-cloudflare\r\nConnection: close\r\n\r\n" % host
    try:
        with socket.create_connection(address, timeout=PROBE_TIMEOUT) as raw:
            with context.wrap_socket(raw, server_hostname=host) as tls:
                tls.sendall(request.encode("ascii"))
                first = tls.makefile("rb").readline(256)
    except (OSError, ssl.SSLError, ValueError):
        return DOWN
    match = _STATUS.match(first)
    return int(match.group(1)) if match else DOWN


def probe(hosts):
    """{host: status or DOWN} for every host, probed side by side."""
    address = _probe_address()
    if not hosts:
        return {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(hosts))) as pool:
        return dict(zip(hosts, pool.map(lambda h: probe_one(h, address), hosts)))


# ---- the service ----

def _same(a, b):
    return os.path.realpath(os.path.expanduser(a)) == os.path.realpath(os.path.expanduser(b))


def _launchd_envfile(path):
    with open(path, "rb") as fh:
        args = plistlib.load(fh).get("ProgramArguments") or []
    for k, arg in enumerate(args):
        if arg == "--envfile" and k + 1 < len(args):
            yield args[k + 1]
        elif isinstance(arg, str) and arg.startswith("--envfile="):
            yield arg[len("--envfile="):]


def _systemd_envfile(path):
    """EnvironmentFile= of the unit and of its drop-ins beside it (<unit>.d/*.conf)."""
    files = [path]
    dropins = path + ".d"
    if os.path.isdir(dropins):
        files += [os.path.join(dropins, n) for n in sorted(os.listdir(dropins)) if n.endswith(".conf")]
    for name in files:
        with open(name, encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.strip().partition("=")
                if sep and key.strip() == "EnvironmentFile":
                    yield value.strip().lstrip("-")


def service(settings):
    """(state, detail, warning or None): does the service start caddy with the envfile?"""
    if not settings.manager:
        return "-", "no manager in the config", None
    if not settings.service:
        return "unknown", settings.manager, "caddy.service is not set: the service's envfile cannot be checked"
    if not settings.envfile:
        return "-", "%s %s: no envfile in the config" % (settings.manager, settings.service), None
    reader = _launchd_envfile if settings.manager == "launchd" else _systemd_envfile
    try:
        found = list(reader(settings.service))
    except (OSError, UnicodeDecodeError, plistlib.InvalidFileException, ValueError) as exc:
        reason = getattr(exc, "strerror", None) or str(exc)
        return "unreadable", "%s %s: %s" % (settings.manager, settings.service, reason), \
            "cannot read %s: %s" % (settings.service, reason)
    if any(_same(f, settings.envfile) for f in found):
        flag = "--envfile " if settings.manager == "launchd" else "EnvironmentFile="
        return "ok", "%s %s: %s%s" % (settings.manager, settings.service, flag, settings.envfile), None
    if settings.manager == "launchd":
        why = "%s does not start caddy with --envfile %s" % (settings.service, settings.envfile)
    else:
        why = "%s has no EnvironmentFile=%s" % (settings.service, settings.envfile)
    return "no-envfile", "%s %s" % (settings.manager, settings.service), \
        why + ": a restart of the service would run caddy without its variables"
