# Caddy digests

Short digests of caddyserver.com/docs (Caddy 2), one per directive family.
`caddy-docs <topic>` prints one; open only the one you need.

| Topic | Covers |
|---|---|
| `caddyfile` | file layout, tokens and quotes, heredocs, comments, addresses, snippets and `import`, named routes, `{$VAR}` and `{env.VAR}` |
| `placeholders` | `{host}`, `{uri}`, `{path}` and every shorthand |
| `matchers` | `*`, `/path`, `@name`; `path`, `host`, `header`, `method`, `query`, `remote_ip`, `client_ip`, `not`, `expression`… |
| `directives` | every standard directive, and the order Caddy runs them in |
| `reverse-proxy` | `reverse_proxy`: upstreams, load balancing, health checks, headers, websockets, `transport http` |
| `routing` | `handle`, `handle_path`, `route`, `redir`, `rewrite`, `uri`, `try_files`, `respond`, `abort`, `error`, `handle_errors` |
| `headers` | `header` (security headers, Cache-Control, CORS), `request_header` |
| `auth` | `basic_auth`, `forward_auth` |
| `encode` | `encode` (gzip, zstd); caching through headers |
| `tls` | the `tls` directive: internal, own certificates, DNS challenge, client auth |
| `files` | `root`, `file_server`, `php_fastcgi` |
| `logging` | `log`, `log_skip`, `log_append`, `log_name` |
| `global-options` | the global options block: `admin`, `email`, `acme_dns`, `auto_https`, `servers`, `trusted_proxies` |
| `patterns` | static site, proxy, PHP, www redirects, wildcard certificates, single-page apps |

## Editing a site with this plugin

- `caddy-sites` lists the blocks, `caddy-site <host>` prints one as written.
- `caddy-site-set <host> --body-file <file>`: the file holds the block's
  directives only, without the address and braces. The block of the host is
  replaced, or a new `https://<host>` block appended; the rest of the file is
  kept byte for byte.
- Each change is copied first, validated (`caddy validate`), reloaded
  (`caddy reload`, never a stop or a restart), then every site is probed
  again: a site that stops answering puts the old file back.
- A block of several addresses or a wildcard block is edited by hand, then
  `caddy-reload`.
- Secrets (the DNS-01 token) stay in the envfile: `{env.NAME}` or `{$NAME}`
  in the Caddyfile, never the value.
