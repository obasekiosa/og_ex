defmodule OgEx.ConfigBuilder do
  @moduledoc false

  @signature_salt "og-ex-image-v1"
  @signature_bytes 16
  @reserved_parameter "__og_ex"

  @doc """
  Builds deterministic metadata and image-response configuration.

  The returned config includes the card metadata, rendering dimensions, content
  version, and an absolute signed image URL derived from the current route.
  """
  def build(conn, card, assigns) when is_atom(card) and is_map(assigns) do
    # Metadata and presentation receive identical assigns. Keeping them
    # together prevents title/description/image content from drifting apart.
    metadata = card.metadata(assigns)
    version = version(card, assigns)

    # Only a compact MAC is placed in the URL. The controller reconstructs the
    # card and version later, so embedding them in the parameter is redundant.
    signature = signature(conn, card, version)

    %OgEx.Config{
      card: card,
      assigns: assigns,
      metadata: metadata,
      width: card.__og_ex__(:width),
      height: card.__og_ex__(:height),
      format: card.__og_ex__(:format),
      version: version,
      image_url: image_url(conn, signature)
    }
  end

  @doc """
  Verifies that an image request signature matches the rebuilt configuration.

  The expected signature binds the card module, content version, and route.
  """
  def verify(conn, %OgEx.Config{} = config) do
    expected = signature(conn, config.card, config.version)

    # Compare equal-length binaries in constant time. A changed card, version,
    # or route produces a different expected signature.
    with supplied when is_binary(supplied) <- OgEx.Request.signature(conn),
         true <- byte_size(supplied) == byte_size(expected),
         true <- Plug.Crypto.secure_compare(supplied, expected) do
      :ok
    else
      _ -> {:error, :invalid_image_signature}
    end
  end

  # Produces the stable, URL-safe SHA-256 version used by signatures, ETags, and
  # cache keys. A card-specific version callback avoids hashing unrelated page
  # assigns.
  defp version(card, assigns) do
    # Cards may define a compact, stable version callback. Without one, the
    # complete assigns map is used as a convenient development default.
    value =
      if function_exported?(card, :version, 1) do
        card.version(assigns)
      else
        assigns
      end

    # URL-safe SHA-256 provides a deterministic cache key without exposing the
    # original assigns in the public image URL.
    :crypto.hash(:sha256, :erlang.term_to_binary({card, value}, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  # Authenticates the reconstructed image identity without embedding it in the
  # URL. A 128-bit truncated HMAC becomes 22 base64url characters.
  defp signature(conn, card, version) do
    message =
      :erlang.term_to_binary(
        {card, version, conn.request_path},
        [:deterministic]
      )

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

  # Builds an absolute URL for the current page while preserving existing query
  # parameters and replacing any previous OgEx signature.
  defp image_url(conn, signature) do
    # Preserve application query parameters such as locale or preview mode.
    # Only a previous OgEx signature is replaced.
    query_params =
      conn
      |> Plug.Conn.fetch_query_params()
      |> Map.fetch!(:query_params)
      |> Map.delete(@reserved_parameter)
      |> Map.put(@reserved_parameter, signature)

    Phoenix.Controller.current_url(conn, query_params)
  end
end
