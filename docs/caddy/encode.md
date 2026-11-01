# Compression: encode

Source: caddyserver.com/docs/caddyfile/directives/encode

```
encode [<matcher>] [<formats...>] {
	gzip [<level>]
	zstd [<level>]
	minimum_length <length>
	match <inline_response_matcher>
}
```

- Formats: with none given, `zstd` (preferred) and `gzip`. With several, the
  client's `Accept-Encoding` chooses; without a q-factor preference the first
  listed wins. Bare `encode` is `encode zstd gzip`.
- `gzip [<level>]`: Gzip, at an optional level.
- `zstd [<level>]`: Zstandard; level `default` (about zstd level 3),
  `fastest`, `better` or `best`.
- `minimum_length`: the smallest response encoded, 512 bytes by default.
  Server-sent events (`text/event-stream`) and responses with
  `Incremental: ?1` skip it and stream at once.
- `match`: a response matcher limiting what is encoded.

Encoded by default when the Content-Type is one of: `text/*`; `font/*` and
font types (EOT, OpenType, OTF, TrueType, TTF); JavaScript, JSON (including
`application/vnd.api+json`, `application/ld+json`), GraphQL JSON, GeoJSON,
WebAssembly; XML, XHTML, RSS, Atom, `application/x-protobuf`;
`image/svg+xml`, `image/vnd.microsoft.icon`, `image/x-icon`;
`multipart/mixed`, `multipart/bag`, `application/manifest+json`,
`application/vnd.ms-fontobject`, and legacy CGI/Perl types.

```
encode gzip

encode zstd gzip

example.com {
	root /srv
	encode
	file_server
}
```

Precompressed files on disk are served by `file_server`'s `precompressed`
(see `files`), not by `encode`.

Caching: Caddy's standard directives have no response cache; set
`Cache-Control` with `header` (see `headers`) and let the browser and the CDN
cache.
