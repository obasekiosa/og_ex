defmodule OgEx.TestEndpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :og_ex
end

defmodule OgEx.TestController do
  use Phoenix.Controller, formats: [:html]
  use OgEx.Controller

  og_card(:show, OgEx.TestCard, image_route: :query)
  og_card(:preview, OgEx.TestCard, load: &load_preview/2)

  defp load_preview(_conn, %{"id" => id}), do: {:ok, %{title: "Preview #{id}"}}
end

defmodule OgEx.TestHTML do
  use Phoenix.Component

  def show(assigns) do
    ~H"""
    <html>
      <head><title>{@title}</title></head>
      <body>Normal page</body>
    </html>
    """
  end
end

defmodule OgEx.TestPathController do
  use Phoenix.Controller, formats: [:html]
  use OgEx.Controller

  og_card(:show, OgEx.TestCard, image_route: :path)

  def show(conn, %{"id" => id}) do
    conn
    |> Phoenix.Controller.put_view(html: OgEx.TestHTML)
    |> render(:show, title: "Loaded #{id}")
  end
end

defmodule OgEx.TestRouter do
  use Phoenix.Router
  import OgEx.Router

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/" do
    pipe_through :browser

    get "/posts/:id", OgEx.TestPathController, :show
    get "/query-posts/:id", OgEx.TestController, :show
  end

  og_ex_routes()
end
