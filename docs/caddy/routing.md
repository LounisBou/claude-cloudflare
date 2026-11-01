# Routing: handle, route, redirects, rewrites, responses, errors

Sources: caddyserver.com/docs/caddyfile/directives/ (handle, handle_path,
route, redir, rewrite, uri, try_files, respond, abort, error, handle_errors)

## handle, handle_path, route

```
handle [<matcher>] {
	<directives...>
}

handle_path <path_matcher> {
	<directives...>
}

route [<matcher>] {
	<directives...>
}
```

- `handle`: of the `handle` blocks at one level, only the first matching one
  runs. One with no matcher is the fallback; put it last. Blocks are sorted by
  their matchers; they may nest; only HTTP handler directives go inside.
- `handle_path`: a `handle` that also strips the matched prefix (the rest
  always starts with `/`). One path matcher only, no named matcher.
  `handle_path /prefix/* { … }` is `handle /prefix/* { uri strip_prefix /prefix … }`.
- `route`: its directives run in the order written, not in the default
  directive order (see `directives`).

```
example.com {
	handle /api/* {
		reverse_proxy backend:8000
	}
	handle {
		root /srv
		try_files {path} /index.html
		file_server
	}
}
```

## redir

```
redir [<matcher>] <to> [<code>]
```

`<code>`: `temporary` (302, the default), `permanent` (301), `html` (an HTML
redirect, for browsers only), a 3xx number or 401, or a placeholder. 301/302
let the client change the method; use 307/308 to keep it.

```
www.example.com {
	redir https://example.com{uri} permanent
}
redir /about-us /about
```

## rewrite

```
rewrite [<matcher>] <to>
```

An internal rewrite of the URI (path and query only). Rewrites in one block
are mutually exclusive: the first matching one runs.

```
rewrite /index.html
rewrite /api/* ?{query}&a=b
```

## uri

```
uri [<matcher>] strip_prefix <target>
uri [<matcher>] strip_suffix <target>
uri [<matcher>] replace      <target> <replacement> [<limit>]
uri [<matcher>] path_regexp  <target> <replacement>
uri [<matcher>] query        [-|+]<param> [<value>]
```

`uri query foo bar` sets, `-foo` removes, `+foo bar` appends, `foo>bar`
renames, `foo ^(ba)r $1z` replaces by regexp; a `query { … }` block groups them.

## try_files

```
try_files <files...> {
	policy first_exist|first_exist_fallback|smallest_size|largest_size|most_recently_modified
}
```

Rewrites to the first file that exists under the site root; no matcher token.
A trailing `/` matches a directory; a last item `=404` raises that error.

`try_files {path} {path}/ /index.php?{query}&p={path}`

## respond, abort, error

```
respond [<matcher>] <status>|<body> [<status>] {
	body <text>
	close
}
abort [<matcher>]
error [<matcher>] <status>|<message> [<status>] {
	message <text>
}
```

- `respond`: a fixed response (status 200 by default); it is not an error.
- `abort`: stops the handler chain and closes the connection, no response.
- `error`: raises an error (500 by default) for `handle_errors` to handle.

```
respond /health-check 200
respond /secret/* "Access denied" 403 {
	close
}
error /private* "Unauthorized" 403
```

## handle_errors

```
handle_errors [<status_codes...>] {
	<directives...>
}
```

Codes may be `404`, `4xx`, `5xx`; with none, it is the fallback error route.
Placeholders: `{err.status_code}`, `{err.status_text}`, `{err.message}`,
`{err.trace}`, `{err.id}`. A status written by `reverse_proxy` is not an error
and does not reach these routes.

```
handle_errors 404 410 {
	respond "It's a 404 or 410 error!"
}
handle_errors {
	rewrite /{err.status_code}.html
	file_server
}
```
