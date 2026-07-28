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
  Initializes the compatibility plug.

  New applications do not need this plug because controller rendering fetches
  the reserved query parameter lazily.
  """
  @impl Plug
  def init(options), do: options

  @doc """
  Fetches query parameters for an endpoint that still installs `plug OgEx`.

  The controller integration performs the same operation lazily, so this
  compatibility callback is not required in new endpoint configurations.
  """
  @impl Plug
  def call(conn, _options) do
    Plug.Conn.fetch_query_params(conn)
  end
end
