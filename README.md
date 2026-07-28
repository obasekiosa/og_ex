# OgEx

OgEx adds Open Graph and Twitter/X images to Phoenix controller responses. A
controller can either render a card from HEEx or point its metadata at an
existing image:

```elixir
# Generate an image from HEEx.
render(conn, :show, post: post, og: MyAppWeb.PostOgCard)

# Use an existing image.
render(conn, :about,
  og: [
    title: "About Acme",
    image: "/images/about-og.png"
  ]
)
```

Generated images are served from a signed version of the page URL. You do not
add an image controller or image route.

## Release status

OgEx `0.1.0` is the current Hex release. This repository is developing `0.2.0`,
which adds image resources inside generated cards and direct-image metadata.
The `0.2.0` native archives have not been published, so a path dependency must
be compiled from source with `OG_EX_BUILD=1`.

OgEx is still a `0.x` package. Review release notes before upgrading because
minor releases may change public APIs.

## Requirements

- Elixir 1.17 or later.
- Phoenix 1.7 or later.
- At least one TTF, OTF, WOFF, or WOFF2 font.
- Rust only when building OgEx from source. Published releases use precompiled
  native archives.

## Installation

For the published `0.1` release:

```elixir
def deps do
  [
    {:og_ex, "~> 0.1"}
  ]
end
```

For the current `0.2` source checkout:

```elixir
def deps do
  [
    {:og_ex, path: "../og-ex"}
  ]
end
```

Compile an unreleased checkout before running any other Mix task that might
compile dependencies:

```bash
OG_EX_BUILD=1 mix deps.compile og_ex --force
OG_EX_BUILD=1 mix phx.server
```

Without `OG_EX_BUILD=1`, `RustlerPrecompiled` looks for a GitHub release matching
the version in `mix.exs`. An unreleased version returns a 404 because its native
archives do not exist yet.

Published versions select a checksum-verified archive for the host operating
system, CPU, and NIF ABI. See [Native distribution](docs/06-distribution.md)
for the supported targets and source-build details.

## Configure fonts

Takumi does not read system fonts. OgEx passes the configured font files to the
renderer on a cache miss:

```elixir
# config/config.exs
import Config

config :og_ex,
  fonts: [
    Path.expand("../priv/fonts/Inter-Regular.ttf", __DIR__),
    Path.expand("../priv/fonts/Inter-Bold.ttf", __DIR__)
  ]
```

The paths must be available in the deployed release. Keeping fonts in your
application's `priv/fonts` directory usually makes that straightforward.
Rendering fails if no font is configured.

## Enable a controller

Add `use OgEx.Controller` after the application's controller setup:

```elixir
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller
  use OgEx.Controller

  def show(conn, %{"id" => id}) do
    post = MyApp.Blog.get_post!(id)

    render(conn, :show,
      post: post,
      og: MyAppWeb.PostOgCard
    )
  end
end
```

`OgEx.Controller` replaces the controller-local `render/3`. Calls without an
`:og` option still delegate to `Phoenix.Controller.render/3`.

No endpoint plug is required. `OgEx` still implements `Plug` for compatibility
with early integrations, but new applications should not install it.

## Define a generated card

A card supplies metadata, a stable version, and HEEx:

```elixir
defmodule MyAppWeb.PostOgCard do
  use OgEx.Card, width: 1200, height: 630, format: :png

  @impl OgEx.Card
  def metadata(%{post: post}) do
    %{
      title: post.title,
      description: post.summary,
      type: "article",
      image_alt: "Social card for #{post.title}",
      twitter_card: "summary_large_image"
    }
  end

  @impl OgEx.Card
  def version(%{post: post}) do
    {post.id, post.title, post.updated_at}
  end

  @impl OgEx.Card
  def render(assigns) do
    ~H"""
    <main class="card">
      <p class="site">ACME ENGINEERING</p>

      <section>
        <h1>{@post.title}</h1>
        <p class="author">By {@post.author.name}</p>
      </section>
    </main>

    <style>
      * {
        box-sizing: border-box;
      }

      .card {
        width: 100%;
        height: 100%;
        padding: 72px;
        display: flex;
        flex-direction: column;
        justify-content: space-between;
        color: white;
        background:
          radial-gradient(circle at top right, #4f46e5, transparent 45%),
          #0f172a;
        font-family: Inter, sans-serif;
      }

      .site {
        margin: 0;
        color: #a5b4fc;
        font-size: 24px;
        font-weight: 700;
        letter-spacing: 0.16em;
      }

      h1 {
        max-width: 1000px;
        margin: 0 0 24px;
        font-size: 72px;
        line-height: 1.05;
      }

      .author {
        margin: 0;
        color: #c7d2fe;
        font-size: 30px;
      }
    </style>
    """
  end
end
```

