defmodule OgEx.Request do
  @moduledoc false

  @parameter "__og_ex"

  # Fetching query params is idempotent. Doing it here makes this module robust
  # even if an application omitted the optional endpoint-level `plug OgEx`.
  @doc """
  Returns `true` when the request contains an OgEx image token.
  """
  def image_request?(conn), do: is_binary(token(conn))

  @doc """
  Returns the reserved image token from the request, or `nil` when absent.
  """
  def token(conn) do
    conn
    |> Plug.Conn.fetch_query_params()
    |> Map.fetch!(:query_params)
    |> Map.get(@parameter)
  end
end
