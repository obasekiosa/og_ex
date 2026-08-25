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

defmodule OgEx.TestHomeCard do
  @moduledoc false

  use OgEx.Card, width: 1200, height: 630

  @impl OgEx.Card
  def metadata(%{title: title}), do: %{title: title}

  # A fixed version keeps signature tests deterministic.
  @impl OgEx.Card
  def version(_assigns), do: {:test_home_card, 1}

  @impl OgEx.Card
  def load(_conn, _params), do: {:ok, %{title: "Loaded"}}

  @impl OgEx.Card
  def render(assigns) do
    ~H"""
    <main class="card">
      <h1>{@title}</h1>
    </main>

    <style>
      .card {
        width: 100%;
        height: 100%;
        display: flex;
        align-items: center;
        justify-content: center;
        color: white;
        background: #312e81;
        font-family: sans-serif;
      }

      h1 {
        font-size: 72px;
      }
    </style>
    """
  end
end

defmodule OgEx.TestHomeHTML do
  @moduledoc false

  use Phoenix.Component

  def home(assigns) do
    ~H"""
    <html>
      <head><title>Home</title></head>
      <body>Root page</body>
    </html>
    """
  end
end

defmodule OgEx.TestHomeController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]
  use OgEx.Controller

  og_card(:home, OgEx.TestHomeCard, image_route: :path)

  def home(conn, _params) do
    conn
    |> Phoenix.Controller.put_view(html: OgEx.TestHomeHTML)
    |> render(:home, title: "Loaded")
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

    get "/", OgEx.TestHomeController, :home
    get "/posts/:id", OgEx.TestPathController, :show
    get "/query-posts/:id", OgEx.TestController, :show
  end

  og_ex_routes()
end
