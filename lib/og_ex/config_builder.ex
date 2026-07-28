defmodule OgEx.ConfigBuilder do
  @moduledoc false

  @signature_salt "og-ex-image-v1"
  @signature_bytes 16
  @reserved_parameter "__og_ex"

  @doc """
  Builds configuration for a generated card module or direct image metadata.

  Generated cards keep the original `og: CardModule` contract. A keyword list
  or map selects the direct-image strategy and must contain `:title` and
  `:image`.
  """
  def build(conn, card, assigns) when is_atom(card) and is_map(assigns) do
    metadata = card.metadata(assigns)
    version = generated_version(card, assigns)
    identity = {:generated, card, version}

    %OgEx.Config{
      strategy: {:generated, card},
      card: card,
      assigns: assigns,
      metadata: metadata,
      width: card.__og_ex__(:width),
      height: card.__og_ex__(:height),
      format: card.__og_ex__(:format),
      version: version,
      image_url: image_url(conn, signature(conn, identity, :image))
    }
  end

  def build(conn, metadata, assigns)
      when (is_list(metadata) or is_map(metadata)) and is_map(assigns) do
    metadata = Map.new(metadata)
    title = Map.fetch!(metadata, :title)
    image_reference = Map.fetch!(metadata, :image)
    image = direct_image!(conn, image_reference)
    twitter_image = direct_image!(conn, Map.get(metadata, :twitter_image, image_reference))
    version = direct_version(image, twitter_image)

    %OgEx.Config{
      strategy: :existing,
      assigns: assigns,
      metadata: Map.put(metadata, :title, title),
      version: version,
      image: image,
      twitter_image: twitter_image,
      width: metadata[:image_width] || dimension(image, :width),
      height: metadata[:image_height] || dimension(image, :height),
      format: format(image),
      image_url: direct_url(conn, image, version, :image),
      twitter_image_url: direct_url(conn, twitter_image, version, :twitter_image)
    }
  end

  @doc """
  Verifies an image request and returns the image role bound to its signature.
  """
  def verify(conn, %OgEx.Config{} = config) do
    supplied = OgEx.Request.signature(conn)

    [:image, :twitter_image]
    |> Enum.uniq_by(&resource_for(config, &1))
    |> Enum.find_value({:error, :invalid_image_signature}, fn role ->
      expected = signature(conn, identity(config, role), role)

      if is_binary(supplied) and byte_size(supplied) == byte_size(expected) and
           Plug.Crypto.secure_compare(supplied, expected) do
        {:ok, role}
      end
    end)
  end

  # Loads local direct images immediately so metadata dimensions, signatures,
  # and private response headers are based on verified bytes. Remote direct
  # images remain untouched and are emitted as their original URL.
  defp direct_image!(conn, reference) do
    with {:ok, source} <- OgEx.Image.normalize(reference, conn) do
      case source.type do
        :remote -> source
        :data -> raise ArgumentError, "data URLs cannot be used as direct social images"
        _ -> load_direct!(source)
      end
    else
      {:error, reason} -> raise ArgumentError, "invalid OgEx image: #{inspect(reason)}"
    end
  end

  # Converts loader failures into declaration errors at the controller boundary.
  defp load_direct!(source) do
    case OgEx.Image.load(source) do
      {:ok, resource} -> resource
      {:error, reason} -> raise ArgumentError, "could not load OgEx image: #{inspect(reason)}"
    end
  end

  # Uses the ordinary Phoenix static URL for public files, the original URL for
  # remote files, and a signed same-route URL for private files.
  defp direct_url(conn, %{source: %{type: :public, reference: path}}, _version, _role),
    do: OgEx.Image.public_url(conn, path)

  defp direct_url(_conn, %{type: :remote, reference: url}, _version, _role), do: url

  defp direct_url(conn, %{source: %{type: :private}} = resource, version, role) do
    image_url(conn, signature(conn, {:existing, version, resource.fingerprint}, role))
  end

  # Returns an inspected resource dimension, or nil for an uninspected remote
  # direct URL.
  defp dimension(%{width: width}, :width), do: width
  defp dimension(%{height: height}, :height), do: height
  defp dimension(_, _dimension), do: nil

  # Returns a verified local resource format when one exists.
  defp format(%{format: format}), do: format
  defp format(_), do: nil

  # Produces a deterministic version for a generated card.
  defp generated_version(card, assigns) do
    value = if function_exported?(card, :version, 1), do: card.version(assigns), else: assigns

    :crypto.hash(:sha256, :erlang.term_to_binary({card, value}, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  # Produces a stable identity for both direct image roles.
  defp direct_version(image, twitter_image) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {resource_identity(image), resource_identity(twitter_image)},
        [:deterministic]
      )
    )
    |> Base.url_encode64(padding: false)
  end

  # Reduces a resource to non-secret cache and signing identity.
  defp resource_identity(%{fingerprint: fingerprint}), do: fingerprint
  defp resource_identity(%{reference: reference}), do: reference

  # Reconstructs the identity originally authenticated in the image URL.
  defp identity(%{strategy: {:generated, card}, version: version}, _role),
    do: {:generated, card, version}

  defp identity(%{strategy: :existing, version: version} = config, role) do
    resource = resource_for(config, role)
    {:existing, version, resource_identity(resource)}
  end

  # Selects the configured resource for a metadata family.
  defp resource_for(config, :image), do: config.image
  defp resource_for(config, :twitter_image), do: config.twitter_image

  # Authenticates a route, response role, and deterministic image identity.
  defp signature(conn, identity, role) do
    message = :erlang.term_to_binary({identity, role, conn.request_path}, [:deterministic])

    :crypto.mac(:hmac, :sha256, signing_key(conn), message)
    |> binary_part(0, @signature_bytes)
    |> Base.url_encode64(padding: false)
  end

  # Derives a domain-separated signing key from Phoenix's secret key base.
  defp signing_key(conn) do
    secret_key_base =
      conn.secret_key_base ||
        conn.private
        |> Map.fetch!(:phoenix_endpoint)
        |> apply(:config, [:secret_key_base])

    :crypto.mac(:hmac, :sha256, secret_key_base, @signature_salt)
  end

  # Builds an absolute same-route URL while retaining application query params.
  defp image_url(conn, signature) do
    query_params =
      conn
      |> Plug.Conn.fetch_query_params()
      |> Map.fetch!(:query_params)
      |> Map.delete(@reserved_parameter)
      |> Map.put(@reserved_parameter, signature)

    Phoenix.Controller.current_url(conn, query_params)
  end
end
