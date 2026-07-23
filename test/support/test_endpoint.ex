defmodule OgEx.TestEndpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :og_ex
end

defmodule OgEx.TestController do
  use Phoenix.Controller, formats: [:html]
  use OgEx.Controller
end
