# Directives: the list and their order

Source: caddyserver.com/docs/caddyfile/directives

## Standard directives

| Directive | Description | Digest |
|---|---|---|
| `abort` | aborts the HTTP request | `routing` |
| `acme_server` | an embedded ACME server | |
| `basic_auth` | enforces HTTP Basic Authentication | `auth` |
| `bind` | customize the server's socket address | |
| `encode` | encodes (usually compresses) responses | `encode` |
| `error` | trigger an error | `routing` |
| `file_server` | serve files from disk | `files` |
| `forward_auth` | delegate authentication to an external service | `auth` |
| `fs` | set the file system to use for file I/O | |
| `handle` | a mutually-exclusive group of directives | `routing` |
| `handle_errors` | defines routes for handling errors | `routing` |
| `handle_path` | like handle, but strips path prefix | `routing` |
| `header` | sets or removes response headers | `headers` |
| `import` | include snippets or files | `caddyfile` |
| `intercept` | intercept responses written by other handlers | |
| `invoke` | invoke a named route | `caddyfile` |
| `log` | enables access/request logging | `logging` |
| `log_append` | append a field to the access log | `logging` |
| `log_skip` | skip access logging for matched requests | `logging` |
| `log_name` | override the logger name(s) to write to | `logging` |
| `map` | maps an input value to one or more outputs | |
| `method` | change the HTTP method internally | |
| `metrics` | configures the Prometheus metrics exposition endpoint | |
| `php_fastcgi` | serve PHP sites over FastCGI | `files` |
| `push` | push content to the client using HTTP/2 server push | |
| `redir` | issues an HTTP redirect to the client | `routing` |
| `request_body` | manipulates request body | |
| `request_header` | manipulates request headers | `headers` |
| `respond` | writes a hard-coded response to the client | `routing` |
| `reverse_proxy` | a powerful and extensible reverse proxy | `reverse-proxy` |
| `rewrite` | rewrites the request internally | `routing` |
| `root` | set the path to the site root | `files` |
| `route` | a group of directives treated literally as single unit | `routing` |
| `templates` | execute templates on the response | |
| `timeouts` | set idle read and write timeouts | |
| `tls` | customize TLS settings | `tls` |
| `tracing` | integration with OpenTelemetry tracing | |
| `try_files` | rewrite that depends on file existence | `routing` |
| `uri` | manipulate the URI | `routing` |
| `vars` | set arbitrary variables | |

A directive without a digest here: read its page,
caddyserver.com/docs/caddyfile/directives/<name>, before using it.

## Directive order

Directives at one level of a site block are sorted into this order, whatever
the order they are written in; `route` keeps the written order, `order` in the
global options moves one.

```
tracing
map
vars
fs
root
log_append
log_skip
log_name
header
copy_response_headers # only in reverse_proxy's handle_response block
request_body
timeouts
redir
# incoming request manipulation
method
rewrite
uri
try_files
# middleware handlers; some wrap responses
basic_auth
forward_auth
request_header
encode
push
intercept
templates
# special routing & dispatching directives
invoke
handle
handle_path
route
# handlers that typically respond to requests
abort
error
copy_response # only in reverse_proxy's handle_response block
respond
metrics
reverse_proxy
php_fastcgi
file_server
acme_server
```

So `redir` runs before `reverse_proxy` and `try_files` before `file_server`,
wherever they are written: use `handle` blocks or `route` to control it.
