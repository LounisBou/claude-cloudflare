"""The local Caddy as the config's caddy section describes it: its files, the
caddy binary run with the envfile's variables, its admin API and the probe of
its sites.

The envfile's variables reach caddy through the environment of the child
process, never its argument vector. With "sudo": true every caddy call is
prefixed with sudo -n, which keeps those variables by name
(--preserve-env=NAMES): a password prompt fails instead of waiting. The
Caddyfile and its copies go through sudo -n too (cat, tee, cp -p) when the
user cannot read or write them; a refusal of sudo names the rule it needs.
Nothing here stops, starts or restarts the service: caddy is only validated
and reloaded.
"""

import concurrent.futures
import contextlib
import datetime
import errno
import fcntl
import os
import plistlib
import re
import shlex
import signal
import socket
import ssl
import subprocess
import time
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
# A whole cycle (validate, reload, the probes, a rollback) stays within BUDGET
# seconds, under the mod's 120 s for a call. Its steps stop when RESERVE of it
# is left, which the rollback keeps; a rollback step always gets ROLLBACK_MIN.
# CF_CADDY_BUDGET overrides it, which is how the suite tries a short one.
BUDGET = 100
RESERVE = 0.4
ROLLBACK_MIN = 1
# How long a change waits for another one to end, at most.
LOCK_WAIT = 15
# An envfile value shorter than this is no secret worth masking ("1", "info").
SECRET_MIN = 8
_STAMP = "%Y%m%dT%H%M%S.%fZ"
_STATUS = re.compile(rb"^HTTP/\d(?:\.\d)? (\d{3})")
_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# How sudo -n says it will not run a command.
_REFUSAL = re.compile(r"^(?:sudo: |Sorry, user )")
# Names that would change which programs caddy loads, not what it is told.
_UNSAFE = re.compile(r"^(?:PATH|LD_.*|DYLD_.*)$")
DOWN = None
# A site whose TLS handshake completes but which sends no HTTP line in time: it answers.
NO_HTTP = "no-http"


class Deadline:
    """The time a cycle has, from its start."""

    def __init__(self):
        self.budget = float(os.environ.get("CF_CADDY_BUDGET") or BUDGET)
        self.end = time.monotonic() + self.budget
        self.steps_end = self.end - self.budget * RESERVE
        self.rolling_back = False

    def passed(self):
        return time.monotonic() >= self.steps_end

    def timeout(self, default):
        """A step's timeout: its own, cut to what is left."""
        if self.rolling_back:
            return max(ROLLBACK_MIN, min(default, self.end - time.monotonic()))
        return min(default, self.steps_end - time.monotonic())


class SudoRefused(errors.ConfigError):
    """sudo -n would not run a caddy call: nothing ran, nothing was reloaded."""


def _refusal(what, err, keeps):
    """The error for a sudo -n that refused to run what, or None when sudo
    ran it (it failed on its own)."""
    line = next((l.strip() for l in err.splitlines() if _REFUSAL.match(l.strip())), None)
    if line is None:
        return None
    rule = "it needs a sudoers rule with NOPASSWD" + (", and SETENV or env_keep for --preserve-env" if keeps else "")
    return "sudo -n refused %s (%s): %s, as the README's Caddy section shows" % (what, line, rule)


def _run(argv, timeout, env=None, data=None):
    """(exit code, stdout, stderr) of one run, in a session of its own: on a
    timeout (TimeoutExpired) or any exception, everything it started is
    killed with it. OSError when it cannot start."""
    proc = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL if data is None else subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = proc.communicate(data, timeout=max(0, timeout))
    except BaseException:
        _kill(proc)
        raise
    return proc.returncode, out, err


@contextlib.contextmanager
def locked(path, deadline):
    """The lock file held for a whole change: one change at a time. Another
    one holding it is waited for, LOCK_WAIT at most and within the deadline."""
    try:
        os.makedirs(os.path.dirname(path), 0o700, exist_ok=True)
        fh = open(path, "a")
    except OSError as exc:
        raise errors.ConfigError("cannot open the lock %s: %s; nothing was changed" % (path, exc.strerror))
    with fh:
        waited = time.monotonic() + max(0, deadline.timeout(LOCK_WAIT))
        while True:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= waited:
                    raise errors.Refused("another Caddy change is running (it holds %s): try again once it "
                                         "ends; nothing was changed" % path)
                time.sleep(0.1)
        yield


