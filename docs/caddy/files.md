# Files: root, file_server, php_fastcgi

Sources: caddyserver.com/docs/caddyfile/directives/root,
caddyserver.com/docs/caddyfile/directives/file_server,
caddyserver.com/docs/caddyfile/directives/php_fastcgi

## root

```
root [<matcher>] <path>
```

Sets the site root (`{http.vars.root}`) that matchers and file directives use;
the current working directory by default. Mutually exclusive with the other
`root` of the same block. It serves nothing by itself: pair it with
`file_server` or `php_fastcgi`.

```
root /home/bob/public_html
root public_html
root /foo/* /home/user/public_html/foo
```

## file_server

```
file_server [<matcher>] [browse] {
	fs            <backend...>
	root          <path>
	hide          <files...>
	index         <filenames...>
	browse        [<template_file>] {
		reveal_symlinks
		sort <sort_field> [<direction>]
		file_limit <number>
	}
	precompressed [<formats...>]
	status        <status>
	disable_canonical_uris
	pass_thru
}
```

- `fs`: another (possibly virtual) file system; the local disk by default.
- `root`: the root for this handler only (default `{http.vars.root}`).
- `hide`: files or folders that appear not to exist (placeholders, globs;
  file system paths).
- `index`: index files, `index.html index.txt` by default.
- `browse`: directory listings where no index exists, with an optional
  template; `reveal_symlinks`; `sort` by `name`, `namedirfirst`, `size` or
  `time`, `asc` or `desc`; `file_limit` (10000 by default).
- `precompressed`: serve sidecar files (`br zstd gzip` by default, in that
  order).
- `status`: override the status code (placeholders allowed).
- `disable_canonical_uris`: no trailing-slash redirects.
- `pass_thru`: hand over to the next handler instead of a 404.

```
example.com {
	root /srv
	file_server
}

file_server browse
file_server /static/*
file_server {
	hide .git
}
```

## php_fastcgi

```
php_fastcgi [<matcher>] <php-fpm_gateways...> {
	root <path>
	split <substrings...>
	index <filename>|off
	try_files <files...>
	env [<key> <value>]
	resolve_root_symlink
	capture_stderr
	dial_timeout  <duration>
	read_timeout  <duration>
	write_timeout <duration>
}
```

| Subdirective | Purpose | Default |
|---|---|---|
| `root` | the site's root folder | the `root` directive, else the working directory |
| `split` | splits the URI into script name and `PATH_INFO` | `.php` |
| `index` | the directory index; `off` disables the fallback | `index.php` |
| `try_files` | replaces the file-based rewrite | `{path} {path}/index.php index.php` |
| `env` | an extra environment variable (repeatable) | none |
| `resolve_root_symlink` | resolve `root` when it is a symlink | off |
| `capture_stderr` | log what the FastCGI server writes to stderr | ignored |
| `dial_timeout` | connecting to the upstream | `3s` |
| `read_timeout` / `write_timeout` | reading from / sending to it | none |

```
php_fastcgi 127.0.0.1:9000
php_fastcgi /blog/* localhost:9000
php_fastcgi unix//run/php/php8.2-fpm.sock

example.com {
	root /var/www/html/public
	php_fastcgi 127.0.0.1:9000
	file_server
}
```

Single-page apps: `try_files {path} /index.html` before `file_server` (see
`routing` and `patterns`).
