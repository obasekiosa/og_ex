# Generated-image cache, native renderer memory, and direct-image costs.
#
#   mix run bench/cache_bench.exs
#
# Sections:
#
#   1. Cold versus warm generated-image requests through the router
#   2. Cache internals: ETS fetch cost, memory per entry, eviction behavior
#   3. Takumi/native memory retention over a burst of cold renders
#   4. Direct-image metadata builds: public static, private signed, remote URL
#   5. Head-injection decomposition against a raw Plug response

Code.require_file("bench_helper.exs", __DIR__)

import Plug.Conn
import Plug.Test

# Direct public/private image resolution reads the endpoint's OTP application.
# The bench endpoint module is defined in bench_helper.exs, so pin it here.
Application.put_env(:og_ex, :otp_app, :og_ex)

router = OgEx.Bench.Router.init([])

{:ok, fonts} = OgEx.Fonts.load()

sign_image_path = fn id, assigns ->
  config =
    :get
    |> conn("/posts/#{id}")
    |> put_private(:phoenix_endpoint, OgEx.Bench.Endpoint)
    |> fetch_query_params()
    |> OgEx.ConfigBuilder.build(OgEx.Bench.WideCard, assigns, image_route: :path)

  URI.parse(config.image_url).path
end

cold_assigns = fn id ->
  integer = String.to_integer(id)
  %{title: "Loaded post #{integer}", rev: integer}
end

warm_assigns = cold_assigns.("42")
warm_path = sign_image_path.("42", warm_assigns)

dispatch_router = fn path ->
  :get
  |> conn(path)
  |> put_private(:phoenix_endpoint, OgEx.Bench.Endpoint)
  |> OgEx.Bench.Router.call(router)
end

page_conn = fn path ->
  :get
  |> conn(path)
  |> put_private(:phoenix_endpoint, OgEx.Bench.Endpoint)
  |> fetch_query_params()
end

warm_config = OgEx.ConfigBuilder.build(page_conn.("/posts/42"), OgEx.Bench.WideCard, warm_assigns)

html_document =
  "<html><head><title>Post</title></head><body>" <>
    String.duplicate(
      "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.</p>",
      120
    ) <> "</body></html>"

{:ok, warm_html} = OgEx.HTML.render(warm_config)
{:ok, _images, fingerprints} = OgEx.Resources.load(warm_html, page_conn.("/posts/42"))

cache_key = {
  OgEx.Bench.WideCard,
  warm_config.version,
  warm_config.width,
  warm_config.height,
  warm_config.format,
  fingerprints
}

verify_conn_and_config = fn ->
  signature = warm_path |> String.split("/") |> List.last()

  c =
    :get
    |> conn(warm_path)
    |> put_private(:phoenix_endpoint, OgEx.Bench.Endpoint)
    |> OgEx.Request.put_origin(
      OgEx.Bench.PathController,
      :show,
      :image,
      %{"id" => "42"},
      page_path: "/posts/42",
      signature: signature
    )

  config = OgEx.ConfigBuilder.build(c, OgEx.Bench.WideCard, warm_assigns, image_route: :path)
  {c, config}
end

{verify_conn, verify_config} = verify_conn_and_config.()

case OgEx.ConfigBuilder.verify(verify_conn, verify_config) do
  {:ok, :image} -> IO.puts("signature verify sanity: ok")
  other -> raise "signature verify sanity failed: #{inspect(other)}"
end

rss_kb = fn ->
  File.read!("/proc/self/status")
  |> String.split("\n")
  |> Enum.find_value(fn line ->
    if String.starts_with?(line, "VmRSS") do
      line |> String.split() |> Enum.at(1) |> String.to_integer()
    end
  end)
end

beam_memory = fn ->
  :erlang.memory() |> Keyword.take([:processes, :processes_used, :binary, :ets])
end

format_kb = fn kb -> Float.round(kb / 1024, 1) end

IO.puts("\n## Takumi/native memory retention (150 cold renders)\n")

