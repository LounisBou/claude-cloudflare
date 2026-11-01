"""The Cloudflare API transport.

CF_API_BASE overrides the base URL, which is how the suite points the engine
at its local fixture server. Answers are unwrapped from Cloudflare's envelope:
a call returns its "result", lists are read page after page and returned
whole, and "success": false raises ApiError with Cloudflare's own codes.
"""

import http.client
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

from . import creds, errors

API = "https://api.cloudflare.com/client/v4"
_TIMEOUT = 30
_MAX_RETRIES = 3
# Pages are read until Cloudflare's total_pages, and never past this, so a
# server that keeps answering pages cannot hold the engine in a loop. A list
# with pages left past it fails whole: a part of it could be backed up and
# restored as if it were all.
_MAX_PAGES = 500

# The default handlers but the redirect one: a redirect would carry the
# Authorization header to wherever it points. A 3xx stays an HTTPError.
_OPENER = urllib.request.OpenerDirector()
for _handler in (urllib.request.ProxyHandler(), urllib.request.HTTPHandler(),
                 urllib.request.HTTPSHandler(), urllib.request.HTTPDefaultErrorHandler(),
                 urllib.request.HTTPErrorProcessor()):
    _OPENER.add_handler(_handler)


def base_url():
    return (os.environ.get("CF_API_BASE") or API).rstrip("/")


def _failure(status, data):
    found = data.get("errors") if isinstance(data, dict) else None
    if found:
        return errors.ApiError("; ".join(
            "Cloudflare %s: %s" % (e.get("code", "?"), e.get("message", "request failed"))
            if isinstance(e, dict) else str(e)
            for e in found
        ))
    return errors.ApiError("Cloudflare answered HTTP %s" % status)


class Api:
    """One account's calls. The token is read when a request is sent, set in
    its Authorization header and nowhere else."""

    def __init__(self, account):
        self.account = account

    def get(self, path, body=None, params=None, raw=False):
        if raw:
            return self._request("GET", path, body, params, raw=True)
        data = self._request("GET", path, body, params)
        result = data.get("result")
        info = data.get("result_info") or {}
        if not isinstance(result, list):
            return result
        items = list(result)
        page = info.get("page") or 1
        total = info.get("total_pages") or 1
        cursor = info.get("cursor")
        pages = 1
        while (page < total or cursor) and pages < _MAX_PAGES:
            more = dict(params or {})
            if cursor:
                more["cursor"] = cursor
            else:
                page += 1
                more["page"] = page
            data = self._request("GET", path, body, more)
            chunk = data.get("result") or []
            items.extend(chunk)
            info = data.get("result_info") or {}
            cursor = info.get("cursor") if chunk else None
            total = info.get("total_pages") or total
            pages += 1
        if page < total or cursor:
            raise errors.ApiError("%s holds more than %d pages: refused rather than cut" % (path, _MAX_PAGES))
        return items

    def post(self, path, body=None, params=None):
        return self._request("POST", path, body, params).get("result")

    def put(self, path, body=None, params=None):
        return self._request("PUT", path, body, params).get("result")

    def patch(self, path, body=None, params=None):
        return self._request("PATCH", path, body, params).get("result")

    def delete(self, path, body=None, params=None):
        return self._request("DELETE", path, body, params).get("result")

    def _request(self, method, path, body, params, raw=False):
        url = base_url() + path
        query = {k: v for k, v in (params or {}).items() if v is not None}
        if query:
            url += "?" + urllib.parse.urlencode(query)
        headers = {
            "Authorization": "Bearer " + creds.token(self.account),
            "Content-Type": "application/json",
            "User-Agent": "claude-cloudflare",
        }
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(_MAX_RETRIES):
            status, text = _send(method, url, data, headers)
            # A 429 is a request Cloudflare did not process: sending it again
            # cannot apply a write twice. Nothing else is retried.
            if status == 429 and attempt < _MAX_RETRIES - 1:
                time.sleep(2 ** attempt)
                continue
            break
        if raw and status < 400:
            return text
        try:
            parsed = json.loads(text) if text else {}
        except ValueError:
            raise errors.ApiError("Cloudflare answered HTTP %s with a body that is not JSON" % status)
        if status >= 400 or not isinstance(parsed, dict) or parsed.get("success") is False:
            raise _failure(status, parsed)
        return parsed


def _send(method, url, data, headers):
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with _OPENER.open(req, timeout=_TIMEOUT) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        if 300 <= exc.code < 400:
            raise errors.ApiError("Cloudflare answered HTTP %s, a redirect, which is not followed" % exc.code)
        return exc.code, exc.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, OSError) as exc:
        reason = getattr(exc, "reason", exc)
        raise errors.ApiError("cannot reach the Cloudflare API at %s: %s" % (base_url(), reason))
    except (http.client.HTTPException, ValueError) as exc:
        # Named by its type alone: its text can quote whatever was sent or read.
        raise errors.ApiError("cannot read the Cloudflare API's answer at %s: %s" % (base_url(), type(exc).__name__))
