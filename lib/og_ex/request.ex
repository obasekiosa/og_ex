defmodule OgEx.Request do
  @moduledoc false

  @parameter "__og_ex"
  @origin_private :og_ex_origin

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

  @doc """
  Stores trusted declaration information on an image request.

  The values must come from a verified OgEx declaration, never directly from
  request-controlled module or atom names.
  """
  def put_origin(conn, controller, action, role, params)
      when is_atom(controller) and is_atom(action) and role in [:image, :twitter_image] and
             is_map(params) do
    Plug.Conn.put_private(conn, @origin_private, %{
      controller: controller,
      action: action,
      role: role,
      params: params
    })
  end

  @doc """
  Returns trusted declaration information stored on an image request.
  """
  def origin(conn), do: Map.get(conn.private, @origin_private)

  @doc """
  Returns normalized page parameters for a declaration-based image request.
  """
  def params(conn) do
    case origin(conn) do
      %{params: params} -> params
      _ -> application_params(conn)
    end
  end

  @doc """
  Returns path and query parameters without OgEx's reserved signature.
  """
  def application_params(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    conn.query_params
    |> Map.delete(@parameter)
    |> Map.merge(conn.path_params || %{})
  end
end
