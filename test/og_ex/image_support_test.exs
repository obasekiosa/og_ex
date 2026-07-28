defmodule OgEx.ImageSupportTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @secret_key_base String.duplicate("og-ex-test-secret-", 4)

  setup_all do
    Application.put_env(:og_ex, OgEx.TestEndpoint,
      secret_key_base: @secret_key_base,
      url: [scheme: "https", host: "example.test", port: 443],
      server: false
    )

    start_supervised!(OgEx.TestEndpoint)
    :ok
  end

  test "a public direct image uses its static URL and verified dimensions" do
    config =
      OgEx.ConfigBuilder.build(
        page_conn(),
        %{title: "Public", image: "/images/og-ex-test.svg"},
        %{}
      )

    assert config.strategy == :existing
    assert config.width == 64
    assert config.height == 32
    assert config.format == :svg
    assert config.image_url == "https://example.test/images/og-ex-test.svg"
    assert config.twitter_image_url == config.image_url
  end

  test "an external direct image is emitted without being fetched" do
    url = "https://cdn.example.com/card.webp"

    config =
      OgEx.ConfigBuilder.build(
        page_conn(),
        %{title: "Remote", image: url, image_width: 1200, image_height: 630},
        %{}
      )

    assert config.image_url == url
    assert config.width == 1200
    assert config.height == 630
  end

  test "a private direct image is returned through its signed same-route URL" do
    page_config =
      OgEx.ConfigBuilder.build(
        page_conn(),
        %{title: "Private", image: {:private, "private-test.svg"}},
        %{}
      )

    signature = signature(page_config.image_url)

    image_conn =
      :get
      |> conn("/posts/42?__og_ex=#{URI.encode_www_form(signature)}")
      |> endpoint_conn()

    image_config =
      OgEx.ConfigBuilder.build(
        image_conn,
        %{title: "Private", image: {:private, "private-test.svg"}},
        %{}
      )

    response = OgEx.ImageResponse.send(image_conn, image_config)

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/svg+xml"]
    assert get_resp_header(response, "etag") == [~s("#{image_config.image.fingerprint}")]
    assert response.resp_body =~ "<svg"
  end

  test "separate private Twitter images receive role-bound signatures" do
    config =
      OgEx.ConfigBuilder.build(
        page_conn(),
        %{
          title: "Separate",
          image: "/images/og-ex-test.svg",
          twitter_image: {:private, "private-test.svg"}
        },
        %{}
      )

    refute config.twitter_image_url == config.image_url
    assert URI.parse(config.twitter_image_url).path == "/posts/42"
    assert signature(config.twitter_image_url)
  end

  test "generated cards load img sources and render a real PNG" do
    page_config = OgEx.ConfigBuilder.build(page_conn(), OgEx.TestImageCard, %{})
    image_conn = signed_conn(page_config.image_url)
    image_config = OgEx.ConfigBuilder.build(image_conn, OgEx.TestImageCard, %{})

    response = OgEx.ImageResponse.send(image_conn, image_config)

    assert response.status == 200
    assert <<137, "PNG\r\n", 26, "\n", _rest::binary>> = response.resp_body
  end

  test "unsafe local paths are rejected" do
    assert {:error, {:unsafe_image_path, "../secret.svg"}} =
             OgEx.Image.normalize({:private, "../secret.svg"}, page_conn())

    assert {:error, {:unsafe_image_path, "/etc/passwd"}} =
             OgEx.Image.normalize({:private, "/etc/passwd"}, page_conn())
  end

  test "remote loading is disabled by default and deny-listed by hostname" do
    original = Application.get_env(:og_ex, :remote_images)

    on_exit(fn ->
      if original,
        do: Application.put_env(:og_ex, :remote_images, original),
        else: Application.delete_env(:og_ex, :remote_images)
    end)

    source = %OgEx.Image.Source{type: :remote, reference: "https://example.com/image.png"}

    Application.delete_env(:og_ex, :remote_images)
    assert {:error, :remote_images_disabled} = OgEx.Image.load(source)

    Application.put_env(:og_ex, :remote_images, enabled: true, allowed_hosts: [])

    assert {:error, {:resource_host_not_allowed, "example.com"}} =
             OgEx.Image.load(source)
  end

  defp page_conn do
    :get
    |> conn("/posts/42")
    |> endpoint_conn()
  end

  # Reconstructs the crawler request from a signed metadata URL.
  defp signed_conn(url) do
    uri = URI.parse(url)

    :get
    |> conn(uri.path <> "?" <> uri.query)
    |> endpoint_conn()
  end

  # Extracts the compact OgEx signature from an image URL.
  defp signature(url) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("__og_ex")
  end

  # Adds the endpoint information normally installed by Phoenix.
  defp endpoint_conn(conn), do: put_private(conn, :phoenix_endpoint, OgEx.TestEndpoint)
end
