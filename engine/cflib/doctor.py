"""The checks /cloudflare:doctor runs past auth-check: what an account's token
may do for the plugin's commands, and whether the local Caddy is set up for
them. Both only read, and neither prints a token or an envfile value.

What a token may read is probed: one read per family of commands, a refusal
naming the permission missing; a token Cloudflare does not authenticate is
said to be invalid. What it may write cannot be probed without writing: it is
read from the token's own policies, which Cloudflare shows a token only when
it was given the right to read API tokens; else it is said to be unchecked.
A write is granted by a permission group of an exact name, as the API names
it ("… Write") or as the dashboard does ("… Edit"), the names of
developers.cloudflare.com/fundamentals/api/reference/permissions/.
"""

import json
import os
import re
import sys

from . import accounts, caddyctl, caddyfile, config, context, creds, errors, http

# (family, the probe's scope and path under it, None for a family with
# nothing to read, its reads, its writes, the permission groups that grant
# those writes).
FAMILIES = (
    ("DNS", "zone", "/dns_records", ("dns-list", "dns-get", "dns-export", "inventory"),
     ("dns-create", "dns-update", "dns-delete", "publish", "unpublish"), ("DNS Write",)),
    ("Zone Settings", "zone", "/settings/ssl", ("settings",),
     ("setting-set", "security-level", "under-attack"), ("Zone Settings Write", "Zone Settings Edit")),
    ("SSL and Certificates", "zone", "/ssl/certificate_packs", ("certs",),
     ("universal-ssl",), ("SSL and Certificates Write", "SSL and Certificates Edit")),
    ("Zone WAF", "zone", "/rulesets/phases/http_request_firewall_custom/entrypoint", ("rules", "plan"),
     ("rule-add", "rule-update", "rule-delete", "block-countries", "allow-only-countries", "challenge",
      "rate-limit", "managed-rules"), ("Zone WAF Write", "Zone WAF Edit")),
    ("Firewall Services", "zone", "/firewall/access_rules/rules", ("ip-rules", "security"),
     ("ip-allow", "ip-block", "ip-rule-delete"), ("Firewall Services Write", "Firewall Services Edit")),
    ("Bot Management", "zone", "/bot_management", ("security",), ("bot-fight",),
     ("Bot Management Write", "Bot Management Edit")),
    ("Cache Rules", "zone", "/rulesets/phases/http_request_cache_settings/entrypoint", ("cache-rules",),
     ("cache-rule-add", "cache-rule-delete"), ("Cache Settings Write", "Cache Rules Edit")),
    ("Cache Purge", None, None, (), ("purge", "purge-all"), ("Cache Purge",)),
    ("Workers Routes", "zone", "/workers/routes", ("worker-routes",),
     ("worker-route-add", "worker-route-delete"), ("Workers Routes Write", "Workers Routes Edit")),
    ("Workers Scripts", "account", "/workers/scripts", ("workers", "worker-domains"),
     ("worker-deploy", "worker-delete", "worker-domain-add", "worker-domain-delete"),
     ("Workers Scripts Write", "Workers Scripts Edit")),
)
# Cloudflare's answer to a request the token has no permission for, and to a
# token it does not authenticate.
_DENIED = ("9109",)
_INVALID = ("10000",)
# /user/tokens/verify's answer to a token it does not know.
_UNKNOWN_TOKEN = ("1000",)
# The permission group that lets Caddy write the DNS-01 challenge's record.
_DNS_EDIT = FAMILIES[0][5]
_CODE = re.compile(r"Cloudflare (\d+):")
_PLACEHOLDER = re.compile(r"\{\$([A-Za-z_][A-Za-z0-9_]*)(?::[^}]*)?\}|\{env\.([A-Za-z_][A-Za-z0-9_]*)\}")


def _coded(exc, codes):
    return any(code in codes for code in _CODE.findall(exc.message))


class _Invalid(Exception):
    """The token itself is refused: no probe can say what it may do."""


