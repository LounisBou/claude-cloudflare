# Global options

Source: caddyserver.com/docs/caddyfile/options

The global options block is optional and must be the very first block of the
Caddyfile, with no address: `{ … }`. It holds options only, no site
directives.

## General

```
debug
http_port    <port>
https_port   <port>
default_bind <hosts...>
order <dir1> first|last|[before|after <dir2>]
storage <module_name> {
	<options...>
}
storage_clean_interval <duration>
admin   off|<addr> {
	origins <origins...>
	enforce_origin
}
persist_config off
log [name] {
	output  <writer_module> ...
	format  <encoder_module> ...
	level   <level>
	include <namespaces...>
	exclude <namespaces...>
}
grace_period   <duration>
shutdown_delay <duration>
metrics {
	per_host
	observe_catchall_hosts
	otlp
}
```

- `admin`: the admin API address, `localhost:2019` by default. `off` disables
  it, and with it every reload: `caddy reload` (and this plugin) need it.
  The config's `caddy.admin` must name the same address.
- `order`: places a handler directive first, last, or before/after another;
  needed for third-party handler directives.
- `debug`: verbose logs, for troubleshooting.

## TLS

```
auto_https off|disable_redirects|ignore_loaded_certs|disable_certs
tls_automate_names <names...>
email <yours>
default_sni <name>
fallback_sni <name>
local_certs
skip_install_trust
acme_ca <directory_url>
acme_ca_root <pem_file>
acme_eab {
	key_id <key_id>
	mac_key <mac_key>
}
acme_dns <provider> ...
dns <provider> ...
tls_resolvers <resolvers...>
ech <public_names...> {
	dns <provider> ...
}
on_demand_tls {
	ask        <endpoint>
	permission <module>
}
key_type ed25519|p256|p384|rsa2048|rsa4096
cert_issuer <name> ...
renew_interval <duration>
cert_lifetime  <duration>
ocsp_interval  <duration>
ocsp_stapling off
renewal_window_ratio <ratio>
preferred_chains [smallest] {
	root_common_name <common_names...>
	any_common_name  <common_names...>
}
```

- `auto_https`: `off` disables certificates and HTTP→HTTPS redirects;
  `disable_redirects` only the redirects; `disable_certs` only the
  certificates; `ignore_loaded_certs` automates names also on loaded
  certificates.
- `email`: the ACME account's address; set it.
- `acme_dns`: the DNS challenge provider for every ACME transaction; the
  caddy binary must include that provider's plugin.

## Servers

```
servers [<listener_address>] {
	name <name>
	listener_wrappers {
		<listener_wrappers...>
	}
	timeouts {
		read_body       <duration>
		read_body_idle  <duration> [<min_rate>]
		read_header     <duration>
		write           <duration>
		write_idle      <duration> [<min_rate>]
		write_max_chunk <size>
		idle            <duration>
	}
	keepalive_interval <duration>
	keepalive_idle     <duration>
	keepalive_count    <number>
	0rtt off
	trusted_proxies <module> ...
	trusted_proxies_strict
	trusted_proxies_unix
	client_ip_headers <headers...>
	trace
	max_header_size <size>
	enable_full_duplex
	expected_underscore_headers <headers...>
	expected_dot_headers        <headers...>
	log_credentials
	protocols [h1|h2|h2c|h3]
	strict_sni_host [on|insecure_off]
}
```

- `trusted_proxies`: the proxies (CIDRs) whose client-IP headers are trusted,
  none by default: `trusted_proxies static private_ranges`, or the CDN's
  ranges when Cloudflare is in front, so `client_ip` is the visitor's.

The page also documents `filesystem`, `pki` and `events` blocks.