`use OgEx.Card` imports `Phoenix.Component`, so the module can use `~H`,
function components, and normal HEEx escaping.

The dimensions in `use OgEx.Card` are the renderer viewport. The wrapper added
by OgEx fills that viewport, so the card's outer element should normally use
`width: 100%` and `height: 100%`.

### Metadata fields

`metadata/1` returns a map with:

| Field | Required | Default |
| --- | --- | --- |
| `:title` | yes | none |
| `:description` | no | omitted |
| `:type` | no | `"website"` |
| `:image_alt` | no | omitted |
| `:twitter_card` | no | `"summary_large_image"` |

Dynamic metadata is escaped before it is inserted into the page.

### Version generated images

`version/1` should return the smallest stable term that changes whenever the
rendered image changes:

```elixir
@impl OgEx.Card
def version(%{post: post}) do
  {post.id, post.title, post.updated_at}
end
```

OgEx hashes this term. It does not place the original value in the public URL.
The hash contributes to the request signature, ETag, and generated-image cache
key.

If `version/1` is omitted, OgEx hashes the complete assigns map. That is useful
while developing a card but can create avoidable cache entries when assigns
contain values that do not affect the image.

Card code and CSS are not automatically part of `version/1`. Change a version
marker when a deployed style change must produce a new immutable URL:

```elixir
def version(%{post: post}) do
  {:layout_v2, post.id, post.updated_at}
end
```

## Add images to generated cards

OgEx reads `<img src>` values after evaluating the card's HEEx. Each source is
normalized, loaded, inspected, and registered with Takumi under the exact
string used in the HTML. Takumi does not receive filesystem or unrestricted
network access.

The current scanner handles `<img src>`. It does not yet discover CSS
`url(...)`, `srcset`, or `<picture>` sources.

### Public Phoenix assets

Use a root-relative path:

```heex
<img src="/images/logo.png" width="160" height="160" />
```

OgEx resolves the file under the endpoint application's `priv/static`
directory. It rejects traversal and symlinks before reading the file.

### Private application files

Private files are not served by `Plug.Static`. Configure their root:

```elixir
# config/config.exs
config :og_ex,
  private_asset_root: "priv/og_ex"
```

Then use `OgEx.private_asset/1` in HEEx:

```heex
<img
  src={OgEx.private_asset("backgrounds/report.png")}
  width="1200"
  height="630"
/>
```

Relative roots are resolved inside the host OTP application. If OgEx cannot
determine that application from the Phoenix endpoint, set it explicitly:

```elixir
config :og_ex, otp_app: :my_app
```

The helper returns an opaque source string. It does not expose the filesystem
path in the rendered image or grant Takumi filesystem access.

### External HTTPS images

Use an ordinary URL in the card:

```heex
<img
  src="https://cdn.example.com/products/cover.webp"
  width="480"
  height="320"
/>
```

Remote loading is disabled until it is configured:

```elixir
# config/runtime.exs
config :og_ex,
  remote_images: [
    enabled: true,
    allowed_hosts: ["cdn.example.com", "*.cloudfront.net"]
  ]
```

