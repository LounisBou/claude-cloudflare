# Headers: header, request_header

Sources: caddyserver.com/docs/caddyfile/directives/header,
caddyserver.com/docs/caddyfile/directives/request_header

## header (response headers)

```
header [<matcher>] [[+|-|?|>]<field> [<value>|<find>] [<replace>]] {
	+<field> <value>            # add
	<field> <value>             # set
	><field> <value>            # set, deferred
	-<field>                    # delete
	<field> <find> <replace>    # replace (find is a regular expression)
	><field> <find> <replace>   # replace, deferred
	?<field> <value>            # default: set only when absent
	[defer]
	match <inline_response_matcher>
}
```

- No prefix sets (overwrites); `+` adds another value; `-` deletes (`*` as a
  prefix or suffix deletes every matching field); `?` sets a default.
- Deferred operations apply when the response is written: always for `-`, `?`,
  `>` and when `match` is present; `defer` forces it. Defer when an upstream
  (`reverse_proxy`) writes the header itself, so the change comes after it.

```
header {
	# enable HSTS
	Strict-Transport-Security max-age=31536000;
	# disable clients from sniffing the media type
	X-Content-Type-Options nosniff
	# clickjacking protection
	X-Frame-Options DENY
}

header -Hidden
header ?Cache-Control "max-age=3600"
header /no-cache* >Cache-Control no-cache
header >Access-Control-Allow-Origin "\*" "allowed-partner.com"
```

The page marks the security block as for those who understand what each
header does. In the last line `<find>` is a regular expression, hence `\*`.

Cache-Control on successful GETs only, and none on server errors:

```
@GET method GET
header @GET Cache-Control "max-age=3600" {
	match status 2xx
}
header {
	-Cache-Control
	-CDN-Cache-Control
	match status 500
}
reverse_proxy upstream:443
```

Caddy has no response cache of its own in the standard directives: caching is
the browser's and the CDN's, steered by these headers (with Cloudflare in
front, see its cache rules).

## request_header (headers sent on)

```
request_header [<matcher>] [[+|-]<field> [<value>|<find>] [<replace>]]
```

```
request_header -Referer
request_header -*_*
```

For headers to one backend only, `reverse_proxy`'s `header_up` /
`header_down` (see `reverse-proxy`).
