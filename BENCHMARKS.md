# OgEx Benchmarks

Baseline performance measurements for OgEx 0.3.0 covering the Takumi native
renderer, the complete request lifecycle, the generated-image cache, native
memory retention, and direct-image metadata builds.

- Benchmark code: `bench/`
- Raw machine-readable logs: `bench/results/*.log`
- Measurement tool: [Benchee](https://hex.pm/packages/benchee) 1.5.1
  (warmup 2 s, measurement 5–6 s per scenario, memory and reduction tracking
  enabled, single process, no parallelism)

## Environment

| Item | Value |
| --- | --- |
| Date | 2026-08-24 (UTC) |
| Host | darkPrimus |
| OS | Linux 6.11.0 |
| CPU | 13th Gen Intel Core i9-13900H, 20 logical cores |
| Memory | 48 GB |
| OTP | 28 (erts 16.3.1), JIT enabled |
| Elixir | 1.19.5 |
| OgEx | 0.3.0, locally built native NIF (`OG_EX_BUILD=1`) |
| Font | NimbusSans-Regular.otf (single configured font) |

### Reproducing

```bash
OG_EX_BUILD=1 mix run bench/render_bench.exs     # renderer formats/sizes
OG_EX_BUILD=1 mix run bench/lifecycle_bench.exs  # request lifecycle paths
OG_EX_BUILD=1 mix run bench/cache_bench.exs      # cache, memory, direct images
```

Each script prints environment metadata before its results. Save output with
`tee bench/results/<name>_$(date +%Y%m%d_%H%M%S).log`.

### Workload

Cards are realistic HEEx layouts modeled on the README example: gradient
background, eyebrow line, title, and author at 1200x630, plus a compact
600x600 variant. Requests exercise the real Phoenix router integration
(`og_ex_routes()`), controller declarations (`og_card`), card-local loaders,
signature generation/verification, ETS caching, head injection, and the native
Takumi render.

## Glossary

| Term | Meaning |
| --- | --- |
| **ips** | Iterations per second (Benchee's throughput measure); higher is faster. |
| **average / median / 99th %** | Latency distribution statistics across all measured iterations. Median is the most noise-resistant single number; 99th % shows tail latency. |
| **deviation** | Relative standard deviation. High values on this laptop reflect CPU frequency scaling and thermal variation between runs. |
| **reduction count** | BEAM work units. Each function call costs roughly one reduction; a process is preempted after ~4000 reductions. Reductions approximate "how much code ran" independent of CPU speed, which is useful for comparing algorithmic work, but NIF/dirty-CPU time inside Rust does not consume reductions, so render-heavy scenarios show fewer reductions than their wall time suggests. |
| **memory usage** | Heap words allocated by the calling process per iteration (BEAM allocations only; NIF-internal allocations are invisible to this counter). |
| **cold** | First render for content not in the generated-image cache: full loader → HEEx → resource scan → Takumi layout/rasterize/encode path. |
| **warm** | Cache hit: signature verify + ETS lookup + response assembly, no rendering. |

## 1. Renderer throughput by format (steady state)

1200x630 wide article card unless noted:

| Format | ips | average | median | 99th % |
| --- | ---: | ---: | ---: | ---: |
| SVG 600x600 | 505.46 | 1.98 ms | 2.11 ms | 3.79 ms |
| SVG 1200x630 | 253.45 | 3.95 ms | 3.24 ms | 8.96 ms |
| PNG 600x600 | 65.25 | 15.33 ms | 14.02 ms | 30.88 ms |
| PNG 1200x630 | 16.70 | 59.88 ms | 62.49 ms | 98.78 ms |
| WebP 1200x630 | 15.34 | 65.21 ms | 60.85 ms | 123.88 ms |
| JPEG 1200x630 | 11.36 | 88.00 ms | 86.61 ms | 135.79 ms |

Encoded output size for one realistic wide card:

| Format | Bytes |
| --- | ---: |
| WebP | 27,278 |
| SVG | 22,360 |
| PNG | 50,659 |
| JPEG | 60,649 |

Cold first-render per format (includes lazy NIF/font initialization):
PNG 110.8 ms, JPEG 119.9 ms, WebP 88.9 ms, SVG 3.0 ms.

Observations:

- Rasterized bitmap formats cost roughly the same order of magnitude;
  encoding choice shifts the total by ~50%. SVG skips rasterization entirely
  and is ~20x faster than PNG.
- The NIF runs on dirty CPU schedulers, so renders do not block normal
  schedulers; throughput scales with cores for concurrent crawler traffic.
- Repeated identical inputs get measurably faster (~2x) as the native side
  warms up; benchmark medians include this warm-up.
- Absolute numbers vary noticeably between runs on this laptop (a pure-Takumi
  wide-card render measured anywhere from ~18 ms to ~62 ms median across
  sessions) due to turbo/thermal states. Compare ratios within one log, not
  absolute values across logs.

## 2. Request lifecycle

Full path-mode dispatch through a real Phoenix router with `og_card`
declarations:

| Scenario | ips | median | 99th % | memory/op |
| --- | ---: | ---: | ---: | ---: |
| Card load dispatch (`__og_ex_load__`) | 73.56 K | 8.05 µs | 42.89 µs | 2.30 KB |
| Endpoint plug pass-through (no card) | 44.77 K | 15.48 µs | 75.45 µs | 2.73 KB |
| Config build + signing | 19.12 K | 33.75 µs | 196.02 µs | 6.45 KB |
| HTML page request (card declared) | 1.84 K | 388.89 µs | 4409.84 µs | 31.89 KB |
| Image request warm cache | 1.00 K | 694.67 µs | 5818.07 µs | 136.98 KB |
| Head injection (isolated) | 0.48 K | 1673.44 µs | 5595.25 µs | 445.80 KB |
| Image request cold cache | 0.0172 K | 58118.53 µs | 100116.31 µs | 150.05 KB |

Observations:

- Cold image requests are completely dominated by Takumi rendering:
  lifecycle cold (~58 ms median) ≈ renderer steady-state PNG time. Everything
  OgEx adds around a miss (routing, loading, signing, verification, HEEx,
  resource scan) costs under 2 ms combined.
- Warm cache hits serve in well under 1 ms (roughly 80–90x faster than a
  miss) because the hit path is verify + ETS lookup + header/body assembly.
- Signing (two HMAC-SHA256 truncations per page render) costs tens of
  microseconds; it is not a bottleneck even on high-traffic HTML pages.
- The endpoint plug candidate check adds ~10 µs to ordinary non-OgEx requests.

## 3. Generated-image cache

Implementation: `OgEx.Cache.ETS`, a public `set` table with
`read_concurrency: true`, owned by a GenServer so the table dies with its
owner. Reads bypass the GenServer mailbox entirely.

### Hit latency

| Scenario | ips | median | memory/op |
| --- | ---: | ---: | ---: |
| Direct `OgEx.Cache.fetch/1` (ETS get) | 3001.85 K | 0.21 µs | 0.24 KB |
| Signature verify (HMAC compare) | 223.35 K | 3.83 µs | 0.53 KB |
| Full warm request through router | 2.13 K | 204.96 µs | 136.98 KB |

The raw ETS fetch is effectively free; the warm-request cost above is almost
entirely Plug conn construction, route resolution, config building, HMAC
verification, and copying the ~41 KB image body into the response, not cache
access.

### Memory footprint per cached card

Measured with 1000 distinct entries of one realistic 41 KB PNG payload:

| Component | Per entry |
| --- | ---: |
| ETS table overhead (key/tuple words) | ~163 bytes |
| Payload binary on the shared binary heap | ~41 KB (= encoded image size) |
| **Total per distinct card** | **~40 KB + image bytes** |

1000 distinct cached cards ≈ 39.5 MB RSS. Memory grows linearly with the
number of *distinct* card versions ever rendered.

### Eviction behavior

- **Generated-image cache: there is none.** Inserting 1000 probe entries left
  all 1000 in place. There is no TTL, no LRU, no size bound, and no
  persistence. Entries live until the node stops or the cache GenServer
  restarts. Capacity planning is the application's responsibility; an
  unbounded stream of unique card versions will grow RSS without limit.
- **Resource cache (`OgEx.ResourceCache`, remote images only): bounded but
  blunt.** Defaults are 128 entries / 25 MB. When an insertion would exceed
  either bound the *entire table is cleared* before inserting (demonstrated
  with `max_entries: 4`: after inserting 10 distinct resources only 2
  survived (the ones inserted after the last reset). This is not LRU; expect
  thundering re-fetches after each reset.

## 4. Native (Takumi) memory retention

150 consecutive cold renders of slightly-varying wide-card documents, sampled
via process RSS (captures native heap that BEAM statistics cannot see):

| Metric | Value |
| --- | --- |
| Average cold render | 17.4–19.9 ms (varies by session) |
| RSS delta over 150 renders | −0.2 to +2.3 KB total |
| Retained per render | ~0.4–16 KB, trending to zero drift |
| Peak RSS during loop | within ~2 MB of baseline |
| BEAM processes/binary/ets deltas | ≤ ±0.3 MB, no growth trend |

No leak detected: repeated renders return their native allocations; RSS stays
flat. Per-render garbage (layout trees, pixel buffers, encoded output) is
freed by the native allocator.

One avoidable per-miss cost lives on the Elixir side: `OgEx.Fonts.load/0`
re-reads the configured font file on **every cache miss**
(15.7 µs median, 0.91 KB BEAM-side; the file itself is ~1 MB passed into the
NIF). A font registry that parses once would shave a little latency and some
I/O from every cold render.

## 5. Direct-image metadata builds (HTML request path)

These strategies never invoke Takumi; they build metadata while rendering the
normal page:

| Strategy | ips | median | memory/op |
| --- | ---: | ---: | ---: |
| Remote URL (no fetch by design) | 144.57 K | 5.01 µs | 3.17 KB |
| Private local file (read + inspect + sign) | 5.28 K | 163.83 µs | 25.64 KB |
| Public static file (read + inspect) | 3.91 K | 194.52 µs | 34.88 KB |

Local files pay one filesystem read plus security checks (traversal/symlink
walk) per image per page render (hundreds of microseconds, worth remembering
for pages that declare several direct images).

## 6. Head-injection decomposition

Why is `<meta>` insertion measurably expensive? Broken down on a ~10.4 KB
HTML document (median values):

| Step | Median | Allocated |
| --- | ---: | ---: |
| Build the meta tags themselves (`Meta.to_html`) | 6.68 µs | 7.12 KB |
| `String.downcase(body)` + scan for `</head>` | 140.22 µs | 170.89 KB |
| Split + rebuild body around the tags | 186.34 µs | 170.86 KB |
| Same response, no OgEx (raw `send_resp`) | 156.43 µs | 2.68 KB |
| Full head injection | 701.04 µs | 445.71 KB |

Findings:

- Tag generation is trivial. Essentially all cost is whole-body rewriting:
  the document is lowercased and scanned **twice** (once for the `contains?`
  guard, once to locate the insertion point), and then rebuilt as a new
  binary. Each `String.downcase/1` alone allocates ~16x the document size.
- Net effect on a 10 KB page: ~4.5x response-path latency and ~165x memory
  versus the same response without OgEx. Cost scales linearly with page size.
- Cheap wins if this ever matters: lowercase-search only once (reuse the
  downcased copy or search for both `</head>` casings with
  `:binary.compile_pattern/1`), and inject via iodata instead of binary
  concatenation to avoid the full rebuild.

## Known sources of variance

- Laptop turbo/thermal states moved pure-render medians up to ~3x between
  sessions. Within-run ratios are stable; cross-run absolutes are not.
- Benchee's memory counter covers the benchmarked process only. Native
  allocations require external observation (RSS sampling, as in section 4).
- Cold-cache scenarios insert every rendered card into the unbounded ETS
  cache; long benchmark sessions grow RSS by design (see section 3).
