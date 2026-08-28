# Public API reference

This guide summarizes the API used by Phoenix applications and extension
modules. Internal request dispatch, signatures, cache-key construction, and the
native bridge are covered in [Internal architecture](internal-architecture.md).

```
Initial: GET /posts/42 → Controller → OgEx sign → HTML with og:image

Image HIT:  GET TOKEN → Dispatcher → Card.load → Cache HIT → 200
Image MISS: GET TOKEN → Dispatcher → Card.load → Cache MISS → Takumi → 200
```

See `README` (Request flow) and `Internal architecture` for the full phase breakdown.

## Controller integration

### `use OgEx.Controller`

Install this after the application's normal controller setup:

```elixir
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller
  use OgEx.Controller
end
```

The macro imports `og_card/2` and `og_card/3`, installs query-image
interception, and replaces the controller-local `render/3`. Undeclared actions
and renders without an `:og` option keep normal Phoenix behavior.

### `og_card/2` and `og_card/3`

Associate a generated card with one controller action:

```elixir
og_card :show, MyAppWeb.PostOgCard
```

Options:

| Option | Default | Purpose |
| --- | --- | --- |
| `:load` | Card `load/2` | Explicit local function capture used instead of card-local loading |
| `:image_route` | Application setting, then `:path` | `:path` or `:query` |

```elixir
og_card :show, MyAppWeb.PostOgCard,
  load: &load_post_card/2,
  image_route: :query
```

The normal action supplies HTML render assigns. A later image request invokes
the selected loader without invoking the action.

An action may have only one declaration. Declaring the same action twice,
including once with `image_route: :path` and once with `image_route: :query`,
raises at compile time. The declaration-level strategy may override the
application default, and separate actions may choose separate strategies.

### Router integration

For path URLs, import `OgEx.Router` and place its route after application
routes:

```elixir
import OgEx.Router

# Application routes...
og_ex_routes()
```

### Endpoint integration

As an alternative, place OgEx immediately before the Phoenix router:

```elixir
plug OgEx, router: MyAppWeb.Router
plug MyAppWeb.Router
```

Router and endpoint integrations are mutually exclusive. OgEx warns when the
endpoint can detect that both were installed.

Query declarations can rely on the controller integration alone.

### Runnable applications

