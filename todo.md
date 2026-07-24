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