The request occurs when the signed image URL is requested, not while Phoenix
renders the HTML page. See [Remote image configuration](#remote-image-configuration)
for the complete policy.

### Data URLs

Generated cards accept base64 image data URLs:

```heex
<img src={"data:image/png;base64," <> @encoded_logo} />
```

Data URLs count against the same byte and decoded-dimension limits as other
resources. They increase the data hashed and passed through the renderer, so a
public or private file is usually preferable.

## Use an existing image directly

Use direct metadata when the social image is already encoded and does not need
Takumi. Pass a keyword list or map as `:og`.

### Public static image

```elixir
def about(conn, _params) do
  render(conn, :about,
    og: [
      title: "About Acme",
      description: "Meet the team",
      image: "/images/about-og.png",
      image_alt: "The Acme team"
    ]
  )
end
```

OgEx verifies the local file, reads its dimensions, and emits the absolute URL
returned by the endpoint's static path handling. `Plug.Static` serves the image;
Takumi and the generated-image cache are not involved.

### Private existing image

```elixir
def report(conn, %{"id" => id}) do
  report = MyApp.Reports.get!(id)

  render(conn, :show,
    report: report,
    og: [
      title: report.title,
      image: {:private, "reports/default-og.png"}
    ]
  )
end
```

OgEx verifies the file during the HTML request and emits a signed URL for the
same controller route. A request with a valid signature returns the original
encoded bytes; the image is not passed through Takumi.

Private means “not served by `Plug.Static`.” Social crawlers still need public
network access to the signed URL. OgEx does not use the visitor's authenticated
session as an authorization mechanism for crawler access.

### External existing image

```elixir
def show(conn, %{"id" => id}) do
  post = MyApp.Blog.get_post!(id)

  render(conn, :show,
    post: post,
    og: [
      title: post.title,
      description: post.summary,
      image: post.cover_url,
      image_width: 1200,
      image_height: 630
    ]
  )
end
```

OgEx writes the external URL into the metadata without requesting it. Explicit
dimensions are optional. When omitted, the corresponding metadata tags are
omitted because OgEx does not download a direct external image to inspect it.

The remote-image allowlist applies to images embedded in generated cards. It
does not restrict direct external metadata URLs because OgEx does not fetch
them.

### Separate Twitter/X image

`:image` is used for both Open Graph and Twitter/X unless
`:twitter_image` is present:

```elixir
render(conn, :release,
  og: [
    title: "Acme 2.0",
    image: "/images/release-wide.png",
    twitter_image: "/images/release-square.png",
    twitter_card: "summary"
  ]
)
```

Public, private, and external source forms are accepted for
`:twitter_image`.

## Generated request lifecycle

For a normal page request:

```text
GET /posts/42
  → the controller loads its normal data
  → OgEx evaluates metadata and builds a signed image URL
  → Phoenix renders the page and root layout
  → OgEx inserts meta tags before </head>
```

The generated metadata points to the same path with the reserved `__og_ex`
query parameter:

```text
GET /posts/42?__og_ex=4K7fQxRfj2p0DqX_WLAzTA
```

For that image request:

```text
GET /posts/42?__og_ex=...
  → the same controller action runs
  → OgEx reaches the controller's render/3 call
  → the signature is verified against the route, card, role, and version
  → card HEEx is evaluated
  → referenced images are loaded and fingerprinted
  → the final-image cache is checked
  → Takumi renders on a cache miss
  → the encoded image is returned
```

The Phoenix page template is not rendered on the image branch. Work performed
by the action before `render/3` still runs. Keep expensive image-specific work
inside the card callbacks or a resource loader rather than performing it
unconditionally in the controller.

The URL retains unrelated query parameters, such as a locale, while replacing
any older `__og_ex` value.

## Head injection

OgEx inserts metadata when Phoenix sends a complete HTML response. The response
must contain a closing `</head>` element. Streaming and compressed HTML bodies
are not rewritten.

The generated tags include:

```html
<meta property="og:title" content="...">
<meta property="og:description" content="...">
<meta property="og:type" content="website">
<meta property="og:image" content="...">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="...">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="...">
<meta name="twitter:description" content="...">
<meta name="twitter:image" content="...">
<meta name="twitter:image:alt" content="...">
```

Optional tags are omitted when their values are absent.

## Output formats

Generated cards support:

| Format | Card option | Response type |
| --- | --- | --- |
| PNG | `:png` | `image/png` |
| JPEG | `:jpeg` | `image/jpeg` |
| WebP | `:webp` | `image/webp` |
| SVG | `:svg` | `image/svg+xml` |

```elixir
use OgEx.Card, width: 1200, height: 630, format: :webp
```

PNG is the default and the safest choice for broad crawler compatibility.
Support for SVG previews varies by platform.

Takumi's SVG output contains vector layout and glyph paths. Bitmap resources
remain bitmap content inside the SVG.

Direct local resources may be PNG, JPEG, WebP, GIF, or SVG. OgEx detects the
type from the file contents rather than trusting the extension.

## Remote image configuration

The default remote loader is opt-in and deny-by-default:

```elixir
config :og_ex,
  remote_images: [
    enabled: true,
    allowed_hosts: ["cdn.example.com", "*.cloudfront.net"],
    max_bytes: 5_000_000,
    max_dimension: 8_192,
    max_pixels: 40_000_000,
    connect_timeout: 2_000,
    receive_timeout: 5_000,
    request_timeout: 8_000,
    max_redirects: 2,
    cache_ttl: 300_000
  ],
  resource_cache: [
    max_entries: 128,
    max_bytes: 25_000_000
  ]
```

Defaults:

| Option | Default | Meaning |
| --- | ---: | --- |
| `:enabled` | `false` | Enables external resources inside generated cards |
| `:allowed_hosts` | `[]` | Exact hosts or `*.` subdomain patterns |
| `:allow_http` | `false` | Allows plain HTTP when explicitly enabled |
| `:max_bytes` | `5_000_000` | Maximum encoded resource size |
| `:max_dimension` | `8_192` | Maximum width or height |
| `:max_pixels` | `40_000_000` | Maximum decoded pixel count |
| `:connect_timeout` | `2_000` | TCP/TLS connection timeout in milliseconds |
| `:receive_timeout` | `5_000` | Socket receive timeout in milliseconds |
| `:request_timeout` | `8_000` | Total request timeout in milliseconds |
| `:max_redirects` | `2` | Redirects validated before the request fails |
| `:cache_ttl` | `300_000` | Fresh remote-resource lifetime in milliseconds |

The loader:

- permits HTTPS by default;
- validates every redirect target;
- resolves every DNS answer and rejects the host if any answer is unsafe;
- rejects loopback, private, link-local, multicast, unspecified, reserved, and
  cloud metadata addresses;
- connects to a validated address while retaining the original TLS hostname;
- does not forward page cookies, authorization, or request headers;
- stops streaming when the byte limit is crossed;
- checks the response media type and then verifies the image bytes;
- retains ETag and Last-Modified validators for conditional requests;
- does not cache failed or partial responses.

To allow every hostname:

```elixir
config :og_ex,
  remote_images: [
    enabled: true,
    allowed_hosts: ["*"]
  ]
```

OgEx logs a warning once when the application starts. `"*"` disables only the
hostname allowlist; address validation and all other limits still apply.

Prefer explicit hosts in production.

### SVG resources

Before SVG bytes reach Takumi, the default loader rejects scripts, event
handlers, `foreignObject`, external `href` or `src` references, and external
CSS `url(...)` references. SVG dimensions and byte size are subject to the
normal limits.

## Caching

OgEx maintains two in-memory caches.

### Generated-image cache

The default `OgEx.Cache.ETS` stores final encoded cards. Its key contains:

```elixir
{
  card_module,
  card_version,
  width,
  height,
  format,
  sorted_resource_fingerprints
}
```

Changing a referenced local image changes its fingerprint and therefore the
final cache key.

Only successful renders are stored. The default cache is local to one BEAM node
and has no persistence or eviction policy. Simultaneous misses for the same key
are not coalesced.

Replace it with a module implementing `OgEx.Cache`:

```elixir
defmodule MyApp.OgImageCache do
  @behaviour OgEx.Cache

  @impl true
  def fetch(key) do
    case MyApp.Cache.get(key) do
      nil -> :error
      image when is_binary(image) -> {:ok, image}
    end
  end

  @impl true
  def put(key, image) do
    MyApp.Cache.put(key, image)
    :ok
  end
end

config :og_ex, cache: MyApp.OgImageCache
```

`fetch/1` follows `Map.fetch/2`: it returns `{:ok, image}` or `:error`.

### Remote-resource cache

`OgEx.ResourceCache` stores verified remote bytes and HTTP validators. It is
bounded by entry count and total byte size:

```elixir
config :og_ex,
  resource_cache: [
    max_entries: 128,
    max_bytes: 25_000_000
  ]
```

When an insertion would exceed a bound, the current implementation clears the
table before inserting the new resource. It is an in-memory, per-node cache.

### Response caching

Successful generated and signed private responses include:

```http
Cache-Control: public, max-age=31536000, immutable
ETag: "CONTENT_IDENTITY"
```

Render failures use `Cache-Control: no-store`.

## Error behavior

Current behavior is intentionally documented here because the failure boundary
depends on the image source:

| Source | HTML request | Image request |
| --- | --- | --- |
| Resource embedded in a generated card | HTML normally returns `200` | Resource or render failure returns an empty, non-cacheable `503` |
| Direct external image | URL is emitted without a fetch | The social platform fetches the external URL |
| Direct public image | File is verified while metadata is built | `Plug.Static` serves the URL |
| Direct private image | File is verified while metadata is built | Valid signed request returns the original bytes |

An invalid image signature returns an empty `404`.

A missing or invalid direct local image currently raises while the HTML
metadata is built and can make the page return `500`. Lazy direct verification
and configurable fallback images are designed in `image_plan.md` but are not
implemented in this version.

OgEx never caches a failed generated render.

## Telemetry

OgEx emits:

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:og_ex, :resource, :stop]` | `:duration`, optional `:size` | `:source_type`, `:status`, `:loader` |
| `[:og_ex, :cache, :hit]` | none | `:card` |
| `[:og_ex, :cache, :miss]` | none | `:card` |
| `[:og_ex, :render, :stop]` | `:duration`, `:size` | `:card`, `:renderer` |
| `[:og_ex, :render, :exception]` | `:system_time` | `:card`, `:reason` |

Durations use native telemetry time units. Convert them with
`System.convert_time_unit/3` in a handler.

## Replace the resource loader

Use a custom `OgEx.ResourceLoader` for authenticated object storage, fixtures,
or an application-specific network policy:

```elixir
defmodule MyApp.OgResourceLoader do
  @behaviour OgEx.ResourceLoader

  @impl true
  def load(%OgEx.Image.Source{type: :remote} = source, _options) do
    with {:ok, bytes} <- MyApp.Media.fetch(source.reference) do
      OgEx.ResourceLoader.Default.from_bytes(source, bytes)
    end
  end

  def load(source, options) do
    OgEx.ResourceLoader.Default.load(source, options)
  end