def _probe(ctx, path):
    """None when the token may read the path, else the reason it may not.
    A path with nothing at it yet (no ruleset entrypoint) is readable."""
    try:
        ctx.api.get(path, raw=True)
    except errors.ApiError as exc:
        if _coded(exc, _INVALID):
            raise _Invalid(exc.message)
        return "denied" if _coded(exc, _DENIED) else None
    return None


def _policies(ctx, token_id):
    """The permission group names the token holds, or None when it cannot
    read its own policies."""
    paths = ["/user/tokens/" + token_id]
    if ctx.account.account_id:
        paths.append("/accounts/%s/tokens/%s" % (ctx.account.account_id, token_id))
    for path in paths:
        try:
            found = ctx.api.get(path)
        except errors.ApiError:
            continue
        return _granted(found)
    return None


def _granted(token):
    """The permission group names a token's allowing policies hold."""
    return {group.get("name", "") for policy in (token or {}).get("policies") or []
            if policy.get("effect", "allow") == "allow" for group in policy.get("permission_groups") or []}


def permissions(ctx, token_id):
    """The lines that say what the token may read and write, family by family;
    one line alone for a token Cloudflare does not authenticate."""
    try:
        return _permissions(ctx, token_id)
    except _Invalid as exc:
        return ["invalid token: %s: nothing it may read or write can be told" % exc]


def _permissions(ctx, token_id):
    # One zone is enough to probe on: its first page, not every page.
    try:
        listed = ctx.api.get("/zones", params={"per_page": 1}, raw=True)
    except errors.ApiError as exc:
        if _coded(exc, _INVALID):
            raise _Invalid(exc.message)
        raise
    found = json.loads(listed or "{}").get("result") or []
    zone = found[0] if found else None
    account = None
    try:
        account = accounts.account_id(ctx)
    except errors.CfError:
        pass
    lines, unread = [], []
    for family, scope, path, reads, _, _ in FAMILIES:
        if scope is None:
            continue
        base = "/zones/%s" % zone["id"] if scope == "zone" and zone else (
            "/accounts/%s" % account if scope == "account" and account else None)
        if base is None:
            lines.append("not probed: %s (no %s to probe on)" % (family, scope))
            continue
        if _probe(ctx, base + path):
            unread.append(family)
            lines.append("missing read: %s (%s)" % (family, ", ".join(reads)))
    if not unread and not lines:
        lines.append("reads: every family readable")
    names = _policies(ctx, token_id) if token_id else None
    if names is None:
        lines.append("writes: not checked: the token cannot read its own policies "
                     "(grant it API Tokens Read for this check)")
        return lines
    missing = [(family, writes) for family, _, _, _, writes, granting in FAMILIES if not names & set(granting)]
    for family, writes in missing:
        lines.append("missing write: %s (%s)" % (family, ", ".join(writes)))
    if not missing:
        lines.append("writes: every family writable")
    return lines


def snippet_variables(text, snippet):
    """The environment variables the TLS snippet reads ({$NAME}, {env.NAME}),
    or None when the Caddyfile has no such snippet."""
    blocks, _ = caddyfile.parse(text)
    for block in blocks:
        if block.kind == "snippet" and block.addresses == ["(%s)" % snippet]:
            return sorted({a or b for a, b in _PLACEHOLDER.findall(text[block.start:block.end])})
    return None


def dns01(envfile, name):
    """(line, ok) of the DNS-01 token the envfile holds under name: valid
    (GET /user/tokens/verify), then its DNS edit right when the token may
    read its own policies (API Tokens Read), else said not checkable. The
    token is read from the envfile when each request is sent, and never shown."""
    api = http.Api(None, token=lambda _account: creds.read_env_file(envfile).get(name, ""))
    try:
        verified = api.get("/user/tokens/verify") or {}
    except errors.ApiError as exc:
        if _coded(exc, _INVALID + _UNKNOWN_TOKEN):
            return "DNS-01 token %s is invalid: %s" % (name, exc.message), False
        return "DNS-01 token %s could not be verified: %s" % (name, exc.message), False
    if verified.get("status") != "active":
        return "DNS-01 token %s is %s" % (name, verified.get("status") or "not active"), False
    try:
        names = _granted(api.get("/user/tokens/%s" % verified.get("id")))
    except errors.ApiError:
        return "DNS-01 token %s: valid; DNS edit right not checkable with this token " \
               "(it may not read its own policies)" % name, True
    if names & set(_DNS_EDIT):
        return "DNS-01 token %s: valid, with DNS Write" % name, True
    return "DNS-01 token %s is valid but has no DNS Write: Caddy cannot answer a DNS-01 challenge" % name, False


