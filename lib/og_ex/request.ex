defmodule OgEx.Request do
  @moduledoc false

  @parameter "__og_ex"

  # Fetching query params is idempotent. Doing it only when the controller
  # reaches its OgEx-aware render keeps endpoint setup unnecessary.
  @doc """
  Returns `true` when the request contains an OgEx image signature.
  """
  def image_request?(conn), do: is_binary(signature(conn))

  @doc """
  Lazily fetches and returns the image signature, or `nil` when absent.
  """
  def signature(conn) do
    conn
    |> Plug.Conn.fetch_query_params()
    |> Map.fetch!(:query_params)
    |> Map.get(@parameter)
  end
end