end

config :og_ex, resource_loader: MyApp.OgResourceLoader
```

Return `{:ok, %OgEx.Image.Resource{}}` only after the bytes have been verified.
`OgEx.ResourceLoader.Default.from_bytes/2` applies the package's native image,
dimension, and SVG checks.

## Replace the renderer

The default renderer is `OgEx.Renderer.Takumi`:

```elixir
config :og_ex, renderer: OgEx.Renderer.Takumi
```

Custom renderers implement `OgEx.Renderer` and return an encoded image, not raw
pixels:

```elixir
defmodule MyApp.OgRenderer do
  @behaviour OgEx.Renderer

  @impl true
  def render(html, options) do
    width = Keyword.fetch!(options, :width)
    height = Keyword.fetch!(options, :height)
    format = Keyword.fetch!(options, :format)
    images = Keyword.get(options, :images, %{})

    MyRenderer.render(html,
      width: width,
      height: height,
      format: format,
      images: images
    )
  end
end
```

The callback must return `{:ok, encoded_binary}` or `{:error, reason}`.

## Testing locally

Request the page, extract its `og:image`, then request that URL:

```bash
curl -s http://localhost:4000/posts/42 |
  grep 'property="og:image"'
```

The URL is absolute. Opening it in a browser is often the quickest way to
inspect the generated card.

For automated controller tests, request the page, parse the metadata URL, and
make a second request with `Phoenix.ConnTest`. The package's integration tests
under `test/og_ex/` demonstrate the complete lifecycle.

The companion `og_ex_demo` repository contains:

- the released `0.1.0` examples;
- an `f_image_sources` application covering a local embedded image, an
  allowlisted external embedded image, and a direct existing image.

## Current limitations

- Controller actions run again for signed image requests, including work done
  before `render/3`.
- Direct local files are verified during the HTML request.
- `<img src>` is the only discovered generated-card image reference.
- Streaming and compressed HTML responses are not rewritten.
- The default caches are in-memory and local to one BEAM node.
- Simultaneous generated-image cache misses are not coalesced.
- Takumi implements HTML and CSS layout but is not Chromium; unsupported CSS
  may render differently from a browser.
- Social-platform support for SVG metadata images is inconsistent.
- Dedicated image routes and static generated files are planned but not part of
  the current controller API.

## Development

```bash
mix deps.get
OG_EX_BUILD=1 mix test
cargo test --manifest-path native/og_ex_native/Cargo.toml
mix docs
mix hex.build
```

The native integration tests render real images and verify their formats and
dimensions.

See [Public API reference](docs/function-reference.md) for callbacks,
configuration boundaries, and extension points. Native release maintenance is
documented separately in [Native distribution](docs/06-distribution.md).

## License

OgEx is released under the MIT License.