# One render warms lazy NIF/font initialization; the loop measures steady-state
# retention. RSS includes native heap that BEAM memory statistics cannot see.
render_once = fn n ->
  html = String.replace(warm_html, "Benchmarking", "Retention pass #{n}")

  case OgEx.Renderer.Takumi.render(html,
         width: 1200,
         height: 630,
         format: :png,
         fonts: fonts,
         images: %{}
       ) do
    {:ok, _bytes} -> :ok
    {:error, reason} -> raise "cold render failed: #{inspect(reason)}"
  end
end

render_once.(0)
:erlang.garbage_collect()
Process.sleep(100)

rss_start = rss_kb.()
beam_start = beam_memory.()
peak_rss = rss_start

{duration_us, peak_rss} =
  Enum.reduce(1..150, {0, peak_rss}, fn n, {acc_us, peak} ->
    {us, :ok} = :timer.tc(render_once, [n])

    peak =
      if rem(n, 25) == 0 do
        max(peak, rss_kb.())
      else
        peak
      end

    {acc_us + us, peak}
  end)

:erlang.garbage_collect()
Process.sleep(100)
rss_end = rss_kb.()
beam_end = beam_memory.()

per_render_kb = (rss_end - rss_start) / 150

IO.puts(
  "RSS before: #{format_kb.(rss_start)} MB | after: #{format_kb.(rss_end)} MB | peak: #{format_kb.(peak_rss)} MB"
)

IO.puts(
  "RSS delta over 150 renders: #{format_kb.(rss_end - rss_start)} KB total (~#{Float.round(per_render_kb, 2)} KB/render retained)"
)

IO.puts("Average cold render: #{Float.round(duration_us / 150 / 1000, 1)} ms")

for {key, start_value} <- beam_start do
  delta = beam_end[key] - start_value
  IO.puts("BEAM #{key}: #{start_value} -> #{beam_end[key]} bytes (delta #{delta})")
end

IO.puts("""

## Generated-image cache footprint and eviction

The default cache is an ETS set owned by OgEx.Cache.ETS with read_concurrency.
It has no TTL, no LRU, and no size bound: entries live until the node stops or
the owner process restarts.
""")

table = OgEx.Cache.ETS
words_before = :ets.info(table, :memory)
binary_before = :erlang.memory(:binary)

probe_png =
  elem(
    OgEx.Renderer.Takumi.render(warm_html,
      width: 1200,
      height: 630,
      format: :png,
      fonts: fonts,
      images: %{}
    ),
    1
  )

probe_payload_bytes = byte_size(probe_png)

Enum.each(1..1000, fn i ->
  :ok = OgEx.Cache.ETS.put({:bench_probe, i}, :binary.copy(probe_png))
end)

words_after = :ets.info(table, :memory)
binary_after = :erlang.memory(:binary)
word_size = :erlang.system_info(:wordsize)
entry_words = (words_after - words_before) / 1000
entry_bytes = entry_words * word_size
binary_per_entry = (binary_after - binary_before) / 1000

IO.puts("Payload: one realistic 1200x630 PNG (#{probe_payload_bytes} bytes)")

IO.puts(
  "ETS table words per entry: #{Float.round(entry_words, 1)} (~#{Float.round(entry_bytes, 1)} bytes of key/tuple overhead)"
)

IO.puts(
  "BEAM binary heap growth per entry: #{Float.round(binary_per_entry, 1)} bytes (payload bytes)"
)

IO.puts(
  "Total cost per cached card: ~#{Float.round((entry_bytes + binary_per_entry) / 1024, 1)} KB; " <>
    "1000 cards ~= #{Float.round((entry_bytes + binary_per_entry) * 1000 / 1_048_576, 1)} MB RSS"
)

IO.puts("Table size after inserting 1000 probe entries: #{:ets.info(table, :size)} (no eviction)")

:ets.match_delete(table, {{:bench_probe, :_}, :_})

