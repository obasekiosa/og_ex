# Changelog

## 0.3.1

This release fixes path-mode image dispatch for root and trailing-slash pages,
makes page-path signing canonical, and rebuilds font configuration around lazy
entries that never touch the filesystem during compilation.

- Path-mode images now work on the root page: `/` signs
  `/opengraph-image/TOKEN` URLs that dispatch correctly through both router
  and endpoint integrations.
- Page paths are canonicalized before signing: trailing slashes are trimmed,
  so a page served at `/posts/42/` signs `/posts/42`. Signed image requests
  verify against the same canonical form.
- Signed image URLs minted by previous releases for trailing-slash pages are
  still verified this release. That compatibility path emits
  `[:og_ex, :signature, :legacy]` telemetry, logs a deprecation warning once
  per node, and will be removed in a future version. OgEx also logs a
  deprecation notice once at startup.
- Image signatures bound to one page are rejected when replayed against
  another page's image URL (unchanged behavior, now regression-tested).
- Font configuration accepts lazy entries that never touch the filesystem
  during compilation, release assembly, or application boot: `{:ogex_font,
  path}` markers resolved against `config :og_ex, :otp_app`, `{mod, fun,
  args}` tuples, and zero-arity functions returning a path or font bytes.
  The marker is plain data, so evaluating application config never requires
  OgEx to be compiled. `OgEx.font/1` returns the same tuple for contexts
  where OgEx is already loaded. Plain binary entries keep their historical
  behavior.
- Invalid font configuration now fails structurally instead of surfacing as a
  native decoding error: image requests return a non-cacheable `503`, OgEx
  logs the exact reason once per node, and application boot warns about
  unrecognized entry shapes.
- A Benchee benchmark suite with the recorded 0.3.0 baseline lives in
  `bench/`, and the published report in BENCHMARKS.md explains how to
  reproduce it.

## 0.3.0

Released July 30, 2026.

This release introduces the controller card DSL and dedicated image dispatch.

- `og_card :show, PostOgCard` associates a card with one controller action.
- `Card.load/2` loads image data without running the normal controller action.
- A controller function passed with `load:` can replace the card loader.
- `image_route: :path` generates `/opengraph-image/TOKEN` and
  `/twitter-image/TOKEN` URLs.
- `image_route: :query` generates `?__og_ex=TOKEN` URLs.
- Path requests can be handled by `og_ex_routes()` in the router or by
  `plug OgEx, router: MyAppWeb.Router` in the endpoint.
- Duplicate declarations and simultaneous router/endpoint integrations are
  detected instead of being silently accepted.
- Loader failures return non-cacheable `404` or `503` responses.
- The 0.2 `render(..., og: ...)` API remains available during migration.

## 0.2.0

Released July 28, 2026.

This release introduces local and remote image sources.

- Generated HEEx cards can contain `<img>` elements.
- Root-relative paths load images from the Phoenix `priv/static` directory.
- `OgEx.private_asset/1` loads a private local file without exposing a public
  URL.
- HTTPS images can be downloaded from an explicit host allowlist.
- Remote loading includes byte, dimension, pixel, redirect, and timeout limits.
- Direct-image declarations can point `og:image` at an existing local or
  external file instead of generating a new image.
- Local image content is inspected to determine its actual format and
  dimensions.

## 0.1.0

Released July 24, 2026.

This is the first OgEx release and introduces generated social cards for
Phoenix controllers.

- `use OgEx.Card` defines card dimensions and output format.
- `metadata/1` defines Open Graph and Twitter/X metadata.
- `render/1` defines the image with HEEx and CSS.
- `render(conn, template, og: CardModule)` adds metadata to the HTML response.
- A signed query URL on the same controller route returns the generated image.
- Takumi renders PNG, JPEG, WebP, and SVG output.
- Generated images use an in-memory ETS cache and immutable response headers.
- Precompiled native libraries are available for supported Linux, macOS, and
  Windows targets.
