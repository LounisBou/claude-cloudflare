# reverse_proxy

Source: caddyserver.com/docs/caddyfile/directives/reverse_proxy

```
reverse_proxy [<matcher>] [<upstreams...>] {
	# backends
	to       <upstreams...>
	dynamic  <module> ...          # a | srv | multi

	# load balancing
	lb_policy       <name> [<options...>]
	lb_retries      <retries>
	lb_try_duration <duration>
	lb_try_interval <interval>
	lb_retry_match  <request-matcher>

	# active health checks
	health_uri          <uri>
	health_upstream     <ip:port>
	health_port         <port>
	health_interval     <interval>
	health_passes       <num>
	health_fails        <num>
	health_timeout      <duration>
	health_method       <method>
	health_status       <status>
	health_request_body <body>
	health_body         <regexp>
	health_follow_redirects
	health_headers {
		<field> [<values...>]
	}

	# passive health checks
	fail_duration     <duration>
	max_fails         <num>
	unhealthy_status  <status>
	unhealthy_latency <duration>
	unhealthy_request_count <num>

	# streaming
	flush_interval     <duration>
	request_buffers    <size>
	response_buffers   <size>
	stream_timeout     <duration>
	stream_close_delay <duration>

	# request and headers
	trusted_proxies [private_ranges] <ranges...>
	header_up   [+|-]<field> [<value|regexp> [<replacement>]]
	header_down [+|-]<field> [<value|regexp> [<replacement>]]
	method  <method>
	rewrite <to>

	# round trip
	transport <name> {           # http or fastcgi
		<options...>
	}

	# response interception
	@name {
		status <code...>
		header <field> [<value>]
	}
	replace_status [<matcher>] <status_code>
	handle_response [<matcher>] {
		<directives...>          # copy_response, copy_response_headers
	}

	proxy_status_name <name>
}
```

## Upstreams

`localhost:4000`, `http://localhost:4000`, `https://example.com`,
`h2c://127.0.0.1`, `unix//var/php.sock`, `unix+h2c//var/grpc.sock`, a port
range `localhost:8001-8006`. Dynamic upstreams: `a` (A/AAAA records), `srv`
(SRV records), `multi` (several sources).

## Load balancing (`lb_policy`)

`random` (default) · `random_choose <n>` · `first` (primary/secondary
failover, in config order) · `round_robin` · `weighted_round_robin
<weights...>` · `least_conn` · `ip_hash` / `client_ip_hash` · `uri_hash` ·
`query [key]` · `header [field]` · `cookie [<name> [<secret>]]` (sticky).

## Headers

- Incoming headers, `Host` included, pass through unchanged, except that
  Caddy sets or extends `X-Forwarded-For` and sets `X-Forwarded-Proto` and
  `X-Forwarded-Host`.
- Incoming `X-Forwarded-*` are ignored unless the peer is in
  `trusted_proxies` (needed behind a CDN such as Cloudflare).
- `header_up` changes what goes to the backend, `header_down` what comes back:
  a bare name sets, `+` adds, `-` deletes (a trailing `*` matches a suffix),
  two arguments do an RE2 search and replace.
- The `http` transport adds `Accept-Encoding: gzip` when the client sent none.
- To an `https://` upstream, Caddy sets `Host` to the upstream's automatically.

## WebSockets

Supported without configuration: the upgrade is performed, then the
connection becomes a two-way tunnel. Such connections close when the config
reloads; `stream_close_delay` and `stream_timeout` control this.

## transport http

Subdirectives, one per line: `read_buffer`, `write_buffer`,
`max_response_header`, `proxy_protocol`, `dial_timeout`, `dial_fallback_delay`,
`response_header_timeout`, `expect_continue_timeout`, `resolvers`, `tls`,
`tls_client_auth`, `tls_insecure_skip_verify`, `tls_curves`, `tls_timeout`,
`tls_trust_pool`, `tls_server_name`, `tls_renegotiation`, `tls_except_ports`,
`keepalive`, `keepalive_interval`, `keepalive_idle_conns`,
`keepalive_idle_conns_per_host`, `versions`, `compression`,
`max_conns_per_host`, `network_proxy`. `transport fastcgi` is what
`php_fastcgi` (see `files`) sets up.

## Examples

```
example.com {
	reverse_proxy localhost:5000
}

example.com {
	reverse_proxy node1:80 node2:80 node3:80 {
		lb_policy first
		health_uri /healthz
		lb_try_duration 5s
	}
}

example.com {
	root /var/www
	reverse_proxy /api/* localhost:5000
	file_server
}

app.example.com {
	reverse_proxy https://example.com
}
```

See also `auth` (`forward_auth`, a preset of `reverse_proxy`) and
`patterns`.
