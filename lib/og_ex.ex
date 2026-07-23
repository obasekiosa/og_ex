defmodule OgEx do
  @moduledoc """
  Embedded Open Graph and Twitter card rendering for Phoenix.

  Install `OgEx` in the endpoint, use `OgEx.Controller` in a controller, and
  pass a card module to the normal render call:

      render(conn, :show, post: post, og: MyAppWeb.PostOgCard)

  Normal requests render the Phoenix page and receive social metadata. A signed
  request to the generated image URL reruns the same action and returns the
  rendered card image instead.
  """

  @behaviour Plug

  @doc """
  Initializes the endpoint plug.

  OgEx currently preserves the supplied options unchanged. The callback exists
  to satisfy `Plug` and leaves room for endpoint-specific configuration later.
  """
  @impl Plug
  def init(options), do: options

  @doc """
  Fetches query parameters before the Phoenix router dispatches the request.

  This makes the reserved `__og_ex` image token available when the controller
  reaches its OgEx-aware `render/3` call.
  """
  @impl Plug
  def call(conn, _options) do
    Plug.Conn.fetch_query_params(conn)
  end
end
