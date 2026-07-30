defmodule OgEx.Dispatcher do
  @moduledoc false

  import Plug.Conn

  @path_pattern ~r{\A(?<page_path>/.*?)/(?<role>opengraph-image|twitter-image)/(?<signature>[^/]+)\z}

  @doc """
  Dispatches an endpoint request when it is an OgEx path or query image.

  Requests that do not resolve to an OgEx declaration are returned unchanged
  so the application's Phoenix router retains ownership.
  """
  def endpoint(conn, router) when is_atom(router) do
    case path_request(conn.request_path) do
      {:ok, page_path, role, signature} ->
        dispatch_path(conn, router, page_path, role, signature, :endpoint)

      :error ->
        dispatch_query(conn, router)
    end
  end

  @doc """
  Dispatches an unmatched request received through `og_ex_routes/1`.

  Unlike endpoint integration, a final router route owns the unmatched request,
  so non-OgEx paths receive the normal empty 404 response.
  """
  def router(conn, router) when is_atom(router) do
    case path_request(conn.request_path) do
      {:ok, page_path, role, signature} ->
        dispatch_path(conn, router, page_path, role, signature, :router)

      :error ->
        send_resp(conn, :not_found, "")
    end
  end

  defp dispatch_query(conn, router) do
    if OgEx.Request.image_request?(conn) do
      case route_info(router, conn, conn.request_path) do
        {:ok, controller, action, path_params} ->
          declaration = declaration(controller, action)

          if declaration && OgEx.Controller.route_strategy(declaration) == :query do
            params = merged_params(conn, path_params)

            conn
            |> Map.put(:path_params, path_params)
            |> OgEx.Request.put_origin(
              controller,
              action,
              :image,
              params,
              page_path: conn.request_path
            )
            |> OgEx.Controller.dispatch_image(controller, action)
          else
            conn
          end

        :error ->
          conn
      end
    else
      conn
    end
  end

  defp dispatch_path(conn, router, page_path, role, signature, owner) do
    case route_info(router, conn, page_path) do
      {:ok, controller, action, path_params} ->
        declaration = declaration(controller, action)

        if declaration && OgEx.Controller.route_strategy(declaration) == :path do
          params = merged_params(conn, path_params)

          conn
          |> Map.put(:path_params, path_params)
          |> OgEx.Request.put_origin(
            controller,
            action,
            role,
            params,
            page_path: page_path,
            signature: signature
          )
          |> OgEx.Controller.dispatch_image(controller, action)
        else
          not_handled(conn, owner)
        end

      :error ->
        not_handled(conn, owner)
    end
  end

  defp path_request(path) do
    case Regex.named_captures(@path_pattern, path) do
      %{"page_path" => page_path, "role" => role, "signature" => signature} ->
        role = if role == "twitter-image", do: :twitter_image, else: :image
        {:ok, page_path, role, signature}

      _ ->
        :error
    end
  end

  defp route_info(router, conn, page_path) do
    case Phoenix.Router.route_info(router, conn.method, page_path, conn.host) do
      %{plug: controller, plug_opts: action} = info
      when is_atom(controller) and is_atom(action) ->
        {:ok, controller, action, Map.get(info, :path_params, %{})}

      _ ->
        :error
    end
  end

  defp declaration(controller, action) do
    if Code.ensure_loaded?(controller) and
         function_exported?(controller, :__og_ex_declaration__, 1) do
      controller.__og_ex_declaration__(action)
    end
  end

  defp merged_params(conn, path_params) do
    conn
    |> fetch_query_params()
    |> Map.fetch!(:query_params)
    |> Map.delete("__og_ex")
    |> Map.merge(path_params)
  end

  defp not_handled(conn, :endpoint), do: conn
  defp not_handled(conn, :router), do: send_resp(conn, :not_found, "")
end
