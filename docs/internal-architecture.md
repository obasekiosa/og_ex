# Internal architecture

This document describes the implementation boundaries maintainers and adapter
authors need to understand. It is not a second setup guide; application usage
belongs in the README and public API reference.

```
Initial                       HIT                         MISS
GET /posts/42                 GET TOKEN                   GET TOKEN
    |                             |                           |
    v                             v                           v
Controller → ConfigBuilder    Dispatcher                  Dispatcher
    |                             |                           |
    v                             v                           v
Head inject                 Card.load                   Card.load
    |                             |                           |
    v                             v                           v
HTML                        Cache HIT → 200             Cache MISS → Takumi → 200
```

## Controller dispatch

`OgEx.Controller.__using__/1` imports the `og_card` declaration macros,
installs an early query-image plug, removes Phoenix's imported `render/3`, and
defines a controller-local replacement.

Each declaration compiles into controller-owned metadata and loader dispatch:

```elixir
controller.__og_ex_declaration__(action)
controller.__og_ex_load__(action, conn, params)
```

The generated loader dispatch calls an explicit declaration loader when one
exists and otherwise delegates to `Card.load/2`.

For a normal declared request:

1. Phoenix calls the page action.
2. The action calls its ordinary `render/3` without an `:og` assign.
3. the controller replacement finds the declaration through
   `conn.private.phoenix_action`;
4. `OgEx.ConfigBuilder.build/4` creates an `OgEx.Config`;
5. `OgEx.Head.put_config/2` registers metadata injection;
6. Phoenix renders the normal template.

For a query image request, the generated controller plug checks `__og_ex`,
loads image assigns, sends the image, and halts before Phoenix invokes the
action.

The legacy `render(..., og: declaration)` branch remains supported. In that
branch the controller action has already run before dispatch reaches
`render/3`.

## Path integrations

`OgEx.Dispatcher` is shared by both path integration options.

`OgEx.Router.og_ex_routes/1` adds a final unmatched-path route. Application
routes therefore take priority. The handler recognizes
`opengraph-image/SIGNATURE` and `twitter-image/SIGNATURE`, recovers the original
page path, resolves it with `Phoenix.Router.route_info/4`, and dispatches the
controller declaration.

The endpoint alternative:

```elixir
plug OgEx, router: MyAppWeb.Router
```

performs the candidate check before Phoenix routing. Requests that do not
resolve to an OgEx declaration pass through unchanged.

These integrations are mutually exclusive. Endpoint initialization inspects a
compiled configured router and logs a warning when its route table already
contains `OgEx.Router`.

Before loading, the dispatcher stores trusted originating controller, action,
role, page path, signature, and normalized parameters through
`OgEx.Request.put_origin/6`. Card code accesses those values through stable
top-level helpers rather than the internal Phoenix handler action.

## Configuration strategies

Generated cards use:

```elixir
%OgEx.Config{
  strategy: {:generated, CardModule},
  card: CardModule,
  assigns: assigns,
  width: width,
  height: height,
  format: format
}
```

Direct images use `strategy: :existing` and retain verified resources or
normalized external sources in `:image` and `:twitter_image`.

Consumers branch on `:strategy`; optional fields should not be used to infer
the lifecycle.

## Signatures

The public URL carries a 128-bit truncated HMAC encoded as 22 base64url
characters. The signature binds:

- deterministic image identity;
- Open Graph or Twitter image role;
- request path.

Path mode places the signature after an `opengraph-image` or `twitter-image`
suffix. Query mode places it in `__og_ex`. Generated cards emit distinct
role-bound URLs even when both roles render the same card.

The key is domain-separated from Phoenix's `secret_key_base`. Card assigns,
private paths, and metadata are not serialized into the URL.

`OgEx.ConfigBuilder.verify/2` rebuilds role candidates and compares equal-length
signatures with `Plug.Crypto.secure_compare/2`.

## Head injection

`OgEx.Head` registers a `Plug.Conn.register_before_send/2` callback.
`OgEx.Meta.to_html/1` escapes dynamic values and creates the tag set.
The callback inserts tags before the first case-insensitive closing `</head>`.

Non-HTML, streaming, compressed, or otherwise unsupported response shapes are
left unchanged.

## Generated-card pipeline

`OgEx.ImageResponse` performs:

1. signature verification;
2. `OgEx.HTML.render/1`;
3. `OgEx.Resources.load/2`;
4. generated-image cache lookup;
5. renderer invocation on a miss;
6. cache insertion after a complete successful render;
7. immutable response headers.

`OgEx.HTML` converts HEEx safe data to a binary and wraps it in a complete
viewport-sized document. Card-local `<style>` elements remain in that document.

`OgEx.Resources` uses Floki to discover unique `<img src>` values. Each resource
is normalized and loaded, and the returned content fingerprints are sorted for
cache identity.

## Image-source boundary

`OgEx.Image.normalize/2` classifies source values and constrains local paths.
Path validation rejects:

- absolute paths;
- null bytes;
- `.` and `..` segments;
- symlinks at any traversed segment;
- missing or non-regular files.

The default private root is `priv/og_ex` inside the endpoint's OTP application.
The public root is that application's `priv/static`.

`OgEx.Image.load/2` calls the configured resource loader and emits resource
telemetry.

## Byte verification

`OgEx.ResourceLoader.Default.from_bytes/2` calls
`OgEx.Native.inspect_image/1`. The NIF detects PNG, JPEG, WebP, GIF, and SVG
from content, decodes intrinsic dimensions with Takumi's image stack, and
rejects unsupported or zero-sized images.

Elixir then applies maximum dimension and pixel limits, checks SVG active
content, and calculates the SHA-256 content fingerprint.

## Remote loading

`OgEx.ResourceLoader.Remote` validates every request and redirect hop:

1. parse the URI;
2. require HTTPS unless HTTP is explicitly enabled;
3. match the hostname allowlist;
4. resolve IPv4 and IPv6 answers;
5. reject the hostname if any answer is unsafe;
6. rewrite the connection URL to one validated address;
7. retain the original hostname for the Host header, TLS SNI, and certificate
   verification;
8. stream under the byte limit and total timeout;
9. validate response media type and bytes.

The loader does not reuse headers from the page request. Only conditional ETag
and Last-Modified validators retained for the same resource are sent.

## Caches

### Final images

`OgEx.Cache.ETS` is a public concurrent-read ETS table owned by a GenServer.
The final key contains the card, version, viewport, format, and resource
fingerprints.

The cache behaviour deliberately uses `{:ok, value} | :error`, matching
`Map.fetch/2`. “Miss” appears in telemetry naming, not as a return value.

### Remote resources

`OgEx.ResourceCache` is a protected concurrent-read ETS table. Entries contain
an expiry time, verified resource, and encoded byte count. Expired entries are
retained for conditional revalidation.

Insertion is serialized through the GenServer so entry and byte bounds can be
updated consistently. When a bound would be exceeded, the table is cleared.

## Native renderer

The Elixir-to-Rust boundary consists of:

```elixir
OgEx.Native.render_html(html, options)
OgEx.Native.inspect_image(bytes)
```

Both NIFs run on Rustler's dirty CPU scheduler.

The render options map contains primitive viewport values, font binaries, and
image binaries. Rust:

1. parses HTML with Takumi;
2. extracts and parses card-local stylesheets;
3. registers fonts;
4. decodes registered image resources;
5. performs layout and painting;
6. writes PNG, JPEG, WebP, or SVG bytes;
7. copies the completed result into an Erlang-managed binary.

Rust performs no filesystem or HTTP operations.

## Response and error semantics

Valid generated and private image responses receive one-year immutable caching
and an ETag.

Invalid signatures return an empty `404`. Resource, HTML, or renderer failures
return an empty `503` with `Cache-Control: no-store`. Failure responses are not
inserted into the final cache.

Direct local resources are currently loaded while the HTML configuration is
built. Missing or invalid files therefore raise `ArgumentError` at that
boundary. The planned lazy failure isolation is documented in
`todo/image_plan.md`
and must not be described as current behavior.

## Telemetry

The implementation emits:

- `[:og_ex, :resource, :stop]`;
- `[:og_ex, :cache, :hit]`;
- `[:og_ex, :cache, :miss]`;
- `[:og_ex, :render, :stop]`;
- `[:og_ex, :render, :exception]`.

Do not add complete signed URLs, query strings, private paths, request headers,
or image bodies to telemetry metadata.