class Settings:
    """The caddy section of the config, checked: types, the manager, and an
    admin endpoint this engine can reach."""

    def __init__(self, config):
        data = config.caddy
        if not data:
            raise errors.ConfigError("no caddy section in %s: the Caddy commands need one" % config.path)

        def value(key, kind=str, default=None):
            got = data.get(key)
            if got is None:
                return default
            if not isinstance(got, kind):
                raise errors.ConfigError("%s: caddy.%s must be a %s" % (config.path, key, kind.__name__))
            return got

        def path(key, default=None):
            got = value(key, default=default)
            return os.path.expanduser(got) if got else got

        self.manager = value("manager")
        if self.manager is not None and self.manager not in MANAGERS:
            raise errors.ConfigError("%s: caddy.manager must be %s" % (config.path, " or ".join(MANAGERS)))
        self.binary = path("binary", "caddy")
        self.caddyfile = path("caddyfile")
        if not self.caddyfile:
            raise errors.ConfigError("%s: caddy.caddyfile is not set" % config.path)
        self.envfile = path("envfile")
        self.service = path("service")
        self.tls_snippet = value("tls_snippet")
        self.sudo = value("sudo", bool, False)
        self.admin = value("admin", default=DEFAULT_ADMIN)
        if "/" in self.admin:
            raise errors.ConfigError("%s: caddy.admin must be host:port; an admin API on a unix socket "
                                     "is not supported" % config.path)
        # Set by a cycle: every call and probe is then cut to the time it has left.
        self.deadline = None

    def timeout(self, default):
        return self.deadline.timeout(default) if self.deadline else default

    # ---- the Caddyfile ----

    def _sudo(self, argv, data=None):
        """The output of sudo -n <argv>, for a file the user cannot reach;
        OSError when it fails or sudo refuses it."""
        try:
            code, out, err = _run(["sudo", "-n"] + argv, self.timeout(CALL_TIMEOUT), data=data)
        except subprocess.TimeoutExpired:
            raise OSError(errno.ETIMEDOUT, "sudo -n %s did not end in time" % argv[0])
        if code != 0:
            text = err.decode("utf-8", "replace")
            lines = [line.strip() for line in text.splitlines() if line.strip()] or ["exit %d" % code]
            raise OSError(errno.EACCES, _refusal(argv[0], text, False) or "sudo -n %s failed: %s" % (argv[0], lines[-1]))
        return out

    def read(self):
        try:
            if self.sudo and not os.access(self.caddyfile, os.R_OK):
                raw = self._sudo(["cat", self.caddyfile])
            else:
                with open(self.caddyfile, "rb") as fh:
                    raw = fh.read()
        except OSError as exc:
            raise errors.ConfigError("cannot read %s: %s" % (self.caddyfile, exc.strerror))
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            raise errors.ConfigError("%s is not UTF-8 text" % self.caddyfile)

    def writable(self):
        return self.sudo or os.access(self.caddyfile, os.W_OK)

    def write(self, text):
        """In place: the file keeps its inode, owner and mode, and a symlink
        keeps pointing where it did. Through sudo -n tee when the user
        cannot write it."""
        if self.sudo and not os.access(self.caddyfile, os.W_OK):
            self._sudo(["tee", self.caddyfile], text.encode("utf-8"))
            return
        with open(self.caddyfile, "wb") as fh:
            fh.write(text.encode("utf-8"))

    def copy(self, text):
        """<caddyfile>.bak-<UTC timestamp>, private, never over an older one.
        Where the user cannot write, sudo -n cp -p makes it from the file,
        which then holds the text: the copy has the Caddyfile's owner and mode."""
        taken = datetime.datetime.now(datetime.timezone.utc)
        through_sudo = self.sudo and not os.access(os.path.dirname(self.caddyfile) or ".", os.W_OK)
        try:
            while True:
                path = "%s.bak-%s" % (self.caddyfile, taken.strftime(_STAMP))
                if through_sudo:
                    if not os.path.lexists(path):
                        self._sudo(["cp", "-p", self.caddyfile, path])
                        return path
                else:
                    try:
                        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                        break
                    except FileExistsError:
                        pass
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
        set but cannot be read, or that names a variable caddy must not take
        from it, stops the command before anything changes."""
        if not self.envfile:
            return {}
        try:
            with open(self.envfile, "rb"):
                pass
        except OSError as exc:
            raise errors.ConfigError("cannot read the envfile %s: %s; nothing was changed"
                                     % (self.envfile, exc.strerror))
        variables = creds.read_env_file(self.envfile)
        for key in variables:
            if not key:
                raise errors.ConfigError("the envfile %s has a line with no name before =; nothing was changed"
                                         % self.envfile)
            if not _NAME.match(key):
                raise errors.ConfigError("the envfile %s: %s is not a variable name; nothing was changed"
                                         % (self.envfile, key))
            if _UNSAFE.match(key):
                raise errors.ConfigError("the envfile %s sets %s, which caddy's environment does not take from it; "
                                         "nothing was changed" % (self.envfile, key))
        return variables

    # ---- caddy ----

    def call(self, args, variables):
        """(ok, its output, or the line that says why not) for one caddy run;
        SudoRefused when sudo -n would not run it."""
        argv = [self.binary] + args
        if self.sudo:
            keep = ["--preserve-env=" + ",".join(sorted(variables))] if variables else []
            argv = ["sudo", "-n"] + keep + argv
        env = dict(os.environ)
        env.update(variables)
        timeout = max(0, self.timeout(CALL_TIMEOUT))
        try:
            code, out, err = _run(argv, timeout, env=env)
        except OSError as exc:
            # A failure like any other: after an edit, the cycle puts the copy back.
            return False, "cannot run %s: %s" % (argv[0], exc.strerror)
        except subprocess.TimeoutExpired:
            return False, "caddy %s did not end within %g seconds" % (args[0], round(timeout, 1))
        hidden = masked(variables)
        if code == 0:
            return True, redact(out.decode("utf-8", "replace").strip(), hidden)
        if self.sudo:
            refused = _refusal("caddy " + args[0], err.decode("utf-8", "replace"), bool(variables))
            if refused:
                raise SudoRefused(refused)
        # Masked before error_line cuts it: a value cut in two would no longer be found.
        return False, error_line(redact(err.decode("utf-8", "replace") + "\n"
                                        + out.decode("utf-8", "replace"), hidden), args[0], code)

    def validate(self, variables):
        return self.call(["validate", "--config", self.caddyfile, "--adapter", "caddyfile"], variables)

    def reload(self, variables):
        """caddy reload; an admin API other than the default is named, so
        the Caddy reloaded is the one alive() asks (validate takes no such flag)."""
        address = ["--address", self.admin] if self.admin != DEFAULT_ADMIN else []
        return self.call(["reload", "--config", self.caddyfile, "--adapter", "caddyfile"] + address, variables)

    def alive(self):
        """Whether the admin API answers GET /config/ with 200. The answer,
        which may hold secrets, is read and dropped."""
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        timeout = self.timeout(PROBE_TIMEOUT)
        if timeout <= 0:
            return False
        try:
            with opener.open("http://%s/config/" % self.admin, timeout=timeout) as resp:
                resp.read()
                return resp.status == 200
        except (urllib.error.URLError, OSError, ValueError):
            return False


def _kill(proc):
    """The process group of a run, killed and reaped; what refuses the signal
    (a process of root's under sudo) is left, without waiting on it long."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        try:
            proc.kill()
        except OSError:
            pass
    try:
        proc.communicate(timeout=1)
    except subprocess.TimeoutExpired:
        pass


def error_line(output, command, code):
    """Caddy's own reason: its last "Error:" line, else its last line."""
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    errs = [line for line in lines if line.startswith("Error:")]
    line = (errs or lines or ["caddy %s exited %d" % (command, code)])[-1]
    return line if len(line) <= 400 else line[:399] + "…"


def masked(variables):
    """The values worth masking among the envfile's."""
    return {v for v in variables.values() if len(v) >= SECRET_MIN}


def redact(text, values):
    for value in values:
        text = text.replace(value, "[token]")
    return text


def secrets(config):
    """The envfile's values, to keep them out of any output. Never fails: an
    unreadable envfile or a malformed section has nothing to mask."""
    envfile = config.caddy.get("envfile") if isinstance(config.caddy, dict) else None
    if not isinstance(envfile, str):
        return set()
    return masked(creds.read_env_file(envfile))


# ---- the probe ----

def _probe_address():
    host, _, port = (os.environ.get("CF_CADDY_PROBE") or PROBE).rpartition(":")
    return host, int(port)


def probe_one(host, address, timeout=PROBE_TIMEOUT):
    """The HTTP status the site answers at the address with SNI = host;
    NO_HTTP when the TLS handshake completes but no HTTP line comes; DOWN
    only when the connection or the TLS handshake fails. The certificate is
    not checked: the probe is about the reload."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["http/1.1"])
    request = "HEAD / HTTP/1.1\r\nHost: %s\r\nUser-Agent: claude-cloudflare\r\nConnection: close\r\n\r\n" % host
    if timeout <= 0:
        return DOWN
    try:
        raw = socket.create_connection(address, timeout=timeout)
    except (OSError, ValueError):
        return DOWN
    with raw:
        try:
            tls = context.wrap_socket(raw, server_hostname=host)
        except (OSError, ssl.SSLError, ValueError):
            return DOWN
        with tls:
            try:
                tls.sendall(request.encode("ascii"))
                first = tls.makefile("rb").readline(256)
            except (OSError, ssl.SSLError, ValueError):
                return NO_HTTP
    match = _STATUS.match(first)
    return int(match.group(1)) if match else NO_HTTP


def probe(hosts, settings=None):
    """{host: status or DOWN} for every host, probed side by side, each
    within the time the settings' cycle has left."""
    address = _probe_address()
    if not hosts:
        return {}

    def one(host):
        return probe_one(host, address, settings.timeout(PROBE_TIMEOUT) if settings else PROBE_TIMEOUT)

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(hosts))) as pool:
        return dict(zip(hosts, pool.map(one, hosts)))


