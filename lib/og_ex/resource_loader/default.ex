defmodule OgEx.ResourceLoader.Default do
  @moduledoc """
  Default local, inline, and remote image resource loader.
  """

  @behaviour OgEx.ResourceLoader

  alias OgEx.Image.{Resource, Source}

  @default_max_bytes 5_000_000

  @doc """
  Loads and verifies a normalized image source.

  Local files are read only after `OgEx.Image` has constrained them to a
  trusted root. Data URLs and remote responses share the same byte and native
  image validation.
  """
  @impl true
  def load(%Source{type: type, path: path} = source, options)
      when type in [:public, :private] and is_binary(path) do
    max_bytes = Keyword.get(options, :max_bytes, configured_max_bytes())

    with {:ok, stat} <- File.stat(path),
         :ok <- within_limit(stat.size, max_bytes),
         {:ok, bytes} <- File.read(path) do
      resource(source, bytes)
    else
      {:error, :enoent} -> {:error, {:resource_not_found, source.reference}}
      {:error, {:resource_too_large, _limit}} = error -> error
      {:error, reason} -> {:error, {:resource_unreadable, source.reference, reason}}
    end
  end

  def load(%Source{type: :data, reference: data_url} = source, options) do
    max_bytes = Keyword.get(options, :max_bytes, configured_max_bytes())

    with {:ok, bytes} <- decode_data_url(data_url),
         :ok <- within_limit(byte_size(bytes), max_bytes) do
      resource(source, bytes)
    end
  end

  def load(%Source{type: :remote} = source, options) do
    OgEx.ResourceLoader.Remote.load(source, options)
  end

  @doc """
  Verifies raw bytes and constructs a resource for a normalized source.

  Custom loaders can use this boundary to apply the same native type,
  dimensions, and safe-SVG checks as the default loader.
  """
  def from_bytes(%Source{} = source, bytes) when is_binary(bytes), do: resource(source, bytes)

  defp resource(source, bytes) do
    with {:ok, info} <- OgEx.Native.inspect_image(bytes),
         :ok <- validate_dimensions(info),
         :ok <- validate_svg(info.format, bytes) do
      fingerprint =
        :crypto.hash(:sha256, bytes)
        |> Base.url_encode64(padding: false)

      {:ok,
       %Resource{
         source: source,
         bytes: bytes,
         content_type: OgEx.Image.content_type(info.format),
         format: info.format,
         width: info.width,
         height: info.height,
         fingerprint: fingerprint
       }}
    else
      {:error, reason} -> {:error, {:invalid_image, reason}}
    end
  end

  # Enforces decoded dimension and pixel limits against decompression bombs.
  defp validate_dimensions(info) do
    config = Application.get_env(:og_ex, :remote_images, [])
    max_dimension = Keyword.get(config, :max_dimension, 8_192)
    max_pixels = Keyword.get(config, :max_pixels, 40_000_000)

    if info.width <= max_dimension and info.height <= max_dimension and
         info.width * info.height <= max_pixels do
      :ok
    else
      {:error, {:image_dimensions_too_large, info.width, info.height}}
    end
  end

  # Rejects active SVG constructs and external resource references before bytes
  # cross into Takumi. This intentionally accepts only self-contained SVG.
  defp validate_svg(:svg, bytes) do
    unsafe? =
      Regex.match?(
        ~r/<\s*(script|foreignObject)\b|(?:^|\s)on[a-z]+\s*=|(?:href|src)\s*=\s*["'](?!data:|#)|url\(\s*["']?(?!data:|#)/i,
        bytes
      )

    if unsafe?, do: {:error, :unsafe_svg}, else: :ok
  end

  defp validate_svg(_format, _bytes), do: :ok

  defp decode_data_url(data_url) do
    with ["data:" <> metadata, encoded] <- String.split(data_url, ",", parts: 2),
         true <- String.ends_with?(metadata, ";base64"),
         {:ok, bytes} <- Base.decode64(encoded) do
      {:ok, bytes}
    else
      _ -> {:error, {:invalid_data_url, data_url}}
    end
  end

  defp within_limit(size, limit) when size <= limit, do: :ok
  defp within_limit(_size, limit), do: {:error, {:resource_too_large, limit}}

  defp configured_max_bytes do
    :og_ex
    |> Application.get_env(:remote_images, [])
    |> Keyword.get(:max_bytes, @default_max_bytes)
  end
end
