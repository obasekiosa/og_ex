# OgEx image support plan

## Goal

OgEx should support two related image workflows:

1. Images embedded inside a generated HEEx card.
2. Existing images used directly as `og:image` or `twitter:image`, without
   invoking Takumi.

The implementation should preserve the existing controller experience. Public
and remote images should use ordinary HTML and URLs. Private application files
need only a small helper because they intentionally have no browser-accessible
URL.

This work is planned for OgEx `0.2.0`. It extends the existing API without
removing the `og: CardModule` form.

## Proposed user API

### Images inside generated cards

A public Phoenix static asset uses an ordinary root-relative URL:

```heex
<img src="/images/logo.png" width="160" height="160" />
```

An external image also uses ordinary HTML:

```heex
<img
  src="https://cdn.example.com/products/cover.webp"
  width="480"
  height="320"
/>
```

A private packaged asset uses a helper to distinguish it from a public URL:

```heex
<img
  src={OgEx.private_asset("backgrounds/confidential.png")}
  width="1200"
  height="630"
/>
```

OgEx resolves these resources and supplies their bytes to Takumi before
rendering. The native renderer never receives unrestricted filesystem or
network access.

### Use an existing public image directly

```elixir
render(conn, :about,
  og: [
    title: "About us",
    description: "Meet the team",
    image: "/images/about-og.png",
    image_alt: "The Acme team"
  ]
)
```

OgEx resolves the image from the application's `priv/static` directory, reads
its media type and dimensions, and emits its cache-busted Phoenix static URL.
`Plug.Static` serves the image normally. Takumi and the generated-image cache
are not involved.

### Use an existing external image directly

```elixir
render(conn, :show,
  post: post,
  og: [
    title: post.title,
    description: post.summary,
    image: post.cover_url
  ]
)
```

The external URL is emitted directly in the metadata. OgEx does not proxy it
unless the URL is used inside a generated card and must therefore be loaded for
Takumi.

External direct images should accept optional explicit dimensions:

```elixir
og: [
  title: post.title,
  image: post.cover_url,
  image_width: 1200,
  image_height: 630
]
```

OgEx should not make a remote request during every HTML page response merely to
discover optional metadata dimensions.

### Use an existing private image directly

```elixir
render(conn, :report,
  report: report,
  og: [
    title: report.title,
    image: {:private, "reports/default-og.png"}
  ]
)
```

OgEx reads the file from an allowlisted private root and exposes it through a
signed image URL. The image is not passed through Takumi because it is already
encoded.

"Private" means the file is not generally served by `Plug.Static`. The signed
URL must still be publicly fetchable because social crawlers do not have the
application user's authenticated session.

### Separate Open Graph and Twitter images

One image remains the default for both metadata families:

```elixir
og: [
  title: "A release",
  image: "/images/release-og.png"
]
```

A separate Twitter image can be selected when needed:

```elixir
og: [
  title: "A release",
  image: "/images/release-og.png",
  twitter_image: "/images/release-twitter.png",
  twitter_card: "summary"
]
```

## Image-source model

Normalize every accepted input into a private internal structure:

```elixir
%OgEx.Image.Source{
  type: :public | :private | :remote | :data,
  reference: "/images/about-og.png",
  content_type: "image/png",
  width: 1200,
  height: 630,
  fingerprint: "sha256..."
}
```

The normalized source is shared by metadata generation, signed responses,
resource loading, cache identity, and renderer input.

## Controller and configuration changes

`og:` will accept either the existing generated-card module:

```elixir
og: MyAppWeb.PostOgCard
```

or image metadata:

```elixir
og: [
  title: "...",
  image: "/images/card.png"
]
```

The controller normalizes both forms before selecting the HTML or image
response. Passing a card module remains fully backwards compatible.

`OgEx.Config` should stop assuming every response has a card module. It should
represent the response strategy explicitly, for example:

