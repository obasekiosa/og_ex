# OgEx

OgEx generates Open Graph and Twitter/X card images from HEEx inside Phoenix
controllers. A page declares its card in the normal `render/3` call; OgEx adds
the metadata and serves the generated image from a signed version of the same
page URL.

```elixir
render(conn, :show, post: post, og: MyAppWeb.PostOgCard)
```

Application code does not define an image route or image controller.

> **Project status:** early development. The core HEEx → Takumi → PNG path and
> signed request lifecycle work, but the package is not ready for production
> publishing yet.

## How it works

For a normal page request:

```text
GET /posts/42
  → controller loads the post
  → OgEx builds metadata and a signed image URL
  → Phoenix renders the normal page
  → OgEx inserts social metadata before </head>
```

The generated `og:image` points to the same route with a compact 22-character
signature:

```text
GET /posts/42?__og_ex=4K7fQxRfj2p0DqX_WLAzTA
```

That request runs the controller action again. When execution reaches the
OgEx-aware `render/3`, it lazily fetches and verifies the signature, renders the
card's HEEx through Takumi, caches the encoded image, and sends it with the
configured image content type.

## Installation

Add OgEx to `mix.exs`:

```elixir
def deps do
  [
    {:og_ex, "~> 0.1"}
  ]
end
```

During local package development:

```elixir
{:og_ex, path: "../og-ex"}
```

Stable releases download a checksum-verified precompiled NIF for supported
Linux, macOS, and Windows targets, so consuming applications do not need Rust.
Development versions and forced source builds require the Rust version pinned in
`rust-toolchain.toml` because Takumi 2.4 requires it. Set `OG_EX_BUILD=true`
when explicitly testing the source-build path.

No endpoint plug or generated route is required. The controller integration
fetches the reserved query parameter lazily only when `render/3` is reached.

Configure at least one font. Takumi shapes text from supplied font data rather
than relying on fonts installed on the host:

```elixir
config :og_ex,
  fonts: [
    Path.expand("../priv/fonts/Inter-Regular.ttf", __DIR__),
    Path.expand("../priv/fonts/Inter-Bold.ttf", __DIR__)
  ]
```

Then enable the controller integration:

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

## Defining a card

A card keeps metadata and presentation in one module:

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

  # Only fields that change the image need to contribute to its public version.
  # A new version creates a new immutable image URL and cache entry.
  @impl OgEx.Card
  def version(%{post: post}) do
    {post.id, post.title, post.updated_at}
  end

  @impl OgEx.Card
  def render(assigns) do
    ~H"""
    <main class="card">
      <p class="site">EXAMPLE.COM</p>

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
        font-size: 26px;
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
        color: #c7d2fe;
        font-size: 30px;
      }
    </style>
    """
  end
end
```

This is ordinary HEEx, HTML, and CSS. OgEx extracts card-local `<style>` blocks
and sends them through Takumi's selector and cascade engine.

The dimensions declared in `use OgEx.Card` are the single source of truth.
OgEx applies them to the renderer viewport and generated HTML document, while
the card root fills that viewport with `width: 100%` and `height: 100%`.

## Output formats

Cards support `:png`, `:jpeg`, `:webp`, and `:svg`:

```elixir
use OgEx.Card, width: 1200, height: 630, format: :svg
```

SVG output is a real vector document produced from the same HTML/CSS layout,
including glyph-outline text and vector backgrounds, borders, gradients,
shadows, clipping, and transforms. Embedded bitmap images remain raster content
inside the SVG. PNG remains the safest default for Open Graph crawlers because
SVG acceptance varies across social platforms.

## Renderer

The default renderer is:

```elixir
config :og_ex,
  renderer: OgEx.Renderer.Takumi
```

The native pipeline is:

```text
HEEx safe data
  → HTML
  → html5ever parser
  → Takumi layout and text shaping
  → Takumi raster renderer
  → PNG/JPEG/WebP encoder
  → Erlang binary
```

The NIF runs on Rustler's dirty CPU scheduler so image work does not block the
BEAM's normal schedulers.

Alternative renderers implement:

```elixir
@behaviour OgEx.Renderer

@impl true
def render(html, options) do
  # Return {:ok, encoded_image_binary} or {:error, reason}.
end
```

## Caching

OgEx starts an ETS cache by default:

```elixir
config :og_ex,
  cache: OgEx.Cache.ETS
```

Successful images receive:

```http
Cache-Control: public, max-age=31536000, immutable
ETag: "CONTENT_VERSION"
```

Only successfully encoded images are cached. The cache behavior is replaceable
for shared or persistent storage.

Custom cache modules implement `OgEx.Cache`. Its lookup follows the conventional
Elixir `fetch/1` contract:

```elixir
@impl OgEx.Cache
def fetch(key) do
  case lookup(key) do
    {:found, image} -> {:ok, image}
    :not_found -> :error
  end
end
```

`{:ok, image}` means the encoded image was found, while `:error` means the key
is absent. The `[:og_ex, :cache, :miss]` telemetry event still uses “miss” as
the conventional name for an unsuccessful cache lookup; it is not the return
value of `fetch/1`.

## Current limitations

- At least one font must be configured.
- Remote `<img>` fetching is not implemented yet.
- The default cache is local to one BEAM node.
- Simultaneous misses are not yet coalesced.
- Streaming or compressed HTML responses are not rewritten automatically.
- Takumi supports a broad CSS subset, but it is not a browser and will not
  reproduce every Chromium behavior.
- The first stable release still requires its native archives and checksum file
  to be generated by the documented release workflow.

## Development

```bash
mix deps.get
mix test
cargo test --manifest-path native/og_ex_native/Cargo.toml
```

The integration suite performs an actual native render and verifies the output
PNG signature and dimensions.

Every public and private function is described in the
[function reference](docs/function-reference.md). Public APIs additionally have
inline ExDoc documentation, while private helpers have adjacent source comments.

## License

MIT.