def caddy(cfg):
    """(lines, ok): the binary runs, the service is found and starts caddy
    with the envfile, the envfile is private and holds the variables the TLS
    snippet reads, and each of them is a valid DNS-01 token."""
    if not cfg.caddy:
        return ["caddy: no caddy section in %s: the Caddy checks are skipped" % cfg.path], True
    settings = caddyctl.Settings(cfg)
    lines = []

    def fail(line):
        nonlocal ok
        ok = False
        lines.append("caddy: error: " + line)

    # The binary is checked first: its answer is where ok starts.
    ok, version = settings.call(["version"], {})
    if ok:
        lines.append("caddy: binary %s: %s" % (settings.binary, (version.splitlines() or ["-"])[0]))
    else:
        fail("binary %s: %s" % (settings.binary, version))
    state, detail, warning = caddyctl.service(settings)
    if state == "ok":
        lines.append("caddy: service " + detail)
    elif state == "-" and not settings.manager:
        lines.append("caddy: service: no manager in the config, not checked")
    else:
        fail(warning or "service " + detail)
    if not settings.envfile:
        fail("no envfile in the config: caddy validate and reload would run without the DNS-01 token")
        return lines, ok
    try:
        variables = settings.variables()
        wanted = snippet_variables(settings.read(), settings.tls_snippet) if settings.tls_snippet else []
    except errors.CfError as exc:
        fail(exc.message)
        return lines, ok
    mode = os.stat(settings.envfile).st_mode & 0o777
    if mode & 0o077:
        lines.append("caddy: warning: %s is readable by others (mode %o): chmod 600 it" % (settings.envfile, mode))
    if not settings.tls_snippet:
        lines.append("caddy: envfile %s: %d variables; no tls_snippet configured, token variable not checked"
                     % (settings.envfile, len(variables)))
    elif wanted is None:
        fail("the Caddyfile has no snippet (%s), which caddy.tls_snippet names" % settings.tls_snippet)
    elif not wanted:
        lines.append("caddy: envfile %s: %d variables; the tls snippet reads none" % (settings.envfile, len(variables)))
    else:
        absent = [name for name in wanted if not variables.get(name)]
        if absent:
            fail("envfile %s has no %s, the variable of the %s snippet" % (
                settings.envfile, ", ".join(absent), settings.tls_snippet))
        else:
            lines.append("caddy: envfile %s holds %s, the variable of the %s snippet" % (
                settings.envfile, ", ".join(wanted), settings.tls_snippet))
            for name in wanted:
                line, valid = dns01(settings.envfile, name)
                if valid:
                    lines.append("caddy: " + line)
                else:
                    fail(line)
    return lines, ok


def _run(argv, cfg):
    if argv[:1] == ["permissions"] and len(argv) in (2, 3):
        ctx = context.make(cfg, argv[1])
        lines = permissions(ctx, argv[2] if len(argv) == 3 else None)
        return lines, 1 if lines[0].startswith("invalid token") else 0
    if argv == ["caddy"]:
        lines, ok = caddy(cfg)
        return lines, 0 if ok else 1
    raise errors.UsageError("usage: doctor.py permissions <account> [token id] | doctor.py caddy")


def main(argv):
    """doctor.py permissions <account> [token id] | doctor.py caddy. Exit 0,
    1 when the token is invalid or a Caddy check failed, or an engine exit code."""
    secrets = creds.secrets([])
    try:
        cfg = config.load_config()
        secrets = creds.secrets(cfg.env_files) | caddyctl.secrets(cfg)
        lines, code = _run(argv, cfg)
    except errors.CfError as exc:
        print("cf: " + creds.redact(exc.message, secrets), file=sys.stderr)
        return exc.code
    print(creds.redact("\n".join(lines), secrets))
    return code
