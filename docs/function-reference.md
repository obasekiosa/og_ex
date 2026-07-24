# Function Reference

This reference covers every function implemented by the OgEx Elixir library and
Takumi NIF. Public functions also have ExDoc documentation in their source
modules. Private functions are documented here because ExDoc intentionally
excludes private APIs.

## `OgEx`

- `init/1` — initializes the optional backward-compatible endpoint plug.
- `call/2` — eagerly fetches query parameters for applications that retain the
  optional plug; new applications do not need it.

## Application internals (`OgEx&#46;Application`)

- `start/2` — starts the OgEx supervisor and its default ETS cache.

## `OgEx.Card`

- `__using__/1` — imports Phoenix component functionality, installs the card
  behaviour, and records width, height, and output format.
- generated `__og_ex__/1` — returns the configured `:width`, `:height`, or
  `:format` for a card module.
- callback `metadata/1` — returns page and image metadata for the current
  assigns.
- callback `render/1` — returns the card's HEEx safe data.
- optional callback `version/1` — returns stable content data used for the image
  URL, ETag, and cache key.

## `OgEx.Controller`

- `__using__/1` — installs a controller-local OgEx-aware `render/3`.
- generated `render/3` — forwards the consuming controller's render request to
  `OgEx.Controller.render/3`.
- `render/3` — delegates ordinary renders to Phoenix; for an OgEx card, selects
  either the normal page response or signed image response and discovers the
  signature lazily.
- private `pop_card/1` — separates the `:og` card module from keyword-list or
  map template assigns.

## Configuration builder internals (`OgEx&#46;ConfigBuilder`)

- `build/3` — evaluates metadata, creates the deterministic content version and
  compact 22-character HMAC, and returns a complete `%OgEx.Config{}`.
- `verify/2` — rebuilds and securely compares the signature bound to the card,
  version, and request path.
- private `version/2` — hashes the card identity and either `version/1` output
  or full assigns into a URL-safe SHA-256 value.
- private `signature/3` — creates a 128-bit truncated HMAC.
- private `signing_key/1` — derives a domain-separated key from Phoenix's
  `secret_key_base`.
- private `image_url/2` — adds the compact signature to the current absolute URL
  while preserving unrelated query parameters.

## Request internals (`OgEx&#46;Request`)

- `image_request?/1` — lazily reports whether the reserved signature is present.
- `signature/1` — lazily fetches and returns the signature, or `nil`.

## HTML internals (`OgEx&#46;HTML`)

- `render/1` — evaluates card HEEx safely and wraps it in a complete,
  viewport-sized HTML document for the native renderer.

## `OgEx.Renderer`

- callback `render/2` — converts HTML plus rendering options into an encoded
  image binary.

## `OgEx.Renderer.Takumi`

- `render/2` — normalizes Elixir keyword options and invokes the native Takumi
  renderer.

## Native bridge internals (`OgEx&#46;Native`)

- `render_html/2` — Rustler NIF declaration. Its Elixir body raises
  `:nif_not_loaded` only if native loading failed.

## Font internals (`OgEx&#46;Fonts`)

- `load/0` — resolves every configured path or binary into loaded font bytes.
- private `load_font!/1` — reads an existing path; otherwise treats the input
  as an already-loaded binary.

## Image response internals (`OgEx&#46;ImageResponse`)

- `send/2` — verifies the request, obtains the encoded image, and sends the
  correct immutable HTTP response.
- private `cached_or_render/1` — checks the configured cache and executes the
  HTML/native rendering pipeline on a miss.
- private `render/2` — loads fonts, calls the configured renderer, and emits
  successful-render telemetry.
- private `content_type/1` — maps `:png`, `:jpeg`, `:webp`, and `:svg` to their
  HTTP media types.

## `OgEx.Cache`

- callback `fetch/1` — follows `Map.fetch/2`, returning `{:ok, image}` when
  found or `:error` when absent.
- callback `put/2` — stores an encoded image.

## `OgEx.Cache.ETS`

- `start_link/1` — starts the cache table owner.
- `fetch/1` — performs a concurrent direct ETS lookup and returns
  `{:ok, image}` or `:error`.
- `put/2` — inserts or replaces an ETS cache entry.
- `init/1` — creates the named, concurrent-read ETS table.

## Head injection internals (`OgEx&#46;Head`)

- `put_config/2` — assigns the card configuration and registers metadata
  injection before the response is sent.
- private `inject_metadata/1` — rewrites complete binary HTML responses and
  leaves unsupported response shapes unchanged.
- private `replace_closing_head/2` — inserts tags before the first
  case-insensitive `</head>` without changing the rest of the original bytes.

## Metadata internals (`OgEx&#46;Meta`)

- `to_html/1` — builds the complete escaped Open Graph and Twitter/X tag set.
- private `meta/1` — safely encodes one `<meta>` element.
- private `optional_meta/2` — omits absent values or adds a `content` attribute
  and delegates to `meta/1`.

## Native Rust functions

These functions live in `native/og_ex_native/src/lib.rs`.

- `render_html/3` — exported dirty-CPU NIF. It decodes Elixir arguments, calls
  the native pipeline, and returns `{:ok, binary}` or `{:error, reason}`.
- private `render/2` — parses HTML, parses CSS, registers fonts, runs Takumi
  layout and painting, and encodes the resulting bitmap.
- private `extract_stylesheets/1` — extracts card-local `<style>` contents
  because Takumi's HTML helper discards style elements from the node tree.
- private `output_format/1` — maps raster Elixir atoms to Takumi encoder
  settings; SVG bypasses raster encoding and uses Takumi's vector backend.
