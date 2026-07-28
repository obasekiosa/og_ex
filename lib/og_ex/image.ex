defmodule OgEx.Image do
  @moduledoc """
  Normalizes and loads image sources.

  Accepted source forms:

    * `"/images/card.png"` for a file below the host application's
      `priv/static`
    * `"https://cdn.example.com/card.webp"` for a remote image
    * `"data:image/png;base64,..."` inside a generated card
    * `{:private, "reports/card.png"}` in direct controller metadata
    * `private_asset/1` inside generated-card HEEx

  Most applications use source values in controller declarations or HEEx
  rather than calling this module directly. Custom resource loaders can use
  `normalize/2` and `load/2` at the same boundary as the built-in loader.
  """

  alias OgEx.Image.Source

  @private_scheme "ogex-private:"

  @doc """
  Builds an opaque source string for a private image inside card HEEx.

  The path is resolved below the configured `:private_asset_root`; it is never
  exposed to Takumi as a filesystem path.
  """
  def private_asset(path) when is_binary(path) do
    @private_scheme <> URI.encode(path)
  end

  @doc """
  Normalizes a supported image reference.

  Local paths are resolved below their trusted root and rejected when missing,
  unreadable, absolute, traversing, or symlinked. The return value is
  `{:ok, source}` or `{:error, reason}`.
  """
  def normalize({:private, path}, conn) when is_binary(path) do
    private_source(path, conn)
  end

  def normalize(@private_scheme <> encoded_path, conn) do
    encoded_path
    |> URI.decode()
    |> private_source(conn)
  end

  def normalize("/" <> _rest = path, conn) do
    public_source(path, conn)
  end

  def normalize("https://" <> _rest = url, _conn) do
    {:ok, %Source{type: :remote, reference: url}}
  end

  def normalize("http://" <> _rest = url, _conn) do
    {:ok, %Source{type: :remote, reference: url}}
  end

  def normalize("data:" <> _rest = data_url, _conn) do
    {:ok, %Source{type: :data, reference: data_url}}
  end

  def normalize(source, _conn), do: {:error, {:invalid_image_source, source}}

  @doc """
  Loads and verifies a normalized source through the configured loader.

  `options` are passed to the loader. The default loader returns
  `{:ok, %OgEx.Image.Resource{}}` or a structured error. Remote sources require
  `remote_images: [enabled: true, ...]`.

  The function emits `[:og_ex, :resource, :stop]` for success and failure.
  """
  def load(%Source{} = source, options \\ []) do
    loader = Application.get_env(:og_ex, :resource_loader, OgEx.ResourceLoader.Default)
    started_at = System.monotonic_time()
    result = loader.load(source, options)

    measurements =
      case result do
        {:ok, resource} ->
          %{duration: System.monotonic_time() - started_at, size: byte_size(resource.bytes)}

        {:error, _reason} ->
          %{duration: System.monotonic_time() - started_at}
      end

    status = if match?({:ok, _resource}, result), do: :ok, else: :error

    :telemetry.execute(
      [:og_ex, :resource, :stop],
      measurements,
      %{source_type: source.type, status: status, loader: loader}
    )

    result
  end

  @doc """
  Returns the HTTP media type for a verified image format.
  """
  def content_type(:png), do: "image/png"
  def content_type(:jpeg), do: "image/jpeg"
  def content_type(:webp), do: "image/webp"
  def content_type(:gif), do: "image/gif"
  def content_type(:svg), do: "image/svg+xml"

  @doc """
  Returns the OTP application that owns the connection's Phoenix endpoint.

  When it cannot be inferred, this reads `config :og_ex, otp_app: ...` and
  raises `ArgumentError` if no application is configured.
  """
  def otp_app(conn) do
    endpoint = conn.private[:phoenix_endpoint]

    if is_atom(endpoint) do
      Application.get_application(endpoint) ||
        Application.get_env(:og_ex, :otp_app) ||
        raise ArgumentError,
              "could not determine the endpoint OTP app; configure :og_ex, :otp_app"
    else
      Application.get_env(:og_ex, :otp_app) ||
        raise ArgumentError,
              "connection has no Phoenix endpoint; configure :og_ex, :otp_app"
    end
  end

  @doc """
  Converts a root-relative static path into an absolute endpoint URL.

  If the endpoint exports `static_path/1`, its cache-digested path is used.
  """
  def public_url(conn, path) do
    endpoint = conn.private[:phoenix_endpoint]

    static_path =
      if is_atom(endpoint) and function_exported?(endpoint, :static_path, 1) do
        endpoint.static_path(path)
      else
        path
      end

    conn
    |> Phoenix.Controller.current_url()
    |> URI.merge(static_path)
    |> URI.to_string()
  end

  defp public_source(path, conn) do
    app = otp_app(conn)
    static_root = Application.app_dir(app, "priv/static")

    with {:ok, file_path} <- safe_file(static_root, String.trim_leading(path, "/")) do
      {:ok, %Source{type: :public, reference: path, path: file_path}}
    end
  end

  defp private_source(path, conn) do
    app = otp_app(conn)
    root = private_root(app)

    with {:ok, file_path} <- safe_file(root, path) do
      {:ok,
       %Source{
         type: :private,
         reference: private_asset(path),
         path: file_path
       }}
    end
  end

  defp private_root(app) do
    case Application.get_env(:og_ex, :private_asset_root, "priv/og_ex") do
      root when is_binary(root) ->
        if Path.type(root) == :absolute, do: root, else: Application.app_dir(app, root)

      root ->
        raise ArgumentError, ":private_asset_root must be a path, got: #{inspect(root)}"
    end
  end

  # Reject traversal and every symlink below the trusted root. Disallowing
  # symlinks is stricter and more portable than attempting platform-specific
  # canonicalization after an attacker-controlled path has been joined.
  defp safe_file(root, relative) do
    segments = Path.split(relative)

    cond do
      Path.type(relative) != :relative ->
        {:error, {:unsafe_image_path, relative}}

      String.contains?(relative, <<0>>) ->
        {:error, {:unsafe_image_path, relative}}

      segments == [] or Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error, {:unsafe_image_path, relative}}

      true ->
        walk_file(Path.expand(root), segments, relative)
    end
  end

  defp walk_file(root, segments, original) do
    Enum.reduce_while(segments, {:ok, root}, fn segment, {:ok, parent} ->
      candidate = Path.join(parent, segment)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:unsafe_image_path, original}}}

        {:ok, _stat} ->
          {:cont, {:ok, candidate}}

        {:error, :enoent} ->
          {:halt, {:error, {:resource_not_found, original}}}

        {:error, reason} ->
          {:halt, {:error, {:resource_unreadable, original, reason}}}
      end
    end)
    |> case do
      {:ok, path} ->
        if File.regular?(path),
          do: {:ok, path},
          else: {:error, {:resource_not_found, original}}

      error ->
        error
    end
  end
end
