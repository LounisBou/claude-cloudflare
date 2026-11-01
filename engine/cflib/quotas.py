"""The quotas of a zone's plan the engine relies on.

Cloudflare does not publish a zone's quotas through the API, so they are
kept here, from the product documentation. A protection write checks them
first and refuses (exit 5) what the plan lacks or what is full, instead of
failing later on an API error. A plan the table does not know is given the
Enterprise column: the API still has the last word.
"""

from . import errors

QUOTAS = {
    "free": {"custom_rules": 5, "rate_limit_rules": 1, "managed": ("free",), "bot": "bot-fight-mode",
             "periods": (10,), "timeout_max": 10},
    "pro": {"custom_rules": 20, "rate_limit_rules": 2, "managed": ("free", "cloudflare", "owasp"),
            "bot": "super-bot-fight-mode", "periods": (10, 60), "timeout_max": 3600},
    "business": {"custom_rules": 100, "rate_limit_rules": 5, "managed": ("free", "cloudflare", "owasp"),
                 "bot": "super-bot-fight-mode", "periods": (10, 60, 120, 300, 600), "timeout_max": 86400},
    "enterprise": {"custom_rules": 1000, "rate_limit_rules": 100, "managed": ("free", "cloudflare", "owasp"),
                   "bot": "bot-management", "periods": None, "timeout_max": 86400},
}
# Log is a custom-rule action of Enterprise only.
LOG_PLANS = ("enterprise",)
MANAGED_NAMES = {"free": "Free Managed Ruleset", "cloudflare": "Cloudflare Managed Ruleset",
                 "owasp": "Cloudflare OWASP Core Ruleset"}


def key(zone):
    plan = zone.get("plan") or {}
    legacy = plan.get("legacy_id")
    if legacy in QUOTAS:
        return legacy
    word = (plan.get("name") or "").split(" ")[0].lower()
    return word if word in QUOTAS else "enterprise"


def name(zone):
    return (zone.get("plan") or {}).get("name") or key(zone)


def limits(zone):
    return QUOTAS[key(zone)]


def refuse(zone, reason):
    """Exit 5: one line naming the plan and what it lacks or what is full."""
    raise errors.Refused("plan %s: %s" % (name(zone), reason))


def require_managed(zone, ruleset):
    if ruleset not in limits(zone)["managed"]:
        refuse(zone, "no %s" % MANAGED_NAMES[ruleset])


def require_room(zone, quota, used, what):
    limit = limits(zone)[quota]
    if used >= limit:
        refuse(zone, "%s quota is full (%d of %d)" % (what, used, limit))