IO.puts("Probe entries removed; table back to #{:ets.info(table, :size)} entries.")

IO.puts("""

## Resource-cache eviction behavior

OgEx.ResourceCache is bounded (defaults: 128 entries / 25 MB). On overflow it
clears the whole table before inserting, which is not LRU. Demonstration with
max_entries: 4:
""")

if Process.whereis(OgEx.ResourceCache) == nil do
  {:ok, _} = OgEx.ResourceCache.start_link([])
end

Application.put_env(:og_ex, :resource_cache, max_entries: 4, max_bytes: 25_000_000)

fake_resource = fn i ->
  %OgEx.Image.Resource{
    source: %OgEx.Image.Source{type: :remote, reference: "https://bench.test/#{i}.png"},
    bytes: :binary.copy(<<7>>, 1024),
    content_type: "image/png",
    format: :png,
    width: 64,
    height: 64,
    fingerprint: "fp-#{i}"
  }
end

Enum.each(1..10, fn i ->
  :ok = OgEx.ResourceCache.put({:bench_res, i}, fake_resource.(i), 300_000)
end)

IO.puts(
  "Inserted 10 distinct resources with max_entries: 4; table now holds #{:ets.info(OgEx.ResourceCache, :size)} entries."
)

IO.puts("(Clear-all on overflow: survivors are whatever was inserted after the last reset.)")

# The resource table is :protected and owned by the cache GenServer, so the
# probe entries cannot be deleted externally. They are tiny and harmless; the
# config override is removed so later work uses package defaults.
Application.delete_env(:og_ex, :resource_cache)

# Seed the generated-image cache with the warm key so the direct ETS-fetch
# job measures hits from the first measurement.
dispatch_router.(warm_path)

IO.puts("""

## Steady-state latency benchmarks
""")

Benchee.run(
  %{
    "image request cold cache" => fn ->
      id = System.unique_integer([:positive])
      id_string = Integer.to_string(id)
      dispatch_router.(sign_image_path.(id_string, cold_assigns.(id_string)))
    end,
    "image request warm cache" => fn -> dispatch_router.(warm_path) end,
    "generated-image cache fetch (ETS)" => fn -> OgEx.Cache.ETS.fetch(cache_key) end,
    "signature verify (HMAC)" => fn ->
      OgEx.ConfigBuilder.verify(verify_conn, verify_config)
    end,
    "meta tags build (Meta.to_html)" => fn -> OgEx.Meta.to_html(warm_config) end,
    "head injection (full rewrite)" => fn ->
      :get
      |> conn("/posts/42")
      |> put_resp_content_type("text/html")
      |> OgEx.Head.put_config(warm_config)
      |> send_resp(200, html_document)
    end,
    "raw send_resp (no OgEx)" => fn ->
      :get
      |> conn("/posts/42")
      |> put_resp_content_type("text/html")
      |> send_resp(200, html_document)
    end,
    "font load per cache miss" => fn -> OgEx.Fonts.load() end,
    "direct public static metadata" => fn ->
      OgEx.ConfigBuilder.build(
        page_conn.("/about"),
        [
          title: "About Acme",
          description: "Meet the team",
          image: "/images/og-ex-test.svg",
          image_alt: "The Acme team"
        ],
        %{}
      )
    end,
    "direct private signed metadata" => fn ->
      OgEx.ConfigBuilder.build(
        page_conn.("/reports/1"),
        [title: "Q3 report", image: {:private, "private-test.svg"}],
        %{}
      )
    end,
    "direct remote URL metadata (no fetch)" => fn ->
      OgEx.ConfigBuilder.build(
        page_conn.("/products/1"),
        [
          title: "Product",
          image: "https://cdn.example.com/products/cover.webp",
          image_width: 1200,
          image_height: 630
        ],
        %{}
      )
    end
  },
  warmup: 2,
  time: 6,
  memory_time: 1,
  reduction_time: 1,
  unit_scaling: :best,
  formatters: [Benchee.Formatters.Console]
)