```elixir
strategy: {:generated, CardModule} | {:existing, OgEx.Image.Source.t()}
```

## Public static files

For a root-relative source such as `/images/card.png`, OgEx should:

1. Determine the host application's OTP app and Phoenix endpoint.
2. Resolve the path under that application's configured `priv/static` root.
3. Canonicalize the path and reject traversal or symlink escapes.
4. Verify the file signature and supported format.
5. Read its dimensions.
6. Ask the endpoint for the digested production static path when available.
7. Construct an absolute URL using the endpoint scheme and host.
8. Let the application's existing `Plug.Static` serve the response.

Supported direct files should initially include PNG, JPEG, WebP, GIF, and SVG.
The documentation must note that social-platform SVG support is inconsistent
and recommend PNG for maximum compatibility.

## Private local files

Applications configure a private root:

```elixir
config :og_ex,
  otp_app: :my_app,
  private_asset_root: "priv/og_ex"
```

Private resolution must:

- accept only paths relative to the configured root;
- reject absolute paths, `..` traversal, null bytes, and symlink escapes;
- verify the image signature rather than trusting the extension;
- calculate a content digest for the signature, ETag, and cache identity;
- return structured errors for missing, unreadable, or invalid files.

The existing signed same-route response can initially serve private bytes.
When OgEx gains dedicated image routes, private images should migrate to that
handler without changing the public controller API.

Successful private responses should include:

```text
Content-Type: image/png
Cache-Control: public, max-age=31536000, immutable
ETag: "<content fingerprint>"
```

## Generated-card resource loading

After evaluating a card's HEEx, OgEx should:

1. Parse the resulting HTML.
2. Discover supported `<img src>` and CSS image references.
3. Normalize every reference into an image source.
4. Resolve each source through the configured resource loader.
5. Calculate stable resource fingerprints.
6. Pass a map of original source strings to verified image bytes into the NIF.
7. Register each byte buffer with Takumi under its original source string.
8. Render the final PNG, JPEG, WebP, or SVG.

Takumi already supports registered image resources and data URLs. OgEx should
use that interface rather than granting the NIF network access.

The first iteration must support `<img src>`. CSS `url(...)`, `srcset`, and
`<picture>` can follow after the base loader and security model are stable.

## Resource-loader behaviour

Introduce a replaceable behaviour:

```elixir
defmodule OgEx.ResourceLoader do
  @callback load(OgEx.Image.Source.t(), keyword()) ::
              {:ok, OgEx.Image.Resource.t()} | {:error, term()}
end
```

The default loader handles public, private, remote, and data sources.

```elixir
config :og_ex,
  resource_loader: OgEx.ResourceLoader.Default
```

Applications can replace it for authenticated object storage, custom HTTP
clients, test fixtures, or a distributed resource cache.

## Remote images

Remote fetching is used only when an external image appears inside a generated
card. A direct external `og:image` remains a direct URL.

Suggested configuration:

```elixir
config :og_ex,
  remote_images: [
    enabled: true,
    allowed_hosts: ["cdn.example.com", "*.cloudfront.net"],
    max_bytes: 5_000_000,
    connect_timeout: 2_000,
    receive_timeout: 5_000,
    max_redirects: 2
  ]
```

Remote fetching is disabled unless explicitly enabled. When enabled, the
default host policy is deny-by-default.

### Wildcard host access

Applications may explicitly allow every external hostname:

```elixir
config :og_ex,
  remote_images: [
    enabled: true,
    allowed_hosts: ["*"]
  ]
```

When `allowed_hosts` contains `"*"`, `OgEx.Application` must log one prominent
warning during application startup:

```text
OgEx remote image loading allows all external hosts. This increases the SSRF
attack surface. Prefer an explicit allowed_hosts list in production.
```

The warning should be emitted once per application start, not once per render.
Wildcard host access disables only hostname allowlisting. It must **not**
disable IP validation, redirect validation, HTTPS enforcement, timeouts,
content limits, media verification, or any other SSRF protection.

