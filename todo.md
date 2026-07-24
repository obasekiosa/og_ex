# OgEx TODO

## Request coalescing

Prevent concurrent cache misses for the same image key from rendering the same
card more than once.

Proposed implementation:

- Add `OgEx.SingleFlight`, a lightweight coordinator keyed by the complete
  renderer cache key.
- Run image generation under an `OgEx.TaskSupervisor` so unrelated cards render
  concurrently and the coordinator never performs CPU-heavy work.
- Let the first caller start the render and hold subsequent callers for that
  key until it completes.
- Perform a second cache lookup after entering the flight to close the race
  between the initial miss and flight registration.
- Reply to every waiter with the same success or failure result.
- Cache only successful encoded images; allow later requests to retry failures.
- Monitor render tasks and return a structured error to all waiters if a task
  crashes.
- Add concurrency tests proving that one render occurs for simultaneous
  identical keys while different keys still render in parallel.

This initially provides single-flight behavior within one BEAM node. Distributed
coalescing can remain the responsibility of a future shared-cache adapter or
distributed lock implementation.

## Dedicated image routes

Give cards declared through the proposed controller DSL a dedicated generated
image URL instead of identifying image requests through the page URL's query
string:

```elixir
og_card :show, MyAppWeb.PostOgCard
```

```text
Page:  /posts/42
Image: /posts/42/opengraph-image/SIGNED_VERSION
```

Implementation requirements:

- Generate or install the image route from the compile-time controller/action
  declaration without requiring an application-owned image controller.
- Preserve path parameters so card loaders receive the same resource identity
  as the page action.
- Keep the image handler separate from the page action so image requests never
  execute HTML-only controller work.
- Bind the signed version to the card, controller action, canonical path,
  relevant parameters, dimensions, format, and content version.
- Reject tokens replayed against another route or card.
- Decide how generated routes integrate with Phoenix route helpers and verified
  routes.
- Define conflict detection and helpful compile-time errors when an application
  already owns the generated path.
- Support configurable route suffixes while providing one stable default.
- Preserve the existing query-string handler during migration or provide a
  documented compatibility path.
- Add routing tests for static, dynamic, nested, scoped, and conflicting routes.

## Static Open Graph and Twitter image files

Allow a controller action to select an existing static file when image
generation is unnecessary:

```elixir
og_image :about, "images/about-og.png"
twitter_image :about, "images/about-twitter.png"
```

Implementation requirements:

- Resolve files from the host application's configured `priv/static` roots.
- Support PNG, JPEG, WebP, GIF, and SVG subject to the target platform's
  compatibility requirements.
- Read image dimensions and media type automatically for generated metadata.
- Produce cache-busted URLs using the application's static asset digest when
  available.
- Reuse a single file for Open Graph and Twitter metadata by default while
  allowing separate files when their aspect ratios or formats differ.
- Allow explicit alt text and Twitter card type without requiring a renderer
  module.
- Validate missing files, unsupported media types, and invalid image headers
  during compilation when the asset is available.
- Serve files through the application's existing static asset pipeline instead
  of passing them through Takumi or the OgEx image cache.
- Define precedence and compile-time errors when an action declares both a
  generated card and a static image.
- Add tests for digested assets, separate Twitter images, dimensions, metadata,
  missing files, and production endpoint prefixes.

## Next version: local and external images

Allow ordinary card HEEx to include local and remote image sources:

```heex
<img src="/images/logo.svg" width="160" height="48" />
<img src="https://cdn.example.com/posts/cover.webp" width="480" height="320" />
```

Implementation requirements:

- Resolve root-relative local paths against a configured application's
  `priv/static` directory without allowing path traversal.
- Support explicit filesystem assets only through configured allowlisted roots.
- Fetch HTTP images through a replaceable resource-loader behaviour with strict
  connection, response, and total timeouts.
- Permit HTTPS by default and make plain HTTP an explicit opt-in.
- Prevent SSRF by rejecting loopback, private, link-local, multicast, and cloud
  metadata addresses before every request and redirect.
- Revalidate every redirect target and enforce a small redirect limit.
- Enforce maximum response bytes and accepted image content types before
  decoding.
- Support PNG, JPEG, WebP, and SVG sources; sanitize or reject unsafe SVG
  features and external references.
- Cache fetched bytes with validators such as ETag and Last-Modified while
  preventing unbounded memory growth.
- Include stable local file digests and remote resource versions in the
  generated image cache identity where possible.
- Return structured resource errors without caching incomplete card renders.
- Add tests for path traversal, redirect-based SSRF, oversized responses,
  invalid content types, timeouts, cache reuse, and deterministic local assets.
