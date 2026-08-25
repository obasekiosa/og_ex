# End-to-end OgEx request lifecycle latency.
#
#   mix run bench/lifecycle_bench.exs
#
# Measures the hot paths of a realistic controller integration:
#
#   * config build and HMAC signing during HTML page renders
#   * head metadata injection into completed HTML responses
#   * card-local load dispatch
#   * full path-mode image dispatch through the Phoenix router
#   * warm generated-image cache hits versus cold cache-miss renders
#   * endpoint plug pass-through for ordinary requests

Code.require_file("bench_helper.exs", __DIR__)

import Plug.Conn
import Plug.Test

router = OgEx.Bench.Router.init([])

# The signed image URL is normally produced while rendering the HTML page.
# Signing assigns must match what the card loader regenerates on the image
# request or signature verification would reject the URL.
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

warm_config =
  :get
  |> conn("/posts/42")
  |> put_private(:phoenix_endpoint, OgEx.Bench.Endpoint)
  |> fetch_query_params()
  |> OgEx.ConfigBuilder.build(OgEx.Bench.WideCard, warm_assigns)

page_html =
  String.duplicate(
    "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.</p>",
    120
  )

html_document = "<html><head><title>Post</title></head><body>#{page_html}</body></html>"

dispatch_router = fn path ->
  :get
  |> conn(path)
  |> put_private(:phoenix_endpoint, OgEx.Bench.Endpoint)
  |> OgEx.Bench.Router.call(router)
end

IO.puts("\n## Lifecycle sanity checks\n")

image_response = dispatch_router.(warm_path)

IO.puts(
  "warm image response: #{image_response.status} #{inspect(get_resp_header(image_response, "content-type"))}"
)

unless image_response.status == 200 and
         get_resp_header(image_response, "content-type") == ["image/png"] do
  IO.puts("ERROR: warm image request did not return a PNG; aborting")
  System.halt(1)
end

cold_id = System.unique_integer([:positive])

cold_response =
  dispatch_router.(
    sign_image_path.(Integer.to_string(cold_id), cold_assigns.(Integer.to_string(cold_id)))
  )

IO.puts(
  "cold image response: #{cold_response.status} #{inspect(get_resp_header(cold_response, "content-type"))}"
)

unless cold_response.status == 200 and byte_size(cold_response.resp_body) > 1000 do
  IO.puts("ERROR: cold image request did not render an image; aborting")
  System.halt(1)
end

page_response = dispatch_router.("/posts/42")

IO.puts(
  "page html response: #{page_response.status}, meta injected: #{page_response.resp_body =~ ~s(og:image)}"
)

Benchee.run(
  %{
    "config build + signing" => fn ->
      :get
      |> conn("/posts/42")
      |> put_private(:phoenix_endpoint, OgEx.Bench.Endpoint)
      |> fetch_query_params()
      |> OgEx.ConfigBuilder.build(OgEx.Bench.WideCard, warm_assigns)
    end,
    "card load dispatch" => fn ->
      conn =
        :get
        |> conn("/posts/42")
        |> put_private(:phoenix_endpoint, OgEx.Bench.Endpoint)

      OgEx.Bench.PathController.__og_ex_load__(:show, conn, %{"id" => "42"})
    end,
    "head injection" => fn ->
      :get
      |> conn("/posts/42")
      |> put_resp_content_type("text/html")
      |> OgEx.Head.put_config(warm_config)
      |> send_resp(200, html_document)
    end,
    "endpoint pass-through (no card)" => fn ->
      :get
      |> conn("/assets/app.css")
      |> put_private(:phoenix_endpoint, OgEx.Bench.Endpoint)
      |> OgEx.call(router: OgEx.Bench.Router)
    end,
    "html page request" => fn -> dispatch_router.("/posts/42") end,
    "image request warm cache" => fn -> dispatch_router.(warm_path) end,
    "image request cold cache" => fn ->
      id = System.unique_integer([:positive])

      dispatch_router.(
        sign_image_path.(Integer.to_string(id), cold_assigns.(Integer.to_string(id)))
      )
    end
  },
  warmup: 2,
  time: 5,
  memory_time: 1,
  reduction_time: 1,
  unit_scaling: :best,
  formatters: [Benchee.Formatters.Console]
)
