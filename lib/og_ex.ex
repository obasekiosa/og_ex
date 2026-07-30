defmodule OgEx do
  @moduledoc """
  Open Graph and Twitter/X image support for Phoenix controllers.

  Add `OgEx.Controller` to a controller, then pass either an `OgEx.Card`
  module or direct image metadata to its normal `render/3` call:

      render(conn, :show, post: post, og: MyAppWeb.PostOgCard)

      render(conn, :about,
        og: [title: "About Acme", image: "/images/about-og.png"]
      )

  Generated cards use a signed version of the page URL. The signed request runs
  the same controller action and returns the image when it reaches `render/3`.
  Direct public and external images use their existing URLs; direct private
  images use a signed controller URL.

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
  Initializes the compatibility plug.

  New applications do not need this plug because controller rendering fetches
  the reserved query parameter lazily.
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
  Fetches query parameters for an endpoint that still installs `plug OgEx`.

  The controller integration performs the same operation lazily, so this
  compatibility callback is not required in new endpoint configurations.
  """
  @impl Plug
  def call(conn, options) do
    case options[:router] do
      nil -> Plug.Conn.fetch_query_params(conn)
      router -> OgEx.Dispatcher.endpoint(conn, router)
    end
  end
end
