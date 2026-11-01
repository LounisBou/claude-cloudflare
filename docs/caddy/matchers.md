# Request matchers

Source: caddyserver.com/docs/caddyfile/matchers

## Forms

A directive that takes a matcher takes it as its first argument:

- `*`: every request (the same as giving none);
- `/path`: an inline path matcher, the token starts with `/`;
- `@name`: a named matcher defined in the same site block.

```
@name matcher args              # single line

@name {                         # block: every line must match (AND)
	matcher args
	matcher args
}

@not-found `{err.status_code} == 404`  # a CEL expression alone

reverse_proxy @name localhost:8080
```

## Combining

- Different matchers in one named set are AND'ed.
- The same matcher repeated is generally OR'ed: several `path`, `method` or
  `host` values match any one; several `header` lines for one field match any
  value, different fields are AND'ed; query keys are AND'ed, values of one key
  OR'ed.
- `header_regexp`, `path_regexp`, `vars_regexp`, `protocol` and `url_pattern`
  have their own limits on repetition: use `expression` for complex logic.

## Paths

- Exact match by default, not a prefix; case-insensitive.
- A trailing `*` makes a prefix: `/foo*` matches `/foo`, `/foo/`, `/foobar`;
  `/foo/*` matches neither `/foo` nor `/foobar`.
- `*` may also lead (suffix), surround (substring) or sit in the middle (glob).

## Matchers

| Syntax | Matches |
|---|---|
| `path <paths...>` | the request path (rules above) |
| `path_regexp [<name>] <regexp>` | the URI-decoded path, RE2; captures in `{re.<name>.1}` or `{re.1}` |
| `host <hosts...>` | the Host header |
| `method <verbs...>` | the HTTP method, case-insensitive |
| `header <field> [<value>]` | a header field, and its value (`*value*` matches a substring); `!field` requires it absent |
| `header_regexp [<name>] <field> <regexp>` | a header value, RE2 |
| `query <key>=<val>...` | query parameters; `query ""` matches no query at all |
| `protocol http\|https\|grpc\|http/<version>[+]` | the protocol, or a minimum HTTP version |
| `remote_ip <ranges...>` | the immediate peer IP (or PROXY protocol address), IPs or CIDRs |
| `client_ip <ranges...>` | the client IP, read from headers when `trusted_proxies` is set |
| `file [<files...>]` | files that exist; block form: `root`, `try_files`, `try_policy`, `split_path` |
| `vars <variable> <values...>` | a variable or placeholder value |
| `vars_regexp [<name>] <variable> <regexp>` | a variable against RE2 |
| `not <matcher>` / `not { <matchers...> }` | the negation |
| `expression <cel...>` | a CEL expression returning true |
| `url_pattern <pattern> { base_url <url>; ignore_case }` | a URLPattern-style pattern |

## Examples

```
@api path /api/*
reverse_proxy @api localhost:5000

@admin {
	path /admin*
	not remote_ip private_ranges
}
respond @admin "Forbidden" 403

@websockets {
	header Connection *Upgrade*
	header Upgrade websocket
}
reverse_proxy @websockets localhost:6001

@foo host foo.example.com
handle @foo {
	respond "Foo!"
}
```

`private_ranges` is the shorthand for the private IPv4 and IPv6 ranges, as in
`trusted_proxies static private_ranges` (see `global-options`).
