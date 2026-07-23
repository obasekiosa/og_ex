# Implementation Architecture and Dependencies

This document describes how the approaches can share one implementation and
what an initial Elixir package would require.

## Proposed package boundary

```text
OgEx
├── Config                 normalized metadata and card declaration
├── Controller             OgEx-aware `render/3` for Plug.Conn
├── LiveView               `og/2` for Phoenix.LiveView.Socket
├── Meta                   Phoenix component that emits `<meta>` tags
├── Card                   metadata callback and HEEx render behavior
├── Plug                   detects and serves image requests
├── Renderer               backend behavior
├── Renderer.Chromium      HEEx/HTML/CSS to PNG
├── Cache                  cache behavior
├── Cache.ETS              local default cache
├── ResourceLoader         fonts and local/remote images
└── TemplateEngine         optional `.og.heex` compiler
```

All public APIs normalize to:

```elixir
%OgEx.Config{
  title: "Building with Phoenix",
  description: "A practical introduction",
  type: "article",
  canonical_url: "https://example.com/posts/42",
  image_url: "https://example.com/posts/42?__og_image=7e948f81",
  image_alt: "Social card for Building with Phoenix",
  width: 1200,
  height: 630,
  format: :png,
  card: {MyAppWeb.PostCard, %{post: post}},
  cache_key: "7e948f81"
}
```

## Request lifecycle

### HTML request

```text
GET /posts/42
  -> Phoenix router
  -> controller action loads post
  -> OgEx-aware render/3 builds OgEx.Config
  -> normal Phoenix page render
  -> endpoint plug inserts OG and Twitter/X tags before </head>
```

### Image request

```text
GET /posts/42?__og_image=7e948f81
  -> OgEx.Plug recognizes reserved parameter
  -> route/action loads post and calls OgEx-aware render/3
  -> render/3 verifies the token and selects the image branch
  -> card HEEx is rendered through Chromium
  -> cache lookup/coalescing
  -> renderer returns PNG bytes
  -> response gets content type, ETag, and cache headers
```

Re-running the controller action is convenient but difficult to intercept
cleanly after Phoenix dispatch. A more maintainable production implementation
may internally rewrite the image request to a library controller that can:

1. Recognize the original route.
2. invoke a registered loader/card specification;
3. render the image without attempting the HTML response.

That design requires route registration, but avoids fragile render interception.

## Routing options

### Reserved query parameter

```text
/posts/42?__og_image=HASH
```

Pros:

- No extra user-written route.
- Preserves the page's path and parameters.
- Easy to generate from `current_url(conn)`.

Cons:

- The action may execute twice.
- The library must intercept rendering safely.
- Existing query parameters must be retained.
- CDN cache rules sometimes treat query parameters differently.

### Generated suffix route

```text
/posts/42/__og__/HASH.png
```

Pros:

- Unambiguous image endpoint.
- CDN-friendly immutable URL.
- Does not overload content negotiation.

Cons:

- Requires a router macro or generated catch-all route.
- Must avoid collisions with application routes.
- Needs a loader capable of rebuilding assigns.

### Accept-header content negotiation

```http
GET /posts/42
Accept: image/png
```

This should not be the primary strategy. Crawlers request the exact `og:image`
URL and caches can mishandle one URL that varies by `Accept`. It also prevents
the metadata from pointing to an obviously immutable asset.

## Rendering approaches

### SVG templates plus `resvg`

Build an SVG document using Elixir data/components, then convert it to PNG.

Possible dependencies:

```elixir
{:resvg, "~> 0.1"} # exact package/API must be validated before release
```

or reuse/integrate the rendering code behind:

```elixir
{:og_image_gen, "~> 0.1"}
```

Advantages:

- Fast and deterministic.
- Much lighter than Chromium.
- Suitable for precompiled Rust NIFs.
- Good typography and vector output.

Costs:

- HTML/CSS compatibility must be intentionally limited.
- Text wrapping and flex layout need an engine or custom implementation.
- NIF binaries must cover supported CPU/OS targets.

This remains a possible future lightweight backend, but it is not the
recommended first implementation because it would require a restricted markup
model or a custom layout DSL.

### Native image composition with `Image`

Use the Elixir `Image` package/libvips to compose backgrounds, text, and images.

Possible dependency:

```elixir
{:image, "~> 0.62"}
```

Advantages:

- Mature bitmap operations.
- Supports resizing, cropping, compositing, and common formats.
- No browser process.

Costs:

- Requires `libvips` or compatible prebuilt/native setup.
- Layout and rich text must be implemented.
- Does not naturally consume HEEx/CSS.

This is a good backend for a data-oriented card DSL.

### HTML/CSS screenshot with `chromic_pdf`

Render ordinary HTML and take a screenshot using Chrome DevTools.

Possible dependency:

```elixir
{:chromic_pdf, "~> 1.17"}
```

Advantages:

- Highest HTML/CSS fidelity.
- Can reuse application fonts and design-system CSS.
- Existing HEEx templates are straightforward.

Costs:

- Requires Chromium in development and production.
- Higher memory use and cold-start latency.
- Browser process supervision and sandboxing complicate deployment.
- Remote content and JavaScript create security/reliability concerns.

This is the recommended default because OgEx's primary design goal is to let
developers describe cards with familiar HEEx, HTML, and CSS. The deployment
cost of Chromium should be documented clearly.

### External Satori/Takumi service

Run a small Node/Bun/Rust renderer beside Phoenix and call it over HTTP or a
Port.

Advantages:

- Can approach the Next.js/Satori component and flexbox model.
- Keeps renderer crashes outside the BEAM.
- Reuses established layout implementations.

Costs:

- Adds another runtime or sidecar.
- Requires protocol, deployment, health-check, and timeout handling.
- No longer a purely embedded Elixir package.

This may be valuable as an adapter, but conflicts with the simplest embedded
deployment story.

## Core dependencies

An initial Phoenix package would likely use:

```elixir
defp deps do
  [
    {:plug, "~> 1.15"},
    {:phoenix, "~> 1.7"},
    {:phoenix_html, "~> 4.0"},
    {:jason, "~> 1.4", optional: true},
    {:telemetry, "~> 1.2"},

    # Default HEEx/HTML/CSS screenshot renderer:
    {:chromic_pdf, "~> 1.17"}
  ]
end
```

LiveView support should remain optional:

```elixir
{:phoenix_live_view, "~> 1.0", optional: true}
```

Remote asset loading could use:

```elixir
{:req, "~> 0.5", optional: true}
```

Exact versions should be selected and tested when implementation begins; the
values above describe the dependency shape rather than a final lockfile.

## Metadata integration

For the minimal application API, the endpoint-level `OgEx` plug registers a
`before_send` callback. The controller stores a normalized config in the
connection and the callback inserts escaped tags immediately before
`</head>`.

This requires explicit handling for streamed responses, compressed response
bodies, missing or malformed head elements, and non-HTML content types. OgEx
should expose an optional `<OgEx.meta>` component as a stricter alternative,
but it is not required by the default API.

The component must:

- HTML-escape all values.
- emit absolute image and canonical URLs;
- omit absent optional properties;
- deduplicate properties;
- set `twitter:card` to `summary_large_image` by default;
- allow global defaults from application configuration.

Example defaults:

```elixir
config :og_ex,
  endpoint: MyAppWeb.Endpoint,
  site_name: "Example",
  default_card: MyAppWeb.DefaultCard,
  renderer: OgEx.Renderer.Chromium,
  cache: OgEx.Cache.ETS
```

## Caching

The cache key should include:

- card module/template digest;
- normalized assigns or explicit version;
- renderer version;
- width, height, and format;
- font and local asset digests.

Do not hash arbitrary structs blindly: they may contain processes, associations,
or unstable fields. Prefer an explicit `version:` or a card callback:

```elixir
@callback cache_key(assigns :: map()) :: term()
```

Recommended layers:

1. Browser/CDN caching with immutable versioned URLs.
2. In-process ETS cache for generated bytes.
3. Optional disk, object-storage, or user-provided distributed cache.
4. Request coalescing so simultaneous misses generate the image once.

Multi-node deployments either need a shared cache or must accept that each node
may render the same deterministic card once.

## Resource loading and security

Remote image loading is an SSRF risk. A production loader should:

- disable remote URLs by default;
- allow only `https`;
- support hostname allowlists;
- reject loopback, link-local, and private network addresses;
- revalidate redirects and resolved IP addresses;
- enforce connection/read timeouts and maximum byte sizes;
- limit decoded image dimensions;
- cache fetched assets;
- never execute JavaScript in the SVG backend.

Card generation also needs:

- render timeouts;
- concurrency limits;
- maximum text and node counts;
- decompression-bomb protection;
- safe font parsing through the chosen backend;
- telemetry without logging sensitive assigns.

## Failure behavior

For HTML requests, invalid card configuration should not normally take down the
page in production. Emit metadata without `og:image`, use a configured fallback,
and record telemetry.

For image requests:

- return a configured fallback image when possible;
- otherwise return `422` for invalid card input;
- return `503` for temporary renderer/resource failure;
- do not cache temporary failures as immutable successes.

In development, raise detailed errors with the component/template source.

## Telemetry

Suggested events:

```text
[:og_ex, :render, :start]
[:og_ex, :render, :stop]
[:og_ex, :render, :exception]
[:og_ex, :cache, :hit]
[:og_ex, :cache, :miss]
[:og_ex, :resource, :fetch]
```

Measurements should include duration and output size. Metadata should include
card module, renderer, format, and cache status—not arbitrary assigns.

## Development experience

Useful development features:

- `mix og_ex.install` to add the plug and layout component;
- a preview route with viewport presets;
- automatic regeneration when card modules/templates change;
- warnings for unsupported styles;
- a `mix og_ex.audit` command that checks page metadata and image URLs;
- snapshot fixtures for component tests.

## Suggested delivery phases

### Phase 1: Minimal controller library

- Reusable card behavior whose `render/1` returns HEEx.
- OgEx-aware controller `render/3`.
- Endpoint plug for automatic metadata insertion.
- Signed query parameter on the existing page route.
- Supervised ChromicPDF/Chromium screenshot backend.
- ETS caching, ETags, and telemetry.

### Phase 2: Automatic same-page image URLs

- Reserved query-parameter plug.
- Stable action/loader registration.
- Request coalescing and pluggable caches.
- Remote-resource policy.

### Phase 3: Templates and LiveView

- `.og.heex` engine.
- LiveView socket helper.
- Router macro for LiveView image endpoints.
- Development preview and file watcher.

## Primary technical decision

The most important early choice is whether “template” means:

1. a constrained, Satori-like flexbox component language rendered by SVG; or
2. real browser HTML/CSS rendered through Chromium.

OgEx chooses the second for its initial developer experience: real HEEx,
HTML, and CSS rendered through Chromium. The public `OgEx.Card` behavior should
still hide the backend so an SVG-based renderer can be added later for users
who prefer a smaller deployment and accept restricted CSS.