### Remote security requirements

The default loader must:

- allow HTTPS by default and require an explicit option for plain HTTP;
- reject loopback, private, link-local, multicast, unspecified, and reserved
  addresses;
- reject cloud metadata addresses;
- resolve and validate every address before connecting;
- revalidate the destination after every redirect;
- enforce a small redirect limit;
- use strict connect, response, and total timeouts;
- enforce a maximum encoded response size while streaming;
- limit decoded dimensions and pixel count;
- accept only supported image media types;
- verify magic bytes or SVG structure instead of trusting `Content-Type`;
- never forward cookies, authorization, or request headers from the page
  request;
- return structured errors without caching failed or partial resources.

An explicit hostname allowlist is not a replacement for IP validation because
DNS answers and redirect targets can still resolve to unsafe destinations.

## SVG handling

SVG resources require special care:

- reject scripts, event handlers, foreign objects, and active content;
- reject or remove external network references;
- prevent nested local filesystem reads;
- enforce input byte and rendered-dimension limits;
- use Takumi's existing safe SVG path where possible;
- document that direct SVG social previews are not portable across platforms.

Raster output may safely include a sanitized SVG source. SVG output should
embed safe vector content or a data URL without leaving unresolved external
references.

## Native renderer changes

Extend the existing NIF options with image resources:

```elixir
%{
  width: 1200,
  height: 630,
  format: :png,
  fonts: [font_bytes],
  images: %{
    "/images/logo.png" => logo_bytes,
    "https://cdn.example.com/cover.webp" => cover_bytes
  }
}
```

Rust should:

1. Decode each verified buffer with Takumi's image resource API.
2. Register it under the exact source used by the parsed HTML.
3. Pass the resource map into raster and SVG render options.
4. Return a structured resource error if registration or decoding fails.

Filesystem and HTTP operations remain outside the dirty CPU NIF.

## Image inspection

Add a small native image-inspection function that returns verified media type
and dimensions:

```elixir
OgEx.Native.inspect_image(bytes)
# => {:ok, %{format: :png, width: 1200, height: 630}}
```

The Rust dependency tree already contains image decoders through Takumi, so
this avoids adding a second Elixir image-processing package.

Inspection must enforce the same dimension and pixel limits as rendering.

## Caching and versioning

Use two cache layers:

1. A resource cache for local or remote source bytes, fingerprints, and HTTP
   validators.
2. The existing generated-image cache for final encoded card output.

The generated-image key should become:

```elixir
{
  card,
  card_version,
  width,
  height,
  format,
  asset_fingerprints
}
```

This ensures that changing a local image or a revalidated remote image
invalidates the generated card even when the controller assigns are unchanged.

Remote cache entries should retain `ETag` and `Last-Modified` and make
conditional requests after their TTL. The resource cache must have bounded
entry and byte limits so arbitrary remote sources cannot grow ETS without
limit.

Direct public and private local image fingerprints should be content hashes.
Direct external URLs should use the URL itself unless the user supplies an
explicit version.

## Dependencies

Likely new Elixir dependencies:

```elixir
{:req, "~> 0.5"}
{:floki, "~> 0.36"}
```

- `Req` provides HTTP requests, redirects, streaming, timeouts, and validator
  support.
- `Floki` provides robust discovery and rewriting of image references in the
  rendered HTML.

Before committing to these dependencies, verify whether the current supported
Req release exposes enough connection control to validate and pin resolved
addresses safely. If it cannot prevent DNS rebinding reliably, keep the loader
behaviour but use a lower-level adapter that can connect to a validated address
while retaining the original TLS hostname.

No additional image-decoding dependency should be necessary because the native
Takumi stack already handles PNG, JPEG, WebP, GIF, and SVG.

## Errors and telemetry

Resource failures should use structured reasons:

