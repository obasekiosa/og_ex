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

defmodule OgEx.TestPathController do
  use Phoenix.Controller, formats: [:html]
  use OgEx.Controller

  og_card(:show, OgEx.TestCard, image_route: :path)

  def show(conn, _params), do: Plug.Conn.send_resp(conn, :ok, "page action")
end

defmodule OgEx.TestRouter do
  use Phoenix.Router
  import OgEx.Router

  get "/posts/:id", OgEx.TestPathController, :show

  og_ex_routes()
end
