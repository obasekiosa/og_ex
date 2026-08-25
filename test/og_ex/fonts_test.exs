defmodule OgEx.FontsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test
  import ExUnit.CaptureLog

  @app_relative_marker {:ogex_font, "priv/static/images/og-ex-test.svg"}

  setup_all do
    Application.put_env(:og_ex, OgEx.TestEndpoint,
      secret_key_base: String.duplicate("og-ex-font-test-secret-", 4),
      url: [scheme: "https", host: "example.test", port: 443],
      server: false
    )

    if Process.whereis(OgEx.TestEndpoint) == nil do
      start_supervised!(OgEx.TestEndpoint)
    end

    # Captured once before any test replaces the :fonts environment.
    font_path =
      :og_ex
      |> Application.get_env(:fonts, [])
      |> List.wrap()
      |> Enum.find(&is_binary/1)

    {:ok, font_path: font_path}
  end

  setup do
    original_fonts = Application.get_env(:og_ex, :fonts)
    original_otp_app = Application.get_env(:og_ex, :otp_app)

    on_exit(fn ->
      if original_fonts == nil do
        Application.delete_env(:og_ex, :fonts)
      else
        Application.put_env(:og_ex, :fonts, original_fonts)
      end

      if original_otp_app == nil do
        Application.delete_env(:og_ex, :otp_app)
      else
        Application.put_env(:og_ex, :otp_app, original_otp_app)
      end
    end)

    :ok
  end

  describe "font/1" do
    test "returns a lazy marker without touching the filesystem" do
      assert {:ogex_font, "priv/fonts/Inter.ttf"} = OgEx.font("priv/fonts/Inter.ttf")
    end
  end

  describe "load/0" do
    test "reads an existing path entry", %{font_path: font_path} do
      Application.put_env(:og_ex, :fonts, [font_path])
      assert {:ok, [bytes]} = OgEx.Fonts.load()
      assert is_binary(bytes) and bytes != ""
    end

    test "passes non-file binaries through as font bytes" do
      Application.put_env(:og_ex, :fonts, ["not-a-file"])
      assert {:ok, ["not-a-file"]} = OgEx.Fonts.load()
    end

    test "resolves an absolute OgEx.font marker", %{font_path: font_path} do
      Application.put_env(:og_ex, :otp_app, nil)
      Application.put_env(:og_ex, :fonts, [OgEx.font(font_path)])
      {:ok, [bytes]} = OgEx.Fonts.load()
      assert bytes == File.read!(font_path)
    end

    test "resolves a relative marker against the configured otp_app" do
      Application.put_env(:og_ex, :otp_app, :og_ex)
      Application.put_env(:og_ex, :fonts, [@app_relative_marker])

      {:ok, [bytes]} = OgEx.Fonts.load()
      assert bytes =~ "<svg"
    end

    test "markers require config :og_ex, :otp_app" do
      Application.delete_env(:og_ex, :otp_app)
      Application.put_env(:og_ex, :fonts, [OgEx.font("priv/fonts/Inter.ttf")])

      assert {:error, {:invalid_font_config, message}} = OgEx.Fonts.load()
      assert message =~ ":otp_app"
    end

    test "markers report missing files with actionable guidance" do
      Application.put_env(:og_ex, :otp_app, :og_ex)
      Application.put_env(:og_ex, :fonts, [OgEx.font("priv/fonts/does-not-exist.ttf")])

      assert {:error, {:invalid_font_config, message}} = OgEx.Fonts.load()
      assert message =~ "does not exist"
      assert message =~ "Application.app_dir/2"
    end

    test "resolves a zero-arity fun returning an existing path", %{font_path: font_path} do
      Application.put_env(:og_ex, :fonts, [fn -> font_path end])
      {:ok, [bytes]} = OgEx.Fonts.load()
      assert bytes == File.read!(font_path)
    end

    test "resolves a zero-arity fun returning font bytes" do
      Application.put_env(:og_ex, :fonts, [fn -> "inline-bytes" end])
      assert {:ok, ["inline-bytes"]} = OgEx.Fonts.load()
    end

    test "resolves {mod, fun, args} entries", %{font_path: font_path} do
      Application.put_env(:og_ex, :fonts, [{__MODULE__, :sample_path, [font_path]}])
      {:ok, [bytes]} = OgEx.Fonts.load()
      assert bytes == File.read!(font_path)
    end

    test "capturing fun failures produces a structured error" do
      Application.put_env(:og_ex, :fonts, [fn -> raise "font storage down" end])

      assert {:error, {:invalid_font_config, message}} = OgEx.Fonts.load()
      assert message =~ "font storage down"
    end

    test "non-binary lazy results produce a structured error" do
      Application.put_env(:og_ex, :fonts, [fn -> {:oops, :tuple} end])

      assert {:error, {:invalid_font_config, message}} = OgEx.Fonts.load()
      assert message =~ "must resolve to a path or font bytes"
    end

    test "unknown entry shapes produce a structured error" do
      Application.put_env(:og_ex, :fonts, [42])

      assert {:error, {:invalid_font_config, message}} = OgEx.Fonts.load()
      assert message =~ "OgEx.font/1 marker"
    end
  end

  describe "validate_config/0" do
    test "warns listing invalid entries" do
      Application.put_env(:og_ex, :fonts, [42, :nope])

      log =
        capture_log(fn ->
          assert :ok = OgEx.Fonts.validate_config()
        end)

      assert log =~ "invalid entries"
      assert log =~ "42"
    end

    test "accepts every documented entry shape silently", %{font_path: font_path} do
      Application.put_env(:og_ex, :fonts, [
        font_path,
        "inline-bytes",
        OgEx.font("priv/fonts/Inter.ttf"),
        {__MODULE__, :sample_path, [font_path]},
        fn -> font_path end
      ])

      log =
        capture_log(fn ->
          assert :ok = OgEx.Fonts.validate_config()
        end)

      refute log =~ "invalid entries"
    end
  end

  describe "render integration" do
    test "an invalid font configuration returns a non-cacheable 503" do
      failure_reason = "broken font config #{System.unique_integer([:positive])}"
      Application.put_env(:og_ex, :fonts, [fn -> raise failure_reason end])
      re_arm_font_error_gate(failure_reason)

      page_conn =
        :get
        |> conn("/posts/42")
        |> put_private(:phoenix_endpoint, OgEx.TestEndpoint)
        |> fetch_query_params()

      # A unique title yields a unique card version, guaranteeing a cache
      # miss so the render path (and its font resolution) actually runs.
      assigns = %{title: "Font failure #{System.unique_integer([:positive])}"}
      page_config = OgEx.ConfigBuilder.build(page_conn, OgEx.TestCard, assigns)

      signature =
        page_config.image_url
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("__og_ex")

      image_conn =
        :get
        |> conn("/posts/42?__og_ex=#{URI.encode_www_form(signature)}")
        |> put_private(:phoenix_endpoint, OgEx.TestEndpoint)
        |> fetch_query_params()

      image_config = OgEx.ConfigBuilder.build(image_conn, OgEx.TestCard, assigns)

      log =
        capture_log(fn ->
          response = OgEx.ImageResponse.send(image_conn, image_config)

          assert response.status == 503
          assert get_resp_header(response, "cache-control") == ["no-store"]
        end)

      assert log =~ failure_reason
    end
  end

  test "log_error_once logs the first occurrence per node and message" do
    message = "fonts test gate #{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        OgEx.Fonts.log_error_once(message)
      end)

    assert log =~ message

    second =
      capture_log(fn ->
        OgEx.Fonts.log_error_once(message)
      end)

    refute second =~ message
  end

  def sample_path(path), do: path

  defp re_arm_font_error_gate(reason) do
    message = "OgEx font configuration error: " <> reason
    gate_key = {OgEx.Fonts, :config_error, message}
    fast_key = {OgEx.Fonts, :config_error_logged, message}

    :persistent_term.erase(fast_key)

    if :ets.whereis(OgEx.Flags) != :undefined do
      :ets.delete(OgEx.Flags, gate_key)
    end
  end
end
