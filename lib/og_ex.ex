defmodule OgEx do
  @moduledoc """
  Embedded Open Graph and Twitter card rendering for Phoenix.

  Use `OgEx.Controller` in a controller and pass a card module to the normal
  render call:

      render(conn, :show, post: post, og: MyAppWeb.PostOgCard)

  Normal requests render the Phoenix page and receive social metadata. A signed
  request to the generated image URL reruns the same action and returns the
  rendered card image instead.
  """

  @behaviour Plug

  @doc """
  Initializes the optional compatibility endpoint plug.

  New applications do not need this plug because controller rendering fetches
  the reserved query parameter lazily.
  """
  @impl Plug
  def init(options), do: options

  @doc """
  Fetches query parameters for applications that still install `plug OgEx`.

  The controller integration performs the same operation lazily, so this
  compatibility callback is not required in new endpoint configurations.
  """
  @impl Plug
  def call(conn, _options) do
    Plug.Conn.fetch_query_params(conn)
  end
end
