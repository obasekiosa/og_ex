defmodule OgEx do
  @moduledoc """
  Open Graph and Twitter/X image support for Phoenix controllers.

  Add `OgEx.Controller` to a controller and declare a card for an action:

      og_card :show, MyAppWeb.PostOgCard

  Card-local `load/2` retrieves image-specific assigns without running the
  normal controller action. Applications can choose signed path or query image
  URLs.

  Path mode supports either `OgEx.Router.og_ex_routes/1` or
  `plug OgEx, router: MyAppWeb.Router`. Choose one, not both. Query mode can be
  intercepted by the controller integration without either path integration.

  Legacy generated-card and direct-image `render(..., og: declaration)` calls
  remain supported.

  See the project README for complete setup, source types, remote-image policy,
  caching, and current failure behavior.
  """

  @behaviour Plug

  @doc """
  Builds an opaque HEEx source for a private image.

  `path` is relative to the configured `:private_asset_root`. Use the return
  value as an `<img src>` inside a generated card:

      <img src={OgEx.private_asset("backgrounds/report.png")} />

  OgEx resolves and verifies the file on the signed image request. The returned
  string is meaningful only to OgEx's resource loader; it is not a public URL.
  """
  defdelegate private_asset(path), to: OgEx.Image

  @doc """
  Returns the controller that declared the current card.

  This is available during declaration-based image loading. It returns `nil`
  for ordinary requests and legacy render-time cards.
  """
  def controller(conn) do
    case OgEx.Request.origin(conn) do
      %{controller: controller} -> controller
      _ -> nil
    end
  end

  @doc """
  Returns the action that declared the current card.
  """
  def action(conn) do
    case OgEx.Request.origin(conn) do
      %{action: action} -> action
      _ -> nil
    end
  end

  @doc """
  Returns normalized route parameters for the current image request.
  """
  defdelegate route_params(conn), to: OgEx.Request, as: :params

  @doc """
  Returns `:open_graph` or `:twitter` for the current image request.
  """
  def image_role(conn) do
    case OgEx.Request.origin(conn) do
      %{role: :image} -> :open_graph
      %{role: :twitter_image} -> :twitter
      _ -> nil
    end
  end

  @doc """
  Initializes endpoint image dispatch.

  Pass `router: MyAppWeb.Router` to use endpoint integration. OgEx warns when
  that router also contains `og_ex_routes()`.
  """
  @impl Plug
  def init(options) do
    options = Keyword.new(options)

    if router = options[:router] do
      OgEx.Integration.warn_if_duplicate(router)
    end

    options
  end

  @doc """
  Dispatches endpoint image requests or preserves legacy query fetching.

  With a configured router, candidate path and query image requests are
  resolved before Phoenix routing. Without one, this retains the `0.2.x`
  compatibility behavior.
  """
  @impl Plug
  def call(conn, options) do
    case options[:router] do
      nil -> Plug.Conn.fetch_query_params(conn)
      router -> OgEx.Dispatcher.endpoint(conn, router)
    end
  end
end
