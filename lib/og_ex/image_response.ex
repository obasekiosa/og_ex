defmodule OgEx.ImageResponse do
  @moduledoc false

  import Plug.Conn

  @doc """
  Verifies and sends a generated card image response.

  Successful responses include the correct media type, an ETag, and immutable
  one-year cache headers. Invalid signatures return 404; render failures return
  503 without cacheable headers.
  """
  def send(conn, config) do
    # Signature verification happens before cache access. This avoids revealing
    # whether a particular private/stale card already exists in the cache.
    with :ok <- OgEx.ConfigBuilder.verify(conn, config),
         {:ok, image} <- cached_or_render(config) do
      conn
      # Binary image media types do not carry a text charset parameter.
      |> put_resp_content_type(content_type(config.format), nil)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("etag", ~s("#{config.version}"))
      |> send_resp(:ok, image)
    else
      {:error, :invalid_image_signature} ->
        send_resp(conn, :not_found, "")

      {:error, reason} ->
        # Failures are deliberately non-cacheable. A missing resource or native
        # renderer problem may recover on the next request.
        :telemetry.execute(
          [:og_ex, :render, :exception],
          %{system_time: System.system_time()},
          %{card: config.card, reason: reason}
        )

        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(:service_unavailable, "")
    end
  end

  # Looks up the fully qualified image key and renders only on a cache miss.
  # Failed renders are deliberately never written to the cache.
  defp cached_or_render(config) do
    # A dependency's config files are not imported into its host application,
    # so retain the built-in adapter as a runtime default.
    cache = Application.get_env(:og_ex, :cache, OgEx.Cache.ETS)

    # Dimensions and format are included even though they normally come from
    # the card module. This prevents collisions if a module changes those
    # values without changing its data version.
    cache_key = {config.card, config.version, config.width, config.height, config.format}

    case cache.fetch(cache_key) do
      {:ok, image} ->
        :telemetry.execute([:og_ex, :cache, :hit], %{}, %{card: config.card})
        {:ok, image}

      :error ->
        :telemetry.execute([:og_ex, :cache, :miss], %{}, %{card: config.card})

        # Cache only complete, successfully encoded image binaries.
        with {:ok, html} <- OgEx.HTML.render(config),
             {:ok, image} <- render(config, html) do
          :ok = cache.put(cache_key, image)
          {:ok, image}
        end
    end
  end

  # Invokes the configured renderer with loaded fonts and emits successful
  # render duration/output-size telemetry.
  defp render(config, html) do
    # Host applications can replace Takumi without being required to repeat
    # the package's default configuration.
    renderer = Application.get_env(:og_ex, :renderer, OgEx.Renderer.Takumi)
    started_at = System.monotonic_time()

    # Fonts are loaded on a cache miss only. A future native font registry can
    # retain parsed fonts across renders without changing this renderer API.
    result =
      renderer.render(
        html,
        width: config.width,
        height: config.height,
        format: config.format,
        fonts: OgEx.Fonts.load()
      )

    duration = System.monotonic_time() - started_at

    case result do
      {:ok, image} ->
        :telemetry.execute(
          [:og_ex, :render, :stop],
          %{duration: duration, size: byte_size(image)},
          %{card: config.card, renderer: renderer}
        )

      _ ->
        :ok
    end

    result
  end

  # Maps the public card format atom to its HTTP response media type.
  defp content_type(:png), do: "image/png"
  defp content_type(:jpeg), do: "image/jpeg"
  defp content_type(:webp), do: "image/webp"
end
