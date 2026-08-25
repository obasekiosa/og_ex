# OgEx TODO

## Post-0.3.0 benchmarking

After `0.3.0` is released and its controller DSL, card loaders, and path/query
image routes are stable, benchmark the complete OgEx request lifecycle. Do not
optimize from isolated microbenchmarks before measuring realistic Phoenix
applications.

The benchmark suite should measure:

- HTML requests with no card, a declared card, and rendered head metadata;
- lazy signature generation and repeated metadata access within one response;
- query-mode and path-mode image-route dispatch;
- card-local `load/2` and explicit controller-loader dispatch;
- loader latency separately from renderer latency;
- generated PNG and SVG output at every documented card size;
- Takumi render throughput and latency distributions;
- local, private, remote, data-URL, and raw in-memory image sources;
- cold and warm generated-image cache behavior;
- cold and warm remote-resource cache behavior;
- request coalescing under simultaneous requests for one cache key;
- parallel requests for different cards and cache keys;
- success, missing-resource, renderer-error, and fallback-image paths;
- Open Graph-only and separate Open Graph/Twitter image generation;
- memory use, binary retention, garbage collection, scheduler utilization, and
  reductions;
- startup time and the cost of declaration registration;
- native NIF loading and first-render latency;
- output byte size and encoding time for each supported format;
- behavior on every supported Linux, macOS, and Windows native target where
  repeatable CI measurements are practical.

Use a dedicated benchmark application with realistic cards rather than the
documentation demo. Include:

- fixed local fixtures so runs are reproducible;
- a controllable local HTTP image server instead of relying on internet
  latency;
- cheap, typical, and deliberately expensive loaders;
- cards with no embedded images, one image, and several images;
- warm-up runs before recording steady-state results;
- configurable concurrency and request counts;
- percentile reporting, including at least p50, p95, and p99;
- peak and steady-state memory measurements;
- machine, operating system, OTP, Elixir, Rust, and OgEx version metadata;
- raw machine-readable results committed or attached to benchmark releases.

Compare at least:

- legacy `0.2.x` query handling against `0.3.0` query mode;
- `0.3.0` query mode against path mode;
- cache disabled, cold cache, and warm cache;
- coalescing disabled and enabled;
- PNG against SVG;
- card-local loaders against explicit declaration loaders;
- source-built native code against released precompiled NIFs;
- one BEAM scheduler configuration representative of a small deployment and
  one representative of a larger production host.

Define performance budgets only after collecting the first trustworthy
baseline. Once established, add CI regression checks with enough tolerance to
avoid treating shared-runner noise as a product regression. Keep stable
microbenchmarks in CI and run expensive end-to-end or cross-platform benchmarks
manually or on scheduled dedicated runners.

Publish a benchmark report that explains:

- the test application and workload;
- hardware and software versions;
- exact commands needed to reproduce the results;
- latency, throughput, memory, and output-size results;
- known sources of variance;
- bottlenecks found in loaders, routing, caching, rendering, and encoding;
- which optimizations are supported by measurements;
- remaining performance work and the baseline used for future releases.

The benchmark milestone is complete when another developer can reproduce the
results, compare a later OgEx version against `0.3.0`, and determine whether a
change improves throughput without hiding latency or memory regressions.

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

The complete controller DSL, loader, path/query strategy, signing, routing,
migration, and delivery design is maintained in
`todo/controller-dsl-image-routes.md`.

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

## Root and trailing-slash path-mode image URLs return 404

Confirmed empirically with a probe against the real router integration
(2026-08-24): sub-route images work, but two request-shape families fail.

Confirmed failures:

- Root page (`/`): generation emits `/opengraph-image/TOKEN`, which the
  dispatcher never recognizes, so router and endpoint integrations return
  an empty 404.
- Trailing-slash page (`/posts/42/`): the signed image path
  `/posts/42/opengraph-image/TOKEN` is recognized and dispatched, but
  verification fails. The page render binds the signature to
  `conn.request_path` (`"/posts/42/"`, untrimmed via `Request.page_path/1`)
  while the dispatcher's origin carries the regex-trimmed `"/posts/42"`,
  so the HMACs differ and the response is an empty 404. Generation trims
  (`String.trim_trailing/2`) but signing does not: inconsistent
  canonicalization of `request_path` is the common root cause.

Implementation requirements:

- Pick one canonical page-path form (trimmed), apply it identically in
  `ConfigBuilder.image_url/4`, `Request.page_path/1`, and the dispatcher
  origin, and normalize an empty page segment to `"/"`.
- Relax the recognition pattern to allow a missing page segment for root.
- Regression tests, all asserting 200 PNG responses, stable ETags, and warm
  cache hits through both `og_ex_routes()` and the endpoint plug:
  card on `/`, card on `/posts/42`, card on trailing-slash `/posts/42/`.
- Keep application routes that intentionally own trailing-slash paths
  working; document the chosen canonical form.

## Head metadata injection performance

