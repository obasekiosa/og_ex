defmodule OgEx.RequestLifecycleTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  test "controller integration replaces Phoenix's imported render/3" do
    Code.ensure_loaded!(OgEx.TestController)
    assert function_exported?(OgEx.TestController, :render, 3)
  end

  test "controller declarations default to card-local loading" do
    assert %{
             action: :show,
             card: OgEx.TestCard,
             image_route: :query
           } = OgEx.TestController.__og_ex_declaration__(:show)

    conn =
      :get
      |> conn("/posts/42")
      |> endpoint_conn()
      |> OgEx.Request.put_origin(
        OgEx.TestController,
        :show,
        :image,
        %{"id" => "42"}
      )

    assert {:ok, %{title: "Loaded 42"}} =
             OgEx.TestController.__og_ex_load__(:show, conn, %{"id" => "42"})

    assert OgEx.controller(conn) == OgEx.TestController
    assert OgEx.action(conn) == :show
    assert OgEx.route_params(conn) == %{"id" => "42"}
    assert OgEx.image_role(conn) == :open_graph
  end

  test "an explicit declaration loader overrides card-local loading" do
    conn =
      :get
      |> conn("/preview/42")
      |> endpoint_conn()

    assert {:ok, %{title: "Preview 42"}} =
             OgEx.TestController.__og_ex_load__(:preview, conn, %{"id" => "42"})
  end

  @secret_key_base String.duplicate("og-ex-test-secret-", 4)

  setup_all do
    # Signature generation and current_url/2 read endpoint configuration
    # through the endpoint stored on the connection.
    Application.put_env(:og_ex, OgEx.TestEndpoint,
      secret_key_base: @secret_key_base,
      url: [scheme: "https", host: "example.test", port: 443],
      server: false
    )

    # Phoenix endpoints keep runtime configuration in an ETS table owned by the
    # endpoint process. Starting this test endpoint mirrors the environment in
    # in which a real controller signs image URLs.
    start_supervised!(OgEx.TestEndpoint)

    :ok
  end

  test "a normal page config produces a signed same-route image URL" do
    config =
      page_conn()
      |> OgEx.ConfigBuilder.build(OgEx.TestCard, %{title: "Hello"})

    uri = URI.parse(config.image_url)
    params = URI.decode_query(uri.query)

    assert uri.path == "/posts/42"
    assert params["locale"] == "en"
    assert byte_size(params["__og_ex"]) == 22
    assert config.metadata.title == "Hello"
  end

  test "generated HTML derives its viewport and root size from the card" do
    config =
      page_conn()
      |> OgEx.ConfigBuilder.build(OgEx.TestCard, %{title: "Hello"})

    assert {:ok, html} = OgEx.HTML.render(config)
    assert html =~ "width: 1200px"
    assert html =~ "height: 630px"
    assert html =~ "[data-og-ex-root]"
    assert html =~ "width: 100%"
    assert html =~ "height: 100%"
  end

  test "the signed image request returns a cached immutable PNG" do
    page_config =
      page_conn()
      |> OgEx.ConfigBuilder.build(OgEx.TestCard, %{title: "Hello"})

    signature =
      page_config.image_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("__og_ex")

    image_conn =
      :get
      |> conn("/posts/42?locale=en&__og_ex=#{URI.encode_www_form(signature)}")
      |> endpoint_conn()

    image_config =
      OgEx.ConfigBuilder.build(image_conn, OgEx.TestCard, %{title: "Hello"})

    response = OgEx.ImageResponse.send(image_conn, image_config)

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png"]

    assert get_resp_header(response, "cache-control") ==
             ["public, max-age=31536000, immutable"]

    assert <<137, "PNG\r\n", 26, "\n", _rest::binary>> = response.resp_body
  end

  test "an SVG card returns a vector image response" do
    page_config =
      page_conn()
      |> OgEx.ConfigBuilder.build(OgEx.TestSvgCard, %{title: "Vector"})

    signature =
      page_config.image_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("__og_ex")

    image_conn =
      :get
      |> conn("/posts/42?locale=en&__og_ex=#{URI.encode_www_form(signature)}")
      |> endpoint_conn()

    image_config =
      OgEx.ConfigBuilder.build(image_conn, OgEx.TestSvgCard, %{title: "Vector"})

    response = OgEx.ImageResponse.send(image_conn, image_config)

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/svg+xml"]
    assert response.resp_body =~ ~s(<svg xmlns="http://www.w3.org/2000/svg")
    assert response.resp_body =~ ~s(width="600")
    assert response.resp_body =~ ~s(height="600")
  end

  test "metadata is escaped and inserted into an iodata HTML response" do
    config =
      page_conn()
      |> OgEx.ConfigBuilder.build(OgEx.TestCard, %{title: ~s(<Unsafe "title">)})

    response =
      page_conn()
      |> OgEx.Head.put_config(config)
      |> put_resp_content_type("text/html")
      |> send_resp(200, ["<html>", "<head></head>", ["<body>", "Page", "</body>"], "</html>"])

    assert response.resp_body =~
             ~s(<meta property="og:title" content="&lt;Unsafe &quot;title&quot;&gt;">)

    assert response.resp_body =~ ~s(property="og:image")
    assert response.resp_body =~ "</head><body>Page</body>"
  end

  test "request signatures are fetched lazily without an endpoint plug" do
    conn = conn(:get, "/posts/42?__og_ex=compact")

    assert %Plug.Conn.Unfetched{} = conn.query_params
    assert OgEx.Request.signature(conn) == "compact"
    assert OgEx.Request.image_request?(conn)
  end

  test "an invalid image signature is rejected before rendering" do
    conn =
      :get
      |> conn("/posts/42?__og_ex=invalid")
      |> endpoint_conn()

    config = OgEx.ConfigBuilder.build(conn, OgEx.TestCard, %{title: "Hello"})
    response = OgEx.ImageResponse.send(conn, config)

    assert response.status == 404
    assert response.resp_body == ""
  end

  test "query image requests invoke the card loader before the controller action" do
    page_config =
      page_conn()
      |> OgEx.ConfigBuilder.build(OgEx.TestCard, %{title: "Loaded 42"})

    signature =
      page_config.image_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("__og_ex")

    conn =
      :get
      |> conn("/posts/42?__og_ex=#{URI.encode_www_form(signature)}")
      |> endpoint_conn()
      |> put_private(:phoenix_controller, OgEx.TestController)
      |> put_private(:phoenix_action, :show)
      |> Map.put(:path_params, %{"id" => "42"})

    response = OgEx.Controller.before_action(conn, OgEx.TestController)

    assert response.halted
    assert response.status == 200
    assert <<137, "PNG\r\n", 26, "\n", _rest::binary>> = response.resp_body
  end

  defp page_conn do
    :get
    |> conn("/posts/42?locale=en")
    |> endpoint_conn()
  end

  defp endpoint_conn(conn) do
    put_private(conn, :phoenix_endpoint, OgEx.TestEndpoint)
  end
end
