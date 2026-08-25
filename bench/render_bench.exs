# Takumi native renderer throughput and latency by output format and size.
#
#   mix run bench/render_bench.exs
#
# Measures steady-state render latency after warm-up, plus the first cold
# render per format (which includes lazy NIF/font initialization) and encoded
# output sizes.

Code.require_file("bench_helper.exs", __DIR__)

alias OgEx.Renderer.Takumi

import Plug.Conn

fonts = OgEx.Fonts.load()

conn = put_private(Plug.Test.conn(:get, "/posts/42"), :phoenix_endpoint, OgEx.Bench.Endpoint)

{:ok, wide_html} =
  conn
  |> OgEx.ConfigBuilder.build(OgEx.Bench.WideCard, %{
    title: "Benchmarking generated social images"
  })
  |> OgEx.HTML.render()

{:ok, square_html} =
  conn
  |> OgEx.ConfigBuilder.build(OgEx.Bench.SquareCard, %{title: "Square card"})
  |> OgEx.HTML.render()

render = fn html, width, height, format ->
  Takumi.render(html, width: width, height: height, format: format, fonts: fonts)
end

# First render per format records lazy initialization cost; later formats may
# reuse already-parsed fonts depending on the native implementation.
IO.puts("\n## Cold first-render per format (1200x630)\n")

for {format, width, height, html} <- [
      {:png, 1200, 630, wide_html},
      {:jpeg, 1200, 630, wide_html},
      {:webp, 1200, 630, wide_html},
      {:svg, 1200, 630, wide_html}
    ] do
  {duration_us, result} = :timer.tc(fn -> render.(html, width, height, format) end)

  case result do
    {:ok, bytes} ->
      IO.puts("#{format} #{width}x#{height}: #{duration_us / 1000}ms (#{byte_size(bytes)} bytes)")

    {:error, reason} ->
      IO.puts("#{format} FAILED: #{inspect(reason)}")
      System.halt(1)
  end
end

IO.puts("\n## Steady-state render latency\n")

Benchee.run(
  %{
    "png 1200x630" => fn -> render.(wide_html, 1200, 630, :png) end,
    "jpeg 1200x630" => fn -> render.(wide_html, 1200, 630, :jpeg) end,
    "webp 1200x630" => fn -> render.(wide_html, 1200, 630, :webp) end,
    "svg 1200x630" => fn -> render.(wide_html, 1200, 630, :svg) end,
    "png 600x600" => fn -> render.(square_html, 600, 600, :png) end,
    "svg 600x600" => fn -> render.(square_html, 600, 600, :svg) end
  },
  warmup: 2,
  time: 5,
  memory_time: 1,
  reduction_time: 1,
  unit_scaling: :best,
  formatters: [Benchee.Formatters.Console]
)
