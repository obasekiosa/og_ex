defmodule OgEx.Request do
  @moduledoc false

  @parameter "__og_ex"
  @origin_private :og_ex_origin

  # Fetching query params is idempotent. Doing it only when the controller
  # reaches its OgEx-aware render keeps endpoint setup unnecessary.
  @doc """
  Returns the canonical form of a page path.

  Trailing slashes are trimmed so signatures bind to one stable form, and the
  root page canonicalizes to `"/"`. URL generation, dispatch origins, and
  signature verification all share this function.
  """
  def canonical_page_path(path) when is_binary(path) do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      canonical -> canonical
    end
  end

  @doc """
  Returns `true` when the request contains an OgEx image signature.
  """
  def image_request?(conn), do: is_binary(signature(conn))

  @doc """
  Lazily fetches and returns the image signature, or `nil` when absent.
  """
  def signature(conn) do
    case origin(conn) do
      %{signature: signature} when is_binary(signature) ->
        signature

      _ ->
        conn
        |> Plug.Conn.fetch_query_params()
        |> Map.fetch!(:query_params)
        |> Map.get(@parameter)
    end
  end

  @doc """
  Stores trusted declaration information on an image request.

  The values must come from a verified OgEx declaration, never directly from
  request-controlled module or atom names.
  """
  def put_origin(conn, controller, action, role, params, options \\ [])
      when is_atom(controller) and is_atom(action) and role in [:image, :twitter_image] and
             is_map(params) do
    Plug.Conn.put_private(conn, @origin_private, %{
      controller: controller,
      action: action,
      role: role,
      params: params,
      page_path: Keyword.get(options, :page_path, canonical_page_path(conn.request_path)),
      signature: Keyword.get(options, :signature)
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

  @doc """
  Returns the canonical page path bound to the current image request.
  """
  def page_path(conn) do
    case origin(conn) do
      %{page_path: page_path} -> page_path
      _ -> canonical_page_path(conn.request_path)
    end
  end
end
