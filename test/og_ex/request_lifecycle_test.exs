defmodule OgEx.RequestLifecycleTest do
  use ExUnit.Case, async: false

  test "controller integration replaces Phoenix's imported render/3" do
    Code.ensure_loaded!(OgEx.TestController)
    assert function_exported?(OgEx.TestController, :render, 3)
  end

  import Plug.Conn
  import Plug.Test

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

  defp page_conn do
    :get
    |> conn("/posts/42?locale=en")
    |> endpoint_conn()
  end

  defp endpoint_conn(conn) do
    put_private(conn, :phoenix_endpoint, OgEx.TestEndpoint)
  end
end
