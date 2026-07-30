# Automatic card fingerprints and cache invalidation

## Status

Future work. The current `Card.version/1` contract is sufficient for now and
remains unchanged.

Today, OgEx hashes the value returned by `Card.version/1`, or the complete
assigns map when that optional callback is omitted. Card source, HEEx, CSS,
fonts, renderer changes, and other resources are not automatically included.
Applications can include a layout revision in `version/1` to invalidate an
image after a presentation-only change.

## Goal

Build a deterministic content fingerprint from the inputs that can affect the
rendered image. A changed input should produce a new signed image URL, ETag,
and generated-image cache key without requiring operators to clear caches.

The fingerprint should cover:

- the value returned by `Card.version/1`, or normalized assigns;
- the compiled card module;
- discoverable shared rendering modules and components;
- configured font contents;
- embedded local image contents;
- renderer implementation and version;
- dimensions, format, quality, and relevant renderer options;
- resource-policy configuration that affects rendering;
- external resources according to an explicit revalidation policy.

## Proposed model

Use two related fingerprints:

```elixir
static_fingerprint =
  hash({
    card_module_fingerprint,
    rendering_dependencies,
    font_hashes,
    renderer_identity,
    render_options
  })

content_fingerprint =
  hash({
    static_fingerprint,
    Card.version(assigns),
    resolved_local_resources,
    resolved_external_resources
  })
```

The final content fingerprint should feed the signed URL, ETag, and generated
image cache key.

## Card and template changes

Investigate a stable fingerprint derived from compiled BEAM code or compile-time
source information. It should change when `render/1`, embedded CSS, or another
function in the card module changes.

Do not assume the card module alone captures every dependency. A card can call
a shared function component whose module changes independently. Evaluate:

- tracking modules referenced by the compiled card;
- a declared dependency list for shared components;
- a compile-time macro that records rendering dependencies;
- a manual dependency fingerprint callback as an escape hatch.

Avoid relying on private compiler details without compatibility tests across
supported Elixir and OTP versions.

## Fonts and local resources

Hash font and local-image bytes rather than paths or modification times.
Content hashes remain correct across release extraction, copied files, and
timestamp changes.

Cache file digests using verified file metadata so ordinary requests do not
reread large files unnecessarily. Recalculate safely when size, modification
time, inode identity, or release identity changes.

Private and public local images embedded into generated cards should contribute
their content digest. Direct images that OgEx does not render need separate
semantics because changing their bytes may not require regenerating a card.

## External resources

OgEx cannot know whether a remote resource changed without contacting its
origin. Do not perform unconditional remote downloads merely to calculate a
cache key.

Design an explicit policy supporting:

- immutable external URLs;
- a configurable time-to-live;
- conditional requests using `ETag` and `Last-Modified`;
- cached byte digests after a successful fetch;
- stale-on-error behavior;
- request timeouts and maximum response sizes;
- per-host policy overrides;
- manual invalidation.

Define whether external revalidation happens before cache lookup, in the
background, or only after expiration. Benchmark the latency and origin-load
tradeoffs.

## Renderer and configuration identity

Include inputs that can alter output bytes:

- OgEx renderer module;
- Takumi/native renderer version;
- output format;
- width and height;
- quality or compression settings;
- font selection and ordering;
- relevant resource-loader behavior.

Prefer explicit renderer fingerprint callbacks over guessing from application
versions.

## Manual revision escape hatch

Retain an application-controlled revision even after automatic fingerprinting.
Some runtime dependencies cannot be discovered reliably.

Recommended form:

```elixir
@layout_revision 2

def version(%{post: post}) do
  {:post_card, @layout_revision, post.id, post.updated_at}
end
```

The atom is an application-chosen card label and the integer is a cache-busting
layout revision. Neither is the OgEx package version or image-route strategy.

Consider a dedicated option or callback that separates manual layout revision
from content data, while retaining backward compatibility with `version/1`.

## Cache operations

Add explicit cache-management APIs for development and operational recovery:

- clear all generated images;
- invalidate one card module;
- invalidate one page/card/role combination;
- inspect cache entries and their fingerprint inputs;
- support distributed cache implementations.

Cache clearing is not a replacement for changing the fingerprint. Browsers,
CDNs, proxies, and social platforms may retain an old immutable URL after the
server-side cache has been cleared.

## Development and deployment behavior

In development, code reloading should produce a new card-module fingerprint
after recompilation. The next image request should render new output without
restarting the server or manually increasing a revision for card-local changes.

In production, a new release should naturally produce new fingerprints for
changed compiled modules and bundled resources. Confirm behavior for rolling
deployments where old and new nodes briefly coexist. URLs and verification must
remain valid during the transition.

## Inspiration and limits

Next.js treats generated metadata images as specialized route handlers. It
relies on its build system, bundled module graph, static optimization, and data
cache/revalidation rules rather than hashing every rendering input on every
request.

OgEx does not have an equivalent JavaScript bundler graph. Its design should
borrow the useful result—code and tracked resources invalidate build
artifacts—without claiming it can automatically discover every runtime
dependency.

## Testing

Add tests proving that the image URL and cache key change when:

- assigns or `Card.version/1` output changes;
- card HEEx or embedded CSS changes;
- a declared shared component changes;
- a configured font's bytes change;
- a local embedded image changes;
- renderer identity or render options change;
- an external resource is revalidated with a new ETag or byte digest.

Also prove that:

- unchanged inputs preserve stable URLs across processes;
- file timestamp changes without byte changes do not invalidate content;
- failed external revalidation follows the configured stale/error policy;
- rolling nodes can serve and verify URLs generated by either release where
  compatibility is expected;
- fingerprint calculation does not add unacceptable HTML-request latency.

## Documentation

Document which inputs are detected automatically, which require declarations,
and which still require a manual revision. Include debugging output that lets a
developer understand why a fingerprint changed.

