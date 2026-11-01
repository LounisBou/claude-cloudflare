# Caddyfile structure

Source: caddyserver.com/docs/caddyfile/concepts

## Layout

```
{
	# global options: optional, and only as the very first block
	email admin@example.com
}

(snippet_name) {
	# a snippet, reused with: import snippet_name
}

&(route_name) {
	# a named route (experimental), reused with: invoke route_name
}

example.com {
	# a site block: directives, one per line
	reverse_proxy localhost:8080
}
```

- Directives and matchers live inside a site block; there is no global scope
  and no inheritance between site blocks.
- With a single site block its braces are optional.
- A block opens with `{` at the end of a line, preceded by a space, and closes
  with `}` on its own line.
- A directive is the first word of a line; its arguments follow on that line.
  Subdirectives go in the directive's own block (`lb_policy first` inside
  `reverse_proxy { }`).
- Directives do not nest, except inside `route`, `handle` and `handle_path`.

## Tokens, quotes, comments

- Tokens split on whitespace: `directive "abc def"` for a value with spaces.
- `\"` escapes a quote inside a quoted token; backticks need no escaping:
  `` `{"foo": "bar"}` ``. Quoted tokens may span lines.
- A quoted `"{"` or `"}"` is a plain argument: it opens or closes nothing.
- Heredoc: `<<MARKER` … `MARKER`. The closing marker may be indented; that
  indentation is stripped from every line. Arguments may follow the closing
  marker (`HTML 200`). `\<<` escapes the opening marker.
- `#` starts a comment to the end of the line, only at the start of a line or
  after a space (a URI with a `#` needs no quoting).

## Addresses

| Address | Effect |
|---|---|
| `example.com` | HTTPS, publicly trusted managed certificate |
| `*.example.com` | HTTPS, wildcard certificate |
| `localhost` | HTTPS, locally trusted certificate |
| `http://example.com` | plain HTTP, with a Host matcher |
| `http://`, `https://` | catch-alls (follow `http_port` / `https_port`) |
| `:443`, `:8080`, `localhost:8080`, `127.0.0.1` | by port or by IP |

- Automatic HTTPS applies when the address has a host name or an IP, unless
  the scheme is `http://`.
- `*` matches exactly one label: `*.example.com` matches `foo.example.com`,
  not `foo.bar.example.com`.
- Several addresses may share a block, separated by spaces or commas
  (`localhost:8080, example.com, www.example.com {`); each must be unique.
- Placeholders are not allowed in addresses; environment variables are.
- Sites bind every interface by default (`bind`, or the `default_bind` global
  option, to change it).

## Snippets and import

```
(logging) {
	log {
		output file /var/log/caddy.log
	}
}

example.com {
	import logging
}
```

- `import` also takes files and globs (`import sites/*`), and may stand
  outside site blocks.
- Arguments: `import snippet "Example A"`, read as `{args[0]}` in the snippet.
- Since v2.9 (experimental): a block passed to the import, read as `{block}`.

## Named routes (experimental)

`&(app-proxy) { reverse_proxy app:8080 }` outside site blocks, then
`invoke app-proxy` in any site. Names are unique; a named route may `import`
and `invoke` others.

## Environment variables

- `{$VAR}` is substituted before parsing: it may expand to nothing, part of a
  token or several tokens. `{$VAR:default}` gives a default
  (`{$DOMAIN:localhost}`). With this plugin the envfile is in the environment
  of `caddy validate` and `caddy reload`, so `{$VAR}` resolves there too.
- `{env.VAR}` is a placeholder read at runtime, from the environment of the
  running Caddy (the service's `--envfile` / `EnvironmentFile=`); not every
  parameter supports placeholders.
- `{file./absolute/path}` reads a secret from a file at runtime.

## Matcher tokens (see `matchers`)

The first argument of a directive that takes a matcher is `*` (every
request), `/path` (a path) or `@name` (a named matcher). Omitted: every request.
