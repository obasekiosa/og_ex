# Function Reference

This reference covers every function implemented by the OgEx Elixir library and
Takumi NIF. Public functions also have ExDoc documentation in their source
modules. Private functions are documented here because ExDoc intentionally
excludes private APIs.

## `OgEx`

- `private_asset/1` — returns an opaque private-image source for card HEEx.
- `init/1` — initializes the optional backward-compatible endpoint plug.
- `call/2` — eagerly fetches query parameters for applications that retain the
  optional plug; new applications do not need it.

## Application internals (`OgEx&#46;Application`)

- `start/2` — logs wildcard remote policy when configured and starts the
  generated-image and resource caches.
- private `warn_for_global_remote_access/0` — emits the once-per-startup SSRF
  warning for `allowed_hosts: ["*"]`.

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
- private `pop_card/1` — separates the `:og` declaration from keyword-list or
  map template assigns.

## Configuration builder internals (`OgEx&#46;ConfigBuilder`)

- `build/3` — builds either a generated-card config or a direct public,
  private, or remote image config.
- `verify/2` — rebuilds signatures and returns the authenticated Open Graph or
  Twitter image role.
- private `direct_image!/2` — normalizes a direct declaration and loads local
  bytes while leaving external URLs unfetched.
- private `load_direct!/1` — turns a loader error into a declaration error.
- private `direct_url/4` — selects a static, external, or signed private URL.
- private `dimension/2` and `format/1` — read optional inspected properties.
- private `generated_version/2` — hashes generated-card version data.
- private `direct_version/2` — hashes both direct image identities.
- private `resource_identity/1` — reduces a resource to a digest or URL.
- private `identity/2` and `resource_for/2` — reconstruct role-bound signature
  identity.
- private `signature/3` — creates a route- and role-bound 128-bit HMAC.
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

## `OgEx.Image`

- `private_asset/1` — encodes an opaque private HEEx source.
- `normalize/2` — normalizes public, private, remote, and data references.
- `load/2` — delegates a normalized source to the configured loader.
- `content_type/1` — maps verified formats to media types.
- `otp_app/1` — discovers the host endpoint's OTP application.
- `public_url/2` — creates an absolute, optionally digested Phoenix static URL.
- private `public_source/2` and `private_source/2` — resolve trusted local roots.
- private `private_root/1` — resolves configured relative roots under the app.
- private `safe_file/2` and `walk_file/3` — reject traversal, missing files,
  and symlinks.

## `OgEx.Resources`

- `load/2` — discovers unique `<img src>` references and returns verified bytes
  plus sorted fingerprints.
- private `load_source/3` — normalizes and loads one HTML source.
- private `finish/1` — finalizes deterministic fingerprint order.

## `OgEx.ResourceLoader`

- callback `load/2` — loads a normalized source into a verified resource.

## `OgEx.ResourceLoader.Default`

- `load/2` — loads local, data, or delegated remote sources.
- `from_bytes/2` — applies common native inspection and safety validation.
- private `resource/2` — constructs content-addressed verified resources.
- private `validate_dimensions/1` — enforces dimension and pixel limits.
- private `validate_svg/2` — rejects active and external SVG content.
- private `decode_data_url/1`, `within_limit/2`, and
  `configured_max_bytes/0` — enforce inline decoding and byte limits.

## `OgEx.ResourceLoader.Remote`

- `load/2` — fetches an enabled, allowlisted remote source through the bounded
  resource cache.
- private `fetch/5`, `handle_response/6`, and `request/3` — validate every hop,
  pin the selected address, stream with a byte ceiling, and handle responses.
- private `validate_destination/2`, `allowed_scheme/2`, `allowed_host/2`,
  `resolve/1`, `validate_addresses/1`, and `unsafe_address?/1` — implement the
  hostname, DNS, and SSRF policy.
- private `pinned_url/2` and `host_header/1` — connect to a validated address
  while retaining the original TLS hostname and HTTP Host.
- private `supported_content_type/1` — validates the declared media type before
  byte-level inspection.

## `OgEx.ResourceCache`

- `start_link/1` — starts the bounded cache owner.
- `fetch/1` — returns a non-expired resource or `:error`.
- `fetch_stale/1` — returns an expired entry for HTTP revalidation only.
- `put/3` — stores a resource for a configured TTL.
- `init/1` — creates the protected, concurrent-read ETS table.
- `handle_call/3` — enforces entry and byte bounds before insertion.

## `OgEx.Renderer`

- callback `render/2` — converts HTML plus rendering options into an encoded
  image binary.

## `OgEx.Renderer.Takumi`

- `render/2` — normalizes Elixir keyword options and invokes the native Takumi
  renderer.

## Native bridge internals (`OgEx&#46;Native`)

- `render_html/2` — Rustler NIF declaration. Its Elixir body raises
  `:nif_not_loaded` only if native loading failed.
- `inspect_image/1` — Rustler NIF declaration for verified format and
  dimensions.

## Font internals (`OgEx&#46;Fonts`)

- `load/0` — resolves every configured path or binary into loaded font bytes.
- private `load_font!/1` — reads an existing path; otherwise treats the input
  as an already-loaded binary.

## Image response internals (`OgEx&#46;ImageResponse`)

- `send/2` — verifies the request, obtains the encoded image, and sends the
  correct immutable HTTP response.
- private `response/3` — selects generated rendering or direct private bytes.
- private `cached_or_render/2` — loads resources, checks the fingerprint-aware
  cache key, and renders on a miss.
- private `render/3` — loads fonts and images, calls the renderer, and emits
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
- `inspect_image/1` — exported dirty-CPU NIF returning verified type and
  dimensions.
- private `render/2` — parses HTML, parses CSS, registers fonts and image
  buffers, runs Takumi
  layout and painting, and encodes the resulting bitmap.
- private `extract_stylesheets/1` — extracts card-local `<style>` contents
  because Takumi's HTML helper discards style elements from the node tree.
- private `output_format/1` — maps raster Elixir atoms to Takumi encoder
  settings; SVG bypasses raster encoding and uses Takumi's vector backend.
- private `decode_images/1`, `image_info/1`, and `detected_format/1` — register
  byte buffers and inspect supported image content without filesystem or
  network access.
