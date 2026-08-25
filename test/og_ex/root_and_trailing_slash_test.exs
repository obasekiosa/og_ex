defmodule OgEx.RootAndTrailingSlashTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test
  import ExUnit.CaptureLog

  # Identical to the secret used by the request lifecycle suite because both
  # suites sign through OgEx.TestEndpoint.
  @secret_key_base String.duplicate("og-ex-test-secret-", 4)

  # Mirrors OgEx.ConfigBuilder's private legacy-warning gate so the warning
  # can be re-armed deterministically inside tests.
  @legacy_warning_persistent_key {OgEx.ConfigBuilder, :legacy_trailing_slash_warning}
  @legacy_warning_ets_key :legacy_signature_warning

  setup_all do
    Application.put_env(:og_ex, OgEx.TestEndpoint,
      secret_key_base: @secret_key_base,
      url: [scheme: "https", host: "example.test", port: 443],
      server: false
    )

    if Process.whereis(OgEx.TestEndpoint) == nil do
      start_supervised!(OgEx.TestEndpoint)
    end

    :ok
  end

  defp page_conn(path) do
    :get
    |> conn(path)
    |> put_private(:phoenix_endpoint, OgEx.TestEndpoint)
    |> fetch_query_params()
  end

  defp build_config(path, card, assigns) do
    OgEx.ConfigBuilder.build(page_conn(path), card, assigns, image_route: :path)
  end

  defp sign_image_path(path, card, assigns) do
    path
    |> build_config(card, assigns)
    |> Map.fetch!(:image_url)
    |> URI.parse()
    |> Map.fetch!(:path)
  end

  defp dispatch_router(path) do
    :get
    |> conn(path)
    |> put_private(:phoenix_endpoint, OgEx.TestEndpoint)
    |> OgEx.TestRouter.call(OgEx.TestRouter.init([]))
  end

  defp dispatch_endpoint(path) do
    :get
    |> conn(path)
    |> put_private(:phoenix_endpoint, OgEx.TestEndpoint)
    |> OgEx.call(router: OgEx.TestRouter)
  end

  defp attach_legacy_telemetry(test_name) do
    handler_id = {__MODULE__, test_name}

    :telemetry.attach(
      handler_id,
      [:og_ex, :signature, :legacy],
      fn _event, _measurements, metadata, _config ->
        send(self(), {:legacy_signature_event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp re_arm_legacy_warning do
    :persistent_term.erase(@legacy_warning_persistent_key)

    if :ets.whereis(OgEx.Flags) != :undefined do
      :ets.delete(OgEx.Flags, @legacy_warning_ets_key)
    end
  end

  # Replicates ConfigBuilder's wire format to mint signatures bound to paths
  # the current generator can no longer produce (pre-canonicalization tokens).
  # The sanity assertion below fails loudly if the internal format ever
  # changes, which is exactly when this compatibility shim must be revisited.
  defp legacy_signature(page_path, role, identity) do
    key = :crypto.mac(:hmac, :sha256, @secret_key_base, "og-ex-image-v1")
    message = :erlang.term_to_binary({identity, role, page_path}, [:deterministic])

    :crypto.mac(:hmac, :sha256, key, message)
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  defp generated_identity(config) do
    {:generated, config.card, config.version}
  end

  test "root pages emit working opengraph image URLs through the router" do
    response =
      :get
      |> conn("/")
      |> put_private(:phoenix_endpoint, OgEx.TestEndpoint)
      |> OgEx.TestRouter.call(OgEx.TestRouter.init([]))

    assert response.status == 200
    assert response.resp_body =~ ~s(property="og:image")

    image_path = sign_image_path("/", OgEx.TestHomeCard, %{title: "Loaded"})
    assert image_path =~ ~r{\A/opengraph-image/[^/]+\z}

    image_response = dispatch_router(image_path)

    assert image_response.status == 200
    assert get_resp_header(image_response, "content-type") == ["image/png"]

    assert get_resp_header(image_response, "cache-control") ==
             ["public, max-age=31536000, immutable"]

    assert get_resp_header(image_response, "etag") != []
    assert <<137, "PNG\r\n", 26, "\n", _rest::binary>> = image_response.resp_body
  end

  test "root image requests hit the warm cache on repeat requests" do
    image_path = sign_image_path("/", OgEx.TestHomeCard, %{title: "Loaded"})

    first = dispatch_router(image_path)
    second = dispatch_router(image_path)

    assert first.status == 200
    assert second.status == 200
    assert first.resp_body == second.resp_body
    assert get_resp_header(first, "etag") == get_resp_header(second, "etag")
  end

  test "endpoint integration dispatches root images before routing" do
    image_path = sign_image_path("/", OgEx.TestHomeCard, %{title: "Loaded"})

    response = dispatch_endpoint(image_path)

    assert response.halted
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png"]
  end

  test "twitter image role is recognized on the root page" do
    config = build_config("/", OgEx.TestHomeCard, %{title: "Loaded"})

    twitter_path =
      config.twitter_image_url
      |> URI.parse()
      |> Map.fetch!(:path)

    assert twitter_path =~ ~r{\A/twitter-image/[^/]+\z}

    response = dispatch_router(twitter_path)

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png"]
  end

  test "trailing-slash pages sign trimmed paths that verify successfully" do
    image_path = sign_image_path("/posts/42/", OgEx.TestCard, %{title: "Loaded 42"})

    refute String.ends_with?(image_path, "/")
    assert image_path =~ ~r{\A/posts/42/opengraph-image/[^/]+\z}

    response = dispatch_router(image_path)

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png"]
  end

  test "fresh tokens verify on the canonical candidate without legacy telemetry or warnings" do
    attach_legacy_telemetry(:canonical_only)
    re_arm_legacy_warning()

    image_path = sign_image_path("/posts/42", OgEx.TestCard, %{title: "Loaded 42"})

    log =
      capture_log(fn ->
        response = dispatch_router(image_path)
        assert response.status == 200
      end)

    refute_received {:legacy_signature_event, _metadata}
    refute log =~ "deprecated image signature"
  end

  test "pre-canonicalization trailing-slash tokens verify through the compatibility path" do
    attach_legacy_telemetry(:legacy_fallback)
    re_arm_legacy_warning()

    config = build_config("/posts/42/", OgEx.TestCard, %{title: "Loaded 42"})
    identity = generated_identity(config)
    legacy_token = legacy_signature("/posts/42/", :image, identity)

    # The replication must agree with the generator on the canonical form.
    canonical_token = legacy_signature("/posts/42", :image, identity)

    assert canonical_token ==
             sign_image_path("/posts/42", OgEx.TestCard, %{title: "Loaded 42"})
             |> String.split("/")
             |> List.last()

    image_path = "/posts/42/opengraph-image/#{legacy_token}"

    log =
      capture_log(fn ->
        response = dispatch_router(image_path)
        assert response.status == 200
        assert get_resp_header(response, "content-type") == ["image/png"]
      end)

    assert_received {:legacy_signature_event, metadata}
    assert metadata.page_path == "/posts/42/"
    assert metadata.canonical == "/posts/42"

    assert log =~ "deprecated image signature"
    assert log =~ ~s("/posts/42/")

    # The gate suppresses the second warning but telemetry still fires.
    log =
      capture_log(fn ->
        response = dispatch_router(image_path)
        assert response.status == 200
      end)

    assert_received {:legacy_signature_event, _metadata}
    refute log =~ "deprecated image signature"
  end

  test "image URLs with trailing slashes still dispatch" do
    image_path = sign_image_path("/posts/7", OgEx.TestCard, %{title: "Loaded 7"})

    response = dispatch_router(image_path <> "/")

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png"]
  end

  test "tokens replayed against another page are rejected" do
    token =
      sign_image_path("/posts/42", OgEx.TestCard, %{title: "Loaded 42"})
      |> String.split("/")
      |> List.last()

    response = dispatch_router("/posts/43/opengraph-image/#{token}")

    assert response.status == 404
    assert response.resp_body == ""
  end

  test "unmatched junk paths keep their existing behavior" do
    routed = dispatch_router("/a/b/c")
    assert routed.status == 404

    passed_through = dispatch_endpoint("/a/b/c")
    refute passed_through.halted
    assert passed_through.status == nil
  end
end