```elixir
{:error, {:resource_not_found, source}}
{:error, {:resource_host_not_allowed, host}}
{:error, {:resource_unsafe_address, address}}
{:error, {:resource_too_large, limit}}
{:error, {:resource_timeout, stage}}
{:error, {:unsupported_image_type, detected_type}}
{:error, {:invalid_image, reason}}
```

Add telemetry events for load duration, byte size, source type, cache status,
and failure class. Do not emit complete signed URLs, query strings, private
paths, response bodies, or secrets in telemetry metadata.

Failed or incomplete card renders must never enter the generated-image cache.

## Test plan

### Direct metadata images

- Public PNG, JPEG, WebP, GIF, and SVG metadata.
- Production digested static URLs.
- Explicit external URLs and dimensions.
- Private signed image responses.
- Separate Open Graph and Twitter images.
- Missing, unreadable, malformed, and unsupported files.
- Correct content type, dimensions, ETag, and cache headers.

### Generated-card resources

- Public static image rendered into PNG.
- Private image rendered into PNG.
- Remote image rendered into PNG.
- Raster source embedded in SVG output.
- Sanitized SVG source in raster and SVG output.
- Multiple references to one resource load only once.
- Asset changes produce a new generated-image cache key.

### Security

- `..`, absolute-path, null-byte, and symlink traversal attempts.
- Disallowed remote hosts.
- `allowed_hosts: ["*"]` startup warning.
- Wildcard mode still rejects unsafe IP ranges.
- IPv4, IPv6, and encoded-address bypass attempts.
- Redirect from an allowed public host to a private address.
- DNS rebinding protection.
- Excessive redirects.
- Connection, response, and total timeouts.
- Oversized streamed responses.
- Incorrect content types and spoofed extensions.
- SVG scripts, event attributes, foreign objects, and external references.

### Compatibility

- Existing `og: CardModule` applications behave unchanged.
- Pages without `og:` remain ordinary Phoenix renders.
- PNG, JPEG, WebP, and SVG generated output still passes native integration
  tests.
- Custom renderer and cache behaviours continue to work.

## Delivery sequence

### Phase 1: Source model and direct public images

- Add `OgEx.Image.Source` and normalization.
- Accept keyword metadata through `og:`.
- Resolve static files and emit digested public URLs.
- Inspect dimensions and media types.
- Add metadata and compatibility tests.

### Phase 2: Direct private images

- Add configured private roots and `OgEx.private_asset/1`.
- Add canonical path validation and fingerprints.
- Serve original bytes through signed image responses.
- Add traversal, symlink, response, and caching tests.

### Phase 3: Local images inside generated cards

- Parse rendered HEEx and discover `<img src>`.
- Load public and private sources.
- Pass resource bytes into the Takumi NIF.
- Include local fingerprints in render-cache keys.
- Add real PNG and SVG integration fixtures.

### Phase 4: Remote images

- Add the loader behaviour and default HTTP implementation.
- Add host allowlists and `"*"` startup warning.
- Implement SSRF, redirect, timeout, type, and size controls.
- Add bounded validator-aware resource caching.
- Add security and integration tests with a controlled local HTTP fixture.

### Phase 5: Documentation and demo

- Document all new public and private functions.
- Update the function reference and architecture guide.
- Add public, private, and remote examples to the demo application.
- Show the resulting generated images in the README.
- Document SVG platform limitations and recommend PNG for social sharing.

## Completion criteria

The feature is complete when:

- existing public, private, and external files can be selected directly as
  social images;
- public, private, and external image sources render inside HEEx cards;
- Takumi performs no filesystem or network I/O;
- private paths cannot escape configured roots;
- remote loading is deny-by-default, with an explicit `"*"` escape hatch and
  startup warning;
- wildcard mode retains all non-host SSRF protections;
- asset changes invalidate generated-image cache entries;
- all new functions are documented;
- native, lifecycle, metadata, cache, and security tests pass on supported
  platforms.