The
[`og_ex_demo`](https://github.com/obasekiosa/og_ex_demo) repository keeps each
example as an independent Mix project:

- [`v0_1_0`](https://github.com/obasekiosa/og_ex_demo/tree/master/apps/v0_1_0)
  demonstrates the published `0.1.0` generated-card API.
- [`v0_2_0`](https://github.com/obasekiosa/og_ex_demo/tree/master/apps/v0_2_0)
  demonstrates published `0.2.0` local, external, and direct image sources.
- [`v0_3_0`](https://github.com/obasekiosa/og_ex_demo/tree/master/apps/v0_3_0)
  demonstrates the controller DSL and both image URL strategies.

### Legacy generated card declaration

The `0.2.0` render-time declaration remains supported:

```elixir
render(conn, :show, post: post, og: MyAppWeb.PostOgCard)
```

This form runs the controller action before recognizing the image request.

### Direct image declaration

Pass a keyword list or map containing `:title` and `:image`:

```elixir
render(conn, :show,
  post: post,
  og: [
    title: post.title,
    description: post.summary,
    image: "/images/post-og.png",
    image_alt: "Preview for #{post.title}",
    twitter_card: "summary_large_image"
  ]
)
```

Supported fields:

| Field | Required | Purpose |
| --- | --- | --- |
| `:title` | yes | Open Graph and Twitter/X title |
| `:image` | yes | Public path, external URL, or `{:private, path}` |
| `:description` | no | Open Graph and Twitter/X description |
| `:type` | no | Open Graph type; defaults to `"website"` |
| `:image_alt` | no | Open Graph and Twitter/X image alt text |
| `:twitter_card` | no | Twitter/X card type; defaults to `"summary_large_image"` |
| `:twitter_image` | no | Separate public, private, or external Twitter/X image |
| `:image_width` | no | Explicit width, mainly for direct external images |
| `:image_height` | no | Explicit height, mainly for direct external images |

Direct local resources are currently read and verified during the HTML request.
Direct external resources are not requested by OgEx.

## `OgEx.Card`

`OgEx.Card` defines generated-card callbacks and provides the setup macro.

### `use OgEx.Card`

```elixir
use OgEx.Card, width: 1200, height: 630, format: :png
```

Options:

| Option | Default | Values |
| --- | ---: | --- |
| `:width` | `1200` | positive integer |
| `:height` | `630` | positive integer |
| `:format` | `:png` | `:png`, `:jpeg`, `:webp`, `:svg` |

The macro imports `Phoenix.Component` and installs the callbacks below.

### `load/2`

Optional callback used by `og_card` declarations when no explicit `load:`
override exists:

```elixir
@impl OgEx.Card
def load(_conn, %{"id" => id}) do
  case Blog.get_public_post(id) do
    nil -> {:error, :not_found}
    post -> {:ok, %{post: post}}
  end
end
```

The callback receives the image connection and normalized route parameters.
It returns `{:ok, map}` or `{:error, reason}`. `:not_found` and `:forbidden`
produce a non-cacheable `404`; other failures produce a non-cacheable `503`.

Use these helpers when a card serves multiple declarations:

```elixir
OgEx.controller(conn)
OgEx.action(conn)
OgEx.route_params(conn)
OgEx.image_role(conn)
```

### `metadata/1`

Required callback. Returns a metadata map:

```elixir
@impl OgEx.Card
def metadata(%{post: post}) do
  %{
    title: post.title,
    description: post.summary,
    type: "article",
    image_alt: "Preview for #{post.title}",
    twitter_card: "summary_large_image"
  }
end
```

Only `:title` is required.

### `render/1`

Required callback. Returns HEEx:

```elixir
@impl OgEx.Card
def render(assigns) do
  ~H"""
  <main style="width: 100%; height: 100%">
    <h1>{@post.title}</h1>
  </main>
  """
end
```

OgEx wraps the result in a viewport-sized HTML document before calling the
renderer.

### `version/1`

Optional callback. Returns stable data that identifies the image content.
Include an application-controlled layout revision because OgEx cannot detect
changes made only to the card's HEEx or CSS:

```elixir
@layout_revision 2

@impl OgEx.Card
def version(%{post: post}) do
  {:post_card, @layout_revision, post.id, post.updated_at}
end
```

When omitted, the complete assigns map is used. The return value is hashed and
does not appear directly in the public URL. Here, `:post_card` is an
application-chosen label and `@layout_revision` is a manual cache-busting
number—not the OgEx package version. Increase the revision after a
presentation-only change that must invalidate existing generated images.

## `OgEx.private_asset/1`

Builds an opaque `<img src>` for a file below `:private_asset_root`:

```heex
<img src={OgEx.private_asset("backgrounds/report.png")} />
```

The argument must be a relative path. The resulting string is interpreted by
OgEx's resource loader and is not a browser-accessible URL.

`OgEx.Image.private_asset/1` is the underlying implementation; application card
code should normally use the top-level delegate.

## `OgEx.Image`

Most applications pass source values through controller metadata or HEEx.
These functions are useful when implementing a custom resource loader.

### `normalize/2`

```elixir
OgEx.Image.normalize(source, conn)
```

Accepted sources:

- root-relative public paths;
- HTTPS or HTTP URLs;
- base64 data URLs;
- `{:private, relative_path}`;
- values returned by `OgEx.private_asset/1`.

Returns `{:ok, %OgEx.Image.Source{}}` or `{:error, reason}`. Local
normalization constrains the path to its configured root and currently requires
the file to exist.

### `load/2`

```elixir
OgEx.Image.load(source, max_bytes: 2_000_000)
```

Delegates a normalized source to the configured `OgEx.ResourceLoader`.
Returns `{:ok, %OgEx.Image.Resource{}}` or `{:error, reason}` and emits the
resource telemetry event.

### `content_type/1`

Maps `:png`, `:jpeg`, `:webp`, `:gif`, or `:svg` to its HTTP media type.

### `otp_app/1`

Returns the OTP application that owns the Phoenix endpoint in a connection.
Falls back to `config :og_ex, otp_app: ...` and raises when neither source is
available.

### `public_url/2`

Returns an absolute URL for a root-relative static path. When available,
the endpoint's `static_path/1` is used to include its digest.

## `OgEx.Image.Source`

A normalized source description produced by `OgEx.Image.normalize/2`.
Applications should pass ordinary source forms instead of constructing the
struct unless they are implementing an integration boundary.

Important fields:

- `:type` — `:public`, `:private`, `:remote`, or `:data`;
- `:reference` — the original or opaque source identity;
- `:path` — trusted resolved local path when applicable.

## `OgEx.Image.Resource`

A verified resource returned by a loader. It contains:

- normalized source;
- encoded bytes;
- detected format and content type;
- intrinsic dimensions;
- SHA-256 content fingerprint;
- optional remote ETag and Last-Modified validators.

## `OgEx.ResourceLoader`

Custom loaders implement:

```elixir
@callback load(OgEx.Image.Source.t(), keyword()) ::
            {:ok, OgEx.Image.Resource.t()} | {:error, term()}
```

Expected missing files, policy rejections, validation problems, and network
failures should be returned rather than raised.

Use `OgEx.ResourceLoader.Default.from_bytes/2` to apply OgEx's native image,
dimension, and SVG validation to bytes obtained from custom storage.

## `OgEx.ResourceLoader.Default`

### `load/2`

Loads a normalized public, private, data, or remote source. Remote sources are
delegated to `OgEx.ResourceLoader.Remote`.

### `from_bytes/2`

```elixir
OgEx.ResourceLoader.Default.from_bytes(source, encoded_bytes)
```

Detects the format, decodes dimensions, applies configured dimension and pixel
limits, checks SVG active content, computes a fingerprint, and returns a
verified resource.

## `OgEx.ResourceLoader.Remote`

### `load/2`

Loads a normalized remote source using the configured remote policy and
resource cache:

```elixir
OgEx.ResourceLoader.Remote.load(source)
```

Per-call options override application `:remote_images` values. Remote loading
must be enabled and the host must match `:allowed_hosts`.

This module is intended for embedded generated-card resources. Direct external
metadata URLs are not routed through it.

## `OgEx.Renderer`

Renderer implementations receive:

```elixir
[
  width: 1200,
  height: 630,
  format: :png,
  fonts: [font_bytes],
  images: %{
    "/images/logo.png" => encoded_logo_bytes
  }
]
```

The callback returns `{:ok, encoded_image}` or `{:error, reason}`.

## `OgEx.Renderer.Takumi`

The default renderer. `render/2` converts keyword options to the stable native
options map and invokes the Takumi NIF. Filesystem and network work must be
completed before this call.

## `OgEx.Cache`

Final-image caches implement:

```elixir
@callback fetch(term()) :: {:ok, binary()} | :error
@callback put(term(), binary()) :: :ok
```

Treat cache keys as opaque. OgEx passes only complete successful image binaries
to `put/2`.

`OgEx.Cache.ETS` is the default per-node implementation.

## Font configuration

Generated-card rendering requires at least one font. The `:fonts` list accepts
these entries:

| Entry | Behavior |
| --- | --- |
| `"path/to/font.ttf"` | An existing file is read as font bytes; any other binary passes through unchanged |
| `{:ogex_font, "priv/fonts/font.ttf"}` | Lazy marker resolved against `config :og_ex, :otp_app` when fonts load; plain data, so it stays safe to evaluate from `config.exs` before OgEx is compiled |
| `{Mod, fun, args}` | Invoked when fonts load; must return a path binary or font bytes |
| `fn -> path_or_bytes end` | Same contract as an MFA |

`OgEx.font(path)` returns the same `{:ogex_font, path}` tuple and can be used
anywhere OgEx is already loaded. Markers never touch the filesystem during
compilation or boot. Relative marker paths resolve with
`Application.app_dir/2` and therefore require `config :og_ex, :otp_app`;
absolute paths resolve directly.

Invalid configuration produces a structured error instead of a native decoding
failure: image requests return a non-cacheable `503`, OgEx logs the exact
reason once per node, and application boot warns about entry shapes it does
not recognize. Renderers always receive fully resolved font binaries through
the `:fonts` option.

## Runtime configuration

```elixir
config :og_ex,
  otp_app: :my_app,
  fonts: [{:ogex_font, "priv/fonts/font.ttf"}],
  private_asset_root: "priv/og_ex",
  renderer: OgEx.Renderer.Takumi,
  cache: OgEx.Cache.ETS,
  resource_loader: OgEx.ResourceLoader.Default,
  resource_cache_module: OgEx.ResourceCache,
  remote_images: [
    enabled: false,
    allowed_hosts: [],
    allow_http: false,
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

Only `:fonts` is required for normal generated-card rendering. The remaining
entries show defaults or extension points.
