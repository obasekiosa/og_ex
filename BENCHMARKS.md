# OgEx Benchmarks

Baseline performance measurements for OgEx 0.3.1 covering the Takumi native
renderer, the complete request lifecycle, the generated-image cache, native
memory retention, and direct-image metadata builds.

- Benchmark code: `bench/`
- Raw machine-readable logs: `bench/results/*.log` (per-version, e.g. `render_20260826_233120.log`)
- Measurement tool: [Benchee](https://hex.pm/packages/benchee) 1.5.1
  (warmup 2 s, measurement 5–6 s per scenario, memory and reduction tracking
  enabled, single process, no parallelism)

> This document reflects a single version. Each hexdocs release snapshots the
> benchmarks for that version; historical logs remain in `bench/results/` but
> are not duplicated here.

## Environment

| Item | Value |
| --- | --- |
| Date | 2026-08-26 (UTC) |
| Host | darkPrimus |
| OS | Linux 6.11.0 |
| CPU | 13th Gen Intel Core i9-13900H, 20 logical cores |
| Memory | 48 GB |
| OTP | 28 (erts 16.3.1), JIT enabled |
| Elixir | 1.19.5 |
| OgEx | 0.3.1, locally built native NIF (`OG_EX_BUILD=1`) |
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
| SVG 600x600 | 2303.33 | 0.43 ms | 0.39 ms | 1.30 ms |
| SVG 1200x630 | 820.37 | 1.22 ms | 1.12 ms | 2.72 ms |
| PNG 600x600 | 190.37 | 5.25 ms | 4.67 ms | 14.95 ms |
| PNG 1200x630 | 48.96 | 20.43 ms | 18.40 ms | 52.71 ms |
| WebP 1200x630 | 42.50 | 23.53 ms | 22.71 ms | 33.27 ms |
| JPEG 1200x630 | 37.45 | 26.70 ms | 25.57 ms | 52.72 ms |

Encoded output size for one realistic wide card:

| Format | Bytes |
| --- | ---: |
| WebP | 27,278 |
| SVG | 22,360 |
| PNG | 50,659 |
| JPEG | 60,649 |

Cold first-render per format (includes lazy NIF/font initialization):
PNG 23.9 ms, JPEG 65.3 ms, WebP 26.8 ms, SVG 1.7 ms.

Observations:

- Rasterized bitmap formats cost roughly the same order of magnitude;
  encoding choice shifts the total by ~50%. SVG skips rasterization entirely
  and is ~20x faster than PNG at steady state.
- The NIF runs on dirty CPU schedulers, so renders do not block normal
  schedulers; throughput scales with cores for concurrent crawler traffic.
- Repeated identical inputs get measurably faster as the native side warms up;
  benchmark medians include this warm-up.
- Absolute numbers vary noticeably between runs on this laptop (a pure-Takumi
  wide-card render measured anywhere from ~18 ms to ~62 ms median across
  sessions in 0.3.0 baselines) due to turbo/thermal states. Compare ratios
  within one log, not absolute values across logs. 0.3.1 steady-state renders
  measured ~3× faster than the 0.3.0 session on the same host — well within
  expected inter-session variance; ratios and memory/reduction profiles are
  stable.

## 2. Request lifecycle

Full path-mode dispatch through a real Phoenix router with `og_card`
declarations:

| Scenario | ips | median | 99th % | memory/op |
| --- | ---: | ---: | ---: | ---: |
| Card load dispatch (`__og_ex_load__`) | 191.63 K | 4.12 µs | 17.55 µs | 2.30 KB |
| Endpoint plug pass-through (no card) | 175.78 K | 4.54 µs | 17.90 µs | 2.60 KB |
| Config build + signing | 52.28 K | 16.21 µs | 65.14 µs | 6.83 KB |
| HTML page request (card declared) | 3.32 K | 205.40 µs | 3855.46 µs | 33.84 KB |
| Image request warm cache | 2.21 K | 205.60 µs | 4851.20 µs | 136.67 KB |
| Head injection (isolated) | 0.96 K | 732.71 µs | 4592.91 µs | 445.80 KB |
| Image request cold cache | 0.0503 K | 17986.11 µs | 35210.76 µs | 150.27 KB |

Observations:

- Cold image requests are completely dominated by Takumi rendering:
  lifecycle cold (~18 ms median) ≈ renderer steady-state PNG time. Everything
  OgEx adds around a miss (routing, loading, signing, verification, HEEx,
  resource scan) costs under 2 ms combined.
- Warm cache hits serve in ~200 µs (≈90× faster than a miss) because the hit
  path is verify + ETS lookup + header/body assembly.
- Signing (two HMAC-SHA256 truncations per page render) costs tens of
  microseconds; it is not a bottleneck even on high-traffic HTML pages.
- The endpoint plug candidate check adds ~5 µs to ordinary non-OgEx requests.
- HTML page cost and head-injection cost are ~2× lower than the 0.3.0
  session — consistent with inter-session turbo variance, not a code delta.
  Head injection remains the dominant page-path cost (see §6).

## 3. Generated-image cache

Implementation: `OgEx.Cache.ETS`, a public `set` table with
`read_concurrency: true`, owned by a GenServer so the table dies with its
owner. Reads bypass the GenServer mailbox entirely.

### Hit latency

| Scenario | ips | median | memory/op |
| --- | ---: | ---: | ---: |
| Direct `OgEx.Cache.fetch/1` (ETS get) | 2729.29 K | 0.21 µs | 0.24 KB |
| Signature verify (HMAC compare) | 219.72 K | 3.87 µs | 0.68 KB |
| Full warm request through router | 2.17 K | 231.11 µs | 136.67 KB |

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
| Average cold render | 18.4 ms |
| RSS before / after / peak | 133.5 MB / 134.4 MB / 134.4 MB |
| RSS delta over 150 renders | 0.9 KB total (~6.05 KB/render retained) |
| BEAM processes/binary/ets deltas | −249 KB / +11 KB / 0 KB, no growth trend |

No leak detected: repeated renders return their native allocations; RSS stays
flat. Per-render garbage (layout trees, pixel buffers, encoded output) is
freed by the native allocator.

One avoidable per-miss cost lives on the Elixir side: `OgEx.Fonts.load/0`
re-reads the configured font file on **every cache miss**
(19.8 µs median, 1.05 KB BEAM-side; the file itself is ~1 MB passed into the
NIF). A font registry that parses once would shave a little latency and some
I/O from every cold render.

## 5. Direct-image metadata builds (HTML request path)

These strategies never invoke Takumi; they build metadata while rendering the
normal page:

| Strategy | ips | median | memory/op |
| --- | ---: | ---: | ---: |
| Remote URL (no fetch by design) | 171.21 K | 4.90 µs | 3.17 KB |
| Private local file (read + inspect + sign) | 5.42 K | 164.18 µs | 26.27 KB |
| Public static file (read + inspect) | 4.60 K | 186.24 µs | 34.86 KB |

Local files pay one filesystem read plus security checks (traversal/symlink
walk) per image per page render (hundreds of microseconds, worth remembering
for pages that declare several direct images).

## 6. Head-injection decomposition

Why is `<meta>` insertion measurably expensive? Broken down on a ~10.4 KB
HTML document (0.3.1 medians in parens; 0.3.0 §6 for comparison):

| Step | Median | Allocated |
| --- | ---: | ---: |
| Build the meta tags themselves (`Meta.to_html`) | 7.58 µs | 7.09 KB |
| `String.downcase(body)` + scan for `</head>` | ~140 µs (0.3.0) | ~171 KB |
| Split + rebuild body around the tags | ~186 µs (0.3.0) | ~171 KB |
| Same response, no OgEx (raw `send_resp`) | 222.07 µs | 2.68 KB |
| Full head injection | 732.71 µs (lifecycle) / 998.86 µs (isolated) | 445.80 KB |

Findings:

- Tag generation is trivial. Essentially all cost is whole-body rewriting:
  the document is lowercased and scanned **twice** (once for the `contains?`
  guard, once to locate the insertion point), and then rebuilt as a new
  binary. Each `String.downcase/1` alone allocates ~16x the document size.
- Net effect on a 10 KB page: ~3–4× response-path latency and ~165× memory
  versus the same response without OgEx. Cost scales linearly with page size.
- Cheap wins if this ever matters: lowercase-search only once (reuse the
  downcased copy or search for both `</head>` casings with
  `:binary.compile_pattern/1`), and inject via iodata instead of binary
  concatenation to avoid the full rebuild.

## Known sources of variance

- Laptop turbo/thermal states moved pure-render medians up to ~3x between
  sessions. Within-run ratios are stable; cross-run absolutes are not.
  0.3.1 measured faster than 0.3.0 on the same host — expected variance.
- Benchee's memory counter covers the benchmarked process only. Native
  allocations require external observation (RSS sampling, as in section 4).
- Cold-cache scenarios insert every rendered card into the unbounded ETS
  cache; long benchmark sessions grow RSS by design (see section 3).
- Historical logs remain in `bench/results/` (e.g. `*_20260824_*.log` for
  0.3.0) but are not duplicated here; each version's document shows only that
  version's baseline.