Benchmarks (`BENCHMARKS.md`, head-injection decomposition) show tag
generation costs ~7 microseconds while whole-body rewriting dominates:
`String.downcase/1` runs twice (~171 KB allocated per pass on a 10 KB
document) followed by a full binary rebuild. Full injection measured ~701
microseconds and ~446 KB versus ~156 microseconds and ~2.7 KB for the same
response without OgEx.

Hard constraint: injection stays non-destructive. The application's HTML must
remain byte-for-byte identical outside OgEx's own inserted tags, applications
must not have to change their HEEx, templates, or root layout, and no user
markup may be reformatted or normalized. Every candidate below must preserve
this contract; the assigns-based option is only acceptable if it can be
installed transparently by `use OgEx.Controller`.

Candidates to benchmark against each other, then keep the winner:

- Single-pass case-insensitive match: reuse one downcased copy for the guard
  and the insertion search. Search-only allocation; the rebuilt body still
  slices the original bytes so nothing else changes.
- Fast-path lowercase match: search for common casings with
  `:binary.compile_pattern/1` and no downcase allocation at all. Misses
  exotic casings such as `</HeAd>`.
- Assigns-based injection: expose the rendered tags as an assign consumed by
  the root layout so tags are produced during normal rendering without any
  post-send body rewrite. Only viable if `use OgEx.Controller` can install it
  without applications editing their layouts, with the string-search path
  kept as the default fallback.

Requirements: keep escaping guarantees and optional-tag omission; add a
before/after bench job; memory allocations must drop measurably or the
approach is rejected.

## Font binary caching

`OgEx.Fonts.load/0` performs `File.read!/1` on every generated-cache miss:
~16 microseconds plus a ~1 MB binary copied into the NIF per cold render
(`BENCHMARKS.md`, section on native memory).

Plan:

- Cache loaded font binaries in `:persistent_term`, keyed by the configured
  font list (paths plus mtime for filesystem entries; byte values pass
  through unchanged).
- Invalidate when application configuration changes; expose no new public
  API beyond current behavior.
- Re-run the `font load per cache miss` bench job before and after; the miss
  path should lose the file read entirely.
- A native parsed-font registry (fonts parsed once inside the NIF) remains a
  larger future option and should be designed separately.

## Generated-image cache eviction policies

The default `OgEx.Cache.ETS` has no TTL, LRU, or size bound (verified during
benchmarking: 1000 probe entries all survive; ~40 KB RSS per distinct
1200x630 card). Capacity grows until the node stops or the owner restarts.

Decisions made:

- Default stays unbounded for backward compatibility with 0.3.x.
- Opt-in settings, combinable:
  - `max_entries` and/or `max_bytes` size bounds;
  - TTL-based expiry;
  - eviction policy per table: `:none` (default), `:lru`
    (least-recently-used approximation), or `:clear_all` (reset the table on
    overflow, matching `OgEx.ResourceCache` semantics).

Implementation requirements:

- Route `put/2` through the GenServer only when a bound, TTL, or policy is
  active; keep today's lock-free direct `:ets.insert` fast path in unbounded
  mode.
- Track per-entry byte sizes for `max_bytes`; store last-access ticks for
  `:lru` without regressing hit latency beyond an accepted, measured margin.
- Emit `[:og_ex, :cache, :evict]` telemetry with evicted counts and
  reclaimed bytes.
- Document interaction with planned request coalescing
  (`OgEx.SingleFlight`): eviction must not resurrect the simultaneous-miss
  storm coalescing exists to prevent.
- Tests: bound enforcement for entries, bytes, and TTL; LRU ordering;
  clear-all reset behavior; unbounded default unchanged; owner-restart
  recovery.
- Benchmarks: extend `bench/cache_bench.exs` with bounded-versus-unbounded
  put and hit scenarios; record results in `BENCHMARKS.md`.

## Rendered-output identity for cards without version/1

Idea from consumer feedback (todo/think-about.txt): when a card does not
define version/1, derive its content identity from the SHA-256 of the fully
rendered card fragment instead of hashing the raw assigns map. version/1
remains an explicit override for cache-burst values.

Pros: template and CSS changes automatically change URLs (removing the
manual layout-revision footgun); assigns the template never uses stop
affecting identity; most cards lose boilerplate. Cons: volatile assigns
such as timestamps churn URLs and grow the unbounded cache; page-assigns
versus loader-assigns divergence becomes a 404 risk for every default
card rather than only risky version/1 implementations.

Speed impact (0.3.0 baseline): page-request metadata cost roughly doubles
(plus 50-100 microseconds of HEEx evaluation and hashing on top of the
34 microsecond config build); warm cache hits gain the same recompute and
stay under 1 millisecond; cold misses are unchanged because they render
anyway.

Requirements:

- ConfigBuilder evaluates the card fragment during page requests when
  version/1 is absent and stores the digest in OgEx.Config for signing
  and cache keys; image requests recompute identically from loader assigns
- version/1 override semantics and their tests remain unchanged
- Document the volatile-assign hazard and the assigns-divergence contract
- Bench before and after: config-build signing cost and warm-hit cost
- Sequence after eviction policies land, as the safety net for URL churn
