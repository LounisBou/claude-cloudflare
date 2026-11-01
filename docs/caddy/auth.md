# Authentication: basic_auth, forward_auth

Sources: caddyserver.com/docs/caddyfile/directives/basic_auth,
caddyserver.com/docs/caddyfile/directives/forward_auth

## basic_auth

```
basic_auth [<matcher>] [<hash_algorithm> [<realm>]] {
	<username> <hashed_password>
	...
}
```

- `<hash_algorithm>`: `bcrypt` (default) or `argon2id`.
- Passwords are hashes, never plain text: make one with
  `caddy hash-password` before writing it here.
- Usernames and hashes may use global placeholders such as `{env.*}`,
  resolved when the config loads: keep a hash in the envfile, not in the
  Caddyfile.
- Missing or wrong credentials answer 401. After a login
  `{http.auth.user.id}` holds the user name.
- Basic auth is not secure over plain HTTP: serve it over HTTPS.
- Named `basicauth` before v2.8.0.

```
example.com {
	basic_auth {
		bob <bcrypt hash>
	}
	reverse_proxy localhost:8080
}

example.com {
	basic_auth /secret/* {
		bob <bcrypt hash>
	}
}

example.com {
	basic_auth argon2id {
		bob <argon2id hash>
	}
}
```

## forward_auth

```
forward_auth [<matcher>] [<upstreams...>] {
	uri          <to>
	copy_headers <fields...> {
		<fields...>
	}
}
```

- Caddy sends a `GET` sub-request with the URI rewritten to `uri` (the
  gateway's verification endpoint) to the upstreams.
- A 2xx answer lets the request through, `copy_headers` copied from the
  answer onto it (`Before>After` renames). Any other answer goes back to the
  client as it is, usually a redirect to the gateway's login page.
- Any `reverse_proxy` subdirective is accepted: `forward_auth` is a preset of
  `reverse_proxy` (`method GET`, the URI rewritten, `X-Forwarded-Method` and
  `X-Forwarded-Uri` added, `handle_response` on 2xx copying the headers with
  `request_header`). Start from that expanded form when a gateway does not fit.

Authelia, as the page shows it (the gateway on its own site):

```
# Serve the authentication gateway itself
auth.example.com {
	reverse_proxy authelia:9091
}

# Serve your app
app1.example.com {
	forward_auth authelia:9091 {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
	}
	reverse_proxy app1:8080
}
```

Tailscale:

```
forward_auth unix//run/tailscale.nginx-auth.sock {
	uri /auth
	header_up Remote-Addr {remote_host}
	header_up Remote-Port {remote_port}
	header_up Original-URI {uri}
	copy_headers {
		Tailscale-User>X-Webauth-User
		Tailscale-Name>X-Webauth-Name
		Tailscale-Login>X-Webauth-Login
		Tailscale-Tailnet>X-Webauth-Tailnet
		Tailscale-Profile-Picture>X-Webauth-Profile-Picture
	}
}
```

See also: `remote_ip` / `client_ip` matchers (see `matchers`) to allow or
refuse by address, and `tls` `client_auth` for client certificates.
