# TLS: the tls directive

Source: caddyserver.com/docs/caddyfile/directives/tls (and the TLS global
options, see `global-options`)

Automatic HTTPS needs nothing: a site address with a host name gets a managed
certificate. `tls` changes how.

```
tls [internal|force_automate|<email>] | [<cert_file> <key_file>] {
	protocols <min> [<max>]
	ciphers   <cipher_suites...>
	curves    <groups...>
	alpn      <values...>
	load      <paths...>
	ca        <ca_dir_url>
	ca_root   <pem_file>
	key_type  ed25519|p256|p384|rsa2048|rsa4096
	dns       <provider_name> [<params...>]
	propagation_timeout <duration>
	propagation_delay   <duration>
	dns_ttl             <duration>
	dns_challenge_override_domain <domain>
	resolvers <dns_servers...>
	eab       <key_id> <mac_key>
	on_demand
	reuse_private_keys
	client_auth {
		mode                   [request|require|verify_if_given|require_and_verify]
		trust_pool             <module>
		verifier               <module>
	}
	issuer          <issuer_name>  [<params...>]
	get_certificate <manager_name> [<params...>]
	insecure_secrets_log <log_file>
	renewal_window_ratio <ratio>
	force_automate
}
```

## One-line forms

- `tls internal`: certificates from Caddy's own local CA.
- `tls <email>`: the email of the ACME account.
- `tls <cert_file> <key_file>`: your own PEM certificate and key (both).
- `force_automate`: automate the site's certificate even when other managed
  certificates would apply.

## Subdirectives

- `protocols`: min and max TLS versions (default 1.2 to 1.3); change only if
  needed. `ciphers` (TLS 1.3 suites cannot be set), `curves`, `alpn`.
- `load`: folders of PEM certificate and key bundles.
- `ca` / `ca_root`: another ACME CA (Let's Encrypt staging, an internal one)
  and its root.
- `key_type`: only for a specific requirement.
- `dns <provider_name> [<params...>]`: the DNS challenge, through a provider
  plugin from the caddy-dns repositories that the caddy binary must include.
  Needed for wildcard certificates.
- `propagation_timeout` (default 2m, `-1` disables the checks),
  `propagation_delay` (default 0), `dns_ttl`, `resolvers`: DNS challenge
  tuning. `dns_challenge_override_domain`: delegate the challenge by CNAME.
- `eab`: external account binding, for CAs that require it.
- `on_demand`: On-Demand TLS; insecure in production without the
  `on_demand_tls` global option.
- `client_auth`: TLS client authentication. `mode` defaults to
  `require_and_verify` with a `trust_pool`, else `require`; `trust_pool`
  sources: `file`, `inline`, `storage`, `http`, `pki_root`, `pki_intermediate`;
  `verifier leaf` checks against permitted certificates.
- `issuer` (repeatable, for fallback), `get_certificate`.
- `insecure_secrets_log`: writes TLS secrets to a file (NSS key log); a
  security risk, for debugging only.
- `renewal_window_ratio`: when renewal starts, 0 to 1 (default 0.3333).

## Examples

```
example.com {
	tls cert.pem key.pem
}

example.com {
	tls internal
}

*.example.com {
	tls {
		dns cloudflare {env.CLOUDFLARE_API_TOKEN}
	}
}

example.com {
	tls {
		client_auth {
			trust_pool file ../caddy.ca.cer ../root.ca.cer
		}
	}
}
```

## On a machine this plugin manages

- The DNS-01 token lives in the envfile, never in the Caddyfile. `{env.NAME}`
  reads it from the running Caddy's environment (the service's `--envfile` or
  `EnvironmentFile=`, which `caddy-status` checks); `{$NAME}` is substituted
  when the file is parsed (the envfile is loaded for validate and reload).
- A shared `(tls_config)` snippet holding the `tls { dns … }` block, imported
  by every site (`import tls_config`), keeps one copy of it.
- `acme_dns <provider> …` in the global options sets the DNS challenge for
  every site at once (see `global-options`).
