defmodule OgEx.ConfigBuilder do
  @moduledoc false

  @token_salt "og-ex-image-v1"
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

    # Phoenix.Token authenticates the card module and its content version with
    # the application's secret_key_base. A caller cannot turn an arbitrary
    # query parameter into an expensive render request.
    token = Phoenix.Token.sign(conn, @token_salt, {card, version})

    %OgEx.Config{
      card: card,
      assigns: assigns,
      metadata: metadata,
      width: card.__og_ex__(:width),
      height: card.__og_ex__(:height),
      format: card.__og_ex__(:format),
      version: version,
      image_url: image_url(conn, token)
    }
  end

  @doc """
  Verifies that an image request token matches the rebuilt card configuration.

  Both the signed card module and the content version must match.
  """
  def verify(conn, %OgEx.Config{} = config) do
    max_age = Application.get_env(:og_ex, :token_max_age, 31_536_000)

    # Verification checks both the token signature and the config rebuilt by
    # the current controller action. A valid but stale token cannot be used to
    # render changed data under an old immutable URL.
    with token when is_binary(token) <- OgEx.Request.token(conn),
         {:ok, {card, version}} <-
           Phoenix.Token.verify(conn, @token_salt, token, max_age: max_age),
         true <- card == config.card,
         true <- Plug.Crypto.secure_compare(version, config.version) do
      :ok
    else
      _ -> {:error, :invalid_image_token}
    end
  end

  # Produces the stable, URL-safe SHA-256 version used by tokens, ETags, and
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

  # Builds an absolute URL for the current page while preserving existing query
  # parameters and replacing any previous OgEx token.
  defp image_url(conn, token) do
    # Preserve application query parameters such as locale or preview mode.
    # Only a previous OgEx token is replaced.
    query_params =
      conn
      |> Plug.Conn.fetch_query_params()
      |> Map.fetch!(:query_params)
      |> Map.delete(@reserved_parameter)
      |> Map.put(@reserved_parameter, token)

    Phoenix.Controller.current_url(conn, query_params)
  end
end
