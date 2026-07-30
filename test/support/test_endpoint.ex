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
