defmodule OgEx.Dispatcher do
  @moduledoc false

  import Plug.Conn

  @role_segments ["opengraph-image", "twitter-image"]

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

  # Recognizes signed image paths by splitting on segments. The role segment
  # and signature are always the last two segments; everything before them is
  # the canonical page path. A missing page segment is the root page "/".
  # Trailing slashes on the image URL itself are ignored so crawlers that
  # append one still reach the image.
  #
  #   "/opengraph-image/TOKEN"          -> page "/", role :image
  #   "/posts/42/opengraph-image/TOKEN" -> page "/posts/42", role :image
  defp path_request(path) do
    case String.split(String.trim_trailing(path, "/"), "/") do
      ["" | segments] when segments != [] ->
        case Enum.split(segments, -2) do
          {page_segments, [role_segment, signature]}
          when role_segment in @role_segments and signature != "" ->
            {:ok, build_page_path(page_segments), role(role_segment), signature}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp build_page_path([]), do: "/"
  defp build_page_path(segments), do: "/" <> Enum.join(segments, "/")

  defp role("twitter-image"), do: :twitter_image
  defp role(_segment), do: :image

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
