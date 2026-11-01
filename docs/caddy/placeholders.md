# Placeholders

Source: caddyserver.com/docs/caddyfile/concepts (Placeholders)

Placeholders are written in braces: `{http.request.host}`. `\{` escapes an
opening brace. What is available depends on the context: HTTP placeholders are
not available in `tls` configuration. In the Caddyfile these shorthands stand
for the full names:

| Shorthand | Full name |
|---|---|
| `{host}` | `{http.request.host}` |
| `{hostport}` | `{http.request.hostport}` |
| `{port}` | `{http.request.port}` |
| `{scheme}` | `{http.request.scheme}` |
| `{method}` | `{http.request.method}` |
| `{uri}` | `{http.request.uri}` |
| `{%uri}` | `{http.request.uri_escaped}` |
| `{path}` | `{http.request.uri.path}` |
| `{%path}` | `{http.request.uri.path_escaped}` |
| `{path.*}` | `{http.request.uri.path.*}` |
| `{dir}` | `{http.request.uri.path.dir}` |
| `{file}` | `{http.request.uri.path.file}` |
| `{file.base}` | `{http.request.uri.path.file.base}` |
| `{file.ext}` | `{http.request.uri.path.file.ext}` |
| `{query}` | `{http.request.uri.query}` |
| `{%query}` | `{http.request.uri.query_escaped}` |
| `{?query}` | `{http.request.uri.prefixed_query}` |
| `{query.*}` | `{http.request.uri.query.*}` |
| `{header.*}` | `{http.request.header.*}` |
| `{cookie.*}` | `{http.request.cookie.*}` |
| `{labels.*}` | `{http.request.host.labels.*}` |
| `{remote}` | `{http.request.remote}` |
| `{remote_host}` | `{http.request.remote.host}` |
| `{remote_port}` | `{http.request.remote.port}` |
| `{client_ip}` | `{http.vars.client_ip}` |
| `{orig_method}` | `{http.request.orig_method}` |
| `{orig_uri}` | `{http.request.orig_uri}` |
| `{orig_path}` | `{http.request.orig_uri.path}` |
| `{orig_dir}` | `{http.request.orig_uri.path.dir}` |
| `{orig_file}` | `{http.request.orig_uri.path.file}` |
| `{orig_query}` | `{http.request.orig_uri.query}` |
| `{orig_?query}` | `{http.request.orig_uri.prefixed_query}` |
| `{re.*}` | `{http.regexp.*}` |
| `{vars.*}` | `{http.vars.*}` |
| `{rp.*}` | `{http.reverse_proxy.*}` |
| `{upstream_hostport}` | `{http.reverse_proxy.upstream.hostport}` |
| `{resp.*}` | `{http.intercept.*}` |
| `{err.*}` | `{http.error.*}` |
| `{file_match.*}` | `{http.matchers.file.*}` |
| `{tls_cipher}` | `{http.request.tls.cipher_suite}` |
| `{tls_version}` | `{http.request.tls.version}` |
| `{tls_client_fingerprint}` | `{http.request.tls.client.fingerprint}` |
| `{tls_client_issuer}` | `{http.request.tls.client.issuer}` |
| `{tls_client_serial}` | `{http.request.tls.client.serial}` |
| `{tls_client_subject}` | `{http.request.tls.client.subject}` |
| `{tls_client_certificate_pem}` | `{http.request.tls.client.certificate_pem}` |
| `{tls_client_certificate_der_base64}` | `{http.request.tls.client.certificate_der_base64}` |

Error routes (`handle_errors`) add `{err.status_code}`, `{err.status_text}`,
`{err.message}`, `{err.trace}` and `{err.id}`.

Not placeholders: `{$VAR}` (an environment variable substituted when the
Caddyfile is parsed) and `{env.VAR}` / `{file./path}` (read at runtime); see
`caddyfile`.

Examples:

```
redir https://example.com{uri} permanent
rewrite /index.php?{query}&p={path}
respond "{err.status_code} {err.status_text}"
```