# ---- the service ----

def _same(a, b):
    return os.path.realpath(os.path.expanduser(a)) == os.path.realpath(os.path.expanduser(b))


def _launchd_envfile(path):
    """The --envfile of the plist's ProgramArguments, an argument that is a
    whole command line (sh -c "caddy run --envfile x") read word by word."""
    with open(path, "rb") as fh:
        args = plistlib.load(fh).get("ProgramArguments") or []
    words = []
    for arg in args:
        if not isinstance(arg, str):
            continue
        try:
            words += shlex.split(arg) if any(c.isspace() for c in arg) else [arg]
        except ValueError:
            words.append(arg)
    found = []
    for k, word in enumerate(words):
        if word == "--envfile" and k + 1 < len(words):
            found.append(words[k + 1])
        elif word.startswith("--envfile="):
            found.append(word[len("--envfile="):])
    return found


def _unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _systemd_envfile(path):
    """EnvironmentFile= of the unit and of its drop-ins beside it
    (<unit>.d/*.conf), in systemd's order: an empty one resets the list, a
    "-" prefix (a file that may be missing) and quotes are not the path."""
    files = [path]
    dropins = path + ".d"
    if os.path.isdir(dropins):
        files += [os.path.join(dropins, n) for n in sorted(os.listdir(dropins)) if n.endswith(".conf")]
    found = []
    for name in files:
        with open(name, encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.strip().partition("=")
                if not sep or key.strip() != "EnvironmentFile":
                    continue
                value = value.strip()
                if not value:
                    found = []
                    continue
                found.append(_unquote(_unquote(value).lstrip("-")).lstrip("-"))
    return found


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
