# Logging: log, log_skip, log_append, log_name

Sources: caddyserver.com/docs/caddyfile/directives/log,
caddyserver.com/docs/caddyfile/directives (the directive table)

## log (access logs of a site)

```
log [<logger_name>] {
	hostnames <hostnames...>
	no_hostname
	output <writer_module> ...
	format <encoder_module> ...
	level  <level>
	sampling {
		interval   <duration>
		first      <number>
		thereafter <number>
	}
}
```

When `log` is present, every request to the site is logged by default.

- `output`: `stderr` (default), `stdout`, `discard`,
  `file <filename> { roll_size, roll_keep, roll_keep_for, roll_local_time, roll_at }`,
  `net <address> { dial_timeout, soft_start }`.
- `format`: `console` (default when stderr is a terminal) or `json`
  (otherwise); `filter { … }` with `delete`, `rename`, `replace`, `ip_mask`,
  `query`, `cookie`, `set_cookie`, `regexp`, `hash`; `append { … }`.
- `level`: `INFO` by default.
- File rolling defaults: `roll_size 100MiB`, `roll_keep 10`,
  `roll_keep_for 2160h` (90 days).

```
example.com {
	log
}

example.com {
	log {
		output file /var/log/access.log {
			roll_size 1gb
			roll_keep 5
			roll_keep_for 720h
		}
	}
}

example.com {
	log {
		format filter {
			request>headers>User-Agent delete
		}
	}
}
```

## Related directives

| Directive | Does |
|---|---|
| `log_skip` | skip access logging for the matched requests |
| `log_append` | append a field to the access log |
| `log_name` | override the logger name(s) to write to |

```
log_skip [<matcher>]

example.com {
	root /srv

	log
	log_skip /static*

	file_server
}
```

## Caddy's own logs

The process log (not the access log) is set in the global options:
`log [name] { output … format … level … include … exclude … }` (see
`global-options`). Under launchd or systemd it goes where the service sends
stderr; the plugin never restarts the service to change it.
