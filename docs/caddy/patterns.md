# Common patterns

Source: caddyserver.com/docs/caddyfile/patterns

## Static files

```
example.com {
	root /var/www
	file_server
}
```

## Reverse proxy

```
example.com {
	reverse_proxy localhost:5000
}

example.com {
	root /var/www
	reverse_proxy /api/* localhost:5000
	file_server
}
```

## PHP

```
example.com {
	root /srv/public
	encode
	php_fastcgi localhost:9000
	file_server
}
```

## www

Add `www.`:

```
example.com {
	redir https://www.{host}{uri}
}

www.example.com {
}
```

Remove `www.`:

```
www.example.com {
	redir https://example.com{uri}
}

example.com {
}
```

## Trailing slashes

```
example.com {
	rewrite /add     /add/
	rewrite /remove/ /remove
}

example.com {
	redir /add     /add/
	redir /remove/ /remove
}
```

The first enforces them internally, the second with a redirect.

## Wildcard certificate, one handle per subdomain

```
*.example.com {
	tls {
		dns <provider_name> [<params...>]
	}

	@foo host foo.example.com
	handle @foo {
		respond "Foo!"
	}

	@bar host bar.example.com
	handle @bar {
		respond "Bar!"
	}

	# Fallback for otherwise unhandled domains
	handle {
		abort
	}
}
```

The plugin does not edit a wildcard block: change it by hand, then
`caddy-reload`.

## Single-page apps

```
example.com {
	root /srv
	encode
	try_files {path} /index.html
	file_server
}
```

With an API beside it, the same in a fallback `handle` after
`handle /api/* { reverse_proxy backend:8000 }` (see `routing`).

## Caddy behind another Caddy (or a proxy)

The back instance trusts the front one's address for client-IP headers:

```
{
	servers {
		trusted_proxies static private_ranges
	}
}

http://foo.example.com {
	reverse_proxy foo-app:8080
}
```

## A site of this machine, as the plugin writes it

```
https://app.example.com {
	import tls_config
	log
	reverse_proxy 127.0.0.1:8080
}
```

`caddy-site-set app.example.com --body-file <file>` takes the three inner
lines; websockets need nothing more (see `reverse-proxy`).
